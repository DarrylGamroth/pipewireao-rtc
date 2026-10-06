"""Inactive public endpoint owned and serviced by the existing DeploymentRunner."""
module NativeSupervisorRuntime

using PipeWireAO, UUIDs
import ..NativeControlCodec
import ..NativeControlClient
import ..NativeControlEndpoint
import ..NativeSupervisorCodec

const Envelope = NativeControlCodec
const Client = NativeControlClient
const Endpoint = NativeControlEndpoint
const Codec = NativeSupervisorCodec
const Profile = Codec.SupervisorProfile
import ..NativeRunnerCodec
const Commands = NativeRunnerCodec.RunnerCommand
const POLL_SECONDS = 0.005

export Runtime, has_pending, poll!, take!, lifecycle!, complete!, flush_terminal!

mutable struct Runtime{P<:Profile,C,E,L}
    profile::P
    uuid::String
    loop::ThreadLoop
    context::Context
    core::C
    endpoint::E
    registry_listener::L
    acknowledged_sequence::Base.RefValue{Cint}
    wake::Base.Threads.Atomic{Bool}
    closed::Bool
    dispatching::Bool
end

"""Publish Preparing before the existing owner prepares its science or plant."""
function Runtime(profile::P, remote::AbstractString, name::AbstractString,
        instance::Int64) where {P<:Profile}
    path = Client.private_remote(remote)
    uuid = string(uuid4())
    loop = ThreadLoop("rtc.deployment.supervisor")
    context = core = endpoint = registry_listener = nothing
    endpoint_ref = Ref{Union{Nothing,Endpoint.Endpoint}}(nothing)
    acknowledged_sequence = Ref{Cint}(-1)
    wake = Base.Threads.Atomic{Bool}(false)
    connection_failure = Ref{Union{Nothing,String}}(nothing)
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => path),
                on_done=(core, id, sequence) -> begin
                    id == 0 && (acknowledged_sequence[] = sequence)
                    nothing
                end,
                on_error=(core, id, sequence, error) -> begin
                    connection_failure[] = sprint(showerror, error)
                    current = endpoint_ref[]
                    current === nothing || (current.failure = connection_failure[])
                    wake[] = true
                    nothing
                end)
            endpoint = Endpoint.Endpoint(profile, Commands, loop, core,
                name, instance, Codec.Preparing;
                properties_extra=Dict(Codec.UUID_PROPERTY=>uuid),
                publisher=(filter, params) -> begin
                    wake[] = true
                    update_params!(filter, params)
                end)
            registry_listener = add_listener!(something(endpoint.registry);
                on_global_added=(registry, global_object) -> (wake[] = true; nothing),
                on_global_removed=(registry, id) -> (wake[] = true; nothing))
            endpoint_ref[] = endpoint
            connection_failure[] === nothing || (endpoint.failure = connection_failure[])
        end
        start!(loop)
        return Runtime(profile, uuid, loop, context, core, endpoint, registry_listener,
            acknowledged_sequence, wake, false, false)
    catch primary
        failures = Exception[primary]
        try
            with_thread_loop_lock(loop) do _
                for resource in (registry_listener, endpoint, core, context)
                    resource === nothing && continue
                    try close(resource) catch cleanup; push!(failures, cleanup) end
                end
            end
        catch cleanup
            push!(failures, cleanup)
        end
        try close(loop) catch cleanup; push!(failures, cleanup) end
        length(failures) == 1 && rethrow()
        throw(CompositeException(failures))
    end
end

"""Check staged work; the serialized deployment owner performs every effect."""
@inline has_pending(runtime::Runtime) = runtime.wake[]

function poll!(runtime::Runtime)
    runtime.wake[] = false
    return Endpoint.poll!(runtime.endpoint)
end

function take!(runtime::Runtime)
    runtime.wake[] = false
    return Endpoint.take!(runtime.endpoint)
end
function lifecycle!(runtime::Runtime, lifecycle::Codec.Phase)
    Endpoint.state!(runtime.endpoint, lifecycle)
    return nothing
end

"""Publish the result of an accepted ticket after the sole owner has applied it."""
function complete!(runtime::Runtime, ticket::Endpoint.Ticket,
        lifecycle::Codec.Phase, snapshot::Union{Nothing,Codec.Snapshot};
        result::Int32=Int32(0), runner_result=nothing, error=nothing)
    header = Envelope.ReplyHeader(ticket.header.controller, runtime.endpoint.instance,
        ticket.header.token, ticket.header.operation, result)
    completion = Codec.encode_completion(header, lifecycle, lifecycle === Codec.Admitted, snapshot, runner_result, error)
    Endpoint.complete!(runtime.endpoint, ticket, completion)
    return nothing
end

"""Synchronize a terminal publication before removing the public endpoint."""
function flush_terminal!(runtime::Runtime, deadline::Float64; check=()->nothing)
    Client.deadline_check(deadline, check)
    sequence = with_thread_loop_lock(runtime.loop) do _
        Endpoint.operational(runtime.endpoint)
        Client.deadline_check(deadline, check)
        sync!(runtime.core)
    end
    while true
        Client.deadline_check(deadline, check)
        observed = with_thread_loop_lock(runtime.loop) do _
            Endpoint.operational(runtime.endpoint)
            runtime.acknowledged_sequence[] == sequence
        end
        Client.deadline_check(deadline, check)
        observed && return nothing
        sleep(min(POLL_SECONDS, max(0.0, deadline - Client.monotonic())))
    end
end

function Base.close(runtime::Runtime)
    runtime.closed && return nothing
    runtime.closed = true
    failures = Exception[]
    try
        with_thread_loop_lock(runtime.loop) do _
            for resource in (runtime.registry_listener, runtime.endpoint,
                    runtime.core, runtime.context)
                try close(resource) catch error; push!(failures, error) end
            end
        end
    catch error
        push!(failures, error)
    end
    try close(runtime.loop) catch error; push!(failures, error) end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

end # module NativeSupervisorRuntime
