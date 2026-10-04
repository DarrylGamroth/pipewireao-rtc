include("heart_classic_projection.jl")
include("heart_correction_flags.jl")
"""Profile contracts for retained native correction evidence.

These describe native representations and configured recurrences. They do not
authorize a candidate inverse or replace either native measurement operator.
"""
module HeartCorrectionProfiles

using SHA
import ..HeartCalibrationTelemetry, ..HeartCorrectionTelemetry, ..HeartClassicProjection, ..HeartCorrectionFlags
const Telemetry=HeartCalibrationTelemetry
const CorrectionTelemetry=HeartCorrectionTelemetry
const Flags=HeartCorrectionFlags
const DETECTOR_ACCEPTANCE_POLICY="normal-correction-adc-bounded-replay-v1"

function descriptor(profile::Symbol)
    profile===:copper && return (;profile,frame_output=:pwfs_frame,width=64,measurements=3600,coordinates=253,
        gradient_datatype=8,gradient_rows=3600,telemetry_max_bytes=UInt64(16*1024*1024),adc_bits=14,ingress="deferred",gain=0.01,pole=0.99,sign=-1)
    profile===:classic && return (;profile,frame_output=:shwfs_frame,width=352,measurements=376,coordinates=277,
        gradient_datatype=13,gradient_rows=188,telemetry_max_bytes=UInt64(128*1024*1024),adc_bits=12,ingress="streaming",gain=-0.3,pole=0.99,sign=1)
    throw(ArgumentError("unsupported native correction profile"))
end

function streams(profile::Symbol,frames::Int)
    0<frames<=256 || throw(ArgumentError("native correction frame count differs"))
    spec=descriptor(profile)
    return (("cbHoPixelsRaw0",7,(spec.width,spec.width),frames),
        ("cbHoPixelsCalib0",8,(spec.width,spec.width),frames),
        ("cbHoGrad0",spec.gradient_datatype,(spec.gradient_rows,1),frames),
        ("cbClUnclipped0",16,(spec.coordinates,1),frames),
        ("cbDmCmd0",20,(277,1),frames+2))
end

"""Largest declared phase file, including all fixed headers and aligned payloads."""
function required_file_budget(profile::Symbol,frames::Int)
    requirements=map(streams(profile,frames)) do (tag,datatype,shape,count)
        element=datatype==7 ? 2 : datatype==13 ? 16 : 4
        payload=cld(prod(shape)*element,64)*64
        # Active DM has F records; its two RUN records reside in other files.
        records=tag=="cbDmCmd0" ? frames : count
        UInt64(1024+records*(64+payload))
    end
    return maximum(requirements)
end

function read_matrix(path,shape,hash)
    isfile(path) && !islink(path) && filesize(path)==4prod(shape) &&
        bytes2hex(open(sha256,path))==hash || throw(ArgumentError("native wire matrix extent or identity differs"))
    words=ltoh.(reinterpret(UInt32,read(path)))
    matrix=Matrix(permutedims(reshape(reinterpret(Float32,words),reverse(shape))))
    all(isfinite,matrix) || throw(ArgumentError("nonfinite native wire matrix"))
    return matrix
end

function read_active(path,hash)
    isfile(path) && !islink(path) && filesize(path)==188 && bytes2hex(open(sha256,path))==hash ||
        throw(ArgumentError("Classic active eligibility extent or identity differs"))
    bytes=read(path)
    all(value->value in (0,1),bytes) && any(==(1),bytes) || throw(ArgumentError("Classic active eligibility must contain zero/one bytes"))
    return Vector{Bool}(bytes .== 1)
end

const sparse_extrapolation=HeartClassicProjection.sparse_extrapolation

