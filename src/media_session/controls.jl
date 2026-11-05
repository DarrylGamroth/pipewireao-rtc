# Cold policy adapters. These methods run only on the serialized Julia owner task.
const PolicySPA = PipeWireAO.SPA
const PolicyPod = PipeWireAO.Pod
policy_struct(values::PolicyPod...) = PolicySPA.Struct(PolicyPod[values...])
policy_scalar(pod, tag, ::Type{T}) where T = begin
    PipeWireAO.pod_type(pod) == tag && sizeof(pod) == 8 + (T === Bool ? 4 : sizeof(T)) ||
        throw(ArgumentError("wrong native scalar type or width"))
    PipeWireAO.pod_value(T, pod)
end
policy_long(pod) = policy_scalar(pod,PolicySPA.POD_LONG,Int64)
policy_int(pod) = policy_scalar(pod,PolicySPA.POD_INT,Int32)
policy_id(pod) = policy_scalar(pod,PolicySPA.POD_ID,PolicySPA.Id).value
policy_bool(pod) = policy_scalar(pod,PolicySPA.POD_BOOL,Bool)
function policy_text(pod; limit=8192, empty=true)
    PipeWireAO.pod_type(pod) == PolicySPA.POD_STRING || throw(ArgumentError("expected native String"))
    value = PipeWireAO.pod_value(String,pod)
    isvalid(value) && ncodeunits(value) <= limit && !occursin('\0',value) && (empty || !isempty(value)) ||
        throw(ArgumentError("invalid native String"))
    return value
end
function policy_fields(pod, count)
    fields = PipeWireAO.pod_value(PolicySPA.Struct,pod).values
    length(fields) == count || throw(ArgumentError("wrong native Struct arity"))
    return fields
end
function named_values(pod)
    result = Dict{String,PolicyPod}()
    for (name,value) in PolicySPA.Props(pod).values
        haskey(result,name) && throw(ArgumentError("duplicate named property"))
        result[name] = value
    end
    return result
end
function named_properties!(runtime,job,handle)
    records = enumerate!(runtime,job,handle,"Props")
    length(records) <= 32 || throw(ArgumentError("owner Props reply exceeds bound"))
    result = Dict{String,PolicyPod}()
    for record in records, (name,value) in named_values(record)
        haskey(result,name) && throw(ArgumentError("duplicate owner property"))
        result[name] = value
    end
    return result
end
function next_control_token!(runtime, minimum::Int64=Int64(0))
    token = max(runtime.token,minimum)
    token < typemax(Int64) || throw(ArgumentError("owner control token space exhausted"))
    runtime.token = token+1
    return runtime.token
end
function identity_integer(runtime,handle,key)
    value = property(runtime,handle,key)
    value !== nothing && occursin(r"^[0-9]+$",value) || throw(ArgumentError("missing native identity property: $key"))
    parsed = tryparse(Int64,value)
    parsed !== nothing && parsed > 0 || throw(ArgumentError("invalid native identity property: $key"))
    return parsed
end

# HEART stays an external owner. This profile only decodes its public v1 wire records.
struct HeartProfile <: ControlClient.Profile end
@enum HeartLifecycle::UInt32 HeartPreparing=1 HeartReady=2 HeartFault=3 HeartStopped=4
struct HeartCommand{O} end
struct HeartSnapshot
    generation::Int64
    pid::Union{Nothing,UInt32}
    returncode::Union{Nothing,Int32}
    alive::Bool
    ingress::UInt32
    placement_applied::Bool
    placement_verified::Bool
    report_path::String
    report_digest::String
end
struct HeartCompletion
    header::ControlCodec.ReplyHeader
    lifecycle::HeartLifecycle
    snapshot::HeartSnapshot
    message::String
end
struct HeartRejection
    header::ControlCodec.ReplyHeader
    lifecycle::HeartLifecycle
    message::String
