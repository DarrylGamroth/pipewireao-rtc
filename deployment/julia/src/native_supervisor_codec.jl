"""Closed public deployment supervisor profile; encoding performs no owner effects."""
module NativeSupervisorCodec

using PipeWireAO, UUIDs
import ..NativeControlCodec
import ..NativeControlClient
import ..NativeRunnerCodec
import ..NativeAcquisitionLifecycleCodec
import ..NativeHeartCodec

const Envelope = NativeControlCodec
const Client = NativeControlClient
const Runner = NativeRunnerCodec
const Acquisition = NativeAcquisitionLifecycleCodec
const Heart = NativeHeartCodec
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod
const MAX_PROCESSES = 32

export SupervisorProfile, PROFILE, Phase, Preparing, Admitted, Failed, Stopping,
    Stopped, Binding, OwnedProcess, RunnerObservation, SimulatorSnapshot,
    SourceObservation, HeartObservation, Snapshot, Completion, Rejection,
    RunnerRecord, validate_snapshot, validate_admission, completion_size,
    preflight_mutation_reply, encode_completion,
    decode_completion, encode_rejection, decode_rejection

struct SupervisorProfile <: Client.Profile end
const PROFILE = SupervisorProfile()
Client.profile_name(::SupervisorProfile) = "pipewireao.rtc.deployment-supervisor/1"
const UUID_PROPERTY = "pipewireao.rtc.deployment-supervisor.session-uuid"
function validate_uuid(value)
    value isa String && ncodeunits(value)==36 && isvalid(value) ||
        throw(ArgumentError("supervisor UUID must be canonical bounded text"))
    parsed = tryparse(UUID,value)
    parsed !== nothing && string(parsed)==value && parsed!=UUID(0) ||
        throw(ArgumentError("supervisor UUID must be a nonzero canonical UUID"))
    return value
end
function Client.node_identity(::SupervisorProfile,properties,previous)
    value=validate_uuid(get(properties,UUID_PROPERTY,nothing))
    previous===nothing || value==previous || throw(Client.UnknownOutcome("supervisor UUID changed"))
    return value
end
Client.capability_names(::SupervisorProfile) = Tuple("pipewireao.rtc.deployment-supervisor." * suffix
    for suffix in ("version", "instance", "owner-pid", "lifecycle", "last-token", "controllers"))
@enum Phase::UInt32 Preparing=1 Admitted=2 Failed=3 Stopping=4 Stopped=5
Client.lifecycle_type(::SupervisorProfile) = Phase
Client.operation_id(::SupervisorProfile, command::Runner.RunnerCommand) = Runner.operation_id(command)
Client.encode_request(::SupervisorProfile, header, command::Runner.RunnerCommand) = Runner.encode_request(header, command)
Client.decode_request(::SupervisorProfile, header, payload) = Runner.decode_request(header, payload)
Client.decode_request(::SupervisorProfile, pod) = Runner.decode_request(pod)

"Preparing and retired endpoints admit only fresh Status, without owner effects."
function validate_admission(phase::Phase, command::Runner.RunnerCommand)
    phase === Admitted || Runner.operation_id(command) == 3 ||
        throw(ArgumentError("supervisor has not coherently admitted this operation"))
    return command
end

struct Binding
    name::String
    profile::String
    pid::UInt32
    global_id::UInt32
    serial::UInt64
    instance::Int64
end
struct OwnedProcess
    role::String
    pid::UInt32
end
"A validated runner result, with the existing typed operation details."
struct RunnerRecord
    lifecycle::Runner.Lifecycle
    result::Runner.RunnerResult
end
struct RunnerObservation
    binding::Binding
    token::Int64
    session_id::String
    status::RunnerRecord
end
"The existing source SnapshotValues fields, including the actual query identity."
struct SimulatorSnapshot
    version::Int32
    instance::Int64
    kind::Int32
    token::Int64
    result::Int32
    generation::Int64
    sequence::Int64
    running::Bool
    completed::Bool
    report_generation::Int64
    report_sequence::Int64
end
struct SourceObservation
    binding::Binding
    token::Int64
    lifecycle::Union{Nothing,Acquisition.ColdLifecycle}
    snapshot::Union{SimulatorSnapshot,Acquisition.Snapshot}
