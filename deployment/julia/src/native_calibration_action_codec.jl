"""Typed, bounded calibration action payloads; no acquisition effects."""
module NativeCalibrationActionCodec

using PipeWireAO
import ..NativeControlCodec
import ..NativeControlClient
import ..NativeAcquisitionLifecycleCodec
const Envelope = NativeControlCodec
const Client = NativeControlClient
const Lifecycle = NativeAcquisitionLifecycleCodec
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod
const ColdLifecycle = Lifecycle.ColdLifecycle
const AcquisitionCursor = Lifecycle.AcquisitionCursor

export PROFILE, CalibrationActionProfile, Command, Hold, Adopt, Settle, Collect,
    Capture, Restore, Release, Immediate, DiscardExposures, ModelTime,
    Held, Adopted, Settled, Responses, Captured, Restored, Released, Failed,
    FailureReason, Cancelled, Endpoint, InvalidEvidence, ProbeClipped,
    Exposure, Completion, Rejection, collect_reply_size, preflight_collect_reply

struct CalibrationActionProfile <: Client.Profile end
const PROFILE = CalibrationActionProfile()
Client.profile_name(::CalibrationActionProfile) = "pipewireao.rtc.calibration-actions/1"
Client.reply_endpoint(::CalibrationActionProfile) = :calibration
Client.capability_names(::CalibrationActionProfile) = Tuple(
    "pipewireao.rtc.calibration-actions." * suffix for suffix in
    ("version", "instance", "owner-pid", "lifecycle", "last-token", "controllers"))
Client.lifecycle_type(::CalibrationActionProfile) = ColdLifecycle

abstract type Rule end
struct Immediate <: Rule end
struct DiscardExposures <: Rule
    frames::UInt32
end
struct ModelTime <: Rule
    duration_ns::UInt64
end
abstract type Action end
struct Hold <: Action end
struct Adopt{V<:AbstractVector{Float32}} <: Action
    probe::UInt32
    figure::V
end
struct Settle{R<:Rule} <: Action
    probe::UInt32
    after::AcquisitionCursor
    rule::R
end
struct Collect <: Action
    probe::UInt32
    after::AcquisitionCursor
    measurements::UInt32
    frames::UInt32
end
struct Capture <: Action
    probe::UInt32
    after::AcquisitionCursor
    frames::UInt32
end
struct Restore{V<:AbstractVector{Float32},R<:Rule} <: Action
    figure::V
    rule::R
end
struct Release <: Action end
struct Command{A<:Action}
    run::UInt64
    serial::UInt64
    action::A
end
_operation(::Hold) = UInt32(1)
_operation(::Adopt) = UInt32(2)
_operation(::Settle) = UInt32(3)
_operation(::Collect) = UInt32(4)
_operation(::Capture) = UInt32(5)
_operation(::Restore) = UInt32(6)
_operation(::Release) = UInt32(7)
Client.operation_id(::CalibrationActionProfile, command::Command) = _operation(command.action)

abstract type Result end
struct Held <: Result
    cursor::AcquisitionCursor
end
struct Adopted{V<:AbstractVector{Float32}} <: Result
    cursor::AcquisitionCursor
    figure::V
    clipped::Bool
end
struct Settled <: Result
    cursor::AcquisitionCursor
end
struct Exposure
    domain::UInt64
    generation::UInt64
    sequence::UInt64
    start_model_ns::UInt64
    duration_ns::UInt64
end
struct Responses{V<:AbstractVector{Float32},E<:AbstractVector{Exposure}} <: Result
    values::V
    exposures::E
    valid::Bool
end
struct Captured <: Result
    cursor::AcquisitionCursor
    manifest::String
    sha256::String
    frames::UInt32
    bytes::UInt64
    metadata_bytes::UInt64
end
struct Restored{V<:AbstractVector{Float32}} <: Result
    figure::V
    clipped::Bool
end
struct Released <: Result end
@enum FailureReason::UInt32 Cancelled=1 Endpoint=2 InvalidEvidence=3 ProbeClipped=4
struct Failed <: Result
    reason::FailureReason
