# Optional scientific integration: SOURCE APPLICATION BUNDLE FRESH_OUTPUT.
# The application must be the exact build identified by the acquired bundle.
using Test, SHA, PipeWireAORTC
using FilterGraphAlgorithms, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsCalibration, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph

length(ARGS) == 4 || error("usage: test_calibration_staging.jl SOURCE APPLICATION BUNDLE FRESH_OUTPUT")
source, application, calibration, destination = abspath.(ARGS)
const C = PipeWireAORTC.InstrumentCalibration
const E = PipeWireAORTC.InstrumentExport
const Common = PipeWireAORTC.Common

snapshot(path) = Dict(relpath(joinpath(root, file), path) => bytes2hex(sha256(read(joinpath(root, file))))
    for (root, _, files) in walkdir(path) for file in files)

@testset "Calibration staging retains the current selection and uses Git for history" begin
    original = snapshot(source)
    mktempdir() do temporary
        authored = E.copy_source(source, joinpath(temporary, "instrument"); runtime_configurations=false)
        history = joinpath(authored, "calibration", "history")
        mkpath(history)
        write(joinpath(history, "obsolete.yaml"), "obsolete: true\n")
        before = snapshot(authored)
        incoming = C.read_bundle(calibration)
        @test C.stage_calibration(authored, application, calibration, destination) == destination
        selected = C.read_bundle(joinpath(destination, "calibration"))
        @test !ispath(joinpath(destination, "calibration", "history"))
        @test !ispath(joinpath(destination, "rtc", "calibration.yaml"))
        @test !haskey(selected.report, "history_sha256")
        @test selected.parameter_files == incoming.parameter_files
        @test selected.report["artifact_sha256"] == incoming.report["artifact_sha256"]
        @test C.read_recipe(application) == selected.report["recipe"]
        rtc = Common.read_yaml(joinpath(destination, "rtc", "configuration.yaml"))
        @test rtc["calibration"] == "calibration/context.yaml"
        @test rtc["calibration_identity"] == "sha256:" * Common.sha256_file(joinpath(destination, "calibration", "result.yaml"))
        @test snapshot(authored) == before
    end
    @test snapshot(source) == original
end
