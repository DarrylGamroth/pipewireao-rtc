"""Serialized owner-local protective recovery; no transport or numerical execution.

All calls must run on one owner control thread. Effects are returned once to that
owner, which stages them through its existing graph interfaces. Returning an
effect does not prove acceptance or application. Never retry an uncertain effect.
Normal hold/resume retains its separate `CorrectionLoops` contract.
"""
module CorrectionRecovery

using Hsm: @hsmdef, @statedef, @on_initial, @on_event, @on_entry, @on_exit
import Hsm
import Clocks

public Coordinator,
    StageRecovery,
    ReleaseRecovery,
    CloseLoop,
    AbstractObservation,
    AbstractLoopObservation,
    AbstractControllerScope,
    SingleController,
    CoupledControllers,
    controller_scope,
    same_scope,
    owner_instance,
    operation_token,
    observation_serial,
    requested_generation,
    active_generation,
    closed,
    all_open,
    all_closed,
    generations_match,
    requested_before,
    active_before,
    active_at_most,
    active_at_least,
    LoopObservation,
    RecoveryObservation,
    ReferenceObservation,
    ReleaseObservation,
    state,
    qualify!,
    request_protection!,
    staged!,
    recovery_staged!,
    observe_loop!,
    observe_recovery!,
    observe_reference!,
    request_close!,
    observe_release!,
    check_timeout!,
    failed!,
    cancel!,
    owner_replaced!

"""An explicit command effect bound to one owner incarnation and operation token."""
struct StageRecovery
    owner_instance::Int64
    token::UInt64
end
"""
    ReleaseRecovery(owner_instance, token, generation)

Effect requesting release of protective recovery inhibition for one owner
incarnation, operation token and recovery generation. Constructing or returning
this value does not prove that the owner accepted or applied the release.
"""
struct ReleaseRecovery
    owner_instance::Int64
    token::UInt64
    generation::UInt64
end
"""
    CloseLoop(owner_instance, token)

Effect requesting the selected correction-loop closure for one owner
incarnation and operation token. Constructing or returning this value does not
prove that the owner accepted or applied the close.
"""
struct CloseLoop
    owner_instance::Int64
    token::UInt64
end

include("observations.jl")

"""One bounded recovery operation for one immutable owner incarnation.

Unverified/Fault outcomes latch and require external reconciliation and a newly
qualified coordinator. History never restores commands or numerical state.
Timeouts are checked by the serialized owner, including before every observation
and operation; no background writer or timer task is created.
`clock` implements `Clocks.AbstractNanoClock` and returns signed Int64 ticks.
Clock regression or unrepresentable elapsed/deadline arithmetic fails closed.
"""
@hsmdef mutable struct Coordinator{C,G,V}
    const owner_instance::Int64
    const clock::C
    const timeout_ns::Int64
    token::UInt64
    serial::UInt64
    loop_generation::G
    expected_loop_generation::G
    target_closed::V
    recovery_generation::UInt64
    reference_serial::UInt64
    reference_since_ns::Int64
    pending_since_ns::Int64
    last_at_ns::Int64
    reason::Symbol
    failure::Union{Nothing,Symbol}
end

@statedef Coordinator :Unverified
@statedef Coordinator :Fault
@statedef Coordinator :Operational
@statedef Coordinator :Open :Operational
@statedef Coordinator :Closed :Operational
@statedef Coordinator :PartiallyClosed :Operational
@statedef Coordinator :ProtectiveOpen :Operational
@statedef Coordinator :Opening :ProtectiveOpen
@statedef Coordinator :RestoringReference :ProtectiveOpen
@statedef Coordinator :Verifying :ProtectiveOpen
@statedef Coordinator :Holding :ProtectiveOpen
@statedef Coordinator :Releasing :ProtectiveOpen
@statedef Coordinator :Closing :Operational

