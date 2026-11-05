"""RTC observations of explicit correction-loop Boolean properties.

These machines observe accepted native writes and authoritative applied
readback. They neither stage writes nor execute scientific frame processing.
"""
module CorrectionLoops

using Hsm: @hsmdef, @statedef, @on_initial, @on_event, @on_entry, @on_exit
import Hsm
import PipeWireAO
import ..Common

public Loop, Observer, state, requested!, observed!, unknown!, check_ready, property_info,
    attach_timers!

const STATUS_PREFIX = "pipewireao.correction-control."

"""One qualified Boolean property bound to one owner incarnation.

Constructed in `Unknown`, the loop first needs applied readback with equal
requested/active generations. Failures remain `Unknown` for this incarnation;
replacement owners require new machines.
"""
@hsmdef mutable struct Loop{C}
    const property::String
    const instance::Int64
    requested_generation::Int64
    active_generation::Int64
    requested_closed::Bool
    applied_closed::Bool
    pending_since_ns::UInt64
    const clock::C
    const timeout_ns::UInt64
    # Cold loop sources are attached after the graph's native filter exists.
    # No timer or Hsm operation runs on the scientific processing path.
    timer::Union{Nothing,PipeWireAO.TimerSource}
    initialized::Bool
    failure::Union{Nothing,Symbol}
end

@statedef Loop :Unknown
@statedef Loop :Operational
@statedef Loop :Open :Operational
@statedef Loop :Closed :Operational
@statedef Loop :Pending :Operational
@statedef Loop :Closing :Pending
@statedef Loop :Opening :Pending

@on_initial function(sm::Loop{C}, ::Root) where {C}
    return Hsm.transition!(sm, :Unknown)
end

@on_event function(sm::Loop{C}, ::Unknown, ::Observed, observation) where {C}
    matching_owner(sm, observation) || return Hsm.EventHandled
    if !valid_generations(observation)
        latch_unknown!(sm, :invalid_observation_generation)
        return Hsm.transition!(sm, :Unknown)
    end
    if observation.requested_generation != observation.active_generation
        latch_unknown!(sm, :uninitialized_pending)
        return Hsm.transition!(sm, :Unknown)
    end
    sm.requested_generation = observation.requested_generation
    sm.active_generation = observation.active_generation
    sm.requested_closed = observation.closed
    sm.applied_closed = observation.closed
    sm.initialized = true
    if observation.closed
        return Hsm.transition!(sm, :Closed)
    else
        return Hsm.transition!(sm, :Open)
    end
end

@on_event function(sm::Loop{C}, ::Unknown, ::Requested, request) where {C}
    matching_owner(sm, request) || return Hsm.EventHandled
    latch_unknown!(sm, :uninitialized_request)
    return Hsm.transition!(sm, :Unknown)
end

@on_event function(sm::Loop{C}, ::Operational, ::Requested, request) where {C}
    matching_owner(sm, request) || return Hsm.EventHandled
    request.requested_generation < sm.requested_generation && return Hsm.EventHandled
    request.active_generation < sm.active_generation && return Hsm.EventHandled
    if request.requested_generation == sm.requested_generation
        request.closed == sm.requested_closed && request.active_generation == sm.active_generation &&
            return Hsm.EventHandled
        latch_unknown!(sm, :conflicting_request)
        return Hsm.transition!(sm, :Unknown)
    end
    if sm.requested_generation != sm.active_generation ||
            request.active_generation != sm.active_generation ||
            request.requested_generation <= request.active_generation
        latch_unknown!(sm, :invalid_request_generation)
        return Hsm.transition!(sm, :Unknown)
    end
    sm.requested_generation = request.requested_generation
    sm.requested_closed = request.closed
    request.closed == sm.applied_closed && return Hsm.EventHandled
    if request.closed
        return Hsm.transition!(sm, :Closing)
    else
        return Hsm.transition!(sm, :Opening)
    end
end

