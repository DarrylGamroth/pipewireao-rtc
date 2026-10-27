"""Finite interaction acquisition on the control context; no science or session policy."""
module CalibrationAcquisition

using JSON

import ..Common
import ..NativeCalibrationActionClient
import ..NativeCalibrationActionCodec
import ..NativeControlClient
const Native = NativeCalibrationActionClient
const Codec = NativeCalibrationActionCodec
const Client = NativeControlClient

export Plan, Timeouts, acquire!, acquire, read_plan, document, Cancelled
export Procedure, complete!, cancel!, expire!, fail!
const MAX_PLAN_BYTES = 16 * 1024 * 1024
const MAX_RECORD_BYTES = 512 * 1024 * 1024

struct Timeouts
    ownership::Int64
    adoption::Int64
    settling::Int64
    collection::Int64
    restoration::Int64
    function Timeouts(ownership, adoption, settling, collection, restoration)
        values = (ownership, adoption, settling, collection, restoration)
        checked = map(v -> Int64(Native._integer(v, 1, typemax(Int64))), values)
        new(checked...)
    end
end

# Prepared figures are owned snapshots. The driver never reads a caller's mutable
# plan after Hold, and neither array axes nor instrument names encode coordinates.
struct Plan{R<:Codec.Rule}
    run::UInt64
    reference::Vector{Float32}
    probes::Vector{Vector{Float32}}
    measurements::UInt32
    frames_per_probe::UInt32
    settling::R
    timeouts::Timeouts
    function Plan(run, reference::AbstractVector, probes::AbstractVector,
            measurements, frames_per_probe, settling::R, timeouts::Timeouts) where {R<:Codec.Rule}
        identity = Native._integer(run, 1, typemax(UInt64))
        count = Int(Native._integer(length(probes), 1, 16384))
        measurements = UInt32(Native._integer(measurements, 1, 131072))
        frames = UInt32(Native._integer(frames_per_probe, 1, 4096))
        Codec._validate(settling)
        # Check all capacities before constructing wire PODs or acquiring Hold.
        Codec.preflight_collect_reply(measurements, frames)
        reference = _figure(reference, Codec._add(8, Codec._rule_size(settling)))
        command_count = length(reference)
        # A conservative retained-payload budget, including per-probe metadata.
        # This is not a Julia heap/RSS limit or a frame-path allocation contract.
        charge = BigInt(count + 1) * command_count * 4 +
            BigInt(count) * (256 + BigInt(measurements) * 4 + BigInt(frames) * 40)
        charge <= MAX_RECORD_BYTES || throw(ArgumentError("calibration record exceeds 512 MiB"))
        figures = Vector{Vector{Float32}}(undef, count)
        for (index, probe) in enumerate(probes)
            length(probe) == command_count || throw(ArgumentError("probe command dimension differs"))
            figures[index] = _figure(probe, 24)
        end
        new{R}(identity, reference, figures, measurements, frames, settling, timeouts)
    end
end
function _figure(values::AbstractVector, overhead)
    converted = Native._figure(values, overhead)
    return Float32[value for value in converted]
end
function Plan(value::AbstractDict)
    Native._fields(value, ("version", "run", "reference", "probes", "measurements",
        "frames_per_probe", "settling", "timeouts_ns"))
    Native._integer(value["version"], 1, 1)
    t = Native._fields(value["timeouts_ns"],
        ("ownership", "adoption", "settling", "collection", "restoration"))
    return Plan(value["run"], value["reference"], value["probes"], value["measurements"],
        value["frames_per_probe"], Native._rule(value["settling"]),
        Timeouts((t[k] for k in ("ownership", "adoption", "settling", "collection", "restoration"))...))
end
function read_plan(path::AbstractString)
    bytes = open(path) do io
        read(io, MAX_PLAN_BYTES + 1)
    end
    length(bytes) <= MAX_PLAN_BYTES || throw(ArgumentError("plan exceeds 16 MiB"))
    text = String(bytes)
    value = Common.parse_json(text)
    # Preserve rejection of duplicate fields before adopting a plan; eager
    # JSON objects otherwise retain only the final value of each repeated key.
    try
        JSON.parse(text; duplicate_keys=:error, maxdepth=64)
    catch exception
        _plan_parse_error(exception)
    end
    return Plan(value)
end

_plan_parse_error(::JSON.DuplicateKeyError) =
    throw(ArgumentError("duplicate calibration plan field"))
_plan_parse_error(exception) = throw(exception)

struct Cancelled <: Exception end
struct AcquisitionFailure <: Exception
    reason::String
end
Base.showerror(io::IO, error::AcquisitionFailure) = print(io, error.reason)
Base.showerror(io::IO, ::Cancelled) = print(io, "calibration cancelled")
_failure(::Cancelled) = "Cancelled"
_failure(e::AcquisitionFailure) = e.reason
_failure(::Exception) = "Endpoint"
_invalid() = throw(AcquisitionFailure("InvalidEvidence"))
_terminal(result::Codec.Result) = result
_terminal(result::Codec.Failed) = throw(AcquisitionFailure(
    ("Cancelled", "Endpoint", "InvalidEvidence", "ProbeClipped")[Int(result.reason)]))