end
struct HeartObservation
    binding::Binding
    token::Int64
    lifecycle::Heart.HeartLifecycle
    snapshot::Heart.HeartSnapshot
end
struct Snapshot
    processes::Vector{OwnedProcess}
    runner::Union{Nothing,RunnerObservation}
    source::Union{Nothing,SourceObservation}
    heart::Union{Nothing,HeartObservation}
end
struct Completion
    header::Envelope.ReplyHeader
    lifecycle::Phase
    admitted::Bool
    snapshot::Union{Nothing,Snapshot}
    result::Union{Nothing,RunnerRecord}
    error::Union{Nothing,Runner.RunnerError}
end
struct Rejection
    header::Envelope.ReplyHeader
    lifecycle::Phase
    admitted::Bool
    error::Runner.RunnerError
end
Client.completion_type(::SupervisorProfile) = Completion
Client.rejection_type(::SupervisorProfile) = Rejection
Client.decode_completion(::SupervisorProfile, pod) = decode_completion(pod)
Client.decode_rejection(::SupervisorProfile, pod) = decode_rejection(pod)

_struct(pods::Pod...) = SPA.Struct(Pod[pods...])
_id(value) = Pod(SPA.Id(UInt32(value)))
const _fields = Runner._fields
const _arity = Runner._arity
const _long = Runner._long
const _bool = Runner._bool
const _none = Runner._is_none
_int(pod) = Runner._scalar(pod, SPA.POD_INT, Int32)
function _text(value; empty=false, limit=128)
    return Runner._string_check(value; empty, limit)
end
function _string(pod; empty=false, limit=128)
    return _text(Runner._string(pod); empty, limit)
end
function _enum(::Type{T}, pod) where T
    try T(Runner._id(pod)) catch; throw(ArgumentError("unknown supervisor enum Id")) end
end
_optional(pod, decode) = _none(pod) ? nothing : decode(pod)
_optional_pod(value, encode) = value === nothing ? Pod(nothing) : Pod(encode(value))
function _phase(phase::Phase, admitted::Bool)
    admitted == (phase === Admitted) || throw(ArgumentError("supervisor phase/admitted mismatch"))
end
function _binding(binding::Binding; profile=nothing)
    _text(binding.name); _text(binding.profile)
    profile === nothing || binding.profile == profile || throw(ArgumentError("binding profile mismatch"))
    binding.pid > 0 && 0 < binding.global_id < typemax(UInt32) && binding.serial > 0 && binding.instance > 0 ||
        throw(ArgumentError("binding requires actual positive PID/serial/incarnation"))
    return binding
end
function _binding_pod(binding::Binding)
    _binding(binding)
    return _struct(Pod(binding.name), Pod(binding.profile), _id(binding.pid),
        _id(binding.global_id), Pod(reinterpret(Int64, binding.serial)), Pod(binding.instance))
end
function _decode_binding(pod)
    f = _arity(_fields(pod), 6)
    return _binding(Binding(_string(f[1]), _string(f[2]), Runner._id(f[3]),
        Runner._id(f[4]), reinterpret(UInt64, _long(f[5])), _long(f[6])))
end