@on_event function(sm::Loop{C}, ::Operational, ::Observed, observation) where {C}
    matching_owner(sm, observation) || return Hsm.EventHandled
    reason = record_applied!(sm, observation)
    reason === nothing && return Hsm.EventHandled
    latch_unknown!(sm, reason)
    return Hsm.transition!(sm, :Unknown)
end

@on_event function(sm::Loop{C}, ::Pending, ::Observed, observation) where {C}
    matching_owner(sm, observation) || return Hsm.EventHandled
    reason = record_applied!(sm, observation)
    if reason !== nothing
        latch_unknown!(sm, reason)
        return Hsm.transition!(sm, :Unknown)
    end
    sm.active_generation == sm.requested_generation || return Hsm.EventHandled
    return sm.applied_closed ? Hsm.transition!(sm, :Closed) : Hsm.transition!(sm, :Open)
end

@on_event function(sm::Loop{C}, ::Pending, ::DeadlineChecked, timing) where {C}
    sm.failure === nothing || return Hsm.EventHandled
    elapsed = timing.now - sm.pending_since_ns
    if elapsed >= timing.timeout_ns
        latch_unknown!(sm, :adoption_timeout)
        return Hsm.transition!(sm, :Unknown)
    end
    arm_timer!(sm.timer, timing.timeout_ns - elapsed)
    return Hsm.EventHandled
end

@on_event function(sm::Loop{C}, ::Root, ::Unknown, reason::Symbol) where {C}
    latch_unknown!(sm, reason) || return Hsm.EventHandled
    return Hsm.transition!(sm, :Unknown)
end

matching_owner(sm::Loop, observation) =
    sm.failure === nothing && observation.instance == sm.instance
valid_generations(observation) = observation.requested_generation >= 0 &&
    0 <= observation.active_generation <= observation.requested_generation

# Handler helpers update facts without dispatching or selecting a transition.
function latch_unknown!(sm::Loop, reason::Symbol)
    sm.failure === nothing || return false
    sm.failure = reason
    return true
end

function record_applied!(sm::Loop, observation)
    valid_generations(observation) || return :invalid_observation_generation
    observation.requested_generation < sm.requested_generation && return nothing
    observation.active_generation < sm.active_generation && return nothing
    observation.requested_generation == sm.requested_generation || return :unexpected_generation
    if observation.active_generation < observation.requested_generation
        observation.active_generation == sm.active_generation &&
            observation.closed == sm.applied_closed || return :contradictory_pending
        return nothing
    end
    observation.closed == sm.requested_closed || return :contradictory_applied
    sm.active_generation = observation.active_generation
    sm.applied_closed = observation.closed
    return nothing
end

function start_timer!(sm::Loop)
    sm.pending_since_ns = clock_ns(sm.clock)
    arm_timer!(sm.timer, sm.timeout_ns)
    return nothing
end

function stop_timer!(sm::Loop)
    disarm_timer!(sm.timer)
    sm.pending_since_ns = UInt64(0)
    return nothing
end

arm_timer!(::Nothing, ::UInt64) = nothing
arm_timer!(timer::PipeWireAO.TimerSource, remaining_ns::UInt64) =
    PipeWireAO.update_timer!(timer; delay=max(1, remaining_ns) / 1e9)
disarm_timer!(::Nothing) = nothing
disarm_timer!(timer::PipeWireAO.TimerSource) = PipeWireAO.update_timer!(timer; delay=nothing)

@on_entry function(sm::Loop{C}, ::Pending) where {C}
    start_timer!(sm)
    return nothing
end

@on_exit function(sm::Loop{C}, ::Pending) where {C}
    stop_timer!(sm)
    return nothing
end

