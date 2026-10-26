# Optional CPU selector; requires RTC, AOS and AOS HIL in the active environment.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs

const IC = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
const F = PipeWireAORTC.Artifacts.FITSIO
const E = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
const Detectors = AdaptiveOpticsSim.Detectors

function write_image(path, values)
    F.FITS(path, "w") do file
        write(file, values)
    end
end

function calibration_simulation(directory)
    write_image(joinpath(directory, "origins.fits"), Int32[0 0; 4 0; 0 4; 4 4])
    C.write_json(joinpath(directory, "mirror.json"), Dict("schema_version" => 1,
        "id" => "test-mirror", "manufacturer" => "Example", "model" => "Test",
        "layout" => Dict("schema_version" => 1, "name" => "Test grid",
            "grid_shape" => [3, 3], "command_positions" => [[2, 2]],
            "axis_labels" => ["column", "row"], "command_order" => "physical")))
    C.write_yaml(joinpath(directory, "instrument.yaml"), Dict("schema_version" => 1,
        "id" => "calibrated-sh", "telescope" => Dict("telescope_diameter_m" => 8.0,
            "central_obstruction_ratio" => 0.0, "pupil_reflectivity" => 1.0, "aperture_revision" => 1),
        "deformable_mirrors" => Dict("mirror" => Dict("description" => "mirror.json",
            "pupil_registration" => Dict("actuator_pitch_pupil_radius" => 1.0),
            "units" => "m", "command_scale_m" => 1.0)),
        "wavefront_sensors" => Dict("sensor" => Dict("kind" => "shack_hartmann",
            "detector_shape" => [8, 8], "subaperture_shape" => [4, 4],
            "subaperture_origins" => Dict("path" => "origins.fits", "hdu" => 1,
                "axes" => [1, 2], "type" => "Int32", "shape" => [4, 2]),
            "expected_schema" => "test.frame/1"))))
    node(name, type, config) = Dict{String,Any}("name" => name, "type" => type, "config" => config)
    graph = Dict("schema_version" => 1, "name" => "calibrated_sh",
        "nodes" => [
            node("modal", "modal_opd_expansion_f32", Dict("mode_count" => 1,
                "pupil_rows" => 8, "pupil_columns" => 8, "basis_schema" => "test.basis/1",
                "coefficients_schema" => "test.command/1", "opd_schema" => "test.opd/1",
                "pupil_support_schema" => "test.pupil/1")),
            node("sensor", "shack_hartmann_rate_f32", Dict("resolution" => 8,
                "telescope_diameter_m" => 8, "n_lenslets" => 2, "n_pix_subap" => 4,
                "pixel_scale_arcsec" => 0.1, "source_wavelength_m" => 0.75e-6,
                "source_photon_irradiance_m2_s" => 100.0,
                "opd_schema" => "test.opd/1", "photon_rate_schema" => "test.rate/1")),
            node("layout", "detector_frame_layout_f32", Dict("input_size" => [8, 8],
                "output_size" => [8, 10], "origin" => [0, 1], "scale" => 1, "bias" => 0,
                "input_schema" => "test.rate/1", "output_schema" => "test.padded-rate/1")),
            node("response", "pixel_mtf", Dict("input_shape" => [8, 10], "padding" => 2,
                "input_schema" => "test.padded-rate/1", "output_schema" => "test.filtered-rate/1")),
            merge(node("camera", "detector", Dict("shutter" => "global", "rows" => 8,
                "columns" => 10, "pixel_sampling_m" => [12e-6, 14e-6],
                "spectral_channel" => "test_band", "exposure_duration_s" => 0.001,
                "quantum_efficiency" => 0.75, "gain" => 2, "photon_noise" => false,
                "readout_noise" => false, "rng_seed" => 1,
                "photon_rate_schema" => "test.filtered-rate/1", "frame_schema" => "test.frame/1")),
                Dict("detector" => "ingaas"))],
        "inputs" => [Dict("name" => "command", "binding" => "command", "destination" => "modal.coefficients")],
        "parameters" => [Dict("binding" => "basis", "destination" => "modal.basis"),
            Dict("binding" => "pupil", "destination" => "modal.pupil_support")],
        "links" => [Dict("source" => source, "destination" => destination) for (source, destination) in
            (("modal.opd", "sensor.opd"), ("sensor.photon_rate", "layout.detector_frame"),
             ("layout.frame", "response.input"), ("response.output", "camera.photon_rate"))],
        "outputs" => [Dict("name" => name, "source" => source) for (name, source) in
            (("pupil_opd", "modal.opd"), ("rate", "layout.frame"),
             ("filtered", "response.output"), ("frame", "camera.frame"))])
    graph["nodes"][4]["bindings"] = Dict("transfer" => "calibrated_transfer")
    C.write_yaml(joinpath(directory, "graph.yaml"), graph)
    transfer = Detectors.pixel_mtf_transfer((12, 14); box_width_pixels=1.03,
        diffusion_variance_pixels2=0.21, ipc_per_neighbor=0.04, T=Float32)
    # Store the transpose so explicit FITS axes must restore the logical grid.
    write_image(joinpath(directory, "transfer.fits"), permutedims(transfer))
    write_image(joinpath(directory, "basis.fits"), reshape(
        Float32[(i - 4.5) / 4 for i in 1:8, j in 1:8], 8, 8, 1))
    fits(path, shape; axes=collect(1:length(shape))) = Dict("kind" => "fits",
        "path" => path, "hdu" => 1, "axes" => axes, "type" => "Float32", "shape" => shape)
    document = Dict{String,Any}("schema_version" => 1, "id" => "calibrated-sh",
        "instrument" => "instrument.yaml", "defaults" => Dict("profile" => "basic"),
        "settings_schema" => Dict("type" => "object", "properties" => Dict("profile" => Dict("type" => "string"))),
        "wire_contracts" => [Dict("frame_encoding" => "float32", "frame_schema" => "test.frame/1",
            "command_schema" => "test.command/1", "command_scale" => 1)],
        "graphs" => Dict("production" => "graph.yaml", "calibration" => "graph.yaml"),
        "profiles" => Dict("basic" => Dict("nodes" => [], "parameters" => []),
            "unused" => Dict("nodes" => [], "parameters" => [Dict("binding" => "unused", "destination" => "modal.basis")])),
        "bindings" => Dict("command" => Dict("kind" => "zeros", "type" => "Float32", "shape" => [1]),
            "basis" => fits("basis.fits", [8, 8, 1]), "pupil" => Dict("kind" => "pupil_support", "resolution" => 8),
            "calibrated_transfer" => fits("transfer.fits", [12, 14]; axes=[2, 1]),
            "unused" => fits("unselected-missing.fits", [8, 8, 1])),
        "settings_bindings" => [], "frame_period_s" => 0.001,
        "hil" => Dict("command_input" => "command", "frame_output" => "frame"))
    path = joinpath(directory, "simulation.yaml")
    C.write_yaml(path, document)
    return (; path, document, graph, transfer)
