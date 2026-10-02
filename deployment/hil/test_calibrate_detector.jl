using Test
using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using SHA

include("calibrate_detector.jl")
const Calibration = HILDetectorCalibration

artifact(path, shape; units="ADC") = Dict("path" => path, "shape" => collect(shape),
    "element_type" => "F32_LE", "layout" => "ROW_MAJOR", "units" => units)

function small_detector(; binning=1)
    return cmos_detector_acquisition_node(:detector; rows=4, columns=4, binning,
        pixel_scale_arcsec=1, wavelength_m=800e-9, exposure_duration_s=0.1,
        quantum_efficiency=0.27, gain=1, dark_current_e_per_pixel_s=10,
        bits=8, full_well_e=255, photon_noise=true, readout_noise=true,
        readout_noise_e=2.33, rng_seed=123, T=Float32,
        photon_rate_schema="org.test.photon-rate/1", frame_schema="org.test.adc/1")
end

@testset "cold calibration CLI and ADC encoding" begin
    arguments = ["--graph", "plant.toml", "--profile", "classic",
        "--specification", "calibration-input.json", "--output", "calibration-result.json"]
    @test Calibration.parse_options(arguments).dark_frames == 256
    @test Calibration.parse_options([arguments; "--dark-frames"; "1"]).dark_frames == 1
    @test Calibration.parse_options([arguments; "--dark-frames"; "4096"]).dark_frames == 4096
    for invalid in ("0", "4097", "-1", "1.5")
        @test_throws Exception Calibration.parse_options([arguments; "--dark-frames"; invalid])
    end
    @test_throws Exception Calibration.parse_options([arguments; "--graph"; "duplicate"])
    @test_throws Exception Calibration.parse_options([arguments; "--backend"; "cpu"])
    @test_throws Exception Calibration.parse_options(arguments[1:end-1])
    @test Calibration.encode_adc!(zeros(UInt16, 1, 4), Float32[0.5 1.5 2.5 65535]) ==
        UInt16[0 2 2 65535]
    for invalid in (Float32(NaN), Float32(Inf), -1.0f0, 65536.0f0)
        @test_throws Exception Calibration.encode_adc!(zeros(UInt16, 1, 1), fill(invalid, 1, 1))
    end
    @test_throws DimensionMismatch Calibration.encode_adc!(zeros(UInt16, 2, 1), zeros(Float32, 1, 2))
end

@testset "production detector config, independent RNG and encoded averages" begin
    detector = small_detector()
    first_owner = Calibration.prepare_dark_graph(detector)
    independent_owner = Calibration.prepare_dark_graph(detector)
    @test first_owner.graph !== independent_owner.graph
    @test all(iszero, first_owner.photons)
    raw_samples = zeros(UInt16, 4, 4, 8)
    for sample in 1:8
        step_graph!(first_owner.graph)
        Calibration.encode_adc!(view(raw_samples, :, :, sample), graph_output(first_owner.graph, :frame))
        step_graph!(independent_owner.graph)
        @test graph_output(first_owner.graph, :frame) == graph_output(independent_owner.graph, :frame)
    end
    @test raw_samples[:, :, 1] != raw_samples[:, :, 2]
    dark = Calibration.acquire_dark(detector; samples=8)
    @test dark.acquisition_sequence == UInt64(8)
    expected_mean = dropdims(sum(Float64.(raw_samples); dims=3); dims=3) ./ 8
    expected_variance = zeros(Float64, 4, 4)
    for sample in 1:8
        expected_variance .+= (Float64.(raw_samples[:, :, sample]) .- expected_mean).^2 ./ 8
    end
    @test dark.background == Float32.(expected_mean)
    @test dark.std_adc ≈ sqrt.(expected_variance)
    @test Calibration.acquire_dark(detector; samples=1).std_adc == zeros(4, 4)
    reset_graph!(first_owner.graph)
    step_graph!(first_owner.graph)
    encoded = zeros(UInt16, 4, 4)
    Calibration.encode_adc!(encoded, graph_output(first_owner.graph, :frame))
    @test encoded == raw_samples[:, :, 1]
    # Calibration owns another RNG; it cannot alter this owner's next acquisition.
    step_graph!(first_owner.graph)
    Calibration.encode_adc!(encoded, graph_output(first_owner.graph, :frame))
    @test encoded == raw_samples[:, :, 2]
    @test_throws Exception Calibration.prepare_dark_graph(small_detector(; binning=2))
    @test_throws Exception Calibration.acquire_dark(detector; samples=0)
end

