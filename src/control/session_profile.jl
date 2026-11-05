"""Direct session profile binding for the shared serialized native control client."""
module SessionProfile

using PipeWireAO
import ..ControlClient
import ..SessionCodec

const Codec = SessionCodec
const CAP_NAMES = (
    "pipewireao.rtc.session.version", "pipewireao.rtc.session.instance",
    "pipewireao.rtc.session.owner-pid", "pipewireao.rtc.session.lifecycle",
    "pipewireao.rtc.session.last-token", "pipewireao.rtc.session.controllers",
)

struct Profile <: ControlClient.Profile end
ControlClient.profile_name(::Profile) = Codec.PROFILE
ControlClient.capability_names(::Profile) = CAP_NAMES
ControlClient.lifecycle_type(::Profile) = Codec.Lifecycle
ControlClient.completion_type(::Profile) = Union{Codec.Completion,Codec.AdministrativeCompletion}
ControlClient.rejection_type(::Profile) = Codec.Rejection
ControlClient.decode_completion(::Profile, pod) = Codec.decode_completion(pod)
ControlClient.decode_rejection(::Profile, pod) = Codec.decode_rejection(pod)
ControlClient.operation_id(::Profile, command::Codec.RunnerCommand) = Codec.operation_id(command)
ControlClient.encode_request(::Profile, header, command::Codec.RunnerCommand) =
    Codec.encode_request(header, command)
ControlClient.operation_id(::Profile, command::Union{Codec.WarmupCommand,Codec.AdmitCommand}) =
    Codec.operation_id(command)
ControlClient.encode_request(::Profile, header,
        command::Union{Codec.WarmupCommand,Codec.AdmitCommand}) = Codec.encode_request(header, command)

function ControlClient.node_identity(::Profile, properties, previous)
    value = get(properties, "pipewireao.rtc.session.session-uuid", nothing)
    _session_uuid(value)
    previous === nothing || previous == value ||
        throw(ArgumentError("direct session UUID changed"))
    return String(value)
end
_session_uuid(value) = throw(ArgumentError("invalid direct session UUID metadata"))
function _session_uuid(value::AbstractString)
    occursin(
        r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", value) &&
        value != "00000000-0000-0000-0000-000000000000" ||
        throw(ArgumentError("invalid direct session UUID metadata"))
    return value
end

export Profile

end # module SessionProfile
