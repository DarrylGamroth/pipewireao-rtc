"""Bounded native lifecycle profile for calibration and finite correction owners."""
module NativeAcquisitionLifecycleCodec

using PipeWireAO
import ..NativeControlCodec
import ..NativeControlClient

const Envelope = NativeControlCodec
const Client = NativeControlClient
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod

export CalibrationLifecycleProfile, CorrectionLifecycleProfile,
    CALIBRATION_PROFILE, CORRECTION_PROFILE, ColdLifecycle,
    Preparing, Prepared, Connected, Fault, Stopped,
    Instrument, Classic, Copper, AcquisitionCursor, Snapshot,
    LifecycleCommand, Completion, Rejection

struct CalibrationLifecycleProfile <: Client.Profile end
struct CorrectionLifecycleProfile <: Client.Profile end
const CALIBRATION_PROFILE = CalibrationLifecycleProfile()
const CORRECTION_PROFILE = CorrectionLifecycleProfile()

_namespace(::CalibrationLifecycleProfile) = "pipewireao.rtc.calibration-lifecycle"
_namespace(::CorrectionLifecycleProfile) = "pipewireao.rtc.correction-lifecycle"
Client.profile_name(profile::Union{CalibrationLifecycleProfile,CorrectionLifecycleProfile}) = _namespace(profile) * "/1"
Client.reply_endpoint(::Union{CalibrationLifecycleProfile,CorrectionLifecycleProfile}) = :lifecycle
Client.capability_names(profile::Union{CalibrationLifecycleProfile,CorrectionLifecycleProfile}) =
    Tuple(_namespace(profile) * "." * suffix for suffix in
        ("version", "instance", "owner-pid", "lifecycle", "last-token", "controllers"))

@enum ColdLifecycle::UInt32 Preparing=1 Prepared=2 Connected=3 Fault=4 Stopped=5
@enum Instrument::UInt32 Classic=1 Copper=2

struct LifecycleCommand{O} end
function LifecycleCommand(operation::Symbol)
    operation in (:status, :pause, :resume, :reset, :connect, :shutdown) ||
        throw(ArgumentError("unknown acquisition lifecycle operation"))
    return LifecycleCommand{operation}()
end
const OPERATIONS = ((:status, UInt32(1)), (:pause, UInt32(2)),
    (:resume, UInt32(3)), (:reset, UInt32(4)), (:connect, UInt32(5)),
    (:shutdown, UInt32(6)))
function Client.operation_id(::Union{CalibrationLifecycleProfile,CorrectionLifecycleProfile},
        ::LifecycleCommand{O}) where O
    for (name, id) in OPERATIONS
        name === O && return id
    end
    throw(ArgumentError("unknown acquisition lifecycle operation"))
end

struct AcquisitionCursor
    domain::UInt64
    generation::UInt64
    sequence::UInt64
    model_ns::UInt64
end

struct Snapshot
    instrument::Instrument
    cursor::Union{Nothing,AcquisitionCursor}
    report_cursor::Union{Nothing,AcquisitionCursor}
    running::Bool
    completed::Bool
    phase::String
    held::Bool
    restored::Bool
    window::Union{Nothing,UInt64}
    function Snapshot(instrument::Instrument, cursor::Union{Nothing,AcquisitionCursor},
            report_cursor::Union{Nothing,AcquisitionCursor}, running::Bool,
            completed::Bool, phase::AbstractString, held::Bool,
            restored::Bool, window::Union{Nothing,UInt64})
        running && completed && throw(ArgumentError("running and completed conflict"))
        value = _checked_string(phase; empty=false, limit=64, ascii=true)
        new(instrument, cursor, report_cursor, running, completed, value, held, restored, window)
    end
end

struct Completion
    header::Envelope.ReplyHeader
    lifecycle::ColdLifecycle
    snapshot::Union{Nothing,Snapshot}
    message::String
end
struct Rejection
    header::Envelope.ReplyHeader
    lifecycle::ColdLifecycle
    message::String
end

const Profile = Union{CalibrationLifecycleProfile,CorrectionLifecycleProfile}
Client.lifecycle_type(::Profile) = ColdLifecycle
Client.completion_type(::Profile) = Completion
Client.rejection_type(::Profile) = Rejection

