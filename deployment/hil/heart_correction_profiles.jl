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

const CLASSIC_RESPONSE_POLICY="normal-classic-flux-state-v1"

"""Read the independently sealed representation of the actual native thresholds."""
function read_response_thresholds(package,contract,profile::Symbol)
    descriptor(profile)
    profile===:copper && return nothing
    contract.normal_response_policy==CLASSIC_RESPONSE_POLICY || throw(ArgumentError("Classic normal response policy differs"))
    name=String(contract.flux_threshold_native_file)
    basename(name)==name && !isempty(name) || throw(ArgumentError("Classic native threshold filename differs"))
    native=joinpath(package,"heart/calibration",name)
    isfile(native) && !islink(native) && bytes2hex(open(sha256,native))==contract.flux_threshold_native_sha256 &&
        contract.runtime_inputs[name]==contract.flux_threshold_native_sha256 || throw(ArgumentError("Classic native threshold identity differs"))
    thresholds=vec(read_matrix(joinpath(package,"heart/classic-flux-thresholds.f32le"),(188,1),contract.flux_threshold_wire_sha256))
    # This qualified profile binds the unchanged native 1000-count threshold.
    all(==(1000f0),thresholds) || throw(ArgumentError("Classic qualified flux thresholds differ"))
    return thresholds
end

"""Validate normal Classic classification while preserving every raw slope.

Eligible subapertures may drop below their sealed flux threshold on any normal
science frame. The native reconstructor excludes their state-zero records.
This does not change the held calibration all-active validity rule.
"""
function normal_response(frame,profile::Symbol,active;thresholds=nothing)
    valid=response_valid(frame,profile,active)
    profile===:copper && return (;valid,dropout=Bool[])
    thresholds isa Vector{Float32} && length(thresholds)==188 && all(==(1000f0),thresholds) ||
        throw(ArgumentError("Classic normal flux thresholds differ"))
    dropout=fill(false,188)
    for index in eachindex(active)
        offset=16(index-1)
        state=Telemetry.value_at(Int32,frame.payload,offset)
        x=Telemetry.value_at(Float32,frame.payload,offset+4)
        y=Telemetry.value_at(Float32,frame.payload,offset+8)
        flux=Telemetry.value_at(Float32,frame.payload,offset+12)
        all(isfinite,(x,y,flux)) || throw(ArgumentError("nonfinite Classic normal response"))
        expected=active[index] ? Int32(flux>0 && flux>=thresholds[index]) : Int32(-1)
        state==expected || throw(ArgumentError("Classic native state differs from sealed eligibility/flux classification"))
        dropout[index]=active[index] && state==0
    end
    return (;valid,dropout)
end

mutable struct ResponseDiagnostics
    frames::UInt64
    dropout_frames::UInt64
    dropout_subaperture_samples::UInt64
    per_subaperture_dropout_frames::Vector{UInt64}
end
function ResponseDiagnostics(profile::Symbol)
    spec=descriptor(profile)
    return ResponseDiagnostics(0,0,0,zeros(UInt64,profile===:classic ? spec.gradient_rows : 0))
end
function observe_response!(diagnostics::ResponseDiagnostics,response)
    length(response.dropout)==length(diagnostics.per_subaperture_dropout_frames) || throw(ArgumentError("native response diagnostic extent differs"))
    diagnostics.frames=Base.checked_add(diagnostics.frames,UInt64(1))
    diagnostics.dropout_frames=Base.checked_add(diagnostics.dropout_frames,UInt64(any(response.dropout)))
    diagnostics.dropout_subaperture_samples=Base.checked_add(diagnostics.dropout_subaperture_samples,UInt64(count(response.dropout)))
    for index in eachindex(response.dropout)
        diagnostics.per_subaperture_dropout_frames[index]=Base.checked_add(diagnostics.per_subaperture_dropout_frames[index],UInt64(response.dropout[index]))
    end
    return nothing
end
response_diagnostics(diagnostics::ResponseDiagnostics)=(;frames=diagnostics.frames,dropout_frames=diagnostics.dropout_frames,
    dropout_subaperture_samples=diagnostics.dropout_subaperture_samples,
    per_subaperture_dropout_frames=copy(diagnostics.per_subaperture_dropout_frames))
function response_statistics(frames,profile::Symbol,active;thresholds=nothing)
    diagnostics=ResponseDiagnostics(profile)
    for frame in frames
        observe_response!(diagnostics,normal_response(frame,profile,active;thresholds))
    end
    return response_diagnostics(diagnostics)
end
function validate_response_diagnostics(frames,profile::Symbol,active,reported;thresholds=nothing)
    actual=response_statistics(frames,profile,active;thresholds)
    for key in (:frames,:dropout_frames,:dropout_subaperture_samples)
        value=getproperty(reported,key)
        value isa Integer && !(value isa Bool) && value>=0 && value==getproperty(actual,key) ||
            throw(ArgumentError("native response diagnostic $key differs"))
    end
    counts=reported.per_subaperture_dropout_frames
    length(counts)==length(actual.per_subaperture_dropout_frames) &&
        all(value->value isa Integer && !(value isa Bool) && value>=0,counts) &&
        counts==actual.per_subaperture_dropout_frames || throw(ArgumentError("native per-subaperture dropout diagnostics differ"))
    return actual
end

"""Recompute normal-correction ADC diagnostics from all retained native records.

Rail values remain part of the actual detector and truth replay. Saturation
counts are observations; exact ADC/truth replay and finite correction utility
are separate required gates. Only the declared first initialization response
may be invalid for Copper. Classic retains classified normal flux dropouts.
Calibration keeps its own stricter acceptance policy.
"""
function detector_statistics(raw_frames,response_frames,profile::Symbol,active;thresholds=nothing)
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
        valid=normal_response(response,profile,active;thresholds).valid
        profile===:classic || index==1 || valid || throw(ArgumentError("undeclared invalid native correction response"))
        invalid=Base.checked_add(invalid,UInt64(!valid))
    end
    return (;raw_available=true,adc_upper_rail=rail,frames=UInt64(length(raw_frames)),
        invalid_frames=invalid,maximum_adc=peak,upper_rail_pixels=pixels,upper_rail_frames=frames)
end

function validate_detector_diagnostics(raw_frames,response_frames,profile::Symbol,active,reported;thresholds=nothing)
    actual=detector_statistics(raw_frames,response_frames,profile,active;thresholds)
    reported.raw_available===true || throw(ArgumentError("native raw diagnostics are unavailable"))
    for key in (:adc_upper_rail,:frames,:invalid_frames,:maximum_adc,:upper_rail_pixels,:upper_rail_frames)
        value=getproperty(reported,key)
        value isa Integer && !(value isa Bool) && value>=0 && value==getproperty(actual,key) ||
            throw(ArgumentError("native detector diagnostic $key differs from retained payloads"))
    end
    return actual
end

end