end
ControlClient.profile_name(::HeartProfile) = "pipewireao.rtc.heart/1"
ControlClient.capability_names(::HeartProfile) = Tuple("pipewireao.rtc.heart."*name for name in
    ("version","instance","owner-pid","lifecycle","last-token","controllers"))
ControlClient.lifecycle_type(::HeartProfile) = HeartLifecycle
ControlClient.completion_type(::HeartProfile) = HeartCompletion
ControlClient.rejection_type(::HeartProfile) = HeartRejection
ControlClient.operation_id(::HeartProfile,::HeartCommand{:status}) = UInt32(1)
ControlClient.operation_id(::HeartProfile,::HeartCommand{:connect}) = UInt32(3)
ControlClient.operation_id(::HeartProfile,::HeartCommand{:quit}) = UInt32(4)
ControlClient.encode_request(profile::HeartProfile,header,command::HeartCommand) =
    (header.operation == ControlClient.operation_id(profile,command) || throw(ArgumentError("HEART operation mismatch"));
     ControlCodec.encode_request(header,policy_struct()))
function ControlClient.decode_completion(::HeartProfile,input)
    header,payload = ControlCodec.decode_completion(input;endpoint=:lifecycle)
    f = payload.values
    length(f) == 3 || throw(ArgumentError("wrong HEART completion arity"))
    state = HeartLifecycle(policy_id(f[1]))
    s = policy_fields(f[2],9)
    generation = policy_long(s[1]); generation >= 0 || throw(ArgumentError("invalid HEART generation"))
    pid = PipeWireAO.pod_type(s[2]) == PolicySPA.POD_NONE ? nothing : policy_id(s[2])
    pid === nothing || pid > 0 || throw(ArgumentError("invalid HEART child PID"))
    returncode = PipeWireAO.pod_type(s[3]) == PolicySPA.POD_NONE ? nothing : policy_int(s[3])
    alive = policy_bool(s[4]); ingress = policy_id(s[5])
    ingress in (1,2) || throw(ArgumentError("unknown HEART ingress mode"))
    path = policy_text(s[8];limit=4096); digest = policy_text(s[9];limit=64)
    isempty(digest) || occursin(r"^[0-9a-f]{64}$",digest) || throw(ArgumentError("invalid HEART report SHA-256"))
    snapshot = HeartSnapshot(generation,pid,returncode,alive,ingress,policy_bool(s[6]),policy_bool(s[7]),path,digest)
    return HeartCompletion(header,state,snapshot,policy_text(f[3]))
end
function ControlClient.decode_rejection(::HeartProfile,input)
    header,payload = ControlCodec.decode_rejection(input;endpoint=:lifecycle)
    length(payload.values) == 2 || throw(ArgumentError("wrong HEART rejection arity"))
    return HeartRejection(header,HeartLifecycle(policy_id(payload.values[1])),policy_text(payload.values[2]))
end

abstract type AbstractOwner end
mutable struct Owner{P<:ControlClient.Profile,O<:ControlClient.Observation} <: AbstractOwner
    profile::P
    observation::O
    handle::UInt64
    pid::UInt32
    instance::Int64
    retired::Bool
end
function check_owner!(runtime,owner::Owner)
    owner.retired && throw(ArgumentError("owner is retired"))
    assert_identity!(runtime,owner.handle)
    property(runtime,owner.handle,"pipewireao.rtc-control.protocol") == ControlClient.PROTOCOL &&
        property(runtime,owner.handle,"pipewireao.rtc-control.profile") == ControlClient.profile_name(owner.profile) &&
        identity_integer(runtime,owner.handle,"pipewireao.rtc-control.instance") == owner.instance &&
        identity_integer(runtime,owner.handle,"pipewireao.rtc-control.owner-pid") == owner.pid ||
        throw(ArgumentError("owner control identity changed"))
    return nothing