end
_tag(::Held) = UInt32(1)
_tag(::Adopted) = UInt32(2)
_tag(::Settled) = UInt32(3)
_tag(::Responses) = UInt32(4)
_tag(::Captured) = UInt32(5)
_tag(::Restored) = UInt32(6)
_tag(::Released) = UInt32(7)
_tag(::Failed) = UInt32(8)
struct Completion
    header::Envelope.ReplyHeader
    lifecycle::ColdLifecycle
    run::UInt64
    serial::UInt64
    result::Union{Nothing,Result}
    message::String
end
struct Rejection
    header::Envelope.ReplyHeader
    lifecycle::ColdLifecycle
    message::String
end
Client.completion_type(::CalibrationActionProfile) = Completion
Client.rejection_type(::CalibrationActionProfile) = Rejection

_struct(fields::Pod...) = SPA.Struct(Pod[fields...])
_id(value) = Pod(SPA.Id(UInt32(value)))
_long(value::UInt64) = Pod(reinterpret(Int64, value))
_fields(pod) = Lifecycle._fields(pod)
_arity(fields, count) = Lifecycle._arity(fields, count)
_read_id(pod) = Lifecycle._id(pod)
_read_long(pod) = reinterpret(UInt64, Lifecycle._long(pod))
_bool(pod) = Lifecycle._bool(pod)
_string(pod; limit) = Lifecycle._string(pod; empty=true, limit)
_enum(T, pod) = Lifecycle._enum(T, pod)
_check(ok, message) = ok || throw(ArgumentError(message))
_identity(run, serial) = _check(run > 0 && serial > 0, "run and serial must be positive")
_probe(value) = _check(value <= 16383, "probe must be in 0:16383")
_frames(value) = _check(1 <= value <= 4096, "frames must be in 1:4096")
_measurements(value) = _check(1 <= value <= 131072, "measurements must be in 1:131072")
function _cursor(cursor::AcquisitionCursor)
    _check(cursor.domain > 0 && cursor.generation > 0 && cursor.model_ns <= typemax(Int64),
        "invalid action acquisition cursor")
    return cursor
end
_cursor_pod(cursor) = Lifecycle._cursor_pod(_cursor(cursor))
_decode_cursor(pod) = _cursor(Lifecycle._decode_cursor(pod))
function _vector(values, maximum)
    _check(1 <= length(values) <= maximum && all(isfinite, values), "invalid Float32 vector")
    return values
end
function _array(pod, T)
    _check(PipeWireAO.pod_type(pod) == SPA.POD_ARRAY, "expected Array")
    array = PipeWireAO.pod_value(SPA.Array, pod)
    _check(eltype(array.values) === T, "wrong Array child type")
    return array.values
end
_float_pod(values::Vector{Float32}, maximum) = Pod(SPA.Array(_vector(values, maximum)))
function _float_pod(values::AbstractVector{Float32}, maximum)
    _vector(values, maximum)
    # Wire positions enumerate values; host index labels are not transmitted.
    owned = Vector{Float32}(undef, length(values))
    for (position, value) in enumerate(values)
        owned[position] = value
    end
    return Pod(SPA.Array(owned))
end
_decode_float(pod, maximum) = _vector(_array(pod, Float32), maximum)
_validate(::Immediate) = nothing
_validate(rule::DiscardExposures) = _frames(rule.frames)
_validate(rule::ModelTime) = _check(0 < rule.duration_ns <= typemax(Int64), "invalid model duration")
_rule_pod(::Immediate) = _struct(_id(1))
_rule_pod(rule::DiscardExposures) = (_validate(rule); _struct(_id(2), _id(rule.frames)))
_rule_pod(rule::ModelTime) = (_validate(rule); _struct(_id(3), _long(rule.duration_ns)))
function _decode_rule(pod)
    f = _fields(pod)
    _check(!isempty(f), "empty settling rule")
    tag = _read_id(f[1])
    rule = if tag == 1
        _arity(f, 1); Immediate()
    elseif tag == 2
        _arity(f, 2); DiscardExposures(_read_id(f[2]))
    elseif tag == 3
        _arity(f, 2); ModelTime(_read_long(f[2]))
    else
        throw(ArgumentError("unknown settling rule"))
    end
    _validate(rule)
    return rule
