"""Exact native endpoint/controller incarnation, including its owning process."""
struct Identity
    global_id::UInt32
    serial::UInt64
    instance::UInt64
    pid::UInt32
end

abstract type Origin end
struct OfflineOrigin <: Origin end
struct ConfiguringOrigin <: Origin end
struct ReadyOrigin <: Origin end
struct RunningOrigin <: Origin end
struct FaultOrigin <: Origin end

abstract type Command end
for (name, id) in ((:Quit,1),(:Groups,2),(:Status,3),(:Properties,4),
        (:PropertyGeneration,5),(:ParameterGeneration,6),(:StopGroup,7),
        (:StartGroup,8),(:Stop,9),(:Start,10),(:SourceEnded,11),(:Reset,12),
        (:SetProperties,13),(:SetParameter,14),(:InspectWarmup,15),(:Admit,16))
    @eval begin
        struct $name <: Command end
        operation(::$name) = UInt32($id)
        _command(::Val{$id}) = $name()
    end
end

"""Owned, normalized public request. Deadlines are absolute monotonic seconds.

The ingress proves the native controller record and copies the payload before
constructing this value. Admission additionally pins the launcher's identity.
"""
struct Request{C<:Command,P}
    command::C
    token::UInt64
    deadline::Float64
    payload::P
    controller::Union{Nothing,Identity}
end
function Request(id::Integer; token::Integer=0, deadline::Real=Inf,
        payload=nothing, controller::Union{Nothing,Identity}=nothing)
    1 <= id <= 16 || throw(ArgumentError("unsupported session operation"))
    token >= 0 || throw(ArgumentError("negative request token"))
    isnan(deadline) && throw(ArgumentError("invalid request deadline"))
    return Request(_command(Val(Int(id))),UInt64(token),Float64(deadline),payload,controller)
end
operation(r::Request) = operation(r.command)

abstract type Effect end
for name in (:CaptureOwners,:ConnectOwners,:CaptureParameters,:CaptureSources,
        :PrepareSources,:DiscoverGraphs,:HoldSources,:ConnectLinks,:HoldGraphs,
        :RunSources,:QuerySourceEnd,:ResetSources,:ResetGraphs,:WithdrawLinks,
        :ShutdownSources,:ShutdownOwners,:RemoveControls,:PublishQuit,:Disconnect,
        :QueryGroups,:QueryStatus)
    @eval struct $name <: Effect end
end
struct RunGraphs{G} <: Effect
    group::G
    running::Bool
end
RunGraphs(group=nothing) = RunGraphs(group,true)

"""Whether the backend must enforce a scientific operation budget.

Disconnect is an emergency transport teardown, with an explicit receipt. It
must execute even after the source-Hold deadline; no scientific mutation is
authorized by this exception. The backend dispatches Disconnect directly and
must not route it through a deadline-admission check for ordinary effects.
"""
budgeted(::Effect) = true
budgeted(::Disconnect) = false
for name in (:QueryProperties,:QueryPropertyGeneration,:QueryParameterGeneration,
        :UpdateProperties,:SubmitParameter)
    @eval struct $name{P} <: Effect
        payload::P
    end
end

"""One effect, issued once by the owner outside Hsm dispatch.

The adapter validates native identity, payload and acknowledgement semantics
before completion. `submitted!` must precede each native mutation, including a
send that can fail. Cancellation fences delivery; it does not imply rollback.
The target may be absent for a bounded cohort effect, whose adapter retains the
exact identities of all its component transactions.
"""
struct EffectTicket{E<:Effect,O<:Origin}
    session::UInt64
    epoch::UInt64
    serial::UInt64
    operation::UInt32
    origin::O
    deadline::Float64
    effect::E
    target::Union{Nothing,Identity}
end

