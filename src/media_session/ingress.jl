"""Pure native session admission and journal ordering, owned by the session task."""
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
payload, absolute nanosecond deadline and exact controller identity/name. Only
the serialized session task consumes them; retaining a ticket does not authorize
another dispatch or retry. The ingress gate owns its dispatch/journal ordering.
"""
abstract type AbstractTicket end
struct Ticket{C} <: AbstractTicket
    header::Envelope.RequestHeader
    command::C
    payload::Vector{UInt8}
    deadline::Int64
    controller::Identity
    client_name::String
end
mutable struct Attempt{T<:AbstractTicket}
    ticket::T
    dispatched::Bool
    job::UInt64
    record::Union{Nothing,Pod}
    cancelled::Bool
end
Attempt(ticket::Ticket) = Attempt(ticket, false, UInt64(0), nothing, false)
"""One bounded instruction from ingress to its serialized session host.

The host dispatches `DispatchRequest`, publishes `PublishRecords`, submits
`AppendJournal` and reports `AuthorityFailed` through concrete action methods.
Journal results return as correlated gate events; emitting an action itself
does not establish successful I/O. No action directly mutates the session Hsm.
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
struct AppendJournal{T<:AbstractTicket} <: AbstractAction
    id::UInt64
    ticket::T
    event::Symbol
    pod::Pod
end
struct AuthorityFailed <: AbstractAction
    message::String
end

@hsmdef mutable struct Gate{C<:Clocks.AbstractNanoClock}
    instance::Int64
    owner_pid::UInt32
    clock::C
    journaled::Bool
    lifecycle::RunnerCodec.Lifecycle
    last_token::Int64
    controllers::Vector{ControllerRecord}
    pending::Union{Nothing,Attempt}
    retired::Union{Nothing,Attempt}
    terminal_request::Union{Nothing,AbstractTicket}
    completion::Pod
    rejection::Pod
    next_job::UInt64
    actions::Vector{AbstractAction}
    delivery::Vector{AbstractAction}
end
@statedef Gate :Open
@statedef Gate :Idle :Open
@statedef Gate :Pending :Open
@statedef Gate :WaitingRequested :Pending
@statedef Gate :Applying :Pending
@statedef Gate :WaitingTerminal :Pending
@statedef Gate :Closing
@statedef Gate :QuitApplying :Closing
@statedef Gate :QuitWaitingTerminal :Closing
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
    _reply_header(gate, ticket.header, -5),
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
        attempt === nothing ||
            !_same_request(attempt.ticket, header, payload) ||
            return true
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
            _reject!(gate, header, -116, "Stale endpoint/controller incarnation")
            return nothing
        end
        if _duplicate(gate, header, canonical.data)
            _publish!(gate)
            return nothing
        end
        header.budget_ns <= 60_000_000_000 || throw(ArgumentError("invalid request budget"))
        deadline = Base.Checked.checked_add(received, header.budget_ns)
        return Ticket(
            header,
            command,
            copy(canonical.data),
            deadline,
            controller.identity,
            controller.name,
        )
    catch
        # Malformed requests never acquire a trusted request identity.
        _reject!(gate, nothing, -22, "Malformed session request")
        return nothing
    end
end
_journaled(::RunnerCodec.RunnerCommand{:properties_set}) = true
_journaled(::RunnerCodec.RunnerCommand{:parameter}) = true
_journaled(command) = false
function _append!(gate, attempt, event, pod)
    gate.next_job < typemax(UInt64) ||
        throw(ArgumentError("journal correlation space exhausted"))
    gate.next_job += 1
    attempt.job = gate.next_job
    _emit!(gate, AppendJournal(attempt.job, attempt.ticket, event, pod))
end
function _dispatch!(gate, attempt)
    attempt.dispatched = true
    _emit!(gate, DispatchRequest(attempt.ticket))
end
function _accept!(gate, ticket)
    if ticket.header.token <= gate.last_token
        _reject!(gate, ticket.header, -116, "Session token already used or superseded")
        return false
    end
    if _now(gate) >= ticket.deadline
        _reject!(gate, ticket.header, -110, "Request budget expired in transport handoff")
        return false
    end
    gate.last_token = ticket.header.token
    attempt = Attempt(ticket)
    gate.pending = attempt
    if gate.journaled && _journaled(ticket.command)
        _append!(gate, attempt, :requested, Pod(ticket.payload))
    else
        _dispatch!(gate, attempt)
    end
    return true
end
function _locate(gate, ticket)
    for attempt in (gate.pending, gate.retired)
        attempt === nothing || attempt.ticket !== ticket || return attempt
    end
    return nothing
