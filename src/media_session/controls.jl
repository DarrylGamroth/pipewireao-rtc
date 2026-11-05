# Cold policy adapters. These methods run only on the serialized Julia owner task.
const PolicySPA = PipeWireAO.SPA
const PolicyPod = PipeWireAO.Pod
# The public owner protocol bounds one cold request to sixty seconds.
const CONTROL_REQUEST_TIMEOUT_NS = Int64(60_000_000_000)
function control_deadline(runtime, job)
    current = now(runtime)::Int64
    deadline = job.ticket.deadline::Int64
    return min(deadline, Base.Checked.checked_add(current, CONTROL_REQUEST_TIMEOUT_NS))
end
policy_struct(values::PolicyPod...) = PolicySPA.Struct(PolicyPod[values...])
policy_scalar(pod, tag, ::Type{T}) where {T} = begin
    PipeWireAO.pod_type(pod) == tag && sizeof(pod) == 8 + (T === Bool ? 4 : sizeof(T)) ||
        throw(ArgumentError("wrong native scalar type or width"))
    PipeWireAO.pod_value(T, pod)
end
policy_long(pod) = policy_scalar(pod, PolicySPA.POD_LONG, Int64)
policy_int(pod) = policy_scalar(pod, PolicySPA.POD_INT, Int32)
policy_id(pod) = policy_scalar(pod, PolicySPA.POD_ID, PolicySPA.Id).value
policy_bool(pod) = policy_scalar(pod, PolicySPA.POD_BOOL, Bool)
function policy_text(pod; limit = 8192, empty = true)
    PipeWireAO.pod_type(pod) == PolicySPA.POD_STRING ||
        throw(ArgumentError("expected native String"))
    value = PipeWireAO.pod_value(String, pod)
    isvalid(value) &&
    ncodeunits(value) <= limit &&
    !occursin('\0', value) &&
    (empty || !isempty(value)) || throw(ArgumentError("invalid native String"))
    return value
end
function policy_fields(pod, count)
    fields = PipeWireAO.pod_value(PolicySPA.Struct, pod).values
    length(fields) == count || throw(ArgumentError("wrong native Struct arity"))
    return fields
end
function named_values(pod)
    result = Dict{String,PolicyPod}()
    for (name, value) in PolicySPA.Props(pod).values
        haskey(result, name) && throw(ArgumentError("duplicate named property"))
        result[name] = value
    end
    return result
end
function named_properties!(runtime, job, handle)
    records = enumerate!(runtime, job, handle, "Props")
    length(records) <= 32 || throw(ArgumentError("owner Props reply exceeds bound"))
    result = Dict{String,PolicyPod}()
    for record in records, (name, value) in named_values(record)
        haskey(result, name) && throw(ArgumentError("duplicate owner property"))
        result[name] = value
    end
    return result
end
function next_control_token!(runtime, minimum::Int64 = Int64(0))
    token = max(runtime.token, minimum)
    token < typemax(Int64) || throw(ArgumentError("owner control token space exhausted"))
    runtime.token = token + 1
    return runtime.token
end
function identity_integer(runtime, handle, key)
    value = property(runtime, handle, key)
    value !== nothing && occursin(r"^[0-9]+$", value) ||
        throw(ArgumentError("missing native identity property: $key"))
    parsed = tryparse(Int64, value)
    parsed !== nothing && parsed > 0 ||
        throw(ArgumentError("invalid native identity property: $key"))
    return parsed
end

"""One captured native owner, controlled by the serialized session task.

`check_owner!` validates the retained incarnation. `request_owner!` submits one
typed profile command and returns its matching reply. Connection and shutdown
methods exist only where the owner's public protocol defines those operations.
`connected_observed` retains acquisition capability evidence to forbid accepting
a later cold lifecycle as initial Hold; it does not drive the owner's lifecycle.
"""
abstract type AbstractOwner end
mutable struct Owner{P<:ControlClient.AbstractProfile,O<:ControlClient.Observation} <:
               AbstractOwner
    profile::P
    observation::O
    handle::UInt64
    pid::UInt32
    instance::Int64
    retired::Bool
    connected_observed::Bool
end
Owner(
    profile::P, observation::O, handle::UInt64, pid::UInt32, instance::Int64, retired::Bool
) where {P,O} = Owner{P,O}(profile, observation, handle, pid, instance, retired, false)
function check_owner!(runtime, owner::Owner)
    owner.retired && throw(ArgumentError("owner is retired"))
    assert_identity!(runtime, owner.handle)
    property(runtime, owner.handle, "pipewireao.rtc-control.protocol") ==
    ControlClient.PROTOCOL &&
    property(runtime, owner.handle, "pipewireao.rtc-control.profile") ==
    ControlClient.profile_name(owner.profile) &&
    identity_integer(runtime, owner.handle, "pipewireao.rtc-control.instance") ==
    owner.instance &&
    identity_integer(runtime, owner.handle, "pipewireao.rtc-control.owner-pid") == owner.pid ||
        throw(ArgumentError("owner control identity changed"))
    return nothing
