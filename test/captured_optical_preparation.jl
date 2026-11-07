# Optional native-free selector; run separately with cpu, cuda or amdgpu.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: optical_execution_graph
import AdaptiveOpticsSim.Backends as B
using LinearAlgebra
BLAS.set_num_threads(1)
B.set_fft_provider_threads!(1)
backend = get(ENV, "PIPEWIREAORTC_TEST_BACKEND", "cpu")
target = if backend == "cuda"
    @eval using CUDA
    CUDA.allowscalar(false)
    B.AcceleratorComputeDevice(B.CUDABackend(), 0)
elseif backend == "amdgpu"
    @eval using AMDGPU
    AMDGPU.allowscalar(false)
    B.AcceleratorComputeDevice(B.AMDGPUBackend(), 1)
elseif backend == "cpu"
    B.HostComputeDevice()
else
    error("unsupported test backend")
end
const IC = PipeWireAORTC.InstrumentConfiguration
const Extension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
Base.include(@__MODULE__, joinpath(@__DIR__, "external_optical_documents.jl"))

function capture_documents(directory; spectral = false, precision = Float64, shared = false)
    physical, simulation = external_optical_documents()
    physical["optical_paths"] = Dict(
        name => Dict(
            "sensor" => name,
            "lyot_stop_port" => name == "scc" ? "transmitted" : "reflected",
        ) for name in ("scc", "llowfs")
    )
    for sensor in values(physical["wavefront_sensors"])
        sensor["acquisition"] = Dict("exposure_duration_s" => 0.002)
    end
    config = simulation["components"]["optics"]["config"]
    for name in ("pupil_opd", "pupil_amplitude")
        simulation["bindings"][name]["type"] = string(precision)
    end
    config["steps"] = [
        Dict("op" => "multiply", "amplitude" => 0.5),
        Dict("op" => "propagate", "distance_m" => 0.01),
    ]
    if shared
        spectral && error("the shared fixture uses scalar monochromatic trains")
        push!(config["steps"], Dict("op" => "multiply", "amplitude" => 0.5))
    else
        config["output_sampling_m"] = 0.003
    end
    # Inline nodes admit the scientific owner's finite-channel declaration.
    if spectral
        config["channels"] = [
            Dict(
                "wavelength_um" => wavelength,
                "weight" => 1.0,
                "steps" => deepcopy(config["steps"]),
            ) for wavelength in (1.5, 1.6)
        ]
    end
    for graph in values(simulation["graphs"])
        graph["nodes"] = [
            Dict(
                "name" => "optics",
                "type" =>
                    precision === Float32 ? "proper_optical_train_f32" :
                    "proper_optical_train_f64",
                "config" => deepcopy(config),
            ),
        ]
    end
    unfringed = deepcopy(simulation["graphs"]["scc"])
    unfringed["name"] = "unfringed"
    unfringed["nodes"][1]["config"]["steps"][shared ? end : 1]["amplitude"] = 0.25
    if shared
        simulation["graphs"]["llowfs"]["nodes"][1]["config"]["steps"][end]["amplitude"] =
            0.75
        camera = Dict(
            "name" => "camera_pixels",
            "type" =>
                precision === Float32 ? "pixel_integration_f32" : "pixel_integration_f64",
            "config" => Dict(
                "input_shape" => [8, 8],
                "output_shape" => [8, 8],
                "input_sampling_m" => [0.003, 0.003],
                "output_sampling_m" => [0.003, 0.003],
                "input_center_pixel" => [5.0, 5.0],
                "output_center_pixel" => [5.0, 5.0],
                "input_schema" => config["output_schema"],
                "output_schema" => "example.pixel-flux/1",
            ),
        )
        push!(simulation["graphs"]["llowfs"]["nodes"], camera)
        simulation["graphs"]["llowfs"]["links"] = [
            Dict("source" => "optics.output", "destination" => "camera_pixels.input")
        ]
        only(simulation["graphs"]["llowfs"]["outputs"])["source"] = "camera_pixels.output"
    end
    if spectral
        for channel in unfringed["nodes"][1]["config"]["channels"]
            channel["steps"][1]["amplitude"] = 0.25
        end
    end
    simulation["graphs"]["unfringed"] = unfringed
    empty!(simulation["components"])
    write_external_optical_documents(directory, physical, simulation)
    authored_response!(directory, physical, simulation; mtf = true)
    observation = pop!(simulation["observations"], "low_order")
    observation["graph"] = "response"
    simulation["observations"]["llowfs"] = observation
    simulation["graphs"] = Dict{String,Any}(simulation["graphs"])
    simulation["graphs"]["response"] = "simulation/low_order_response.yaml"
    detector = simulation["components"]["low_order_detector"]["config"]
    detector["pixel_sampling_m"] = [0.003, 0.003]
    detector["photon_noise"] = false
    detector["readout_noise"] = false
    return write_external_optical_documents(directory, physical, simulation)
