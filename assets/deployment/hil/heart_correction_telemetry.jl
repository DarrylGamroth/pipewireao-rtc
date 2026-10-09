module HeartCorrectionTelemetry

using SHA
import ..HeartCalibrationTelemetry
const Telemetry = HeartCalibrationTelemetry

"""Open the public full-rate Copper closed-loop VDM telemetry file.

Datatype 16 is the native Float32 active virtual-actuator representation. This
separate decoder preserves the sealed calibration reader used by the cohort.
"""
function vdm_reader(path; tag::String, maximum_bytes::UInt64, coordinates::Int=253)
    coordinates in (253,277) || throw(ArgumentError("unsupported native VDM coordinate count"))
    data_bytes = cld(4coordinates,64)*64
    ENDIAN_BOM == 0x04030201 || throw(ArgumentError("VDM telemetry requires a little-endian host"))
    maximum_bytes >= 1024 && !islink(path) || throw(ArgumentError("invalid VDM telemetry input"))
    io = open(path, "r")
    try
        metadata = stat(io)
        isfile(metadata) && 1024 <= metadata.size <= maximum_bytes ||
            throw(ArgumentError("VDM telemetry header is incomplete or exceeds its bound"))
        header = read(io, 1024)
        nul = findfirst(iszero, @view header[1:32])
        nul !== nothing && String(header[1:nul-1]) == tag || throw(ArgumentError("VDM telemetry tag differs"))
        at(T, offset) = Telemetry.value_at(T, header, offset)
        at(Int32, 40) == 16 && (at(UInt32, 48), at(UInt32, 52)) == (coordinates, 1) &&
            at(Float64, 32) == 4 && at(UInt32, 60) == 0 && at(UInt32, 56) == data_bytes ||
            throw(ArgumentError("VDM telemetry must match the declared row-major Float32 coordinates"))
        spec = Telemetry.TelemetrySpec(tag, Int32(16), coordinates, 1, 4, data_bytes)
        return Telemetry.TelemetryReader(io, spec, UInt64(metadata.device), UInt64(metadata.inode),
            maximum_bytes, UInt64(metadata.size), UInt64(0), nothing, false)
    catch
        close(io)
        rethrow()
    end
end

"""Decode one serialized controller update without assigning an exposure sync.

Native CLWC writes this CB with a null header, retaining its creation sync.
The caller must also prove exactly one controller update and one positive-sync
physical DM record for the admitted exposure.
"""
function vdm_values(frame, exposure_sequence::UInt64; coordinates::Int=253)
    coordinates in (253,277) || throw(ArgumentError("unsupported native VDM coordinate count"))
    exposure_sequence > 0 || throw(ArgumentError("VDM association requires a positive exposure"))
    frame.spec.datatype == 16 && (frame.spec.rows, frame.spec.columns) == (coordinates, 1) ||
        throw(ArgumentError("VDM representation differs"))
    Telemetry.require_complete(frame)
    frame.progress == frame.required == 0 && frame.sync == 0 &&
        frame.bucket == exposure_sequence - 1 || throw(ArgumentError("serialized VDM bucket differs"))
    values = [Telemetry.value_at(Float32, frame.payload, 4(index-1)) for index in 1:coordinates]
    all(isfinite, values) || throw(ArgumentError("nonfinite native VDM demand"))
    return values
end

"""The two actual zonal maps used after the native integrator.

Classic cbClUnclipped stores the padded integrated VDM vector before native E.
Retaining E and P separately preserves the two Float32 operations in the
independent demand bound; a pre-multiplied P*E cannot prove those roundings.
"""
struct ZonalProjection
    extrapolation::Matrix{Float32}
    physical::Matrix{Float32}
    function ZonalProjection(extrapolation::Matrix{Float32},physical::Matrix{Float32})
        size(extrapolation)==size(physical)==(277,277) || throw(DimensionMismatch("Classic zonal maps must be 277 by 277"))
        all(isfinite,extrapolation) && all(isfinite,physical) || throw(ArgumentError("nonfinite Classic zonal maps"))
        new(extrapolation,physical)
    end
end

function stage_bound(matrix::Matrix{Float32},values::Vector{Float64},input_bound::Vector{Float64})
    size(matrix,2)==length(values)==length(input_bound) || throw(DimensionMismatch("native projection stage differs"))
    operations=2size(matrix,2)
    gamma32=operations*2.0^-24/(1-operations*2.0^-24)
    gamma64=operations*2.0^-53/(1-operations*2.0^-53)
    demanded=zeros(Float64,size(matrix,1));bounds=similar(demanded)
    for row in axes(matrix,1)
        absolute_sum=0.0; propagated=0.0
        for column in axes(matrix,2)
            coefficient=Float64(matrix[row,column])
            product=coefficient*values[column]
            isfinite(Float32(product)) && (iszero(product) || abs(product)>=Float64(floatmin(Float32))) ||
                throw(ArgumentError("native zonal projection has an overflowing or subnormal product"))
            absolute_sum+=abs(product)
            propagated+=abs(coefficient)*input_bound[column]
            demanded[row]+=product
        end
        # Propagate the preceding native stage's error, then bound this stage's
        # Float32 arithmetic and the independent Float64 diagnostic sum.
        bounds[row]=propagated+(gamma32+gamma64)*(absolute_sum+propagated)
        isfinite(demanded[row]) && isfinite(bounds[row]) || throw(ArgumentError("nonfinite native zonal demand bound"))
    end
    return demanded,bounds