end

# Exact SPA padded size grammar, checked before any vector POD copy.
_add(a, b) = Base.Checked.checked_add(a, b)
_mul(a, b) = Base.Checked.checked_mul(a, b)
_pad(body) = _add(body, 15) & -8
_array_size(n, width) = _pad(_add(8, _mul(n, width)))
_string_size(n) = _pad(_add(n, 1))
function _envelope_base(kind)
    h, p = Envelope._names(kind)
    return _add(176, _add(_string_size(ncodeunits(h)), _string_size(ncodeunits(p))))
end
_rule_size(::Immediate) = 24
_rule_size(::Union{DiscardExposures,ModelTime}) = 40
_args_size(::Union{Hold,Release}) = 8
_args_size(action::Adopt) = (_probe(action.probe); _vector(action.figure, 4096); _add(24, _array_size(length(action.figure), 4)))
_args_size(action::Settle) = (_probe(action.probe); _cursor(action.after); _validate(action.rule); _add(96, _rule_size(action.rule)))
_args_size(action::Collect) = (_probe(action.probe); _cursor(action.after); _measurements(action.measurements); _frames(action.frames); 128)
_args_size(action::Capture) = (_probe(action.probe); _cursor(action.after); _frames(action.frames); 112)
_args_size(action::Restore) = (_vector(action.figure, 4096); _validate(action.rule); _add(8, _add(_array_size(length(action.figure), 4), _rule_size(action.rule))))
function _preflight(command::Command)
    _identity(command.run, command.serial)
    size = _add(_envelope_base(:request), _add(32, _args_size(command.action)))
    _check(size <= 16384, "calibration request exceeds 16 KiB")
    return size
end
_args(::Union{Hold,Release}) = _struct()
_args(a::Adopt) = _struct(_id(a.probe), _float_pod(a.figure, 4096))
_args(a::Settle) = _struct(_id(a.probe), Pod(_cursor_pod(a.after)), Pod(_rule_pod(a.rule)))
_args(a::Collect) = _struct(_id(a.probe), Pod(_cursor_pod(a.after)), _id(a.measurements), _id(a.frames))
_args(a::Capture) = _struct(_id(a.probe), Pod(_cursor_pod(a.after)), _id(a.frames))
_args(a::Restore) = _struct(_float_pod(a.figure, 4096), Pod(_rule_pod(a.rule)))
function Client.encode_request(profile::CalibrationActionProfile, header::Envelope.RequestHeader, command::Command)
    _check(header.operation == Client.operation_id(profile, command), "header/action operation mismatch")
    _preflight(command)
    return Envelope.encode_request(header, _struct(_long(command.run), _long(command.serial), Pod(_args(command.action))))
end
function _decode_action(operation, pod)
    f = _fields(pod)
    if operation == 1
        _arity(f, 0); return Hold()
    elseif operation == 2
        _arity(f, 2); return Adopt(_read_id(f[1]), _decode_float(f[2], 4096))
    elseif operation == 3
        _arity(f, 3); return Settle(_read_id(f[1]), _decode_cursor(f[2]), _decode_rule(f[3]))
    elseif operation == 4
        _arity(f, 4); return Collect(_read_id(f[1]), _decode_cursor(f[2]), _read_id(f[3]), _read_id(f[4]))
    elseif operation == 5
        _arity(f, 3); return Capture(_read_id(f[1]), _decode_cursor(f[2]), _read_id(f[3]))
    elseif operation == 6
        _arity(f, 2); return Restore(_decode_float(f[1], 4096), _decode_rule(f[2]))
    elseif operation == 7
        _arity(f, 0); return Release()
    end
    throw(ArgumentError("unknown calibration operation"))
end
function Client.decode_request(::CalibrationActionProfile, header::Envelope.RequestHeader, payload::SPA.Struct)
    f = _arity(payload.values, 3)
    command = Command(_read_long(f[1]), _read_long(f[2]), _decode_action(header.operation, f[3]))
    _preflight(command)
    return command
