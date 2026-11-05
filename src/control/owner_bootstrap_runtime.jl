"""Cold native bootstrap resources and the reserved ordinary-owner monitor."""
module OwnerBootstrapRuntime

using PipeWireAO
import Agent
import Clocks
import ..Common
import Hsm
using Hsm: @hsmdef, @statedef, @finaldef, @on_initial, @on_event
import ThreadPinning
import ..ControlCodec
import ..ControlClient
import ..ControlEndpoint
import ..OwnerBootstrapCodec

const Envelope = ControlCodec
const Client = ControlClient
const Endpoint = ControlEndpoint
const Codec = OwnerBootstrapCodec
const Profile = Codec.Profile
const Commands = Union{Codec.Command{:status},Codec.Command{:connect},Codec.Command{:quit}}
const POLL_SECONDS = 0.005

export Runtime,
    validate_threads,
    preparation_check!,
    prepared!,
    take_connect!,
    check_connect!,
    connecting!,
    connected!,
    await_connected!,
    cancelled,
    cancel!,
    finishing!,
    fault!,
    finish!,
    clean_cancel,
    flush_terminal!,
    with_owner

mutable struct Transport{P<:Profile,C,E,L}
    profile::P
    loop::ThreadLoop
    context::Context
    core::C
    endpoint::E
    registry_listener::L
    acknowledged_sequence::Base.RefValue{Cint}
    wake::Base.Threads.Atomic{Bool}
    closed::Bool
end

"""Publish Preparing before the existing owner prepares its science or plant."""
function Transport(
    profile::P,
    remote::AbstractString,
    name::AbstractString,
    instance::Int64;
    application_name::AbstractString = name,
) where {P<:Profile}
    path = Client.private_remote(remote)
    loop = ThreadLoop("rtc-bootstrap")
    context = core = endpoint = registry_listener = nothing
    endpoint_ref = Ref{Union{Nothing,Endpoint.Endpoint}}(nothing)
    acknowledged_sequence = Ref{Cint}(-1)
    wake = Base.Threads.Atomic{Bool}(false)
    connection_failure = Ref{Union{Nothing,String}}(nothing)
    try
        with_thread_loop_lock(loop) do _
            context = Context(
                loop; properties = Dict("application.name" => application_name)
            )
            core = CoreConnection(
                context;
                properties = Dict("remote.name" => path),
                on_done = (core, id, sequence) -> begin
                    id == 0 && (acknowledged_sequence[] = sequence)
                    nothing
                end,
                on_error = (core, id, sequence, error) -> begin
                    connection_failure[] = sprint(showerror, error)
                    current = endpoint_ref[]
                    current === nothing || (current.failure = connection_failure[])
                    wake[] = true
                    nothing
                end,
            )
            endpoint = Endpoint.Endpoint(
                profile,
                Commands,
                loop,
                core,
                name,
                instance,
                Codec.Preparing;
                publisher = (filter, params) -> begin
                    wake[] = true
                    update_params!(filter, params)
                end,
            )
            registry_listener = add_listener!(
                something(endpoint.registry);
                on_global_added = (registry, global_object) -> (wake[] = true; nothing),
                on_global_removed = (registry, id) -> (wake[] = true; nothing),
            )
            endpoint_ref[] = endpoint
            connection_failure[] === nothing || (endpoint.failure = connection_failure[])
        end
        start!(loop)
        return Transport(
            profile,
            loop,
            context,
            core,
            endpoint,
            registry_listener,
            acknowledged_sequence,
            wake,
            false,
        )
    catch primary
        failures = Exception[primary]
        try
            with_thread_loop_lock(loop) do _
                for resource in (registry_listener, endpoint, core, context)
                    resource === nothing && continue
                    try
                        close(resource)
                    catch cleanup
                        push!(failures, cleanup)
                    end
                end
            end
        catch cleanup
            push!(failures, cleanup)
        end
        try
            close(loop)
        catch cleanup
            push!(failures, cleanup)
        end
        length(failures) == 1 && rethrow()
        throw(CompositeException(failures))
    end
end

"""Cold ingress hint, including Core error."""
@inline has_pending(runtime::Transport) = runtime.wake[]

poll!(runtime::Transport) = Endpoint.poll!(runtime.endpoint)
take!(runtime::Transport) = Endpoint.take!(runtime.endpoint)

"Check quiet transport health without registry traversal; consume only the old wake."
function _poll_ready!(runtime::Transport)
    wake = Base.Threads.atomic_xchg!(runtime.wake, false)
    pending = with_thread_loop_lock(runtime.loop) do _
        Endpoint.operational(runtime.endpoint)
        retained = runtime.endpoint.retained_controller
        retained === nothing ||
            Endpoint.controller_present(runtime.endpoint, retained) ||
            error("retained native bootstrap controller was revoked")
        runtime.endpoint.pending !== nothing
    end
    if wake || pending
        poll!(runtime)
        return true
    end
    return false
end
function lifecycle!(runtime::Transport, lifecycle::Codec.Lifecycle)
    Endpoint.state!(runtime.endpoint, lifecycle)
    return nothing
end

"""Publish the result of an accepted ticket after the sole owner has applied it."""
function complete!(
    runtime::Transport,
    ticket::Endpoint.Ticket,
    lifecycle::Codec.Lifecycle;
    result::Int32 = Int32(0),
    message::AbstractString = "",
    terminal::Bool = false,
)
    header = Envelope.ReplyHeader(
        ticket.header.controller,
        runtime.endpoint.instance,
        ticket.header.token,
        ticket.header.operation,
        result,
    )
    completion = Client.encode_completion(runtime.profile, header, lifecycle, message)
    Endpoint.complete!(runtime.endpoint, ticket, completion; terminal)
    return nothing