end

@testset "shared scalar propagation preserves seeded detector exposures and metadata" begin
    mktempdir() do directory
        path = capture_documents(directory; shared = true)
        document = PipeWireAORTC.Common.read_yaml(path)
        detector = document["components"]["low_order_detector"]["config"]
        detector["photon_noise"] = true
        detector["readout_noise"] = true
        detector["readout_noise_e"] = 2.0
        PipeWireAORTC.Common.write_yaml(path, document)
        chopping = (
            scc = (
                unfringed_graph = "unfringed",
                initial_phase = "fringed",
                trigger_high_is_fringed = true,
            ),
        )
        actual = IC.prepare_external_pupil(path; target, chopping)
        reference = IC.prepare_external_pupil(path; chopping)
        # Retain the pre-optimization independent path as the numerical oracle.
        reference = AlgorithmGraphs.PreparedExternalPupil(
            reference.graphs,
            reference.exposures,
            reference.pupil_opd,
            reference.pupil_amplitude,
            reference.observations,
            reference.input_names,
            nothing,
            reference.state,
        )
        @test actual.propagation !== nothing
        @test optical_execution_graph(actual, :scc) ===
            optical_execution_graph(actual, :llowfs)
        declaration = IC.load_simulation(path)
        configured = IC.settings(declaration, NamedTuple())
        identity = IC.prescription_identity(declaration, configured)
        contract = Extension.ExternalPupilOwner.sensor_contract(
            declaration, configured, actual, :scc, identity
        )
        execution = optical_execution_graph(actual, :scc)
        @test parse(Int, contract.properties["optics.captured-node-count"]) ==
            captured_graph_node_count(execution)
        @test contract.properties["optics.execution"] ==
            string(nameof(typeof(graph_execution_policy(execution))))
        @test contract.properties["optics.execution-scope"] == "prepared"
        @test parse(Int, contract.properties["optics.independent.captured-node-count"]) ==
            captured_graph_node_count(actual.graphs.scc)
        @test parse(
            Int, contract.properties["optics.unfringed.independent.captured-node-count"]
        ) == captured_graph_node_count(actual.observations.scc.chopping.unfringed)
        function exposures(plant)
            products = NamedTuple[]
            for sequence in 1:8
                opd = [1e-8sin(i + sequence) * cos(j) for i in 1:4, j in 1:4]
                amplitude = fill(sequence <= 4 ? 1.0 : 0.7, 4, 4)
                step_external_pupil!(
                    plant,
                    opd,
                    amplitude,
                    ModelTimestamp((sequence - 1) * 1_000_000),
                    ModelDuration(1_000_000);
                    domain = ntuple(_ -> UInt8(1), 16),
                    generation = UInt64(1),
                    sequence = UInt64(sequence),
                ) do name, image, metadata
                    push!(products, (; name, image = Array(image), metadata))
                end
            end
            return products
        end
        expected = exposures(reference)
        observed = exposures(actual)
        @test length(expected) == length(observed) == 8
        for (a, b) in zip(expected, observed)
            @test a.name == b.name && a.metadata == b.metadata
            @test a.image ≈ b.image rtol = 8e-5 atol = 1e-8
        end
        reset_external_pupil!(actual)
        again = exposures(actual)
        @test map(row -> row.metadata, again) == map(row -> row.metadata, observed)
        @test all(a.image == b.image for (a, b) in zip(again, observed))
    end
end

