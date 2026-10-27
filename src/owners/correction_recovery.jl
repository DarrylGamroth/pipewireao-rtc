"""Serialized owner-local protective recovery; no transport or numerical execution.

All calls must run on one owner control thread. Effects are returned once to that
owner, which stages them through its existing graph interfaces. Returning an
effect does not prove acceptance or application. Never retry an uncertain effect.
Normal hold/resume retains its separate `CorrectionLoops` contract.
"""
module CorrectionRecovery

using Hsm: @hsmdef, @statedef, @on_initial, @on_event, @on_entry, @on_exit
import Hsm

public Coordinator, StageRecovery, ReleaseRecovery, CloseLoop,
    LoopObservation, RecoveryObservation, ReferenceObservation, ReleaseObservation,
    state, qualify!, request_protection!, staged!, recovery_staged!, observe_loop!,
    observe_recovery!, observe_reference!, request_close!, observe_release!,
    check_timeout!, failed!, cancel!, owner_replaced!

"""An explicit command effect bound to one owner incarnation and operation token."""
struct StageRecovery
    owner_instance::Int64
    token::UInt64
end
struct ReleaseRecovery
    owner_instance::Int64
    token::UInt64
    generation::UInt64
end
struct CloseLoop
    owner_instance::Int64
    token::UInt64
end

"""Exact atomic Boolean/generation readback, with an owner-produced serial.

All observations in an operation share one strictly increasing serial sequence
assigned by the serialized owner when obtaining evidence. A serial is not a
caller readiness assertion or evidence of physical settling. Token zero is used
only for initial qualification. Adapters must not relabel cached observations.
"""
struct LoopObservation
    owner_instance::Int64
    token::UInt64
    serial::UInt64
    requested_generation::UInt64
    active_generation::UInt64
    closed::Bool
end

"""Graph recovery status; `:applied` establishes scope adoption, not reference arrival."""
struct RecoveryObservation
    owner_instance::Int64
    token::UInt64
    serial::UInt64
    requested_generation::UInt64
    active_generation::UInt64
    status::Symbol
    closure_inhibited::Bool
end

"""Fresh command-reference, coherence and RTC readiness evidence for this scope.

The scientific owner supplies these facts after scope adoption. `reference_reached`
means the declared command reference was reached; it does not claim physical
settling. `coherent` covers controller, participants and delayed feedback.
"""
struct ReferenceObservation
    owner_instance::Int64
    token::UInt64
    serial::UInt64
    generation::UInt64
    reference_reached::Bool
    coherent::Bool
    ready::Bool
end

"""Fresh release adoption and revalidated closure prerequisites, obtained together.

The owner must establish these facts after the release callback boundary; it
cannot copy the pre-release reference/readiness observation into this record.
"""
struct ReleaseObservation
    owner_instance::Int64
    token::UInt64
    serial::UInt64
    generation::UInt64
    released::Bool
    closed::Bool
    reference_reached::Bool
    coherent::Bool
    ready::Bool
end

"""One bounded recovery operation for one immutable owner incarnation.

Unverified/Fault outcomes latch and require external reconciliation and a newly
qualified coordinator. History never restores commands or numerical state.
Timeouts are checked by the serialized owner, including before every observation
and operation; no background writer or timer task is created.
"""
@hsmdef mutable struct Coordinator{C}
    const owner_instance::Int64
    const clock::C
    const timeout_ns::UInt64
    token::UInt64
    serial::UInt64
    loop_generation::UInt64
    expected_loop_generation::UInt64
    recovery_generation::UInt64
    reference_serial::UInt64
    reference_since_ns::UInt64
    pending_since_ns::UInt64
    reason::Symbol
    failure::Union{Nothing,Symbol}
end

@statedef Coordinator :Unverified
@statedef Coordinator :Fault
@statedef Coordinator :Operational
@statedef Coordinator :Open :Operational
@statedef Coordinator :Closed :Operational
@statedef Coordinator :ProtectiveOpen :Operational
@statedef Coordinator :Opening :ProtectiveOpen
@statedef Coordinator :RestoringReference :ProtectiveOpen
@statedef Coordinator :Verifying :ProtectiveOpen
@statedef Coordinator :Holding :ProtectiveOpen
@statedef Coordinator :Releasing :ProtectiveOpen
@statedef Coordinator :Closing :Operational

@on_initial function(sm::Coordinator{C}, ::Root) where {C}
    return Hsm.transition!(sm, :Unverified)
