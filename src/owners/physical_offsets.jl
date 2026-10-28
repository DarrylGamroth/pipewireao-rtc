"""Calibrated held physical-mirror contributions (RTC-DEV-037)."""
module PhysicalOffsets

using LinearAlgebra
using PipeWireAO: AcquisitionIdentity
using ..Common, ..Artifacts
import ..DeploymentConfiguration

public Calibration, Contribution, Receiver, arm!, disarm!, observe_clock!, accept!, expire!, total!, with_receiver

"Cold, owned physical projection and branch authority; commands and coefficients are metres OPD."
struct Calibration
    identity::String
    schema::String
    command_order::String
    P::Matrix{Float32}
    Q::Matrix{Float32}
    modes::Vector{Int}
    command_limit_m::Float32
    coefficient_limit_m::Float32
    span_rtol::Float64
    max_age_ns::Int64
    silence_ns::UInt64
end

function Calibration(;identity, schema, command_order, projection, inverse, modes,
        command_limit_m, coefficient_limit_m, max_age_ns, silence_ns, span_rtol=1e-5)
    all(x -> x isa AbstractString && !isempty(x), (identity,schema,command_order)) ||
        throw(ArgumentError("physical offsets require calibration, schema and command-order identities"))
    P, Q = Matrix{Float32}(projection), Matrix{Float32}(inverse)
    n,m = size(P)
    n > 0 && m > 0 && size(Q) == (m,n) && all(isfinite,P) && all(isfinite,Q) ||
        throw(ArgumentError("invalid finite physical projection or left inverse"))
    modes isa AbstractVector && !isempty(modes) && all(i -> i isa Integer && !(i isa Bool) && 1<=i<=m,modes) &&
        length(unique(modes))==length(modes) || throw(ArgumentError("invalid explicit branch mode authority"))
    all(x -> x isa Real && isfinite(x) && x>0, (command_limit_m,coefficient_limit_m,span_rtol)) &&
        span_rtol < 1 || throw(ArgumentError("physical offset limits must be finite positive values"))
    max_age_ns isa Integer && !(max_age_ns isa Bool) && 0 < max_age_ns <= typemax(Int64) &&
        silence_ns isa Integer && !(silence_ns isa Bool) && 0 < silence_ns <= typemax(UInt64) ||
        throw(ArgumentError("physical offsets require positive bounded time limits"))
    norm(Float64.(Q)*Float64.(P)-I) <= span_rtol*sqrt(m) ||
        throw(ArgumentError("physical inverse does not recover calibrated modes"))
    limits = Float32.((command_limit_m,coefficient_limit_m))
    all(x -> isfinite(x) && x>0,limits) || throw(ArgumentError("limits are not representable Float32"))
    return Calibration(String(identity),String(schema),String(command_order),P,Q,Int.(modes),
        limits...,Float64(span_rtol),Int64(max_age_ns),UInt64(silence_ns))
end

mutable struct Contribution
    const calibration::Calibration
    const value::Vector{Float32}
    identity::Union{Nothing,AcquisitionIdentity}
    last_sequence::UInt64
    end_ns::Int64
    arrived_ns::UInt64
    armed::Bool
    present::Bool
    reason::Symbol
end
Contribution(calibration::Calibration) = Contribution(calibration,zeros(Float32,size(calibration.P,1)),
    nothing,0,0,0,false,false,:startup)

"Single serialized control-task state. Native frame callbacks never access or mutate it."
mutable struct Receiver
    const branches::Dict{Symbol,Contribution}
    const command_limit_m::Float32
    clock_identity::Union{Nothing,AcquisitionIdentity}
    clock_end_ns::Int64
    revision::UInt64
