"""Pure native session admission and completion ordering, owned by the session task."""
module Ingress
using PipeWireAO
using Hsm: @hsmdef, @statedef, @on_initial, @on_event
import Hsm
import Clocks
import ..Identity
import ..QUIT_OPERATION
import ...ControlCodec
import ...ControlClient
import ...RunnerCodec
import ...SessionCodec
const SPA = PipeWireAO.SPA
const Envelope = ControlCodec
const PREFIX = "pipewireao.rtc.session."
const MAX_CONTROLLERS = 32
const MAX_ACTIONS = 32
const WARMUP_OPERATION = SessionCodec.operation_id(SessionCodec.WarmupCommand())
const ADMIT_OPERATION = SessionCodec.operation_id(SessionCodec.AdmitCommand())

"Full copied controller NodeInfo facts; invalid or changed facts never confer authority."
struct Controller
    identity::Identity
    name::String
    input_ports::UInt32
    output_ports::UInt32
    protocol::String
    profile::String
    full_info::Bool
    bound::Bool
end
Base.:(==)(left::Controller, right::Controller) =
    left.identity == right.identity &&
    left.name == right.name &&
    left.input_ports == right.input_ports &&
    left.output_ports == right.output_ports &&
    left.protocol == right.protocol &&
    left.profile == right.profile &&
    left.full_info == right.full_info &&
    left.bound == right.bound
Controller(
    identity::Identity,
    name::AbstractString;
    input_ports::Integer = 0,
    output_ports::Integer = 0,
    protocol = ControlClient.PROTOCOL,
    profile = ControlClient.CONTROLLER_PROFILE,
    full_info = true,
    bound = true,
) = Controller(
    identity,
    String(name),
    UInt32(input_ports),
    UInt32(output_ports),
    String(protocol),
    String(profile),
    full_info,
    bound,
)
mutable struct ControllerRecord
    facts::Controller
    retired::Bool
end
"""An owned, admitted native request retained until its terminal publication.

Concrete tickets carry a validated envelope header, decoded command, copied
payload, absolute nanosecond deadline and exact controller identity. Only
the serialized session task consumes them; retaining a ticket does not authorize
another dispatch or retry. The ingress gate owns dispatch and completion ordering.
"""
abstract type AbstractTicket end
struct Ticket{C} <: AbstractTicket
    header::Envelope.RequestHeader
    command::C
    payload::Vector{UInt8}
    deadline::Int64
    controller::Identity
end
"""One bounded instruction from ingress to its serialized session host.

The host dispatches `DispatchRequest`, publishes `PublishRecords` and reports
`AuthorityFailed` through concrete action methods. Emitting a dispatch action
does not establish a successful effect. No action directly mutates the session Hsm.
"""
abstract type AbstractAction end
struct DispatchRequest{T<:AbstractTicket} <: AbstractAction
    ticket::T
end
struct PublishRecords <: AbstractAction
    capability::Pod
    completion::Pod
    rejection::Pod
end
struct AuthorityFailed <: AbstractAction
    message::String
end

@hsmdef mutable struct Gate{C<:Clocks.AbstractNanoClock}
    instance::Int64
    owner_pid::UInt32
    clock::C
    lifecycle::RunnerCodec.Lifecycle
    last_token::Int64
    controllers::Vector{ControllerRecord}
    pending::Union{Nothing,AbstractTicket}
    retired::Union{Nothing,AbstractTicket}
    terminal_request::Union{Nothing,AbstractTicket}
    completion::Pod
    rejection::Pod
    actions::Vector{AbstractAction}
    delivery::Vector{AbstractAction}
end
@statedef Gate :Open
@statedef Gate :Idle :Open
@statedef Gate :Applying :Open
@statedef Gate :Closing
@statedef Gate :QuitApplying :Closing
@statedef Gate :Closed :Closing
@on_initial function (gate::Gate, ::Root)
    return Hsm.transition!(gate, :Idle)
end
_struct(values::Pod...) = SPA.Struct(Pod[values...])
_now(gate)::Int64 = Clocks.time_nanos(gate.clock)
function _emit!(gate, action::AbstractAction)
    length(gate.actions) < MAX_ACTIONS ||
        throw(ArgumentError("drain ingress actions before dispatching more events"))
    push!(gate.actions, action)
    return nothing
end
function _valid(facts::Controller)
    i = facts.identity
    return 0 < i.global_id < typemax(UInt32) &&
           i.serial > 0 &&
           0 < i.instance <= typemax(Int64) &&
           0 < i.pid < typemax(UInt32) &&
           isvalid(facts.name) &&
           0 < ncodeunits(facts.name) <= 4096 &&
           !occursin('\0', facts.name) &&
           facts.full_info &&
           facts.bound &&
           facts.input_ports == 0 &&
           facts.output_ports == 0 &&
           facts.protocol == ControlClient.PROTOCOL &&
           facts.profile == ControlClient.CONTROLLER_PROFILE
