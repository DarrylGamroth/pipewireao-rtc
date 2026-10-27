"""One serialized calibration effect owner behind the existing native action profile."""
module NativeCalibrationEndpoint

using PipeWireAO
import ..NativeControlEndpoint as Ingress
import ..NativeControlClient as Client
import ..NativeControlCodec as Envelope
import ..NativeCalibrationActionCodec as Actions
import ..NativeAcquisitionLifecycleCodec as Lifecycle

export Endpoint, serve!

mutable struct Endpoint{F}
    loop::ThreadLoop
    context::Context
    core::CoreConnection
    ingress::Ingress.Endpoint
    listener::ManagedListener
    wakeup::Base.AsyncCondition
    wakeup_lock::ReentrantLock
    effects::F
    run::UInt64
    serial::UInt64
    phase::Symbol
    started::Threads.Atomic{Bool}
    closed::Bool
end

function wake!(condition, guard)
    lock(guard) do
        isopen(condition) && ccall(:uv_async_send, Cint, (Ptr{Cvoid},), condition)
    end
    return nothing
end

"""
    Endpoint(remote, name, instance, effects)

Publish an initial-calibration endpoint on an explicitly private remote. One
control task calls `effects(action, absolute_deadline)` for each admitted action;
the callback must return the matching typed result only after the actual effect.
Exceptions denote unknown outcomes and fault the endpoint without retry.

The endpoint takes ownership of `effects` and the supplied wakeup condition;
pass the same `wakeup_lock` used by other producers of that condition.
`close(effects)` must fence its work
and stop its non-actuating endpoints without resuming ordinary correction.
The effect owner must establish exclusive command ownership, prove adoption and
associate exposures. Native ingress alone does not establish those facts.
"""
function Endpoint(remote::AbstractString, name::AbstractString, instance::Int64, effects;
        wakeup::Base.AsyncCondition=Base.AsyncCondition(), wakeup_lock::ReentrantLock=ReentrantLock())
    remote = Client.private_remote(remote)
    condition, guard = wakeup, wakeup_lock
    notify_owner() = wake!(condition, guard)
    loop = ThreadLoop("rtc.calibration.actions")
    context = core = ingress = listener = nothing
    ingress_ref = Ref{Union{Nothing,Ingress.Endpoint}}(nothing)
    failure = Ref{Union{Nothing,String}}(nothing)
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => remote),
                on_error=(core, id, sequence, error) -> begin
                    failure[] = sprint(showerror, error)
                    ingress_ref[] === nothing || (ingress_ref[].failure = failure[])
                    notify_owner()
                    nothing
                end)
            ingress = Ingress.Endpoint(Actions.PROFILE, Actions.Command, loop, core,
                name, instance, Lifecycle.Connected;
                publisher=(filter, parameters) -> begin
                    update_params!(filter, parameters)
                    notify_owner()
                    nothing
                end)
            ingress_ref[] = ingress
            failure[] === nothing || (ingress.failure = failure[])
            listener = add_listener!(something(ingress.registry);
                on_global_added=(_...) -> (notify_owner(); nothing),
                on_global_removed=(_...) -> (notify_owner(); nothing))
        end
        start!(loop)
        return Endpoint(loop, context, core, ingress, listener, condition, guard,
            effects, UInt64(0), UInt64(0), :Prepared, Threads.Atomic{Bool}(false), false)
    catch primary
        errors = Exception[primary]
        with_thread_loop_lock(loop) do _
            for resource in (listener, ingress, core, context)
                resource === nothing && continue
                try close(resource) catch error; push!(errors, error) end
            end
        end
        for resource in (loop, effects)
            try close(resource) catch error; push!(errors, error) end
        end
        lock(guard) do
            try close(condition) catch error; push!(errors, error) end
        end
        length(errors) == 1 && rethrow()
        throw(CompositeException(errors))
    end
end

function await(predicate, condition::Base.AsyncCondition, guard::ReentrantLock, deadline::Float64)
    isfinite(deadline) || throw(ArgumentError("calibration deadline must be finite"))
    timer = Timer(_ -> wake!(condition, guard),
        max(0.0, deadline - Client.monotonic()))
    try
        while true
            Client.monotonic() < deadline || throw(Client.UnknownOutcome("calibration owner deadline expired"))
            value = predicate()
            Client.monotonic() < deadline || throw(Client.UnknownOutcome("calibration owner deadline expired"))
            value === nothing || value === false || return value
            wait(condition)
        end
    finally
        close(timer)
    end
end

allowed(::Actions.Hold, phase) = phase === :Prepared
allowed(::Actions.Adopt, phase) = phase in (:Held, :Responses, :Captured)
allowed(::Actions.Settle, phase) = phase === :Adopted
allowed(::Union{Actions.Collect,Actions.Capture}, phase) = phase === :Settled
allowed(::Actions.Restore, phase) = phase !== :Released
allowed(::Actions.Release, phase) = phase === :Restored

