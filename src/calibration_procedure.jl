# Included in CalibrationAcquisition: one task dispatches correlated completions.
# Handlers select the next command; transport remains in the caller's driver.

"""
    Procedure(plan; clock=Common.MONOTONIC_CLOCK, consume=(_...)->nothing)

Prepare a completion-driven interaction acquisition. `command` is the sole
pending native command and `deadline` its absolute monotonic deadline. The
caller submits it once, then calls `complete!`, `expire!` or `fail!`. Terminal
procedures have `command === nothing` and a `result`.

`consume(probe, batch)` receives each causally validated response batch before
the next probe is issued; `probe` is one-based. These are candidate data until
the complete run restores/releases successfully and scientific acceptance is
established. Consumer failure aborts acquisition and requests restoration.
Consumers run on the procedure's control task, never in PipeWire callbacks.
They must do bounded work or hand owned data to a bounded numerical worker.
The consumer owns its batch; retained result storage is separate.
Consumer calls run between Hsm dispatch steps and may request cancellation of
the procedure. They do not run in entry/exit behaviors.

One task owns a procedure. Transport adapters prove controller/owner identity
before delivering completions; this object additionally checks run, serial and
operation. Replay delivers the same typed commands/completions without devices.
Hsm handlers own acquisition and recovery phases. Entry/exit behaviors perform
no command submission or consumer work.
`clock` accepts a Clocks nanosecond clock or an existing seconds callable.
"""
@hsmdef mutable struct Procedure{P<:Plan,F,C,K}
    plan::P
    consume::F
    clock::C
    cancellation::K
    command::Union{Nothing,Codec.Command}
    deadline::Float64
    serial::UInt64
    probe::Int
    cursor::Union{Nothing,Codec.AcquisitionCursor}
    responses::Vector{Codec.Responses}
    delivery::Union{Nothing,Codec.Responses}
    cancelled::Bool
    restoration_confirmed::Bool
    failure::Union{Nothing,String}
    recovery_failure::Union{Nothing,String}
    result::Union{Nothing,Result}
end

@statedef Procedure :Idle
@statedef Procedure :Active
@statedef Procedure :Acquiring :Active
@statedef Procedure :Holding :Acquiring
@statedef Procedure :Adopting :Acquiring
@statedef Procedure :Settling :Acquiring
@statedef Procedure :Collecting :Acquiring
@statedef Procedure :Processing :Acquiring
@statedef Procedure :Recovery :Active
@statedef Procedure :Restoring :Recovery
@statedef Procedure :Releasing :Recovery
@statedef Procedure :Terminal
@statedef Procedure :Complete :Terminal
@statedef Procedure :Aborted :Terminal
@statedef Procedure :Fault :Terminal

@on_initial function(p::Procedure, ::Root)
    return Hsm.transition!(p, :Idle)
end

@on_event function(p::Procedure, ::Idle, ::Started, _)
    if p.cancellation()
        p.failure = "Cancelled"
        _issue_restore!(p)
        return Hsm.transition!(p, :Restoring)
    end
    _issue!(p, Codec.Hold())
    return Hsm.transition!(p, :Holding)
end

@on_event function(p::Procedure, ::Holding, ::Completed, completion)
    _completion_error(p, completion) === nothing || return Hsm.EventNotHandled
    try
        result = _accepted_result!(p, completion)
        _valid(result.cursor) || _invalid()
        p.cursor = result.cursor
    catch error
        _restore_after_failure!(p, _failure(error))
        return Hsm.transition!(p, :Restoring)
    end
    if p.cancelled
        _restore_after_failure!(p, "Cancelled")
        return Hsm.transition!(p, :Restoring)
    end
    _issue_probe!(p)
    return Hsm.transition!(p, :Adopting)
end

@on_event function(p::Procedure, ::Adopting, ::Completed, completion)
    _completion_error(p, completion) === nothing || return Hsm.EventNotHandled
    try
        result = _accepted_result!(p, completion)
        p.cursor = _adopted(result, something(p.cursor), p.plan.probes[p.probe])
    catch error
        _restore_after_failure!(p, _failure(error))
        return Hsm.transition!(p, :Restoring)
    end
    if p.cancelled
        _restore_after_failure!(p, "Cancelled")
        return Hsm.transition!(p, :Restoring)
    end
    _issue!(p, Codec.Settle(UInt32(p.probe - 1), something(p.cursor), p.plan.settling))
    return Hsm.transition!(p, :Settling)
end

@on_event function(p::Procedure, ::Settling, ::Completed, completion)
    _completion_error(p, completion) === nothing || return Hsm.EventNotHandled
    try
        result = _accepted_result!(p, completion)
        _settled(p.plan.settling, something(p.cursor), result.cursor) || _invalid()
        p.cursor = result.cursor
    catch error
        _restore_after_failure!(p, _failure(error))
        return Hsm.transition!(p, :Restoring)
    end
    if p.cancelled
        _restore_after_failure!(p, "Cancelled")
        return Hsm.transition!(p, :Restoring)
    end
    _issue!(p, Codec.Collect(UInt32(p.probe - 1), something(p.cursor),
        p.plan.measurements, p.plan.frames_per_probe))
    return Hsm.transition!(p, :Collecting)