end
_same_incarnation(a::Identity, b::Identity) =
    a.global_id == b.global_id && a.serial == b.serial && a.instance == b.instance
_same_facts(a::Controller, b::Controller) =
    a.identity == b.identity && a.name == b.name && _valid(b)
function _controller(gate, header)
    for record in gate.controllers
        i = record.facts.identity
        !record.retired &&
            i.global_id == header.controller.global_id &&
            i.serial == header.controller.serial &&
            i.instance == UInt64(header.controller.instance) &&
            return record.facts
    end
    return nothing
end
function _capability(gate)
    rows = Pod[]
    for record in gate.controllers
        record.retired && continue
        i = record.facts.identity
        push!(
            rows,
            Pod(
                _struct(
                    Pod(SPA.Id(i.global_id)),
                    Pod(reinterpret(Int64, i.serial)),
                    Pod(Int64(i.instance)),
                ),
            ),
        )
    end
    names = ("version", "instance", "owner-pid", "lifecycle", "last-token", "controllers")
    values = Pod[
        Pod(Int32(1)),
        Pod(gate.instance),
        Pod(SPA.Id(gate.owner_pid)),
        Pod(SPA.Id(UInt32(gate.lifecycle))),
        Pod(gate.last_token),
        Pod(SPA.Struct(rows)),
    ]
    pod = Pod(
        props_param(SPA.Props([PREFIX * names[i] => values[i] for i in eachindex(names)]))
    )
    sizeof(pod) <= 64 * 1024 ||
        throw(ArgumentError("session capability exceeds native reply bound"))
    return pod
end
_publish!(gate) =
    _emit!(gate, PublishRecords(_capability(gate), gate.completion, gate.rejection))
_reply_header(gate, ::Nothing, result) = Envelope.ReplyHeader(gate.instance, Int32(result))
_reply_header(gate, header::Envelope.RequestHeader, result) = Envelope.ReplyHeader(
    header.controller, gate.instance, header.token, header.operation, Int32(result)
)
_message(value) = first(replace(String(value), '\0' => '?'), 2048)
_error_payload(gate, message) =
    _struct(Pod("session"), Pod(_message(message)), Pod(SPA.Id(UInt32(gate.lifecycle))))
function _reject!(gate, header, result, message)
    gate.rejection = Envelope.encode_rejection(
        _reply_header(gate, header, result),
        _error_payload(gate, message);
        endpoint = :lifecycle,
    )
    _publish!(gate)
end
_failure(gate, ticket, message) = Envelope.encode_completion(
    _reply_header(gate, ticket.header, -Base.Libc.EIO),
    _error_payload(gate, message);
    endpoint = :lifecycle,
)
function _same_request(ticket::AbstractTicket, header, payload)
    a = ticket.header
    return a.version == header.version &&
           a.endpoint_instance == header.endpoint_instance &&
           a.controller == header.controller &&
           a.token == header.token &&
           a.operation == header.operation &&
           a.budget_ns == header.budget_ns &&
           ticket.payload == payload
end
function _duplicate(gate, header, payload)
    for attempt in (gate.pending, gate.retired)
        attempt === nothing || !_same_request(attempt, header, payload) || return true
    end
    return gate.terminal_request !== nothing &&
           _same_request(gate.terminal_request, header, payload)
end
function _command(header, payload)
    if header.operation in (WARMUP_OPERATION, ADMIT_OPERATION)
        isempty(payload.values) ||
            throw(ArgumentError("administrative request requires empty Struct"))
        return header.operation == WARMUP_OPERATION ? SessionCodec.WarmupCommand() :
               SessionCodec.AdmitCommand()
    end
    return RunnerCodec.decode_request(header, payload)
end
_canonical(header, command::RunnerCodec.RunnerCommand) =
    RunnerCodec.encode_request(header, command)
_canonical(header, command::Union{SessionCodec.WarmupCommand,SessionCodec.AdmitCommand}) =
    SessionCodec.encode_request(header, command)
function _candidate!(gate, pod, received::Int64)
    header = nothing
    try
        pod === nothing && throw(ArgumentError("rejected native parameter"))
        header, payload = Envelope.decode_request(pod)
        command = _command(header, payload)
        canonical = _canonical(header, command)
        controller = _controller(gate, header)
        if header.endpoint_instance != gate.instance || controller === nothing
            _reject!(gate, header, -Base.Libc.ESTALE, "Stale endpoint/controller incarnation")
            return nothing
        end
        if _duplicate(gate, header, canonical.data)
            _publish!(gate)
            return nothing
        end
        header.budget_ns <= 60_000_000_000 || throw(ArgumentError("invalid request budget"))
        deadline = Base.Checked.checked_add(received, header.budget_ns)
        return Ticket(header, command, copy(canonical.data), deadline, controller.identity)
    catch
        # Malformed requests never acquire a trusted request identity.
        _reject!(gate, nothing, -Base.Libc.EINVAL, "Malformed session request")
        return nothing
    end
