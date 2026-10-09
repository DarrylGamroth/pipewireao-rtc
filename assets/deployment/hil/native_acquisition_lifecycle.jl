"""Cold lifecycle bridge; acquisition effects remain with the existing owner."""
module HILNativeAcquisitionLifecycle

using PipeWireAO

# HIL and deployment have distinct environments, but execute the same
# source-authoritative wire and endpoint implementation.
# Sealed SDK owners live in hil/ beside julia/; package resources live
# in assets/deployment/hil/ inside the same named Julia package.
const SOURCE = let sdk = normpath(joinpath(@__DIR__, "..", "julia", "src"))
    isdir(sdk) ? sdk : normpath(joinpath(@__DIR__, "..", "..", "..", "src"))
end
include(joinpath(SOURCE, "native_control_codec.jl"))
include(joinpath(SOURCE, "native_control_client.jl"))
include(joinpath(SOURCE, "native_control_endpoint.jl"))
include(joinpath(SOURCE, "native_acquisition_lifecycle_codec.jl"))
include(joinpath(SOURCE, "native_calibration_action_codec.jl"))
include(joinpath(SOURCE, "native_acquisition_lifecycle_runtime.jl"))

const Codec = NativeAcquisitionLifecycleCodec
const Runtime = NativeAcquisitionLifecycleRuntime
const Endpoint = NativeControlEndpoint
const Profile = Codec.Profile

export Bridge, has_pending, take!, lifecycle!, complete!, snapshot,
    report_published!, dispatch!, flush_terminal!, TransportFailure

struct TransportFailure <: Exception
    cause::Exception
end
Base.showerror(io::IO, error::TransportFailure) =
    print(io, "native lifecycle transport failed: ", sprint(showerror, error.cause))

mutable struct Bridge{P<:Profile,R}
    profile::P
    runtime::R
    instrument::Codec.Instrument
    report_cursor::Union{Nothing,Codec.AcquisitionCursor}
    deferred::Bool
    action_endpoint::Union{Nothing,Endpoint.Endpoint}
end
Bridge(profile, runtime, instrument, report_cursor, deferred) =
    Bridge(profile, runtime, instrument, report_cursor, deferred, nothing)

function Bridge(options, profile::P) where {P<:Profile}
    instrument = options.profile === :classic ? Codec.Classic :
        options.profile === :copper ? Codec.Copper :
        throw(ArgumentError("unknown acquisition instrument"))
    runtime = Runtime.Runtime(profile, options.remote, options.control_node,
        options.control_instance)
    return Bridge(profile, runtime, instrument, nothing, false)
end

@inline has_pending(bridge::Bridge; safe::Bool=true) =
    (safe && bridge.deferred) || Runtime.has_pending(bridge.runtime)
_defer(::Codec.LifecycleCommand) = false
_defer(::Codec.LifecycleCommand{:reset}) = true
_defer(::Codec.LifecycleCommand{:connect}) = true
_defer(::Codec.LifecycleCommand{:shutdown}) = true

"""Take a safe operation; defer mutations that require an action boundary."""
function take!(bridge::Bridge; safe::Bool)
    if bridge.deferred && !safe && !Runtime.has_pending(bridge.runtime)
        return nothing
    end
    has_pending(bridge; safe) || return nothing
    try Runtime.poll!(bridge.runtime) catch error; throw(TransportFailure(error)) end
    pending = try
        with_thread_loop_lock(bridge.runtime.loop) do _
            bridge.runtime.endpoint.pending
        end
    catch error
        throw(TransportFailure(error))
    end
    if pending !== nothing && !safe && _defer(pending.command)
        bridge.deferred = true
        return nothing
    end
    bridge.deferred = false
    try
        return Runtime.take!(bridge.runtime)
    catch error
        throw(TransportFailure(error))
    end
end

function lifecycle!(bridge::Bridge, state::Codec.ColdLifecycle)
    Runtime.lifecycle!(bridge.runtime, state)
    bridge.action_endpoint === nothing || Endpoint.state!(bridge.action_endpoint, state)
    return nothing
end

function cursor(value)
    value === nothing && return nothing
    return Codec.AcquisitionCursor(value.domain, value.generation,
        value.sequence, value.model_ns)
end

function snapshot(bridge::Bridge, state, current_cursor;
        phase::AbstractString, held::Bool, restored::Bool,
        window::Union{Nothing,UInt64}=nothing)
    return Codec.Snapshot(bridge.instrument, cursor(current_cursor),
        bridge.report_cursor, state.running, state.completed,
        phase, held, restored, window)
end

"""Advance only after the selected saved report has been published."""
function report_published!(bridge::Bridge, current_cursor)
    bridge.report_cursor = cursor(current_cursor)
    return nothing
end