matches(::Actions.Hold, result) = result isa Actions.Held
matches(::Actions.Adopt, result) = result isa Actions.Adopted
matches(::Actions.Settle, result) = result isa Actions.Settled
matches(::Actions.Collect, result) = result isa Actions.Responses
matches(::Actions.Capture, result) = result isa Actions.Captured
matches(::Actions.Restore, result) = result isa Actions.Restored
matches(::Actions.Release, result) = result isa Actions.Released

function check_current!(endpoint::Endpoint)
    with_thread_loop_lock(endpoint.loop) do _
        ticket = endpoint.ingress.pending
        ticket === nothing && throw(Client.UnknownOutcome("calibration has no applying ticket"))
        Ingress.check_ticket(endpoint.ingress, ticket)
    end
    return nothing
end

function apply!(endpoint::Endpoint, ticket::Ingress.Ticket)
    command = ticket.command
    valid = (endpoint.run == 0 || command.run == endpoint.run) &&
        command.serial > endpoint.serial && allowed(command.action, endpoint.phase)
    result = if valid
        Ingress.retain_controller!(endpoint.ingress, ticket)
        endpoint.run = command.run
        endpoint.serial = command.serial
        endpoint.effects(command.action, ticket.deadline)
    else
        Actions.Failed(Actions.InvalidEvidence)
    end
    result isa Actions.Failed || matches(command.action, result) ||
        error("calibration effect returned the wrong result")
    Ingress.check_ticket(endpoint.ingress, ticket)
    if valid && !(result isa Actions.Failed)
        endpoint.phase = nameof(typeof(result))
    end
    header = Envelope.ReplyHeader(ticket.header.controller, endpoint.ingress.instance,
        ticket.header.token, ticket.header.operation, Int32(0))
    completion = Client.encode_completion(Actions.PROFILE, header, Lifecycle.Connected,
        command.run, command.serial, result, "")
    Ingress.complete!(endpoint.ingress, ticket, completion; terminal=result isa Actions.Released)
    return result
end

"""
Serve one run using callback notifications and one-shot deadlines. Effects execute
outside the PipeWire callback and loop lock. Wrong run/serial/phase requests have
no effects. Release remains published until the exact controller disconnects.
Unknown outcomes fence/close the effect owner and never authorize resumption.
"""
function serve!(endpoint::Endpoint; deadline::Real)
    endpoint.closed && throw(InvalidStateException("calibration endpoint is closed", :closed))
    Threads.atomic_cas!(endpoint.started, false, true) &&
        throw(InvalidStateException("calibration endpoint has already been served", :started))
    try
        while true
            ticket = await(endpoint.wakeup, endpoint.wakeup_lock, Float64(deadline)) do
                Ingress.poll!(endpoint.ingress)
                with_thread_loop_lock(endpoint.loop) do _
                    retained = endpoint.ingress.retained_controller
                    retained === nothing || Ingress.controller_present(endpoint.ingress, retained) ||
                        throw(Client.UnknownOutcome("retained calibration controller disappeared"))
                end
                ticket = Ingress.take!(endpoint.ingress)
                if ticket === nothing
                    with_thread_loop_lock(endpoint.loop) do _
                        header, _ = Envelope.decode_completion(endpoint.ingress.completion; endpoint=:calibration)
                        header.result < 0 && error("calibration request retired without a known outcome")
                    end
                end
                ticket
            end
            result = apply!(endpoint, ticket)
            if result isa Actions.Released
                release = await(endpoint.wakeup, endpoint.wakeup_lock, min(Float64(deadline), ticket.deadline)) do
                    status = Ingress.terminal_release(endpoint.ingress, ticket)
                    status === :waiting ? nothing : status
                end
                release === :removed || throw(Client.UnknownOutcome("terminal completion was not observed"))
                return nothing
            end
        end
    catch primary
        errors = Exception[primary]
        endpoint.phase = :Fault
        try Ingress.state!(endpoint.ingress, Lifecycle.Fault) catch error; push!(errors, error) end
        # Closing the actual effect owner fences outstanding transport/science;
        # a disconnected caller cannot cause restoration or implicit release.
        try close(endpoint.effects) catch error; push!(errors, error) end
        try close(endpoint.ingress) catch error; push!(errors, error) end
        length(errors) == 1 && rethrow()
        throw(CompositeException(errors))
    end
end

function Base.close(endpoint::Endpoint)
    endpoint.closed && return nothing
    endpoint.closed = true
    errors = Exception[]
    with_thread_loop_lock(endpoint.loop) do _
        for resource in (endpoint.listener, endpoint.ingress, endpoint.core, endpoint.context)
            try close(resource) catch error; push!(errors, error) end
        end
    end
    for resource in (endpoint.loop, endpoint.effects)
        try close(resource) catch error; push!(errors, error) end
    end
    lock(endpoint.wakeup_lock) do
        try close(endpoint.wakeup) catch error; push!(errors, error) end
    end
    isempty(errors) || throw(CompositeException(errors))
    return nothing
end

end