_struct(fields::Pod...) = SPA.Struct(Pod[fields...])
_fields(value::SPA.Struct) = value.values
function _fields(pod::Pod)
    PipeWireAO.pod_type(pod) == SPA.POD_STRUCT || throw(ArgumentError("expected lifecycle Struct"))
    return PipeWireAO.pod_value(SPA.Struct, pod).values
end
function _arity(fields, count)
    length(fields) == count || throw(ArgumentError("wrong lifecycle field arity"))
    return fields
end
function _scalar(pod::Pod, type::UInt32, ::Type{T}) where T
    PipeWireAO.pod_type(pod) == type && sizeof(pod) == 8 + (type == SPA.POD_BOOL ? 4 : sizeof(T)) ||
        throw(ArgumentError("wrong lifecycle scalar type or width"))
    return PipeWireAO.pod_value(T, pod)
end
_id(pod) = _scalar(pod, SPA.POD_ID, SPA.Id).value
_long(pod) = _scalar(pod, SPA.POD_LONG, Int64)
_bool(pod) = _scalar(pod, SPA.POD_BOOL, Bool)
function _checked_string(value::AbstractString; empty::Bool, limit::Int, ascii::Bool=false)
    (empty || !isempty(value)) && ncodeunits(value) <= limit && isvalid(value) &&
        !occursin('\0', value) && (!ascii || all(isascii, value)) ||
        throw(ArgumentError("invalid or oversized lifecycle string"))
    return String(value)
end
function _string(pod; empty::Bool, limit::Int, ascii::Bool=false)
    PipeWireAO.pod_type(pod) == SPA.POD_STRING || throw(ArgumentError("expected lifecycle String"))
    return _checked_string(PipeWireAO.pod_value(String, pod); empty, limit, ascii)
end
function _enum(::Type{T}, pod) where {T<:Enum}
    try
        return T(_id(pod))
    catch
        throw(ArgumentError("unknown lifecycle Id"))
    end
end
function _optional(pod, decode)
    if PipeWireAO.pod_type(pod) == SPA.POD_NONE
        sizeof(pod) == 8 || throw(ArgumentError("wrong None width"))
        return nothing
    end
    return decode(pod)
end

const CALIBRATION_PHASES = ("initial", "held", "adopted", "settled", "collected",
    "restoring", "restored", "released", "fault")
const CORRECTION_PHASES = ("initial", "startup_run", "correcting", "restore_run",
    "restored", "fault")
function _validate(profile::Profile, lifecycle::ColdLifecycle, snapshot::Snapshot)
    snapshot.phase in (profile isa CalibrationLifecycleProfile ? CALIBRATION_PHASES : CORRECTION_PHASES) ||
        throw(ArgumentError("phase/profile mismatch"))
    if lifecycle === Connected
        snapshot.cursor !== nothing && snapshot.cursor.generation > 0 ||
            throw(ArgumentError("Connected requires an acquisition cursor and generation"))
    end
    if profile isa CalibrationLifecycleProfile
        snapshot.window === nothing || throw(ArgumentError("calibration has no window"))
    elseif lifecycle === Connected
        snapshot.window !== nothing && snapshot.window > 0 ||
            throw(ArgumentError("Connected correction requires a positive window"))
    end
    return snapshot
end

_cursor_pod(cursor::AcquisitionCursor) = _struct(
    Pod(reinterpret(Int64, cursor.domain)), Pod(reinterpret(Int64, cursor.generation)),
    Pod(reinterpret(Int64, cursor.sequence)), Pod(reinterpret(Int64, cursor.model_ns)))
function _decode_cursor(pod)
    f = _arity(_fields(pod), 4)
    return AcquisitionCursor((reinterpret(UInt64, _long(field)) for field in f)...)