function complete!(bridge::Bridge, ticket, state::Codec.ColdLifecycle,
        value::Union{Nothing,Codec.Snapshot}; result::Int32=Int32(0), message::AbstractString="")
    Runtime.complete!(bridge.runtime, ticket, state, value; result, message)
    return nothing
end

_apply!(::Codec.LifecycleCommand{:status}, bridge, state, ticket,
    period_ns, connect!, reset!, resume!, allow_shutdown) = (Int32(0), "", false)

function _apply!(::Codec.LifecycleCommand{:pause}, bridge, state, ticket,
        period_ns, connect!, reset!, resume!, allow_shutdown)
    bridge.runtime.endpoint.lifecycle === Codec.Connected ||
        return (Int32(-22), "owner is not Connected", false)
    state.running = false
    state.deadline_ns = UInt64(0)
    return (Int32(0), "", false)
end

function _apply!(::Codec.LifecycleCommand{:resume}, bridge, state, ticket,
        period_ns, connect!, reset!, resume!, allow_shutdown)
    bridge.runtime.endpoint.lifecycle === Codec.Connected && !state.completed ||
        return (Int32(-22), "owner is not resumable", false)
    if !state.running
        state.deadline_ns = Base.checked_add(time_ns(), period_ns)
        state.running = true
        resume!(ticket)
    end
    return (Int32(0), "", false)
end

function _apply!(::Codec.LifecycleCommand{:reset}, bridge, state, ticket,
        period_ns, connect!, reset!, resume!, allow_shutdown)
    bridge.runtime.endpoint.lifecycle === Codec.Connected && !state.running ||
        return (Int32(-22), "reset requires a paused Connected owner", false)
    result, message = reset!(ticket)
    if result == 0
        state.sequence = UInt64(0)
        state.completed = false
        state.deadline_ns = UInt64(0)
    end
    return (result, message, false)
end

function _apply!(::Codec.LifecycleCommand{:connect}, bridge, state, ticket,
        period_ns, connect!, reset!, resume!, allow_shutdown)
    bridge.runtime.endpoint.lifecycle === Codec.Prepared ||
        return (Int32(-22), "Connect requires Prepared", false)
    connect!(ticket)
    try lifecycle!(bridge, Codec.Connected)
    catch error; throw(TransportFailure(error)) end
    return (Int32(0), "", false)
end

function _apply!(::Codec.LifecycleCommand{:shutdown}, bridge, state, ticket,
        period_ns, connect!, reset!, resume!, allow_shutdown)
    allow_shutdown() || return (Int32(-16), "restoration or release is unresolved", false)
    state.running = false
    state.deadline_ns = UInt64(0)
    return (Int32(0), "", true)
end

"""Apply a ticket at the serialized owner boundary and return terminal intent.

Effects use the owner's established methods. An accepted Shutdown ticket is
completed only after the owner closes its resources and synchronizes Stopped.
"""
function dispatch!(bridge::Bridge, state; safe::Bool, period_ns::UInt64,
        snapshot!, connect!, reset!, allow_shutdown, resume! = ticket -> nothing)
    ticket = take!(bridge; safe)
    ticket === nothing && return nothing
    try Endpoint.check_ticket(bridge.runtime.endpoint, ticket)
    catch error; throw(TransportFailure(error)) end
    result = Int32(0)
    message = ""
    terminal = false
    value = try
        result, message, terminal = _apply!(ticket.command, bridge, state, ticket,
            period_ns, connect!, reset!, resume!, allow_shutdown)
        terminal ? nothing : snapshot!()
    catch primary
        primary isa TransportFailure && rethrow()
        # An effect or snapshot failure is an owner fault. A later completion
        # failure is outside this catch and cannot roll back successful effects.
        if bridge.runtime.endpoint.pending === ticket
            try
                lifecycle!(bridge, Codec.Fault)
                complete!(bridge, ticket, Codec.Fault, nothing; result=Int32(-5),
                    message=first(sprint(showerror, primary), 1024))
            catch publication
                throw(CompositeException([primary, publication]))
            end
        end
        rethrow()
    end
    terminal && return ticket
    try
        complete!(bridge, ticket, bridge.runtime.endpoint.lifecycle, value; result, message)
    catch error
        throw(TransportFailure(error))
    end
    return nothing
end

flush_terminal!(bridge::Bridge, deadline::Float64; check=()->nothing) =
    Runtime.flush_terminal!(bridge.runtime, deadline; check)

function Base.close(bridge::Bridge)
    primary = nothing
    if bridge.action_endpoint !== nothing
        try close(bridge.action_endpoint) catch error; primary = error end
        bridge.action_endpoint = nothing
    end
    try close(bridge.runtime)
    catch error
        primary === nothing ? rethrow() : throw(CompositeException([primary,error]))
    end
    primary === nothing || throw(primary)
    return nothing
end

end # module HILNativeAcquisitionLifecycle