end

@on_event function(p::Procedure, ::Collecting, ::Completed, completion)
    _completion_error(p, completion) === nothing || return Hsm.EventNotHandled
    try
        result = _accepted_result!(p, completion)
        p.cursor = _batch_cursor(result, something(p.cursor), p.plan)
        push!(p.responses, _snapshot(result))
        try
            p.delivery = _snapshot(result)
        catch
            _restore_after_failure!(p, "Processing")
            return Hsm.transition!(p, :Restoring)
        end
    catch error
        _restore_after_failure!(p, _failure(error))
        return Hsm.transition!(p, :Restoring)
    end
    return Hsm.transition!(p, :Processing)
end

@on_event function(p::Procedure, ::Processing, ::Consumed, _)
    try
        p.cancelled = p.cancelled || p.cancellation()
    catch error
        _restore_after_failure!(p, _failure(error))
        return Hsm.transition!(p, :Restoring)
    end
    if p.cancelled
        _restore_after_failure!(p, "Cancelled")
        return Hsm.transition!(p, :Restoring)
    end
    p.probe += 1
    if p.probe > length(p.plan.probes)
        _issue_restore!(p)
        return Hsm.transition!(p, :Restoring)
    end
    _issue_probe!(p)
    return Hsm.transition!(p, :Adopting)
end

@on_event function(p::Procedure, ::Processing, ::Completed, _)
    _fault!(p, "Endpoint", false)
    return Hsm.transition!(p, :Fault)
end

@on_event function(p::Procedure, ::Restoring, ::Completed, completion)
    _completion_error(p, completion) === nothing || return Hsm.EventNotHandled
    try
        result = _accepted_result!(p, completion)
        p.restoration_confirmed = _restored(result, p.plan.reference)
        p.cancelled && _record_failure!(p, "Cancelled")
        _issue!(p, Codec.Release())
    catch error
        _fault!(p, _failure(error), true)
        return Hsm.transition!(p, :Fault)
    end
    return Hsm.transition!(p, :Releasing)
end

@on_event function(p::Procedure, ::Releasing, ::Completed, completion)
    _completion_error(p, completion) === nothing || return Hsm.EventNotHandled
    try
        _accepted_result!(p, completion)
        p.cancelled && _record_failure!(p, "Cancelled")
        _finish!(p, true)
    catch error
        _fault!(p, _failure(error), true)
        return Hsm.transition!(p, :Fault)
    end
    return p.failure === nothing ? Hsm.transition!(p, :Complete) : Hsm.transition!(p, :Aborted)
end

# Invalid correlation/late delivery bubbles to the phase's shared failure rule.
# The check is pure: it must not poll cancellation twice while propagating.
@on_event function(p::Procedure, ::Acquiring, ::Completed, completion)
    failure = _completion_error(p, completion)
    failure === nothing && return Hsm.EventNotHandled
    if failure.known
        _restore_after_failure!(p, failure.reason)
        return Hsm.transition!(p, :Restoring)
    end
    _fault!(p, failure.reason, false)
    return Hsm.transition!(p, :Fault)
end

@on_event function(p::Procedure, ::Recovery, ::Completed, completion)
    failure = _completion_error(p, completion)
    failure === nothing && return Hsm.EventNotHandled
    _fault!(p, failure.reason, failure.known)
    return Hsm.transition!(p, :Fault)
end

@on_event function(p::Procedure, ::Acquiring, ::Failed, failure)
    if failure.known
        _restore_after_failure!(p, failure.reason)
        return Hsm.transition!(p, :Restoring)
    end
    _fault!(p, failure.reason, false)
    return Hsm.transition!(p, :Fault)
end

@on_event function(p::Procedure, ::Recovery, ::Failed, failure)
    _fault!(p, failure.reason, failure.known)
    return Hsm.transition!(p, :Fault)
end

@on_event function(p::Procedure, ::Active, ::Cancelled, _)
    p.cancelled = true
    return Hsm.EventHandled
end

@on_event function(p::Procedure, ::Active, ::Expired, _)
    Common.monotonic_seconds(p.clock) < p.deadline && return Hsm.EventHandled
    _fault!(p, "TimedOut($(_phase(something(p.command).action)))", false)
    return Hsm.transition!(p, :Fault)
end

@on_event function(p::Procedure, ::Terminal, ::Completed, _)
    throw(ArgumentError("calibration procedure is terminal"))
end
@on_event function(p::Procedure, ::Terminal, ::Failed, _)
    throw(ArgumentError("calibration procedure is terminal"))
end
@on_event function(p::Procedure, ::Terminal, ::Cancelled, _)
    return Hsm.EventHandled
end
@on_event function(p::Procedure, ::Terminal, ::Expired, _)
    return Hsm.EventHandled
end