end
function capture_owner(runtime,handle::UInt64,profile::ControlClient.Profile,instance::Integer,pid::Integer)
    0 < instance <= typemax(Int64) && 0 < pid < typemax(UInt32) || throw(ArgumentError("invalid owner incarnation"))
    capture!(runtime,handle)
    owner = Owner(profile,ControlClient.Observation(profile,Int64(instance),UInt32(pid)),handle,UInt32(pid),Int64(instance),false)
    check_owner!(runtime,owner)
    return owner
end
owner_profile(::Val{Symbol("pipewireao.rtc.owner-bootstrap")}) = OwnerBootstrapCodec.PROFILE
owner_profile(::Val{Symbol("pipewireao.rtc.heart")}) = HeartProfile()
owner_profile(::Val{Symbol("pipewireao.rtc.calibration-lifecycle")}) = AcquisitionLifecycleCodec.CALIBRATION_PROFILE
owner_profile(::Val{Symbol("pipewireao.rtc.correction-lifecycle")}) = AcquisitionLifecycleCodec.CORRECTION_PROFILE
owner_profile(::Val{Symbol("pipewireao.rtc.parameter-source")}) = ParameterSource.PROFILE
owner_profile(::Val) = throw(ArgumentError("unsupported owner profile"))
capture_owner(runtime,handle::UInt64,namespace::AbstractString,instance::Integer,pid::Integer) =
    capture_owner(runtime,handle,owner_profile(Val(Symbol(namespace))),instance,pid)
function observe_owner!(runtime,job,owner::Owner)
    check_owner!(runtime,owner)
    records = enumerate!(runtime,job,owner.handle,"Props")
    length(records) <= 3 || throw(ArgumentError("owner published too many Props records"))
    kinds = Set{String}()
    for pod in records
        values = named_values(pod)
        names = ControlClient.capability_names(owner.profile)
        kind = haskey(values,names[1]) ? "capability" : haskey(values,"pipewireao.rtc.control.completion.header") ? "completion" :
            haskey(values,"pipewireao.rtc.control.rejection.header") ? "rejection" : throw(ArgumentError("unrecognized owner Props record"))
        kind in kinds && throw(ArgumentError("duplicate owner Props record"))
        push!(kinds,kind)
        ControlClient.observe!(owner.observation,pod;at=now(runtime))
    end
    "capability" in kinds || throw(ArgumentError("owner capability is unavailable"))
    check_owner!(runtime,owner)
    owner.observation.fatal_failure === nothing || throw(ArgumentError(owner.observation.fatal_failure))
    return owner.observation.capability
end
function wait_prepared!(runtime,job,owner::Owner)
    owner.observation.pending === nothing || throw(ArgumentError("owner operation already pending"))
    return await_condition!(runtime,job) do
        capability = observe_owner!(runtime,job,owner)
        state = UInt32(capability.lifecycle)
        state in (1,2) || throw(ArgumentError("owner preparation reached unexpected lifecycle"))
        state == 2 && runtime.controller in capability.controllers ? capability.lifecycle : nothing
    end
end
function request_owner!(runtime,job,owner::Owner,command)
    observation = owner.observation
    observation.pending === nothing || throw(ArgumentError("owner operation already pending"))
    deadline = min(job.ticket.deadline,now(runtime)+60.0)
    submitted = false
    try
        return await_condition!(runtime,job) do
            now(runtime) < deadline || throw(ControlClient.UnknownOutcome(submitted ? "owner completion timed out" : "owner registration timed out"))
            capability = observe_owner!(runtime,job,owner)
            if submitted
                reply = ControlClient.matching_reply(observation,deadline)
                reply === nothing && return nothing
                reply.header.result == 0 || throw(ArgumentError("owner rejected operation ($(reply.header.result))"))
                return reply
            end
            runtime.controller in capability.controllers || return nothing
            token = next_control_token!(runtime,observation.max_accepted)
            budget = max(Int64(1),floor(Int64,(deadline-now(runtime))*1e9))
            header = ControlCodec.RequestHeader(runtime.controller,owner.instance,token,
                ControlClient.operation_id(owner.profile,command),budget)
            request = ControlClient.encode_request(owner.profile,header,command)
            observation.pending = header
            observation.matched_completion = nothing; observation.matched_rejection = nothing
            submitted = true
            setparam!(runtime,job,owner.handle,"Props",request)
            return nothing
        end
    finally
        observation.pending = nothing
        observation.matched_completion = nothing; observation.matched_rejection = nothing
    end