end
function capture_owner(
    runtime,
    handle::UInt64,
    profile::ControlClient.AbstractProfile,
    instance::Integer,
    pid::Integer,
)
    0 < instance <= typemax(Int64) && 0 < pid < typemax(UInt32) ||
        throw(ArgumentError("invalid owner incarnation"))
    capture!(runtime, handle)
    owner = Owner(
        profile,
        ControlClient.Observation(profile, Int64(instance), UInt32(pid)),
        handle,
        UInt32(pid),
        Int64(instance),
        false,
    )
    check_owner!(runtime, owner)
    return owner
end
owner_profile(::Val{Symbol("pipewireao.rtc.owner-bootstrap")}) = OwnerBootstrapCodec.PROFILE
owner_profile(::Val{Symbol("pipewireao.rtc.calibration-lifecycle")}) =
    AcquisitionLifecycleCodec.CALIBRATION_PROFILE
owner_profile(::Val{Symbol("pipewireao.rtc.correction-lifecycle")}) =
    AcquisitionLifecycleCodec.CORRECTION_PROFILE
owner_profile(::Val{Symbol("pipewireao.rtc.parameter-source")}) = ParameterSource.PROFILE
owner_profile(::Val{N}) where {N} =
    throw(ArgumentError("unsupported owner control profile: $N"))
capture_owner(
    runtime, handle::UInt64, namespace::AbstractString, instance::Integer, pid::Integer
) = capture_owner(runtime, handle, owner_profile(Val(Symbol(namespace))), instance, pid)
function observe_owner!(runtime, job, owner::Owner)
    check_owner!(runtime, owner)
    records = enumerate!(runtime, job, owner.handle, "Props")
    length(records) <= 3 || throw(ArgumentError("owner published too many Props records"))
    kinds = Set{String}()
    for pod in records
        values = named_values(pod)
        names = ControlClient.capability_names(owner.profile)
        kind = if haskey(values, names[1])
            "capability"
        elseif haskey(values, "pipewireao.rtc.control.completion.header")
            "completion"
        elseif haskey(values, "pipewireao.rtc.control.rejection.header")
            "rejection"
        else
            throw(ArgumentError("unrecognized owner Props record"))
        end
        kind in kinds && throw(ArgumentError("duplicate owner Props record"))
        push!(kinds, kind)
        # ControlClient's existing observation API declares seconds.
        ControlClient.observe!(owner.observation, pod; at = now(runtime) / 1.0e9)
        owner.connected_observed |= _connected_observed(
            owner.profile, owner.observation.capability
        )
    end
    "capability" in kinds || throw(ArgumentError("owner capability is unavailable"))
    check_owner!(runtime, owner)
    owner.observation.fatal_failure === nothing ||
        throw(ArgumentError(owner.observation.fatal_failure))
    return owner.observation.capability
end
# Initial Hold consumes this monotone native observation. Other owner profiles
# retain their own lifecycle meanings and do not participate in acquisition Hold.
_connected_observed(::ControlClient.AbstractProfile, capability) = false
_connected_observed(
    ::Union{
        AcquisitionLifecycleCodec.CalibrationLifecycleProfile,
        AcquisitionLifecycleCodec.CorrectionLifecycleProfile,
    },
    capability::ControlClient.Capability,
) = capability.lifecycle === AcquisitionLifecycleCodec.Connected
preparation_states(::OwnerBootstrapCodec.Profile) =
    (OwnerBootstrapCodec.Preparing, OwnerBootstrapCodec.Prepared)
preparation_states(::AcquisitionLifecycleCodec.CalibrationLifecycleProfile) =
    (AcquisitionLifecycleCodec.Preparing, AcquisitionLifecycleCodec.Prepared)
preparation_states(::AcquisitionLifecycleCodec.CorrectionLifecycleProfile) =
    (AcquisitionLifecycleCodec.Preparing, AcquisitionLifecycleCodec.Prepared)
preparation_states(::ParameterSource.Profile) =
    (ParameterSource.Preparing, ParameterSource.Prepared)
