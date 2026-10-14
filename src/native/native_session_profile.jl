"""Direct session profile binding for the shared serialized native control client."""
module NativeSessionProfile

using PipeWireAO
import ..NativeControlClient
import ..NativeSessionCodec

const Codec = NativeSessionCodec
const CAP_NAMES = (
    "pipewireao.rtc.session.version", "pipewireao.rtc.session.instance",
    "pipewireao.rtc.session.owner-pid", "pipewireao.rtc.session.lifecycle",
    "pipewireao.rtc.session.last-token", "pipewireao.rtc.session.controllers",
)

struct Profile <: NativeControlClient.Profile end
NativeControlClient.profile_name(::Profile) = Codec.PROFILE
NativeControlClient.capability_names(::Profile) = CAP_NAMES
NativeControlClient.lifecycle_type(::Profile) = Codec.Lifecycle
NativeControlClient.completion_type(::Profile) = Union{Codec.Completion,Codec.AdministrativeCompletion}
NativeControlClient.rejection_type(::Profile) = Codec.Rejection
NativeControlClient.decode_completion(::Profile, pod) = Codec.decode_completion(pod)
NativeControlClient.decode_rejection(::Profile, pod) = Codec.decode_rejection(pod)
NativeControlClient.operation_id(::Profile, command::Codec.RunnerCommand) = Codec.operation_id(command)
NativeControlClient.encode_request(::Profile, header, command::Codec.RunnerCommand) =
    Codec.encode_request(header, command)
NativeControlClient.operation_id(::Profile, command::Union{Codec.WarmupCommand,Codec.AdmitCommand}) =
    Codec.operation_id(command)
NativeControlClient.encode_request(::Profile, header,
        command::Union{Codec.WarmupCommand,Codec.AdmitCommand}) = Codec.encode_request(header, command)

function NativeControlClient.node_identity(::Profile, properties, previous)
    value = get(properties, "pipewireao.rtc.session.session-uuid", nothing)
    value isa AbstractString && occursin(
        r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", value) &&
        value != "00000000-0000-0000-0000-000000000000" ||
        throw(ArgumentError("invalid direct session UUID metadata"))
    previous === nothing || previous == value ||
        throw(ArgumentError("direct session UUID changed"))
    return String(value)
end

export Profile

end # module NativeSessionProfile
