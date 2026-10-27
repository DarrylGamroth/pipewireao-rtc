"""Optional clipping observations and protective-operation recommendations.

This module owns no acquisition, timer, task, native write or scientific state.
The caller serializes observations and admits any recommended operation through
the existing RTC coordinator. Recommendations never request automatic closure.
"""
module CorrectionSupervision

public Configuration, Supervisor, Recommendation, observe!, rearm!, state, reason

fraction(_) = nothing
fraction(::Bool) = nothing
fraction(value::Real) = isfinite(value) && 0 <= value <= 1 ? Float64(value) : nothing
unsigned(_) = false
unsigned(::Bool) = false
unsigned(value::Integer) = 0 <= value <= typemax(UInt64)
owner(_) = false
owner(::Bool) = false
owner(value::Integer) = 0 < value <= typemax(Int64)
function duration(value::Integer, name)
    0 < value <= typemax(Int64) ||
        throw(ArgumentError("$name must be positive nanoseconds fitting Int64"))
    return UInt64(value)
end
duration(value, name) = throw(ArgumentError("$name must be positive nanoseconds fitting Int64"))
duration(::Bool, name) = throw(ArgumentError("$name must be positive nanoseconds fitting Int64"))

"""Explicit clipping thresholds and monotonic-time limits.

All numeric settings are required. Fractions must be finite in [0, 1], with
`clear_fraction < trip_fraction`; durations must be positive and fit Int64 ns.
An observation at/above `trip_fraction` starts persistence. Subsequent contiguous
fresh observations above `clear_fraction` retain it, including the hysteresis
band. An observation at/below `clear_fraction` clears pending persistence.

`max_gap_ns` bounds sample age, the gap between sample timestamps, and the gap
between observations. Persistence uses sample timestamps. The default enabled
policy returns only `:monitor_only`; explicitly configured `:hold` or
`:restore_reference` remain recommendations requiring coordinator admission.
"""
struct Configuration
    trip_fraction::Float64
    clear_fraction::Float64
    persistence_ns::UInt64
    max_gap_ns::UInt64
    enabled::Bool
    action::Symbol

    function Configuration(; trip_fraction, clear_fraction, persistence_ns,
            max_gap_ns, enabled::Bool=true, action::Symbol=:monitor_only)
        trip, clear = fraction(trip_fraction), fraction(clear_fraction)
        trip !== nothing && clear !== nothing && clear < trip ||
            throw(ArgumentError("clipping fractions must satisfy 0 ≤ clear < trip ≤ 1"))
        action in (:monitor_only, :hold, :restore_reference) ||
            throw(ArgumentError("action must be :monitor_only, :hold or :restore_reference"))
        return new(trip, clear, duration(persistence_ns, "persistence_ns"),
            duration(max_gap_ns, "max_gap_ns"), enabled, action)
    end
end

"""One observation result, containing intent only.

`action` is `:none` except on the first newly latched trip, when it contains the
configured action. `reason` describes this observation; `tripped` reports the
retained latch. Inspect `reason(supervisor)` for its latched cause. A result is
neither write acceptance nor evidence of recovery or physical settling.
"""
struct Recommendation
    action::Symbol
    reason::Symbol
    tripped::Bool
end

"""Clipping persistence and a one-shot trip latch for one exact owner incarnation.

Construct a new Supervisor for a replacement owner. For the same owner, explicit
`rearm!` requires a recent clear observation after coordinator reconciliation.
No observation clears the trip or changes the scientific loop's closure.
"""
mutable struct Supervisor
    const configuration::Configuration
    const owner_instance::Int64
    has_sample::Bool
    last_sequence::UInt64
    last_sample_ns::UInt64
    last_observed_ns::UInt64
    last_fraction::Union{Nothing,Float64}
    pending::Bool
    pending_since_ns::UInt64
    tripped::Bool
    trip_reason::Union{Nothing,Symbol}

    function Supervisor(configuration::Configuration, owner_instance)
        owner(owner_instance) || throw(ArgumentError("owner incarnation must be positive and fit Int64"))
        return new(configuration, Int64(owner_instance), false, 0, 0, 0, nothing,
            false, 0, false, nothing)
    end
end

"""Return `:Disabled`, `:Unknown`, `:Clear`, `:Pending` or retained `:Tripped`."""
state(supervisor::Supervisor) = !supervisor.configuration.enabled ? :Disabled :
    supervisor.tripped ? :Tripped : supervisor.last_fraction === nothing ? :Unknown :
    supervisor.pending ? :Pending : :Clear

"""Return the latched trip cause, or `nothing` before a trip/after explicit rearm."""
reason(supervisor::Supervisor) = supervisor.trip_reason

