"""Finite interaction acquisition on the control context; no science or session policy."""
module CalibrationAcquisition

using JSON
using Hsm: @hsmdef, @statedef, @on_initial, @on_event
import Hsm
import Clocks

import ..Common
import ..CalibrationActionClient
import ..CalibrationActionCodec
import ..ControlClient

export Plan, Timeouts, acquire!, acquire, read_plan, document, Cancelled
export Procedure, complete!, cancel!, expire!, fail!

const ActionClient = CalibrationActionClient
const Codec = CalibrationActionCodec
const Client = ControlClient

const MAX_PLAN_BYTES = 16 * 1024 * 1024
const MAX_RECORD_BYTES = 512 * 1024 * 1024

"""
    Timeouts(ownership, adoption, settling, collection, restoration)

Per-action calibration deadlines, in positive nanoseconds.

The fields bound ownership, adoption, settling, collection and restoration
actions respectively. Each value must be a positive integer representable as
`Int64`.
"""
struct Timeouts
    ownership::Int64
    adoption::Int64
    settling::Int64
    collection::Int64
    restoration::Int64
    function Timeouts(ownership, adoption, settling, collection, restoration)
        values = (ownership, adoption, settling, collection, restoration)
        checked = map(v -> Int64(ActionClient._integer(v, 1, typemax(Int64))), values)
        new(checked...)
    end
end

# Prepared figures are owned snapshots. The driver never reads a caller's mutable
# plan after Hold, and neither array axes nor instrument names encode coordinates.
"""
    Plan(run, reference, probes, measurements, frames_per_probe, settling, timeouts)

Owned finite calibration acquisition plan.

The constructor copies the reference and probe command vectors to `Float32`
storage. `run` is a positive identifier; probes, measurements and frames per
probe must be positive and bounded by the native action profile. `settling`
selects the required cursor advance, and `timeouts` supplies per-action
deadlines. The dictionary constructor accepts the version-1 plan fields used
by [`read_plan`](@ref).
"""
struct Plan{R<:Codec.AbstractRule}
    run::UInt64
    reference::Vector{Float32}
    probes::Vector{Vector{Float32}}
    measurements::UInt32
    frames_per_probe::UInt32
    settling::R
    timeouts::Timeouts
    function Plan(
        run,
        reference::AbstractVector,
        probes::AbstractVector,
        measurements,
        frames_per_probe,
        settling::R,
        timeouts::Timeouts,
    ) where {R<:Codec.AbstractRule}
        identity = ActionClient._integer(run, 1, typemax(UInt64))
        count = Int(ActionClient._integer(length(probes), 1, 16384))
        measurements = UInt32(ActionClient._integer(measurements, 1, 131072))
        frames = UInt32(ActionClient._integer(frames_per_probe, 1, 4096))
        Codec._validate(settling)
        # Check all capacities before constructing wire PODs or acquiring Hold.
        Codec.preflight_collect_reply(measurements, frames)
        reference = _figure(reference, Codec._add(8, Codec._rule_size(settling)))
        command_count = length(reference)
        # A conservative retained-payload budget, including per-probe metadata.
        # This is not a Julia heap/RSS limit or a frame-path allocation contract.
        charge =
            BigInt(count + 1) * command_count * 4 +
            BigInt(count) * (256 + BigInt(measurements) * 4 + BigInt(frames) * 40)
        charge <= MAX_RECORD_BYTES ||
            throw(ArgumentError("calibration record exceeds 512 MiB"))
        figures = Vector{Vector{Float32}}(undef, count)
        for (index, probe) in enumerate(probes)
            length(probe) == command_count ||
                throw(ArgumentError("probe command dimension differs"))
            figures[index] = _figure(probe, 24)
        end
        new{R}(identity, reference, figures, measurements, frames, settling, timeouts)
    end
end
function _figure(values::AbstractVector, overhead)
    converted = ActionClient._figure(values, overhead)
    return Float32[value for value in converted]
end
function Plan(value::AbstractDict)
    ActionClient._fields(
        value,
        (
            "version",
            "run",
            "reference",
            "probes",
            "measurements",
            "frames_per_probe",
            "settling",
            "timeouts_ns",
        ),
    )
    ActionClient._integer(value["version"], 1, 1)
    t = ActionClient._fields(
        value["timeouts_ns"],
        ("ownership", "adoption", "settling", "collection", "restoration"),
    )
    return Plan(
        value["run"],
        value["reference"],
        value["probes"],
        value["measurements"],
        value["frames_per_probe"],
        ActionClient._rule(value["settling"]),
        Timeouts(
            (
                t[k] for
                k in ("ownership", "adoption", "settling", "collection", "restoration")
            )...,
        ),
    )
end
"""
    read_plan(path)

Read a version-1 JSON calibration plan and return an owned [`Plan`](@ref).
The file is limited to 16 MiB; duplicate object keys and unknown or missing
fields are rejected. This parses a plan only and does not contact an endpoint.
"""
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
        JSON.parse(text; duplicate_keys = :error, maxdepth = 64)
    catch exception
        _plan_parse_error(exception)
    end
    return Plan(value)
end

_plan_parse_error(::JSON.DuplicateKeyError) =
    throw(ArgumentError("duplicate calibration plan field"))
_plan_parse_error(exception) = throw(exception)

"""
    Cancelled()

Exception used to request cancellation of an in-flight acquisition.

Cancellation is resolved through the acquisition procedure so restoration and
release can be observed; throwing this exception does not itself prove either
completed.
"""
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
_terminal(result::Codec.AbstractResult) = result
_terminal(result::Codec.Failed) = throw(
    AcquisitionFailure(
        ("Cancelled", "Endpoint", "InvalidEvidence", "ProbeClipped")[Int(result.reason)]
    ),
)
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

