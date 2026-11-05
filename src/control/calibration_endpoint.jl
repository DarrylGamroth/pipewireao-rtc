"""One serialized calibration effect owner behind the existing native action profile."""
module CalibrationEndpoint

using PipeWireAO
using Hsm: @hsmdef, @statedef, @on_initial, @on_event
import Hsm
import Clocks
import ..ControlEndpoint as Ingress
import ..ControlClient as Client
import ..ControlCodec as Envelope
import ..CalibrationActionCodec as Actions
import ..AcquisitionLifecycleCodec as Lifecycle

export Endpoint, serve!

"""The serialized scientific action protocol; native ingress owns its tickets."""
@hsmdef mutable struct Protocol
    run::UInt64
    serial::UInt64
    command::Union{Nothing,Actions.Command}
end

# These unreleased phases share Restore admission, including the old Fault phase.
@statedef Protocol :Active
@statedef Protocol :Prepared :Active
@statedef Protocol :Acquisition :Active
@statedef Protocol :Held :Acquisition
@statedef Protocol :Adopted :Acquisition
@statedef Protocol :Settled :Acquisition
@statedef Protocol :Responses :Acquisition
@statedef Protocol :Captured :Acquisition
@statedef Protocol :Restored :Active
@statedef Protocol :Fault :Active
@statedef Protocol :Released

@on_initial function (sm::Protocol, ::Root)
    return Hsm.transition!(sm, :Prepared)
end
@on_event function (
    sm::Protocol, ::Prepared, ::Requested, command::Actions.Command{Actions.Hold}
)
    return admit!(sm, command)
end
@on_event function (
    sm::Protocol, ::Held, ::Requested, command::Actions.Command{<:Actions.Adopt}
)
    return admit!(sm, command)
end
@on_event function (
    sm::Protocol, ::Responses, ::Requested, command::Actions.Command{<:Actions.Adopt}
)
    return admit!(sm, command)
end
@on_event function (
    sm::Protocol, ::Captured, ::Requested, command::Actions.Command{<:Actions.Adopt}
)
    return admit!(sm, command)
end
@on_event function (
    sm::Protocol, ::Adopted, ::Requested, command::Actions.Command{<:Actions.Settle}
)
    return admit!(sm, command)
end
@on_event function (
    sm::Protocol,
    ::Settled,
    ::Requested,
    command::Actions.Command{<:Union{Actions.Collect,Actions.Capture}},
)
    return admit!(sm, command)
end
@on_event function (
    sm::Protocol, ::Restored, ::Requested, command::Actions.Command{Actions.Release}
)
    return admit!(sm, command)
end
@on_event function (
    sm::Protocol, ::Active, ::Requested, command::Actions.Command{<:Actions.Restore}
)
    return admit!(sm, command)
end
@on_event function (sm::Protocol, ::Active, ::Accepted, command)
    sm.command === command && command.serial > sm.serial || return Hsm.EventNotHandled
    sm.run = command.run
    sm.serial = command.serial
    return Hsm.EventHandled
end
@on_event function (sm::Protocol, ::Root, ::Completed, result::Actions.Held)
    record_result!(sm, result)
    return Hsm.transition!(sm, :Held)
end
@on_event function (sm::Protocol, ::Root, ::Completed, result::Actions.Adopted)
    record_result!(sm, result)
    return Hsm.transition!(sm, :Adopted)
end
@on_event function (sm::Protocol, ::Root, ::Completed, result::Actions.Settled)
    record_result!(sm, result)
    return Hsm.transition!(sm, :Settled)
end
@on_event function (sm::Protocol, ::Root, ::Completed, result::Actions.Responses)
    record_result!(sm, result)
    return Hsm.transition!(sm, :Responses)
end
@on_event function (sm::Protocol, ::Root, ::Completed, result::Actions.Captured)
    record_result!(sm, result)
    return Hsm.transition!(sm, :Captured)
end
@on_event function (sm::Protocol, ::Root, ::Completed, result::Actions.Restored)
    record_result!(sm, result)
    return Hsm.transition!(sm, :Restored)