end
function _publish_terminal!(gate, attempt, pod)
    ticket = attempt.ticket
    if gate.terminal_request === nothing ||
        ticket.header.token > gate.terminal_request.header.token
        gate.terminal_request = ticket
        gate.completion = pod
    end
    gate.pending === attempt && (gate.pending = nothing)
    gate.retired === attempt && (gate.retired = nothing)
    attempt.job = 0
    _publish!(gate)
end
function _finish!(gate, attempt, pod; unknown = false)
    attempt.record === nothing || return nothing
    attempt.record = pod
    if gate.journaled && _journaled(attempt.ticket.command)
        _append!(gate, attempt, unknown ? :unknown : :completed, pod)
    else
        _publish_terminal!(gate, attempt, pod)
    end
    return nothing
end
function _cancel!(gate, attempt, message; authority = true)
    attempt.cancelled && return nothing
    attempt.cancelled = true
    unknown = attempt.dispatched
    unknown &&
        authority &&
        _emit!(gate, AuthorityFailed(message * "; effect outcome unknown"))
    # Fence any original append before staging the replacement terminal record.
    attempt.job = 0
    attempt.record = nothing
    _finish!(
        gate,
        attempt,
        _failure(
            gate,
            attempt.ticket,
            message *
            (unknown ? "; effect outcome unknown" : "; no scientific effect issued"),
        );
        unknown,
    )
    return nothing
end
function _check!(gate)
    for attempt in (gate.pending, gate.retired)
        attempt === nothing && continue
        attempt.cancelled && continue
        _controller(gate, attempt.ticket.header) === nothing &&
            (_cancel!(gate, attempt, "Session controller disappeared or changed"); continue)
        _now(gate) >= attempt.ticket.deadline &&
            _cancel!(gate, attempt, "Session request expired")
    end
end
_closing(gate) = Hsm.current(gate) in (:QuitApplying, :QuitWaitingTerminal, :Closed)
function _state_after(gate; closing = _closing(gate))
    attempt = gate.pending
    attempt === nothing && return closing ? :Closed : :Idle
    if closing
        return attempt.record === nothing ? :QuitApplying : :QuitWaitingTerminal
    end
    attempt.record !== nothing && return :WaitingTerminal
    return attempt.dispatched ? :Applying : :WaitingRequested
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
    elseif nextstate === :WaitingRequested
        return Hsm.transition!(gate, :WaitingRequested)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :WaitingTerminal
        return Hsm.transition!(gate, :WaitingTerminal)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    elseif nextstate === :QuitWaitingTerminal
        return Hsm.transition!(gate, :QuitWaitingTerminal)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Pending, ::Received, event)
    ticket = _candidate!(gate, event.pod, event.received)
    ticket === nothing && return Hsm.EventHandled
    if ticket.header.operation != QUIT_OPERATION
        _reject!(gate, ticket.header, -16, "Session operation already pending")
        return Hsm.EventHandled
    end
    if ticket.header.token <= gate.last_token || _now(gate) >= ticket.deadline
        _reject!(
            gate,
            ticket.header,
            ticket.header.token <= gate.last_token ? -116 : -110,
            "Stale or expired shutdown request",
        )
        return Hsm.EventHandled
    end
    gate.retired === nothing ||
        throw(ArgumentError("retired public request slot is occupied"))
    old = gate.pending
    gate.retired = old
    gate.pending = nothing
    old.dispatched ||
        _cancel!(gate, old, "Session request superseded by Quit"; authority = false)
    _accept!(gate, ticket)
    nextstate = _state_after(gate; closing = true)
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :WaitingRequested
        return Hsm.transition!(gate, :WaitingRequested)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :WaitingTerminal
        return Hsm.transition!(gate, :WaitingTerminal)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    elseif nextstate === :QuitWaitingTerminal
        return Hsm.transition!(gate, :QuitWaitingTerminal)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Closing, ::Received, event)
    ticket = _candidate!(gate, event.pod, event.received)
    ticket === nothing ||
        _reject!(gate, ticket.header, -108, "Session shutdown already accepted")
    return Hsm.EventHandled
