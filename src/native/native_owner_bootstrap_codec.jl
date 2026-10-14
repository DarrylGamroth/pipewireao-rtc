"""Bounded native bootstrap for ordinary source and external graph owners."""
module NativeOwnerBootstrapCodec
using PipeWireAO
import ..NativeControlCodec
import ..NativeControlClient
const Envelope = NativeControlCodec
const Client = NativeControlClient
const SPA = PipeWireAO.SPA
export Profile, PROFILE, Lifecycle, Preparing, Prepared, Connected, Fault, Stopped,
    Command, Completion, Rejection
struct Profile <: Client.Profile end
const PROFILE = Profile()
Client.profile_name(::Profile) = "pipewireao.rtc.owner-bootstrap/1"
Client.capability_names(::Profile) = Tuple("pipewireao.rtc.owner-bootstrap." * suffix for suffix in
    ("version", "instance", "owner-pid", "lifecycle", "last-token", "controllers"))
@enum Lifecycle::UInt32 Preparing=1 Prepared=2 Connected=3 Fault=4 Stopped=5
struct Command{O} end
const OPERATIONS = ((:status, UInt32(1)), (:connect, UInt32(2)), (:quit, UInt32(3)))
function Command(operation::Symbol)
    any(pair -> first(pair) === operation, OPERATIONS) || throw(ArgumentError("unknown bootstrap operation"))
    return Command{operation}()
end
function Client.operation_id(::Profile, ::Command{O}) where O
    for (name, id) in OPERATIONS
        O === name && return id
    end
    throw(ArgumentError("unknown bootstrap operation"))
end
struct Completion
    header::Envelope.ReplyHeader
    lifecycle::Lifecycle
    message::String
end
struct Rejection
    header::Envelope.ReplyHeader
    lifecycle::Lifecycle
    message::String
end
Client.lifecycle_type(::Profile) = Lifecycle
Client.completion_type(::Profile) = Completion
Client.rejection_type(::Profile) = Rejection
_struct(fields::Pod...) = SPA.Struct(Pod[fields...])
function _message(value::AbstractString)
    isvalid(value) && ncodeunits(value) <= 8192 && !occursin('\0', value) ||
        throw(ArgumentError("invalid or oversized bootstrap message"))
    return String(value)
end
function _payload(payload::SPA.Struct)
    length(payload.values) == 2 || throw(ArgumentError("wrong bootstrap reply arity"))
    state, message = payload.values
    pod_type(state) == SPA.POD_ID && sizeof(state) == 12 || throw(ArgumentError("wrong bootstrap lifecycle type or width"))
    lifecycle = try Lifecycle(pod_value(SPA.Id, state).value) catch
        throw(ArgumentError("unknown bootstrap lifecycle"))
    end
    pod_type(message) == SPA.POD_STRING || throw(ArgumentError("wrong bootstrap message type"))
    return lifecycle, _message(pod_value(String, message))
end
function Client.encode_request(profile::Profile, header::Envelope.RequestHeader, command::Command)
    header.operation == Client.operation_id(profile, command) || throw(ArgumentError("bootstrap header/command mismatch"))
    return Envelope.encode_request(header, _struct())
end
function Client.decode_request(::Profile, header::Envelope.RequestHeader, payload::SPA.Struct)
    isempty(payload.values) || throw(ArgumentError("bootstrap requests require empty Struct"))
    for (name, id) in OPERATIONS
        header.operation == id && return Command{name}()
    end
    throw(ArgumentError("unknown bootstrap operation"))
end
function Client.decode_request(profile::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_request(input)
    return header, Client.decode_request(profile, header, payload)
end
function _operation(header)
    any(pair -> last(pair) == header.operation, OPERATIONS) || throw(ArgumentError("unknown bootstrap completion operation"))
end
function Client.encode_completion(::Profile, header::Envelope.ReplyHeader, lifecycle::Lifecycle, message::AbstractString)
    _operation(header)
    header.result == 0 && header.operation == 2 && lifecycle !== Connected &&
        throw(ArgumentError("successful Connect requires Connected"))
    header.result == 0 && header.operation == 3 && lifecycle !== Stopped &&
        throw(ArgumentError("successful Quit requires Stopped"))
    return Envelope.encode_completion(header, _struct(Pod(SPA.Id(UInt32(lifecycle))), Pod(_message(message))); endpoint=:lifecycle)
end
function Client.decode_completion(profile::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_completion(input; endpoint=:lifecycle)
    header.controller === nothing && throw(ArgumentError("initial sentinel is not a bootstrap completion"))
    _operation(header)
    lifecycle, message = _payload(payload)
    Client.encode_completion(profile, header, lifecycle, message)
    return Completion(header, lifecycle, message)
end
Client.encode_rejection(::Profile, header::Envelope.ReplyHeader, lifecycle::Lifecycle) =
    Envelope.encode_rejection(header, _struct(Pod(SPA.Id(UInt32(lifecycle))), Pod("request rejected")); endpoint=:lifecycle)
function Client.decode_rejection(::Profile, input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_rejection(input; endpoint=:lifecycle)
    return Rejection(header, _payload(payload)...)
end
Client.encode_failure(profile::Profile, header::Envelope.ReplyHeader, lifecycle::Lifecycle) =
    Client.encode_completion(profile, header, lifecycle, "request expired or controller removed")
end