_timeout(::Union{Codec.Hold,Codec.Release}, t) = t.ownership
_timeout(::Codec.Adopt, t) = t.adoption
_timeout(::Codec.Settle, t) = t.settling
_timeout(::Codec.Collect, t) = t.collection
_timeout(::Codec.Restore, t) = t.restoration
_phase(::Codec.Hold) = "Holding"
_phase(::Codec.Adopt) = "Adopting"
_phase(::Codec.Settle) = "Settling"
_phase(::Codec.Collect) = "Collecting"
_phase(::Codec.Restore) = "Restoring"
_phase(::Codec.Release) = "Releasing"

_valid(c::Codec.AcquisitionCursor) = c.domain > 0 && c.generation > 0 &&
    c.sequence < typemax(UInt64) && c.model_ns <= typemax(Int64)
function _follows(previous, next)
    return _valid(next) && next.domain == previous.domain &&
        next.generation == previous.generation && next.sequence >= previous.sequence &&
        next.model_ns >= previous.model_ns
end
_settled(::Codec.Immediate, previous, next) = _follows(previous, next)
_settled(r::Codec.DiscardExposures, previous, next) = _follows(previous, next) &&
    previous.sequence <= typemax(UInt64) - r.frames && next.sequence == previous.sequence + r.frames
_settled(r::Codec.ModelTime, previous, next) = _follows(previous, next) &&
    previous.model_ns <= typemax(UInt64) - r.duration_ns && next.model_ns >= previous.model_ns + r.duration_ns
function _batch_cursor(batch::Codec.Responses, cursor, plan)
    batch.valid && length(batch.values) == plan.measurements && all(isfinite, batch.values) &&
        length(batch.exposures) == plan.frames_per_probe || _invalid()
    for exposure in batch.exposures
        exposure.domain == cursor.domain && exposure.generation == cursor.generation &&
            cursor.sequence < typemax(UInt64) && exposure.sequence == cursor.sequence + 1 &&
            exposure.start_model_ns >= cursor.model_ns && exposure.duration_ns > 0 &&
            exposure.start_model_ns <= typemax(UInt64) - exposure.duration_ns || _invalid()
        cursor = Codec.AcquisitionCursor(exposure.domain, exposure.generation,
            exposure.sequence, exposure.start_model_ns + exposure.duration_ns)
    end
    _valid(cursor) || _invalid()
    return cursor
end
function _adopted(result::Codec.Adopted, previous, figure)
    result.clipped && throw(AcquisitionFailure("ProbeClipped"))
    result.figure == figure && _follows(previous, result.cursor) || _invalid()
    return result.cursor
end
function _restored(result::Codec.Restored, reference)
    !result.clipped && result.figure == reference || _invalid()
    return true
end

struct Result
    run::UInt64
    phase::String
    restoration_confirmed::Bool
    resume_permitted::Bool
    failure::Union{Nothing,String}
    recovery_failure::Union{Nothing,String}
    responses::Vector{Codec.Responses}
end
function document(result::Result)
    responses = result.phase == "complete" ? [Dict("values"=>batch.values,
        "exposures"=>Native.document(batch)["exposures"], "valid"=>batch.valid)
        for batch in result.responses] : nothing
    return Dict("version"=>1, "run"=>result.run, "phase"=>result.phase,
        "restoration_confirmed"=>result.restoration_confirmed,
        "resume_permitted"=>result.resume_permitted, "failure"=>result.failure,
        "recovery_failure"=>result.recovery_failure, "responses"=>responses)
end

include("calibration_procedure.jl")

# Enter the prepared exchange before starting the action's budget. Compiling a
# consumer/procedure specialization is cold preparation, not endpoint latency.
@noinline function _exchange!(connection, procedure, action::T, check) where {T<:Codec.Action}
    budget = _timeout(action, procedure.plan.timeouts)
    deadline = Float64(procedure.clock()) + budget / 1e9
    isfinite(deadline) || throw(ArgumentError("calibration deadline is not finite"))
    procedure.deadline = deadline
    connection.timeout_ns = budget
    answer = Native.complete!(connection, action; deadline, check, record=false)
    return answer, Float64(procedure.clock())
end

"""Acquire a plan using the event-driven `Procedure` on the caller's task.
`consume(probe, batch)` processes validated candidate responses during acquisition.
Native callbacks wake the task; no frame-count sleep advances the procedure.
Unknown transport outcomes retire the connection without another submission.
"""
function acquire!(connection::Native.Connection, input::Plan;
        cancelled=()->false, check=Client.NO_CHECK, clock=Client.monotonic,
        observe=(_...)->nothing, consume=(_...)->nothing)
    connection.run == input.run && connection.serial == 0 &&
        connection.command_count == length(input.reference) ||
        throw(ArgumentError("acquisition requires a fresh connection matching the plan"))
    procedure = Procedure(input; clock, consume, cancelled)
    while procedure.command !== nothing
        command = procedure.command
        known = false
        try
            answer, completed_at = _exchange!(connection, procedure, command.action, check)
            known = true
            observe(command.action, answer, connection.serial)
            cancelled() && cancel!(procedure)
            complete!(procedure, command.run, command.serial, answer; at=completed_at)
        catch error
            reason = !known && clock() >= procedure.deadline ?
                "TimedOut($(_phase(command.action)))" : _failure(error)
            fail!(procedure, reason; known)
        end
    end
    return something(procedure.result)
end

"Prove an explicit native binding, acquire, and always close that controller."
function acquire(binding::Native.Binding, plan::Plan; kwargs...)
    connection = Native.connect(binding, plan.run, plan.timeouts.ownership;
        command_count=length(plan.reference))
    try
        return acquire!(connection, plan; kwargs...)
    finally
        close(connection)
    end
end

end # module CalibrationAcquisition