end
@on_event function (sm::Protocol, ::Root, ::Completed, result::Actions.Released)
    record_result!(sm, result)
    return Hsm.transition!(sm, :Released)
end
@on_event function (sm::Protocol, ::Root, ::Completed, result::Actions.Failed)
    record_result!(sm, result)
    return Hsm.EventHandled
end
@on_event function (sm::Protocol, ::Root, ::Faulted, _)
    sm.command = nothing
    return Hsm.transition!(sm, :Fault)
end

Protocol() = Protocol(UInt64(0), UInt64(0), nothing)

# Handler helpers update accepted facts without dispatch or native effects.
function admit!(sm::Protocol, command::Actions.Command)
    sm.command === nothing &&
    (sm.run == 0 || command.run == sm.run) &&
    command.serial > sm.serial || return Hsm.EventNotHandled
    sm.command = command
    return Hsm.EventHandled
end
function record_result!(sm::Protocol, result::Actions.AbstractResult)
    command = something(sm.command)
    command.run == sm.run && command.serial == sm.serial ||
        error("calibration action has not been accepted")
    matches(command.action, result) || error("calibration effect returned the wrong result")
    sm.command = nothing
    return nothing
end

mutable struct Endpoint{F}
    loop::ThreadLoop
    context::Context
    core::CoreConnection
    ingress::Ingress.Endpoint
    listener::ManagedListener
    wakeup::Base.AsyncCondition
    wakeup_lock::ReentrantLock
    effects::F
    protocol::Protocol
    started::Threads.Atomic{Bool}
    closed::Bool
end

# Preserve the endpoint's existing readback vocabulary at its public boundary.
function Base.getproperty(endpoint::Endpoint, name::Symbol)
    name === :phase && return Hsm.current(getfield(endpoint, :protocol))
    name in (:run, :serial) && return getproperty(getfield(endpoint, :protocol), name)
    return getfield(endpoint, name)
end
Base.propertynames(endpoint::Endpoint, private::Bool = false) =
    private ? (fieldnames(typeof(endpoint))..., :run, :serial, :phase) :
    (
        :loop,
        :context,
        :core,
        :ingress,
        :listener,
        :wakeup,
        :wakeup_lock,
        :effects,
        :run,
        :serial,
        :phase,
        :started,
        :closed,
    )

function wake!(condition, guard)
    lock(guard) do
        isopen(condition) && ccall(:uv_async_send, Cint, (Ptr{Cvoid},), condition)
    end
    return nothing
end

