"""
Bounded, single-task preparation evidence for calibration acquisition. Adapters
verify authority and readbacks before constructing evidence, and invalidate the
gate on observed condition or authority loss. Manual evidence is operator
attestation, not continuous hardware readback. This module performs no I/O.
"""
module CalibrationPreparation

using Hsm: @hsmdef, @statedef, @on_initial, @on_event
import Hsm
import ..Common

export Request,
    Confirmation, Procedure, complete!, cancel!, expire!, invalidate!, check_current!

# Retain the existing seconds callable without another clock-reading wrapper.
const monotonic = Common.monotonic_seconds

function _text(value::AbstractString, name, maximum)
    0 < ncodeunits(value) <= maximum &&
    isvalid(value) &&
    !occursin('\0', value) &&
    !all(isspace, value) || throw(ArgumentError("$name must be bounded nonempty UTF-8"))
    return String(value)
end

function _time(value::Real, name)
    result = Float64(value)
    isfinite(result) || throw(ArgumentError("$name must be finite"))
    return result
end

"""
    Request(; run, serial, stage, condition, configuration_identity, kind, issued_at, deadline)

Identify one preparation window in a shared monotonic clock domain. `run` and
`serial` are nonzero UInt64 identifiers; text fields are at most 256 UTF-8 bytes.
`kind` is `:manual`, `:simulated` or `:service` and `issued_at < deadline`.
"""
struct Request
    run::UInt64
    serial::UInt64
    stage::String
    condition::String
    configuration_identity::String
    kind::Symbol
    issued_at::Float64
    deadline::Float64
    function Request(
        run::Integer,
        serial::Integer,
        stage::AbstractString,
        condition::AbstractString,
        configuration_identity::AbstractString,
        kind::Symbol,
        issued_at::Real,
        deadline::Real,
    )
        0 < run <= typemax(UInt64) || throw(ArgumentError("run must be a nonzero UInt64"))
        0 < serial <= typemax(UInt64) ||
            throw(ArgumentError("serial must be a nonzero UInt64"))
        stage = _text(stage, "stage", 256)
        condition = _text(condition, "condition", 256)
        configuration_identity =
            _text(configuration_identity, "configuration identity", 256)
        kind in (:manual, :simulated, :service) ||
            throw(ArgumentError("unsupported evidence kind"))
        issued_at = _time(issued_at, "issued_at")
        deadline = _time(deadline, "deadline")
        issued_at < deadline || throw(ArgumentError("issued_at must precede deadline"))
        return new(
            UInt64(run),
            UInt64(serial),
            stage,
            condition,
            configuration_identity,
            kind,
            issued_at,
            deadline,
        )
    end
end

Request(;
    run,
    serial,
    stage,
    condition,
    configuration_identity,
    kind,
    issued_at,
    deadline,
) = Request(
    run,
    serial,
    stage,
    condition,
    configuration_identity,
    kind,
    issued_at,
    deadline,
)

Base.:(==)(a::Request, b::Request) =
    a.run == b.run &&
    a.serial == b.serial &&
    a.stage == b.stage &&
    a.condition == b.condition &&
    a.configuration_identity == b.configuration_identity &&
    a.kind == b.kind &&
    a.issued_at == b.issued_at &&
    a.deadline == b.deadline

"""
    Confirmation(request; observed_at, witness)

Bind an observation to the exact request. `witness` names the operator or exact
simulator/service incarnation (at most 1024 UTF-8 bytes). The adapter owns its
authority checks and clock mapping; a witness string alone proves no authority.
"""
struct Confirmation
    request::Request
    observed_at::Float64
    witness::String
    function Confirmation(request::Request, observed_at::Real, witness::AbstractString)
        return new(
            request,
            _time(observed_at, "observed_at"),
            _text(witness, "witness", 1024),
        )
    end
end

Confirmation(request::Request; observed_at, witness) =
    Confirmation(request, observed_at, witness)

"""
    Procedure(request; clock=Common.MONOTONIC_CLOCK)

One owning task advances `state` from `:pending` to `:ready`. Cancellation,
expiry and invalidation are terminal and never ready. At most one confirmation
and a bounded reason are retained. Every acquisition admission must call
`check_current!`; callers invalidate observed condition/authority loss. The
read-only `state` property projects the active HSM state as a lowercase symbol.
`clock` accepts a Clocks nanosecond clock or an existing seconds callable.
"""
@hsmdef mutable struct Procedure{C}
    const request::Request
    const clock::C
    const owner::Task
    confirmation::Union{Nothing,Confirmation}
    reason::Union{Nothing,String}
    last_at::Float64
end

@statedef Procedure :Active
@statedef Procedure :Pending :Active
@statedef Procedure :Ready :Active
@statedef Procedure :Terminal
@statedef Procedure :Cancelled :Terminal
@statedef Procedure :Expired :Terminal
@statedef Procedure :Invalidated :Terminal

@on_initial function (p::Procedure{C}, ::Root) where {C}
    return Hsm.transition!(p, :Pending)
end
@on_event function (p::Procedure{C}, ::Active, ::DeadlineObserved, at) where {C}
    _owner(p)
    if at >= p.request.deadline
        p.reason = "Deadline expired"
        return Hsm.transition!(p, :Expired)
    end
    return Hsm.EventHandled
