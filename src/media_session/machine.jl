const SESSION_EFFECT_TIMEOUT_NS = Int64(5_000_000_000)
const DEFAULT_STARTUP_TIMEOUT_NS = Int64(300_000_000_000)
const MIN_STARTUP_TIMEOUT_NS = Int64(1_000_000_000)
const MAX_STARTUP_TIMEOUT_NS = Int64(3_600_000_000_000)

"""Exact native endpoint/controller incarnation, including its owning process."""
struct Identity
    global_id::UInt32
    serial::UInt64
    instance::UInt64
    pid::UInt32
end

"Lifecycle evidence retained when an operation temporarily leaves its admitted state."
abstract type AbstractOrigin end
struct OfflineOrigin <: AbstractOrigin end
struct ConfiguringOrigin <: AbstractOrigin end
struct ReadyOrigin <: AbstractOrigin end
struct RunningOrigin <: AbstractOrigin end
struct FaultOrigin <: AbstractOrigin end

"Closed session operation interface: `operation(command)` is its codec-defined wire ID."
abstract type AbstractCommand end
struct Quit <: AbstractCommand end

const QUIT_OPERATION = RunnerCodec.operation_id(RunnerCodec.RunnerCommand(:quit))
operation(::Quit) = QUIT_OPERATION

_command(::Val{QUIT_OPERATION}) = Quit()

struct Groups <: AbstractCommand end

const GROUPS_OPERATION = RunnerCodec.operation_id(RunnerCodec.RunnerCommand(:groups))
operation(::Groups) = GROUPS_OPERATION

_command(::Val{GROUPS_OPERATION}) = Groups()

struct Status <: AbstractCommand end

const STATUS_OPERATION = RunnerCodec.operation_id(RunnerCodec.RunnerCommand(:status))
operation(::Status) = STATUS_OPERATION

_command(::Val{STATUS_OPERATION}) = Status()

struct Properties <: AbstractCommand end

const PROPERTIES_OPERATION = RunnerCodec.operation_id(
    RunnerCodec.RunnerCommand(:properties)
)
operation(::Properties) = PROPERTIES_OPERATION

_command(::Val{PROPERTIES_OPERATION}) = Properties()

struct PropertyGeneration <: AbstractCommand end

const PROPERTY_GENERATION_OPERATION = RunnerCodec.operation_id(
    RunnerCodec.RunnerCommand(:property_generation)
)
operation(::PropertyGeneration) = PROPERTY_GENERATION_OPERATION

_command(::Val{PROPERTY_GENERATION_OPERATION}) = PropertyGeneration()

struct ParameterGeneration <: AbstractCommand end

const PARAMETER_GENERATION_OPERATION = RunnerCodec.operation_id(
    RunnerCodec.RunnerCommand(:parameter_generation)
)
operation(::ParameterGeneration) = PARAMETER_GENERATION_OPERATION

_command(::Val{PARAMETER_GENERATION_OPERATION}) = ParameterGeneration()

struct StopGroup <: AbstractCommand end

const STOP_GROUP_OPERATION = RunnerCodec.operation_id(
    RunnerCodec.RunnerCommand(:stop_group)
)
operation(::StopGroup) = STOP_GROUP_OPERATION

_command(::Val{STOP_GROUP_OPERATION}) = StopGroup()

struct StartGroup <: AbstractCommand end

const START_GROUP_OPERATION = RunnerCodec.operation_id(
    RunnerCodec.RunnerCommand(:start_group)
)
operation(::StartGroup) = START_GROUP_OPERATION

_command(::Val{START_GROUP_OPERATION}) = StartGroup()

struct Stop <: AbstractCommand end

const SESSION_STOP_OPERATION = RunnerCodec.operation_id(
    RunnerCodec.RunnerCommand(:session_stop)
)
operation(::Stop) = SESSION_STOP_OPERATION

_command(::Val{SESSION_STOP_OPERATION}) = Stop()

struct Start <: AbstractCommand end

const SESSION_START_OPERATION = RunnerCodec.operation_id(
    RunnerCodec.RunnerCommand(:session_start)
)
operation(::Start) = SESSION_START_OPERATION

_command(::Val{SESSION_START_OPERATION}) = Start()

struct SourceEnded <: AbstractCommand end

const SOURCE_ENDED_OPERATION = RunnerCodec.operation_id(
    RunnerCodec.RunnerCommand(:source_ended)
)
operation(::SourceEnded) = SOURCE_ENDED_OPERATION

_command(::Val{SOURCE_ENDED_OPERATION}) = SourceEnded()

struct Reset <: AbstractCommand end

const RESET_OPERATION = RunnerCodec.operation_id(RunnerCodec.RunnerCommand(:reset))
operation(::Reset) = RESET_OPERATION

_command(::Val{RESET_OPERATION}) = Reset()

struct SetProperties <: AbstractCommand end

const PROPERTIES_SET_OPERATION = RunnerCodec.operation_id(
    RunnerCodec.RunnerCommand(:properties_set)
)
operation(::SetProperties) = PROPERTIES_SET_OPERATION

_command(::Val{PROPERTIES_SET_OPERATION}) = SetProperties()

struct SetParameter <: AbstractCommand end

const PARAMETER_OPERATION = RunnerCodec.operation_id(RunnerCodec.RunnerCommand(:parameter))
operation(::SetParameter) = PARAMETER_OPERATION

_command(::Val{PARAMETER_OPERATION}) = SetParameter()

struct InspectWarmup <: AbstractCommand end