function wait_prepared!(runtime, job, owner::Owner)
    owner.observation.pending === nothing ||
        throw(ArgumentError("owner operation already pending"))
    return await_condition!(runtime, job) do
        capability = observe_owner!(runtime, job, owner)
        preparing, prepared = preparation_states(owner.profile)
        state = capability.lifecycle
        state in (preparing, prepared) ||
            throw(ArgumentError("owner preparation reached unexpected lifecycle"))
        state == prepared && runtime.controller in capability.controllers ?
        capability.lifecycle : nothing
    end
end
send_owner_request!(runtime, job, owner, command, pod::PolicyPod) =
    setparam!(runtime, job, owner.handle, "Props", pod)
function send_owner_request!(
    runtime,
    job,
    owner,
    command::Union{
        OwnerBootstrapCodec.Command{:status},
        AcquisitionLifecycleCodec.LifecycleCommand{:status},
        RunnerCodec.RunnerCommand{:status},
    },
    pod::PolicyPod,
)
    return queryparam!(runtime, job, owner.handle, "Props", pod)
end
function request_owner!(runtime, job, owner::Owner, command)
    observation = owner.observation
    observation.pending === nothing ||
        throw(ArgumentError("owner operation already pending"))
    deadline = control_deadline(runtime, job)
    submitted = false
    try
        return await_condition!(runtime, job) do
            now(runtime) < deadline || throw(
                ControlClient.UnknownOutcome(
                    submitted ? "owner completion timed out" :
                    "owner registration timed out",
                ),
            )
            capability = observe_owner!(runtime, job, owner)
            now(runtime) < deadline ||
                throw(ControlClient.UnknownOutcome("owner control deadline expired"))
            if submitted
                # Keep nanoseconds in policy; convert at the seconds-based client API.
                reply = ControlClient.matching_reply(observation, deadline / 1.0e9)
                reply === nothing && return nothing
                reply.header.result == 0 || throw(
                    ArgumentError("owner rejected operation ($(reply.header.result))")
                )
                return reply
            end
            runtime.controller in capability.controllers || return nothing
            token = next_control_token!(runtime, observation.max_accepted)
            budget = Base.Checked.checked_sub(deadline, now(runtime))
            budget > 0 || throw(
                ControlClient.UnknownOutcome("owner request expired before submission")
            )
            header = ControlCodec.RequestHeader(
                runtime.controller,
                owner.instance,
                token,
                ControlClient.operation_id(owner.profile, command),
                budget,
            )
            request = ControlClient.encode_request(owner.profile, header, command)
            observation.pending = header
            observation.matched_completion = nothing
            observation.matched_rejection = nothing
            submitted = true
            send_owner_request!(runtime, job, owner, command, request)
            return nothing
        end
    finally
        observation.pending = nothing
        observation.matched_completion = nothing
        observation.matched_rejection = nothing
    end
end
connect_command(::OwnerBootstrapCodec.Profile) = OwnerBootstrapCodec.Command(:connect)
shutdown_command(::OwnerBootstrapCodec.Profile) = OwnerBootstrapCodec.Command(:quit)
function connect_owner!(runtime, job, owner::Owner)
    wait_prepared!(runtime, job, owner)
    reply = request_owner!(runtime, job, owner, connect_command(owner.profile))
    validate_connected(reply)
    return reply
end
validate_connected(reply::OwnerBootstrapCodec.Completion) = (
    reply.lifecycle == OwnerBootstrapCodec.Connected ||
        throw(ArgumentError("bootstrap owner did not connect"));
    nothing
)
function shutdown_owner!(runtime, job, owner::Owner)
    reply = request_owner!(runtime, job, owner, shutdown_command(owner.profile))
    validate_stopped(reply)
    owner.retired = true
    return reply
end
validate_stopped(reply::OwnerBootstrapCodec.Completion) = (
    reply.lifecycle == OwnerBootstrapCodec.Stopped ||
        throw(ArgumentError("bootstrap owner did not stop"));
    nothing
)
"A normalized finite-source cursor; owner protocol details retain their declared type."
struct SourceSnapshot{D}
    running::Bool
    completed::Bool
    generation::UInt64
    sequence::UInt64
    report_generation::UInt64
    report_sequence::UInt64
    details::D
end
"""A captured source whose protocol owns its acquisition cursor.

Implement `prepare_source!`, `connect_source!`, `source_operation!` and
`shutdown_source!` on the serialized session task. Operations return a
`SourceSnapshot` after their protocol's fresh acknowledgement and cursor proof.
An unconnected acquisition Hold returns `InitialSourceHold` without a cursor;
shutdown may return `nothing` when another declared owner owns that resource.
"""
abstract type AbstractSource end
mutable struct AcquisitionBinding{O<:Owner} <: AbstractSource
    owner::O
    instrument::Union{Nothing,AcquisitionLifecycleCodec.Instrument}
    previous::Union{Nothing,AcquisitionLifecycleCodec.AcquisitionCursor}
