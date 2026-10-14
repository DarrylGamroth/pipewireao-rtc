"""Exact native ordinary-owner binding; no automatic reconnect or retry."""
module NativeOwnerBootstrapClient
import ..NativeControlClient
import ..NativeOwnerBootstrapCodec
const Client = NativeControlClient
const Codec = NativeOwnerBootstrapCodec
export Binding, Connection, connect, status, request!, connect_owner!, quit!
struct Binding
    remote::String
    node::String
    owner_pid::UInt32
    instance::Int64
    function Binding(remote::AbstractString, node::AbstractString, pid::Integer, instance::Integer)
        pid isa Bool && throw(ArgumentError("bootstrap owner PID must not be Bool"))
        instance isa Bool && throw(ArgumentError("bootstrap instance must not be Bool"))
        path = Client.private_remote(remote)
        occursin(r"^[a-zA-Z0-9_.-]{1,128}$", node) || throw(ArgumentError("invalid bootstrap node name"))
        0 < pid <= typemax(UInt32) || throw(ArgumentError("invalid bootstrap owner PID"))
        0 < instance <= typemax(Int64) || throw(ArgumentError("invalid bootstrap instance"))
        new(path, String(node), UInt32(pid), Int64(instance))
    end
end
struct Connection{C<:Client.Client}
    binding::Binding
    client::C
end
request!(connection::Connection, operation::Symbol; deadline::Float64, check=()->nothing) =
    Client.request!(connection.client, Codec.Command(operation); deadline, check)
function status(connection::Connection; deadline::Float64, check=()->nothing)
    reply = request!(connection, :status; deadline, check)
    reply isa Codec.Completion && reply.header.result == 0 || error("bootstrap Status was not successful")
    return reply
end
"""Bind exact PID/incarnation and require fresh Status, including Preparing."""
function connect(binding::Binding; deadline::Float64, check=()->nothing)
    Client.deadline_check(deadline, check)
    client = Client.connect(Codec.PROFILE, binding.remote, binding.node,
        binding.owner_pid, binding.instance; deadline, check)
    connection = Connection(binding, client)
    try
        status(connection; deadline, check)
        return connection
    catch primary
        try close(connection) catch cleanup; throw(CompositeException([primary, cleanup])) end
        rethrow()
    end
end
function connect(remote::AbstractString, node::AbstractString, pid::Integer, instance::Integer;
        deadline::Float64, check=()->nothing)
    Client.deadline_check(deadline, check)
    return connect(Binding(remote, node, pid, instance); deadline, check)
end
function connect_owner!(connection::Connection; deadline::Float64, check=()->nothing)
    while true
        reply = status(connection; deadline, check)
        reply.lifecycle === Codec.Prepared && break
        reply.lifecycle === Codec.Preparing || error("bootstrap owner is not Prepared: $(reply.lifecycle): $(reply.message)")
        Client.deadline_check(deadline, check)
        sleep(min(0.005, max(0.0, deadline - Client.monotonic())))
    end
    reply = request!(connection, :connect; deadline, check)
    reply isa Codec.Completion && reply.header.result == 0 && reply.lifecycle === Codec.Connected ||
        error("bootstrap Connect did not complete")
    return reply
end
function quit!(connection::Connection; deadline::Float64, check=()->nothing)
    reply = request!(connection, :quit; deadline, check)
    reply isa Codec.Completion && reply.header.result == 0 && reply.lifecycle === Codec.Stopped ||
        error("bootstrap Quit did not complete")
    return reply
end
Base.close(connection::Connection) = close(connection.client)
end