end

"""Synchronize a terminal publication before removing the public endpoint."""
function flush_terminal!(runtime::Transport, deadline::Float64; check = () -> nothing)
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

function Base.close(runtime::Transport)
    runtime.closed && return nothing
    runtime.closed = true
    failures = Exception[]
    try
        with_thread_loop_lock(runtime.loop) do _
            for resource in
                (runtime.registry_listener, runtime.endpoint, runtime.core, runtime.context)
                try
                    close(resource)
                catch error
                    push!(failures, error)
                end
            end
        end
    catch error
        push!(failures, error)
    end
    try
        close(runtime.loop)
    catch error
        push!(failures, error)
    end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end


abstract type AbstractConnectionHooks end
struct Hooks{R,Q} <: AbstractConnectionHooks
    ready::R
    quit::Q
end

"Immutable owner observation, published only by the reserved monitor."
struct Status
    ready::Bool
    cancelled::Bool
    prepared::Bool
    connect_ticket::Union{Nothing,Endpoint.Ticket}
    connect_taken::Bool
    connected::Bool
    main_finished::Bool
    main_error::Union{Nothing,Exception}
    failure::Union{Nothing,Exception}
    hooks_excluded::Bool
    done::Bool
end
Status() = Status(
    false, false, false, nothing, false, false, false, nothing, nothing, false, false
)

struct OwnerReply
    ticket::Union{Nothing,Endpoint.Ticket}
    error::Union{Nothing,Exception}
end
abstract type AbstractOwnerMessage end
struct OwnerPrepared <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
end
struct ConnectTaken <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
    ticket::Endpoint.Ticket
end
struct ConnectChecked <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
    ticket::Endpoint.Ticket
end
struct ConnectAwaited <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
    ticket::Endpoint.Ticket
end
struct ConnectionRegistered <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
    ticket::Endpoint.Ticket
    hooks::AbstractConnectionHooks
end
struct ConnectCompleted <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
    ticket::Endpoint.Ticket
end
struct HooksExcluded <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
end
struct OwnerFault <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
    error::Exception
end
struct OwnerFinished <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
end
struct OwnerClosed <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
end
struct OwnerCancelled <: AbstractOwnerMessage
    reply::Channel{OwnerReply}
end

const MAILBOX_CAPACITY = 4
"Separate cleanup capacity keeps ordinary ingress from preventing hook exclusion."
struct Mailbox
    owner::Channel{AbstractOwnerMessage}
    cleanup::Channel{AbstractOwnerMessage}
end
Mailbox() = Mailbox(
    Channel{AbstractOwnerMessage}(MAILBOX_CAPACITY),
    Channel{AbstractOwnerMessage}(MAILBOX_CAPACITY),
)

"""Owner proxy; science stays on thread 1 and mutable handshakes on monitor 2.

The bounded Channels synchronise messages from owner tasks on thread 1. The
monitor is their sole consumer and each private reply has one producer/consumer.
Normal ingress rejects a full mailbox before acceptance. Cleanup has reserved
capacity and applies synchronous back pressure; closing the monitor wakes queued
senders/readers. No public operation retries an accepted message.
"""
mutable struct Runtime{T}
    const transport::T
    const mailbox::Mailbox
    @atomic status::Status
    # ThreadPinning does not promise a concrete, version-stable task handle type.
    # Only the owner uses this cold handle; it never enters science.
    monitor::Any
end
Runtime(transport) = Runtime(transport, Mailbox(), Status(), nothing)
_status(runtime::Runtime) = @atomic :acquire runtime.status
Base.getproperty(runtime::Runtime, name::Symbol) =
    name in (:failure, :main_error, :connect_ticket) ? getproperty(_status(runtime), name) :
    getfield(runtime, name)
Base.propertynames(runtime::Runtime, private::Bool = false) =
    (fieldnames(typeof(runtime))..., :failure, :main_error, :connect_ticket)

"""
    validate_threads()

Require construction on default thread 1 with a pool numbered `1:N`, `N ≥ 2`.
Thread 2 is reserved for the cold bootstrap Active Object. Public owner messages
must originate on thread 1; multiple tasks there use the Channel's synchronization.
"""
function validate_threads()
    VERSION >= v"1.12" || throw(ArgumentError("native bootstrap requires Julia >= 1.12"))
    Base.Threads.threadid() == 1 ||
        throw(ArgumentError("native owner must construct on Julia thread 1"))
    ids = ThreadPinning.threadids(; threadpool = :default)
    length(ids) >= 2 && ids == collect(1:length(ids)) || throw(
        ArgumentError(
            "native owner requires --threads=N,0 with N >= 2; thread 2 is the cold monitor",
        ),
    )
    return nothing