end
"""A fresh initial Status proves that acquisition has not been connected.

The original completion is retained, including its absent cursor and its actual
held/restored flags. This evidence establishes quiescent initial ingress only;
it is neither a Pause acknowledgement nor Stopped/restoration evidence.
"""
struct InitialSourceHold
    completion::AcquisitionLifecycleCodec.Completion
    function InitialSourceHold(
        profile::ControlClient.AbstractProfile,
        completion::AcquisitionLifecycleCodec.Completion,
    )
        header = completion.header
        header.controller !== nothing &&
        header.token > 0 &&
        header.result == 0 &&
        header.operation == ControlClient.operation_id(
            profile, AcquisitionLifecycleCodec.LifecycleCommand(:status)
        ) || throw(
            ArgumentError(
                "initial acquisition Hold requires a correlated successful Status"
            ),
        )
        completion.lifecycle in
        (AcquisitionLifecycleCodec.Preparing, AcquisitionLifecycleCodec.Prepared) || throw(
            ArgumentError("initial acquisition Hold requires an unconnected lifecycle")
        )
        snapshot = completion.snapshot
        snapshot !== nothing &&
        snapshot.phase == "initial" &&
        !snapshot.running &&
        !snapshot.completed &&
        snapshot.cursor === nothing &&
        snapshot.report_cursor === nothing &&
        snapshot.window === nothing &&
        !snapshot.held &&
        !snapshot.restored &&
        isempty(completion.message) || throw(
            ArgumentError("acquisition Status has no untouched initial ingress proof")
        )
        return new(completion)
    end
end
struct SourceControlDetails
    kind::Int32
    token::Int64
    result::Int32
end
mutable struct SourceControlBinding <: AbstractSource
    handle::UInt64
    pid::UInt32
    instance::Int64
    previous::Union{Nothing,SourceSnapshot{SourceControlDetails}}
end
function source(runtime, handle::UInt64, declaration)
    pid = Int64(declaration["pid"])
    0 < pid < typemax(UInt32) || throw(ArgumentError("invalid acquisition owner PID"))
    name = get(declaration, "control-node", nothing)
    name === nothing ||
        property(runtime, handle, "node.name") == name ||
        throw(ArgumentError("acquisition node name mismatch"))
    profile = declaration["control-protocol"]
    if profile == "pipewireao.source-control/1"
        capture!(runtime, handle)
        instance = identity_integer(runtime, handle, "pipewireao.source-control.instance")
        identity_integer(runtime, handle, "pipewireao.source-control.owner-pid") == pid ||
            throw(ArgumentError("source PID mismatch"))
        return SourceControlBinding(handle, UInt32(pid), instance, nothing)
    end
    profile in
    ("pipewireao.rtc.calibration-lifecycle/1", "pipewireao.rtc.correction-lifecycle/1") ||
        throw(ArgumentError("unsupported acquisition profile"))
    owner = capture_owner(
        runtime,
        handle,
        chopsuffix(profile, "/1"),
        parse(Int64, string(declaration["control-instance"])),
        pid,
    )
    instrument = get(declaration, "instrument", nothing)
    normalized = if instrument === nothing
        nothing
    elseif instrument in ("classic", "Classic", 1)
        AcquisitionLifecycleCodec.Classic
    elseif instrument in ("copper", "Copper", 2)
        AcquisitionLifecycleCodec.Copper
    else
        throw(ArgumentError("invalid acquisition instrument"))
    end
    return AcquisitionBinding(owner, normalized, nothing)
end
function source_snapshot!(
    source::AcquisitionBinding, reply::AcquisitionLifecycleCodec.Completion
)
    snapshot = reply.snapshot
    snapshot === nothing && throw(ArgumentError("acquisition snapshot unavailable"))
    source.instrument === nothing ||
        source.instrument == snapshot.instrument ||
        throw(ArgumentError("acquisition instrument changed"))
    source.instrument = snapshot.instrument
    cursor = snapshot.cursor
    report = snapshot.report_cursor
    # An absent current cursor is unknown, not permission to erase a previously
    # acknowledged connected cursor and later accept a cold lifecycle rollback.
    cursor === nothing || (source.previous = cursor)
    return SourceSnapshot(
        snapshot.running,
        snapshot.completed,
        cursor === nothing ? UInt64(0) : cursor.generation,
        cursor === nothing ? UInt64(0) : cursor.sequence,
        report === nothing ? UInt64(0) : report.generation,
        report === nothing ? UInt64(0) : report.sequence,
        reply,
    )