end
@on_event function (p::Procedure{C}, ::Pending, ::Complete, confirmation) where {C}
    _owner(p)
    at = _now!(p)
    if at === nothing
        p.reason = "Invalid monotonic clock"
        Hsm.transition!(p, :Invalidated)
        throw(ArgumentError(p.reason))
    elseif at >= p.request.deadline
        p.reason = "Deadline expired"
        Hsm.transition!(p, :Expired)
        throw(ArgumentError(p.reason))
    end
    reason =
        confirmation.request != p.request ? "Preparation request mismatch" :
        !(
            p.request.issued_at <= confirmation.observed_at <= at &&
            confirmation.observed_at < p.request.deadline
        ) ? "Preparation observation is outside the current window" : nothing
    if reason !== nothing
        p.reason = reason
        Hsm.transition!(p, :Invalidated)
        throw(ArgumentError(reason))
    end
    p.confirmation = confirmation
    return Hsm.transition!(p, :Ready)
end
@on_event function (p::Procedure{C}, ::Active, ::Complete, _) where {C}
    _owner(p)
    p.reason = "Preparation is not pending"
    Hsm.transition!(p, :Invalidated)
    throw(ArgumentError(p.reason))
end
@on_event function (p::Procedure{C}, ::Terminal, ::Complete, _) where {C}
    _owner(p)
    throw(ArgumentError("Preparation is not pending"))
end
@on_event function (p::Procedure{C}, ::Active, ::Cancel, _) where {C}
    _owner(p)
    p.reason = "Cancelled"
    return Hsm.transition!(p, :Cancelled)
end
@on_event function (p::Procedure{C}, ::Active, ::Expire, _) where {C}
    _owner(p)
    at = _now!(p)
    if at === nothing
        p.reason = "Invalid monotonic clock"
        Hsm.transition!(p, :Invalidated)
        throw(ArgumentError(p.reason))
    elseif at >= p.request.deadline
        p.reason = "Deadline expired"
        return Hsm.transition!(p, :Expired)
    end
    return Hsm.EventHandled
end
@on_event function (p::Procedure{C}, ::Active, ::Invalidate, reason) where {C}
    _owner(p)
    p.reason = _text(reason, "reason", 1024)
    return Hsm.transition!(p, :Invalidated)
end
@on_event function (p::Procedure{C}, ::Terminal, ::Cancel, _) where {C}
    _owner(p)
    return Hsm.EventHandled
end
@on_event function (p::Procedure{C}, ::Terminal, ::Expire, _) where {C}
    _owner(p)
    return Hsm.EventHandled
end
@on_event function (p::Procedure{C}, ::Terminal, ::Invalidate, reason) where {C}
    _owner(p)
    _text(reason, "reason", 1024)
    return Hsm.EventHandled
end
@on_event function (p::Procedure{C}, ::Ready, ::CheckCurrent, _) where {C}
    _owner(p)
    return Hsm.EventHandled
end
@on_event function (p::Procedure{C}, ::Root, ::CheckCurrent, _) where {C}
    _owner(p)
    throw(ArgumentError("Preparation is not ready ($(p.state))"))
end

const STATES = (;
    Pending = :pending,
    Ready = :ready,
    Cancelled = :cancelled,
    Expired = :expired,
    Invalidated = :invalidated,
)
Base.getproperty(p::Procedure, name::Symbol) =
    name === :state ? getproperty(STATES, Hsm.current(p)) : getfield(p, name)
Base.propertynames(p::Procedure, private::Bool = false) =
    private ? (fieldnames(typeof(p))..., :state) :
    (:request, :clock, :owner, :state, :confirmation, :reason, :last_at)

function Procedure(request::Request; clock = Common.MONOTONIC_CLOCK)
    at = _time(Common.monotonic_seconds(clock), "clock")
    p = Procedure(request, clock, current_task(), nothing, nothing, at)
    Hsm.dispatch!(p, :DeadlineObserved, at)
    return p
end

function _owner(p::Procedure)
    current_task() === p.owner ||
        throw(ArgumentError("preparation procedure belongs to another task"))
    return nothing
end

function _now!(p::Procedure)
    at = try
        Float64(Common.monotonic_seconds(p.clock))
    catch
        return nothing
    end
    isfinite(at) && at >= p.last_at || return nothing
    p.last_at = at
    return at
end

"""
    complete!(procedure, confirmation)

Accept one exact, fresh confirmation and return it. Observed and delivery times
must lie in `[issued_at, deadline)` and observations cannot be in the future.
Wrong, stale, late or duplicate completion fences acquisition and throws
`ArgumentError`. Terminal gates cannot revive.
"""
function complete!(p::Procedure, confirmation::Confirmation)
    _owner(p)
    Hsm.dispatch!(p, :Complete, confirmation)
    return confirmation
end

"Cancel pending or ready preparation without retry or hardware effects."
function cancel!(p::Procedure)
    _owner(p)
    Hsm.dispatch!(p, :Cancel)
    return nothing
end

"Expire pending or ready preparation when its absolute deadline has elapsed."
function expire!(p::Procedure)
    _owner(p)
    Hsm.dispatch!(p, :Expire)
    return nothing
end

"Fence preparation on observed condition/authority loss; reasons are at most 1024 bytes."
function invalidate!(p::Procedure, reason::AbstractString)
    _owner(p)
    reason = _text(reason, "reason", 1024)
    Hsm.dispatch!(p, :Invalidate, reason)
    return nothing
end

"Return the confirmation only while ready and unexpired; otherwise throw ArgumentError."
function check_current!(p::Procedure)
    _owner(p)
    Hsm.dispatch!(p, :Expire)
    Hsm.dispatch!(p, :CheckCurrent)
    return something(p.confirmation)
end

end