end
function Runtime(
    remote::AbstractString,
    name::AbstractString,
    instance::Int64;
    application_name::AbstractString = name,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    validate_threads()
    transport = Transport(Codec.PROFILE, remote, name, instance; application_name)
    runtime = Runtime(transport)
    try
        precompile(serve!, (typeof(runtime),)) ||
            error("cannot compile native bootstrap monitor before startup")
        _precompile_owner_routes!(Monitor{typeof(runtime),typeof(clock)})
        runtime.monitor = ThreadPinning.@spawnat 2 serve!(runtime; clock)
        deadline = Client.monotonic() + 5.0
        while !_status(runtime).ready
            Client.deadline_check(deadline, () -> nothing)
            _status(runtime).done && error("bootstrap monitor stopped before startup")
            sleep(POLL_SECONDS)
        end
        return runtime
    catch primary
        if runtime.monitor !== nothing
            # Shutdown is a message too; never mutate monitor-owned handshakes.
            try
                _enqueue!(
                    runtime.mailbox, OwnerClosed(Channel{OwnerReply}(1)); cleanup = true
                )
            catch
            end
            timedwait(() -> istaskdone(runtime.monitor), 2.0; pollint = POLL_SECONDS) ==
            :ok || throw(
                CompositeException([
                    primary,
                    ErrorException(
                        "bootstrap monitor did not terminate; resources retained for finite process cleanup",
                    ),
                ]),
            )
            wait(runtime.monitor)
        end
        try
            close(transport)
        catch cleanup
            throw(CompositeException([primary, cleanup]))
        end
        rethrow()
    end
end

function _owner_thread()
    Base.Threads.threadid() == 1 ||
        throw(ArgumentError("bootstrap owner messages require constructing thread 1"))
    return nothing
end
function _enqueue!(mailbox::Mailbox, message::AbstractOwnerMessage; cleanup::Bool = false)
    channel = cleanup ? mailbox.cleanup : mailbox.owner
    lock(channel) do
        isopen(channel) || throw(InvalidStateException("bootstrap mailbox closed", :closed))
        Base.isfull(channel) &&
            throw(InvalidStateException("bootstrap mailbox full", :full))
        # Check and acceptance are one Channel transaction even with several
        # owner tasks. No blocked Channel producer can make isready report a
        # waiting sender instead of a buffered message to the monitor consumer.
        put!(channel, message)
    end
    return nothing
end
_mailbox_full(error) = false
_mailbox_full(error::InvalidStateException) = error.state === :full

function _request!(runtime::Runtime, message::AbstractOwnerMessage; cleanup::Bool = false)
    _owner_thread()
    _status(runtime).done &&
        throw(InvalidStateException("bootstrap monitor closed", :closed))
    while true
        try
            _enqueue!(runtime.mailbox, message; cleanup)
            break
        catch error
            # Reserved cleanup capacity applies back pressure before acceptance.
            # Accepted mutations are never retried, and no native lock is held.
            cleanup && _mailbox_full(error) || rethrow()
            _status(runtime).done && rethrow()
            sleep(POLL_SECONDS)
        end
    end
    while !isready(message.reply)
        status = _status(runtime)
        status.done && status.failure !== nothing && throw(status.failure)
        status.done &&
            throw(InvalidStateException("bootstrap monitor closed before reply", :closed))
        if runtime.monitor !== nothing && istaskdone(runtime.monitor)
            wait(runtime.monitor)
            error("bootstrap monitor stopped before reply")
        end
        sleep(POLL_SECONDS)
    end
    reply = Base.take!(message.reply)
    reply.error === nothing || throw(reply.error)
    return reply.ticket
end

"Atomic immutable status read; this does not establish scientific cleanup."
cancelled(runtime::Runtime) = _status(runtime).cancelled
function clean_cancel(runtime::Runtime)
    status = _status(runtime)
    return status.cancelled && status.failure === nothing
end
"Check recorded failure/cancellation without queueing work or allocating."
function preparation_check!(runtime::Runtime)
    status = _status(runtime)
    status.failure === nothing || throw(status.failure)
    status.cancelled && throw(InterruptException())
    return nothing
end
"Signal prepared facts to the monitor; science/lifecycle publication stays separate."
function prepared!(runtime::Runtime)
    preparation_check!(runtime)
    _request!(runtime, OwnerPrepared(Channel{OwnerReply}(1)))
    return nothing
end
"Wait for and claim the monitor's exact Connect ticket once."
function take_connect!(runtime::Runtime)
    _owner_thread()
    while true
        preparation_check!(runtime)
        status = _status(runtime)
        if status.connect_ticket !== nothing && !status.connect_taken
            ticket = _request!(
                runtime, ConnectTaken(Channel{OwnerReply}(1), status.connect_ticket)
            )
            ticket === nothing || return ticket
        end
        status.done && error("bootstrap monitor stopped before Connect")
        sleep(POLL_SECONDS)
    end
end
"Validate the exact Connect through its monitor owner and native loop transaction."
function check_connect!(runtime::Runtime, ticket::Endpoint.Ticket)
    preparation_check!(runtime)
    _request!(runtime, ConnectChecked(Channel{OwnerReply}(1), ticket))
    return nothing
end
"""Register public any-thread native readiness/quit capabilities for Connect.

The monitor owns these hooks after acceptance. They must not execute science or
mutate owner Julia state. A Quit capability must wake blocking native run! even
when thread 1 cannot consume messages. finishing! acknowledges hook exclusion
before the owner closes its scientific node.
"""
function connecting!(runtime::Runtime, ticket::Endpoint.Ticket; ready, quit)
    preparation_check!(runtime)
    _request!(
        runtime, ConnectionRegistered(Channel{OwnerReply}(1), ticket, Hooks(ready, quit))
    )
    return nothing
end
"Signal completed connection facts; only the monitor completes the native ticket."
function connected!(runtime::Runtime, ticket::Endpoint.Ticket)
    preparation_check!(runtime)
    _request!(runtime, ConnectCompleted(Channel{OwnerReply}(1), ticket))
    return nothing
end
"Wait for exact native Connected completion using immutable monitor observations."
function await_connected!(runtime::Runtime, ticket::Endpoint.Ticket)
    _owner_thread()
    while true
        preparation_check!(runtime)
        status = _status(runtime)
        status.connected && status.connect_ticket === ticket && return nothing
        observed = _request!(runtime, ConnectAwaited(Channel{OwnerReply}(1), ticket))
        observed === ticket && return nothing
        sleep(POLL_SECONDS)
    end
end
function _cleanup_request!(runtime::Runtime, message::AbstractOwnerMessage)
    _owner_thread()
    _status(runtime).done && return nothing
    try
        _request!(runtime, message; cleanup = true)
    catch error
        # Monitor close publishes exclusion before closing/draining its channels.
        # Once done, no further hook invocation can race scientific close.
        _status(runtime).done || rethrow()
    end
    return nothing
end
"Synchronously acknowledge hook exclusion before scientific close."
function finishing!(runtime::Runtime)
    _cleanup_request!(runtime, HooksExcluded(Channel{OwnerReply}(1)))
    return nothing
end
"Request cooperative native wake/cancellation without claiming scientific cleanup."
function cancel!(runtime::Runtime)
    _cleanup_request!(runtime, OwnerCancelled(Channel{OwnerReply}(1)))
    return nothing
end
"Retain the first owner failure on the monitor; closed cleanup cannot revive it."
function fault!(runtime::Runtime, error::Exception)
    _cleanup_request!(runtime, OwnerFault(Channel{OwnerReply}(1), error))
    return nothing
end
"Acknowledge scientific cleanup, then wait for monitor terminal publication/release."
function finish!(runtime::Runtime)
    finishing!(runtime)
    _cleanup_request!(runtime, OwnerFinished(Channel{OwnerReply}(1)))
    runtime.monitor === nothing || wait(runtime.monitor)
    failure = _status(runtime).failure
    failure === nothing || throw(failure)
    return nothing
end
function _message(error::Exception)
    text = sprint(showerror, error)
    io = IOBuffer()
    bytes = 0
    for char in text
        width = ncodeunits(string(char))
        bytes + width <= 8192 || break
        print(io, char == '\0' ? '?' : char)
        bytes += width
    end
    return String(Base.take!(io))
end
struct Facts
    prepared::Bool
    finished::Bool
    error::Union{Nothing,Exception}
end
function _facts(runtime::Runtime)
    status = _status(runtime)
    return Facts(status.prepared, status.main_finished, status.main_error)
end
function _apply!(runtime::Runtime, ticket, ::Codec.Command{:status}, lifecycle)
    error = _facts(runtime).error
    try
        complete!(
            runtime.transport,
            ticket,
            lifecycle;
            message = error === nothing ? "" : _message(error),
        )
    catch failure
        endpoint = runtime.transport.endpoint
        neutral = with_thread_loop_lock(runtime.transport.loop) do _
            Endpoint.operational(endpoint)
            Client.monotonic() >= ticket.deadline ||
                !Endpoint.controller_present(endpoint, ticket.header.controller)
        end
        neutral || rethrow()
        complete!(
            runtime.transport,
            ticket,
            lifecycle;
            result = Int32(-110),
            message = "Status expired or controller removed",
        )
    end
    return nothing
end
_fault_reply!(runtime, ticket, command::Codec.Command{:status}, lifecycle) =
    _apply!(runtime, ticket, command, lifecycle)
_fault_reply!(
    runtime, ticket, command::Union{Codec.Command{:connect},Codec.Command{:quit}}, lifecycle
) = complete!(
    runtime.transport,
    ticket,
    lifecycle;
    result = Int32(-5),
    message = "owner cleanup after failure",
)

"""Reserved-monitor state only; owner threads publish the bounded Runtime facts."""
@hsmdef mutable struct Monitor{R,N<:Clocks.AbstractNanoClock}
    const runtime::R
    const owner::Task
    const source_clock::N
    const clock::Clocks.CachedNanoClock
    prepare_done::Bool
    connect_ticket::Union{Nothing,Endpoint.Ticket}
    connect_taken::Bool
    connect_done::Bool
    hooks::Union{Nothing,AbstractConnectionHooks}
    finishing::Bool
    main_finished::Bool
    main_error::Union{Nothing,Exception}
    failure::Union{Nothing,Exception}
    cancel::Bool
    ready::Bool
    done::Bool
    active::Union{Nothing,Endpoint.Ticket}
    incoming::Union{Nothing,Endpoint.Ticket}
    ingress::Bool
    # Native wire projection, updated with publication by handlers. Pending Quit
    # retains its admission phase until actual scientific cleanup completes.
    lifecycle::Codec.Lifecycle
    cleanup_deadline::Float64
end

@statedef Monitor :Monitoring
@statedef Monitor :Healthy :Monitoring
@statedef Monitor :Preparing :Healthy
@statedef Monitor :Prepared :Healthy
@statedef Monitor :ConnectPending :Prepared
@statedef Monitor :Connected :Healthy
@statedef Monitor :Fault :Monitoring
@statedef Monitor :FaultConnectPending :Fault
@statedef Monitor :QuitPending :Monitoring
@statedef Monitor :QuitPreparing :QuitPending
@statedef Monitor :QuitPrepared :QuitPending
@statedef Monitor :QuitConnected :QuitPending
@statedef Monitor :QuitFault :QuitPending
@statedef Monitor :Cleanup :Monitoring
@finaldef Monitor :Stopped
@finaldef Monitor :Done

@on_initial function (sm::Monitor{R}, ::Root) where {R}
    return Hsm.transition!(sm, :Preparing)
end
Monitor(runtime; clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock()) = Monitor(
    runtime,
    current_task(),
    clock,
    Clocks.CachedNanoClock(),
    false,
    nothing,
    false,
    false,
    nothing,
    false,
    false,
    nothing,
    nothing,
    false,
    false,
    false,
    nothing,
    nothing,
    false,
    Codec.Preparing,
    0.0,
)

_facts(sm::Monitor) = Facts(sm.prepare_done, sm.main_finished, sm.main_error)
_now(sm::Monitor) = Common.monotonic_seconds(sm.clock)
function _observe!(sm::Monitor)
    snapshot = Status(
        sm.ready,
        sm.cancel,
        sm.prepare_done,
        sm.connect_ticket,
        sm.connect_taken,
        sm.lifecycle === Codec.Connected &&
            sm.active === nothing &&
            sm.main_error === nothing,
        sm.main_finished,
        sm.main_error,
        sm.failure,
        sm.finishing,
        sm.done,
    )
    @atomic :release sm.runtime.status = snapshot
    return nothing
end
function _stop!(sm::Monitor)
    if !sm.cancel
        sm.cancel = true
        _observe!(sm)
    end
    sm.hooks === nothing || Base.invokelatest(sm.hooks.quit)
    return nothing
end
_ready(sm::Monitor) =
    sm.connect_done || (sm.hooks !== nothing && Base.invokelatest(sm.hooks.ready))

function _publish!(sm::Monitor, lifecycle::Codec.Lifecycle)
    sm.lifecycle = lifecycle
    lifecycle!(sm.runtime.transport, lifecycle)
    _observe!(sm)
    return nothing
end
function _owner_fault!(sm::Monitor)
    _publish!(sm, Codec.Fault)
    return nothing
end

@on_event function (sm::Monitor{R}, ::Healthy, ::OwnerObserved, facts) where {R}
    facts.error === nothing && return Hsm.EventHandled
    _owner_fault!(sm)
    return Hsm.transition!(sm, :Fault)
end
@on_event function (sm::Monitor{R}, ::Preparing, ::OwnerObserved, facts) where {R}
    facts.error === nothing || return Hsm.EventNotHandled
    if facts.prepared && !sm.cancel && !sm.finishing
        _publish!(sm, Codec.Prepared)
        return Hsm.transition!(sm, :Prepared)
    end
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::ConnectPending, ::OwnerObserved, facts) where {R}
    facts.error === nothing && return Hsm.EventHandled
    _owner_fault!(sm)
    return Hsm.transition!(sm, :FaultConnectPending)