end
@on_event function(sm::Coordinator{C}, ::Unverified, ::Qualified, closed::Bool) where {C}
    return closed ? Hsm.transition!(sm, :Closed) : Hsm.transition!(sm, :Open)
end
@on_event function(sm::Coordinator{C}, ::Operational, ::Protect, _) where {C}
    return Hsm.transition!(sm, :Opening)
end
@on_event function(sm::Coordinator{C}, ::Opening, ::Opened, _) where {C}
    return Hsm.transition!(sm, :RestoringReference)
end
@on_event function(sm::Coordinator{C}, ::RestoringReference, ::Applied, _) where {C}
    return Hsm.transition!(sm, :Verifying)
end
@on_event function(sm::Coordinator{C}, ::Verifying, ::Verified, _) where {C}
    return Hsm.transition!(sm, :Holding)
end
@on_event function(sm::Coordinator{C}, ::Holding, ::Release, _) where {C}
    return Hsm.transition!(sm, :Releasing)
end
@on_event function(sm::Coordinator{C}, ::Releasing, ::Released, _) where {C}
    return Hsm.transition!(sm, :Closing)
end
@on_event function(sm::Coordinator{C}, ::Closing, ::ClosedApplied, _) where {C}
    return Hsm.transition!(sm, :Closed)
end
@on_event function(sm::Coordinator{C}, ::Root, ::Failed, uncertain::Bool) where {C}
    return uncertain ? Hsm.transition!(sm, :Unverified) : Hsm.transition!(sm, :Fault)
end

# Entry/exit behaviors own deadlines only. Commands stay in admitted operations.
@on_entry function(sm::Coordinator{C}, ::Opening) where {C}
    sm.pending_since_ns = clock_ns(sm.clock)
    return nothing
end
@on_entry function(sm::Coordinator{C}, ::RestoringReference) where {C}
    sm.pending_since_ns = clock_ns(sm.clock)
    return nothing
end
@on_entry function(sm::Coordinator{C}, ::Verifying) where {C}
    sm.pending_since_ns = clock_ns(sm.clock)
    return nothing
end
@on_entry function(sm::Coordinator{C}, ::Releasing) where {C}
    sm.pending_since_ns = clock_ns(sm.clock)
    return nothing
end
@on_entry function(sm::Coordinator{C}, ::Closing) where {C}
    sm.pending_since_ns = clock_ns(sm.clock)
    return nothing
end
@on_exit function(sm::Coordinator{C}, ::Opening) where {C}
    sm.pending_since_ns = UInt64(0)
    return nothing
end
@on_exit function(sm::Coordinator{C}, ::RestoringReference) where {C}
    sm.pending_since_ns = UInt64(0)
    return nothing
end
@on_exit function(sm::Coordinator{C}, ::Verifying) where {C}
    sm.pending_since_ns = UInt64(0)
    return nothing
end
@on_exit function(sm::Coordinator{C}, ::Releasing) where {C}
    sm.pending_since_ns = UInt64(0)
    return nothing
end
@on_exit function(sm::Coordinator{C}, ::Closing) where {C}
    sm.pending_since_ns = UInt64(0)
    return nothing
end

clock_ns(clock) = clock_value(clock())
clock_value(_) = throw(ArgumentError("clock must return nanoseconds representable by UInt64"))
clock_value(::Bool) = throw(ArgumentError("clock must return nanoseconds representable by UInt64"))
function clock_value(now::Integer)
    0 <= now <= typemax(UInt64) ||
        throw(ArgumentError("clock must return nanoseconds representable by UInt64"))
    return UInt64(now)
end

function Coordinator(owner_instance::Int64; clock=time_ns, timeout_ms::Integer=5000)
    owner_instance > 0 || throw(ArgumentError("owner incarnation must be positive"))
    !(timeout_ms isa Bool) && 1 <= timeout_ms <= 60_000 ||
        throw(ArgumentError("timeout_ms must be between 1 and 60000"))
    clock_ns(clock)
    return Coordinator(owner_instance, clock, UInt64(timeout_ms) * UInt64(1_000_000),
        UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0),
        UInt64(0), UInt64(0), :none, nothing)
end

state(sm::Coordinator) = Hsm.current(sm)

"""Latch failure; uncertain effects become Unverified and are never replayed."""
function failed!(sm::Coordinator, reason::Symbol; uncertain::Bool=true)
    sm.failure === nothing || return nothing
    sm.failure = reason
    sm.reference_serial = 0
    Hsm.dispatch!(sm, :Failed, uncertain)
    return nothing
end

