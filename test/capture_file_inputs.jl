# Shared deterministic inputs for finite capture tests and legacy-data generation.
using Test, SHA, PipeWireAORTC
import PipeWireAO
const CaptureFiles = PipeWireAORTC.CaptureFiles
const CaptureActions = PipeWireAORTC.CalibrationActionCodec
const CaptureClock = PipeWireAORTC.ControlClient
@assert isdefined(CaptureFiles, :CaptureStore)

const capture_contract = CaptureFiles.Contract((;
    raw = CaptureFiles.Channel(
        PipeWireAO.NdArrayFormat(
            PipeWireAO.NdArray.U16_LE,
            (352, 352);
            layout = PipeWireAO.NdArray.ROW_MAJOR,
            rate = PipeWireAO.SPA.Fraction(500, 1),
        ),
        "detector-adu",
    ),
    slopes = CaptureFiles.Channel(
        PipeWireAO.NdArrayFormat(
            PipeWireAO.NdArray.F32_LE,
            (188, 2);
            layout = PipeWireAO.NdArray.ROW_MAJOR,
            rate = PipeWireAO.SPA.Fraction(500, 1),
        ),
        "wfs-slopes",
    ),
    flux = CaptureFiles.Channel(
        PipeWireAO.NdArrayFormat(
            PipeWireAO.NdArray.F32_LE,
            (188,);
            layout = PipeWireAO.NdArray.ROW_MAJOR,
            rate = PipeWireAO.SPA.Fraction(500, 1),
        ),
        "wfs-flux",
    ),
    validity = CaptureFiles.Channel(
        PipeWireAO.NdArrayFormat(
            PipeWireAO.NdArray.BOOL8,
            (188,);
            layout = PipeWireAO.NdArray.ROW_MAJOR,
            rate = PipeWireAO.SPA.Fraction(500, 1),
        ),
        "wfs-validity",
    ),
))

const capture_settings = Dict{String,Any}(
    "profile" => "classic",
    "simulation_graph" => "internal-source",
    "graph_sha256" => repeat("a", 64),
    "mask_sha256" => repeat("b", 64),
    "source_magnitude" => 2.0,
    "exposure_ns" => 2000000,
    "photon_noise" => true,
    "readout_noise" => true,
    "adc_bits" => 12,
)
const capture_domain = PipeWireAO.AcquisitionDomain(ntuple(index -> UInt8(index), 16))
const capture_generation = UInt64(2)^53 + 7
const capture_coordinator_domain = UInt64(2)^53 + 11
capture_cursor(sequence = 0, model = 0) = CaptureActions.AcquisitionCursor(
    capture_coordinator_domain, capture_generation, UInt64(sequence), UInt64(model)
)

function capture_file_receipt(
    identity,
    model,
    duration;
    optical = nothing,
    trigger = nothing,
    timing = PipeWireAO.ExposureTiming(; duration_nanoseconds = duration),
    reference_timestamp = PipeWireAO.ReferenceTimestamp(1_730_000_000_000_000_123),
)
    header = PipeWireAO.BufferHeader(
        UInt32(0), UInt32(0), Int64(-17), Int64(-2), identity.sequence + UInt64(100)
    )
    requirements = (
        PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_HEADER),
        PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_ACQUISITION_IDENTITY),
        PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_EXPOSURE_TIMING),
        PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_REFERENCE_TIMESTAMP),
        PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_OPTICAL_CHOPPING),
        PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_ELECTRICAL_TRIGGER),
    )
    records = PipeWireAO.MetadataSnapshot(requirements)
    writable = PipeWireAO.writable_metadata_records(records)
    PipeWireAO.set_buffer_header!(writable, header)
    PipeWireAO.set_acquisition_identity!(writable, identity)
    PipeWireAO.set_exposure_timing!(writable, timing)
    PipeWireAO.set_reference_timestamp!(writable, reference_timestamp)
    optical === nothing || PipeWireAO.set_optical_classification!(writable, optical)
    trigger === nothing || PipeWireAO.set_trigger_classification!(writable, trigger)
    return (;
        identity,
        model_start_ns = Int64(model),
        duration_ns = UInt64(duration),
        header,
        optical_classification = optical,
        trigger_classification = trigger,
        exposure_timing = timing,
        reference_timestamp,
        records,
    )
end

function capture_source(;
    start = capture_cursor(),
    fail = 0,
    metadata_change = identity,
    duration = 2000000,
    period = duration,
)
    count = Ref(0)
    function acquire()
        count[] += 1
        count[] == fail && error("interrupted acquisition")
        sequence = start.sequence + UInt64(count[])
        model = start.model_ns + UInt64(count[] - 1) * UInt64(period)
        exposure = CaptureActions.Exposure(
            start.domain, start.generation, sequence, model, UInt64(duration)
        )
        # Asymmetry catches accidental transpose/column-major encoding. Keep
        # full ADC values including the top UInt16 bit, without electron conversion.
        raw = reshape(UInt16.(mod.(0:(352*352-1), 65536)), 352, 352)
        raw[1, 2], raw[2, 1], raw[end, end] = 0x8001, 0x0012, 0xffff
        arrays = (;
            raw,
            slopes = reshape(Float32.(1:376), 188, 2),
            flux = fill(Float32(count[]), 188),
            validity = [index != 3 for index in 1:188],
        )
        receipt = capture_file_receipt(
            PipeWireAO.AcquisitionIdentity(capture_domain, start.generation, sequence),
            model,
            UInt64(duration),
        )
        metadata = metadata_change((;
            raw = receipt, slopes = receipt, flux = receipt, validity = receipt
        ))
        return (; arrays, metadata), exposure
    end
    return acquire, count
end