end
function prepare_source!(runtime, job, source::AcquisitionBinding)
    wait_prepared!(runtime, job, source.owner)
    reply = request_owner!(
        runtime, job, source.owner, AcquisitionLifecycleCodec.LifecycleCommand(:status)
    )
    reply.lifecycle == AcquisitionLifecycleCodec.Prepared ||
        throw(ArgumentError("acquisition owner changed Prepared readiness"))
    source_snapshot!(source, reply)
    return connect_source!(runtime, job, source)
end
function connect_source!(runtime, job, source::AcquisitionBinding)
    reply = request_owner!(
        runtime, job, source.owner, AcquisitionLifecycleCodec.LifecycleCommand(:connect)
    )
    reply.lifecycle == AcquisitionLifecycleCodec.Connected ||
        throw(ArgumentError("acquisition Connect did not complete Connected"))
    return source_snapshot!(source, reply)
end
function source_operation!(
    runtime, job, source::AcquisitionBinding, kind::Symbol; running = false
)
    kind in (:run, :query, :reset) || throw(ArgumentError("invalid acquisition operation"))
    kind === :run && !running && return _hold_acquisition!(runtime, job, source)
    operation = if kind === :query
        :status
    elseif kind === :reset
        :reset
    elseif running
        :resume
    else
        :pause
    end
    reply = request_owner!(
        runtime, job, source.owner, AcquisitionLifecycleCodec.LifecycleCommand(operation)
    )
    return _acquisition_result!(source, reply, kind, running)
end
function _acquisition_result!(
    source::AcquisitionBinding,
    reply::AcquisitionLifecycleCodec.Completion,
    kind::Symbol,
    running::Bool,
)
    kind === :query ||
        reply.lifecycle == AcquisitionLifecycleCodec.Connected ||
        throw(ArgumentError("acquisition effect did not complete Connected"))
    snapshot = source_snapshot!(source, reply)
    validate_source_operation(snapshot, kind, running)
    return snapshot
end
function _hold_acquisition!(runtime, job, source::AcquisitionBinding)
    status = request_owner!(
        runtime, job, source.owner, AcquisitionLifecycleCodec.LifecycleCommand(:status)
    )
    return _hold_acquisition!(runtime, job, source, Val(status.lifecycle), status)
end
function _hold_acquisition!(
    runtime,
    job,
    source::AcquisitionBinding,
    ::Val{AcquisitionLifecycleCodec.Connected},
    status,
)
    source_snapshot!(source, status)
    reply = request_owner!(
        runtime, job, source.owner, AcquisitionLifecycleCodec.LifecycleCommand(:pause)
    )
    return _acquisition_result!(source, reply, :run, false)
end
_hold_acquisition!(
    runtime,
    job,
    source::AcquisitionBinding,
    ::Val{AcquisitionLifecycleCodec.Preparing},
    status,
) = _initial_source_hold(source, status)
_hold_acquisition!(
    runtime,
    job,
    source::AcquisitionBinding,
    ::Val{AcquisitionLifecycleCodec.Prepared},
    status,
) = _initial_source_hold(source, status)
_hold_acquisition!(runtime, job, source::AcquisitionBinding, ::Val, status) =
    throw(ArgumentError("acquisition lifecycle cannot establish Hold"))
function _initial_source_hold(
    source::AcquisitionBinding, status::AcquisitionLifecycleCodec.Completion
)
    !source.owner.connected_observed && source.previous === nothing ||
        throw(ArgumentError("connected acquisition regressed to a cold lifecycle"))
    proof = InitialSourceHold(source.owner.profile, status)
    snapshot = something(status.snapshot)
    source.instrument === nothing ||
        source.instrument == snapshot.instrument ||
        throw(ArgumentError("acquisition instrument changed"))
    source.instrument = snapshot.instrument
    return proof
end
function validate_source_operation(snapshot::SourceSnapshot, kind, running)
    kind === :run &&
        (snapshot.running != running || (running && snapshot.completed)) &&
        throw(ArgumentError("acquisition run state was not acknowledged"))
    kind === :reset &&
        (snapshot.running || snapshot.completed || snapshot.sequence != 0) &&
        throw(ArgumentError("acquisition reset cursor was not acknowledged"))
    return nothing