function Loop(property::String, instance::Int64; clock=Common.MONOTONIC_CLOCK, timeout_ms::Integer=5000)
    names = split(property, ':')
    length(names) == 2 && all(!isempty, names) ||
        throw(ArgumentError("correction-loop property must be qualified as node:property"))
    instance > 0 || throw(ArgumentError("owner instance must be positive"))
    clock_ns(clock)
    return Loop(property, instance, 0, 0, false, false, UInt64(0), clock,
        timeout_ns(timeout_ms), nothing, false, nothing)
end

"""Return `Unknown`, `Open`, `Closing`, `Closed`, or `Opening` as a Symbol."""
state(sm::Loop) = sm.failure === nothing ? Hsm.current(sm) : :Unknown

"""Latch an unknown outcome through the `Unknown` event without issuing a write.

The event retains the first failure reason. If Hsm itself throws before it can
handle the event, retain a publication failure without escaping the observer.
"""
function unknown!(sm::Loop, reason::Symbol=:unknown)
    # Even an internal Hsm exception must not escape an accepted-write observer.
    try
        Hsm.dispatch!(sm, :Unknown, reason)
    catch
        # Dispatch itself can fail before the handler runs. Keep publication
        # fail-closed even when the Hsm cannot complete its own transition.
        latch_unknown!(sm, reason)
    end
    return nothing
end

"""Observe an accepted Boolean write; acceptance is not applied adoption.

The native owner enforces its busy slot before acceptance. Duplicate callbacks
are harmless; a conflicting accepted write while pending is an unknown outcome,
not a second admission decision. Same-value writes retain `Open`/`Closed`.
"""
function requested!(sm::Loop, instance::Int64, requested_generation::Int64,
        active_generation::Int64, closed::Bool)
    Hsm.dispatch!(sm, :Requested, (; instance, requested_generation, active_generation, closed))
    return nothing
end

"""Observe one coherent applied snapshot for this owner incarnation.

Only exact requested/active generation equality and the accepted Boolean value
confirm a pending change. Stale snapshots and other owner incarnations cannot
confirm it. Future, malformed or contradictory snapshots latch `Unknown`.
"""
function observed!(sm::Loop, instance::Int64, requested_generation::Int64,
        active_generation::Int64, closed::Bool)
    Hsm.dispatch!(sm, :Observed, (; instance, requested_generation, active_generation, closed))
    return nothing
end

"""Callable native property observer for explicitly selected qualified Booleans.

The owner invokes `observer(Val(:observed), props)` for applied readback and
`observer(Val(:requested), props)` after successful staging. Every callback is
serialized by that owner; this observer is never shared across incarnations.
`timeout_ms` is 1 to 60000 (default 5000). `clock` accepts a Clocks nanosecond
clock or a callable returning integer nanoseconds representable by UInt64.
Adoption deadlines are checked before
every callback or available status readback. Attached native timers request
owner-thread publication at the deadline; no background Hsm writer is created.
"""
struct Observer{C}
    loops::Vector{Loop{C}}
    instance::Int64
    timeout_ns::UInt64
    clock::C
end

clock_ns(clock) = clock_value(Common.monotonic_ns(clock))

function clock_value(now::Integer)
    0 <= now <= typemax(UInt64) ||
        throw(ArgumentError("correction-loop clock must return an integer UInt64 nanosecond count"))
    return UInt64(now)
end

clock_value(::Bool) =
    throw(ArgumentError("correction-loop clock must return an integer UInt64 nanosecond count"))
clock_value(_) =
    throw(ArgumentError("correction-loop clock must return an integer UInt64 nanosecond count"))

function timeout_ns(timeout_ms::Integer)
    1 <= timeout_ms <= 60_000 ||
        throw(ArgumentError("correction-loop adoption timeout must be 1 to 60000 milliseconds"))
    return UInt64(timeout_ms) * UInt64(1_000_000)
end

timeout_ns(::Bool) =
    throw(ArgumentError("correction-loop adoption timeout must be 1 to 60000 milliseconds"))