@on_initial function (sm::Coordinator{C}, ::Root) where {C}
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::Unverified, ::Qualified, observation) where {C}
    sm.failure === nothing || return Hsm.EventNotHandled
    now = try
        Clocks.time_nanos(sm.clock)
    catch
        latch_failure!(sm, :clock_error)
        return Hsm.transition!(sm, :Unverified)
    end
    record_clock!(sm, now) || return Hsm.transition!(sm, :Unverified)
    matching_observation(sm, observation) || return Hsm.EventNotHandled
    reason = if !same_scope(sm, observation)
        :loop_scope_mismatch
    elseif !generations_match(observation)
        :initial_generation_mismatch
    else
        nothing
    end
    if reason !== nothing
        latch_failure!(sm, reason)
        return Hsm.transition!(sm, :Unverified)
    end
    sm.serial = observation_serial(observation)
    sm.loop_generation = active_generation(observation)
    sm.target_closed = closed(observation)
    return if all_open(observation)
        Hsm.transition!(sm, :Open)
    elseif all_closed(observation)
        Hsm.transition!(sm, :Closed)
    else
        Hsm.transition!(sm, :PartiallyClosed)
    end
end
@on_event function (sm::Coordinator{C}, ::Open, ::Protect, request) where {C}
    if !accept_protection!(sm, request)
        sm.failure === nothing && return Hsm.EventNotHandled
        return Hsm.transition!(sm, :Unverified)
    end
    return Hsm.transition!(sm, :Opening)
end
@on_event function (sm::Coordinator{C}, ::Closed, ::Protect, request) where {C}
    if !accept_protection!(sm, request)
        sm.failure === nothing && return Hsm.EventNotHandled
        return Hsm.transition!(sm, :Unverified)
    end
    return Hsm.transition!(sm, :Opening)
end
@on_event function (sm::Coordinator{C}, ::PartiallyClosed, ::Protect, request) where {C}
    if !accept_protection!(sm, request)
        sm.failure === nothing && return Hsm.EventNotHandled
        return Hsm.transition!(sm, :Unverified)
    end
    return Hsm.transition!(sm, :Opening)
end
@on_event function (sm::Coordinator{C}, ::Opening, ::LoopObserved, observation) where {C}
    matching_observation(sm, observation) || return Hsm.EventHandled
    outcome = adopt_loop!(sm, observation)
    outcome === :pending && return Hsm.EventHandled
    outcome === :applied && return Hsm.transition!(sm, :RestoringReference)
    latch_failure!(sm, outcome)
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (
    sm::Coordinator{C}, ::ProtectiveOpen, ::LoopObserved, observation
) where {C}
    matching_observation(sm, observation) || return Hsm.EventHandled
    reason = monitor_open_loop!(sm, observation)
    reason === nothing && return Hsm.EventHandled
    latch_failure!(sm, reason)
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (
    sm::Coordinator{C}, ::RestoringReference, ::RecoveryObserved, observation
) where {C}
    matching_observation(sm, observation) || return Hsm.EventHandled
    outcome = recovery_outcome(sm, observation)
    outcome === :pending && return Hsm.EventHandled
    if outcome === :applied
        sm.serial = observation_serial(observation)
        return Hsm.transition!(sm, :Verifying)
    end
    latch_failure!(sm, outcome)
    return outcome === :recovery_failed ? Hsm.transition!(sm, :Fault) :
           Hsm.transition!(sm, :Unverified)
end
@on_event function (
    sm::Coordinator{C}, ::Verifying, ::ReferenceObserved, observation
) where {C}
    matching_reference(sm, observation) || return Hsm.EventHandled
    record_reference!(sm, observation) || return Hsm.EventHandled
    return Hsm.transition!(sm, :Holding)
end
@on_event function (
    sm::Coordinator{C}, ::Holding, ::ReferenceObserved, observation
) where {C}
    matching_reference(sm, observation) || return Hsm.EventHandled
    record_reference!(sm, observation)
    return Hsm.EventHandled
end
@on_event function (
    sm::Coordinator{C}, ::PartiallyClosed, ::ReferenceObserved, observation
) where {C}
    matching_reference(sm, observation) || return Hsm.EventHandled
    record_reference!(sm, observation)
    return Hsm.EventHandled
