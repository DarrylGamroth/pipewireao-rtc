"""Explicit native verification and a retained connection to one listed RTC session."""
module SessionClient
import Clocks

using PipeWireAO: with_thread_loop_lock
import ..SessionDiscovery
import ..ControlClient
import ..RunnerCodec
import ..SessionCodec
import ..SessionProfile
import ..RunnerCommands

export Connection, select_session, select_direct_session, request!, lifecycle, render_direct

const Discovery = SessionDiscovery
const Runner = RunnerCodec
const Session = SessionCodec

"A verified listing and the exact native client used to verify it."
struct Connection{C}
    selected::Discovery.SelectedSession
    client::C
end
Base.close(connection::Connection) = close(connection.client)

"""
    lifecycle(completion)

Return the direct session lifecycle without projecting it through a runner wrapper.
"""
function lifecycle(completion::Session.Completion)
    completion.header.result == 0 || throw(ArgumentError("native session Status failed"))
    completion.header.operation == UInt32(3) ||
        throw(ArgumentError("session lifecycle requires a Status completion"))
    return Symbol(lowercase(string(completion.lifecycle)))
end

function _fresh_session_status(record::Discovery.SessionRecord, client, completion)
    completion.header.operation == UInt32(3) && completion.header.result == 0 || throw(
        ArgumentError("session selection requires a successful fresh Status completion")
    )
    state = lifecycle(completion)
    return with_thread_loop_lock(client.loop) do _
        ControlClient.healthy(client)
        Discovery.FreshSessionStatus(
            client.observation.node_identity,
            client.observation.owner_pid,
            client.observation.instance,
            record.remote,
            client.node_name,
            client.global_id,
            client.serial,
            completion.header.token,
            state,
            :rtc_session,
        )
    end
end

"""
    select_session(entry; kwargs...)

Select the exact RTC session and retain its binding.
"""
select_session(entry::Discovery.DiscoveryEntry; kwargs...) =
    select_direct_session(entry; kwargs...)

"""
    select_direct_session(entry; deadline, check=()->nothing, clock=Clocks.SystemNanoClock())

Select an RTC session using only the direct native session profile.
"""
function select_direct_session(
    entry::Discovery.DiscoveryEntry;
    deadline::Union{Int64,Float64},
    check = () -> nothing,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    entry.record === nothing && return Discovery.DiscoveryEntry(
        nothing, Discovery.Malformed, "record cannot be selected"
    )
    entry.verification === Discovery.Unverified || return entry
    record = entry.record
    client = nothing
    try
        client = ControlClient.connect(
            SessionProfile.Profile(),
            record.remote,
            record.node_name,
            record.owner_pid,
            record.incarnation;
            deadline,
            check,
            clock,
        )
        completion = ControlClient.request!(
            client, Session.RunnerCommand(:status); deadline, check
        )
        fresh = _fresh_session_status(record, client, completion)
        selected = Discovery.select_session(entry, _ -> fresh)
        return _retain(selected, client)
    catch error
        client === nothing || close(client)
        return _discovery_failure(record, error)
    end
end

_discovery_failure(record, error::InterruptException) = throw(error)
_discovery_failure(record, error) =
    Discovery.DiscoveryEntry(record, Discovery.Inaccessible, sprint(showerror, error))

_retain(selected::Discovery.SelectedSession, client) = Connection(selected, client)
function _retain(failure::Discovery.DiscoveryEntry, client)
    close(client)
    return failure
end

"""
    request!(connection, command; kwargs...)

Send an operator command on the retained, verified endpoint.
"""
request!(connection::Connection, command::Runner.RunnerCommand; kwargs...) =
    ControlClient.request!(connection.client, command; kwargs...)

"""
    render_direct(connection, reply)

Render a direct typed reply with the selected session UUID, without supervisor fields.
"""
function render_direct(
    connection::Connection, reply::Union{Session.Completion,Session.Rejection}
)
    selected = connection.selected
    reply.header.endpoint_instance == selected.status.incarnation ||
        throw(ArgumentError("direct reply came from a different endpoint incarnation"))
    result = RunnerCommands.render(reply)
    result["session_id"] = selected.status.session_id
    result["authority"] = "rtc_session"
    result["owner_pid"] = selected.status.owner_pid
    return result
end

end # module SessionClient
