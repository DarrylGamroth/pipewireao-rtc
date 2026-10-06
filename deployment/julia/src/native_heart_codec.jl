"""Exact typed native-control profile for the supervised HEART owner."""
module NativeHeartCodec

using PipeWireAO
import ..NativeControlCodec
import ..NativeControlClient

const Envelope = NativeControlCodec
const Client = NativeControlClient
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod

export HeartProfile, HEART_PROFILE, HeartLifecycle, Ingress,
    HeartCommand, HeartSnapshot, HeartCompletion, HeartRejection,
    Preparing, Ready, Fault, Stopped, Streaming, Deferred

struct HeartProfile <: Client.Profile end
const HEART_PROFILE = HeartProfile()

Client.profile_name(::HeartProfile) = "pipewireao.rtc.heart/1"
Client.reply_endpoint(::HeartProfile) = :lifecycle
Client.capability_names(::HeartProfile) = (
    "pipewireao.rtc.heart.version", "pipewireao.rtc.heart.instance",
    "pipewireao.rtc.heart.owner-pid", "pipewireao.rtc.heart.lifecycle",
    "pipewireao.rtc.heart.last-token", "pipewireao.rtc.heart.controllers",
)

@enum HeartLifecycle::UInt32 Preparing=1 Ready=2 Fault=3 Stopped=4
@enum Ingress::UInt32 Streaming=1 Deferred=2

"A zero-argument operation whose operation identity is encoded in its type."
struct HeartCommand{O} end
function HeartCommand(operation::Symbol)
    operation === :status && return HeartCommand{:status}()
    operation === :reset && return HeartCommand{:reset}()
    operation === :connect && return HeartCommand{:connect}()
    operation === :shutdown && return HeartCommand{:shutdown}()
    throw(ArgumentError("unknown HEART operation"))
end

const OPERATIONS = ((:status, UInt32(1)), (:reset, UInt32(2)),
    (:connect, UInt32(3)), (:shutdown, UInt32(4)))
function Client.operation_id(::HeartProfile, ::HeartCommand{O}) where O
    for (operation, id) in OPERATIONS
        operation === O && return id
    end
    throw(ArgumentError("unknown HEART operation"))
end

struct HeartSnapshot
    generation::Int64
    child_pid::Union{Nothing,UInt32}
    child_returncode::Union{Nothing,Int32}
    alive::Bool
    ingress::Ingress
    placement_validated::Bool
    diagnostics_disabled::Bool
    report_path::String
    report_sha256::String
    function HeartSnapshot(generation::Int64, child_pid::Union{Nothing,UInt32},
            child_returncode::Union{Nothing,Int32}, alive::Bool, ingress::Ingress,
            placement_validated::Bool, diagnostics_disabled::Bool,
            report_path::AbstractString, report_sha256::AbstractString)
        generation >= 0 || throw(ArgumentError("negative HEART generation"))
        child_pid === nothing || child_pid > 0 || throw(ArgumentError("invalid HEART child PID"))
        path = _checked_string(report_path; empty=true, limit=4096)
        digest = _checked_string(report_sha256; empty=true, limit=64)
        isempty(digest) || occursin(r"^[0-9a-f]{64}$", digest) ||
            throw(ArgumentError("invalid HEART report SHA-256"))
        new(generation, child_pid, child_returncode, alive, ingress,
            placement_validated, diagnostics_disabled, path, digest)
    end
end

struct HeartCompletion
    header::Envelope.ReplyHeader
    lifecycle::HeartLifecycle
    snapshot::Union{Nothing,HeartSnapshot}
    message::String
end
struct HeartRejection
    header::Envelope.ReplyHeader
    lifecycle::HeartLifecycle
    message::String
end

Client.lifecycle_type(::HeartProfile) = HeartLifecycle
Client.completion_type(::HeartProfile) = HeartCompletion
Client.rejection_type(::HeartProfile) = HeartRejection

_struct(fields::Pod...) = SPA.Struct(Pod[fields...])
_fields(value::SPA.Struct) = value.values
function _fields(pod::Pod)
    PipeWireAO.pod_type(pod) == SPA.POD_STRUCT || throw(ArgumentError("expected HEART Struct"))
    return PipeWireAO.pod_value(SPA.Struct, pod).values
end
function _arity(fields, count::Int)
    length(fields) == count || throw(ArgumentError("wrong HEART field arity"))
    return fields
end
function _scalar(pod::Pod, type::UInt32, ::Type{T}) where T
    PipeWireAO.pod_type(pod) == type || throw(ArgumentError("wrong HEART scalar POD type"))
    width = type == SPA.POD_BOOL ? 4 : sizeof(T)
    sizeof(pod) == 8 + width || throw(ArgumentError("wrong HEART scalar POD width"))
    return PipeWireAO.pod_value(T, pod)
end
_int(pod) = _scalar(pod, SPA.POD_INT, Int32)
_long(pod) = _scalar(pod, SPA.POD_LONG, Int64)
_id(pod) = _scalar(pod, SPA.POD_ID, SPA.Id).value
_bool(pod) = _scalar(pod, SPA.POD_BOOL, Bool)
function _string(pod; empty::Bool=false, limit::Int=8192)
    PipeWireAO.pod_type(pod) == SPA.POD_STRING || throw(ArgumentError("expected HEART String POD"))
    return _checked_string(PipeWireAO.pod_value(String, pod); empty, limit)