const WARMUP_OPERATION = SessionCodec.operation_id(SessionCodec.WarmupCommand())
operation(::InspectWarmup) = WARMUP_OPERATION

_command(::Val{WARMUP_OPERATION}) = InspectWarmup()

struct Admit <: AbstractCommand end

const ADMIT_OPERATION = SessionCodec.operation_id(SessionCodec.AdmitCommand())
operation(::Admit) = ADMIT_OPERATION

_command(::Val{ADMIT_OPERATION}) = Admit()

"""Owned, normalized public request. Deadlines are absolute signed monotonic nanoseconds.

The ingress proves the native controller record and copies the payload before
constructing this value. Admission additionally pins the launcher's identity.
`deadline` must be an `Int64` in the clock's nanosecond domain; seconds and
unsigned ticks are rejected. Negative clock origins are valid. The default
`typemax(Int64)` leaves the machine's five-second effect budget in force.
"""
struct Request{C<:AbstractCommand,P}
    command::C
    token::UInt64
    deadline::Int64
    payload::P
    controller::Union{Nothing,Identity}
end
function Request(
    command::AbstractCommand;
    token::Integer = 0,
    deadline::Int64 = typemax(Int64),
    payload = nothing,
    controller::Union{Nothing,Identity} = nothing,
)
    token >= 0 || throw(ArgumentError("negative request token"))
    return Request(command, UInt64(token), deadline, payload, controller)
end
function Request(id::Integer; kwargs...)
    0 <= id <= typemax(UInt32) || throw(ArgumentError("invalid session operation"))
    return Request(_command(Val(UInt32(id))); kwargs...)
end
_command(::Val) = throw(ArgumentError("unsupported session operation"))
operation(r::Request) = operation(r.command)

"""Work requested by a handler and executed once by the session task.

The backend implements `perform!(session, job, effect)` for each concrete effect
and returns its documented evidence. Only correlated completion/failure events
advance the machine. The independent `budgeted` trait controls deadline checks;
it does not select an Hsm phase or grant retry permission.
"""
abstract type AbstractEffect end
struct CaptureOwners <: AbstractEffect end

struct ConnectOwners <: AbstractEffect end

struct CaptureParameters <: AbstractEffect end

struct CaptureSources <: AbstractEffect end

struct PrepareSources <: AbstractEffect end

struct DiscoverGraphs <: AbstractEffect end

struct HoldSources <: AbstractEffect end

struct ConnectLinks <: AbstractEffect end

struct HoldGraphs <: AbstractEffect end

struct RunSources <: AbstractEffect end

struct QuerySourceEnd <: AbstractEffect end

struct ResetSources <: AbstractEffect end

struct ResetGraphs <: AbstractEffect end

struct WithdrawLinks <: AbstractEffect end

struct ShutdownSources <: AbstractEffect end

struct ShutdownOwners <: AbstractEffect end

struct RemoveControls <: AbstractEffect end

struct PublishQuit <: AbstractEffect end

struct Disconnect <: AbstractEffect end

struct QueryGroups <: AbstractEffect end

struct QueryStatus <: AbstractEffect end

struct RunGraphs{G} <: AbstractEffect
    group::G
    running::Bool
end
RunGraphs(group = nothing) = RunGraphs(group, true)

"""Whether the backend must enforce a scientific operation budget.

Disconnect is an emergency transport teardown, with an explicit receipt. It
must execute even after the source-Hold deadline; no scientific mutation is
authorized by this exception. The backend dispatches Disconnect directly and
must not route it through a deadline-admission check for ordinary effects.

The default is `true`. Emergency `Disconnect` returns `false` so an expired
scientific request cannot revoke transport teardown. The machine assigns the
ticket deadline and the transport checks the trait before submission.
"""
budgeted(::AbstractEffect) = true
budgeted(::Disconnect) = false
struct QueryProperties{P} <: AbstractEffect
    payload::P
end

struct QueryPropertyGeneration{P} <: AbstractEffect
    payload::P
end

struct QueryParameterGeneration{P} <: AbstractEffect
    payload::P
end

struct UpdateProperties{P} <: AbstractEffect
    payload::P
end

struct SubmitParameter{P} <: AbstractEffect
    payload::P
end

"""One effect, issued once by the owner outside Hsm dispatch.

The adapter validates native identity, payload and acknowledgement semantics
before completion. `submitted!` must precede each native mutation, including a
send that can fail. Cancellation fences delivery; it does not imply rollback.
The target may be absent for a bounded cohort effect, whose adapter retains the
exact identities of all its component transactions.
"""
struct EffectTicket{E<:AbstractEffect,O<:AbstractOrigin}
    session::UInt64
    epoch::UInt64
    serial::UInt64
    operation::UInt32
    origin::O
    deadline::Int64
    effect::E
    target::Union{Nothing,Identity}
end

"""A correlated completion shared by the effect task and Hsm dispatcher.

The result remains parametric. The ticket is retained through its common
interface so each effect kind does not create another Hsm payload specialization.
This cold-control boundary preserves exact ticket correlation while avoiding
repeated compilation of the entire hierarchy during a cleanup deadline.
"""
struct EffectCompleted{R} <: AbstractEvent
    ticket::EffectTicket
    result::R
    at::Int64
end

"A failed effect; `submitted` records possible mutation in addition to prior receipts."
struct EffectFailed <: AbstractEvent
    ticket::EffectTicket
    reason::String
    submitted::Bool
end