# These are repository-local helper seams. No arbitrary JSON value is inferred.
function _record_pod(record::RunnerRecord, operation::UInt32)
    result = record.result
    result isa Runner.RunnerResult{Runner.OPERATIONS[Int(operation)]} ||
        throw(ArgumentError("runner result operation mismatch"))
    d = result.details
    ps = _struct
    fields = if operation == 1
        ps(Pod(d.shutdown))
    elseif operation == 2
        ps(Pod(SPA.Struct(Pod[Pod(ps(Pod(name), _id(d.groups[name]))) for name in sort!(collect(keys(d.groups)))])))
    elseif operation == 3
        sinks = SPA.Struct(Pod[Pod(ps(Pod(name), Pod(reinterpret(Int64, d.discarded_by_sink[name]))))
            for name in sort!(collect(keys(d.discarded_by_sink)))])
        ps(Pod(d.running), Pod(reinterpret(Int64, d.owned_nodes)), Pod(reinterpret(Int64, d.owned_links)),
            Pod(reinterpret(Int64, d.discarded_buffers)), Pod(sinks))
    elseif operation == 4
        rows = SPA.Struct(Pod[Pod(ps(Pod(name), Runner._scalar_pod(d.properties[name]; finite=false)))
            for name in sort!(collect(keys(d.properties)))])
        ps(Pod(d.graph), Pod(rows))
    elseif operation == 5 || operation == 6
        ps(Pod(d.graph), Pod(d.node), Pod(d.requested), Pod(d.active))
    elseif operation == 7 || operation == 8
        ps(Pod(d.group), _id(d.requested), d.observed === nothing ? Pod(nothing) : _id(d.observed))
    elseif operation in (9, 10, 11, 12)
        ps(_id(d.state))
    elseif operation == 13
        rows = SPA.Struct(Pod[Pod(ps(Pod(g.node), Pod(g.requested), Pod(g.active))) for g in d.generations])
        ps(Pod(d.graph), Pod(rows), Pod(d.active_adoption_observed))
    else
        ps(Pod(d.graph), Pod(d.parameter), d.generation === nothing ? Pod(nothing) :
            Pod(ps(Pod(d.generation[1]), Pod(d.generation[2]))), Pod(d.active_adoption_observed))
    end
    decoded = Runner._decode_details(operation, fields.values, record.lifecycle)
    decoded.outcome == result.outcome || throw(ArgumentError("runner outcome mismatch"))
    return ps(_id(record.lifecycle), _id(result.outcome), Pod(fields))
end
function _decode_record(pod, operation::UInt32)
    f = _arity(_fields(pod), 3)
    lifecycle = Runner._lifecycle(f[1])
    result = Runner._decode_details(operation, _fields(f[3]), lifecycle)
    result.outcome == Runner._outcome(f[2]) || throw(ArgumentError("runner outcome mismatch"))
    return RunnerRecord(lifecycle, result)
end
function _validate_runner(runner::RunnerObservation)
    _binding(runner.binding; profile="pipewireao.rtc.runner/1")
    runner.token > 0 || throw(ArgumentError("runner status must have a fresh matching token"))
    _text(runner.session_id; limit=128) == "native-runner-instance:$(runner.binding.instance)" ||
        throw(ArgumentError("runner session does not identify its binding incarnation"))
    runner.status.result.outcome === Runner.Observed || throw(ArgumentError("runner Status must be Observed"))
    _record_size(runner.status, UInt32(3))
end
function _runner_pod(runner::RunnerObservation)
    _validate_runner(runner)
    return _struct(Pod(_binding_pod(runner.binding)), Pod(runner.token), Pod(runner.session_id),
        Pod(_record_pod(runner.status, UInt32(3))))
end
function _decode_runner(pod)
    f = _arity(_fields(pod), 4)
    runner = RunnerObservation(_decode_binding(f[1]), _long(f[2]), _string(f[3]), _decode_record(f[4], UInt32(3)))
    _validate_runner(runner)
    return runner
end
function _simulator(snapshot::SimulatorSnapshot, binding::Binding, token::Int64)
    snapshot.version == 1 && snapshot.instance == binding.instance && snapshot.kind == 3 &&
        snapshot.token == token > 0 && snapshot.result == 0 || throw(ArgumentError("source is not a matched fresh query"))
    snapshot.generation >= 1 && snapshot.sequence >= 0 && snapshot.report_generation >= 1 &&
        snapshot.report_sequence >= 0 && snapshot.report_generation <= snapshot.generation &&
        (snapshot.report_generation != snapshot.generation || snapshot.report_sequence <= snapshot.sequence) &&
        !(snapshot.running && snapshot.completed) || throw(ArgumentError("invalid simulator snapshot semantics"))
    snapshot.completed && (snapshot.report_generation, snapshot.report_sequence) != (snapshot.generation, snapshot.sequence) &&
        throw(ArgumentError("completed source report cursor is not current"))
    return snapshot