"""
    Endpoint(remote, name, instance, effects)

Publish an initial-calibration endpoint on an explicitly private remote. One
control task calls `effects(action, absolute_deadline)` with signed Int64
nanoseconds for each admitted action;
the callback must return the matching typed result only after the actual effect.
Exceptions denote unknown outcomes and fault the endpoint without retry.

The endpoint takes ownership of `effects` and the supplied wakeup condition;
pass the same `wakeup_lock` used by other producers of that condition.
`close(effects)` must fence its work
and stop its non-actuating endpoints without resuming ordinary correction.
The effect owner must establish exclusive command ownership, prove adoption and
associate exposures. Native ingress alone does not establish those facts.
`run`, `serial` and `phase` are read-only projections of the action protocol.
"""
function Endpoint(
    remote::AbstractString,
    name::AbstractString,
    instance::Int64,
    effects;
    wakeup::Base.AsyncCondition = Base.AsyncCondition(),
    wakeup_lock::ReentrantLock = ReentrantLock(),
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
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
            core = CoreConnection(
                context;
                properties = Dict("remote.name" => remote),
                on_error = (core, id, sequence, error) -> begin
                    failure[] = sprint(showerror, error)
                    ingress_ref[] === nothing || (ingress_ref[].failure = failure[])
                    notify_owner()
                    nothing
                end,
            )
            ingress = Ingress.Endpoint(
                Actions.PROFILE,
                Actions.Command,
                loop,
                core,
                name,
                instance,
                Lifecycle.Connected;
                clock,
                publisher = (filter, parameters) -> begin
                    update_params!(filter, parameters)
                    notify_owner()
                    nothing
                end,
            )
            ingress_ref[] = ingress
            failure[] === nothing || (ingress.failure = failure[])
            listener = add_listener!(
                something(ingress.registry);
                on_global_added = (_...) -> (notify_owner(); nothing),
                on_global_removed = (_...) -> (notify_owner(); nothing),
            )
        end
        start!(loop)
        return Endpoint(
            loop,
            context,
            core,
            ingress,
            listener,
            condition,
            guard,
            effects,
            Protocol(),
            Threads.Atomic{Bool}(false),
            false,
        )
    catch primary
        errors = Exception[primary]
        with_thread_loop_lock(loop) do _
            for resource in (listener, ingress, core, context)
                resource === nothing && continue
                try
                    close(resource)
                catch error
                    push!(errors, error)
                end
            end
        end
        for resource in (loop, effects)
            try
                close(resource)
            catch error
                push!(errors, error)
            end
        end
        lock(guard) do
            try
                close(condition)
            catch error
                push!(errors, error)
            end
        end
        length(errors) == 1 && rethrow()
        throw(CompositeException(errors))
    end
end

"""Wait until a predicate succeeds using signed nanosecond decision samples.

Float64 deadlines are the existing seconds compatibility boundary. The caller
owns cached-clock updates. One source sample starts each wait iteration; Timer
alone receives seconds. Native effect admission performs its own fresh checks.
"""
function await(
    predicate,
    condition::Base.AsyncCondition,
    guard::ReentrantLock,
    deadline::Union{Int64,Float64};
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    deadline = Client._deadline_ns(deadline)
    at = Clocks.time_nanos(clock)::Int64
    previous = at
    timer = Timer(
        _ -> wake!(condition, guard), Float64(max(Int128(0), Int128(deadline) - at)) / 1e9
    )
    try
        while true
            at >= previous ||
                throw(Client.UnknownOutcome("calibration owner clock regressed"))
            previous = at
            Client.deadline_check(deadline, Client.NO_CHECK, at)
            value = predicate()
            value === nothing || value === false || return value
            wait(condition)
            at = Clocks.time_nanos(clock)::Int64
        end
    finally
        close(timer)
    end
end

matches(::Actions.AbstractAction, ::Actions.AbstractResult) = false
matches(::Actions.AbstractAction, ::Actions.Failed) = true
matches(::Actions.Hold, ::Actions.Held) = true
matches(::Actions.Adopt, ::Actions.Adopted) = true
matches(::Actions.Settle, ::Actions.Settled) = true
matches(::Actions.Collect, ::Actions.Responses) = true
matches(::Actions.Capture, ::Actions.Captured) = true
matches(::Actions.Restore, ::Actions.Restored) = true
matches(::Actions.Release, ::Actions.Released) = true

function check_current!(endpoint::Endpoint)
    with_thread_loop_lock(endpoint.loop) do _
        ticket = endpoint.ingress.pending
        ticket === nothing &&
            throw(Client.UnknownOutcome("calibration has no applying ticket"))
        Ingress.check_ticket(endpoint.ingress, ticket)
    end
    return nothing
end

_terminal_result(::Actions.AbstractResult) = false
_terminal_result(::Actions.Released) = true
_await_release(endpoint, ticket, ::Actions.AbstractResult, deadline) = false
function _await_release(endpoint, ticket, ::Actions.Released, deadline)
    release = await(
        endpoint.wakeup,
        endpoint.wakeup_lock,
        min(deadline, ticket.deadline);
        clock = endpoint.ingress.clock,
    ) do
        status = Ingress.terminal_release(endpoint.ingress, ticket)
        status === :waiting ? nothing : status
    end
    release === :removed ||
        throw(Client.UnknownOutcome("terminal completion was not observed"))
    return true
end

function apply!(endpoint::Endpoint, ticket::Ingress.Ticket)
    command = ticket.command
    valid = Hsm.dispatch!(endpoint.protocol, :Requested, command) == Hsm.EventHandled
    result = if valid
        Ingress.retain_controller!(endpoint.ingress, ticket)
        Hsm.dispatch!(endpoint.protocol, :Accepted, command) == Hsm.EventHandled ||
            error("calibration action has not been admitted")
        endpoint.effects(command.action, ticket.deadline)
    else
        Actions.Failed(Actions.InvalidEvidence)
    end
    matches(command.action, result) || error("calibration effect returned the wrong result")
    Ingress.check_ticket(endpoint.ingress, ticket)
    valid && Hsm.dispatch!(endpoint.protocol, :Completed, result)
    header = Envelope.ReplyHeader(
        ticket.header.controller,
        endpoint.ingress.instance,
        ticket.header.token,
        ticket.header.operation,
        Int32(0),
    )
    completion = Client.encode_completion(
        Actions.PROFILE,
        header,
        Lifecycle.Connected,
        command.run,
        command.serial,
        result,
        "",
    )
    Ingress.complete!(
        endpoint.ingress, ticket, completion; terminal = _terminal_result(result)
    )
    return result
end

"""
    serve!(endpoint::Endpoint; deadline)

Serve one run using callback notifications and one-shot deadlines. Effects execute
outside the PipeWire callback and loop lock. Wrong run/serial/phase requests have
no effects. Release remains published until the exact controller disconnects.
Unknown outcomes fence/close the effect owner and never authorize resumption.
"""
function serve!(endpoint::Endpoint; deadline::Union{Int64,Float64})
    deadline = Client._deadline_ns(deadline)
    endpoint.closed &&
        throw(InvalidStateException("calibration endpoint is closed", :closed))
    Threads.atomic_cas!(endpoint.started, false, true) && throw(
        InvalidStateException("calibration endpoint has already been served", :started)
    )
    try
        while true
            ticket = await(
                endpoint.wakeup,
                endpoint.wakeup_lock,
                deadline;
                clock = endpoint.ingress.clock,
            ) do
                Ingress.poll!(endpoint.ingress)
                with_thread_loop_lock(endpoint.loop) do _
                    retained = endpoint.ingress.retained_controller
                    retained === nothing ||
                        Ingress.controller_present(endpoint.ingress, retained) ||
                        throw(
                            Client.UnknownOutcome(
                                "retained calibration controller disappeared"
                            ),
                        )
                end
                ticket = Ingress.take!(endpoint.ingress)
                if ticket === nothing
                    with_thread_loop_lock(endpoint.loop) do _
                        header, _ = Envelope.decode_completion(
                            endpoint.ingress.completion; endpoint = :calibration
                        )
                        header.result < 0 &&
                            error("calibration request retired without a known outcome")
                    end
                end
                ticket
            end
            result = apply!(endpoint, ticket)
            _await_release(endpoint, ticket, result, deadline) && return nothing
        end
    catch primary
        errors = Exception[primary]
        Hsm.dispatch!(endpoint.protocol, :Faulted)
        try
            Ingress.state!(endpoint.ingress, Lifecycle.Fault)
        catch error
            push!(errors, error)
        end
        # Closing the actual effect owner fences outstanding transport/science;
        # a disconnected caller cannot cause restoration or implicit release.
        try
            close(endpoint.effects)
        catch error
            push!(errors, error)
        end
        try
            close(endpoint.ingress)
        catch error
            push!(errors, error)
        end
        length(errors) == 1 && rethrow()
        throw(CompositeException(errors))
    end
end

function Base.close(endpoint::Endpoint)
    endpoint.closed && return nothing
    endpoint.closed = true
    errors = Exception[]
    with_thread_loop_lock(endpoint.loop) do _
        for resource in
            (endpoint.listener, endpoint.ingress, endpoint.core, endpoint.context)
            try
                close(resource)
            catch error
                push!(errors, error)
            end
        end
    end
    for resource in (endpoint.loop, endpoint.effects)
        try
            close(resource)
        catch error
            push!(errors, error)
        end
    end
    lock(endpoint.wakeup_lock) do
        try
            close(endpoint.wakeup)
        catch error
            push!(errors, error)
        end
    end
    isempty(errors) || throw(CompositeException(errors))
    return nothing
end

end