end
@on_event function (sm::Monitor{R}, ::QuitPending, ::OwnerObserved, facts) where {R}
    facts.error === nothing && return Hsm.EventHandled
    _owner_fault!(sm)
    return Hsm.transition!(sm, :QuitFault)
end
@on_event function (sm::Monitor{R}, ::QuitFault, ::OwnerObserved, facts) where {R}
    return Hsm.EventHandled
end

@on_event function (sm::Monitor{R}, ::Monitoring, ::PollTransport, arg) where {R}
    sm.ingress = _poll_ready!(sm.runtime.transport)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::TakeIngress, arg) where {R}
    sm.incoming =
        sm.active === nothing && sm.ingress ? take!(sm.runtime.transport) : nothing
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::StatusRequested, ticket) where {R}
    _apply!(sm.runtime, ticket, ticket.command, sm.lifecycle)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::ConnectRequested, ticket) where {R}
    complete!(
        sm.runtime.transport,
        ticket,
        sm.lifecycle;
        result = Int32(-22),
        message = "Connect requires Prepared",
    )
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Prepared, ::ConnectRequested, ticket) where {R}
    sm.connect_ticket = ticket
    _observe!(sm)
    sm.active = ticket
    return Hsm.transition!(sm, :ConnectPending)
end

function _quit!(sm::Monitor, ticket)
    _stop!(sm)
    sm.active = ticket
    return nothing