end
function _source_kind(source::SourceObservation)
    profile = source.binding.profile
    return profile == "pipewireao.source-control/1" ? UInt32(1) :
        profile == Client.profile_name(Acquisition.CALIBRATION_PROFILE) ? UInt32(2) :
        profile == Client.profile_name(Acquisition.CORRECTION_PROFILE) ? UInt32(3) :
        throw(ArgumentError("unknown source binding profile"))
end
function _source_pod(source::SourceObservation)
    _binding(source.binding); source.token > 0 || throw(ArgumentError("source status token must be fresh"))
    kind = _source_kind(source)
    body = if kind == 1
        source.lifecycle === nothing && source.snapshot isa SimulatorSnapshot || throw(ArgumentError("wrong simulator observation kind"))
        s = _simulator(source.snapshot, source.binding, source.token)
        _struct(Pod(s.version), Pod(s.instance), Pod(s.kind), Pod(s.token), Pod(s.result),
            Pod(s.generation), Pod(s.sequence), Pod(s.running), Pod(s.completed),
            Pod(s.report_generation), Pod(s.report_sequence))
    else
        source.lifecycle !== nothing && source.snapshot isa Acquisition.Snapshot || throw(ArgumentError("wrong acquisition observation kind"))
        profile = kind == 2 ? Acquisition.CALIBRATION_PROFILE : Acquisition.CORRECTION_PROFILE
        Acquisition._validate(profile, source.lifecycle, source.snapshot)
        _struct(_id(source.lifecycle), Pod(Acquisition._snapshot_pod(source.snapshot)))
    end
    return _struct(Pod(_binding_pod(source.binding)), Pod(source.token), _id(kind), Pod(body))
end
function _decode_source(pod)
    f = _arity(_fields(pod), 4); binding = _decode_binding(f[1]); token = _long(f[2]); kind = Runner._id(f[3])
    body = _fields(f[4])
    source = if kind == 1
        _arity(body, 11)
        SourceObservation(binding, token, nothing, SimulatorSnapshot(_int(body[1]), _long(body[2]),
            _int(body[3]), _long(body[4]), _int(body[5]), _long(body[6]), _long(body[7]),
            _bool(body[8]), _bool(body[9]), _long(body[10]), _long(body[11])))
    elseif kind in (2, 3)
        _arity(body, 2); lifecycle = _enum(Acquisition.ColdLifecycle, body[1])
        profile = kind == 2 ? Acquisition.CALIBRATION_PROFILE : Acquisition.CORRECTION_PROFILE
        SourceObservation(binding, token, lifecycle, Acquisition._decode_snapshot(profile, lifecycle, body[2]))
    else
        throw(ArgumentError("unknown supervisor source kind"))
    end
    _source_kind(source) == kind || throw(ArgumentError("source kind/profile mismatch"))
    _source_pod(source)
    return source
end
function _heart_pod(heart::HeartObservation)
    _binding(heart.binding; profile="pipewireao.rtc.heart/1")
    heart.token > 0 || throw(ArgumentError("HEART health must have a fresh matching token"))
    Heart._validate_snapshot(heart.lifecycle, heart.snapshot)
    return _struct(Pod(_binding_pod(heart.binding)), Pod(heart.token), _id(heart.lifecycle), Pod(Heart._snapshot_pod(heart.snapshot)))
end
function _decode_heart(pod)
    f = _arity(_fields(pod), 4); lifecycle = _enum(Heart.HeartLifecycle, f[3])
    heart = HeartObservation(_decode_binding(f[1]), _long(f[2]), lifecycle, Heart._decode_snapshot(lifecycle, f[4]))
    _heart_pod(heart)
    return heart
end
function validate_snapshot(phase::Phase, admitted::Bool, snapshot::Snapshot)
    _phase(phase, admitted)
    length(snapshot.processes) <= MAX_PROCESSES || throw(ArgumentError("too many owned processes"))
    roles = Set{String}(); pids = Set{UInt32}()
    for process in snapshot.processes
        _text(process.role); process.pid > 0 || throw(ArgumentError("invalid owned PID"))
        process.role in roles && throw(ArgumentError("duplicate owned role"))
        process.pid in pids && throw(ArgumentError("duplicate owned PID"))
        push!(roles, process.role); push!(pids, process.pid)
    end
    if phase === Preparing
        isempty(roles) && snapshot.runner === nothing && snapshot.source === nothing && snapshot.heart === nothing ||
            throw(ArgumentError("Preparing cannot report admitted owners"))
    end
    admitted && snapshot.runner === nothing && throw(ArgumentError("Admitted requires fresh runner status"))
    for observation in (snapshot.runner, snapshot.source, snapshot.heart)
        observation === nothing && continue
        observation.binding.pid in pids || throw(ArgumentError("binding PID is not currently owned"))
    end
    snapshot.runner === nothing || _validate_runner(snapshot.runner)
    snapshot.source === nothing || _source_pod(snapshot.source)
    snapshot.heart === nothing || _heart_pod(snapshot.heart)
    return snapshot