end

@testset "FITS construction calibration through cold contracts and CPU HIL" begin
    mktempdir() do directory
        case = calibration_simulation(directory)
        contracts = PipeWireAORTC.InstrumentExport.simulator_port_contracts(case.path)
        @test contracts["focal-image"]["shape"] == [16, 16]
        @test !isfile(joinpath(directory, "unselected-missing.fits"))
        declaration = IC.load_simulation(case.path)
        configured = IC.settings(declaration)
        @test IC.artifact_paths(declaration, configured) ==
            Set(["mirror.json", "origins.fits", "basis.fits", "transfer.fits"])
        identity = IC.prescription_identity(declaration, configured)
        basis_path = joinpath(directory, "basis.fits")
        basis_bytes = read(basis_path)
        rm(basis_path)
        @test PipeWireAORTC.InstrumentExport.simulator_port_contracts(case.path) == contracts
        write(basis_path, basis_bytes)
        system = IC.prepare_system(case.path)
        @test graph_step_sequence(system.graph) == 0
        response = system.definition.nodes[4]
        @test Matrix(response.config.transfer) == case.transfer
        @test size(hil_frame_buffer(system.boundary)) == (8, 10)
        hil_command_buffer(system.boundary) .= 12f-9
        step_hil_frame_at!(system.boundary, system.driver)
        rate = graph_output(system.graph, :rate)
        native = Detectors.prepare_pixel_mtf(copy(rate), case.transfer; padding=2)
        expected = copy(Detectors.apply_pixel_mtf!(native))
        @test graph_output(system.graph, :filtered) ≈ expected rtol=2f-6 atol=2f-5
        @test hil_frame_buffer(system.boundary) ≈ expected .* 0.0015f0 rtol=2f-6 atol=2f-7
        first = copy(hil_frame_buffer(system.boundary))
        # Native and declared graph owners retain independent calibration snapshots.
        fill!(case.transfer, 0)
        write_image(joinpath(directory, "transfer.fits"), zeros(Float32, 14, 12))
        @test IC.prescription_identity(declaration, configured) != identity
        @test any(!iszero, response.config.transfer)
        @test Detectors.apply_pixel_mtf!(native) ≈ expected rtol=2f-6 atol=2f-5
        reset_hil_boundary!(system.boundary, system.driver)
        @test graph_step_sequence(system.graph) == 0
        @test all(iszero, graph_output(system.graph, :filtered))
        hil_command_buffer(system.boundary) .= 12f-9
        step_hil_frame_at!(system.boundary, system.driver)
        @test hil_frame_buffer(system.boundary) == first
        @test_throws AlgorithmGraphs.AlgorithmGraphError PipeWireAORTC.InstrumentExport.simulator_port_contracts(case.path)
        @test_throws AlgorithmGraphs.AlgorithmGraphError IC.prepare_system(case.path)
    end