end
connect_command(::OwnerBootstrapCodec.Profile) = OwnerBootstrapCodec.Command(:connect)
connect_command(::HeartProfile) = HeartCommand{:connect}()
shutdown_command(::OwnerBootstrapCodec.Profile) = OwnerBootstrapCodec.Command(:quit)
shutdown_command(::HeartProfile) = HeartCommand{:quit}()
function connect_owner!(runtime,job,owner::Owner)
    wait_prepared!(runtime,job,owner)
    reply = request_owner!(runtime,job,owner,connect_command(owner.profile))
    validate_connected(reply)
    return reply
end
validate_connected(reply::OwnerBootstrapCodec.Completion) =
    (reply.lifecycle == OwnerBootstrapCodec.Connected || throw(ArgumentError("bootstrap owner did not connect")); nothing)
function validate_connected(reply::HeartCompletion)
    s = reply.snapshot
    reply.lifecycle == HeartReady && s.generation >= 1 && s.pid !== nothing && s.returncode === nothing &&
        s.alive && !isempty(s.report_path) && occursin(r"^[0-9a-f]{64}$",s.report_digest) ||
        throw(ArgumentError("HEART wrapper did not complete Ready with a live child report"))
    return nothing
end
function shutdown_owner!(runtime,job,owner::Owner)
    reply = request_owner!(runtime,job,owner,shutdown_command(owner.profile))
    validate_stopped(reply)
    owner.retired = true
    return reply
end
validate_stopped(reply::OwnerBootstrapCodec.Completion) =
    (reply.lifecycle == OwnerBootstrapCodec.Stopped || throw(ArgumentError("bootstrap owner did not stop")); nothing)
validate_stopped(reply::HeartCompletion) =
    (reply.lifecycle == HeartStopped && !reply.snapshot.alive || throw(ArgumentError("HEART child remained alive after shutdown")); nothing)

"A normalized finite-source cursor; cold profile details retain their declared type."
struct SourceSnapshot{D}
    running::Bool
    completed::Bool
    generation::UInt64
    sequence::UInt64
    report_generation::UInt64
    report_sequence::UInt64
    details::D
end
abstract type AbstractAcquisitionSource end
const AcquisitionSource = AbstractAcquisitionSource
mutable struct ColdSource{O<:Owner} <: AbstractAcquisitionSource
    owner::O
    instrument::Union{Nothing,AcquisitionLifecycleCodec.Instrument}
    previous::Union{Nothing,AcquisitionLifecycleCodec.AcquisitionCursor}
end
struct LegacyDetails
    kind::Int32
    token::Int64
    result::Int32
end
mutable struct LegacySource <: AbstractAcquisitionSource
    handle::UInt64
    pid::UInt32
    instance::Int64
    previous::Union{Nothing,SourceSnapshot{LegacyDetails}}
