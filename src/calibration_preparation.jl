"""
Bounded, single-task preparation evidence for calibration acquisition. Adapters
verify authority and readbacks before constructing evidence, and invalidate the
gate on observed condition or authority loss. Manual evidence is operator
attestation, not continuous hardware readback. This module performs no I/O.
"""
module CalibrationPreparation

export Request, Confirmation, Procedure, complete!, cancel!, expire!, invalidate!, check_current!

monotonic() = time_ns() / 1e9

function _text(value::AbstractString, name, maximum)
    0 < ncodeunits(value) <= maximum && isvalid(value) && !occursin('\0', value) &&
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
    function Request(run::Integer, serial::Integer, stage::AbstractString,
            condition::AbstractString, configuration_identity::AbstractString,
            kind::Symbol, issued_at::Real, deadline::Real)
        0 < run <= typemax(UInt64) || throw(ArgumentError("run must be a nonzero UInt64"))
        0 < serial <= typemax(UInt64) || throw(ArgumentError("serial must be a nonzero UInt64"))
        stage = _text(stage, "stage", 256)
        condition = _text(condition, "condition", 256)
        configuration_identity = _text(configuration_identity, "configuration identity", 256)
        kind in (:manual, :simulated, :service) || throw(ArgumentError("unsupported evidence kind"))
        issued_at = _time(issued_at, "issued_at")
        deadline = _time(deadline, "deadline")
        issued_at < deadline || throw(ArgumentError("issued_at must precede deadline"))
        return new(UInt64(run), UInt64(serial), stage, condition,
            configuration_identity, kind, issued_at, deadline)
    end
end

Request(; run, serial, stage, condition, configuration_identity, kind, issued_at, deadline) =
    Request(run, serial, stage, condition, configuration_identity, kind, issued_at, deadline)

Base.:(==)(a::Request, b::Request) = a.run == b.run && a.serial == b.serial &&
    a.stage == b.stage && a.condition == b.condition &&
    a.configuration_identity == b.configuration_identity && a.kind == b.kind &&
    a.issued_at == b.issued_at && a.deadline == b.deadline

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
        return new(request, _time(observed_at, "observed_at"), _text(witness, "witness", 1024))
    end
end

Confirmation(request::Request; observed_at, witness) = Confirmation(request, observed_at, witness)

"""
    Procedure(request; clock=monotonic)

One owning task advances `state` from `:pending` to `:ready`. Cancellation,
expiry and invalidation are terminal and never ready. At most one confirmation
and a bounded reason are retained. Every acquisition admission must call
`check_current!`; callers invalidate observed condition/authority loss.
"""
mutable struct Procedure{C}
    const request::Request
    const clock::C
    const owner::Task
    state::Symbol
    confirmation::Union{Nothing,Confirmation}
    reason::Union{Nothing,String}
    last_at::Float64
    function Procedure(request::Request; clock=monotonic)
        at = _time(clock(), "clock")
        expired = at >= request.deadline
        return new{typeof(clock)}(request, clock, current_task(),
            expired ? :expired : :pending, nothing, expired ? "Deadline expired" : nothing, at)
    end
end

function _owner(p::Procedure)
    current_task() === p.owner || throw(ArgumentError("preparation procedure belongs to another task"))
    return nothing
end

function _finish!(p::Procedure, state::Symbol, reason::String)
    p.state = state
    p.reason = reason
    return nothing
end

function _reject!(p::Procedure, reason::String)
    p.state in (:pending, :ready) && _finish!(p, :invalidated, reason)
    throw(ArgumentError(reason))
end

function _now!(p::Procedure)
    at = try
        Float64(p.clock())
    catch
        _reject!(p, "Invalid monotonic clock")
    end
    isfinite(at) && at >= p.last_at || _reject!(p, "Invalid monotonic clock")
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
    p.state == :pending || _reject!(p, "Preparation is not pending")
    at = _now!(p)
    if at >= p.request.deadline
        _finish!(p, :expired, "Deadline expired")
        throw(ArgumentError("Deadline expired"))
    end
    confirmation.request == p.request || _reject!(p, "Preparation request mismatch")
    p.request.issued_at <= confirmation.observed_at <= at &&
        confirmation.observed_at < p.request.deadline ||
        _reject!(p, "Preparation observation is outside the current window")
    p.confirmation = confirmation
    p.state = :ready
    return confirmation
end

"Cancel pending or ready preparation without retry or hardware effects."
function cancel!(p::Procedure)
    _owner(p)
    p.state in (:pending, :ready) && _finish!(p, :cancelled, "Cancelled")
    return nothing
end

"Expire pending or ready preparation when its absolute deadline has elapsed."
function expire!(p::Procedure)
    _owner(p)
    if p.state in (:pending, :ready) && _now!(p) >= p.request.deadline
        _finish!(p, :expired, "Deadline expired")
    end
    return nothing
end

"Fence preparation on observed condition/authority loss; reasons are at most 1024 bytes."
function invalidate!(p::Procedure, reason::AbstractString)
    _owner(p)
    reason = _text(reason, "reason", 1024)
    p.state in (:pending, :ready) && _finish!(p, :invalidated, reason)
    return nothing
end

"Return the confirmation only while ready and unexpired; otherwise throw ArgumentError."
function check_current!(p::Procedure)
    _owner(p)
    expire!(p)
    p.state == :ready || throw(ArgumentError("Preparation is not ready ($(p.state))"))
    return something(p.confirmation)
end

end