end
@on_event function (
    sm::Coordinator{C}, ::Releasing, ::ReferenceObserved, observation
) where {C}
    matching_reference(sm, observation) || return Hsm.EventHandled
    if !record_reference!(sm, observation)
        latch_failure!(sm, :release_prerequisites_changed)
        return Hsm.transition!(sm, :Unverified)
    end
    return Hsm.EventHandled
end
@on_event function (sm::Coordinator{C}, ::Holding, ::Release, request) where {C}
    accept_close!(sm, request) || return Hsm.EventNotHandled
    return Hsm.transition!(sm, :Releasing)
end
@on_event function (
    sm::Coordinator{C}, ::Releasing, ::ReleaseObserved, observation
) where {C}
    matching_reference(sm, observation) && observation.released ||
        return Hsm.EventNotHandled
    reason = accept_release!(sm, observation)
    if reason !== nothing
        latch_failure!(sm, reason)
        return Hsm.transition!(sm, :Unverified)
    end
    return Hsm.transition!(sm, :Closing)
end
@on_event function (sm::Coordinator{C}, ::Closing, ::LoopObserved, observation) where {C}
    matching_observation(sm, observation) || return Hsm.EventHandled
    outcome = adopt_loop!(sm, observation)
    outcome === :pending && return Hsm.EventHandled
    if outcome !== :applied
        latch_failure!(sm, outcome)
        return Hsm.transition!(sm, :Unverified)
    end
    return if all_open(sm)
        Hsm.transition!(sm, :Open)
    elseif all_closed(sm)
        Hsm.transition!(sm, :Closed)
    else
        Hsm.transition!(sm, :PartiallyClosed)
    end
end
@on_event function (
    sm::Coordinator{C}, ::PartiallyClosed, ::CloseRemaining, request
) where {C}
    accept_close!(sm, request) || return Hsm.EventNotHandled
    return Hsm.transition!(sm, :Closing)
end
@on_event function (sm::Coordinator{C}, ::Closing, ::LoopStaged, staged) where {C}
    matching_effect(sm, staged.effect) || return Hsm.EventNotHandled
    reason = bind_loop!(sm, staged.generation)
    reason === nothing && return Hsm.EventHandled
    latch_failure!(sm, reason)
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::Opening, ::RecoveryStaged, staged) where {C}
    matching_effect(sm, staged.effect) || return Hsm.EventNotHandled
    reason = bind_recovery!(sm, staged.generation, staged.loop_generation)
    reason === nothing && return Hsm.EventHandled
    latch_failure!(sm, reason)
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::ProtectiveOpen, ::Cancelled, request) where {C}
    matching_effect(sm, request) || return Hsm.EventNotHandled
    latch_failure!(sm, :operation_cancelled)
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::Closing, ::Cancelled, request) where {C}
    matching_effect(sm, request) || return Hsm.EventNotHandled
    latch_failure!(sm, :operation_cancelled)
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::PartiallyClosed, ::Cancelled, request) where {C}
    matching_effect(sm, request) && sm.recovery_generation > 0 || return Hsm.EventNotHandled
    latch_failure!(sm, :operation_cancelled)
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::Opening, ::DeadlineChecked, now) where {C}
    deadline_expired!(sm, now) || return Hsm.EventHandled
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (
    sm::Coordinator{C}, ::RestoringReference, ::DeadlineChecked, now
) where {C}
    deadline_expired!(sm, now) || return Hsm.EventHandled
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::Verifying, ::DeadlineChecked, now) where {C}
    deadline_expired!(sm, now) || return Hsm.EventHandled
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::Releasing, ::DeadlineChecked, now) where {C}
    deadline_expired!(sm, now) || return Hsm.EventHandled
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::Closing, ::DeadlineChecked, now) where {C}
    deadline_expired!(sm, now) || return Hsm.EventHandled
    return Hsm.transition!(sm, :Unverified)