"Submission intent, published to the Hsm immediately before a scientific write."
struct EffectSubmitted <: AbstractEvent
    ticket::EffectTicket
end

struct Reply{D}
    token::UInt64
    operation::UInt32
    lifecycle::RunnerCodec.Lifecycle
    outcome::Symbol
    details::D
    error::Union{Nothing,String}
    unknown::Bool
end

"""Fresh primary-source completion evidence, normalized by the adapter."""
struct SourceEnd
    completed::Bool
    running::Bool
end

"""Owned observational facts published by the backend; `nothing` is unknown.

This permits status/group inspection while startup or fault compensation owns
the single effect slot. Updating facts is an internal event and never restarts
an operation deadline. Status receipts must retain their producer timestamp.
"""
struct Observation{G,S}
    groups::G
    status::S
end

"""Pure session authority. One owner task dispatches events and executes effects.

`effect` is a bounded single-slot outbox and remains the current ticket until a
correlated terminal event. The owner drains cancellation before starting the
replacement effect. Replies have capacity two: a cancelled request and Quit.
No method in this machine performs native I/O, polls an owner or runs science.
Wire lifecycle uses RunnerCodec.Lifecycle; transient Hsm states are private.
The clock must implement `Clocks.AbstractNanoClock`. Its signed nanosecond
values are used directly, including negative injected clock origins. Deadline
addition is checked; an unrepresentable deadline raises `OverflowError`.
"""
@hsmdef mutable struct Machine{C<:Clocks.AbstractNanoClock}
    session::UInt64
    clock::C
    startup_timeout_ns::Int64
    admission_controller::Union{Nothing,Identity}
    lifecycle::RunnerCodec.Lifecycle
    lifecycle_origin::AbstractOrigin
    warmed::Bool
    epoch::UInt64
    serial::UInt64
    origin::AbstractOrigin
    request::Union{Nothing,Request}
    fault_request::Union{Nothing,Request}
    effect::Union{Nothing,EffectTicket}
    cancelled::Union{Nothing,EffectTicket}
    cancellation_delivery::Union{Nothing,EffectTicket}
    replies::Vector{Reply}
    reply_delivery::Vector{Reply}
    deadline::Int64
    mutated::Bool
    failure::Union{Nothing,String}
    cleanup_failure::Union{Nothing,String}
    fault_unknown::Bool
    observation::Observation
end

@statedef Machine :Offline
@statedef Machine :Managed
@statedef Machine :Configuring :Managed
@statedef Machine :Preparing :Configuring
@statedef Machine :CapturingOwners :Preparing

@statedef Machine :ConnectingOwners :Preparing

@statedef Machine :CapturingParameters :Preparing

@statedef Machine :CapturingSources :Preparing

@statedef Machine :PreparingSources :Preparing

@statedef Machine :DiscoveringGraphs :Preparing

@statedef Machine :HoldingInitialSources :Preparing

@statedef Machine :ConnectingLinks :Preparing

@statedef Machine :HoldingInitialGraphs :Preparing

@statedef Machine :AwaitingAdmission :Configuring
@statedef Machine :Admitted :Managed
@statedef Machine :Ready :Admitted
@statedef Machine :Running :Admitted
@statedef Machine :Executing :Managed
@statedef Machine :StartingGraphs :Executing

@statedef Machine :StartingSources :Executing

@statedef Machine :CheckingSourceEnd :Executing

@statedef Machine :StoppingSources :Executing

@statedef Machine :StoppingGraphs :Executing

@statedef Machine :ResettingSourcesHold :Executing

@statedef Machine :ResettingGraphsHold :Executing

@statedef Machine :ResettingSources :Executing

@statedef Machine :ResettingGraphs :Executing

@statedef Machine :ControllingGroup :Executing

@statedef Machine :Querying :Executing

@statedef Machine :Updating :Executing

@statedef Machine :ShuttingDown :Managed
@statedef Machine :HoldingQuitSources :ShuttingDown

@statedef Machine :HoldingQuitGraphs :ShuttingDown

@statedef Machine :WithdrawingQuitLinks :ShuttingDown

@statedef Machine :ShuttingSources :ShuttingDown

@statedef Machine :ShuttingOwners :ShuttingDown

@statedef Machine :RemovingControls :ShuttingDown

@statedef Machine :PublishingQuit :ShuttingDown

@statedef Machine :Fault :Managed
@statedef Machine :HoldingFaultSources :Fault
@statedef Machine :HoldingFaultGraphs :Fault
@statedef Machine :WithdrawingFaultLinks :Fault
@statedef Machine :HeldFault :Fault
@statedef Machine :EmergencyDisconnect :Fault

@on_initial function (m::Machine, ::Root)
    return Hsm.transition!(m, :Offline)
end

_now(m::Machine)::Int64 = Clocks.time_nanos(m.clock)
_deadline(m::Machine, duration_ns::Int64) = Base.Checked.checked_add(_now(m), duration_ns)
function _issue!(m::Machine, effect::AbstractEffect; target = nothing)
    m.effect === nothing || error("session effect already pending")
    m.serial = Base.Checked.checked_add(m.serial, UInt64(1))
    m.effect = EffectTicket(
        m.session,
        m.epoch,
        m.serial,
        m.request === nothing ? UInt32(0) : operation(m.request),
        m.origin,
        budgeted(effect) ? m.deadline : typemax(Int64),
        effect,
        target,
    )
    return nothing