end
function _snapshot_pod(snapshot::Snapshot)
    rows = SPA.Struct(Pod[Pod(_struct(Pod(p.role), _id(p.pid))) for p in sort(snapshot.processes; by=p->p.role)])
    return _struct(Pod(rows), _optional_pod(snapshot.runner, _runner_pod),
        _optional_pod(snapshot.source, _source_pod), _optional_pod(snapshot.heart, _heart_pod))
end
function _decode_snapshot(pod)
    f = _arity(_fields(pod), 4); rows = _fields(f[1])
    length(rows) <= MAX_PROCESSES || throw(ArgumentError("too many owned processes"))
    processes = OwnedProcess[]
    for row in rows
        r = _arity(_fields(row), 2); push!(processes, OwnedProcess(_string(r[1]), Runner._id(r[2])))
    end
    return Snapshot(processes, _optional(f[2], _decode_runner), _optional(f[3], _decode_source), _optional(f[4], _decode_heart))
end
function _operation(header)
    1 <= header.operation <= length(Runner.OPERATIONS) || throw(ArgumentError("unknown supervisor operation"))
end
function _completion_payload(header, phase, admitted, snapshot, result, error)
    _phase(phase, admitted); _operation(header)
    header.controller === nothing && throw(ArgumentError("sentinel is not a fresh supervisor completion"))
    if header.result < 0
        snapshot === nothing && result === nothing && error isa Runner.RunnerError || throw(ArgumentError("invalid failed supervisor completion"))
        return _struct(_id(phase), Pod(admitted), Pod(_text(error.field; empty=true, limit=8192)), Pod(_text(error.message; empty=true, limit=8192)))
    end
    error === nothing && snapshot isa Snapshot || throw(ArgumentError("successful supervisor completion requires snapshot"))
    validate_snapshot(phase, admitted, snapshot)
    if header.operation == 3
        result === nothing || throw(ArgumentError("Status result is the fresh runner observation"))
    else
        phase === Admitted && result isa RunnerRecord || throw(ArgumentError("non-Status completion requires admitted runner result"))
    end
    return _struct(_id(phase), Pod(admitted), Pod(_snapshot_pod(snapshot)),
        _optional_pod(result, r -> _record_pod(r, header.operation)))
end
const REPLY_BOUND = 64 * 1024
_add(a, b) = Envelope._bounded_add(a, b, REPLY_BOUND)
_struct_size(sizes) = foldl(_add, sizes; init=8)
_string_size(value; empty=false, limit=64 * 1024) = Runner._pod_size(ncodeunits(_text(value; empty, limit)) + 1)
function _catalog_size(records, row_size)
    length(records) <= Runner.MAX_ROWS || throw(ArgumentError("runner catalog cannot fit reply"))
    return _struct_size(row_size(record) for record in records)