end

function projection_witness(projection::ZonalProjection,vdm::Vector{Float32},received::Vector{Float32};limit_um::Float32=0.8f0)
    length(vdm)==length(received)==277 || throw(DimensionMismatch("Classic correction demand extents differ"))
    all(isfinite,vdm) && all(isfinite,received) && isfinite(limit_um) && limit_um>0 || throw(ArgumentError("nonfinite Classic demand"))
    extrapolated,extrapolation_bound=stage_bound(projection.extrapolation,Float64.(vdm),zeros(Float64,277))
    demanded,bounds=stage_bound(projection.physical,extrapolated,extrapolation_bound)
    for index in eachindex(demanded,received,bounds)
        abs(demanded[index])+bounds[index]<Float64(limit_um) || throw(ArgumentError("native demanded figure cannot prove no clipping"))
        abs(Float64(received[index])-demanded[index])<=bounds[index] || throw(ArgumentError("native physical receipt differs from retained E and P demand"))
    end
    return (;demanded_um=demanded,error_bound_um=bounds,demanded_max_abs_um=maximum(abs,demanded),
        maximum_error_bound_um=maximum(bounds),limit_um,clipping_excluded=true,
        vdm_sha256=bytes2hex(sha256(reinterpret(UInt8,vdm))),received_sha256=bytes2hex(sha256(reinterpret(UInt8,received))),
        qualification="serialized padded native VDM followed by separate E and P Float32 error bounds; runtime additive terms require separate ACK/config proof")
end

"""Bound native Float32 projection error and require an unclipped physical figure.

The supplied P is the actual retained Float32 native projection. The active
owner separately proves that flat, offsets, disturbances, dither and feedback
terms are disabled or zero. This check cannot authorize those runtime flags.
The bound covers any ordering of Float32 products and additions (including
FMA); nonzero subnormal products and overflow are rejected. It is a numerical
consistency and no-clipping witness, not a replacement controller calculation.
"""
function projection_witness(projection::Matrix{Float32}, vdm::Vector{Float32},
    received::Vector{Float32}; limit_um::Float32=0.8f0)
    size(projection) == (277,253) && length(vdm) == 253 && length(received) == 277 ||
        throw(DimensionMismatch("Copper correction projection extents differ"))
    all(isfinite, projection) && all(isfinite, vdm) && all(isfinite, received) &&
        isfinite(limit_um) && limit_um > 0 || throw(ArgumentError("nonfinite correction projection"))
    unit32 = 2.0^-24
    operations = 2size(projection,2)
    gamma32 = operations*unit32/(1-operations*unit32)
    unit64 = 2.0^-53
    gamma64 = operations*unit64/(1-operations*unit64)
    demanded = zeros(Float64,277)
    bounds = zeros(Float64,277)
    for row in axes(projection,1)
        absolute_sum = 0.0
        for column in axes(projection,2)
            product = Float64(projection[row,column])*Float64(vdm[column])
            product32 = Float32(product)
            isfinite(product32) && (iszero(product) || abs(product) >= Float64(floatmin(Float32))) ||
                throw(ArgumentError("projection has an overflowing or subnormal product"))
            absolute_sum += abs(product)
            demanded[row] += product
        end
        # Also cover rounding in this independent Float64 diagnostic sum.
        bounds[row] = (gamma32+gamma64)*absolute_sum
        abs(demanded[row]) + bounds[row] < Float64(limit_um) ||
            throw(ArgumentError("native demanded figure cannot prove no clipping"))
        abs(Float64(received[row])-demanded[row]) <= bounds[row] ||
            throw(ArgumentError("native physical receipt differs from the retained VDM projection"))
    end
    return (; demanded_um=demanded, error_bound_um=bounds,
        demanded_max_abs_um=maximum(abs,demanded), maximum_error_bound_um=maximum(bounds),
        limit_um, clipping_excluded=true,
        vdm_sha256=bytes2hex(sha256(reinterpret(UInt8,vdm))),
        received_sha256=bytes2hex(sha256(reinterpret(UInt8,received))),
        qualification="serialized native VDM/projection witness; runtime additive terms require separate ACK/config proof")
end

end