end
@on_event function (gate::Gate, ::Root, ::Controllers, observed)
    _update_controllers!(gate, observed)
    nextstate = _state_after(gate)
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :WaitingRequested
        return Hsm.transition!(gate, :WaitingRequested)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :WaitingTerminal
        return Hsm.transition!(gate, :WaitingTerminal)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    elseif nextstate === :QuitWaitingTerminal
        return Hsm.transition!(gate, :QuitWaitingTerminal)
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
    elseif nextstate === :WaitingRequested
        return Hsm.transition!(gate, :WaitingRequested)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :WaitingTerminal
        return Hsm.transition!(gate, :WaitingTerminal)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    elseif nextstate === :QuitWaitingTerminal
        return Hsm.transition!(gate, :QuitWaitingTerminal)
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
    elseif nextstate === :WaitingRequested
        return Hsm.transition!(gate, :WaitingRequested)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :WaitingTerminal
        return Hsm.transition!(gate, :WaitingTerminal)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    elseif nextstate === :QuitWaitingTerminal
        return Hsm.transition!(gate, :QuitWaitingTerminal)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Root, ::Completed, event)
    _check!(gate)
    attempt = _locate(gate, event.ticket)
    if attempt !== nothing &&
        attempt.dispatched &&
        !attempt.cancelled &&
        attempt.record === nothing
        header, _ = Envelope.decode_completion(event.pod; endpoint = :lifecycle)
        request = attempt.ticket.header
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
                attempt.ticket,
                "Scientific operation outcome unavailable; effect outcome unknown",
            ) : event.pod
        _finish!(gate, attempt, record; unknown = event.unknown)
    end
    nextstate = _state_after(gate)
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :WaitingRequested
        return Hsm.transition!(gate, :WaitingRequested)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :WaitingTerminal
        return Hsm.transition!(gate, :WaitingTerminal)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    elseif nextstate === :QuitWaitingTerminal
        return Hsm.transition!(gate, :QuitWaitingTerminal)
    else
        return Hsm.transition!(gate, :Closed)
    end
end
@on_event function (gate::Gate, ::Root, ::JournalReceipt, event)
    _check!(gate)
    for attempt in (gate.pending, gate.retired)
        attempt === nothing && continue
        attempt.job == event.id && event.id != 0 || continue
        attempt.job = 0
        if attempt.record === nothing
            if event.success
                _dispatch!(gate, attempt)
            else
                _publish_terminal!(
                    gate,
                    attempt,
                    _failure(
                        gate,
                        attempt.ticket,
                        "Journal failed before dispatch; no scientific effect issued: " *
                        event.message,
                    ),
                )
            end
        elseif event.success
            _publish_terminal!(gate, attempt, attempt.record)
        else
            if attempt.dispatched
                _emit!(
                    gate,
                    AuthorityFailed(
                        "Journal persistence failed after dispatch; effect outcome unknown"
                    ),
                )
            end
            message =
                attempt.dispatched ?
                "Journal persistence failed; effect outcome unknown: " :
                "Journal persistence failed before dispatch: "
            _publish_terminal!(
                gate, attempt, _failure(gate, attempt.ticket, message * event.message)
            )
        end
        break
    end
    nextstate = _state_after(gate)
    nextstate == Hsm.current(gate) && return Hsm.EventHandled
    if nextstate === :Idle
        return Hsm.transition!(gate, :Idle)
    elseif nextstate === :WaitingRequested
        return Hsm.transition!(gate, :WaitingRequested)
    elseif nextstate === :Applying
        return Hsm.transition!(gate, :Applying)
    elseif nextstate === :WaitingTerminal
        return Hsm.transition!(gate, :WaitingTerminal)
    elseif nextstate === :QuitApplying
        return Hsm.transition!(gate, :QuitApplying)
    elseif nextstate === :QuitWaitingTerminal
        return Hsm.transition!(gate, :QuitWaitingTerminal)
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
    journaled = false,
    owner_pid::Integer = getpid(),
)
    0 < instance <= typemax(Int64) && 0 < owner_pid < typemax(UInt32) ||
        throw(ArgumentError("invalid session endpoint incarnation"))
    initial = Envelope.ReplyHeader(Int64(instance), Int32(0))
    completion = Envelope.encode_completion(initial, _struct(); endpoint = :lifecycle)
    rejection = Envelope.encode_rejection(
        Envelope.ReplyHeader(Int64(instance), Int32(-11)),
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
        journaled,
        RunnerCodec.Offline,
        Int64(0),
        ControllerRecord[],
        nothing,
        nothing,
        nothing,
        completion,
        rejection,
        UInt64(0),
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
journal_receipt!(gate::Gate, id::Integer, success::Bool, message::AbstractString = "") = (
    Hsm.dispatch!(
        gate,
        :JournalReceipt,
        (id = UInt64(id), success = success, message = _message(message)),
    );
    nothing
)
take_actions!(gate::Gate) = (Hsm.dispatch!(gate, :TakeActions); gate.delivery)

export Gate,
    Controller,
    Ticket,
    AbstractAction,
    DispatchRequest,
    PublishRecords,
    AppendJournal,
    AuthorityFailed,
    receive!,
    controllers!,
    controller_removed!,
    state!,
    tick!,
    complete!,
    journal_receipt!,
    take_actions!
end
