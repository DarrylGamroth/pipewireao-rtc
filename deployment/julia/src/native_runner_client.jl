"""Runner profile for the shared serialized native owner connection."""
module NativeRunnerClient

using PipeWireAO
import ..NativeControlCodec
import ..NativeRunnerCodec
import ..NativeControlClient
import ..NativeControlClient: Client, Observation, Capability, ObservedReply,
    UnknownOutcome, next_instance, fail!, scalar, scalar_id, scalar_long,
    capability, same_request, observe!, matching_reply, private_remote,
    deadline_check, serial, candidate, healthy, poll, node_info!, request!, monotonic

const Envelope = NativeControlCodec
const Codec = NativeRunnerCodec
const SPA = PipeWireAO.SPA
const PROTOCOL = NativeControlClient.PROTOCOL
const PROFILE = "pipewireao.rtc.runner/1"
const CONTROLLER_PROFILE = NativeControlClient.CONTROLLER_PROFILE
const MAX_REPLY = 64 * 1024
const CAP_NAMES = (
    "pipewireao.rtc.runner.version", "pipewireao.rtc.runner.instance",
    "pipewireao.rtc.runner.owner-pid", "pipewireao.rtc.runner.lifecycle",
    "pipewireao.rtc.runner.last-token", "pipewireao.rtc.runner.controllers",
)

struct RunnerProfile <: NativeControlClient.Profile end
NativeControlClient.profile_name(::RunnerProfile) = PROFILE
NativeControlClient.capability_names(::RunnerProfile) = CAP_NAMES
NativeControlClient.lifecycle_type(::RunnerProfile) = Codec.Lifecycle
NativeControlClient.completion_type(::RunnerProfile) = Codec.Completion
NativeControlClient.rejection_type(::RunnerProfile) = Codec.Rejection
NativeControlClient.decode_completion(::RunnerProfile, pod) = Codec.decode_completion(pod)
NativeControlClient.decode_rejection(::RunnerProfile, pod) = Codec.decode_rejection(pod)
NativeControlClient.operation_id(::RunnerProfile, command::Codec.RunnerCommand) = Codec.operation_id(command)
NativeControlClient.encode_request(::RunnerProfile, header, command::Codec.RunnerCommand) = Codec.encode_request(header, command)

# Preserve the existing runner-facing constructors and function identities.
NativeControlClient.Observation(instance::Int64, pid::UInt32) = Observation(RunnerProfile(), instance, pid)
connect(args...; kwargs...) = NativeControlClient.connect(RunnerProfile(), args...; kwargs...)

export Client, connect, request!, UnknownOutcome

end # module NativeRunnerClient