end
function shutdown_source!(runtime, job, source::AcquisitionBinding)
    reply = request_owner!(
        runtime, job, source.owner, AcquisitionLifecycleCodec.LifecycleCommand(:shutdown)
    )
    snapshot = source_snapshot!(source, reply)
    details = reply.snapshot
    reply.lifecycle == AcquisitionLifecycleCodec.Stopped &&
    isempty(reply.message) &&
    !snapshot.running &&
    !details.held &&
    (details.phase == "initial" || details.restored) ||
        throw(ArgumentError("acquisition Shutdown has no stopped restoration proof"))
    source.owner.retired = true
    return snapshot
end
shutdown_source!(runtime, job, source::SourceControlBinding) = nothing

struct ControlStatus
    token::Int64
    result::Int32
    state::String
end
struct ControlRecords
    run::Union{Nothing,ControlStatus}
    reset::Union{Nothing,ControlStatus}
    snapshot::Union{Nothing,SourceSnapshot{SourceControlDetails}}
    rejection::Union{Nothing,SourceSnapshot{SourceControlDetails}}
    maximum::Int64
end
function exact_named(values, names)
    length(values) == length(names) && all(name -> haskey(values, name), names) ||
        throw(ArgumentError("incorrect native control fields"))
    return nothing
end
function control_status(pod::PolicyPod, ::Val{:run})
    destination = Ref{PipeWireAO.RunControlStatus}()
    PipeWireAO.parse_run_control_status!(destination, pod) == 0 ||
        throw(ArgumentError("invalid run-control status"))
    status = destination[]
    status.result <= 0 || throw(ArgumentError("invalid run-control result"))
    state =
        status.actual_state == PipeWireAO.LibPipeWire.PW_AO_RUN_CONTROL_STATE_UNKNOWN ?
        "unknown" : control_state(status.actual_state)
    return ControlStatus(status.completed_token, status.result, state)
end
function control_status(pod::PolicyPod, ::Val{:reset})
    destination = Ref{PipeWireAO.ResetControlStatus}()
    PipeWireAO.parse_reset_control_status!(destination, pod) == 0 ||
        throw(ArgumentError("invalid reset-control status"))
    status = destination[]
    status.result <= 0 || throw(ArgumentError("invalid reset-control result"))
    return ControlStatus(status.completed_token, status.result, "")
end
function source_control_snapshot(values, instance::Int64; rejection = false)
    names = rejection ? SourceControl.REJECTION_NAMES : SourceControl.SNAPSHOT_NAMES
    exact_named(values, names)
    f = [values[name] for name in names]
    policy_int(f[1]) == SourceControl.VERSION &&
    policy_long(f[2]) == instance &&
    instance > 0 || throw(ArgumentError("source snapshot identity mismatch"))
    kind = policy_int(f[3])
    token = policy_long(f[4])
    result = policy_int(f[5])
    generation = policy_long(f[6])
    sequence = policy_long(f[7])
    running = policy_bool(f[8])
    completed = policy_bool(f[9])
    report_generation = policy_long(f[10])
    report_sequence = policy_long(f[11])
    generation >= 1 &&
    sequence >= 0 &&
    report_generation >= 1 &&
    report_sequence >= 0 &&
    (
        report_generation < generation ||
        (report_generation == generation && report_sequence <= sequence)
    ) &&
    !(running && completed) || throw(ArgumentError("invalid source snapshot cursor"))
    valid = if kind == SourceControl.INITIAL
        token == 0 && result == 0
    elseif rejection && kind == SourceControl.INVALID
        token == 0 && result < 0
    else
        kind in (SourceControl.RUN, SourceControl.RESET, SourceControl.QUERY) &&
            token > 0 &&
            (rejection ? result < 0 : result <= 0)
    end
    valid || throw(ArgumentError("invalid source snapshot result"))
    return SourceSnapshot(
        running,
        completed,
        UInt64(generation),
        UInt64(sequence),
        UInt64(report_generation),
        UInt64(report_sequence),
        SourceControlDetails(kind, token, result),
    )