function reject!(supervisor::Supervisor, cause::Symbol)
    supervisor.pending = false
    supervisor.pending_since_ns = 0
    supervisor.last_fraction = nothing
    return Recommendation(:none, cause, supervisor.tripped)
end

"""Observe clipping feedback for an exact owner, sequence and monotonic timestamp.

Pass `nothing` for missing feedback. Malformed, wrong-owner, repeated, stale and
future samples invalidate pending continuity and rearm eligibility; they never
count as zero clipping or clear a trip. Valid sample sequence and time must
increase, and sequence must advance by exactly one to retain persistence.
`now_ns` is the caller's monotonic observation time and must not regress.

Fresh same-owner headers with missing/malformed feedback advance the last seen
sequence and time, so replay cannot repair that observation. Wrong-owner or
invalid headers preserve the last trusted sequence/time. A gap starts a new
persistence interval using the current valid sample. While tripped, valid
observations only update evidence for explicit rearm and return `:none`.
"""
function observe!(supervisor::Supervisor, owner_instance, sequence, sample_ns,
        clipping_fraction; now_ns)
    configuration = supervisor.configuration
    configuration.enabled || return Recommendation(:none, :disabled, false)
    owner(owner_instance) && owner_instance == supervisor.owner_instance ||
        return reject!(supervisor, :wrong_owner)
    unsigned(sequence) && unsigned(sample_ns) && unsigned(now_ns) ||
        return reject!(supervisor, :malformed_sample)
    sequence, sample_ns, now_ns = UInt64(sequence), UInt64(sample_ns), UInt64(now_ns)
    sample_ns <= now_ns || return reject!(supervisor, :future_sample)
    if supervisor.has_sample && (sequence <= supervisor.last_sequence ||
            sample_ns <= supervisor.last_sample_ns || now_ns < supervisor.last_observed_ns)
        return reject!(supervisor, :stale_sample)
    end
    now_ns - sample_ns <= configuration.max_gap_ns ||
        return reject!(supervisor, :stale_sample)
    contiguous = !supervisor.has_sample ||
        (sequence - supervisor.last_sequence == 1 &&
         sample_ns - supervisor.last_sample_ns <= configuration.max_gap_ns &&
         now_ns - supervisor.last_observed_ns <= configuration.max_gap_ns)
    supervisor.has_sample = true
    supervisor.last_sequence = sequence
    supervisor.last_sample_ns = sample_ns
    supervisor.last_observed_ns = now_ns
    supervisor.last_fraction = fraction(clipping_fraction)
    supervisor.last_fraction === nothing && return reject!(supervisor,
        clipping_fraction === nothing ? :missing_feedback : :malformed_feedback)
    if !contiguous
        supervisor.pending = false
        supervisor.pending_since_ns = 0
    end
    supervisor.tripped && return Recommendation(:none, :already_tripped, true)
    if supervisor.last_fraction <= configuration.clear_fraction
        supervisor.pending = false
        supervisor.pending_since_ns = 0
    elseif !supervisor.pending && supervisor.last_fraction >= configuration.trip_fraction
        supervisor.pending = true
        supervisor.pending_since_ns = sample_ns
    end
    if supervisor.pending && sample_ns - supervisor.pending_since_ns >= configuration.persistence_ns
        supervisor.tripped = true
        supervisor.trip_reason = :persistent_clipping
        return Recommendation(configuration.action, supervisor.trip_reason, true)
    end
    return Recommendation(:none, supervisor.pending ? :pending : :clear, false)
end

"""Explicitly rearm a tripped supervisor after higher-level recovery.

Return `true` only for the exact owner and latest observed sequence with valid
feedback at/below the clear threshold that remains fresh at `now_ns`. Retain
last sequence/time so a replay cannot retrip or start a persistence interval.
This clears only supervision's latch; it neither closes the scientific loop nor
establishes that coordinator recovery or device settling actually completed.
"""
function rearm!(supervisor::Supervisor, owner_instance, sequence; now_ns)
    supervisor.tripped && owner(owner_instance) &&
        owner_instance == supervisor.owner_instance && unsigned(sequence) &&
        sequence == supervisor.last_sequence && unsigned(now_ns) || return false
    now_ns = UInt64(now_ns)
    now_ns >= supervisor.last_observed_ns &&
        now_ns - supervisor.last_sample_ns <= supervisor.configuration.max_gap_ns &&
        supervisor.last_fraction !== nothing &&
        supervisor.last_fraction <= supervisor.configuration.clear_fraction || return false
    supervisor.tripped = false
    supervisor.trip_reason = nothing
    supervisor.pending = false
    supervisor.pending_since_ns = 0
    return true
end

include("correction_supervision_observer.jl")

end