end
function source(runtime,handle::UInt64,declaration)
    pid = Int64(declaration["pid"])
    0 < pid < typemax(UInt32) || throw(ArgumentError("invalid acquisition owner PID"))
    name = get(declaration,"control-node",nothing)
    name === nothing || property(runtime,handle,"node.name") == name || throw(ArgumentError("acquisition node name mismatch"))
    profile = declaration["control-protocol"]
    if profile == "pipewireao.source-control/1"
        capture!(runtime,handle)
        instance = identity_integer(runtime,handle,"pipewireao.source-control.instance")
        identity_integer(runtime,handle,"pipewireao.source-control.owner-pid") == pid || throw(ArgumentError("source PID mismatch"))
        return LegacySource(handle,UInt32(pid),instance,nothing)
    end
    profile in ("pipewireao.rtc.calibration-lifecycle/1","pipewireao.rtc.correction-lifecycle/1") ||
        throw(ArgumentError("unsupported acquisition profile"))
    owner = capture_owner(runtime,handle,chopsuffix(profile,"/1"),parse(Int64,string(declaration["control-instance"])),pid)
    instrument = get(declaration,"instrument",nothing)
    normalized = instrument === nothing ? nothing : instrument in ("classic","Classic",1) ? AcquisitionLifecycleCodec.Classic :
        instrument in ("copper","Copper",2) ? AcquisitionLifecycleCodec.Copper : throw(ArgumentError("invalid acquisition instrument"))
    return ColdSource(owner,normalized,nothing)
end
function source_snapshot!(source::ColdSource,reply::AcquisitionLifecycleCodec.Completion)
    snapshot = reply.snapshot
    snapshot === nothing && throw(ArgumentError("acquisition snapshot unavailable"))
    source.instrument === nothing || source.instrument == snapshot.instrument || throw(ArgumentError("acquisition instrument changed"))
    source.instrument = snapshot.instrument
    cursor = snapshot.cursor; report = snapshot.report_cursor
    source.previous = cursor
    return SourceSnapshot(snapshot.running,snapshot.completed,cursor === nothing ? UInt64(0) : cursor.generation,
        cursor === nothing ? UInt64(0) : cursor.sequence,report === nothing ? UInt64(0) : report.generation,
        report === nothing ? UInt64(0) : report.sequence,reply)
end
function prepare_source!(runtime,job,source::ColdSource)
    wait_prepared!(runtime,job,source.owner)
    reply = request_owner!(runtime,job,source.owner,AcquisitionLifecycleCodec.LifecycleCommand(:status))
    reply.lifecycle == AcquisitionLifecycleCodec.Prepared || throw(ArgumentError("acquisition owner changed Prepared readiness"))
    source_snapshot!(source,reply)
    return connect_source!(runtime,job,source)
end
function connect_source!(runtime,job,source::ColdSource)
    reply = request_owner!(runtime,job,source.owner,AcquisitionLifecycleCodec.LifecycleCommand(:connect))
    reply.lifecycle == AcquisitionLifecycleCodec.Connected || throw(ArgumentError("acquisition Connect did not complete Connected"))
    return source_snapshot!(source,reply)
end
function source_operation!(runtime,job,source::ColdSource,kind::Symbol;running=false)
    kind in (:run,:query,:reset) || throw(ArgumentError("invalid acquisition operation"))
    operation = kind === :query ? :status : kind === :reset ? :reset : running ? :resume : :pause
    reply = request_owner!(runtime,job,source.owner,AcquisitionLifecycleCodec.LifecycleCommand(operation))
    kind === :query || reply.lifecycle == AcquisitionLifecycleCodec.Connected || throw(ArgumentError("acquisition effect did not complete Connected"))
    snapshot = source_snapshot!(source,reply)
    validate_source_operation(snapshot,kind,running)
    return snapshot
end
function validate_source_operation(snapshot::SourceSnapshot,kind,running)
    kind === :run && (snapshot.running != running || (running && snapshot.completed)) && throw(ArgumentError("acquisition run state was not acknowledged"))
    kind === :reset && (snapshot.running || snapshot.completed || snapshot.sequence != 0) && throw(ArgumentError("acquisition reset cursor was not acknowledged"))
    return nothing
