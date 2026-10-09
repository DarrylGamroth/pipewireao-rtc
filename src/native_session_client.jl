"""Explicit native verification and a retained connection to one listed RTC session."""
module NativeSessionClient

using PipeWireAO: with_thread_loop_lock
import ..NativeSessionDiscovery
import ..NativeControlClient
import ..NativeRunnerCodec
import ..NativeSessionCodec
import ..NativeSessionProfile
import ..RunnerCommands

const Discovery = NativeSessionDiscovery
const Runner = NativeRunnerCodec
const Session = NativeSessionCodec

export Connection, select_session, select_direct_session, request!, lifecycle,
    render_direct

"A verified listing and the exact native client used to verify it."
struct Connection{C}
    selected::Discovery.SelectedSession
    client::C
end
Base.close(connection::Connection) = close(connection.client)

"Return the direct session lifecycle without projecting it through a runner wrapper."
function lifecycle(completion::Session.Completion)
    completion.header.result == 0 || throw(ArgumentError("native session Status failed"))
    completion.header.operation == UInt32(3) ||
        throw(ArgumentError("session lifecycle requires a Status completion"))
    return Symbol(lowercase(string(completion.lifecycle)))
end

function _fresh_session_status(record::Discovery.SessionRecord, client, completion)
    completion.header.operation == UInt32(3) && completion.header.result == 0 ||
        throw(ArgumentError("session selection requires a successful fresh Status completion"))
    state = lifecycle(completion)
    return with_thread_loop_lock(client.loop) do _
        NativeControlClient.healthy(client)
        Discovery.FreshSessionStatus(client.observation.node_identity,
            client.observation.owner_pid, client.observation.instance,
            record.remote, client.node_name, client.global_id, client.serial,
            completion.header.token, state, :wireplumber_session)
    end
end

"Select only WirePlumber; coordinator fallback and automatic rebinding are forbidden."
select_session(entry::Discovery.DiscoveryEntry; kwargs...) = select_direct_session(entry; kwargs...)

"Select a WirePlumber session using only the direct native session profile."
function select_direct_session(entry::Discovery.DiscoveryEntry; deadline::Float64,
        check=()->nothing)
    entry.record === nothing && return Discovery.DiscoveryEntry(nothing,
        Discovery.Malformed, "record cannot be selected")
    entry.verification === Discovery.Unverified || return entry
    record = entry.record
    client = nothing
    try
        client = NativeControlClient.connect(NativeSessionProfile.Profile(),
            record.remote, record.node_name, record.owner_pid, record.incarnation;
            deadline, check)
        completion = NativeControlClient.request!(client, Session.RunnerCommand(:status);
            deadline, check)
        fresh = _fresh_session_status(record, client, completion)
        selected = Discovery.select_session(entry, _ -> fresh)
        return _retain(selected, client)
    catch error
        client === nothing || close(client)
        error isa InterruptException && rethrow()
        return Discovery.DiscoveryEntry(record, Discovery.Inaccessible,
            sprint(showerror, error))
    end
end

_retain(selected::Discovery.SelectedSession, client) = Connection(selected, client)
function _retain(failure::Discovery.DiscoveryEntry, client)
    close(client)
    return failure
end

"Send an explicit operator command on the already verified endpoint; never rebind."
request!(connection::Connection, command::Runner.RunnerCommand; kwargs...) =
    NativeControlClient.request!(connection.client, command; kwargs...)

"Render a direct typed reply with the selected session UUID, without supervisor fields."
function render_direct(connection::Connection,
        reply::Union{Session.Completion,Session.Rejection})
    selected = connection.selected
    reply.header.endpoint_instance == selected.status.incarnation ||
        throw(ArgumentError("direct reply came from a different endpoint incarnation"))
    result = RunnerCommands.render(reply)
    result["session_id"] = selected.status.session_id
    result["authority"] = "wireplumber_session"
    result["owner_pid"] = selected.status.owner_pid
    return result
end

end # module NativeSessionClient
