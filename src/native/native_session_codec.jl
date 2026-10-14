"""Direct WirePlumber profile with private one-shot admission operations."""
module NativeSessionCodec

using PipeWireAO
import ..NativeRunnerCodec
import ..NativeControlCodec

const PROFILE = "pipewireao.rtc.session/1"
const Runner = NativeRunnerCodec
const Envelope = NativeControlCodec
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod

export PROFILE, RunnerCommand, RunnerScalar, RunnerResult, RunnerError, Completion,
    Rejection, Lifecycle, Outcome, GroupState, WarmupCommand, AdmitCommand,
    AdministrativeCompletion, operation_id, encode_request, decode_completion,
    decode_rejection

const RunnerCommand = Runner.RunnerCommand
const RunnerScalar = Runner.RunnerScalar
const RunnerResult = Runner.RunnerResult
const RunnerError = Runner.RunnerError
const Completion = Runner.Completion
const Rejection = Runner.Rejection
const Lifecycle = Runner.Lifecycle
const Outcome = Runner.Outcome
const GroupState = Runner.GroupState

"Read-only query that retains Configuring while WirePlumber warms the session."
struct WarmupCommand end
"One-shot transition to Ready after the external placement check."
struct AdmitCommand end

struct AdministrativeCompletion
    header::Envelope.ReplyHeader
    lifecycle::Lifecycle
    warmed::Union{Nothing,Bool}
    error::Union{Nothing,RunnerError}
end

operation_id(command::RunnerCommand) = Runner.operation_id(command)
operation_id(::WarmupCommand) = UInt32(15)
operation_id(::AdmitCommand) = UInt32(16)

encode_request(header::Envelope.RequestHeader, command::RunnerCommand) =
    Runner.encode_request(header, command)
function encode_request(header::Envelope.RequestHeader,
                        command::Union{WarmupCommand,AdmitCommand})
    header.operation == operation_id(command) ||
        throw(ArgumentError("administrative request operation differs from command"))
    return Envelope.encode_request(header, SPA.Struct(Pod[]))
end

function decode_completion(input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_completion(input; endpoint=:lifecycle)
    header.operation in (15, 16) || return Runner.decode_completion(input)
    header.controller !== nothing ||
        throw(ArgumentError("administrative completion needs correlated header"))
    fields = payload.values
    if header.result < 0
        error, state = Runner._error(fields)
        return AdministrativeCompletion(header, state, nothing, error)
    end
    header.result == 0 || throw(ArgumentError("invalid administrative result code"))
    length(fields) == 2 ||
        throw(ArgumentError("administrative completion needs lifecycle and warmed flag"))
    PipeWireAO.pod_type(fields[1]) == SPA.POD_ID && sizeof(fields[1]) == 12 ||
        throw(ArgumentError("administrative lifecycle must be an Id"))
    PipeWireAO.pod_type(fields[2]) == SPA.POD_BOOL && sizeof(fields[2]) == 12 ||
        throw(ArgumentError("administrative warmed flag must be a Bool"))
    state = Lifecycle(PipeWireAO.pod_value(SPA.Id, fields[1]).value)
    warmed = PipeWireAO.pod_value(Bool, fields[2])
    header.operation == 16 && (state != Runner.Ready || !warmed) &&
        throw(ArgumentError("admission completion must prove warmed Ready"))
    header.operation == 15 && state != Runner.Configuring &&
        throw(ArgumentError("warmup completion must retain Configuring"))
    return AdministrativeCompletion(header, state, warmed, nothing)
end

decode_rejection(input::Union{Pod,AbstractVector{UInt8}}) = Runner.decode_rejection(input)

end # module NativeSessionCodec