function check_timeout!(sm::Coordinator)
    sm.failure === nothing || return nothing
    now = try
        clock_ns(sm.clock)
    catch
        return failed!(sm, :clock_error)
    end
    if state(sm) in (:Opening, :RestoringReference, :Verifying, :Releasing, :Closing)
        now - sm.pending_since_ns >= sm.timeout_ns &&
            failed!(sm, :operation_timeout)
    end
    return nothing
end

function matches(sm::Coordinator, observation)
    check_timeout!(sm)
    return sm.failure === nothing && observation.owner_instance == sm.owner_instance &&
        observation.token == sm.token && observation.serial > sm.serial
end

"""Qualify only a new coordinator from exact current applied loop readback."""
function qualify!(sm::Coordinator, observation::LoopObservation)
    sm.failure === nothing && state(sm) === :Unverified || return nothing
    matches(sm, observation) || return nothing
    observation.requested_generation == observation.active_generation ||
        return failed!(sm, :initial_generation_mismatch)
    sm.serial = observation.serial
    sm.loop_generation = observation.active_generation
    Hsm.dispatch!(sm, :Qualified, observation.closed)
    return nothing
end

"""Admit one protective operation. `:saturation` is a reason, not a threshold policy."""
function request_protection!(sm::Coordinator, owner_instance::Int64, token::UInt64;
        reason::Symbol=:operator)
    check_timeout!(sm)
    sm.failure === nothing && owner_instance == sm.owner_instance &&
        state(sm) in (:Open, :Closed) && token > sm.token ||
        throw(ArgumentError("recovery requires a qualified owner and a new operation token"))
    sm.token = token
    sm.reason = reason
    sm.expected_loop_generation = 0
    sm.recovery_generation = 0
    sm.reference_serial = 0
    Hsm.dispatch!(sm, :Protect, nothing)
    # One atomic recovery stage inhibits closure, forces open and resets the
    # declared scientific scope. An ordinary open must never precede it.
    return StageRecovery(sm.owner_instance, token)
end

function bind_loop!(sm::Coordinator, effect, generation::UInt64, expected_state::Symbol)
    check_timeout!(sm)
    sm.failure === nothing && effect.owner_instance == sm.owner_instance &&
        effect.token == sm.token && state(sm) === expected_state || return nothing
    # A second staging acknowledgement cannot replace an accepted effect.
    sm.expected_loop_generation == generation && return nothing
    sm.expected_loop_generation == 0 || return failed!(sm, :conflicting_staging)
    generation > sm.loop_generation || return failed!(sm, :invalid_loop_generation)
    sm.expected_loop_generation = generation
    return nothing
end
staged!(sm::Coordinator, effect::CloseLoop, generation::UInt64) =
    bind_loop!(sm, effect, generation, :Closing)

"""Observe exact forced-open/close adoption without emitting another stage."""
function observe_loop!(sm::Coordinator, observation::LoopObservation)
    matches(sm, observation) || return nothing
    current = state(sm)
    if current in (:RestoringReference, :Verifying, :Holding, :Releasing)
        observation.active_generation < sm.loop_generation && return nothing
        expected = sm.expected_loop_generation
        allowed_generation = expected == 0 ? sm.loop_generation : expected
        !observation.closed && observation.requested_generation == allowed_generation &&
            sm.loop_generation <= observation.active_generation <= allowed_generation ||
            return failed!(sm, :unexpected_loop_change)
        sm.serial = observation.serial
        if observation.active_generation == allowed_generation
            sm.loop_generation = allowed_generation
            sm.expected_loop_generation = 0
        end
        return nothing
    end
    current in (:Opening, :Closing) || return nothing
    expected = sm.expected_loop_generation
    expected > 0 || return nothing
    observation.requested_generation < expected && return nothing
    observation.active_generation < sm.loop_generation && return nothing
    observation.requested_generation == expected && observation.active_generation <= expected ||
        return failed!(sm, :conflicting_loop_generation)
    observation.active_generation == expected || return nothing
    observation.closed == (current === :Closing) ||
        return failed!(sm, :conflicting_loop_value)
    sm.serial = observation.serial
    sm.loop_generation = expected
    sm.expected_loop_generation = 0
    if current === :Opening
        Hsm.dispatch!(sm, :Opened, nothing)
        return nothing
    end
    Hsm.dispatch!(sm, :ClosedApplied, nothing)
    return nothing
end