end
function _reply!(
    m::Machine,
    r::Request,
    outcome::Symbol,
    details = nothing;
    error = nothing,
    unknown = false,
)
    length(m.replies) < 2 || throw(ArgumentError("session reply outbox is full"))
    push!(
        m.replies,
        Reply(
            r.token,
            operation(r),
            m.lifecycle,
            outcome,
            details,
            error === nothing ? nothing : String(error),
            unknown,
        ),
    )
    return nothing
end
function _retire!(m::Machine)
    # Fence before exposing cancellation, which may synchronously deliver I/O.
    m.epoch = Base.Checked.checked_add(m.epoch, UInt64(1))
    if m.effect !== nothing
        m.cancelled === nothing || error("session cancellation outbox is full")
        m.cancelled = m.effect
        m.effect = nothing
    end
    return nothing
end
function _begin!(m::Machine, r::Request, origin::AbstractOrigin)
    m.effect === nothing || error("session effect already pending")
    deadline = min(r.deadline, _deadline(m, SESSION_EFFECT_TIMEOUT_NS))
    m.epoch = Base.Checked.checked_add(m.epoch, UInt64(1))
    m.origin, m.request, m.mutated = origin, r, false
    m.deadline = deadline
    return nothing
end
function _finish!(m::Machine, outcome::Symbol, details = nothing)
    r = m.request
    m.request = nothing
    r === nothing || _reply!(m, r, outcome, details)
    return nothing
end
_ready(::ReadyOrigin) = true
_ready(::RunningOrigin) = false
_wire_id(::OfflineOrigin) = RunnerCodec.Offline
_wire_id(::ConfiguringOrigin) = RunnerCodec.Configuring
_wire_id(::ReadyOrigin) = RunnerCodec.Ready
_wire_id(::RunningOrigin) = RunnerCodec.Running
_wire_id(::FaultOrigin) = RunnerCodec.Fault
function _lifecycle!(m::Machine, origin::AbstractOrigin)
    m.lifecycle_origin, m.lifecycle = origin, _wire_id(origin)
    return nothing
end

function _matches(m::Machine, t::EffectTicket)
    current = m.effect
    return current !== nothing &&
           t.session == m.session &&
           t.epoch == m.epoch &&
           t.serial == current.serial &&
           t.operation == current.operation &&
           t.target == current.target &&
           t.effect === current.effect &&
           t.origin === current.origin
end
_expired(m, event) = event.at >= m.deadline || _now(m) >= m.deadline
function _accept!(m, event)
    _matches(m, event.ticket) && !_expired(m, event) || return false
    m.effect = nothing
    return true
end
function _receive_failure!(m, event)
    _matches(m, event.ticket) || return false
    m.mutated = m.mutated || event.submitted
    m.effect = nothing
    return true
end
function _enter_fault!(m::Machine, reason)
    deadline = _deadline(m, SESSION_EFFECT_TIMEOUT_NS)
    _retire!(m)
    m.failure === nothing && (m.failure = String(reason))
    m.fault_request, m.request = m.request, nothing
    m.fault_unknown = m.mutated
    _lifecycle!(m, FaultOrigin())
    m.origin = FaultOrigin()
    m.deadline = deadline
    _issue!(m, HoldSources())
    return nothing
end
function _fault_reply!(m::Machine)
    r = m.fault_request
    m.fault_request = nothing
    r === nothing || _reply!(m, r, :Failed; error = m.failure, unknown = m.fault_unknown)
    return nothing
end
function _refuse_operation!(m::Machine, reason)
    _retire!(m)
    r, m.request = m.request, nothing
    _reply!(m, something(r), :Failed; error = reason)
    return nothing
end
function _begin_quit!(m::Machine, r::Request)
    deadline = min(r.deadline, _deadline(m, SESSION_EFFECT_TIMEOUT_NS))
    _retire!(m)
    old, m.request = m.request, nothing
    old === nothing ||
        _reply!(m, old, :Failed; error = "Cancelled by shutdown", unknown = m.mutated)
    _fault_reply!(m)
    m.request, m.origin = r, m.lifecycle_origin
    m.deadline = deadline
    m.mutated = false
    _issue!(m, HoldSources())
    return nothing
end
function _cleanup_failed!(m::Machine, reason)
    m.cleanup_failure = String(reason)
    _retire!(m)
    return nothing
end

@on_event function (m::Machine, ::Offline, ::Boot, _)
    _lifecycle!(m, ConfiguringOrigin())
    m.origin = ConfiguringOrigin()
    m.epoch = Base.Checked.checked_add(m.epoch, UInt64(1))
    m.deadline = _deadline(m, m.startup_timeout_ns)
    _issue!(m, CaptureOwners())
    return Hsm.transition!(m, :CapturingOwners)
end
@on_event function (m::Machine, ::Root, ::TakeCancellation, _)
    m.cancellation_delivery, m.cancelled = m.cancelled, nothing
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Root, ::TakeReplies, _)
    m.reply_delivery = copy(m.replies)
    empty!(m.replies)
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Root, ::Submitted, event)
    _matches(m, event.ticket) && (m.mutated = true)
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Root, ::Observed, observation)
    m.observation = observation
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Managed, ::RequiredLost, reason)
    _enter_fault!(m, reason)
    return Hsm.transition!(m, :HoldingFaultSources)
end
@on_event function (m::Machine, ::Fault, ::RequiredLost, _)
    return Hsm.EventHandled
end

# Each phase retains the operation's absolute deadline. Static transitions must
# remain in Hsm handler bodies; helpers validate records or update facts only.
@on_event function (m::Machine, ::CapturingOwners, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, ConnectOwners())
    return Hsm.transition!(m, :ConnectingOwners)