end
function shutdown_source!(runtime,job,source::ColdSource)
    reply = request_owner!(runtime,job,source.owner,AcquisitionLifecycleCodec.LifecycleCommand(:shutdown))
    snapshot = source_snapshot!(source,reply); details = reply.snapshot
    reply.lifecycle == AcquisitionLifecycleCodec.Stopped && isempty(reply.message) && !snapshot.running && !details.held &&
        (details.phase == "initial" || details.restored) || throw(ArgumentError("acquisition Shutdown has no stopped restoration proof"))
    source.owner.retired = true
    return snapshot
end
shutdown_source!(runtime,job,source::LegacySource) = nothing

struct NativeStatus
    token::Int64
    result::Int32
    state::String
end
struct NodeRecords
    run::Union{Nothing,NativeStatus}
    reset::Union{Nothing,NativeStatus}
    snapshot::Union{Nothing,SourceSnapshot{LegacyDetails}}
    rejection::Union{Nothing,SourceSnapshot{LegacyDetails}}
    maximum::Int64
end
function exact_named(values,names)
    length(values) == length(names) && all(name -> haskey(values,name),names) ||
        throw(ArgumentError("incorrect native control fields"))
    return nothing
end
function native_status(values,namespace,run::Bool)
    names = [namespace*"."*field for field in (run ? ("version","completed-token","result","actual-state") : ("version","completed-token","result"))]
    exact_named(values,names)
    token = policy_long(values[namespace*".completed-token"])
    result = policy_int(values[namespace*".result"])
    policy_int(values[namespace*".version"]) == 1 && token >= 0 && result <= 0 || throw(ArgumentError("invalid native control status"))
    state = run ? policy_text(values[namespace*".actual-state"]) : ""
    !run || state in ("running","stopped","unknown") || throw(ArgumentError("invalid native running state"))
    return NativeStatus(token,result,state)
end
function legacy_snapshot(values,instance::Int64;rejection=false)
    names = rejection ? SourceControl.REJECTION_NAMES : SourceControl.SNAPSHOT_NAMES
    exact_named(values,names)
    f = [values[name] for name in names]
    policy_int(f[1]) == 1 && policy_long(f[2]) == instance && instance > 0 || throw(ArgumentError("source snapshot identity mismatch"))
    kind = policy_int(f[3]); token = policy_long(f[4]); result = policy_int(f[5])
    generation = policy_long(f[6]); sequence = policy_long(f[7])
    running = policy_bool(f[8]); completed = policy_bool(f[9])
    report_generation = policy_long(f[10]); report_sequence = policy_long(f[11])
    generation >= 1 && sequence >= 0 && report_generation >= 1 && report_sequence >= 0 &&
        (report_generation < generation || (report_generation == generation && report_sequence <= sequence)) &&
        !(running && completed) || throw(ArgumentError("invalid source snapshot cursor"))
    valid = kind == 0 ? token == 0 && result == 0 : rejection && kind == 4 ? token == 0 && result < 0 :
        kind in 1:3 && token > 0 && (rejection ? result < 0 : result <= 0)
    valid || throw(ArgumentError("invalid source snapshot result"))
    return SourceSnapshot(running,completed,UInt64(generation),UInt64(sequence),UInt64(report_generation),UInt64(report_sequence),LegacyDetails(kind,token,result))