function Procedure(input::Plan; clock=Common.MONOTONIC_CLOCK, consume=(_...)->nothing,
        cancelled=()->false)
    plan = Plan(input.run, input.reference, input.probes, input.measurements,
        input.frames_per_probe, input.settling, input.timeouts)
    procedure = Procedure(plan, consume, clock, cancelled, nothing, Inf, UInt64(0), 1,
        nothing, Codec.Responses[], nothing, false, false, nothing, nothing, nothing)
    Hsm.dispatch!(procedure, :Started)
    return procedure
end

# Handler helpers construct commands and update facts, never dispatch/transition.
function _issue!(p::Procedure, action::Codec.Action)
    deadline = Float64(Common.monotonic_seconds(p.clock)) + _timeout(action, p.plan.timeouts) / 1e9
    isfinite(deadline) || throw(ArgumentError("calibration deadline is not finite"))
    p.serial = Base.Checked.checked_add(p.serial, UInt64(1))
    p.command = Codec.Command(p.plan.run, p.serial, action)
    p.deadline = deadline
    return p.command
end

_issue_probe!(p::Procedure) =
    _issue!(p, Codec.Adopt(UInt32(p.probe - 1), copy(p.plan.probes[p.probe])))
_issue_restore!(p::Procedure) = _issue!(p, Codec.Restore(copy(p.plan.reference), p.plan.settling))

function _record_failure!(p::Procedure, reason::AbstractString)
    p.failure === nothing && (p.failure = String(reason))
    return nothing
end
function _restore_after_failure!(p::Procedure, reason::AbstractString)
    _record_failure!(p, reason)
    p.delivery = nothing
    _issue_restore!(p)
    return nothing
end
function _fault!(p::Procedure, reason::AbstractString, known::Bool)
    _record_failure!(p, reason)
    p.delivery = nothing
    p.recovery_failure = known ? String(reason) : "Endpoint"
    _finish!(p, false)
    return nothing
end

function _finish!(p::Procedure, released::Bool)
    phase = released ? (p.failure === nothing ? "complete" : "aborted") : "fault"
    p.result = Result(p.plan.run, phase, p.restoration_confirmed,
        p.restoration_confirmed && released, p.failure, p.recovery_failure,
        phase == "complete" ? p.responses : Codec.Responses[])
    p.command = nothing
    return nothing
end

function _completion_error(p::Procedure, completion)
    command = something(p.command)
    if completion.run != command.run || completion.serial != command.serial ||
            !ActionClient._valid_result(command.action, completion.result)
        return (; reason="Endpoint", known=false)
    end
    isfinite(completion.at) || throw(ArgumentError("completion time is not finite"))
    if completion.at >= p.deadline
        return (; reason="TimedOut($(_phase(command.action)))", known=true)
    end
    return nothing
end

function _accepted_result!(p::Procedure, completion)
    p.cancelled = p.cancelled || p.cancellation()
    return _terminal(completion.result)
end

_snapshot(batch::Codec.Responses) = Codec.Responses(copy(batch.values), copy(batch.exposures), batch.valid)

# Deliver the single owned batch outside run-to-completion dispatch, so a
# consumer can call cancel! without recursively dispatching the same machine.
# Phase decisions and subsequent command selection remain in the handlers.
function _dispatch_completion!(p::Procedure, completion)
    Hsm.dispatch!(p, :Completed, completion)
    if p.delivery !== nothing
        batch = p.delivery
        p.delivery = nothing
        try
            p.consume(p.probe, batch)
        catch
            Hsm.dispatch!(p, :Failed, (; reason="Processing", known=true))
            return p.command
        end
        Hsm.dispatch!(p, :Consumed)
    end
    return p.command
end

"""
    fail!(procedure, reason; known=false)

Report an endpoint or consumer failure. An unknown in-flight outcome faults
without another submission. A known outcome permits one restoration/release
attempt, unless that recovery is already in progress. No automatic retry.
"""
function fail!(p::Procedure, reason::AbstractString; known::Bool=false)
    Hsm.dispatch!(p, :Failed, (; reason, known))
    return p.command
end

"""Mark cancellation; resolve the in-flight action before restoring/releasing.
Cancellation never interrupts recovery or establishes an unknown command outcome.
"""
function cancel!(p::Procedure)
    Hsm.dispatch!(p, :Cancelled)
    return nothing
end

"""Deliver a deadline event. Early events do nothing; an expired in-flight
command has unknown outcome and faults without submitting a restore or retry.
"""
function expire!(p::Procedure)
    Hsm.dispatch!(p, :Expired)
    return nothing
end

"""
    complete!(procedure, run, serial, result)

Deliver one correlated terminal action result and return the next command, or
`nothing` when terminal. Wrong run/serial/operation faults without recovery.
Malformed scientific evidence with a known terminal action requests recovery.
The transport adapter remains responsible for owner/controller correlation.
"""
function complete!(p::Procedure, run::UInt64, serial::UInt64, result::Codec.Result;
        at::Float64=Float64(Common.monotonic_seconds(p.clock)))
    return _dispatch_completion!(p, (; run, serial, result, at))
end