end
function control_records(records, instance::Union{Nothing,Int64} = nothing)
    length(records) <= (instance === nothing ? 3 : 4) ||
        throw(ArgumentError("node published too many Props records"))
    run = nothing
    reset = nothing
    snapshot = nothing
    rejection = nothing
    maximum = Int64(0)
    for pod in records
        values = named_values(pod)
        if haskey(values, "pipewireao.run-control.version")
            run === nothing || throw(ArgumentError("duplicate run-control record"))
            run = control_status(pod, Val(:run))
            instance === nothing ||
                run.state != "unknown" ||
                throw(ArgumentError("invalid source running state"))
            maximum = max(maximum, run.token)
        elseif haskey(values, "pipewireao.reset-control.version")
            reset === nothing || throw(ArgumentError("duplicate reset-control record"))
            reset = control_status(pod, Val(:reset))
            maximum = max(maximum, reset.token)
        elseif instance !== nothing && haskey(values, "pipewireao.source-snapshot.version")
            snapshot === nothing || throw(ArgumentError("duplicate source snapshot"))
            snapshot = source_control_snapshot(values, instance)
            maximum = max(maximum, snapshot.details.token)
        elseif instance !== nothing && haskey(values, "pipewireao.source-rejection.version")
            rejection === nothing || throw(ArgumentError("duplicate source rejection"))
            rejection = source_control_snapshot(values, instance; rejection = true)
            maximum = max(maximum, rejection.details.token)
        else
            instance === nothing ||
                throw(ArgumentError("unrecognized source control Props"))
            for name in keys(values)
                correction_status_field(name) ||
                    (
                        !occursin(r"^pipewireao\.[a-z-]+-control\.", name) &&
                        !startswith(name, "pipewireao.source-")
                    ) ||
                    throw(ArgumentError("unrecognized reserved node control field"))
            end
        end
    end
    instance === nothing ||
        snapshot !== nothing ||
        throw(ArgumentError("source snapshot unavailable"))
    return ControlRecords(run, reset, snapshot, rejection, maximum)
end
control_records!(runtime, job, handle, instance::Union{Nothing,Int64} = nothing) =
    control_records(enumerate!(runtime, job, handle, "Props"), instance)
function check_source_control!(runtime, source::SourceControlBinding)
    assert_identity!(runtime, source.handle)
    identity_integer(runtime, source.handle, "pipewireao.source-control.instance") ==
    source.instance &&
    identity_integer(runtime, source.handle, "pipewireao.source-control.owner-pid") ==
    source.pid || throw(ArgumentError("source owner identity changed"))
    return nothing
end
control_request(kind::Symbol, token::Int64, argument, instance) =
    control_request(Val(kind), token, argument, instance)
control_request(::Val{:run}, token::Int64, argument, instance) =
    PipeWireAO.run_control_request(token, Symbol(argument))
control_request(::Val{:reset}, token::Int64, argument, instance) =
    PipeWireAO.reset_control_request(token)
function control_request(::Val{:query}, token::Int64, argument, instance::Int64)
    values = SourceControl.query_values(token, instance)
    return PolicyPod(
        PipeWireAO.props_param(
            PolicySPA.Props([
                SourceControl.QUERY_NAMES[i] => PolicyPod(values[i]) for
                i in eachindex(values)
            ]),
        ),
    )
end
control_state(argument::Bool) = argument ? "running" : "stopped"
function control_state(argument)
    argument in
    (PipeWireAO.LibPipeWire.PW_AO_RUN_CONTROL_STATE_STOPPED, "stopped", :stopped) &&
        return "stopped"
    argument in
    (PipeWireAO.LibPipeWire.PW_AO_RUN_CONTROL_STATE_RUNNING, "running", :running) &&
        return "running"
    throw(ArgumentError("invalid requested running state"))
end
function matching_control_record(records::ControlRecords, kind::Symbol, token::Int64, state)
    record = kind === :run ? records.run : records.reset
    record === nothing && return nothing
    record.token > token && throw(ArgumentError("node advanced past requested completion"))
    record.token == token || return nothing
    record.result == 0 ||
        throw(ArgumentError("node rejected control operation ($(record.result))"))
    kind === :run &&
        record.state != state &&
        throw(ArgumentError("node reported unexpected running state"))
    return record
end
function matching_source_control_record(
    records::ControlRecords, kind::Symbol, token::Int64, state, previous::SourceSnapshot
)
    snapshot = records.snapshot
    expected = if kind === :run
        SourceControl.RUN
    elseif kind === :reset
        SourceControl.RESET
    else
        SourceControl.QUERY
    end
    snapshot.details.token > token &&
        throw(ArgumentError("source advanced past requested completion"))
    if snapshot.details.token != token
        rejected = records.rejection
        rejected !== nothing &&
            rejected.details.kind == expected &&
            rejected.details.token == token &&
            throw(
                ArgumentError(
                    "source rejected control operation ($(rejected.details.result))"
                ),
            )
        return nothing
    end
    snapshot.details.kind == expected ||
        throw(ArgumentError("source completion kind mismatch"))
    if kind !== :query
        ack = kind === :run ? records.run : records.reset
        (ack === nothing || ack.token != token) && return nothing
        ack.result == snapshot.details.result &&
        (kind !== :run || (ack.state == "running") == snapshot.running) ||
            throw(ArgumentError("native ACK and source snapshot disagree"))
    end
    snapshot.generation > previous.generation ||
        (
            snapshot.generation == previous.generation &&
            snapshot.sequence >= previous.sequence
        ) ||
        throw(ArgumentError("source cursor moved backwards"))
    snapshot.details.result == 0 || throw(
        ArgumentError("source rejected control operation ($(snapshot.details.result))")
    )
    if kind === :reset
        previous.generation < typemax(Int64) &&
        snapshot.generation == previous.generation + 1 &&
        snapshot.sequence == 0 &&
        !snapshot.running &&
        !snapshot.completed ||
            throw(ArgumentError("source reset did not commit a new paused generation"))
    end
    if kind === :reset || snapshot.completed
        snapshot.generation == snapshot.report_generation &&
        snapshot.sequence == snapshot.report_sequence ||
            throw(ArgumentError("source completed before report publication"))
    end
    kind === :run &&
        snapshot.running != (state == "running") &&
        throw(ArgumentError("source run state was not acknowledged"))
    return snapshot
