"""RTC observations of explicit correction-loop Boolean properties.

These machines observe accepted native writes and authoritative applied
readback. They neither stage writes nor execute scientific frame processing.
"""
module CorrectionLoops

using Hsm: @hsmdef, @statedef, @on_initial, @on_event
import Hsm
import PipeWireAO

public Loop, Observer, state, requested!, observed!, unknown!, check_ready

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
    return Loop(property, instance, 0, 0, false, false, false, nothing)
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
"""
struct Observer
    loops::Vector{Loop}
end

function Observer(properties::Vector{String}, instance::Int64)
    allunique(properties) || throw(ArgumentError("duplicate correction-loop property"))
    return Observer([Loop(property, instance) for property in properties])
end

"""Require initial authoritative Boolean readback before owner admission."""
function check_ready(observer::Observer)
    for sm in observer.loops
        sm.initialized && sm.failure === nothing ||
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

observe!(::Val{:requested}, sm::Loop, requested::Int64, active::Int64, closed::Bool) =
    requested!(sm, sm.instance, requested, active, closed)
observe!(::Val{:observed}, sm::Loop, requested::Int64, active::Int64, closed::Bool) =
    observed!(sm, sm.instance, requested, active, closed)

function (observer::Observer)(phase::Union{Val{:requested},Val{:observed}},
        props::PipeWireAO.SPA.Props)
    for sm in observer.loops
        sm.failure === nothing || continue
        try
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

end
