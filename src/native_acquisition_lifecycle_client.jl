"""Exact private-core caller for a calibration or correction lifecycle owner."""
module NativeAcquisitionLifecycleClient

using PipeWireAO: with_thread_loop_lock
import ..NativeControlClient
import ..NativeAcquisitionLifecycleCodec

const Client = NativeControlClient
const Codec = NativeAcquisitionLifecycleCodec
const Profile = Codec.Profile

export Connection, connect, connect_owner!, status, request!

struct Connection{P<:Profile,C<:Client.Client}
    profile::P
    client::C
    instrument::Codec.Instrument
end

function _checked(connection::Connection, reply)
    if reply isa Codec.Completion && reply.snapshot !== nothing
        if reply.snapshot.instrument !== connection.instrument
            with_thread_loop_lock(connection.client.loop) do _
                Client.fail!(connection.client.observation, "acquisition owner instrument changed")
            end
            throw(Client.UnknownOutcome("acquisition owner instrument changed"))
        end
    end
    return reply
end

"""Send one typed operation through the bound owner incarnation, without retry."""
function request!(connection::Connection, operation::Symbol;
        deadline::Float64, check=()->nothing)
    return _checked(connection, Client.request!(connection.client,
        Codec.LifecycleCommand(operation); deadline, check))
end

_snapshot_detail(reply::Codec.Completion) = reply.snapshot === nothing ? "absent" : "present"
_snapshot_detail(::Codec.Rejection) = "rejection"

function _reply_failure(context, reply::Union{Codec.Completion,Codec.Rejection})
    header = reply.header
    error("$context (result=$(header.result), lifecycle=$(reply.lifecycle), " *
        "instance=$(header.endpoint_instance), token=$(header.token), operation=$(header.operation), " *
        "snapshot=$(_snapshot_detail(reply))): message=$(repr(reply.message))")
end

function _require_status(reply::Codec.Completion)
    reply.header.result == 0 && reply.snapshot !== nothing ||
        _reply_failure("acquisition lifecycle status was not successful", reply)
    return reply
end
_require_status(reply::Codec.Rejection) =
    _reply_failure("acquisition lifecycle status was not successful", reply)

function _require_ready(reply::Codec.Completion)
    reply.lifecycle in (Codec.Prepared, Codec.Connected) ||
        _reply_failure("acquisition owner changed readiness during discovery", reply)
    return reply
end

function _require_connected(reply::Codec.Completion)
    reply.header.result == 0 && reply.lifecycle === Codec.Connected && reply.snapshot !== nothing ||
        _reply_failure("acquisition owner Connect did not complete", reply)
    return reply
end
_require_connected(reply::Codec.Rejection) =
    _reply_failure("acquisition owner Connect did not complete", reply)

"""Return a fresh successful status completion from this exact owner."""
function status(connection::Connection; deadline::Float64, check=()->nothing)
    reply = request!(connection, :status; deadline, check)
    return _require_status(reply)
end

"""Discover Prepared or Connected, then require a fresh matching Status result."""
function connect(profile::P, remote::AbstractString, node::AbstractString,
        pid::Integer, instance::Integer, instrument::Codec.Instrument;
        deadline::Float64, check=()->nothing) where {P<:Profile}
    client = Client.connect(profile, remote, node, pid, instance; deadline, check)
    connection = Connection(profile, client, instrument)
    try
        Client.poll(client, deadline, check) do
            capability = client.observation.capability
            capability === nothing && return false
            capability.lifecycle === Codec.Preparing && return false
            capability.lifecycle in (Codec.Prepared, Codec.Connected) ||
                error("acquisition owner preparation failed")
            return true
        end
        reply = status(connection; deadline, check)
        _require_ready(reply)
        return connection
    catch primary
        try close(connection) catch cleanup; throw(CompositeException([primary, cleanup])) end
        rethrow()
    end
end

"""Apply Connect and require a truthful Connected completion."""
function connect_owner!(connection::Connection; deadline::Float64, check=()->nothing)
    reply = request!(connection, :connect; deadline, check)
    return _require_connected(reply)
end

Base.close(connection::Connection) = close(connection.client)

end # module NativeAcquisitionLifecycleClient
