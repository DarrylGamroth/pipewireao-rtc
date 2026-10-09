"""Finite interaction acquisition on the control context; no science or session policy."""
module CalibrationAcquisition

using JSON3

import ..Common
import ..NativeCalibrationActionClient
import ..NativeCalibrationActionCodec
import ..NativeControlClient
const Native = NativeCalibrationActionClient
const Codec = NativeCalibrationActionCodec
const Client = NativeControlClient

export Plan, Timeouts, acquire!, acquire, read_plan, document, Cancelled
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
    # JSON dictionaries otherwise collapse duplicate keys. Rust's v1 plan
    # rejects them; inspect the parsed object pairs before adopting a plan.
    _unique_fields(JSON3.read(text))
    return Plan(value)
end
function _unique_fields(value::AbstractDict)
    length(Set(keys(value))) == length(value) || throw(ArgumentError("duplicate calibration plan field"))
    foreach(_unique_fields, values(value))
    return nothing
end
_unique_fields(value::AbstractVector) = (foreach(_unique_fields, value); nothing)
_unique_fields(value) = nothing

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

"""Acquire one immutable plan with one controller. Cancellation is checked at
completed action boundaries; an in-flight operation resolves within its deadline.
Unknown transport outcomes retire the connection without another submission.
Recovery uses its own restoration/ownership budgets and ignores cancellation.
`check` monitors external supervision while waiting; its failure retires transport.
"""
function acquire!(connection::Native.Connection, input::Plan;
        cancelled=()->false, check=()->nothing, clock=Client.monotonic, observe=(_...)->nothing)
    # Snapshot and preflight again: the public plan's vectors may have been edited.
    plan = Plan(input.run, input.reference, input.probes, input.measurements,
        input.frames_per_probe, input.settling, input.timeouts)
    connection.run == plan.run && connection.serial == 0 &&
        connection.command_count == length(plan.reference) ||
        throw(ArgumentError("acquisition requires a fresh connection matching the plan"))
    responses = Codec.Responses[]
    phase = "Holding"
    restoration = false
    released = false
    known = true
    failure = recovery = nothing
    action_deadline = Inf
    function request(action; recovering=false)
        if !recovering && cancelled()
            throw(Cancelled())
        end
        phase = _phase(action)
        budget = _timeout(action, plan.timeouts)
        deadline = Float64(clock()) + budget / 1e9
        isfinite(deadline) || throw(ArgumentError("calibration deadline is not finite"))
        connection.timeout_ns = budget
        action_deadline = deadline
        # An exception during submission/wait does not authorize another action.
        known = false
        result = Native.complete!(connection, action; deadline, check, record=false)
        known = true
        observe(action, result, connection.serial)
        clock() < deadline || throw(AcquisitionFailure("TimedOut($phase)"))
        return _terminal(result)
    end
    try
        held = request(Codec.Hold())
        _valid(held.cursor) || _invalid()
        cursor = held.cursor
        for (index, figure) in enumerate(plan.probes)
            probe = UInt32(index - 1)
            adopted = request(Codec.Adopt(probe, figure))
            cursor = _adopted(adopted, cursor, figure)
            settled = request(Codec.Settle(probe, cursor, plan.settling))
            _settled(plan.settling, cursor, settled.cursor) || _invalid()
            cursor = settled.cursor
            batch = request(Codec.Collect(probe, cursor, plan.measurements, plan.frames_per_probe))
            cursor = _batch_cursor(batch, cursor, plan)
            push!(responses, batch)
        end
        restoration = _restored(request(Codec.Restore(plan.reference, plan.settling)), plan.reference)
        # A cancellation during restoration cannot interrupt recovery halfway.
        cancelled() && (failure = "Cancelled")
        request(Codec.Release(); recovering=true)
        released = true
    catch error
        failure = !known && clock() >= action_deadline ? "TimedOut($phase)" : _failure(error)
        if known && phase != "Restoring" && phase != "Releasing"
            try
                restoration = _restored(request(Codec.Restore(plan.reference, plan.settling);
                    recovering=true), plan.reference)
                request(Codec.Release(); recovering=true)
                released = true
            catch error
                recovery = _failure(error)
            end
        else
            recovery = known ? failure : "Endpoint"
        end
    end
    result_phase = released ? (failure === nothing ? "complete" : "aborted") : "fault"
    return Result(plan.run, result_phase, restoration, restoration && released,
        failure, recovery, result_phase == "complete" ? responses : Codec.Responses[])
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