_valid(c::Codec.AcquisitionCursor) =
    c.domain > 0 &&
    c.generation > 0 &&
    c.sequence < typemax(UInt64) &&
    c.model_ns <= typemax(Int64)
function _follows(previous, next)
    return _valid(next) &&
           next.domain == previous.domain &&
           next.generation == previous.generation &&
           next.sequence >= previous.sequence &&
           next.model_ns >= previous.model_ns
end
_settled(::Codec.Immediate, previous, next) = _follows(previous, next)
_settled(r::Codec.DiscardExposures, previous, next) =
    _follows(previous, next) &&
    previous.sequence <= typemax(UInt64) - r.frames &&
    next.sequence == previous.sequence + r.frames
_settled(r::Codec.ModelTime, previous, next) =
    _follows(previous, next) &&
    previous.model_ns <= typemax(UInt64) - r.duration_ns &&
    next.model_ns >= previous.model_ns + r.duration_ns
function _batch_cursor(batch::Codec.Responses, cursor, plan)
    batch.valid &&
    length(batch.values) == plan.measurements &&
    all(isfinite, batch.values) &&
    length(batch.exposures) == plan.frames_per_probe || _invalid()
    for exposure in batch.exposures
        exposure.domain == cursor.domain &&
        exposure.generation == cursor.generation &&
        cursor.sequence < typemax(UInt64) &&
        exposure.sequence == cursor.sequence + 1 &&
        exposure.start_model_ns >= cursor.model_ns &&
        exposure.duration_ns > 0 &&
        exposure.start_model_ns <= typemax(UInt64) - exposure.duration_ns || _invalid()
        cursor = Codec.AcquisitionCursor(
            exposure.domain,
            exposure.generation,
            exposure.sequence,
            exposure.start_model_ns + exposure.duration_ns,
        )
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
"""
    document(result)

Return the version-1 JSON-compatible report for an acquisition result. The
`responses` field contains values and exposure records only for a completed
acquisition; it is `nothing` for other phases. A report does not establish
endpoint readiness or resume permission beyond the recorded Boolean fields.
"""
function document(result::Result)
    responses =
        result.phase == "complete" ?
        [
            Dict(
                "values" => batch.values,
                "exposures" => ActionClient.document(batch)["exposures"],
                "valid" => batch.valid,
            ) for batch in result.responses
        ] : nothing
    return Dict(
        "version" => 1,
        "run" => result.run,
        "phase" => result.phase,
        "restoration_confirmed" => result.restoration_confirmed,
        "resume_permitted" => result.resume_permitted,
        "failure" => result.failure,
        "recovery_failure" => result.recovery_failure,
        "responses" => responses,
    )
end

include("procedure.jl")

# Enter the prepared exchange before starting the action's budget. Compiling a
# consumer/procedure specialization is cold preparation, not endpoint latency.
@noinline function _exchange!(
    connection, procedure, action::T, check, clock::Clocks.AbstractNanoClock
) where {T<:Codec.AbstractAction}
    budget = _timeout(action, procedure.plan.timeouts)
    at = Clocks.time_nanos(clock)::Int64
    Clocks.update!(procedure.clock, at)
    _now!(procedure, at) === nothing && throw(AcquisitionFailure("Invalid monotonic clock"))
    deadline = Base.Checked.checked_add(at, budget)
    procedure.deadline = deadline
    connection.timeout_ns = budget
    answer = ActionClient.complete!(connection, action; deadline, check, record = false)
    received = Clocks.time_nanos(clock)::Int64
    Clocks.update!(procedure.clock, received)
    return answer, received
end

"""
    acquire!(connection, input; kwargs...)

Acquire a plan using the event-driven `Procedure` on the caller's task.
`consume(probe, batch)` processes validated candidate responses during acquisition.
Native callbacks wake the task; no frame-count sleep advances the procedure.
Unknown transport outcomes retire the connection without another submission.
"""
function acquire!(
    connection::ActionClient.Connection,
    input::Plan;
    cancelled = () -> false,
    check = Client.NO_CHECK,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
    observe = (_...) -> nothing,
    consume = (_...) -> nothing,
)
    connection.run == input.run &&
    connection.serial == 0 &&
    connection.command_count == length(input.reference) ||
        throw(ArgumentError("acquisition requires a fresh connection matching the plan"))
    cached = Clocks.CachedNanoClock(Clocks.time_nanos(clock))
    procedure = Procedure(input; clock = cached, consume, cancelled)
    while procedure.command !== nothing
        command = procedure.command
        known = false
        try
            answer, completed_at = _exchange!(
                connection, procedure, command.action, check, clock
            )
            known = true
            observe(command.action, answer, connection.serial)
            cancelled() && cancel!(procedure)
            complete!(procedure, command.run, command.serial, answer; at = completed_at)
        catch error
            received =
                known ? Clocks.time_nanos(cached)::Int64 : Clocks.time_nanos(clock)::Int64
            Clocks.update!(cached, received)
            reason =
                !known && received >= procedure.deadline ?
                "TimedOut($(_phase(command.action)))" : _failure(error)
            fail!(procedure, reason; known)
        end
    end
    return something(procedure.result)
end

"""
    acquire(binding, plan; kwargs...)

Prove an explicit native binding, acquire, and always close that controller.
"""
function acquire(binding::ActionClient.Binding, plan::Plan; kwargs...)
    connection = ActionClient.connect(
        binding, plan.run, plan.timeouts.ownership; command_count = length(plan.reference)
    )
    try
        return acquire!(connection, plan; kwargs...)
    finally
        close(connection)
    end
end

end # module CalibrationAcquisition