end
@on_event function (sm::Coordinator{C}, ::Root, ::Failed, failure) where {C}
    latch_failure!(sm, failure.reason) || return Hsm.EventHandled
    return failure.uncertain ? Hsm.transition!(sm, :Unverified) :
           Hsm.transition!(sm, :Fault)
end

# Entry/exit behaviors own deadlines only. Commands stay in admitted operations.
@on_entry function (sm::Coordinator{C}, ::Opening) where {C}
    sm.pending_since_ns = Clocks.time_nanos(sm.clock)
    return nothing
end
@on_entry function (sm::Coordinator{C}, ::RestoringReference) where {C}
    sm.pending_since_ns = Clocks.time_nanos(sm.clock)
    return nothing
end
@on_entry function (sm::Coordinator{C}, ::Verifying) where {C}
    sm.pending_since_ns = Clocks.time_nanos(sm.clock)
    return nothing
end
@on_entry function (sm::Coordinator{C}, ::Releasing) where {C}
    sm.pending_since_ns = Clocks.time_nanos(sm.clock)
    return nothing
end
@on_entry function (sm::Coordinator{C}, ::Closing) where {C}
    sm.pending_since_ns = Clocks.time_nanos(sm.clock)
    return nothing
end
@on_exit function (sm::Coordinator{C}, ::Opening) where {C}
    sm.pending_since_ns = Int64(0)
    return nothing
end
@on_exit function (sm::Coordinator{C}, ::RestoringReference) where {C}
    sm.pending_since_ns = Int64(0)
    return nothing
end
@on_exit function (sm::Coordinator{C}, ::Verifying) where {C}
    sm.pending_since_ns = Int64(0)
    return nothing
end
@on_exit function (sm::Coordinator{C}, ::Releasing) where {C}
    sm.pending_since_ns = Int64(0)
    return nothing
end
@on_exit function (sm::Coordinator{C}, ::Closing) where {C}
    sm.pending_since_ns = Int64(0)
    return nothing
end

controller_scope(sm::Coordinator) =
    _controller_scope(sm.loop_generation, sm.expected_loop_generation, sm.target_closed)
closed(sm::Coordinator) = sm.target_closed
all_open(sm::Coordinator) = all_open(controller_scope(sm), sm)
all_closed(sm::Coordinator) = all_closed(controller_scope(sm), sm)

unstaged_generation(sm::Coordinator) = unstaged_generation(controller_scope(sm))
unstaged_generation(::SingleController) = UInt64(0)
unstaged_generation(::CoupledControllers{N}) where {N} = ntuple(_ -> UInt64(0), Val(N))
has_staged_loop(sm::Coordinator) = has_staged_loop(controller_scope(sm), sm)
has_staged_loop(::SingleController, sm::Coordinator) = !iszero(sm.expected_loop_generation)
has_staged_loop(::CoupledControllers, sm::Coordinator) =
    !all(iszero, sm.expected_loop_generation)

open_target(::SingleController) = false
open_target(::CoupledControllers{N}) where {N} = ntuple(_ -> false, Val(N))
close_target(::SingleController) = true
close_target(::CoupledControllers{N}) where {N} = ntuple(_ -> true, Val(N))

function adds_closure(sm::Coordinator, selected)
    same_scope(controller_scope(sm), _closure_scope(selected)) || return false
    return adds_closure(controller_scope(sm), sm, selected)
end
adds_closure(::SingleController, sm::Coordinator, selected::Bool) =
    selected && !sm.target_closed
adds_closure(::CoupledControllers{N}, sm::Coordinator, selected::NTuple{N,Bool}) where {N} =
    selected != sm.target_closed &&
    all(map((after, before) -> !before || after, selected, sm.target_closed))

generation_scope_matches(sm::Coordinator, generation) = same_scope(
    controller_scope(sm), _controller_scope(generation, generation, sm.target_closed)
)
staging_advances(::SingleController, sm::Coordinator, generation::UInt64) =
    generation > sm.loop_generation