function projection(options,contract)
    spec=descriptor(options.profile)
    P=read_matrix(options.heart_projection,(277,spec.coordinates),contract.projection_wire_sha256)
    options.profile===:copper && return P
    E=read_matrix(joinpath(dirname(options.heart_projection),"native-extrapolation.f32le"),(277,277),contract.extrapolation_wire_sha256)
    # The qualified Classic source has no VDM_TO_PDM_FILE and executes the
    # native same-sized copy after E. This identity is a representation proof.
    contract.projection_native_file===nothing && contract.physical_projection_mode=="native-default-copy" ||
        throw(ArgumentError("Classic physical projection contract differs"))
    all(reinterpret(UInt32,P[row,column])==(row==column ? UInt32(0x3f800000) : UInt32(0)) for row in 1:277,column in 1:277) ||
        throw(ArgumentError("Classic default native physical projection is not identity"))
    return CorrectionTelemetry.ZonalProjection(E,P)
end

function response_valid(frame,profile::Symbol,active)
    profile===:copper && return Telemetry.copper_response(frame).valid
    descriptor(profile)
    active isa Vector{Bool} && length(active)==188 && any(active) || throw(ArgumentError("Classic active eligibility differs"))
    for index in eachindex(active)
        active[index] || Telemetry.value_at(Int32,frame.payload,16(index-1))==-1 ||
            throw(ArgumentError("native Classic disabled subaperture reactivated"))
    end
    # Raw inactive slopes are retained. The admitted selected inverse must have
    # exact positive-zero coefficients in those disabled measurement columns.
    return Telemetry.classic_response(frame;order=collect(1:188),scale=(1.0,1.0),active).valid
end

"""Recompute normal-correction ADC diagnostics from all retained native records.

Rail values remain part of the actual detector and truth replay. Saturation
counts are observations; exact ADC/truth replay and finite correction utility
are separate required gates. Only the declared first initialization response
may be invalid. Calibration keeps its own stricter acceptance policy.
"""
function detector_statistics(raw_frames,response_frames,profile::Symbol,active)
    spec=descriptor(profile)
    length(raw_frames)==length(response_frames) && 0<length(raw_frames)<=256 ||
        throw(ArgumentError("native detector record counts differ"))
    rail=UInt16(2^spec.adc_bits-1)
    peak=UInt16(0);pixels=UInt64(0);frames=UInt64(0);invalid=UInt64(0)
    for (index,(raw,response)) in enumerate(zip(raw_frames,response_frames))
        (raw.spec.datatype,raw.spec.rows,raw.spec.columns)==(7,spec.width,spec.width) ||
            throw(ArgumentError("native raw detector extent differs"))
        values=Telemetry.raw_pixels(raw)
        maximum(values)<=rail || throw(ArgumentError("native detector exceeds declared ADC rail"))
        peak=max(peak,maximum(values))
        hits=UInt64(count(==(rail),values))
        pixels=Base.checked_add(pixels,hits);frames=Base.checked_add(frames,UInt64(hits>0))
        valid=response_valid(response,profile,active)
        index==1 || valid || throw(ArgumentError("undeclared invalid native correction response"))
        invalid=Base.checked_add(invalid,UInt64(!valid))
    end
    return (;raw_available=true,adc_upper_rail=rail,frames=UInt64(length(raw_frames)),
        invalid_frames=invalid,maximum_adc=peak,upper_rail_pixels=pixels,upper_rail_frames=frames)
end

function validate_detector_diagnostics(raw_frames,response_frames,profile::Symbol,active,reported)
    actual=detector_statistics(raw_frames,response_frames,profile,active)
    reported.raw_available===true || throw(ArgumentError("native raw diagnostics are unavailable"))
    for key in (:adc_upper_rail,:frames,:invalid_frames,:maximum_adc,:upper_rail_pixels,:upper_rail_frames)
        value=getproperty(reported,key)
        value isa Integer && !(value isa Bool) && value>=0 && value==getproperty(actual,key) ||
            throw(ArgumentError("native detector diagnostic $key differs from retained payloads"))
    end
    return actual
end

end