function Observer(properties::Vector{String}, instance::Int64;
        timeout_ms::Integer=5000, clock=Common.MONOTONIC_CLOCK)
    allunique(properties) || throw(ArgumentError("duplicate correction-loop property"))
    instance > 0 || throw(ArgumentError("owner instance must be positive"))
    timeout = timeout_ns(timeout_ms)
    clock_ns(clock)
    return Observer([Loop(property, instance; clock, timeout_ms) for property in properties], instance,
        timeout, clock)
end

"""Attach disarmed PipeWire timers to an initialized graph owner.

Entry to Opening/Closing arms a one-shot timer; exit cancels it. `wake()` runs
on the supplied native ThreadLoop and must only request control-loop work, not
dispatch Hsm events or throw. The graph owner uses `notify_properties!` to publish on its
own control thread, where expiration is reconciled before applied readback.
Close the observer before destroying that graph or the supplied loop.
"""
function attach_timers!(observer::Observer, loop::PipeWireAO.ThreadLoop, wake)
    check_ready(observer)
    all(sm -> sm.timer === nothing, observer.loops) ||
        throw(ArgumentError("correction-loop timers are already attached"))
    try
        for sm in observer.loops
            sm.timer = PipeWireAO.TimerSource(loop, (_, _) -> wake())
        end
    catch
        close(observer)
        rethrow()
    end
    return observer
end

"""Cancel native timers and mark observation unavailable before owner teardown.

Call on the serialized control thread, before closing the graph filter or timer
loop. Repeated closure is harmless; late observations cannot clear the fault.
"""
function Base.close(observer::Observer)
    failures = Exception[]
    for sm in observer.loops
        unknown!(sm, :observer_unavailable)
        timer = sm.timer
        timer === nothing && continue
        try
            close(timer)
            sm.timer = nothing
        catch error
            push!(failures, error)
        end
    end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

"""Require initial authoritative Boolean readback before owner admission."""
function check_ready(observer::Observer)
    for sm in observer.loops
        sm.initialized && sm.failure === nothing && state(sm) in (:Open, :Closed) &&
            sm.requested_generation == sm.active_generation ||
            throw(ArgumentError("correction-loop property $(sm.property) has no valid initial readback (failure=$(sm.failure))"))
    end
    return nothing
end

function prop_value(::Type{T}, props::PipeWireAO.SPA.Props, name::String) where {T}
    found = false
    value = zero(T)
    for (key, pod) in props.values
        key == name || continue
        found && throw(ArgumentError("duplicate observed property: $name"))
        value = PipeWireAO.pod_value(T, pod)
        found = true
    end
    found || throw(ArgumentError("missing observed property: $name"))
    return value
end

function observe!(::Val{:requested}, sm::Loop, requested::Int64, active::Int64,
        closed::Bool)
    requested!(sm, sm.instance, requested, active, closed)
    return nothing
end

observe!(::Val{:observed}, sm::Loop, requested::Int64, active::Int64, closed::Bool) =
    observed!(sm, sm.instance, requested, active, closed)

function expire!(sm::Loop, now::UInt64, timeout_ns::UInt64)
    Hsm.dispatch!(sm, :DeadlineChecked, (; now, timeout_ns))
    return nothing
end

function (observer::Observer)(phase::Union{Val{:requested},Val{:observed}},
        props::PipeWireAO.SPA.Props)
    now = try
        clock_ns(observer.clock)
    catch
        foreach(sm -> unknown!(sm, :observer_error), observer.loops)
        return nothing
    end
    for sm in observer.loops
        sm.failure === nothing || continue
        try
            # Expiration precedes adoption: a late matching snapshot cannot
            # retroactively establish that adoption met its deadline.
            expire!(sm, now, observer.timeout_ns)
            sm.failure === nothing || continue
            node = first(split(sm.property, ':'))
            requested = prop_value(Int64, props, node * ":requested-generation")
            active = prop_value(Int64, props, node * ":active-generation")
            closed = prop_value(Bool, props, sm.property)
            observe!(phase, sm, requested, active, closed)
        catch
            unknown!(sm, :observer_error)
        end
    end
    return nothing