@testset "Copper averages encoded samples rather than fractional ADC output" begin
    detector = emccd_detector_acquisition_node(:detector; rows=4, columns=4,
        binning=1, normalized_pupil_sampling=1 / 64, wavelength_m=550e-9,
        exposure_duration_s=0.002, quantum_efficiency=0.95, gain=1,
        dark_current_e_per_pixel_s=20, bits=14, full_well_e=16000,
        photon_noise=true, readout_noise=true, readout_noise_e=1,
        excess_noise_factor=1, clock_induced_charge_e_per_pixel_frame=0,
        rng_seed=0, photon_rate_schema="org.test.photon-rate/1",
        frame_schema="org.test.adc/1", T=Float32)
    prepared = Calibration.prepare_dark_graph(detector)
    rounded_sum = zeros(Float64, 4, 4)
    fractional_sum = zeros(Float64, 4, 4)
    encoded = zeros(UInt16, 4, 4)
    for sample in 1:8
        step_graph!(prepared.graph)
        frame = graph_output(prepared.graph, :frame)
        fractional_sum .+= frame
        Calibration.encode_adc!(encoded, frame)
        rounded_sum .+= encoded
    end
    dark = Calibration.acquire_dark(detector; samples=8)
    @test dark.background == Float32.(rounded_sum ./ 8)
    @test dark.background != Float32.(fractional_sum ./ 8)
    @test dark.acquisition_sequence == UInt64(8)
end

@testset "ROW_MAJOR artifacts and public RTC reference estimator" begin
    mktempdir() do directory
        coordinates = Float32[-1 -1; 1 -1; -1 1; 1 1]
        thresholds = Float32[5 10; 5 10]
        coord_spec = artifact("coordinates.f32le", (4, 2); units="detector coordinate")
        threshold_spec = artifact("thresholds.f32le", (2, 2); units="ADC")
        coord_record = Calibration.write_artifact(directory, "coordinates", coord_spec, coordinates)
        Calibration.write_artifact(directory, "thresholds", threshold_spec, thresholds)
        @test coord_record["path"] == "coordinates.f32le"
        @test !haskey(coord_record, "resolved_path")
        @test coord_record["sha256"] == bytes2hex(sha256(read(joinpath(directory, "coordinates.f32le"))))
        @test Calibration.read_artifact(directory, coord_spec, (4, 2)) == coordinates
        @test collect(reinterpret(Float32, read(joinpath(directory, "coordinates.f32le")))) ==
            Float32[-1, -1, 1, -1, -1, 1, 1, 1]
        descriptor = Dict("detector_height" => 2, "detector_width" => 4,
            "subaperture_height" => 2, "subaperture_width" => 2,
            "subaperture_origins" => [[0, 0], [0, 2]], "active" => [true, true],
            "coordinates" => coord_spec, "thresholds" => threshold_spec)
        frame = UInt16[20 60 0 0; 20 60 0 0]
        reference = Calibration.reference_slopes(frame, fill(2.0f0, 2, 4), descriptor, directory)
        @test reference.slopes[1, 1] ≈ Float32(80 / 152)
        @test reference.slopes[1, 2] == 0
        @test reference.slopes[2, :] == zeros(Float32, 2)
        @test reference.diagnostics["validity"] == [true, false]
        @test reference.diagnostics["invalid_active_subapertures_zero_based"] == [1]
        @test reference.diagnostics["reference_residual_max_abs"] == 0
        @test reference.diagnostics["flux_adc"] == Float32[152, 0]
        @test_throws Exception Calibration.validate_artifact(coord_spec, (2, 4))
        bad = merge(coord_spec, Dict("layout" => "COLUMN_MAJOR"))
        @test_throws Exception Calibration.read_artifact(directory, bad, (4, 2))
    end
end

# Optional installed-model check: set this to the exact retained hil/plant.toml.
if haskey(ENV, "HIL_CALIBRATION_TEST_GRAPH")
    @testset "flat acquisition retains installed optical and ADC settings" begin
        installed = Calibration.installed_definition(ENV["HIL_CALIBRATION_TEST_GRAPH"], :classic)
        graph = Calibration.prepare_flat_graph(installed, :classic)
        step_graph!(graph)
        flat = zeros(UInt16, 352, 352)
        Calibration.encode_adc!(flat, graph_output(graph, :frame))
        @test sum(flat) > 0
        @test size(flat) == (352, 352)
        @test graph_step_sequence(graph) == UInt64(1)
        @test installed.definition.nodes[5].config.exposure_duration_s ==
            Float32(installed.document["nodes"][5]["config"]["exposure_duration_s"])
        @test installed.definition.nodes[5].config.dark_current_e_per_pixel_s > 0
    end
end