end
function Receiver(calibrations::NamedTuple; command_limit_m)
    isempty(calibrations) && throw(ArgumentError("physical offsets require at least one branch"))
    all(x -> x isa Calibration,calibrations) || throw(ArgumentError("invalid branch calibration"))
    first_calibration = first(calibrations)
    modes = Int[]
    for c in calibrations
        c.identity == first_calibration.identity && c.command_order == first_calibration.command_order &&
            c.P == first_calibration.P && c.Q == first_calibration.Q ||
            throw(ArgumentError("branches must share exactly one projection, inverse and calibration identity"))
        append!(modes,c.modes)
    end
    length(unique(modes)) == length(modes) || throw(ArgumentError("physical branch authorities overlap"))
    limit = Float32(command_limit_m)
    isfinite(limit) && limit > 0 || throw(ArgumentError("invalid total physical offset limit"))
    return Receiver(Dict(name=>Contribution(c) for (name,c) in pairs(calibrations)),limit,nothing,0,0)
end

function limit_violation(receiver::Receiver,combined)
    maximum(abs,combined)<=receiver.command_limit_m || return :total_limit
    coefficients = first(values(receiver.branches)).calibration.Q*combined
    for contribution in values(receiver.branches)
        authority = contribution.calibration
        maximum(i -> abs(coefficients[i]),authority.modes)<=authority.coefficient_limit_m ||
            return :total_coefficient_limit
    end
    return nothing
end

function disarm!(receiver::Receiver, branch::Symbol; reason::Symbol=:disarmed)
    contribution = receiver.branches[branch]
    changed = contribution.armed || contribution.present || any(!iszero,contribution.value)
    fill!(contribution.value,0)
    contribution.armed = contribution.present = false
    contribution.reason = reason
    if changed
        violation = limit_violation(receiver,total!(zeros(Float32,length(contribution.value)),receiver))
        if violation!==nothing
            # Withdrawal can remove a cancelling command or tolerated mode
            # leakage. No intermediate unsafe remainder is ever submitted.
            for other in values(receiver.branches)
                other===contribution && continue
                fill!(other.value,0)
                other.armed = other.present = false
                other.reason = violation
            end
        end
    end
    changed && (receiver.revision = Base.checked_add(receiver.revision,UInt64(1)))
    return receiver
end
function disarm!(receiver::Receiver; reason::Symbol=:disarmed)
    for branch in keys(receiver.branches)
        disarm!(receiver,branch;reason)
    end
    return receiver
end

"Explicitly bind a stopped/reset branch to a source cohort; rearming always begins at zero."
function arm!(receiver::Receiver, branch::Symbol, identity::AcquisitionIdentity)
    identity.generation>0 && identity.sequence==0 ||
        throw(ArgumentError("arming requires positive generation and sequence zero"))
    receiver.clock_identity === nothing && throw(ArgumentError("upstream model clock is not admitted"))
    disarm!(receiver,branch;reason=:armed)
    contribution = receiver.branches[branch]
    contribution.identity = identity
    contribution.last_sequence = 0
    contribution.end_ns = 0
    contribution.arrived_ns = 0
    contribution.armed = true
    return receiver
end

same_cohort(a,b) = a.domain==b.domain && a.generation==b.generation
function exposure_end(pts,duration)
    pts isa Int64 && duration isa UInt64 && pts>=0 && duration>0 && duration<=typemax(Int64) ||
        throw(ArgumentError("invalid model exposure interval"))
    return Base.checked_add(pts,Int64(duration))
end

"Observe actual upstream acquisition time; a changed cohort clears every downstream contribution."
function observe_clock!(receiver::Receiver, identity::AcquisitionIdentity, pts::Int64, duration::UInt64)
    endpoint = exposure_end(pts,duration)
    identity.generation>0 && identity.sequence>0 || throw(ArgumentError("invalid upstream clock identity"))
    previous = receiver.clock_identity
    if previous !== nothing
        if !same_cohort(previous,identity)
            disarm!(receiver;reason=:upstream_cohort)
        elseif identity.sequence<=previous.sequence || endpoint<receiver.clock_end_ns
            disarm!(receiver;reason=:upstream_clock)
            return false
        end
    end
    receiver.clock_identity = identity
    receiver.clock_end_ns = endpoint
    return true