end
function node_records(records,instance::Union{Nothing,Int64}=nothing)
    length(records) <= (instance === nothing ? 3 : 4) || throw(ArgumentError("node published too many Props records"))
    run = nothing; reset = nothing; snapshot = nothing; rejection = nothing; maximum = Int64(0)
    for pod in records
        values = named_values(pod)
        if haskey(values,"pipewireao.run-control.version")
            run === nothing || throw(ArgumentError("duplicate run-control record"))
            run = native_status(values,"pipewireao.run-control",true)
            instance === nothing || run.state != "unknown" || throw(ArgumentError("invalid source running state"))
            maximum = max(maximum,run.token)
        elseif haskey(values,"pipewireao.reset-control.version")
            reset === nothing || throw(ArgumentError("duplicate reset-control record"))
            reset = native_status(values,"pipewireao.reset-control",false)
            maximum = max(maximum,reset.token)
        elseif instance !== nothing && haskey(values,"pipewireao.source-snapshot.version")
            snapshot === nothing || throw(ArgumentError("duplicate source snapshot"))
            snapshot = legacy_snapshot(values,instance)
            maximum = max(maximum,snapshot.details.token)
        elseif instance !== nothing && haskey(values,"pipewireao.source-rejection.version")
            rejection === nothing || throw(ArgumentError("duplicate source rejection"))
            rejection = legacy_snapshot(values,instance;rejection=true)
            maximum = max(maximum,rejection.details.token)
        else
            instance === nothing || throw(ArgumentError("unrecognized source control Props"))
            for name in keys(values)
                correction_status_field(name) || (!occursin(r"^pipewireao\.[a-z-]+-control\.",name) && !startswith(name,"pipewireao.source-")) ||
                    throw(ArgumentError("unrecognized reserved node control field"))
            end
        end
    end
    instance === nothing || snapshot !== nothing || throw(ArgumentError("source snapshot unavailable"))
    return NodeRecords(run,reset,snapshot,rejection,maximum)
end
function check_legacy!(runtime,source::LegacySource)
    assert_identity!(runtime,source.handle)
    identity_integer(runtime,source.handle,"pipewireao.source-control.instance") == source.instance &&
        identity_integer(runtime,source.handle,"pipewireao.source-control.owner-pid") == source.pid ||
        throw(ArgumentError("source owner identity changed"))
    return nothing
end
function native_request(kind::Symbol,token::Int64,argument,instance)
    namespace = kind === :query ? "pipewireao.source-query" : "pipewireao.$kind-control"
    pairs = Pair{String,PolicyPod}[namespace*".version"=>PolicyPod(Int32(1)),namespace*".request-token"=>PolicyPod(token)]
    kind === :run && push!(pairs,namespace*".requested-state"=>PolicyPod(argument))
    kind === :query && push!(pairs,namespace*".instance"=>PolicyPod(instance))
    return PolicyPod(PipeWireAO.props_param(PolicySPA.Props(pairs)))
end
native_state(argument::Bool) = argument ? "running" : "stopped"
function native_state(argument)
    argument in (1,"stopped",:stopped) && return "stopped"
    argument in (2,"running",:running) && return "running"
    throw(ArgumentError("invalid requested running state"))
end
function matching_node_record(records::NodeRecords,kind::Symbol,token::Int64,state)
    record = kind === :run ? records.run : records.reset
    record === nothing && return nothing
    record.token > token && throw(ArgumentError("node advanced past requested completion"))
    record.token == token || return nothing
    record.result == 0 || throw(ArgumentError("node rejected control operation ($(record.result))"))
    kind === :run && record.state != state && throw(ArgumentError("node reported unexpected running state"))
    return record
end
function matching_source_record(records::NodeRecords,kind::Symbol,token::Int64,state,previous::SourceSnapshot)
    snapshot = records.snapshot
    expected = kind === :run ? SourceControl.RUN : kind === :reset ? SourceControl.RESET : SourceControl.QUERY
    snapshot.details.token > token && throw(ArgumentError("source advanced past requested completion"))
    if snapshot.details.token != token
        rejected = records.rejection
        rejected !== nothing && rejected.details.kind == expected && rejected.details.token == token &&
            throw(ArgumentError("source rejected control operation ($(rejected.details.result))"))
        return nothing
    end
    snapshot.details.kind == expected || throw(ArgumentError("source completion kind mismatch"))
    if kind !== :query
        ack = kind === :run ? records.run : records.reset
        (ack === nothing || ack.token != token) && return nothing
        ack.result == snapshot.details.result && (kind !== :run || (ack.state == "running") == snapshot.running) ||
            throw(ArgumentError("native ACK and source snapshot disagree"))
    end
    snapshot.generation > previous.generation || (snapshot.generation == previous.generation && snapshot.sequence >= previous.sequence) ||
        throw(ArgumentError("source cursor moved backwards"))
    snapshot.details.result == 0 || throw(ArgumentError("source rejected control operation ($(snapshot.details.result))"))
    if kind === :reset
        previous.generation < typemax(Int64) && snapshot.generation == previous.generation+1 && snapshot.sequence == 0 &&
            !snapshot.running && !snapshot.completed || throw(ArgumentError("source reset did not commit a new paused generation"))
    end
    if kind === :reset || snapshot.completed
        snapshot.generation == snapshot.report_generation && snapshot.sequence == snapshot.report_sequence ||
            throw(ArgumentError("source completed before report publication"))
    end
    kind === :run && snapshot.running != (state == "running") && throw(ArgumentError("source run state was not acknowledged"))
    return snapshot