end
function Client.decode_request(profile::CalibrationActionProfile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_request(input)
    return header, Client.decode_request(profile, header, payload)
end
function _exposure(e::Exposure)
    _check(e.domain > 0 && e.generation > 0 && e.duration_ns > 0 &&
        e.duration_ns <= typemax(UInt64) - e.start_model_ns, "invalid exposure identity or end")
    return e
end
function _exposures(values)
    _frames(length(values))
    foreach(_exposure, values)
    return values
end
function _exposure_pod(values)
    _exposures(values)
    flat = Int64[]
    sizehint!(flat, 5 * length(values))
    for e in values
        append!(flat, reinterpret(Int64, UInt64[e.domain, e.generation, e.sequence, e.start_model_ns, e.duration_ns]))
    end
    return Pod(SPA.Array(flat))
end
function _decode_exposures(pod)
    flat = _array(pod, Int64)
    _check(length(flat) % 5 == 0, "exposure array must contain groups of five Longs")
    _frames(length(flat) ÷ 5)
    values = Exposure[Exposure((reinterpret(UInt64, flat[i+j]) for j in 0:4)...) for i in 1:5:length(flat)]
    return _exposures(values)
end
function _capture(result::Captured)
    _cursor(result.cursor); _frames(result.frames)
    Lifecycle._checked_string(result.manifest; empty=false, limit=512)
    _check(!startswith(result.manifest, "/") && !occursin('\\', result.manifest) &&
        all(part -> !isempty(part) && !(part in (".", "..")), split(result.manifest, '/')),
        "manifest must be a relative path without traversal")
    _check(ncodeunits(result.sha256) == 64 && all(c -> c in '0':'9' || c in 'a':'f', result.sha256), "invalid SHA256")
end
_result_size(r::Union{Held,Settled}) = (_cursor(r.cursor); 96)
_result_size(r::Adopted) = (_cursor(r.cursor); _vector(r.figure, 4096); _add(112, _array_size(length(r.figure), 4)))
_result_size(r::Responses) = (_vector(r.values, 131072); _exposures(r.exposures); _add(40, _add(_array_size(length(r.values), 4), _array_size(length(r.exposures), 40))))
_result_size(r::Captured) = (_capture(r); _add(144, _add(_string_size(ncodeunits(r.manifest)), _string_size(64))))
_result_size(r::Restored) = (_vector(r.figure, 4096); _add(40, _array_size(length(r.figure), 4)))
_result_size(::Released) = 24
_result_size(result::Failed) = (_check(1 <= UInt32(result.reason) <= 4, "unknown failure reason"); 40)
_result_size(::Nothing) = 8
function _completion_size(result_size, message_bytes)
    _check(0 <= message_bytes <= 8192, "invalid completion message size")
    return _add(_envelope_base(:completion), _add(48, _add(result_size, _string_size(message_bytes))))
end
"Exact successful Collect completion extent with the supplied UTF-8 message byte count."
function collect_reply_size(measurements::Integer, frames::Integer; message_bytes::Int=0)
    _measurements(measurements); _frames(frames)
    return _completion_size(_add(40, _add(_array_size(Int(measurements), 4), _array_size(Int(frames), 40))), message_bytes)
end
function preflight_collect_reply(measurements::Integer, frames::Integer; message_bytes::Int=0)
    size = collect_reply_size(measurements, frames; message_bytes)
    _check(size <= 131072, "Collect completion exceeds 128 KiB")
    return size
end
_result(r::Held) = _struct(_id(1), Pod(_cursor_pod(r.cursor)))
_result(r::Adopted) = _struct(_id(2), Pod(_cursor_pod(r.cursor)), _float_pod(r.figure, 4096), Pod(r.clipped))
_result(r::Settled) = _struct(_id(3), Pod(_cursor_pod(r.cursor)))
_result(r::Responses) = _struct(_id(4), _float_pod(r.values, 131072), _exposure_pod(r.exposures), Pod(r.valid))
_result(r::Captured) = _struct(_id(5), Pod(_cursor_pod(r.cursor)), Pod(r.manifest), Pod(r.sha256), _id(r.frames), _long(r.bytes), _long(r.metadata_bytes))
_result(r::Restored) = _struct(_id(6), _float_pod(r.figure, 4096), Pod(r.clipped))
_result(::Released) = _struct(_id(7))
_result(r::Failed) = _struct(_id(8), _id(r.reason))
function _decode_result(pod)
    f = _fields(pod)
    _check(!isempty(f), "empty action result")
    tag = _read_id(f[1])
    if tag == 1
        _arity(f, 2); return Held(_decode_cursor(f[2]))
    elseif tag == 2
        _arity(f, 4); return Adopted(_decode_cursor(f[2]), _decode_float(f[3], 4096), _bool(f[4]))
    elseif tag == 3
        _arity(f, 2); return Settled(_decode_cursor(f[2]))
    elseif tag == 4
        _arity(f, 4); return Responses(_decode_float(f[2], 131072), _decode_exposures(f[3]), _bool(f[4]))
    elseif tag == 5
        _arity(f, 7); return Captured(_decode_cursor(f[2]), _string(f[3]; limit=512), _string(f[4]; limit=64), _read_id(f[5]), _read_long(f[6]), _read_long(f[7]))
    elseif tag == 6
        _arity(f, 3); return Restored(_decode_float(f[2], 4096), _bool(f[3]))
    elseif tag == 7
        _arity(f, 1); return Released()
    elseif tag == 8
        _arity(f, 2); return Failed(_enum(FailureReason, f[2]))
    end
    throw(ArgumentError("unknown calibration result tag"))
end
function _completion(header, run, serial, result)
    _identity(run, serial)
    _check(header.controller !== nothing && 1 <= header.operation <= 7, "invalid action completion correlation")
    result === nothing ? _check(header.result < 0, "successful completion requires result") :
        _check(_tag(result) == 8 || _tag(result) == header.operation, "operation/result mismatch")
end
function Client.encode_completion(::CalibrationActionProfile, header::Envelope.ReplyHeader,
        lifecycle::ColdLifecycle, run::UInt64, serial::UInt64, result::Union{Nothing,Result}, message::AbstractString)
    _check(1 <= UInt32(lifecycle) <= 5, "unknown cold lifecycle")
    _completion(header, run, serial, result)
    text = Lifecycle._checked_string(message; empty=true, limit=8192)
    _check(_completion_size(_result_size(result), ncodeunits(text)) <= 131072, "completion exceeds 128 KiB")
    body = result === nothing ? Pod(nothing) : Pod(_result(result))
    return Envelope.encode_completion(header, _struct(_id(lifecycle), _long(run), _long(serial), body, Pod(text)); endpoint=:calibration)
end
function Client.decode_completion(::CalibrationActionProfile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_completion(input; endpoint=:calibration)
    f = _arity(payload.values, 5)
    lifecycle = _enum(ColdLifecycle, f[1]); run = _read_long(f[2]); serial = _read_long(f[3])
    result = Lifecycle._optional(f[4], _decode_result)
    message = _string(f[5]; limit=8192)
    _completion(header, run, serial, result); _result_size(result)
    return Completion(header, lifecycle, run, serial, result, message)
end
function Client.encode_failure(profile::CalibrationActionProfile, header::Envelope.ReplyHeader,
        lifecycle::ColdLifecycle, command::Command)
    return Client.encode_completion(profile, header, lifecycle, command.run,
        command.serial, nothing, "request expired or controller disappeared")
end
function Client.encode_rejection(::CalibrationActionProfile, header::Envelope.ReplyHeader,
        lifecycle::ColdLifecycle, message::AbstractString="request rejected")
    _check(1 <= UInt32(lifecycle) <= 5, "unknown cold lifecycle")
    text = Lifecycle._checked_string(message; empty=true, limit=8192)
    return Envelope.encode_rejection(header, _struct(_id(lifecycle), Pod(text)); endpoint=:calibration)
end
function Client.decode_rejection(::CalibrationActionProfile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_rejection(input; endpoint=:calibration)
    f = _arity(payload.values, 2)
    return Rejection(header, _enum(ColdLifecycle, f[1]), _string(f[2]; limit=8192))
end

end # module NativeCalibrationActionCodec