@testset "RTC target execution policy and actual external optical replay" begin
    for precision in (Float32, Float64), spectral in (false, true)
        mktempdir() do directory
            path = capture_documents(directory; spectral, precision)
            chopping = (
                scc = (
                    unfringed_graph = "unfringed",
                    initial_phase = "fringed",
                    trigger_high_is_fringed = true,
                ),
            )
            reference = IC.prepare_external_pupil(path; chopping)
            actual = IC.prepare_external_pupil(path; target, chopping)
            graphs = (
                values(actual.graphs)...,
                actual.observations.scc.chopping.unfringed,
                actual.observations.llowfs.response.graph,
            )
            for graph in graphs
                @test graph_execution_policy(graph) isa
                    (backend == "cpu" ? StreamGraphExecution : CapturedGraphExecution)
                @test captured_graph_node_count(graph) ==
                    (backend == "cpu" ? 0 : length(graph.nodes))
            end
            if backend != "cpu"
                @test_throws ArgumentError IC.prepare_system(
                    path;
                    simulation_graph = "scc",
                    target,
                    execution = StreamGraphExecution(),
                )
                @test_throws ArgumentError IC.prepare_external_pupil(
                    path; target, execution = StreamGraphExecution(), chopping
                )
            end
            function replay(plant)
                products = NamedTuple[]
                for sequence in 1:8
                    opd = [1e-8sin(i + sequence) * cos(j) for i in 1:4, j in 1:4]
                    amplitude = fill(sequence <= 4 ? 1.0 : 0.7, 4, 4)
                    @test step_external_pupil!(
                        plant,
                        opd,
                        amplitude,
                        ModelTimestamp((sequence - 1) * 1_000_000),
                        ModelDuration(1_000_000);
                        domain = ntuple(_ -> UInt8(1), 16),
                        generation = UInt64(1),
                        sequence = UInt64(sequence),
                    ) do name, image, metadata
                        push!(products, (; name, image = Array(image), metadata))
                    end
                end
                return products
            end
            expected = replay(reference)
            observed = replay(actual)
            @test length(expected) == length(observed) == 8
            for (a, b) in zip(expected, observed)
                @test a.name == b.name &&
                    a.metadata.pts == b.metadata.pts &&
                    a.metadata.duration == b.metadata.duration
                @test a.image ≈ b.image rtol = 8e-5 atol = 1e-8
                @test all(isfinite, b.image) && sum(b.image) > 0
            end
            scc = filter(p -> p.name == :scc, observed)
            @test map(p -> p.metadata.chopped_image_kind, scc) ==
                [:fringed, :unfringed, :fringed, :unfringed]
            @test sum(scc[2].image) ≈ sum(scc[1].image) / 4 rtol = 8e-5
            reset_external_pupil!(actual)
            again = replay(actual)
            @test map(p -> p.metadata, again) == map(p -> p.metadata, observed)
            @test all(a.image ≈ b.image for (a, b) in zip(again, observed))
            execution_graph = optical_execution_graph(actual, :scc)
            properties = AdaptiveOpticsSimPipeWireHIL.ExternalPupil.execution_properties(
                execution_graph; prefix = "aos.simulation."
            )
            @test properties["aos.simulation.execution"] ==
                string(nameof(typeof(graph_execution_policy(execution_graph))))
            @test parse(Int, properties["aos.simulation.captured-node-count"]) ==
                captured_graph_node_count(execution_graph)
            declaration = IC.load_simulation(path)
            configured = IC.settings(declaration, NamedTuple())
            identity = IC.prescription_identity(declaration, configured)
            contract = Extension.ExternalPupilOwner.sensor_contract(
                declaration, configured, actual, :scc, identity
            )
            @test contract.properties["optics.execution"] ==
                properties["aos.simulation.execution"]
            @test parse(Int, contract.properties["optics.captured-node-count"]) ==
                captured_graph_node_count(execution_graph)
            unfringed = optical_execution_graph(actual, :scc; unfringed = true)
            @test parse(Int, contract.properties["optics.unfringed.captured-node-count"]) ==
                captured_graph_node_count(unfringed)
        end
    end
end
@testset "detector response capture advances and resets its seeded draws" begin
    mktempdir() do directory
        path = capture_documents(directory)
        document = PipeWireAORTC.Common.read_yaml(path)
        document["components"]["low_order_detector"]["config"]["photon_noise"] = true
        document["observations"]["llowfs"]["normalized_to_photon_rate"] = 1e8
        PipeWireAORTC.Common.write_yaml(path, document)
        plant = IC.prepare_external_pupil(path; target)
        response = plant.observations.llowfs.response.graph
        @test graph_execution_policy(response) isa
            (backend == "cpu" ? StreamGraphExecution : CapturedGraphExecution)
        function detector_frames()
            frames = Matrix{Float32}[]
            for sequence in 1:2
                @test step_external_pupil!(
                    plant,
                    zeros(4, 4),
                    ones(4, 4),
                    ModelTimestamp((sequence - 1) * 2_000_000),
                    ModelDuration(2_000_000);
                    domain = ntuple(_ -> UInt8(1), 16),
                    generation = UInt64(1),
                    sequence = UInt64(sequence),
                ) do name, image, metadata
                    name == :llowfs && push!(frames, Array(image))
                end
            end
            return frames
        end
        frames = detector_frames()
        @test length(frames) == 2 && frames[1] != frames[2]
        @test all(frame -> all(isfinite, frame) && sum(frame) > 0, frames)
        reset_external_pupil!(plant)
        @test detector_frames() == frames
    end
end
@test backend == "cuda" || !any(p.name == "CUDA" for p in keys(Base.loaded_modules))
@test backend == "amdgpu" || !any(p.name == "AMDGPU" for p in keys(Base.loaded_modules))
