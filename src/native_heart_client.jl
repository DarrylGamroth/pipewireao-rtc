"""Native wrapper authority and verified saved HEART generation reports."""
module NativeHeartClient

using PipeWireAO, SHA, JSON3
import ..NativeControlClient
import ..NativeHeartCodec

const Client = NativeControlClient
const Codec = NativeHeartCodec

function status(client::Client.Client; deadline::Float64, check=()->nothing)
    reply = Client.request!(client, Codec.HeartCommand(:status); deadline, check)
    reply.header.result == 0 && reply.lifecycle === Codec.Ready && reply.snapshot !== nothing ||
        error("HEART wrapper did not provide a successful Ready snapshot: $(reply.message)")
    return reply.snapshot
end

function connect(remote, node, pid, instance; deadline::Float64, check=()->nothing)
    client = Client.connect(Codec.HEART_PROFILE, remote, node, pid, instance; deadline, check)
    try
        Client.poll(client, deadline, check) do
            capability = client.observation.capability
            capability === nothing && return false
            capability.lifecycle === Codec.Preparing && return false
            capability.lifecycle === Codec.Ready || error("HEART wrapper preparation failed")
            return true
        end
        status(client; deadline, check)
        return client
    catch primary
        try
            close(client)
        catch cleanup
            throw(CompositeException([primary, cleanup]))
        end
        rethrow()
    end
end

"Acknowledge the prepared wrapper connection without changing scientific state."
function connect!(client::Client.Client; deadline::Float64, check=()->nothing)
    reply = Client.request!(client, Codec.HeartCommand(:connect); deadline, check)
    reply.header.result == 0 && reply.lifecycle === Codec.Ready && reply.snapshot !== nothing ||
        error("HEART wrapper connection did not complete: $(reply.message)")
    return reply.snapshot
end

"Stop the owned child once and return its terminal native snapshot."
function shutdown!(client::Client.Client; deadline::Float64, check=()->nothing)
    reply = Client.request!(client, Codec.HeartCommand(:shutdown); deadline, check)
    reply.header.result == 0 && reply.lifecycle === Codec.Stopped && reply.snapshot !== nothing &&
        !reply.snapshot.alive || error("HEART wrapper shutdown did not complete: $(reply.message)")
    return reply.snapshot
end

function reset!(client::Client.Client, previous::Codec.HeartSnapshot;
        deadline::Float64, check=()->nothing)
    reply = Client.request!(client, Codec.HeartCommand(:reset); deadline, check)
    reply.header.result == 0 && reply.lifecycle === Codec.Ready && reply.snapshot !== nothing ||
        error("HEART wrapper reset did not complete: $(reply.message)")
    current = reply.snapshot
    current.generation == previous.generation + 1 && current.child_pid != previous.child_pid ||
        error("HEART wrapper reset did not replace the declared child generation")
    return current
end

"Check subscribed native authority without reading a mutable status file."
function require_ready(client::Client.Client, expected::Codec.HeartSnapshot)
    return with_thread_loop_lock(client.loop) do _
        client.closed && error("HEART control client closed")
        isrunning(client.loop) || error("HEART control loop stopped")
        observation = client.observation
        observation.failure === nothing || throw(Client.UnknownOutcome(observation.failure))
        capability = observation.capability
        capability !== nothing && capability.lifecycle === Codec.Ready ||
            error("HEART wrapper is not Ready")
        completion = observation.completion
        completion !== nothing && completion.value.snapshot !== nothing ||
            throw(Client.UnknownOutcome("current HEART child identity is unavailable; fresh status is required"))
        current = completion.value.snapshot
        current.generation == expected.generation && current.child_pid == expected.child_pid &&
            current.alive && current.ingress === expected.ingress ||
            error("HEART child generation, health or ingress changed")
        return nothing
    end
end

"Read one saved report whose bytes are bound by a fresh native completion."
function generation_report(client::Client.Client, root::AbstractString;
        deadline::Float64, check=()->nothing)
    snapshot = status(client; deadline, check)
    expected = joinpath(realpath(root), "heart-generation-$(snapshot.generation).json")
    snapshot.report_path == expected && !islink(expected) && isfile(expected) ||
        error("HEART generation report is outside the declared owner runtime")
    bytes = open(expected) do io
        read(io, 64 * 1024 + 1)
    end
    length(bytes) <= 64 * 1024 || error("HEART generation report exceeds its bound")
    bytes2hex(sha256(bytes)) == snapshot.report_sha256 ||
        error("HEART generation report digest changed")
    report = JSON3.read(String(bytes))
    get(report, :generation, nothing) == snapshot.generation &&
        get(report, :child_pid, nothing) == snapshot.child_pid &&
        get(report, :owner_pid, nothing) == client.observation.owner_pid ||
        error("HEART generation report identity differs from the native snapshot")
    require_ready(client, snapshot)
    return snapshot, report
end

end # module NativeHeartClient