staging_advances(
    ::CoupledControllers{N}, sm::Coordinator, generation::NTuple{N,UInt64}
) where {N} =
    generation != sm.loop_generation && all(map(>=, generation, sm.loop_generation))
recovery_staging_advances(::SingleController, sm::Coordinator, generation::UInt64) =
    generation > sm.loop_generation
recovery_staging_advances(
    ::CoupledControllers{N}, sm::Coordinator, generation::NTuple{N,UInt64}
) where {N} = all(map(>, generation, sm.loop_generation))

_check_timeout(::Bool) = throw(ArgumentError("timeout_ms must be between 1 and 60000"))
_check_timeout(timeout_ms::Integer) =
    1 <= timeout_ms <= 60_000 ||
    throw(ArgumentError("timeout_ms must be between 1 and 60000"))
_check_controller_count(::Nothing) = nothing
_check_controller_count(::Bool) = throw(ArgumentError("controllers must lie in 1:16"))
_check_controller_count(controllers::Integer) =
    1 <= controllers <= 16 || throw(ArgumentError("controllers must lie in 1:16"))

function Coordinator(
    owner_instance::Int64;
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
    timeout_ms::Integer = 5000,
    controllers::Union{Nothing,Integer} = nothing,
)
    owner_instance > 0 || throw(ArgumentError("owner incarnation must be positive"))
    _check_timeout(timeout_ms)
    now = Clocks.time_nanos(clock)
    _check_controller_count(controllers)
    generation = controllers === nothing ? UInt64(0) : ntuple(_ -> UInt64(0), controllers)
    target = controllers === nothing ? true : ntuple(_ -> true, controllers)
    return Coordinator(
        owner_instance,
        clock,
        Int64(timeout_ms) * Int64(1_000_000),
        UInt64(0),
        UInt64(0),
        generation,
        generation,
        target,
        UInt64(0),
        UInt64(0),
        Int64(0),
        Int64(0),
        now,
        :none,
        nothing,
    )
end

"""
    state(coordinator::Coordinator)

Return the coordinator's current state symbol, such as `:Unverified`,
`:Opening`, `:Holding`, `:Closing`, or `:Fault`. State records the local
protocol position; it does not independently establish graph adoption.
"""
state(sm::Coordinator) = Hsm.current(sm)

"""Latch failure; uncertain effects become Unverified and are never replayed."""
function failed!(sm::Coordinator, reason::Symbol; uncertain::Bool = true)
    Hsm.dispatch!(sm, :Failed, (; reason, uncertain))
    return nothing
end

"""
    check_timeout!(coordinator::Coordinator)

Check the injected nanosecond clock against the active operation deadline.
Expired operations latch `:operation_timeout`; clock errors latch
`:clock_error`. Returns `nothing` and issues no effect. Owners call this on
their serialized control thread before processing observations and requests.
"""
function check_timeout!(sm::Coordinator)
    sm.failure === nothing || return nothing
    now = try
        Clocks.time_nanos(sm.clock)
    catch
        return failed!(sm, :clock_error)
    end
    Hsm.dispatch!(sm, :DeadlineChecked, now)
    return nothing
end

function matches(sm::Coordinator, observation)
    check_timeout!(sm)
    return matching_observation(sm, observation)
end
matching_observation(sm, observation) =
    sm.failure === nothing &&
    owner_instance(observation) == sm.owner_instance &&
    operation_token(observation) == sm.token &&
    observation_serial(observation) > sm.serial
matching_reference(sm, observation) =
    matching_observation(sm, observation) &&
    sm.recovery_generation > 0 &&
    observation.generation == sm.recovery_generation
matching_effect(sm, effect) =
    sm.failure === nothing &&
    effect.owner_instance == sm.owner_instance &&
    effect.token == sm.token

# Handler helpers mutate accepted facts only; they never dispatch or transition.
function latch_failure!(sm, reason)
    sm.failure === nothing || return false
    sm.failure = reason
    sm.reference_serial = 0
    return true
