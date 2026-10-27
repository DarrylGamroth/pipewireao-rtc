# Included in CalibrationAcquisition: one owner advances this procedure from
# correlated completions. It performs no transport, file I/O, sleeping or polling.

"""
    Procedure(plan; clock=NativeControlClient.monotonic, consume=(_...)->nothing)

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

One task owns a procedure. Transport adapters prove controller/owner identity
before delivering completions; this object additionally checks run, serial and
operation. Replay delivers the same typed commands/completions without devices.
"""
mutable struct Procedure{P<:Plan,F,C,K}
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
    cancelled::Bool
    restoration_confirmed::Bool
    failure::Union{Nothing,String}
    recovery_failure::Union{Nothing,String}
    result::Union{Nothing,Result}
end

function Procedure(input::Plan; clock=Client.monotonic, consume=(_...)->nothing,
        cancelled=()->false)
    plan = Plan(input.run, input.reference, input.probes, input.measurements,
        input.frames_per_probe, input.settling, input.timeouts)
    procedure = Procedure(plan, consume, clock, cancelled, nothing, Inf, UInt64(0), 1,
        nothing, Codec.Responses[], false, false, nothing, nothing, nothing)
    if cancelled()
        procedure.failure = "Cancelled"
        _issue!(procedure, Codec.Restore(copy(plan.reference), plan.settling))
    else
        _issue!(procedure, Codec.Hold())
    end
    return procedure
end

function _issue!(p::Procedure, action::Codec.Action)
    deadline = Float64(p.clock()) + _timeout(action, p.plan.timeouts) / 1e9
    isfinite(deadline) || throw(ArgumentError("calibration deadline is not finite"))
    p.serial = Base.Checked.checked_add(p.serial, UInt64(1))
    p.command = Codec.Command(p.plan.run, p.serial, action)
    p.deadline = deadline
    return p.command
end

function _finish!(p::Procedure, released::Bool)
    phase = released ? (p.failure === nothing ? "complete" : "aborted") : "fault"
    p.result = Result(p.plan.run, phase, p.restoration_confirmed,
        p.restoration_confirmed && released, p.failure, p.recovery_failure,
        phase == "complete" ? p.responses : Codec.Responses[])
    p.command = nothing
    return nothing
end

"""
    fail!(procedure, reason; known=false)

Report an endpoint or consumer failure. An unknown in-flight outcome faults
without another submission. A known outcome permits one restoration/release
attempt, unless that recovery is already in progress. No automatic retry.
"""
function fail!(p::Procedure, reason::AbstractString; known::Bool=false)
    p.command === nothing && throw(ArgumentError("calibration procedure is terminal"))
    action = p.command.action
    p.failure === nothing && (p.failure = String(reason))
    if known && !(action isa Union{Codec.Restore,Codec.Release})
        _issue!(p, Codec.Restore(copy(p.plan.reference), p.plan.settling))
    else
        p.recovery_failure = known ? String(reason) : "Endpoint"
        _finish!(p, false)
    end
    return p.command
end

"""Mark cancellation; resolve the in-flight action before restoring/releasing.
Cancellation never interrupts recovery or establishes an unknown command outcome.
"""
function cancel!(p::Procedure)
    p.command === nothing && return nothing
    p.cancelled = true
    return nothing
end

"""Deliver a deadline event. Early events do nothing; an expired in-flight
command has unknown outcome and faults without submitting a restore or retry.
"""
function expire!(p::Procedure)
    p.command === nothing && return nothing
    p.clock() < p.deadline && return nothing
    return fail!(p, "TimedOut($(_phase(p.command.action)))")
end

_snapshot(batch::Codec.Responses) = Codec.Responses(copy(batch.values), copy(batch.exposures), batch.valid)

"""
    complete!(procedure, run, serial, result)

Deliver one correlated terminal action result and return the next command, or
`nothing` when terminal. Wrong run/serial/operation faults without recovery.
Malformed scientific evidence with a known terminal action requests recovery.
The transport adapter remains responsible for owner/controller correlation.
"""
function complete!(p::Procedure, run::UInt64, serial::UInt64, result::Codec.Result;
        at::Float64=Float64(p.clock()))
    command = p.command
    command === nothing && throw(ArgumentError("calibration procedure is terminal"))
    if run != command.run || serial != command.serial ||
            !Native._valid_result(command.action, result)
        return fail!(p, "Endpoint")
    end
    isfinite(at) || throw(ArgumentError("completion time is not finite"))
    if at >= p.deadline
        return fail!(p, "TimedOut($(_phase(command.action)))"; known=true)
    end
    action = command.action
    try
        p.cancelled = p.cancelled || p.cancellation()
        result = _terminal(result)
        if action isa Codec.Hold
            _valid(result.cursor) || _invalid()
            p.cursor = result.cursor
        elseif action isa Codec.Adopt
            p.cursor = _adopted(result, something(p.cursor), p.plan.probes[p.probe])
        elseif action isa Codec.Settle
            _settled(p.plan.settling, something(p.cursor), result.cursor) || _invalid()
            p.cursor = result.cursor
        elseif action isa Codec.Collect
            p.cursor = _batch_cursor(result, something(p.cursor), p.plan)
            push!(p.responses, _snapshot(result))
            try
                p.consume(p.probe, _snapshot(result))
            catch
                return fail!(p, "Processing"; known=true)
            end
            p.cancelled = p.cancelled || p.cancellation()
        elseif action isa Codec.Restore
            p.restoration_confirmed = _restored(result, p.plan.reference)
            p.cancelled && p.failure === nothing && (p.failure = "Cancelled")
            return _issue!(p, Codec.Release())
        elseif action isa Codec.Release
            p.cancelled && p.failure === nothing && (p.failure = "Cancelled")
            return _finish!(p, true)
        end
    catch error
        return fail!(p, _failure(error); known=true)
    end
    p.cancelled && return fail!(p, "Cancelled"; known=true)
    if action isa Union{Codec.Hold,Codec.Collect}
        action isa Codec.Collect && (p.probe += 1)
        if p.probe > length(p.plan.probes)
            return _issue!(p, Codec.Restore(copy(p.plan.reference), p.plan.settling))
        end
        return _issue!(p, Codec.Adopt(UInt32(p.probe - 1), copy(p.plan.probes[p.probe])))
    elseif action isa Codec.Adopt
        return _issue!(p, Codec.Settle(UInt32(p.probe - 1), something(p.cursor), p.plan.settling))
    else
        return _issue!(p, Codec.Collect(UInt32(p.probe - 1), something(p.cursor),
            p.plan.measurements, p.plan.frames_per_probe))
    end
end