end
function _accept!(gate, ticket)
    if ticket.header.token <= gate.last_token
        _reject!(gate, ticket.header, -Base.Libc.ESTALE, "Session token already used or superseded")
        return false
    end
    if _now(gate) >= ticket.deadline
        _reject!(
            gate, ticket.header, -Base.Libc.ETIMEDOUT, "Request budget expired in transport handoff"
        )
        return false
    end
    gate.last_token = ticket.header.token
    gate.pending = ticket
    _emit!(gate, DispatchRequest(ticket))
    return true
end
function _locate(gate, ticket)
    for attempt in (gate.pending, gate.retired)
        attempt === nothing || attempt !== ticket || return attempt
    end
    return nothing
end
function _finish!(gate, ticket, pod)
    if gate.terminal_request === nothing ||
        ticket.header.token > gate.terminal_request.header.token
        gate.terminal_request = ticket
        gate.completion = pod
    end
    gate.pending === ticket && (gate.pending = nothing)
    gate.retired === ticket && (gate.retired = nothing)
    _publish!(gate)
end
function _cancel!(gate, ticket, message)
    _emit!(gate, AuthorityFailed(message * "; effect outcome unknown"))
    _finish!(gate, ticket, _failure(gate, ticket, message * "; effect outcome unknown"))
    return nothing
end
function _check!(gate)
    for attempt in (gate.pending, gate.retired)
        attempt === nothing && continue
        _controller(gate, attempt.header) === nothing &&
            (_cancel!(gate, attempt, "Session controller disappeared or changed"); continue)
        _now(gate) >= attempt.deadline && _cancel!(gate, attempt, "Session request expired")
    end
end
_closing(gate) = Hsm.current(gate) in (:QuitApplying, :Closed)
function _state_after(gate; closing = _closing(gate))
    gate.pending === nothing && return closing ? :Closed : :Idle
    return closing ? :QuitApplying : :Applying
end
function _update_controllers!(gate, observed::Vector{Controller})
    length(observed) <= MAX_CONTROLLERS ||
        throw(ArgumentError("too many native controller observations"))
    length(unique(facts.identity.global_id for facts in observed)) == length(observed) ||
        throw(ArgumentError("duplicate controller global ID"))
    for record in gate.controllers
        index = findfirst(
            facts -> _same_incarnation(facts.identity, record.facts.identity), observed
        )
        if index === nothing || !_same_facts(record.facts, observed[index])
            record.retired = true
        end
    end
    for facts in observed
        _valid(facts) || continue
        any(
            record -> _same_incarnation(record.facts.identity, facts.identity),
            gate.controllers,
        ) && continue
        length(gate.controllers) < MAX_CONTROLLERS || continue
        push!(gate.controllers, ControllerRecord(facts, false))
    end
    _check!(gate)
    _publish!(gate)
end

# Hsm requires literal transition targets inside each handler. Controller absence
# retires authority; only a native removal proof reclaims its bounded record.
@on_event function (gate::Gate, ::Root, ::Boot, _)
    _publish!(gate)
    return Hsm.EventHandled
end
@on_event function (gate::Gate, ::Idle, ::Received, event)
    ticket = _candidate!(gate, event.pod, event.received)
    ticket === nothing && return Hsm.EventHandled
    accepted = _accept!(gate, ticket)
    nextstate = _state_after(
        gate; closing = accepted && ticket.header.operation == QUIT_OPERATION
    )
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Applying, ::Received, event)
    ticket = _candidate!(gate, event.pod, event.received)
    ticket === nothing && return Hsm.EventHandled
    if ticket.header.operation != QUIT_OPERATION
        _reject!(gate, ticket.header, -Base.Libc.EBUSY, "Session operation already pending")
        return Hsm.EventHandled
    end
    if ticket.header.token <= gate.last_token || _now(gate) >= ticket.deadline
        _reject!(
            gate,
            ticket.header,
            ticket.header.token <= gate.last_token ? -Base.Libc.ESTALE : -Base.Libc.ETIMEDOUT,
            "Stale or expired shutdown request",
        )
        return Hsm.EventHandled
    end
    gate.retired === nothing ||
        throw(ArgumentError("retired public request slot is occupied"))
    gate.retired = gate.pending
    gate.pending = nothing
    _accept!(gate, ticket)
    nextstate = _state_after(gate; closing = true)
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Closing, ::Received, event)
    ticket = _candidate!(gate, event.pod, event.received)
    ticket === nothing ||
        _reject!(gate, ticket.header, -Base.Libc.ESHUTDOWN, "Session shutdown already accepted")
    return Hsm.EventHandled