end
# Strict expiry for reference/adoption budgets; signed zero is a valid origin.
function fresh_within(now::Int64, then::Int64, timeout::Int64)
    now >= then || return false
    elapsed, overflow = Base.sub_with_overflow(now, then)
    return !overflow && elapsed < timeout
end
function record_clock!(sm, now::Int64)
    sm.failure === nothing || return false
    if now < sm.last_at_ns || last(Base.add_with_overflow(now, sm.timeout_ns))
        latch_failure!(sm, :clock_error)
        return false
    end
    sm.last_at_ns = now
    return true
end
@on_event function (sm::Coordinator{C}, ::Root, ::DeadlineChecked, now::Int64) where {C}
    record_clock!(sm, now) && return Hsm.EventHandled
    return Hsm.transition!(sm, :Unverified)
end
function deadline_expired!(sm, now::Int64)
    record_clock!(sm, now) || return true
    elapsed = try
        Base.checked_sub(now, sm.pending_since_ns)
    catch
        latch_failure!(sm, :clock_error)
        return true
    end
    return elapsed >= sm.timeout_ns && latch_failure!(sm, :operation_timeout)
end
function accept_protection!(sm, request)
    sm.failure === nothing &&
    request.owner_instance == sm.owner_instance &&
    request.token > sm.token || return false
    try
        Base.checked_add(sm.last_at_ns, sm.timeout_ns)
    catch
        latch_failure!(sm, :clock_error)
        return false
    end
    sm.token = request.token
    sm.reason = request.reason
    sm.expected_loop_generation = unstaged_generation(sm)
    sm.target_closed = open_target(controller_scope(sm))
    sm.recovery_generation = 0
    sm.reference_serial = 0
    return true
end
function record_reference!(sm, observation)
    sm.serial = observation_serial(observation)
    if observation.reference_reached && observation.coherent && observation.ready
        sm.reference_serial = observation_serial(observation)
        sm.reference_since_ns = Clocks.time_nanos(sm.clock)
        return true
    end
    sm.reference_serial = 0
    return false
end
function accept_close!(sm, request)
    matching_effect(sm, request) &&
    sm.recovery_generation > 0 &&
    sm.reference_serial > 0 &&
    fresh_within(Clocks.time_nanos(sm.clock), sm.reference_since_ns, sm.timeout_ns) ||
        return false
    adds_closure(sm, request.closed) || throw(
        ArgumentError("close requires a nonempty scope-compatible controller selection")
    )
    sm.target_closed = request.closed
    return true
end
function accept_release!(sm, observation)
    sm.serial = observation_serial(observation)
    same_scope(sm, observation) || return :loop_scope_mismatch
    all_open(observation) &&
    observation.reference_reached &&
    observation.coherent &&
    observation.ready || return :release_prerequisites_changed
    sm.reference_serial = observation_serial(observation)
    sm.reference_since_ns = Clocks.time_nanos(sm.clock)
    sm.expected_loop_generation = unstaged_generation(sm)
    return nothing
end
function bind_loop!(sm, generation)
    generation_scope_matches(sm, generation) || return :loop_scope_mismatch
    sm.expected_loop_generation == generation && return nothing
    !has_staged_loop(sm) || return :conflicting_staging
    staging_advances(controller_scope(sm), sm, generation) ||
        return :invalid_loop_generation
    sm.expected_loop_generation = generation
    return nothing
end
function bind_recovery!(sm, generation, loop_generation)
    generation_scope_matches(sm, loop_generation) || return :loop_scope_mismatch
    sm.recovery_generation == generation &&
        generation > 0 &&
        sm.expected_loop_generation == loop_generation &&
        return nothing
    recovery_staging_advances(controller_scope(sm), sm, loop_generation) ||
        return :invalid_loop_generation
    sm.recovery_generation == 0 && generation > 0 || return :invalid_recovery_generation
    sm.recovery_generation = generation
    sm.expected_loop_generation = loop_generation
    return nothing