function recovery_staged!(sm::Coordinator, effect::StageRecovery, generation::UInt64;
        loop_generation::UInt64)
    check_timeout!(sm)
    sm.failure === nothing && effect.owner_instance == sm.owner_instance &&
        effect.token == sm.token && state(sm) === :Opening || return nothing
    sm.recovery_generation == generation && generation > 0 &&
        sm.expected_loop_generation == loop_generation && return nothing
    loop_generation > sm.loop_generation || return failed!(sm, :invalid_loop_generation)
    sm.recovery_generation == 0 && generation > 0 ||
        return failed!(sm, :invalid_recovery_generation)
    sm.recovery_generation = generation
    sm.expected_loop_generation = loop_generation
    return nothing
end

function observe_recovery!(sm::Coordinator, observation::RecoveryObservation)
    matches(sm, observation) || return nothing
    state(sm) === :RestoringReference || return nothing
    generation = sm.recovery_generation
    generation > 0 || return nothing
    observation.requested_generation < generation && return nothing
    observation.requested_generation == generation && observation.active_generation <= generation ||
        return failed!(sm, :conflicting_recovery_generation)
    observation.status === :failed && return failed!(sm, :recovery_failed; uncertain=false)
    observation.status === :unknown && return failed!(sm, :recovery_unknown)
    observation.active_generation == generation && observation.status === :applied || return nothing
    observation.closure_inhibited || return failed!(sm, :missing_closure_inhibition)
    sm.serial = observation.serial
    Hsm.dispatch!(sm, :Applied, nothing)
    return nothing
end

function observe_reference!(sm::Coordinator, observation::ReferenceObservation)
    matches(sm, observation) || return nothing
    state(sm) in (:Verifying, :Holding, :Releasing) || return nothing
    observation.generation == sm.recovery_generation || return nothing
    sm.serial = observation.serial
    if observation.reference_reached && observation.coherent && observation.ready
        sm.reference_serial = observation.serial
        sm.reference_since_ns = clock_ns(sm.clock)
        state(sm) === :Verifying && Hsm.dispatch!(sm, :Verified, nothing)
    else
        sm.reference_serial = 0
        state(sm) === :Releasing && return failed!(sm, :release_prerequisites_changed)
    end
    return nothing
end

"""Explicit close intent: release inhibition, then revalidate before issuing close.

Recovery completion leaves Holding. Stale evidence or early closure is refused
without effects. A successful request emits only ReleaseRecovery; the owner must
observe the matching release with fresh prerequisites before CloseLoop can occur.
"""
function request_close!(sm::Coordinator, owner_instance::Int64, token::UInt64)
    check_timeout!(sm)
    sm.failure === nothing && state(sm) === :Holding &&
        owner_instance == sm.owner_instance && token == sm.token &&
        sm.reference_serial > 0 &&
        clock_ns(sm.clock) - sm.reference_since_ns < sm.timeout_ns ||
        throw(ArgumentError("close requires fresh verified reference, coherence and readiness"))
    Hsm.dispatch!(sm, :Release, nothing)
    return ReleaseRecovery(sm.owner_instance, sm.token, sm.recovery_generation)
end

function observe_release!(sm::Coordinator, observation::ReleaseObservation)
    matches(sm, observation) || return nothing
    state(sm) === :Releasing || return nothing
    observation.generation == sm.recovery_generation || return nothing
    observation.released || return nothing
    sm.serial = observation.serial
    !observation.closed && observation.reference_reached && observation.coherent &&
        observation.ready || return failed!(sm, :release_prerequisites_changed)
    sm.reference_serial = observation.serial
    sm.reference_since_ns = clock_ns(sm.clock)
    sm.expected_loop_generation = 0
    Hsm.dispatch!(sm, :Released, nothing)
    return CloseLoop(sm.owner_instance, sm.token)
end

"""Cancel sequencing without undoing or replaying any effect already handed off.

Cancellation cannot claim a restored reference or revoke an applied command.
The outcome stays Unverified and existing graph inhibition remains authoritative.
"""
function cancel!(sm::Coordinator, owner_instance::Int64, token::UInt64)
    owner_instance == sm.owner_instance && token == sm.token &&
        state(sm) in (:Opening, :RestoringReference, :Verifying, :Holding,
            :Releasing, :Closing) && failed!(sm, :operation_cancelled)
    return nothing
end

"""Invalidate this incarnation; construct and qualify a new owner separately."""
function owner_replaced!(sm::Coordinator, owner_instance::Int64)
    owner_instance == sm.owner_instance || failed!(sm, :owner_replaced)
    return nothing
end

include("correction_recovery_client.jl")

end