end
_scalar_size(value::Runner.RunnerScalar) = value.kind === :string ? _string_size(value.value; empty=true) : 16
function _record_size(record::RunnerRecord, operation::UInt32)
    record.result isa Runner.RunnerResult{Runner.OPERATIONS[Int(operation)]} || throw(ArgumentError("runner result operation mismatch"))
    d = record.result.details
    details = if operation == 1
        16
    elseif operation == 2
        _catalog_size(pairs(d.groups), row -> _struct_size((_string_size(row.first), 16)))
    elseif operation == 3
        _add(64, _catalog_size(pairs(d.discarded_by_sink), row -> _struct_size((_string_size(row.first), 16))))
    elseif operation == 4
        _add(_string_size(d.graph), _catalog_size(pairs(d.properties), row -> _struct_size((_string_size(row.first), _scalar_size(row.second)))))
    elseif operation == 5 || operation == 6
        _struct_size((_string_size(d.graph), _string_size(d.node), 16, d.active === nothing ? 8 : 16)) - 8
    elseif operation == 7 || operation == 8
        _struct_size((_string_size(d.group), 16, d.observed === nothing ? 8 : 16)) - 8
    elseif operation in (9, 10, 11, 12)
        16
    elseif operation == 13
        _struct_size((_string_size(d.graph), _catalog_size(d.generations,
            g -> _struct_size((_string_size(g.node), g.requested === nothing ? 8 : 16, g.active === nothing ? 8 : 16))), 16)) - 8
    else
        _struct_size((_string_size(d.graph), _string_size(d.parameter), d.generation === nothing ? 8 : 40, 16)) - 8
    end
    return _struct_size((16, 16, _add(8, details)))
end
function _binding_size(binding::Binding)
    _binding(binding)
    return _struct_size((_string_size(binding.name; limit=128), _string_size(binding.profile; limit=128), 16, 16, 16, 16))
end
function _runner_size(runner::RunnerObservation)
    _validate_runner(runner)
    return _struct_size((_binding_size(runner.binding), 16, _string_size(runner.session_id; limit=128), _record_size(runner.status, UInt32(3))))
end
# Source and HEART records have fixed field counts and checked bounded strings;
# their small owned PODs also reuse the established owner validators.
_source_size(source::SourceObservation) = sizeof(Pod(_source_pod(source)))
_heart_size(heart::HeartObservation) = sizeof(Pod(_heart_pod(heart)))
_optional_size(value, size) = value === nothing ? 8 : size(value)
function _snapshot_size(snapshot::Snapshot)
    rows = _struct_size(_struct_size((_string_size(p.role; limit=128), 16)) for p in snapshot.processes)
    return _struct_size((rows, _optional_size(snapshot.runner, _runner_size),
        _optional_size(snapshot.source, _source_size), _optional_size(snapshot.heart, _heart_size)))
end

"""Reserve a mutation's combined reply and bounded error alternative before effects.

`snapshot_bound` must include any fields or string growth the operation can add.
The caller obtains it from a specified future owner layout when the present
snapshot does not bound that layout. No mutation or result catalog is constructed.
"""
function preflight_mutation_reply(command::Runner.RunnerCommand, snapshot::Snapshot;
        snapshot_bound::Int=_snapshot_size(snapshot))
    op = Runner.operation_id(command)
    op in (1, 7, 8, 9, 10, 11, 12, 13, 14) || throw(ArgumentError("query has no mutation reply reservation"))
    validate_snapshot(Admitted, true, snapshot)
    present = _snapshot_size(snapshot)
    present <= snapshot_bound <= REPLY_BOUND || throw(ArgumentError("future snapshot bound is too small or oversized"))
    Runner._preflight_request(command, sizeof(Envelope.encode_request(
        Envelope.RequestHeader(Envelope.ControllerIdentity(UInt32(1), UInt64(1), Int64(1)), Int64(1), Int64(1), op, Int64(1)), _struct())))
    args = command.args
    details = if op in (1, 9, 10, 11, 12)
        16
    elseif op in (7, 8)
        _struct_size((_string_size(args[1]), 16, 16)) - 8
    elseif op == 13
        # The dispatcher reports one generation row per distinct node prefix.
        # Invalid qualified names fail the existing runner validation before effects.
        nodes = Set{SubString{String}}()
        for qualified in keys(args[2])
            parts = split(qualified, ':'; limit=2)
            length(parts) == 2 && !isempty(parts[1]) && !isempty(parts[2]) ||
                throw(ArgumentError("property name must be qualified node:property"))
            push!(nodes, parts[1])
        end
        rows = _struct_size(_struct_size((_string_size(node), 16, 16)) for node in nodes)
        _struct_size((_string_size(args[1]), rows, 16)) - 8
    else
        # Parameter result has graph/name and the worst present generation pair;
        # dimensions/schema/artifact path are request preparation metadata only.
        _struct_size((_string_size(args[1]), _string_size(args[2]), 40, 16)) - 8
    end
    record = _struct_size((16, 16, _add(8, details)))
    success = _struct_size((16, 16, snapshot_bound, record))
    failure = _struct_size((16, 16, Runner._pod_size(8193), Runner._pod_size(8193)))
    base = sizeof(Envelope.encode_completion(Envelope.ReplyHeader(Int64(1), Int32(0)), _struct()))
    return max(_add(base, success - 8), _add(base, failure - 8))