end
function _snapshot_pod(snapshot::Snapshot)
    return _struct(Pod(SPA.Id(UInt32(snapshot.instrument))),
        snapshot.cursor === nothing ? Pod(nothing) : Pod(_cursor_pod(snapshot.cursor)),
        snapshot.report_cursor === nothing ? Pod(nothing) : Pod(_cursor_pod(snapshot.report_cursor)),
        Pod(snapshot.running), Pod(snapshot.completed), Pod(snapshot.phase),
        Pod(snapshot.held), Pod(snapshot.restored),
        snapshot.window === nothing ? Pod(nothing) : Pod(reinterpret(Int64, snapshot.window)))
end
function _decode_snapshot(profile::Profile, lifecycle::ColdLifecycle, pod)
    f = _arity(_fields(pod), 9)
    snapshot = Snapshot(_enum(Instrument, f[1]), _optional(f[2], _decode_cursor),
        _optional(f[3], _decode_cursor), _bool(f[4]), _bool(f[5]),
        _string(f[6]; empty=false, limit=64, ascii=true),
        _bool(f[7]), _bool(f[8]), _optional(f[9], p -> reinterpret(UInt64, _long(p))))
    return _validate(profile, lifecycle, snapshot)
end

function Client.encode_request(profile::Profile, header::Envelope.RequestHeader,
        command::LifecycleCommand)
    header.operation == Client.operation_id(profile, command) ||
        throw(ArgumentError("lifecycle header/command operation mismatch"))
    return Envelope.encode_request(header, _struct())
end
function Client.decode_request(::Profile, header::Envelope.RequestHeader, payload::SPA.Struct)
    isempty(payload.values) || throw(ArgumentError("lifecycle request payload must be empty"))
    for (name, id) in OPERATIONS
        header.operation == id && return LifecycleCommand{name}()
    end
    throw(ArgumentError("unknown lifecycle operation Id"))
end
function Client.decode_request(profile::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_request(input)
    return header, Client.decode_request(profile, header, payload)
end

function Client.encode_completion(profile::Profile, header::Envelope.ReplyHeader,
        lifecycle::ColdLifecycle, snapshot::Union{Nothing,Snapshot}, message::AbstractString)
    any(pair -> last(pair) == header.operation, OPERATIONS) ||
        throw(ArgumentError("unknown lifecycle completion operation"))
    text = _checked_string(message; empty=true, limit=8192)
    snapshot === nothing ? (header.result < 0 || throw(ArgumentError("successful completion requires snapshot"))) :
        _validate(profile, lifecycle, snapshot)
    body = snapshot === nothing ? Pod(nothing) : Pod(_snapshot_pod(snapshot))
    return Envelope.encode_completion(header,
        _struct(Pod(SPA.Id(UInt32(lifecycle))), body, Pod(text)); endpoint=:lifecycle)
end
function Client.decode_completion(profile::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_completion(input; endpoint=:lifecycle)
    header.controller === nothing && throw(ArgumentError("initial sentinel is not a lifecycle completion"))
    any(pair -> last(pair) == header.operation, OPERATIONS) ||
        throw(ArgumentError("unknown lifecycle completion operation"))
    f = _arity(payload.values, 3)
    lifecycle = _enum(ColdLifecycle, f[1])
    snapshot = _optional(f[2], p -> _decode_snapshot(profile, lifecycle, p))
    snapshot === nothing && header.result >= 0 &&
        throw(ArgumentError("successful completion requires snapshot"))
    return Completion(header, lifecycle, snapshot, _string(f[3]; empty=true, limit=8192))
end
function Client.encode_rejection(::Profile, header::Envelope.ReplyHeader, lifecycle::ColdLifecycle)
    return Envelope.encode_rejection(header,
        _struct(Pod(SPA.Id(UInt32(lifecycle))), Pod("request rejected")); endpoint=:lifecycle)
end
function Client.decode_rejection(::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_rejection(input; endpoint=:lifecycle)
    f = _arity(payload.values, 2)
    return Rejection(header, _enum(ColdLifecycle, f[1]), _string(f[2]; empty=true, limit=8192))
end
function Client.encode_failure(profile::Profile, header::Envelope.ReplyHeader,
        lifecycle::ColdLifecycle)
    return Client.encode_completion(profile, header, lifecycle, nothing,
        "request expired or controller removed")
end

end # module NativeAcquisitionLifecycleCodec