struct Reply{D}
    token::UInt64
    operation::UInt32
    lifecycle::UInt32
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
Wire lifecycle IDs remain 1–5; transient Hsm states are private.
"""
@hsmdef mutable struct Machine{C}
    session::UInt64
    clock::C
    startup_timeout::Float64
    admission_controller::Union{Nothing,Identity}
    lifecycle::UInt32
    lifecycle_origin::Origin
    warmed::Bool
    epoch::UInt64
    serial::UInt64
    origin::Origin
    request::Union{Nothing,Request}
    fault_request::Union{Nothing,Request}
    effect::Union{Nothing,EffectTicket}
    cancelled::Union{Nothing,EffectTicket}
    cancellation_delivery::Union{Nothing,EffectTicket}
    replies::Vector{Reply}
    reply_delivery::Vector{Reply}
    deadline::Float64
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
for name in (:CapturingOwners,:ConnectingOwners,:CapturingParameters,
        :CapturingSources,:PreparingSources,:DiscoveringGraphs,
        :HoldingInitialSources,:ConnectingLinks,:HoldingInitialGraphs)
    @eval @statedef Machine $(QuoteNode(name)) :Preparing
end
@statedef Machine :AwaitingAdmission :Configuring
@statedef Machine :Admitted :Managed
@statedef Machine :Ready :Admitted
@statedef Machine :Running :Admitted
@statedef Machine :Executing :Managed
for name in (:StartingGraphs,:StartingSources,:CheckingSourceEnd,:StoppingSources,
        :StoppingGraphs,:ResettingSourcesHold,:ResettingGraphsHold,:ResettingSources,
        :ResettingGraphs,:ControllingGroup,:Querying,:Updating)
    @eval @statedef Machine $(QuoteNode(name)) :Executing
end
@statedef Machine :ShuttingDown :Managed
for name in (:HoldingQuitSources,:HoldingQuitGraphs,:WithdrawingQuitLinks,
        :ShuttingSources,:ShuttingOwners,:RemovingControls,:PublishingQuit)
    @eval @statedef Machine $(QuoteNode(name)) :ShuttingDown
end
@statedef Machine :Fault :Managed
@statedef Machine :HoldingFaultSources :Fault
@statedef Machine :HoldingFaultGraphs :Fault
@statedef Machine :WithdrawingFaultLinks :Fault
@statedef Machine :HeldFault :Fault
@statedef Machine :EmergencyDisconnect :Fault

@on_initial function(m::Machine, ::Root)
    return Hsm.transition!(m,:Offline)
end

_now(m::Machine) = Float64(Common.monotonic_seconds(m.clock))
function _issue!(m::Machine,effect::Effect;target=nothing)
    m.effect === nothing || error("session effect already pending")
    m.serial = Base.Checked.checked_add(m.serial,UInt64(1))
    m.effect = EffectTicket(m.session,m.epoch,m.serial,
        m.request === nothing ? UInt32(0) : operation(m.request),m.origin,
        budgeted(effect) ? m.deadline : Inf,effect,target)
    return nothing
end
function _reply!(m::Machine,r::Request,outcome::Symbol,details=nothing;
        error=nothing,unknown=false)
    length(m.replies) < 2 || throw(ArgumentError("session reply outbox is full"))
    push!(m.replies,Reply(r.token,operation(r),m.lifecycle,outcome,details,
        error === nothing ? nothing : String(error),unknown))
    return nothing
end
function _retire!(m::Machine)
    # Fence before exposing cancellation, which may synchronously deliver I/O.
    m.epoch = Base.Checked.checked_add(m.epoch,UInt64(1))
    if m.effect !== nothing
        m.cancelled === nothing || error("session cancellation outbox is full")
        m.cancelled = m.effect
        m.effect = nothing
    end
    return nothing
end
function _begin!(m::Machine,r::Request,origin::Origin)
    m.effect === nothing || error("session effect already pending")
    m.epoch = Base.Checked.checked_add(m.epoch,UInt64(1))
    m.origin,m.request,m.mutated = origin,r,false
    m.deadline = min(r.deadline,_now(m)+5.0)
    return nothing
end
function _finish!(m::Machine,outcome::Symbol,details=nothing)
    r = m.request
    m.request = nothing
    r === nothing || _reply!(m,r,outcome,details)
    return nothing
end
_ready(::ReadyOrigin) = true
_ready(::RunningOrigin) = false
_wire_id(::OfflineOrigin) = UInt32(1)
_wire_id(::ConfiguringOrigin) = UInt32(2)
_wire_id(::ReadyOrigin) = UInt32(3)
_wire_id(::RunningOrigin) = UInt32(4)
_wire_id(::FaultOrigin) = UInt32(5)
function _lifecycle!(m::Machine,origin::Origin)
    m.lifecycle_origin,m.lifecycle = origin,_wire_id(origin)
    return nothing
end

function _matches(m::Machine,t::EffectTicket)
    current = m.effect
    return current !== nothing && t.session == m.session && t.epoch == m.epoch &&
        t.serial == current.serial && t.operation == current.operation &&
        t.target == current.target && t.effect === current.effect && t.origin === current.origin
end
_expired(m,event) = !isfinite(event.at) || event.at >= m.deadline || _now(m) >= m.deadline
function _accept!(m,event)
    _matches(m,event.ticket) && !_expired(m,event) || return false
    m.effect = nothing
    return true
end
function _receive_failure!(m,event)
    _matches(m,event.ticket) || return false
    m.mutated = m.mutated || event.submitted
    m.effect = nothing
    return true
end
function _enter_fault!(m::Machine,reason)
    _retire!(m)
    m.failure === nothing && (m.failure = String(reason))
    m.fault_request,m.request = m.request,nothing
    m.fault_unknown = m.mutated
    _lifecycle!(m,FaultOrigin())
    m.origin = FaultOrigin()
    m.deadline = _now(m)+5.0
    _issue!(m,HoldSources())
    return nothing
end
function _fault_reply!(m::Machine)
    r = m.fault_request
    m.fault_request = nothing
    r === nothing || _reply!(m,r,:Failed;error=m.failure,unknown=m.fault_unknown)
    return nothing
end
function _refuse_operation!(m::Machine,reason)
    _retire!(m)
    r,m.request = m.request,nothing
    _reply!(m,something(r),:Failed;error=reason)
    return nothing
end
function _begin_quit!(m::Machine,r::Request)
    _retire!(m)
    old,m.request = m.request,nothing
    old === nothing || _reply!(m,old,:Failed;error="Cancelled by shutdown",unknown=m.mutated)
    _fault_reply!(m)
    m.request,m.origin = r,m.lifecycle_origin
    m.deadline = min(r.deadline,_now(m)+5.0)
    m.mutated = false
    _issue!(m,HoldSources())
    return nothing
end
function _cleanup_failed!(m::Machine,reason)
    m.cleanup_failure = String(reason)
    _retire!(m)
    return nothing
end

@on_event function(m::Machine,::Offline,::Boot,_)
    _lifecycle!(m,ConfiguringOrigin())
    m.origin = ConfiguringOrigin()
    m.epoch = Base.Checked.checked_add(m.epoch,UInt64(1))
    m.deadline = _now(m)+m.startup_timeout
    _issue!(m,CaptureOwners())
    return Hsm.transition!(m,:CapturingOwners)
end
@on_event function(m::Machine,::Root,::TakeCancellation,_)
    m.cancellation_delivery,m.cancelled = m.cancelled,nothing
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Root,::TakeReplies,_)
    m.reply_delivery = copy(m.replies)
    empty!(m.replies)
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Root,::Submitted,ticket)
    _matches(m,ticket) && (m.mutated = true)
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Root,::Observed,observation)
    m.observation = observation
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Managed,::RequiredLost,reason)
    _enter_fault!(m,reason)
    return Hsm.transition!(m,:HoldingFaultSources)
end
@on_event function(m::Machine,::Fault,::RequiredLost,_)
    return Hsm.EventHandled
end

# Each phase retains the operation's absolute deadline. Static transitions must
# remain in Hsm handler bodies; helpers validate records or update facts only.
for (state,nextstate,nexteffect) in (
        (:CapturingOwners,:ConnectingOwners,:ConnectOwners),
        (:ConnectingOwners,:CapturingParameters,:CaptureParameters),
        (:CapturingParameters,:CapturingSources,:CaptureSources),
        (:CapturingSources,:PreparingSources,:PrepareSources),
        (:PreparingSources,:DiscoveringGraphs,:DiscoverGraphs),
        (:DiscoveringGraphs,:HoldingInitialSources,:HoldSources),
        (:HoldingInitialSources,:ConnectingLinks,:ConnectLinks),
        (:ConnectingLinks,:HoldingInitialGraphs,:HoldGraphs),
        (:StartingGraphs,:StartingSources,:RunSources),
        (:StoppingSources,:StoppingGraphs,:HoldGraphs),
        (:ResettingSourcesHold,:ResettingGraphsHold,:HoldGraphs),
        (:ResettingGraphsHold,:ResettingSources,:ResetSources),
        (:ResettingSources,:ResettingGraphs,:ResetGraphs),
        (:HoldingQuitSources,:HoldingQuitGraphs,:HoldGraphs),
        (:HoldingQuitGraphs,:WithdrawingQuitLinks,:WithdrawLinks),
        (:WithdrawingQuitLinks,:ShuttingSources,:ShutdownSources),
        (:ShuttingSources,:ShuttingOwners,:ShutdownOwners),
        (:ShuttingOwners,:RemovingControls,:RemoveControls))
    after = state in (:StoppingSources,:ResettingSourcesHold) ? :(_lifecycle!(m,ReadyOrigin())) : nothing
    @eval @on_event function(m::Machine,::$state,::Completion,event)
        _accept!(m,event) || return Hsm.EventNotHandled
        $after
        _issue!(m,$nexteffect())
        return Hsm.transition!(m,$(QuoteNode(nextstate)))
    end
end
@on_event function(m::Machine,::HoldingInitialGraphs,::Completion,event)
    _accept!(m,event) || return Hsm.EventNotHandled
    m.warmed = true
    return Hsm.transition!(m,:AwaitingAdmission)
end
@on_event function(m::Machine,::StartingSources,::Completion,event)
    _accept!(m,event) || return Hsm.EventNotHandled
    _lifecycle!(m,RunningOrigin())
    _finish!(m,:Lifecycle)
    return Hsm.transition!(m,:Running)
end
_source_ended(result::SourceEnd) = result.completed && !result.running
_source_ended(result) = false
@on_event function(m::Machine,::CheckingSourceEnd,::Completion,event)
    _accept!(m,event) || return Hsm.EventNotHandled
    if !_source_ended(event.result)
        _enter_fault!(m,"Source end is not confirmed")
        return Hsm.transition!(m,:HoldingFaultSources)
    end
    _issue!(m,HoldSources())
    return Hsm.transition!(m,:StoppingSources)
end
@on_event function(m::Machine,::StoppingGraphs,::Completion,event)
    _accept!(m,event) || return Hsm.EventNotHandled
    _lifecycle!(m,ReadyOrigin())
    _finish!(m,:Lifecycle)
    return Hsm.transition!(m,:Ready)
end
@on_event function(m::Machine,::ResettingGraphs,::Completion,event)
    _accept!(m,event) || return Hsm.EventNotHandled
    _finish!(m,:Lifecycle)
    return Hsm.transition!(m,:Ready)
end
@on_event function(m::Machine,::ControllingGroup,::Completion,event)
    _accept!(m,event) || return Hsm.EventNotHandled
    _finish!(m,:Group,event.result)
    return Hsm.transition!(m,:Running)
end
for (state,outcome) in ((:Querying,:Observed),(:Updating,:Updated))
    @eval @on_event function(m::Machine,::$state,::Completion,event)
        _accept!(m,event) || return Hsm.EventNotHandled
        _finish!(m,$(QuoteNode(outcome)),event.result)
        if _ready(m.origin)
            return Hsm.transition!(m,:Ready)
        end
        return Hsm.transition!(m,:Running)
    end
end
@on_event function(m::Machine,::PublishingQuit,::Completion,event)
    _matches(m,event.ticket) || return Hsm.EventHandled
    _expired(m,event) && (m.cleanup_failure = "Quit completion publication fence expired")
    m.effect,m.request = nothing,nothing
    return Hsm.transition!(m,:Offline)
end
@on_event function(m::Machine,::RemovingControls,::Completion,event)
    _accept!(m,event) || return Hsm.EventNotHandled
    # Cleanup is established here. The successful completion must be published
    # before the backend can fence that publication and disconnect transport.
    _lifecycle!(m,OfflineOrigin())
    _reply!(m,something(m.request),:Quit,true)
    _issue!(m,PublishQuit())
    return Hsm.transition!(m,:PublishingQuit)
end
@on_event function(m::Machine,::PublishingQuit,::Failure,event)
    _receive_failure!(m,event) || return Hsm.EventHandled
    m.cleanup_failure = String(event.reason)
    m.request = nothing
    return Hsm.transition!(m,:Offline)
end
@on_event function(m::Machine,::PublishingQuit,::Tick,_)
    m.effect === nothing && return Hsm.EventHandled
    _now(m) < m.deadline && return Hsm.EventHandled
    m.cleanup_failure = "Quit completion publication fence expired"
    _retire!(m)
    m.request = nothing
    return Hsm.transition!(m,:Offline)
end
@on_event function(m::Machine,::PublishingQuit,::RequiredLost,_)
    # Owner disappearance is expected after acknowledged cleanup. The final
    # publication fence can fail, but cannot undo the successful shutdown.
    return Hsm.EventHandled
end
@on_event function(m::Machine,::WithdrawingFaultLinks,::Completion,event)
    _accept!(m,event) || return Hsm.EventNotHandled
    _fault_reply!(m)
    return Hsm.transition!(m,:HeldFault)
end
@on_event function(m::Machine,::EmergencyDisconnect,::Completion,event)
    _matches(m,event.ticket) || return Hsm.EventHandled
    m.effect = nothing
    _fault_reply!(m)
    return Hsm.transition!(m,:HeldFault)
end
@on_event function(m::Machine,::EmergencyDisconnect,::Failure,event)
    _receive_failure!(m,event) || return Hsm.EventHandled
    m.cleanup_failure = String(event.reason)
    _fault_reply!(m)
    return Hsm.transition!(m,:HeldFault)
end
@on_event function(m::Machine,::EmergencyDisconnect,::Tick,_)
    return Hsm.EventHandled
end
@on_event function(m::Machine,::EmergencyDisconnect,::RequiredLost,_)
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Managed,::Completion,event)
    _matches(m,event.ticket) || return Hsm.EventHandled
    _enter_fault!(m,"Session effect expired; outcome unknown")
    return Hsm.transition!(m,:HoldingFaultSources)
end
@on_event function(m::Machine,::Executing,::Completion,event)
    _matches(m,event.ticket) || return Hsm.EventHandled
    if m.mutated
        _enter_fault!(m,"Session effect expired; outcome unknown")
        return Hsm.transition!(m,:HoldingFaultSources)
    end
    _refuse_operation!(m,"Session query expired")
    if _ready(m.origin)
        return Hsm.transition!(m,:Ready)
    end
    return Hsm.transition!(m,:Running)
end
@on_event function(m::Machine,::Root,::Completion,_)
    return Hsm.EventHandled
end

@on_event function(m::Machine,::Managed,::Failure,event)
    _receive_failure!(m,event) || return Hsm.EventHandled
    _enter_fault!(m,event.reason)
    return Hsm.transition!(m,:HoldingFaultSources)
end
@on_event function(m::Machine,::Executing,::Failure,event)
    _receive_failure!(m,event) || return Hsm.EventHandled
    if m.mutated
        _enter_fault!(m,event.reason)
        return Hsm.transition!(m,:HoldingFaultSources)
    end
    _refuse_operation!(m,event.reason)
    if _ready(m.origin)
        return Hsm.transition!(m,:Ready)
    end
    return Hsm.transition!(m,:Running)
end
@on_event function(m::Machine,::Root,::Failure,_)
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Managed,::Tick,_)
    m.effect === nothing && return Hsm.EventHandled
    _now(m) < m.deadline && return Hsm.EventHandled
    _enter_fault!(m,"Session effect expired; outcome unknown")
    return Hsm.transition!(m,:HoldingFaultSources)
end
@on_event function(m::Machine,::Executing,::Tick,_)
    m.effect === nothing && return Hsm.EventHandled
    _now(m) < m.deadline && return Hsm.EventHandled
    if m.mutated
        _enter_fault!(m,"Session effect expired; outcome unknown")
        return Hsm.transition!(m,:HoldingFaultSources)
    end
    _refuse_operation!(m,"Session query expired")
    if _ready(m.origin)
        return Hsm.transition!(m,:Ready)
    end
    return Hsm.transition!(m,:Running)
end
@on_event function(m::Machine,::Root,::Tick,_)
    return Hsm.EventHandled
end

# Fault compensation has its own absolute budget. A failed source Hold cannot
# establish safe graph teardown: disconnect invokes systemd's emergency path.
for event in (:Failure,:Tick)
    validity = event === :Failure ? :(_receive_failure!(m,event)) :
        event === :Completion ? :(_matches(m,event.ticket) && _expired(m,event)) :
        :(m.effect !== nothing && _now(m) >= m.deadline)
    reason = event === :Failure ? :(event.reason) : :("Fault cleanup expired; outcome unknown")
    @eval @on_event function(m::Machine,::HoldingFaultSources,::$event,event)
        $validity || return Hsm.EventNotHandled
        _cleanup_failed!(m,$reason)
        _issue!(m,Disconnect())
        return Hsm.transition!(m,:EmergencyDisconnect)
    end
    @eval @on_event function(m::Machine,::HoldingFaultGraphs,::$event,event)
        $validity || return Hsm.EventNotHandled
        _cleanup_failed!(m,$reason)
        _issue!(m,WithdrawLinks())
        return Hsm.transition!(m,:WithdrawingFaultLinks)
    end
    @eval @on_event function(m::Machine,::Fault,::$event,event)
        $validity || return Hsm.EventHandled
        _cleanup_failed!(m,$reason)
        _fault_reply!(m)
        return Hsm.transition!(m,:HeldFault)
    end
end
@on_event function(m::Machine,::Fault,::Completion,event)
    _matches(m,event.ticket) || return Hsm.EventHandled
    _cleanup_failed!(m,"Fault cleanup expired; outcome unknown")
    _fault_reply!(m)
    return Hsm.transition!(m,:HeldFault)
end
# Completion handlers above must handle success before Fault's expiry fallback.
@on_event function(m::Machine,::HoldingFaultSources,::Completion,event)
    if _accept!(m,event)
        _issue!(m,HoldGraphs())
        return Hsm.transition!(m,:HoldingFaultGraphs)
    end
    _matches(m,event.ticket) || return Hsm.EventHandled
    _cleanup_failed!(m,"Fault source Hold expired; outcome unknown")
    _issue!(m,Disconnect())
    return Hsm.transition!(m,:EmergencyDisconnect)
end
@on_event function(m::Machine,::HoldingFaultGraphs,::Completion,event)
    if _accept!(m,event)
        _issue!(m,WithdrawLinks())
        return Hsm.transition!(m,:WithdrawingFaultLinks)
    end
    _matches(m,event.ticket) || return Hsm.EventHandled
    _cleanup_failed!(m,"Fault graph Hold expired; outcome unknown")
    _issue!(m,WithdrawLinks())
    return Hsm.transition!(m,:WithdrawingFaultLinks)
end

@on_event function(m::Machine,::Managed,::QuitRequested,r)
    _begin_quit!(m,r)
    return Hsm.transition!(m,:HoldingQuitSources)
end
@on_event function(m::Machine,::ShuttingDown,::QuitRequested,r)
    _reply!(m,r,:Failed;error="Session shutdown already pending")
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Root,::QuitRequested,r)
    _reply!(m,r,:Failed;error="Session is offline")
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Configuring,::WarmupRequested,r)
    if r.controller === nothing || (m.admission_controller !== nothing &&
            r.controller != m.admission_controller)
        _reply!(m,r,:Failed;error="Resource admission launcher incarnation changed")
    else
        m.admission_controller = r.controller
        _reply!(m,r,:Warmup,m.warmed)
    end
    return Hsm.EventHandled
end
@on_event function(m::Machine,::AwaitingAdmission,::AdmissionRequested,r)
    if m.admission_controller === nothing || r.controller != m.admission_controller
        _reply!(m,r,:Failed;error="Resource admission requires prior launcher inspection")
        return Hsm.EventHandled
    end
    _lifecycle!(m,ReadyOrigin())
    _reply!(m,r,:Warmup,true)
    return Hsm.transition!(m,:Ready)
end
for event in (:WarmupRequested,:AdmissionRequested)
    @eval @on_event function(m::Machine,::Root,::$event,r)
        _reply!(m,r,:Failed;error="Resource admission is not available in this state")
        return Hsm.EventHandled
    end
end
_event(::Quit) = :QuitRequested
_event(::InspectWarmup) = :WarmupRequested
_event(::Admit) = :AdmissionRequested
for (command,event) in ((:Groups,:GroupsRequested),(:Status,:StatusRequested),
        (:Properties,:PropertiesRequested),(:PropertyGeneration,:PropertyGenerationRequested),
        (:ParameterGeneration,:ParameterGenerationRequested),(:StopGroup,:StopGroupRequested),
        (:StartGroup,:StartGroupRequested),(:Stop,:StopRequested),(:Start,:StartRequested),
        (:SourceEnded,:SourceEndedRequested),(:Reset,:ResetRequested),
        (:SetProperties,:SetPropertiesRequested),(:SetParameter,:SetParameterRequested))
    @eval _event(::$command) = $(QuoteNode(event))
    if command !== :Groups && command !== :Status
        @eval @on_event function(m::Machine,::Root,::$event,r)
            _reply!(m,r,:Failed;error="Operation is not admitted in this state")
            return Hsm.EventHandled
        end
    end
end
@on_event function(m::Machine,::Root,::GroupsRequested,r)
    _reply!(m,r,:Observed,m.observation.groups)
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Root,::StatusRequested,r)
    _reply!(m,r,:Observed,m.observation.status)
    return Hsm.EventHandled
end
@on_event function(m::Machine,::Ready,::StartRequested,r)
    _begin!(m,r,ReadyOrigin())
    _issue!(m,RunGraphs())
    return Hsm.transition!(m,:StartingGraphs)
end
@on_event function(m::Machine,::Ready,::ResetRequested,r)
    _begin!(m,r,ReadyOrigin())
    _issue!(m,HoldSources())
    return Hsm.transition!(m,:ResettingSourcesHold)
end
for (state,origin) in ((:Ready,:ReadyOrigin),(:Running,:RunningOrigin))
    @eval @on_event function(m::Machine,::$state,::StopRequested,r)
        _begin!(m,r,$origin())
        _issue!(m,HoldSources())
        return Hsm.transition!(m,:StoppingSources)
    end
    @eval @on_event function(m::Machine,::$state,::SourceEndedRequested,r)
        _begin!(m,r,$origin())
        _issue!(m,QuerySourceEnd())
        return Hsm.transition!(m,:CheckingSourceEnd)
    end
    for (event,effect) in ((:GroupsRequested,:QueryGroups),(:StatusRequested,:QueryStatus))
        @eval @on_event function(m::Machine,::$state,::$event,r)
            _begin!(m,r,$origin())
            _issue!(m,$effect())
            return Hsm.transition!(m,:Querying)
        end
    end
    for (event,effect,nextstate) in ((:PropertiesRequested,:QueryProperties,:Querying),
            (:PropertyGenerationRequested,:QueryPropertyGeneration,:Querying),
            (:ParameterGenerationRequested,:QueryParameterGeneration,:Querying),
            (:SetPropertiesRequested,:UpdateProperties,:Updating),
            (:SetParameterRequested,:SubmitParameter,:Updating))
        @eval @on_event function(m::Machine,::$state,::$event,r)
            _begin!(m,r,$origin())
            _issue!(m,$effect(r.payload))
            return Hsm.transition!(m,$(QuoteNode(nextstate)))
        end
    end
end
for (event,running) in ((:StopGroupRequested,false),(:StartGroupRequested,true))
    @eval @on_event function(m::Machine,::Running,::$event,r)
        _begin!(m,r,RunningOrigin())
        _issue!(m,RunGraphs(r.payload,$running))
        return Hsm.transition!(m,:ControllingGroup)
    end
end

function Machine(session::Integer;clock=Common.MONOTONIC_CLOCK,startup_timeout::Real=300.0,
        admission_controller::Union{Nothing,Identity}=nothing)
    0 < session <= typemax(Int64) || throw(ArgumentError("invalid session incarnation"))
    isfinite(startup_timeout) && 1 <= startup_timeout <= 3600 ||
        throw(ArgumentError("invalid startup timeout"))
    m = Machine(UInt64(session),clock,Float64(startup_timeout),admission_controller,
        UInt32(1),OfflineOrigin(),false,UInt64(0),UInt64(0),ConfiguringOrigin(),nothing,nothing,nothing,
        nothing,nothing,Reply[],Reply[],Inf,false,nothing,nothing,false,Observation(nothing,nothing))
    Hsm.dispatch!(m,:Boot)
    return m
end
submit!(m::Machine,r::Request) = (Hsm.dispatch!(m,_event(r.command),r); nothing)
submitted!(m::Machine,t::EffectTicket) = (Hsm.dispatch!(m,:Submitted,t); nothing)
complete!(m::Machine,t::EffectTicket,result=nothing;at::Real=_now(m)) =
    (Hsm.dispatch!(m,:Completion,(;ticket=t,result,at=Float64(at))); nothing)
fail!(m::Machine,t::EffectTicket,reason::AbstractString;submitted::Bool=true) =
    (Hsm.dispatch!(m,:Failure,(;ticket=t,reason=String(reason),submitted)); nothing)
tick!(m::Machine) = (Hsm.dispatch!(m,:Tick); nothing)
required_lost!(m::Machine,reason::AbstractString) =
    (Hsm.dispatch!(m,:RequiredLost,String(reason)); nothing)
take_cancelled!(m::Machine) = (Hsm.dispatch!(m,:TakeCancellation); m.cancellation_delivery)
take_replies!(m::Machine) = (Hsm.dispatch!(m,:TakeReplies); m.reply_delivery)
observe!(m::Machine,o::Observation) = (Hsm.dispatch!(m,:Observed,o); nothing)