end

"Exact capacity preflight, before cloning variable runner catalogs or encoding the reply."
function completion_size(header, phase, admitted, snapshot, result=nothing, error=nothing)
    _phase(phase, admitted); _operation(header)
    header.controller === nothing && throw(ArgumentError("sentinel is not a fresh supervisor completion"))
    payload_size = if header.result < 0
        snapshot === nothing && result === nothing && error isa Runner.RunnerError || throw(ArgumentError("invalid failed supervisor completion"))
        _struct_size((16, 16, _string_size(error.field; empty=true, limit=8192), _string_size(error.message; empty=true, limit=8192)))
    else
        error === nothing && snapshot isa Snapshot || throw(ArgumentError("success requires snapshot"))
        validate_snapshot(phase, admitted, snapshot)
        header.operation == 3 ? (result === nothing || throw(ArgumentError("Status result is the runner observation"))) :
            (phase === Admitted && result isa RunnerRecord || throw(ArgumentError("non-Status requires admitted runner result")))
        _struct_size((16, 16, _snapshot_size(snapshot), _optional_size(result, r -> _record_size(r, header.operation))))
    end
    base = sizeof(Envelope.encode_completion(header, _struct(); endpoint=:lifecycle))
    return _add(base, payload_size - 8)
end
function encode_completion(header, phase, admitted, snapshot, result=nothing, error=nothing)
    completion_size(header, phase, admitted, snapshot, result, error)
    payload = _completion_payload(header, phase, admitted, snapshot, result, error)
    return Envelope.encode_completion(header, payload; endpoint=:lifecycle)
end
function decode_completion(input)
    header, payload = Envelope.decode_completion(input; endpoint=:lifecycle)
    _operation(header); header.controller === nothing && throw(ArgumentError("sentinel is not a fresh supervisor completion"))
    f = _arity(payload.values, 4); phase = _enum(Phase, f[1]); admitted = _bool(f[2]); _phase(phase, admitted)
    if header.result < 0
        return Completion(header, phase, admitted, nothing, nothing,
            Runner.RunnerError(_string(f[3]; empty=true, limit=8192), _string(f[4]; empty=true, limit=8192)))
    end
    snapshot = _decode_snapshot(f[3]); result = _optional(f[4], p -> _decode_record(p, header.operation))
    _completion_payload(header, phase, admitted, snapshot, result, nothing)
    return Completion(header, phase, admitted, snapshot, result, nothing)
end
function encode_rejection(header, phase, admitted, error=Runner.RunnerError("control", "request rejected"))
    _phase(phase, admitted)
    return Envelope.encode_rejection(header, _struct(_id(phase), Pod(admitted),
        Pod(_text(error.field; empty=true, limit=8192)), Pod(_text(error.message; empty=true, limit=8192))); endpoint=:lifecycle)
end
function decode_rejection(input)
    header, payload = Envelope.decode_rejection(input; endpoint=:lifecycle)
    f = _arity(payload.values, 4); phase = _enum(Phase, f[1]); admitted = _bool(f[2]); _phase(phase, admitted)
    return Rejection(header, phase, admitted, Runner.RunnerError(_string(f[3]; empty=true, limit=8192),
        _string(f[4]; empty=true, limit=8192)))
end
Client.encode_completion(::SupervisorProfile, args...) = encode_completion(args...)
Client.encode_rejection(::SupervisorProfile, header, phase) = encode_rejection(header, phase, phase === Admitted)
Client.encode_failure(::SupervisorProfile, header, phase) = encode_completion(header, phase, phase === Admitted,
    nothing, nothing, Runner.RunnerError("control", "request expired or controller removed"))

end # module NativeSupervisorCodec