end
@on_event function (sm::Monitor{R}, ::Preparing, ::QuitRequested, ticket) where {R}
    _quit!(sm, ticket)
    return Hsm.transition!(sm, :QuitPreparing)
end
@on_event function (sm::Monitor{R}, ::Prepared, ::QuitRequested, ticket) where {R}
    _quit!(sm, ticket)
    return Hsm.transition!(sm, :QuitPrepared)
end
@on_event function (sm::Monitor{R}, ::Connected, ::QuitRequested, ticket) where {R}
    _quit!(sm, ticket)
    return Hsm.transition!(sm, :QuitConnected)
end
@on_event function (sm::Monitor{R}, ::Fault, ::QuitRequested, ticket) where {R}
    _quit!(sm, ticket)
    return Hsm.transition!(sm, :QuitFault)
end

@on_event function (sm::Monitor{R}, ::ConnectPending, ::TicketObserved, facts) where {R}
    ticket = something(sm.active)
    Endpoint.check_ticket(sm.runtime.transport.endpoint, ticket)
    if facts.finished
        complete!(
            sm.runtime.transport,
            ticket,
            sm.lifecycle;
            result = Int32(-5),
            message = "owner stopped before Connect registered",
        )
        sm.active = nothing
        return Hsm.transition!(sm, :Prepared)
    elseif _ready(sm)
        # Seal registry discovery before publishing Connected, and complete the
        # exact accepted ticket before main may enter scientific execution.
        with_thread_loop_lock(sm.runtime.transport.loop) do _
            Endpoint.check_ticket(sm.runtime.transport.endpoint, ticket)
            close(sm.runtime.transport.registry_listener)
            Endpoint.retain_controller!(sm.runtime.transport.endpoint, ticket)
        end
        _publish!(sm, Codec.Connected)
        complete!(sm.runtime.transport, ticket, sm.lifecycle)
        sm.active = nothing
        _observe!(sm)
        return Hsm.transition!(sm, :Connected)
    end
    return Hsm.EventHandled
