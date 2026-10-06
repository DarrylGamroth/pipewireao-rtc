"""Explicit native verification and a retained connection to one listed RTC session."""
module NativeSessionClient

using PipeWireAO: with_thread_loop_lock
import ..NativeSessionDiscovery
import ..NativeSupervisorClient
import ..NativeSupervisorCodec
import ..NativeControlClient
import ..NativeRunnerCodec

const Discovery = NativeSessionDiscovery
const Public = NativeSupervisorClient
const Codec = NativeSupervisorCodec
const Runner = NativeRunnerCodec

export Connection, select_session, request!, lifecycle

"A verified listing and the exact native client used to verify it."
struct Connection{C}
    selected::Discovery.SelectedSession
    client::C
end
Base.close(connection::Connection) = close(connection.client)

"Discovery lifecycle is derived only from the freshly queried supervisor and runner."
function lifecycle(completion::Codec.Completion)
    completion.header.result == 0 || throw(ArgumentError("native supervisor Status failed"))
    phase = completion.lifecycle
    phase === Codec.Preparing && return :preparing
    phase === Codec.Failed && return :fault
    phase in (Codec.Stopping, Codec.Stopped) && return :stopped
    completion.admitted && completion.snapshot !== nothing &&
        completion.snapshot.runner !== nothing ||
        throw(ArgumentError("admitted supervisor Status has no runner"))
    runner = completion.snapshot.runner.status.lifecycle
    runner === Runner.Fault && return :fault
    runner in (Runner.Ready, Runner.Offline) && return :stopped
    runner === Runner.Running && return :ready
    return :preparing
end

function _fresh_status(record::Discovery.SessionRecord, client, completion)
    completion.header.operation == UInt32(3) ||
        throw(ArgumentError("session selection requires a fresh Status completion"))
    return with_thread_loop_lock(client.loop) do _
        NativeControlClient.healthy(client)
        Discovery.FreshSupervisorStatus(Codec.validate_uuid(client.observation.node_identity),
            client.observation.owner_pid, client.observation.instance,
            record.remote, client.node_name, client.global_id, client.serial,
            completion.header.token, lifecycle(completion), :deployment_supervisor)
    end
end

"Connect once, query once, and retain that exact binding for explicit later controls."
function select_session(entry::Discovery.DiscoveryEntry; deadline::Float64,
        check=()->nothing)
    entry.record === nothing && return Discovery.DiscoveryEntry(nothing,
        Discovery.Malformed, "record cannot be selected")
    entry.verification === Discovery.Unverified || return entry
    record = entry.record
    client = nothing
    try
        # Do not supply an expected UUID here: observing a different live UUID
        # allows selection to report Replaced rather than silently rebinding.
        client = Public.connect(record.remote, record.node_name, record.owner_pid,
            record.incarnation; deadline, check)
        completion = Public.request!(client, Runner.RunnerCommand(:status); deadline, check)
        fresh = _fresh_status(record, client, completion)
        selected = Discovery.select_session(entry, _ -> fresh)
        return _retain(selected, client)
    catch error
        client === nothing || close(client)
        error isa InterruptException && rethrow()
        return Discovery.DiscoveryEntry(record, Discovery.Inaccessible, sprint(showerror, error))
    end
end

_retain(selected::Discovery.SelectedSession, client) = Connection(selected, client)
function _retain(failure::Discovery.DiscoveryEntry, client)
    close(client)
    return failure
end

"Send an explicit operator command on the already verified endpoint; never rebind."
request!(connection::Connection, command::Runner.RunnerCommand; kwargs...) =
    Public.request!(connection.client, command; kwargs...)

end # module NativeSessionClient