end

"Validate and hold one complete absolute command. Rejection clears this branch and requires rearming."
function accept!(receiver::Receiver, branch::Symbol, values::AbstractVector{Float32},
        identity::AcquisitionIdentity, pts::Int64, duration::UInt64;
        now_ns::UInt64, schema::AbstractString, calibration_identity::AbstractString,
        command_order::AbstractString)
    Base.require_one_based_indexing(values)
    c = receiver.branches[branch]
    c.armed || return false
    function reject(reason)
        disarm!(receiver,branch;reason)
        return false
    end
    calibration = c.calibration
    schema == calibration.schema && calibration_identity == calibration.identity &&
        command_order == calibration.command_order || return reject(:contract)
    same_cohort(something(c.identity),identity) && identity.sequence>c.last_sequence ||
        return reject(:source_cohort)
    length(values)==length(c.value) && all(isfinite,values) || return reject(:payload)
    maximum(abs,values)<=calibration.command_limit_m || return reject(:command_limit)
    endpoint = try exposure_end(pts,duration) catch; return reject(:interval); end
    pts>=c.end_ns && endpoint<=receiver.clock_end_ns &&
        receiver.clock_end_ns-endpoint<=calibration.max_age_ns || return reject(:model_age)
    c.present && now_ns<c.arrived_ns && return reject(:monotonic_clock)
    coefficients = calibration.Q*values
    projected = calibration.P*coefficients
    scale = norm(Float64.(values))
    # The absolute floor is only Float32 rounding at this vector's scale, never a
    # fixed physical tolerance that could admit a small arbitrary command.
    norm(Float64.(projected)-values) <= calibration.span_rtol*scale || return reject(:physical_span)
    maximum(abs,coefficients)<=calibration.coefficient_limit_m || return reject(:coefficient_limit)
    outside = setdiff(axes(coefficients,1),calibration.modes)
    norm(Float64.(coefficients[outside])) <= calibration.span_rtol*norm(Float64.(coefficients)) ||
        return reject(:mode_authority)
    # Use the same Float32 addition order as total!: tolerable leakage from an
    # otherwise disjoint branch must not enlarge another branch's mode limit.
    combined = zeros(Float32,length(values))
    for other in Base.values(receiver.branches)
        combined .+= other===c ? values : other.value
    end
    violation = limit_violation(receiver,combined)
    violation===nothing || return reject(violation)
    copyto!(c.value,values)
    c.last_sequence = identity.sequence
    c.end_ns, c.arrived_ns = endpoint,now_ns
    c.present = true
    c.reason = :accepted
    receiver.revision = Base.checked_add(receiver.revision,UInt64(1))
    return true
end

"Clear stale branches using separate monotonic silence and upstream model-age limits."
function expire!(receiver::Receiver, now_ns::UInt64)
    for (branch,c) in receiver.branches
        c.armed && c.present || continue
        if now_ns<c.arrived_ns || now_ns-c.arrived_ns>c.calibration.silence_ns
            disarm!(receiver,branch;reason=:silence)
        elseif receiver.clock_end_ns-c.end_ns>c.calibration.max_age_ns
            disarm!(receiver,branch;reason=:model_age)
        end
    end
    return receiver
end
function total!(destination::AbstractVector{Float32},receiver::Receiver)
    Base.require_one_based_indexing(destination)
    length(destination)==length(first(values(receiver.branches)).value) ||
        throw(DimensionMismatch("physical offset destination differs from command order"))
    fill!(destination,0)
    for c in values(receiver.branches)
        destination .+= c.value
    end
    return destination
end

"Run a native array receiver within the existing graph-owner lifecycle (optional HIL extension)."
function with_receiver end

"Prepare and verify receiver calibration against a concrete ordinary graph before publication."
function prepare end

"Compose a bounded upstream model-clock observer with the existing graph observer."
function frame_observer end

include("physical_offset_configuration.jl")

end