end
@on_event function (
    sm::Monitor{R}, ::FaultConnectPending, ::TicketObserved, facts
) where {R}
    ticket = something(sm.active)
    Endpoint.check_ticket(sm.runtime.transport.endpoint, ticket)
    complete!(
        sm.runtime.transport,
        ticket,
        sm.lifecycle;
        result = Int32(-5),
        message = _message(something(facts.error)),
    )
    sm.active = nothing
    return Hsm.transition!(sm, :Fault)
end
@on_event function (sm::Monitor{R}, ::QuitPending, ::TicketObserved, facts) where {R}
    runtime = sm.runtime
    ticket = something(sm.active)
    Endpoint.check_ticket(runtime.transport.endpoint, ticket)
    if facts.finished
        result = facts.error === nothing ? Int32(0) : Int32(-5)
        lifecycle = result == 0 ? Codec.Stopped : Codec.Fault
        _publish!(sm, lifecycle)
        result == 0 && Endpoint.retain_controller!(runtime.transport.endpoint, ticket)
        complete!(
            runtime.transport,
            ticket,
            lifecycle;
            result,
            message = facts.error === nothing ? "" : _message(facts.error),
            terminal = result == 0,
        )
        flush_terminal!(runtime.transport, ticket.deadline)
        result == 0 && Endpoint.wait_terminal_release!(runtime.transport.endpoint, ticket)
        sm.active = nothing
        result == 0 && return Hsm.transition!(sm, :Stopped)
        return Hsm.transition!(sm, :Done)
    end
    # Quit can race main entering its native blocking run loop. Repeat the
    # public hook until main excludes it before scientific close.
    _stop!(sm)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::FinishedObserved, facts) where {R}
    facts.finished && sm.active === nothing || return Hsm.EventHandled
    _publish!(sm, facts.error === nothing ? Codec.Stopped : Codec.Fault)
    flush_terminal!(sm.runtime.transport, _now(sm) + 5.0)
    facts.error === nothing && return Hsm.transition!(sm, :Stopped)
    return Hsm.transition!(sm, :Done)
end

function _record_cleanup_failure!(sm::Monitor, cleanup)
    sm.failure = CompositeException([something(sm.failure), cleanup])
    _observe!(sm)
    return nothing
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::MonitorFailed, error) where {R}
    runtime = sm.runtime
    sm.failure === nothing && (sm.failure = error)
    _observe!(sm)
    # Preserve actual completed scientific cleanup when terminal transport fails.
    facts = _facts(sm)
    failed_lifecycle =
        facts.finished && facts.error === nothing ? Codec.Stopped : Codec.Fault
    try
        _publish!(sm, failed_lifecycle)
    catch publication
        sm.failure = CompositeException([error, publication])
        _observe!(sm)
    end
    try
        _stop!(sm)
        if sm.active !== nothing
            pending = with_thread_loop_lock(runtime.transport.loop) do _
                runtime.transport.endpoint.pending === sm.active &&
                    runtime.transport.endpoint.applying
            end
            pending && complete!(
                runtime.transport,
                sm.active,
                failed_lifecycle;
                result = Int32(-5),
                message = _message(error),
            )
        end
        sm.active = nothing
        sm.incoming = nothing
        # This budget is anchored to the beginning of the failed duty cycle;
        # subordinate native I/O retains its fresh trust-boundary deadline clock.
        sm.cleanup_deadline = _now(sm) + 5.0
    catch cleanup
        _record_cleanup_failure!(sm, cleanup)
        return Hsm.transition!(sm, :Done)
    end
    return Hsm.transition!(sm, :Cleanup)
end
@on_event function (sm::Monitor{R}, ::Cleanup, ::MonitorFailed, error) where {R}
    _record_cleanup_failure!(sm, error)
    return Hsm.transition!(sm, :Done)
end
@on_event function (sm::Monitor{R}, ::Cleanup, ::OwnerObserved, facts) where {R}
    if facts.finished || _now(sm) >= sm.cleanup_deadline
        flush_terminal!(sm.runtime.transport, sm.cleanup_deadline)
        return Hsm.transition!(sm, :Done)
    end
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Cleanup, ::PollTransport, arg) where {R}
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Cleanup, ::TakeIngress, arg) where {R}
    _stop!(sm)
    poll!(sm.runtime.transport)
    sm.incoming = take!(sm.runtime.transport)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Cleanup, ::ConnectRequested, ticket) where {R}
    _fault_reply!(sm.runtime, ticket, ticket.command, sm.lifecycle)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Cleanup, ::QuitRequested, ticket) where {R}
    _fault_reply!(sm.runtime, ticket, ticket.command, sm.lifecycle)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Cleanup, ::FinishedObserved, facts) where {R}
    return Hsm.EventHandled