end
function node_operation!(runtime,job,handle::UInt64,kind::Symbol,argument=nothing)
    kind in (:run,:reset) || throw(ArgumentError("unknown node control"))
    capture!(runtime,handle)
    state = kind === :run ? native_state(argument) : ""
    raw_instance = property(runtime,handle,"pipewireao.source-control.instance")
    instance = raw_instance === nothing ? nothing : identity_integer(runtime,handle,"pipewireao.source-control.instance")
    # Legacy source operations additionally require the snapshot/native ACK join.
    if instance !== nothing
        pid = identity_integer(runtime,handle,"pipewireao.source-control.owner-pid")
        0 < pid < typemax(UInt32) || throw(ArgumentError("invalid source owner PID"))
        return legacy_operation!(runtime,job,LegacySource(handle,UInt32(pid),instance,nothing),kind,state)
    end
    records = node_records(enumerate!(runtime,job,handle,"Props"))
    token = next_control_token!(runtime,records.maximum)
    deadline = min(job.ticket.deadline,now(runtime)+60.0)
    setparam!(runtime,job,handle,"Props",native_request(kind,token,state,nothing))
    return await_condition!(runtime,job) do
        now(runtime) < deadline || throw(ControlClient.UnknownOutcome("node operation expired"))
        assert_identity!(runtime,handle)
        matching_node_record(node_records(enumerate!(runtime,job,handle,"Props")),kind,token,state)
    end
end
function legacy_operation!(runtime,job,source::LegacySource,kind::Symbol,state="")
    check_legacy!(runtime,source)
    records = node_records(enumerate!(runtime,job,source.handle,"Props"),source.instance)
    previous = records.snapshot
    token = next_control_token!(runtime,records.maximum)
    deadline = min(job.ticket.deadline,now(runtime)+60.0)
    check_legacy!(runtime,source)
    setparam!(runtime,job,source.handle,"Props",native_request(kind,token,state,source.instance))
    snapshot = await_condition!(runtime,job) do
        now(runtime) < deadline || throw(ControlClient.UnknownOutcome("source operation expired"))
        check_legacy!(runtime,source)
        matching_source_record(node_records(enumerate!(runtime,job,source.handle,"Props"),source.instance),kind,token,state,previous)
    end
    source.previous = snapshot
    return snapshot
end
function source_operation!(runtime,job,source::LegacySource,kind::Symbol;running=false)
    kind in (:run,:query,:reset) || throw(ArgumentError("invalid acquisition operation"))
    if kind !== :query
        legacy_operation!(runtime,job,source,kind,running ? "running" : "stopped")
    end
    snapshot = legacy_operation!(runtime,job,source,:query)
    validate_source_operation(snapshot,kind,running)
    return snapshot
end
prepare_source!(runtime,job,source::LegacySource) = source_operation!(runtime,job,source,:query)
connect_source!(runtime,job,source::LegacySource) = source_operation!(runtime,job,source,:query)