end
function _checked_string(value::AbstractString; empty::Bool=false, limit::Int)
    (empty || !isempty(value)) && ncodeunits(value) <= limit && !occursin('\0', value) && isvalid(value) ||
        throw(ArgumentError("invalid or oversized HEART string"))
    return String(value)
end
function _enum(::Type{T}, pod, label) where {T<:Enum}
    value = try T(_id(pod)) catch; throw(ArgumentError("unknown HEART $label Id")) end
    return value
end

function _validate_snapshot(state::HeartLifecycle, snapshot::HeartSnapshot)
    if state === Ready
        snapshot.generation >= 1 && snapshot.alive && snapshot.child_pid !== nothing &&
            snapshot.child_returncode === nothing && !isempty(snapshot.report_path) &&
            !isempty(snapshot.report_sha256) ||
            throw(ArgumentError("invalid Ready HEART snapshot"))
    end
    return snapshot
end

function _snapshot_pod(snapshot::HeartSnapshot)
    return _struct(Pod(snapshot.generation),
        snapshot.child_pid === nothing ? Pod(nothing) : Pod(SPA.Id(snapshot.child_pid)),
        snapshot.child_returncode === nothing ? Pod(nothing) : Pod(snapshot.child_returncode),
        Pod(snapshot.alive), Pod(SPA.Id(UInt32(snapshot.ingress))),
        Pod(snapshot.placement_validated), Pod(snapshot.diagnostics_disabled),
        Pod(snapshot.report_path), Pod(snapshot.report_sha256))
end
function _decode_snapshot(state::HeartLifecycle, pod::Pod)
    f = _arity(_fields(pod), 9)
    pid = if PipeWireAO.pod_type(f[2]) == SPA.POD_NONE
        sizeof(f[2]) == 8 || throw(ArgumentError("wrong HEART None width")); nothing
    else
        _id(f[2])
    end
    rc = if PipeWireAO.pod_type(f[3]) == SPA.POD_NONE
        sizeof(f[3]) == 8 || throw(ArgumentError("wrong HEART None width")); nothing
    else
        _int(f[3])
    end
    snap = HeartSnapshot(_long(f[1]), pid, rc, _bool(f[4]), _enum(Ingress, f[5], "ingress"),
        _bool(f[6]), _bool(f[7]), _string(f[8]; empty=true, limit=4096),
        _string(f[9]; empty=true, limit=64))
    return _validate_snapshot(state, snap)
end

function Client.encode_request(profile::HeartProfile, header::Envelope.RequestHeader,
        command::HeartCommand{O}) where O
    op = Client.operation_id(profile, command)
    header.operation == op || throw(ArgumentError("HEART header/command operation mismatch"))
    return Envelope.encode_request(header, _struct())
end
function Client.decode_request(::HeartProfile, header::Envelope.RequestHeader, payload::SPA.Struct)
    isempty(payload.values) || throw(ArgumentError("HEART operation payload must be empty"))
    for (operation, id) in OPERATIONS
        header.operation == id && return HeartCommand{operation}()
    end
    throw(ArgumentError("unknown HEART operation Id"))
end
function Client.decode_request(profile::HeartProfile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_request(input)
    return header, Client.decode_request(profile, header, payload)
end

function Client.encode_completion(::HeartProfile, header::Envelope.ReplyHeader,
        lifecycle::HeartLifecycle, snapshot::Union{Nothing,HeartSnapshot}, message::AbstractString)
    text = _checked_string(message; empty=true, limit=8192)
    if snapshot === nothing
        header.result < 0 || throw(ArgumentError("successful HEART completion requires a snapshot"))
    else
        _validate_snapshot(lifecycle, snapshot)
    end
    body = snapshot === nothing ? Pod(nothing) : Pod(_snapshot_pod(snapshot))
    payload = _struct(Pod(SPA.Id(UInt32(lifecycle))), body, Pod(text))
    return Envelope.encode_completion(header, payload; endpoint=:lifecycle)
end
function Client.decode_completion(::HeartProfile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_completion(input; endpoint=:lifecycle)
    header.controller === nothing && throw(ArgumentError("initial sentinel is not a HEART completion"))
    any(pair -> last(pair) == header.operation, OPERATIONS) || throw(ArgumentError("unknown HEART completion operation"))
    f = _arity(payload.values, 3)
    state = _enum(HeartLifecycle, f[1], "lifecycle")
    snapshot = if PipeWireAO.pod_type(f[2]) == SPA.POD_NONE
        sizeof(f[2]) == 8 && header.result < 0 ||
            throw(ArgumentError("absent HEART snapshot requires a failed completion"))
        nothing
    else
        _decode_snapshot(state, f[2])
    end
    message = _string(f[3]; empty=true, limit=8192)
    return HeartCompletion(header, state, snapshot, message)
end
function Client.encode_rejection(::HeartProfile, header::Envelope.ReplyHeader,
        lifecycle::HeartLifecycle)
    return Envelope.encode_rejection(header,
        _struct(Pod(SPA.Id(UInt32(lifecycle))), Pod("request rejected")); endpoint=:lifecycle)
end
function Client.decode_rejection(::HeartProfile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_rejection(input; endpoint=:lifecycle)
    f = _arity(payload.values, 2)
    state = _enum(HeartLifecycle, f[1], "lifecycle")
    return HeartRejection(header, state, _string(f[2]; empty=true, limit=8192))
end
function Client.encode_failure(profile::HeartProfile, header::Envelope.ReplyHeader,
        lifecycle::HeartLifecycle)
    return Client.encode_completion(profile, header, lifecycle, nothing,
        "request expired or controller removed")
end

end # module NativeHeartCodec