end

_dispatch_request!(sm::Monitor, ::Nothing) = nothing
_dispatch_request!(sm::Monitor, ticket::Endpoint.Ticket) =
    _dispatch_request!(sm, ticket, ticket.command)
_dispatch_request!(sm, ticket, ::Codec.Command{:status}) =
    Hsm.dispatch!(sm, :StatusRequested, ticket)
_dispatch_request!(sm, ticket, ::Codec.Command{:connect}) =
    Hsm.dispatch!(sm, :ConnectRequested, ticket)
_dispatch_request!(sm, ticket, ::Codec.Command{:quit}) =
    Hsm.dispatch!(sm, :QuitRequested, ticket)

function _health(sm::Monitor)
    sm.failure === nothing || throw(sm.failure)
    sm.cancel && throw(InterruptException())
    sm.finishing && throw(
        InvalidStateException(
            "bootstrap owner finished admitting connection work", :closed
        ),
    )
    return nothing
end
function _connection_health(sm::Monitor, ticket)
    _health(sm)
    Endpoint.check_ticket(sm.runtime.transport.endpoint, ticket)
    return nothing
end
function _reply!(
    sm::Monitor, message::AbstractOwnerMessage; ticket = nothing, error = nothing
)
    _observe!(sm)
    put!(message.reply, OwnerReply(ticket, error))
    return nothing
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::PreparedByOwner, message) where {R}
    _health(sm)
    sm.prepare_done = true
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::ConnectTakenByOwner, message) where {R}
    _health(sm)
    ticket = nothing
    if sm.connect_ticket === message.ticket && !sm.connect_taken
        sm.connect_taken = true
        ticket = sm.connect_ticket
    end
    _reply!(sm, message; ticket)
    return Hsm.EventHandled
end
@on_event function (
    sm::Monitor{R}, ::Monitoring, ::ConnectCheckedByOwner, message
) where {R}
    _connection_health(sm, message.ticket)
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (
    sm::Monitor{R}, ::Monitoring, ::ConnectAwaitedByOwner, message
) where {R}
    _connection_health(sm, message.ticket)
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Connected, ::ConnectAwaitedByOwner, message) where {R}
    _health(sm)
    sm.connect_ticket === message.ticket ||
        error("native Connect observation does not match its ticket")
    _reply!(sm, message; ticket = message.ticket)
    return Hsm.EventHandled
end
@on_event function (
    sm::Monitor{R}, ::Monitoring, ::ConnectionRegisteredByOwner, message
) where {R}
    _connection_health(sm, message.ticket)
    sm.hooks = message.hooks
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (
    sm::Monitor{R}, ::Monitoring, ::ConnectCompletedByOwner, message
) where {R}
    _connection_health(sm, message.ticket)
    sm.connect_done = true
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::HooksExcludedByOwner, message) where {R}
    sm.hooks = nothing
    sm.finishing = true
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::FaultedByOwner, message) where {R}
    sm.main_error === nothing && (sm.main_error = message.error)
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::FinishedByOwner, message) where {R}
    sm.hooks = nothing
    sm.finishing = true
    sm.main_finished = true
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::ClosedByOwner, message) where {R}
    sm.cancel || _stop!(sm)
    sm.hooks = nothing
    sm.finishing = true
    sm.main_finished = true
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::CancelledByOwner, message) where {R}
    _stop!(sm)
    _reply!(sm, message)
    return Hsm.EventHandled
end
@on_event function (sm::Monitor{R}, ::Monitoring, ::CancellationObserved, arg) where {R}
    # An owner cancellation with no pending native Quit still needs repeated
    # public wake: its first wake may precede main entering native run!.
    sm.cancel && sm.active === nothing && !sm.main_finished && _stop!(sm)
    return Hsm.EventHandled
end

_dispatch_owner!(sm, message::OwnerPrepared) = Hsm.dispatch!(sm, :PreparedByOwner, message)
_dispatch_owner!(sm, message::ConnectTaken) =
    Hsm.dispatch!(sm, :ConnectTakenByOwner, message)
_dispatch_owner!(sm, message::ConnectChecked) =
    Hsm.dispatch!(sm, :ConnectCheckedByOwner, message)
_dispatch_owner!(sm, message::ConnectAwaited) =
    Hsm.dispatch!(sm, :ConnectAwaitedByOwner, message)
_dispatch_owner!(sm, message::ConnectionRegistered) =
    Hsm.dispatch!(sm, :ConnectionRegisteredByOwner, message)
_dispatch_owner!(sm, message::ConnectCompleted) =
    Hsm.dispatch!(sm, :ConnectCompletedByOwner, message)
_dispatch_owner!(sm, message::HooksExcluded) =
    Hsm.dispatch!(sm, :HooksExcludedByOwner, message)
_dispatch_owner!(sm, message::OwnerFault) = Hsm.dispatch!(sm, :FaultedByOwner, message)
_dispatch_owner!(sm, message::OwnerFinished) = Hsm.dispatch!(sm, :FinishedByOwner, message)
_dispatch_owner!(sm, message::OwnerClosed) = Hsm.dispatch!(sm, :ClosedByOwner, message)
_dispatch_owner!(sm, message::OwnerCancelled) =
    Hsm.dispatch!(sm, :CancelledByOwner, message)