end

@testset "invalid construction calibration rejects cold contracts and preparation" begin
    for failure in (:undeclared, :missing, :type, :shape, :axes, :nan, :dc, :graph_shape)
        mktempdir() do directory
            case = calibration_simulation(directory)
            binding = case.document["bindings"]["calibrated_transfer"]
            if failure === :undeclared
                delete!(case.document["bindings"], "calibrated_transfer")
            elseif failure === :missing
                rm(joinpath(directory, "transfer.fits"))
            elseif failure === :type
                binding["type"] = "ComplexF32"
            elseif failure === :shape
                binding["shape"] = [12, 13]
            elseif failure === :axes
                binding["axes"] = [1, 2]
            elseif failure === :graph_shape
                case.graph["nodes"][4]["config"]["padding"] = 3
                C.write_yaml(joinpath(directory, "graph.yaml"), case.graph)
            else
                values = copy(case.transfer)
                failure === :nan ? (values[2, 3] = NaN32) : (values[1, 1] = 0.5f0)
                write_image(joinpath(directory, "transfer.fits"), permutedims(values))
            end
            C.write_yaml(case.path, case.document)
            error_type = failure in (:shape, :axes) ? DimensionMismatch :
                failure in (:dc, :graph_shape) ? AlgorithmGraphs.AlgorithmGraphError :
                failure === :missing ? Base.IOError : ArgumentError
            @test_throws error_type PipeWireAORTC.InstrumentExport.simulator_port_contracts(case.path)
            @test_throws error_type IC.prepare_system(case.path)
        end
    end
    @test !any(id -> id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end

# An unrelated extension factory declares a differently named binding through
# the same AOS trait. No pixel-MTF names enter the RTC binding collector.
calibrated_node(name, config, props, bindings) = bindings[Symbol(config.calibration)]
AlgorithmGraphs.graph_node_bindings(::typeof(calibrated_node), config::NamedTuple) = (Symbol(config.calibration),)
@testset "construction binding discovery is generic and deduplicated" begin
    document = Dict("nodes" => [Dict("type" => "custom", "config" => Dict(),
        "bindings" => Dict("calibration" => "gain")) for _ in 1:2])
    @test E.configuration_binding_names(document, (;custom=calibrated_node)) == [:gain]
    @test AlgorithmGraphs.graph_node_bindings(identity, (;)) == ()
end