end

@on_event function (m::Machine, ::ConnectingOwners, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, CaptureParameters())
    return Hsm.transition!(m, :CapturingParameters)
end

@on_event function (m::Machine, ::CapturingParameters, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, CaptureSources())
    return Hsm.transition!(m, :CapturingSources)
end

@on_event function (m::Machine, ::CapturingSources, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, PrepareSources())
    return Hsm.transition!(m, :PreparingSources)
end

@on_event function (m::Machine, ::PreparingSources, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, DiscoverGraphs())
    return Hsm.transition!(m, :DiscoveringGraphs)
end

@on_event function (m::Machine, ::DiscoveringGraphs, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, HoldSources())
    return Hsm.transition!(m, :HoldingInitialSources)
end

@on_event function (m::Machine, ::HoldingInitialSources, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, ConnectLinks())
    return Hsm.transition!(m, :ConnectingLinks)
end

@on_event function (m::Machine, ::ConnectingLinks, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, HoldGraphs())
    return Hsm.transition!(m, :HoldingInitialGraphs)
end

@on_event function (m::Machine, ::StartingGraphs, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, RunSources())
    return Hsm.transition!(m, :StartingSources)
end

@on_event function (m::Machine, ::StoppingSources, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _lifecycle!(m, ReadyOrigin())
    _issue!(m, HoldGraphs())
    return Hsm.transition!(m, :StoppingGraphs)
end

@on_event function (m::Machine, ::ResettingSourcesHold, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _lifecycle!(m, ReadyOrigin())
    _issue!(m, HoldGraphs())
    return Hsm.transition!(m, :ResettingGraphsHold)
end

@on_event function (m::Machine, ::ResettingGraphsHold, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, ResetSources())
    return Hsm.transition!(m, :ResettingSources)
end

@on_event function (m::Machine, ::ResettingSources, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, ResetGraphs())
    return Hsm.transition!(m, :ResettingGraphs)
end

@on_event function (m::Machine, ::HoldingQuitSources, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, HoldGraphs())
    return Hsm.transition!(m, :HoldingQuitGraphs)
end

@on_event function (m::Machine, ::HoldingQuitGraphs, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, WithdrawLinks())
    return Hsm.transition!(m, :WithdrawingQuitLinks)
end

@on_event function (m::Machine, ::WithdrawingQuitLinks, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, ShutdownSources())
    return Hsm.transition!(m, :ShuttingSources)
end

@on_event function (m::Machine, ::ShuttingSources, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, ShutdownOwners())
    return Hsm.transition!(m, :ShuttingOwners)
end

@on_event function (m::Machine, ::ShuttingOwners, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _issue!(m, RemoveControls())
    return Hsm.transition!(m, :RemovingControls)
end

@on_event function (m::Machine, ::HoldingInitialGraphs, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    m.warmed = true
    return Hsm.transition!(m, :AwaitingAdmission)
end
@on_event function (m::Machine, ::StartingSources, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _lifecycle!(m, RunningOrigin())
    _finish!(m, :Lifecycle)
    return Hsm.transition!(m, :Running)
end
_source_ended(result::SourceEnd) = result.completed && !result.running
_source_ended(result) = false
@on_event function (m::Machine, ::CheckingSourceEnd, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    if !_source_ended(event.result)
        _enter_fault!(m, "Source end is not confirmed")
        return Hsm.transition!(m, :HoldingFaultSources)
    end
    _issue!(m, HoldSources())
    return Hsm.transition!(m, :StoppingSources)
end
@on_event function (m::Machine, ::StoppingGraphs, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _lifecycle!(m, ReadyOrigin())
    _finish!(m, :Lifecycle)
    return Hsm.transition!(m, :Ready)
end
@on_event function (m::Machine, ::ResettingGraphs, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _finish!(m, :Lifecycle)
    return Hsm.transition!(m, :Ready)
end
@on_event function (m::Machine, ::ControllingGroup, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _finish!(m, :Group, event.result)
    return Hsm.transition!(m, :Running)
end
@on_event function (m::Machine, ::Querying, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _finish!(m, :Observed, event.result)
    if _ready(m.origin)
        return Hsm.transition!(m, :Ready)
    end
    return Hsm.transition!(m, :Running)
end

@on_event function (m::Machine, ::Updating, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _finish!(m, :Updated, event.result)
    if _ready(m.origin)
        return Hsm.transition!(m, :Ready)
    end
    return Hsm.transition!(m, :Running)
end

@on_event function (m::Machine, ::PublishingQuit, ::Completion, event)
    _matches(m, event.ticket) || return Hsm.EventHandled
    _expired(m, event) && (m.cleanup_failure = "Quit completion publication fence expired")
    m.effect, m.request = nothing, nothing
    return Hsm.transition!(m, :Offline)
end
@on_event function (m::Machine, ::RemovingControls, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    # Cleanup is established here. The successful completion must be published
    # before the backend can fence that publication and disconnect transport.
    _lifecycle!(m, OfflineOrigin())
    _reply!(m, something(m.request), :Quit, true)
    _issue!(m, PublishQuit())
    return Hsm.transition!(m, :PublishingQuit)
end
@on_event function (m::Machine, ::PublishingQuit, ::Failure, event)
    _receive_failure!(m, event) || return Hsm.EventHandled
    m.cleanup_failure = String(event.reason)
    m.request = nothing
    return Hsm.transition!(m, :Offline)
end
@on_event function (m::Machine, ::PublishingQuit, ::Tick, _)
    m.effect === nothing && return Hsm.EventHandled
    _now(m) < m.deadline && return Hsm.EventHandled
    m.cleanup_failure = "Quit completion publication fence expired"
    _retire!(m)
    m.request = nothing
    return Hsm.transition!(m, :Offline)
end
@on_event function (m::Machine, ::PublishingQuit, ::RequiredLost, _)
    # Owner disappearance is expected after acknowledged cleanup. The final
    # publication fence can fail, but cannot undo the successful shutdown.
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::WithdrawingFaultLinks, ::Completion, event)
    _accept!(m, event) || return Hsm.EventNotHandled
    _fault_reply!(m)
    return Hsm.transition!(m, :HeldFault)
end
@on_event function (m::Machine, ::EmergencyDisconnect, ::Completion, event)
    _matches(m, event.ticket) || return Hsm.EventHandled
    m.effect = nothing
    _fault_reply!(m)
    return Hsm.transition!(m, :HeldFault)
end
@on_event function (m::Machine, ::EmergencyDisconnect, ::Failure, event)
    _receive_failure!(m, event) || return Hsm.EventHandled
    m.cleanup_failure = String(event.reason)
    _fault_reply!(m)
    return Hsm.transition!(m, :HeldFault)
end
@on_event function (m::Machine, ::EmergencyDisconnect, ::Tick, _)
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::EmergencyDisconnect, ::RequiredLost, _)
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Managed, ::Completion, event)
    _matches(m, event.ticket) || return Hsm.EventHandled
    _enter_fault!(m, "Session effect expired; outcome unknown")
    return Hsm.transition!(m, :HoldingFaultSources)
end
@on_event function (m::Machine, ::Executing, ::Completion, event)
    _matches(m, event.ticket) || return Hsm.EventHandled
    if m.mutated
        _enter_fault!(m, "Session effect expired; outcome unknown")
        return Hsm.transition!(m, :HoldingFaultSources)
    end
    _refuse_operation!(m, "Session query expired")
    if _ready(m.origin)
        return Hsm.transition!(m, :Ready)
    end
    return Hsm.transition!(m, :Running)
end
@on_event function (m::Machine, ::Root, ::Completion, _)
    return Hsm.EventHandled
end

@on_event function (m::Machine, ::Managed, ::Failure, event)
    _receive_failure!(m, event) || return Hsm.EventHandled
    _enter_fault!(m, event.reason)
    return Hsm.transition!(m, :HoldingFaultSources)
end
@on_event function (m::Machine, ::Executing, ::Failure, event)
    _receive_failure!(m, event) || return Hsm.EventHandled
    if m.mutated
        _enter_fault!(m, event.reason)
        return Hsm.transition!(m, :HoldingFaultSources)
    end
    _refuse_operation!(m, event.reason)
    if _ready(m.origin)
        return Hsm.transition!(m, :Ready)
    end
    return Hsm.transition!(m, :Running)
end
@on_event function (m::Machine, ::Root, ::Failure, _)
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Managed, ::Tick, _)
    m.effect === nothing && return Hsm.EventHandled
    _now(m) < m.deadline && return Hsm.EventHandled
    _enter_fault!(m, "Session effect expired; outcome unknown")
    return Hsm.transition!(m, :HoldingFaultSources)
end
@on_event function (m::Machine, ::Executing, ::Tick, _)
    m.effect === nothing && return Hsm.EventHandled
    _now(m) < m.deadline && return Hsm.EventHandled
    if m.mutated
        _enter_fault!(m, "Session effect expired; outcome unknown")
        return Hsm.transition!(m, :HoldingFaultSources)
    end
    _refuse_operation!(m, "Session query expired")
    if _ready(m.origin)
        return Hsm.transition!(m, :Ready)
    end
    return Hsm.transition!(m, :Running)
end
@on_event function (m::Machine, ::Root, ::Tick, _)
    return Hsm.EventHandled
end

# Fault compensation has its own absolute budget. A failed source Hold cannot
# establish safe graph teardown: disconnect invokes systemd's emergency path.
@on_event function (m::Machine, ::HoldingFaultSources, ::Failure, event)
    _receive_failure!(m, event) || return Hsm.EventNotHandled
    _cleanup_failed!(m, event.reason)
    _issue!(m, Disconnect())
    return Hsm.transition!(m, :EmergencyDisconnect)
end

@on_event function (m::Machine, ::HoldingFaultGraphs, ::Failure, event)
    _receive_failure!(m, event) || return Hsm.EventNotHandled
    _cleanup_failed!(m, event.reason)
    _issue!(m, WithdrawLinks())
    return Hsm.transition!(m, :WithdrawingFaultLinks)
end

@on_event function (m::Machine, ::Fault, ::Failure, event)
    _receive_failure!(m, event) || return Hsm.EventHandled
    _cleanup_failed!(m, event.reason)
    _fault_reply!(m)
    return Hsm.transition!(m, :HeldFault)
end

@on_event function (m::Machine, ::HoldingFaultSources, ::Tick, event)
    m.effect !== nothing && _now(m) >= m.deadline || return Hsm.EventNotHandled
    _cleanup_failed!(m, "Fault cleanup expired; outcome unknown")
    _issue!(m, Disconnect())
    return Hsm.transition!(m, :EmergencyDisconnect)
end

@on_event function (m::Machine, ::HoldingFaultGraphs, ::Tick, event)
    m.effect !== nothing && _now(m) >= m.deadline || return Hsm.EventNotHandled
    _cleanup_failed!(m, "Fault cleanup expired; outcome unknown")
    _issue!(m, WithdrawLinks())
    return Hsm.transition!(m, :WithdrawingFaultLinks)
end

@on_event function (m::Machine, ::Fault, ::Tick, event)
    m.effect !== nothing && _now(m) >= m.deadline || return Hsm.EventHandled
    _cleanup_failed!(m, "Fault cleanup expired; outcome unknown")
    _fault_reply!(m)
    return Hsm.transition!(m, :HeldFault)
end

@on_event function (m::Machine, ::Fault, ::Completion, event)
    _matches(m, event.ticket) || return Hsm.EventHandled
    _cleanup_failed!(m, "Fault cleanup expired; outcome unknown")
    _fault_reply!(m)
    return Hsm.transition!(m, :HeldFault)
end
# Completion handlers above must handle success before Fault's expiry fallback.
@on_event function (m::Machine, ::HoldingFaultSources, ::Completion, event)
    if _accept!(m, event)
        _issue!(m, HoldGraphs())
        return Hsm.transition!(m, :HoldingFaultGraphs)
    end
    _matches(m, event.ticket) || return Hsm.EventHandled
    _cleanup_failed!(m, "Fault source Hold expired; outcome unknown")
    _issue!(m, Disconnect())
    return Hsm.transition!(m, :EmergencyDisconnect)
end
@on_event function (m::Machine, ::HoldingFaultGraphs, ::Completion, event)
    if _accept!(m, event)
        _issue!(m, WithdrawLinks())
        return Hsm.transition!(m, :WithdrawingFaultLinks)
    end
    _matches(m, event.ticket) || return Hsm.EventHandled
    _cleanup_failed!(m, "Fault graph Hold expired; outcome unknown")
    _issue!(m, WithdrawLinks())
    return Hsm.transition!(m, :WithdrawingFaultLinks)
end

@on_event function (m::Machine, ::Managed, ::QuitRequested, r)
    _begin_quit!(m, r)
    return Hsm.transition!(m, :HoldingQuitSources)
end
@on_event function (m::Machine, ::ShuttingDown, ::QuitRequested, r)
    _reply!(m, r, :Failed; error = "Session shutdown already pending")
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Root, ::QuitRequested, r)
    _reply!(m, r, :Failed; error = "Session is offline")
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Configuring, ::WarmupRequested, r)
    if r.controller === nothing ||
        (m.admission_controller !== nothing && r.controller != m.admission_controller)
        _reply!(m, r, :Failed; error = "Resource admission launcher incarnation changed")
    else
        m.admission_controller = r.controller
        _reply!(m, r, :Warmup, m.warmed)
    end
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::AwaitingAdmission, ::AdmissionRequested, r)
    if m.admission_controller === nothing || r.controller != m.admission_controller
        _reply!(
            m, r, :Failed; error = "Resource admission requires prior launcher inspection"
        )
        return Hsm.EventHandled
    end
    _lifecycle!(m, ReadyOrigin())
    _reply!(m, r, :Warmup, true)
    return Hsm.transition!(m, :Ready)
end
@on_event function (m::Machine, ::Root, ::WarmupRequested, r)
    _reply!(
        m, r, :Failed;
        error = something(m.failure, "Resource admission is not available in this state"),
    )
    return Hsm.EventHandled
end

@on_event function (m::Machine, ::Root, ::AdmissionRequested, r)
    _reply!(m, r, :Failed; error = "Resource admission is not available in this state")
    return Hsm.EventHandled
end

_event(::Quit) = :QuitRequested
_event(::InspectWarmup) = :WarmupRequested
_event(::Admit) = :AdmissionRequested
_event(::Groups) = :GroupsRequested

_event(::Status) = :StatusRequested

_event(::Properties) = :PropertiesRequested

@on_event function (m::Machine, ::Root, ::PropertiesRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::PropertyGeneration) = :PropertyGenerationRequested

@on_event function (m::Machine, ::Root, ::PropertyGenerationRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::ParameterGeneration) = :ParameterGenerationRequested

@on_event function (m::Machine, ::Root, ::ParameterGenerationRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::StopGroup) = :StopGroupRequested

@on_event function (m::Machine, ::Root, ::StopGroupRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::StartGroup) = :StartGroupRequested

@on_event function (m::Machine, ::Root, ::StartGroupRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::Stop) = :StopRequested

@on_event function (m::Machine, ::Root, ::StopRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::Start) = :StartRequested

@on_event function (m::Machine, ::Root, ::StartRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::SourceEnded) = :SourceEndedRequested

@on_event function (m::Machine, ::Root, ::SourceEndedRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::Reset) = :ResetRequested

@on_event function (m::Machine, ::Root, ::ResetRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::SetProperties) = :SetPropertiesRequested

@on_event function (m::Machine, ::Root, ::SetPropertiesRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

_event(::SetParameter) = :SetParameterRequested

@on_event function (m::Machine, ::Root, ::SetParameterRequested, r)
    _reply!(m, r, :Failed; error = "Operation is not admitted in this state")
    return Hsm.EventHandled
end

@on_event function (m::Machine, ::Root, ::GroupsRequested, r)
    _reply!(m, r, :Observed, m.observation.groups)
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Root, ::StatusRequested, r)
    _reply!(m, r, :Observed, m.observation.status)
    return Hsm.EventHandled
end
@on_event function (m::Machine, ::Ready, ::StartRequested, r)
    _begin!(m, r, ReadyOrigin())
    _issue!(m, RunGraphs())
    return Hsm.transition!(m, :StartingGraphs)
end
@on_event function (m::Machine, ::Ready, ::ResetRequested, r)
    _begin!(m, r, ReadyOrigin())
    _issue!(m, HoldSources())
    return Hsm.transition!(m, :ResettingSourcesHold)
end
@on_event function (m::Machine, ::Admitted, ::StopRequested, r)
    _begin!(m, r, m.lifecycle_origin)
    _issue!(m, HoldSources())
    return Hsm.transition!(m, :StoppingSources)
end

@on_event function (m::Machine, ::Admitted, ::SourceEndedRequested, r)
    _begin!(m, r, m.lifecycle_origin)
    _issue!(m, QuerySourceEnd())
    return Hsm.transition!(m, :CheckingSourceEnd)
end

@on_event function (m::Machine, ::Admitted, ::GroupsRequested, r)
    _begin!(m, r, m.lifecycle_origin)
    _issue!(m, QueryGroups())
    return Hsm.transition!(m, :Querying)
end

@on_event function (m::Machine, ::Admitted, ::StatusRequested, r)
    _begin!(m, r, m.lifecycle_origin)
    _issue!(m, QueryStatus())
    return Hsm.transition!(m, :Querying)
end

@on_event function (m::Machine, ::Admitted, ::PropertiesRequested, r)
    _begin!(m, r, m.lifecycle_origin)
    _issue!(m, QueryProperties(r.payload))
    return Hsm.transition!(m, :Querying)
end

@on_event function (m::Machine, ::Admitted, ::PropertyGenerationRequested, r)
    _begin!(m, r, m.lifecycle_origin)
    _issue!(m, QueryPropertyGeneration(r.payload))
    return Hsm.transition!(m, :Querying)
end

@on_event function (m::Machine, ::Admitted, ::ParameterGenerationRequested, r)
    _begin!(m, r, m.lifecycle_origin)
    _issue!(m, QueryParameterGeneration(r.payload))
    return Hsm.transition!(m, :Querying)
end

@on_event function (m::Machine, ::Admitted, ::SetPropertiesRequested, r)
    _begin!(m, r, m.lifecycle_origin)
    _issue!(m, UpdateProperties(r.payload))
    return Hsm.transition!(m, :Updating)
end

@on_event function (m::Machine, ::Admitted, ::SetParameterRequested, r)
    _begin!(m, r, m.lifecycle_origin)
    _issue!(m, SubmitParameter(r.payload))
    return Hsm.transition!(m, :Updating)
end

@on_event function (m::Machine, ::Running, ::StopGroupRequested, r)
    _begin!(m, r, RunningOrigin())
    _issue!(m, RunGraphs(r.payload, false))
    return Hsm.transition!(m, :ControllingGroup)
end

@on_event function (m::Machine, ::Running, ::StartGroupRequested, r)
    _begin!(m, r, RunningOrigin())
    _issue!(m, RunGraphs(r.payload, true))
    return Hsm.transition!(m, :ControllingGroup)
end

function Machine(
    session::Integer;
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
    startup_timeout_ns::Int64 = DEFAULT_STARTUP_TIMEOUT_NS,
    admission_controller::Union{Nothing,Identity} = nothing,
)
    0 < session <= typemax(Int64) || throw(ArgumentError("invalid session incarnation"))
    MIN_STARTUP_TIMEOUT_NS <= startup_timeout_ns <= MAX_STARTUP_TIMEOUT_NS ||
        throw(ArgumentError("invalid startup timeout"))
    m = Machine(
        UInt64(session),
        clock,
        startup_timeout_ns,
        admission_controller,
        RunnerCodec.Offline,
        OfflineOrigin(),
        false,
        UInt64(0),
        UInt64(0),
        ConfiguringOrigin(),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        Reply[],
        Reply[],
        typemax(Int64),
        false,
        nothing,
        nothing,
        false,
        Observation(nothing, nothing),
    )
    Hsm.dispatch!(m, :Boot)
    return m
end
submit!(m::Machine, r::Request) = (Hsm.dispatch!(m, _event(r.command), r); nothing)
submitted!(m::Machine, t::EffectTicket) =
    (Hsm.dispatch!(m, :Submitted, EffectSubmitted(t)); nothing)
complete!(m::Machine, t::EffectTicket, result = nothing; at::Int64 = _now(m)) =
    complete!(m, EffectCompleted(t, result, at))
complete!(m::Machine, event::EffectCompleted) =
    (Hsm.dispatch!(m, :Completion, event); nothing)
fail!(m::Machine, t::EffectTicket, reason::AbstractString; submitted::Bool = true) =
    fail!(m, EffectFailed(t, String(reason), submitted))
fail!(m::Machine, event::EffectFailed) = (Hsm.dispatch!(m, :Failure, event); nothing)
tick!(m::Machine) = (Hsm.dispatch!(m, :Tick); nothing)
required_lost!(m::Machine, reason::AbstractString) =
    (Hsm.dispatch!(m, :RequiredLost, String(reason)); nothing)
take_cancelled!(m::Machine) = (Hsm.dispatch!(m, :TakeCancellation); m.cancellation_delivery)
take_replies!(m::Machine) = (Hsm.dispatch!(m, :TakeReplies); m.reply_delivery)
observe!(m::Machine, o::Observation) = (Hsm.dispatch!(m, :Observed, o); nothing)