function _precompile_owner_routes!(::Type{M}) where {M<:Monitor}
    # Channel erases the concrete message type at the consumer boundary. Warm
    # every bounded route before admission; first-use compilation of registration
    # must not consume an already accepted native ticket's deadline.
    for message in (
        OwnerPrepared,
        ConnectTaken,
        ConnectChecked,
        ConnectAwaited,
        ConnectionRegistered,
        ConnectCompleted,
        HooksExcluded,
        OwnerFault,
        OwnerFinished,
        OwnerClosed,
        OwnerCancelled,
    )
        precompile(_dispatch_owner!, (M, message)) ||
            error("cannot compile native bootstrap owner message before startup")
    end
    return nothing
end
function _drain_owner!(sm::Monitor)
    work = 0
    # A finite per-direction budget keeps native duties responsive under callers.
    for channel in (sm.runtime.mailbox.cleanup, sm.runtime.mailbox.owner)
        for _ in 1:MAILBOX_CAPACITY
            isready(channel) || break
            message = Base.take!(channel)
            try
                _dispatch_owner!(sm, message)
            catch error
                _reply!(sm, message; error)
            end
            work += 1
        end
    end
    return work
end

function Agent.on_start(sm::Monitor)
    sm.ready = true
    _observe!(sm)
    return nothing
end
function Agent.do_work(sm::Monitor)
    current_task() === sm.owner || error("bootstrap monitor belongs to its reserved task")
    Clocks.update!(sm.clock, Clocks.time_nanos(sm.source_clock))
    Hsm.dispatch!(sm, :PollTransport)
    work = _drain_owner!(sm)
    Hsm.dispatch!(sm, :CancellationObserved)
    facts = _facts(sm)
    Hsm.dispatch!(sm, :OwnerObserved, facts)
    Hsm.isrunning(sm) || return work
    Hsm.dispatch!(sm, :TakeIngress)
    _dispatch_request!(sm, sm.incoming)
    Hsm.dispatch!(sm, :TicketObserved, facts)
    Hsm.isrunning(sm) || return work
    Hsm.dispatch!(sm, :FinishedObserved, facts)
    return work
end
function Agent.on_close(sm::Monitor)
    # Release-publish exclusion before waking senders/reply readers. No hook can
    # be invoked after this point, including when the monitor failed unexpectedly.
    sm.hooks = nothing
    sm.finishing = true
    sm.done = true
    _observe!(sm)
    for channel in (sm.runtime.mailbox.cleanup, sm.runtime.mailbox.owner)
        close(channel)
        while isready(channel)
            message = Base.take!(channel)
            put!(
                message.reply,
                OwnerReply(
                    nothing,
                    something(
                        sm.failure,
                        InvalidStateException("bootstrap monitor closed", :closed),
                    ),
                ),
            )
        end
    end
    return nothing
end

function _idle!()
    # Julia Timer progress can depend on the construction thread's libuv loop.
    # This ordinary cold syscall stays responsive while main is in native code.
    @ccall gc_safe = true usleep(Cuint(5000)::Cuint)::Cint
    yield()
    return nothing
end
function serve!(
    runtime::Runtime; clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock()
)
    bind(runtime.mailbox.owner, current_task())
    bind(runtime.mailbox.cleanup, current_task())
    sm = Monitor(runtime; clock)
    invoker = Agent.AgentInvoker(sm)
    try
        Agent.start(invoker)
        while Hsm.isrunning(sm)
            try
                Agent.invoke_unchecked(invoker)
                Hsm.isrunning(sm) && _idle!()
            catch error
                Hsm.dispatch!(sm, :MonitorFailed, error)
            end
        end
    finally
        close(invoker)
    end
    return nothing
end
function Base.close(runtime::Runtime)
    _cleanup_request!(runtime, OwnerClosed(Channel{OwnerReply}(1)))
    runtime.monitor === nothing || wait(runtime.monitor)
    close(runtime.transport)
    return nothing
end

"""
    with_owner(f, options)

Publish the native bootstrap `Preparing` endpoint before running cold owner
construction on the caller thread. Call `f` with `options` extended by
`bootstrap_runtime` and `owner_check`; the latter checks preparation failure and
cooperative cancellation. Retain primary and cleanup failures in order, and
treat an interrupt after accepted cancellation as clean owner shutdown.
"""
function with_owner(f, options; application_name::AbstractString = options.bootstrap_node)
    runtime = Runtime(
        options.remote, options.bootstrap_node, options.bootstrap_instance; application_name
    )
    return _with_owner(f, options, runtime)
end

function _record_owner_failure!(failures, runtime, error)
    push!(failures, error)
    fault!(runtime, error)
    return nothing
end
function _record_owner_failure!(failures, runtime, error::InterruptException)
    cancelled(runtime) && return nothing
    push!(failures, error)
    fault!(runtime, error)
    return nothing
end

function _with_owner(f, options, runtime)
    failures = Exception[]
    admitted = merge(
        options,
        (; bootstrap_runtime = runtime, owner_check = () -> preparation_check!(runtime)),
    )
    try
        f(admitted)
    catch error
        _record_owner_failure!(failures, runtime, error)
    finally
        try
            finish!(runtime)
        catch error
            push!(failures, error)
        end
        try
            close(runtime)
        catch error
            push!(failures, error)
        end
    end
    isempty(failures) ||
        throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    return nothing
end

end # module OwnerBootstrapRuntime
