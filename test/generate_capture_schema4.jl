# Regenerate historical schema-4 test data with the original frozen writer.
# Run from the repository root: julia --project=. test/generate_capture_schema4.jl
using PipeWireAORTC, SHA
include("capture_file_inputs.jl")

const source_revision = "94ecd39fe83e5f292c46d2d08f5867d78dd3d02d"
const source_path = "src/calibration_capture_files.jl"
source = read(`git show $source_revision:$source_path`, String)
source = replace(
    source,
    "import ..CalibrationActionCodec" => "import PipeWireAORTC.CalibrationActionCodec",
    "import ..ControlClient" => "import PipeWireAORTC.ControlClient",
)
module HistoricalCaptureWriter
using SHA
import PipeWireAORTC.Common
end
Base.include_string(HistoricalCaptureWriter, source, source_path)
destination = joinpath(@__DIR__, "data", "capture-schema4")
mktempdir() do parent
    store = HistoricalCaptureWriter.CaptureStore(
        joinpath(parent, "capture");
        stage = "lamp-training",
        illumination = "lamp",
        settings = capture_settings,
        maximum_bytes = HistoricalCaptureWriter.CLASSIC_CAPTURE_BYTES,
    )
    acquire, _ = capture_source()
    descriptor = HistoricalCaptureWriter.capture!(
        store,
        acquire;
        run = UInt64(7),
        serial = UInt64(1),
        probe = UInt32(1),
        cursor = capture_cursor(),
        frames = UInt32(1),
        deadline = CaptureClock.monotonic() + 30,
    )
    receipt = Dict(
        "generated" => Dict(
            "source_revision" => source_revision,
            "source_path" => source_path,
            "regenerate" => "julia --project=. test/generate_capture_schema4.jl",
        ),
        "descriptor" => Dict(
            "manifest" => descriptor.manifest,
            "sha256" => descriptor.sha256,
            "frames" => descriptor.frames,
            "bytes" => descriptor.bytes,
            "metadata_bytes" => descriptor.metadata_bytes,
            "cursor" => CaptureFiles._capture_cursor(descriptor.cursor),
        ),
    )
    # The generator owns only this named generated dataset.
    ispath(destination) && rm(destination; recursive = true)
    cp(store.directory, destination)
    write(
        joinpath(destination, "generated.json"),
        PipeWireAORTC.Common.JSON.json(receipt) * "\n",
    )
end