end
function adopt_loop!(sm, observation)
    same_scope(sm, observation) || return :loop_scope_mismatch
    expected = sm.expected_loop_generation
    !has_staged_loop(sm) && return :pending
    requested_before(observation, expected) && return :pending
    active_before(observation, sm.loop_generation) && return :pending
    requested_generation(observation) == expected &&
    active_at_most(observation, expected) || return :conflicting_loop_generation
    active_generation(observation) == expected || return :pending
    closed(observation) == sm.target_closed || return :conflicting_loop_value
    sm.serial = observation_serial(observation)
    sm.loop_generation = expected
    sm.expected_loop_generation = unstaged_generation(sm)
    return :applied
end
function monitor_open_loop!(sm, observation)
    same_scope(sm, observation) || return :loop_scope_mismatch
    active_before(observation, sm.loop_generation) && return nothing
    expected = sm.expected_loop_generation
    allowed_generation = !has_staged_loop(sm) ? sm.loop_generation : expected
    all_open(observation) &&
    requested_generation(observation) == allowed_generation &&
    active_at_least(observation, sm.loop_generation) &&
    active_at_most(observation, allowed_generation) || return :unexpected_loop_change
    sm.serial = observation_serial(observation)
    if active_generation(observation) == allowed_generation
        sm.loop_generation = allowed_generation
        sm.expected_loop_generation = unstaged_generation(sm)
    end
    return nothing
end
function recovery_outcome(sm, observation)
    generation = sm.recovery_generation
    generation > 0 || return :pending
    requested_generation(observation) < generation && return :pending
    requested_generation(observation) == generation &&
    active_generation(observation) <= generation || return :conflicting_recovery_generation
    observation.status === :failed && return :recovery_failed
    observation.status === :unknown && return :recovery_unknown
    active_generation(observation) == generation && observation.status === :applied ||
        return :pending
    observation.closure_inhibited || return :missing_closure_inhibition
    return :applied
end

"""Qualify only a new coordinator from exact current applied loop readback."""
function qualify!(sm::Coordinator, observation::AbstractLoopObservation)
    Hsm.dispatch!(sm, :Qualified, observation)
    return nothing
end

"""Admit one protective operation. `:saturation` is a reason, not a threshold policy."""
function request_protection!(
    sm::Coordinator, owner_instance::Int64, token::UInt64; reason::Symbol = :operator
)
    check_timeout!(sm)
    Hsm.dispatch!(sm, :Protect, (; owner_instance, token, reason)) == Hsm.EventHandled ||
        throw(
            ArgumentError("recovery requires a qualified owner and a new operation token")
        )
    # One atomic recovery stage inhibits closure, forces open and resets the
    # declared scientific scope. An ordinary open must never precede it.
    return StageRecovery(sm.owner_instance, token)
end

"""
    staged!(coordinator, effect::CloseLoop, generation)

Record the owner-reported generation assigned when the close effect was
staged. This binds the expected loop generation while `:Closing`; it does not
establish that the graph applied the close. Invalid or conflicting generations
latch a coordinator failure. Returns `nothing`.
"""
function staged!(sm::Coordinator, effect::CloseLoop, generation)
    check_timeout!(sm)
    Hsm.dispatch!(sm, :LoopStaged, (; effect, generation))
    return nothing
end

"""Observe exact forced-open/close adoption without emitting another stage."""
function observe_loop!(sm::Coordinator, observation::AbstractLoopObservation)
    matches(sm, observation) || return nothing
    same_scope(sm, observation) || return failed!(sm, :loop_scope_mismatch)
    Hsm.dispatch!(sm, :LoopObserved, observation)
    return nothing
end