end
@on_event function (gate::Gate, ::Root, ::Controllers, observed)
    _update_controllers!(gate, observed)
    nextstate = _state_after(gate)
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Root, ::ControllerRemoved, event)
    filter!(
        record -> !(
            record.facts.identity.global_id == event.global_id &&
            record.facts.identity.serial == event.serial
        ),
        gate.controllers,
    )
    _check!(gate)
    _publish!(gate)
    nextstate = _state_after(gate)
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Root, ::LifecycleObserved, state)
    gate.lifecycle = state
    _publish!(gate)
    return Hsm.EventHandled
end
@on_event function (gate::Gate, ::Root, ::Tick, _)
    _check!(gate)
    nextstate = _state_after(gate)
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Root, ::Completed, event)
    _check!(gate)
    attempt = _locate(gate, event.ticket)
    if attempt !== nothing
        header, _ = Envelope.decode_completion(event.pod; endpoint = :lifecycle)
        request = attempt.header
        header.endpoint_instance == request.endpoint_instance &&
        header.controller == request.controller &&
        header.token == request.token &&
        header.operation == request.operation ||
            throw(ArgumentError("completion does not match public ticket"))
        SessionCodec.decode_completion(event.pod)
        event.terminal &&
            request.operation != QUIT_OPERATION &&
            throw(ArgumentError("terminal closure requires Quit"))
        record =
            event.unknown && header.result == 0 ?
            _failure(
                gate,
                attempt,
                "Scientific operation outcome unavailable; effect outcome unknown",
            ) : event.pod
        _finish!(gate, attempt, record)
    end
    nextstate = _state_after(gate)
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Root, ::TakeActions, _)
    gate.delivery = copy(gate.actions)
    empty!(gate.actions)
    return Hsm.EventHandled
end
function Gate(
    instance::Integer;
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
    owner_pid::Integer = getpid(),
)
    0 < instance <= typemax(Int64) && 0 < owner_pid < typemax(UInt32) ||
        throw(ArgumentError("invalid session endpoint incarnation"))
    initial = Envelope.ReplyHeader(Int64(instance), Int32(0))
    completion = Envelope.encode_completion(initial, _struct(); endpoint = :lifecycle)
    rejection = Envelope.encode_rejection(
        Envelope.ReplyHeader(Int64(instance), Int32(-Base.Libc.EAGAIN)),
        _struct(
            Pod("session"),
            Pod("No rejected request"),
            Pod(SPA.Id(UInt32(RunnerCodec.Offline))),
        );
        endpoint = :lifecycle,
    )
    gate = Gate(
        Int64(instance),
        UInt32(owner_pid),
        clock,
        RunnerCodec.Offline,
        Int64(0),
        ControllerRecord[],
        nothing,
        nothing,
        nothing,
        completion,
        rejection,
        AbstractAction[],
        AbstractAction[],
    )
    Hsm.dispatch!(gate, :Boot)
    return gate
end
"""Receive an owned native POD with its producer's signed nanosecond receipt.

The receipt and clock share the Clocks.time_nanos domain. Queue delay consumes
the original budget; an unrepresentable deadline rejects before admission.
"""
receive!(gate::Gate, pod::Union{Nothing,Pod}, received::Int64) =
    (Hsm.dispatch!(gate, :Received, (; pod, received)); nothing)
controllers!(gate::Gate, observed::Vector{Controller}) =
    (Hsm.dispatch!(gate, :Controllers, observed); nothing)
controller_removed!(gate::Gate, global_id::UInt32, serial::UInt64) =
    (Hsm.dispatch!(gate, :ControllerRemoved, (; global_id, serial)); nothing)
state!(gate::Gate, lifecycle::RunnerCodec.Lifecycle) =
    (Hsm.dispatch!(gate, :LifecycleObserved, lifecycle); nothing)
tick!(gate::Gate) = (Hsm.dispatch!(gate, :Tick); nothing)
complete!(gate::Gate, ticket::AbstractTicket, pod::Pod; unknown = false, terminal = false) =
    (Hsm.dispatch!(gate, :Completed, (; ticket, pod, unknown, terminal)); nothing)
take_actions!(gate::Gate) = (Hsm.dispatch!(gate, :TakeActions); gate.delivery)

export Gate,
    Controller,
    Ticket,
    AbstractAction,
    DispatchRequest,
    PublishRecords,
    AuthorityFailed,
    receive!,
    controllers!,
    controller_removed!,
    state!,
    tick!,
    complete!,
    take_actions!
end
