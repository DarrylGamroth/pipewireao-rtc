"""RTC observations of explicit correction-loop Boolean properties.

These machines observe accepted native writes and authoritative applied
readback. They neither stage writes nor execute scientific frame processing.
"""
module CorrectionLoops

using Hsm: @hsmdef, @statedef, @on_initial, @on_event
import Hsm
import PipeWireAO

public Loop, Observer, state, requested!, observed!, unknown!, check_ready, property_info

const STATUS_PREFIX = "pipewireao.correction-control."

"""One qualified Boolean property bound to one owner incarnation.

Constructed in `Unknown`, the loop first needs applied readback with equal
requested/active generations. Failures remain `Unknown` for this incarnation;
replacement owners require new machines.
"""
@hsmdef mutable struct Loop
    const property::String
    const instance::Int64
    requested_generation::Int64
    active_generation::Int64
    requested_closed::Bool
    applied_closed::Bool
    pending_since_ns::UInt64
    initialized::Bool
    failure::Union{Nothing,Symbol}
end

@statedef Loop :Unknown
@statedef Loop :Open
@statedef Loop :Closing
@statedef Loop :Closed
@statedef Loop :Opening

@on_initial function(sm::Loop, ::Root)
    return Hsm.transition!(sm, :Unknown)
end

@on_event function(sm::Loop, ::Root, ::Applied, closed::Bool)
    if closed
        return Hsm.transition!(sm, :Closed)
    else
        return Hsm.transition!(sm, :Open)
    end
end

@on_event function(sm::Loop, ::Root, ::Requested, closed::Bool)
    if closed
        return Hsm.transition!(sm, :Closing)
    else
        return Hsm.transition!(sm, :Opening)
    end
end

@on_event function(sm::Loop, ::Root, ::Failure, _)
    return Hsm.transition!(sm, :Unknown)
end

function Loop(property::String, instance::Int64)
    names = split(property, ':')
    length(names) == 2 && all(!isempty, names) ||
        throw(ArgumentError("correction-loop property must be qualified as node:property"))
    instance > 0 || throw(ArgumentError("owner instance must be positive"))
    return Loop(property, instance, 0, 0, false, false, UInt64(0), false, nothing)
end

"""Return `Unknown`, `Open`, `Closing`, `Closed`, or `Opening` as a Symbol."""
state(sm::Loop) = sm.failure === nothing ? Hsm.current(sm) : :Unknown

"""Latch an unknown outcome without issuing or retrying a native write."""
function unknown!(sm::Loop, reason::Symbol=:unknown)
    sm.failure === nothing || return nothing
    sm.failure = reason
    # Even an internal Hsm exception must not escape an accepted-write observer.
    try
        Hsm.dispatch!(sm, :Failure, nothing)
    catch
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
    instance == sm.instance && sm.failure === nothing || return nothing
    sm.initialized || return unknown!(sm, :uninitialized_request)
    requested_generation < sm.requested_generation && return nothing
    active_generation < sm.active_generation && return nothing
    if requested_generation == sm.requested_generation
        closed == sm.requested_closed && active_generation == sm.active_generation &&
            return nothing
        return unknown!(sm, :conflicting_request)
    end
    if sm.requested_generation != sm.active_generation ||
       active_generation != sm.active_generation ||
       requested_generation <= active_generation
        return unknown!(sm, :invalid_request_generation)
    end
    sm.requested_generation = requested_generation
    sm.requested_closed = closed
    closed == sm.applied_closed || Hsm.dispatch!(sm, :Requested, closed)
    return nothing
end

"""Observe one coherent applied snapshot for this owner incarnation.

Only exact requested/active generation equality and the accepted Boolean value
confirm a pending change. Stale snapshots and other owner incarnations cannot
confirm it. Future, malformed or contradictory snapshots latch `Unknown`.
"""
function observed!(sm::Loop, instance::Int64, requested_generation::Int64,
        active_generation::Int64, closed::Bool)
    instance == sm.instance && sm.failure === nothing || return nothing
    if requested_generation < 0 || active_generation < 0 ||
       active_generation > requested_generation
        return unknown!(sm, :invalid_observation_generation)
    end
    if !sm.initialized
        requested_generation == active_generation ||
            return unknown!(sm, :uninitialized_pending)
        sm.requested_generation = requested_generation
        sm.active_generation = active_generation
        sm.requested_closed = closed
        sm.applied_closed = closed
        sm.initialized = true
        Hsm.dispatch!(sm, :Applied, closed)
        return nothing
    end
    requested_generation < sm.requested_generation && return nothing
    active_generation < sm.active_generation && return nothing
    requested_generation == sm.requested_generation ||
        return unknown!(sm, :unexpected_generation)
    if active_generation < requested_generation
        active_generation == sm.active_generation && closed == sm.applied_closed ||
            return unknown!(sm, :contradictory_pending)
        return nothing
    end
    closed == sm.requested_closed || return unknown!(sm, :contradictory_applied)
    sm.active_generation = active_generation
    sm.applied_closed = closed
    state(sm) === (closed ? :Closed : :Open) || Hsm.dispatch!(sm, :Applied, closed)
    return nothing
end

"""Callable native property observer for explicitly selected qualified Booleans.

The owner invokes `observer(Val(:observed), props)` for applied readback and
`observer(Val(:requested), props)` after successful staging. Every callback is
serialized by that owner; this observer is never shared across incarnations.
`timeout_ms` is 1 to 60000 (default 5000). `clock` must return monotonic integer
nanoseconds representable by UInt64. Adoption deadlines are checked before
every callback or available status readback; no background writer is created.
"""
struct Observer{C}
    loops::Vector{Loop}
    instance::Int64
    timeout_ns::UInt64
    clock::C
end

clock_ns(clock) = clock_value(clock())

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
        timeout_ms::Integer=5000, clock=time_ns)
    allunique(properties) || throw(ArgumentError("duplicate correction-loop property"))
    instance > 0 || throw(ArgumentError("owner instance must be positive"))
    timeout = timeout_ns(timeout_ms)
    clock_ns(clock)
    return Observer([Loop(property, instance) for property in properties], instance,
        timeout, clock)
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
        closed::Bool, now::UInt64)
    previous_generation = sm.requested_generation
    requested!(sm, sm.instance, requested, active, closed)
    if sm.failure === nothing && sm.requested_generation != previous_generation &&
       state(sm) in (:Opening, :Closing)
        sm.pending_since_ns = now
    end
    return nothing
end

observe!(::Val{:observed}, sm::Loop, requested::Int64, active::Int64, closed::Bool,
        ::UInt64) =
    observed!(sm, sm.instance, requested, active, closed)

function expire!(sm::Loop, now::UInt64, timeout_ns::UInt64)
    if state(sm) in (:Opening, :Closing) && now - sm.pending_since_ns >= timeout_ns
        unknown!(sm, :adoption_timeout)
    end
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
            observe!(phase, sm, requested, active, closed, now)
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