"""
    recovery_staged!(coordinator, effect::StageRecovery, generation; loop_generation)

Record the owner-reported recovery and loop generations after the atomic
protective recovery effect was staged. This acknowledges staging only; graph
application and closure inhibition require a matching [`RecoveryObservation`](@ref).
Invalid scope or generation transitions latch a coordinator failure. Returns
`nothing`.
"""
function recovery_staged!(
    sm::Coordinator, effect::StageRecovery, generation::UInt64; loop_generation
)
    check_timeout!(sm)
    Hsm.dispatch!(sm, :RecoveryStaged, (; effect, generation, loop_generation))
    return nothing
end

"""
    observe_recovery!(coordinator, observation::RecoveryObservation)

Consume fresh recovery status for the current owner and operation. A matching
`:applied` status advances to reference verification only when requested and
active generations match and closure inhibition is confirmed. `:failed`,
`:unknown`, or contradictory evidence latches failure; stale or out-of-phase
observations are ignored. Returns `nothing` and emits no graph effect.
"""
function observe_recovery!(sm::Coordinator, observation::RecoveryObservation)
    matches(sm, observation) || return nothing
    Hsm.dispatch!(sm, :RecoveryObserved, observation)
    return nothing
end

"""
    observe_reference!(coordinator, observation::ReferenceObservation)

Consume a fresh reference observation for the current recovery generation.
Only evidence with `reference_reached`, `coherent` and `ready` all true records
verification; in `:Verifying` it advances to `:Holding`. Evidence lacking
these facts clears verification, and changed prerequisites during release
latch failure. Returns `nothing` and emits no graph effect.
"""
function observe_reference!(sm::Coordinator, observation::ReferenceObservation)
    matches(sm, observation) || return nothing
    sm.recovery_generation > 0 && observation.generation == sm.recovery_generation ||
        return nothing
    Hsm.dispatch!(sm, :ReferenceObserved, observation)
    return nothing
end

"""Explicit close intent: release inhibition, then revalidate before issuing close.

Recovery completion leaves Holding. Stale evidence or early closure is refused
without effects. A successful request emits only ReleaseRecovery; the owner must
observe the matching release with fresh prerequisites before CloseLoop can occur.
"""
function request_close!(
    sm::Coordinator,
    owner_instance::Int64,
    token::UInt64;
    closed = close_target(controller_scope(sm)),
    released::Bool = false,
)
    check_timeout!(sm)
    request = (; owner_instance, token, closed)
    if released && Hsm.dispatch!(sm, :CloseRemaining, request) == Hsm.EventHandled
        return CloseLoop(sm.owner_instance, sm.token)
    end
    Hsm.dispatch!(sm, :Release, request) == Hsm.EventHandled || throw(
        ArgumentError("close requires fresh verified reference, coherence and readiness"),
    )
    return ReleaseRecovery(sm.owner_instance, sm.token, sm.recovery_generation)
end

"""
    observe_release!(coordinator, observation::ReleaseObservation)

Consume fresh release adoption and readiness evidence for the active
operation. A matching released observation must show all loops open and
reference, coherence and readiness still valid; it then returns a
[`CloseLoop`](@ref) effect for the requested closure. It does not apply that
effect. Stale observations are ignored and changed prerequisites latch failure.
"""
function observe_release!(sm::Coordinator, observation::ReleaseObservation)
    matches(sm, observation) || return nothing
    Hsm.dispatch!(sm, :ReleaseObserved, observation) == Hsm.EventHandled &&
    sm.failure === nothing || return nothing
    return CloseLoop(sm.owner_instance, sm.token)
end

"""Cancel sequencing without undoing or replaying any effect already handed off.

Cancellation cannot claim a restored reference or revoke an applied command.
The outcome stays Unverified and existing graph inhibition remains authoritative.
"""
function cancel!(sm::Coordinator, owner_instance::Int64, token::UInt64)
    Hsm.dispatch!(sm, :Cancelled, (; owner_instance, token))
    return nothing
end

"""Invalidate this incarnation; construct and qualify a new owner separately."""
function owner_replaced!(sm::Coordinator, owner_instance::Int64)
    owner_instance == sm.owner_instance || failed!(sm, :owner_replaced)
    return nothing
end

include("recovery_client.jl")

end