end

function fault(sm::Loop)
    sm.failure === nothing && return ""
    sm.failure === :adoption_timeout && return "Applied correction did not confirm before the adoption timeout"
    sm.failure === :observer_unavailable && return "Authoritative property observation is unavailable"
    sm.failure === :observer_error && return "Authoritative property observation failed or was malformed"
    sm.failure === :uninitialized_request && return "Accepted request preceded initial applied readback"
    sm.failure === :uninitialized_pending && return "Initial readback contained an unconfirmed request"
    sm.failure === :conflicting_request && return "Accepted requests disagree at the same generation"
    sm.failure === :invalid_request_generation && return "Accepted request generations are inconsistent"
    sm.failure === :invalid_observation_generation && return "Applied readback generations are invalid"
    sm.failure === :unexpected_generation && return "Applied readback contains an unexpected generation"
    sm.failure === :contradictory_pending && return "Pending readback contradicts the last applied correction"
    sm.failure === :contradictory_applied && return "Applied correction contradicts the accepted request"
    return "Correction outcome is unknown"
end

"""Describe the read-only correction-control status properties.

The actual Boolean target and its existing requested/active node generations
remain the authoritative graph properties; these descriptions add status only.
"""
function property_info(observer::Observer)
    readonly = PipeWireAO.SPA.PROPERTY_READONLY
    infos = PipeWireAO.SPA.PropInfo[
        PipeWireAO.SPA.PropInfo(STATUS_PREFIX * "version", PipeWireAO.Pod(Int32(1));
            flags=readonly, group="Correction control", display_name="Control version", params=true),
        PipeWireAO.SPA.PropInfo(STATUS_PREFIX * "owner-instance", PipeWireAO.Pod(observer.instance);
            flags=readonly, group="Correction control", display_name="Owner instance", params=true),
    ]
    for sm in observer.loops
        prefix = STATUS_PREFIX * sm.property * "."
        group = "Correction control/" * sm.property
        push!(infos,
            PipeWireAO.SPA.PropInfo(prefix * "state", PipeWireAO.Pod("Unknown");
                flags=readonly, group, display_name="State", params=true),
            PipeWireAO.SPA.PropInfo(prefix * "fault", PipeWireAO.Pod("");
                flags=readonly, group, display_name="Fault", params=true),
            PipeWireAO.SPA.PropInfo(prefix * "requested", PipeWireAO.Pod(sm.requested_closed);
                flags=readonly, group, display_name="Requested closed", params=true))
    end
    return infos
end

"""Return status extras reconciled against exactly `graphprops`.

The clock returns unsigned nanoseconds, with wrap-safe elapsed arithmetic.
Only `Opening`/`Closing` adoption expires after `timeout_ms` (default 5000).
Unavailable observation and expired adoption latch `Unknown`; this getter never
writes scientific properties or retries and never returns cached known state
when authoritative observation is unavailable.
"""
function (observer::Observer)(graphprops::PipeWireAO.SPA.Props, available::Bool)
    if available
        observer(Val(:observed), graphprops)
    else
        foreach(sm -> unknown!(sm, :observer_unavailable), observer.loops)
    end
    extras = Pair{String,PipeWireAO.Pod}[
        STATUS_PREFIX * "version" => PipeWireAO.Pod(Int32(1)),
        STATUS_PREFIX * "owner-instance" => PipeWireAO.Pod(observer.instance),
    ]
    for sm in observer.loops
        prefix = STATUS_PREFIX * sm.property * "."
        push!(extras,
            prefix * "state" => PipeWireAO.Pod(string(state(sm))),
            prefix * "fault" => PipeWireAO.Pod(fault(sm)),
            prefix * "requested" => PipeWireAO.Pod(sm.requested_closed))
    end
    return PipeWireAO.SPA.Props(extras)
end

end
