"""Exact native ordinary-owner binding; no automatic reconnect or retry."""
module OwnerBootstrapClient
import Clocks
import ..ControlClient
import ..OwnerBootstrapCodec

export Binding, Connection, connect, status, request!, connect_owner!, quit!

const Client = ControlClient
const Codec = OwnerBootstrapCodec
struct Binding
    remote::String
    node::String
    owner_pid::UInt32
    instance::Int64
    function Binding(
        remote::AbstractString, node::AbstractString, pid::Integer, instance::Integer
    )
        _check_pid(pid)
        _check_instance(instance)
        path = Client.private_remote(remote)
        occursin(r"^[a-zA-Z0-9_.-]{1,128}$", node) ||
            throw(ArgumentError("invalid bootstrap node name"))
        0 < pid <= typemax(UInt32) || throw(ArgumentError("invalid bootstrap owner PID"))
        0 < instance <= typemax(Int64) || throw(ArgumentError("invalid bootstrap instance"))
        new(path, String(node), UInt32(pid), Int64(instance))
    end
end
_check_pid(::Integer) = nothing
_check_pid(::Bool) = throw(ArgumentError("bootstrap owner PID must not be Bool"))
_check_instance(::Integer) = nothing
_check_instance(::Bool) = throw(ArgumentError("bootstrap instance must not be Bool"))
_require_status(reply) = error("bootstrap Status was not successful")
_require_status(reply::Codec.Completion) =
    reply.header.result == 0 || error("bootstrap Status was not successful")
_require_connected(reply) = error("bootstrap Connect did not complete")
_require_connected(reply::Codec.Completion) =
    reply.header.result == 0 && reply.lifecycle === Codec.Connected ||
    error("bootstrap Connect did not complete")
_require_stopped(reply) = error("bootstrap Quit did not complete")
_require_stopped(reply::Codec.Completion) =
    reply.header.result == 0 && reply.lifecycle === Codec.Stopped ||
    error("bootstrap Quit did not complete")
struct Connection{C<:Client.Client}
    binding::Binding
    client::C
end
"""
    request!(connection, operation; deadline, check=()->nothing)

Send the named bootstrap operation and return the correlated native reply before `deadline`.
"""
request!(
    connection::Connection,
    operation::Symbol;
    deadline::Union{Int64,Float64},
    check = () -> nothing,
) = Client.request!(connection.client, Codec.Command(operation); deadline, check)
"""
    status(connection; deadline, check=()->nothing)

Request and validate a fresh bootstrap status reply.
"""
function status(
    connection::Connection; deadline::Union{Int64,Float64}, check = () -> nothing
)
    reply = request!(connection, :status; deadline, check)
    _require_status(reply)
    return reply
end
"""
    connect(binding; deadline, check=()->nothing, clock=Clocks.SystemNanoClock())

Bind exact PID/incarnation and require fresh Status, including Preparing.
"""
function connect(
    binding::Binding;
    deadline::Union{Int64,Float64},
    check = () -> nothing,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    deadline = Client._deadline_ns(deadline)
    client = Client.connect(
        Codec.PROFILE,
        binding.remote,
        binding.node,
        binding.owner_pid,
        binding.instance;
        deadline,
        check,
        clock,
    )
    connection = Connection(binding, client)
    try
        status(connection; deadline, check)
        return connection
    catch primary
        try
            close(connection)
        catch cleanup
            throw(CompositeException([primary, cleanup]))
        end
        rethrow()
    end
end
function connect(
    remote::AbstractString,
    node::AbstractString,
    pid::Integer,
    instance::Integer;
    deadline::Union{Int64,Float64},
    check = () -> nothing,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    return connect(Binding(remote, node, pid, instance); deadline, check, clock)
end
"""
    connect_owner!(connection; deadline, check=()->nothing)

Wait for the bound owner to reach Prepared, send Connect and return its Connected reply.
"""
function connect_owner!(
    connection::Connection; deadline::Union{Int64,Float64}, check = () -> nothing
)
    deadline = Client._deadline_ns(deadline)
    previous = nothing
    while true
        current = Clocks.time_nanos(connection.client.clock)
        previous === nothing ||
            current >= previous ||
            throw(Client.UnknownOutcome("bootstrap client clock regressed"))
        previous = current
        Client.deadline_check(deadline, check, current)
        reply = status(connection; deadline, check)
        reply.lifecycle === Codec.Prepared && break
        reply.lifecycle === Codec.Preparing ||
            error("bootstrap owner is not Prepared: $(reply.lifecycle): $(reply.message)")
        sleep(min(Client.SUPERVISION_INTERVAL_NS, Client.remaining_ns(deadline, current)) / 1e9)
    end
    reply = request!(connection, :connect; deadline, check)
    _require_connected(reply)
    return reply
end
"""
    quit!(connection; deadline, check=()->nothing)

Send Quit to the bound owner and require a Stopped reply.
"""
function quit!(
    connection::Connection; deadline::Union{Int64,Float64}, check = () -> nothing
)
    reply = request!(connection, :quit; deadline, check)
    _require_stopped(reply)
    return reply
end
Base.close(connection::Connection) = close(connection.client)
end