end
function node_operation!(runtime, job, handle::UInt64, kind::Symbol, argument = nothing)
    kind in (:run, :reset) || throw(ArgumentError("unknown node control"))
    capture!(runtime, handle)
    state = kind === :run ? control_state(argument) : ""
    raw_instance = property(runtime, handle, "pipewireao.source-control.instance")
    instance =
        raw_instance === nothing ? nothing :
        identity_integer(runtime, handle, "pipewireao.source-control.instance")
    # Source-control operations additionally require the snapshot/native ACK join.
    if instance !== nothing
        pid = identity_integer(runtime, handle, "pipewireao.source-control.owner-pid")
        0 < pid < typemax(UInt32) || throw(ArgumentError("invalid source owner PID"))
        return source_control_operation!(
            runtime,
            job,
            SourceControlBinding(handle, UInt32(pid), instance, nothing),
            kind,
            state,
        )
    end
    records = control_records!(runtime, job, handle)
    token = next_control_token!(runtime, records.maximum)
    deadline = control_deadline(runtime, job)
    setparam!(runtime, job, handle, "Props", control_request(kind, token, state, nothing))
    return await_condition!(runtime, job) do
        now(runtime) < deadline ||
            throw(ControlClient.UnknownOutcome("node operation expired"))
        assert_identity!(runtime, handle)
        records = control_records!(runtime, job, handle)
        now(runtime) < deadline ||
            throw(ControlClient.UnknownOutcome("node operation expired"))
        matching_control_record(records, kind, token, state)
    end
end
function source_control_operation!(
    runtime, job, source::SourceControlBinding, kind::Symbol, state = ""
)
    check_source_control!(runtime, source)
    records = control_records!(runtime, job, source.handle, source.instance)
    previous = records.snapshot
    token = next_control_token!(runtime, records.maximum)
    deadline = control_deadline(runtime, job)
    check_source_control!(runtime, source)
    send_source_control_request!(
        runtime,
        job,
        source,
        Val(kind),
        control_request(kind, token, state, source.instance),
    )
    snapshot = await_condition!(runtime, job) do
        now(runtime) < deadline ||
            throw(ControlClient.UnknownOutcome("source operation expired"))
        check_source_control!(runtime, source)
        records = control_records!(runtime, job, source.handle, source.instance)
        now(runtime) < deadline ||
            throw(ControlClient.UnknownOutcome("source operation expired"))
        matching_source_control_record(records, kind, token, state, previous)
    end
    source.previous = snapshot
    return snapshot
end
send_source_control_request!(
    runtime, job, source::SourceControlBinding, ::Val, pod::PolicyPod
) = setparam!(runtime, job, source.handle, "Props", pod)
send_source_control_request!(
    runtime, job, source::SourceControlBinding, ::Val{:query}, pod::PolicyPod
) = queryparam!(runtime, job, source.handle, "Props", pod)
function source_operation!(
    runtime, job, source::SourceControlBinding, kind::Symbol; running = false
)
    kind in (:run, :query, :reset) || throw(ArgumentError("invalid acquisition operation"))
    if kind !== :query
        source_control_operation!(
            runtime, job, source, kind, running ? "running" : "stopped"
        )
    end
    snapshot = source_control_operation!(runtime, job, source, :query)
    validate_source_operation(snapshot, kind, running)
    return snapshot
end
prepare_source!(runtime, job, source::SourceControlBinding) =
    source_operation!(runtime, job, source, :query)
connect_source!(runtime, job, source::SourceControlBinding) =
    source_operation!(runtime, job, source, :query)
