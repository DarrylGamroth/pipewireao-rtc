# Optional science test. Run in an environment containing RTC, AOS, HIL and
# REVOLTClassicSim; select cpu (default) or cuda as the first argument.
using Test
using JSON
using PipeWireAORTC
using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL
using REVOLTClassicSim

const InstrumentOwner = PipeWireAORTC.AOSOwner
const InstrumentExtension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
const InstrumentBackend = isempty(ARGS) ? :cpu : Symbol(only(ARGS))
InstrumentBackend in (:cpu, :cuda) || error("expected cpu or cuda")
InstrumentBackend === :cuda && Base.require(Main, :CUDA)

module CountingInstrument
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO
import AdaptiveOpticsSim.AlgorithmGraphs: hil_command_buffer, hil_frame_buffer,
    step_hil_frame_at!, adopt_hil_command!, reset_hil_boundary!

mutable struct Counts
    steps::Int
    adoptions::Int
    resets::Int
end
struct Boundary{B,G,C,F}
    boundary::B
    graph::G
    command_input::C
    frame_output::F
    counts::Counts
end
hil_command_buffer(boundary::Boundary) = hil_command_buffer(boundary.boundary)
hil_frame_buffer(boundary::Boundary) = hil_frame_buffer(boundary.boundary)
function step_hil_frame_at!(boundary::Boundary, driver)
    boundary.counts.steps += 1
    return step_hil_frame_at!(boundary.boundary, driver)
end
function adopt_hil_command!(boundary::Boundary, sequence)
    boundary.counts.adoptions += 1
    return adopt_hil_command!(boundary.boundary, sequence)
end
function reset_hil_boundary!(boundary::Boundary, driver)
    boundary.counts.resets += 1
    return reset_hil_boundary!(boundary.boundary, driver)
end
function prepare_hil_system(settings::NamedTuple; target, execution)
    definition = load_algorithm_graph(settings.graph_path;
        bindings=(; command=zeros(Float32, 3), basis=reshape(Float32.(1:18), 2, 3, 3),
            pupil=fill(true, 2, 3)))
    graph = prepare_algorithm_graph(definition; target, execution)
    actual = prepare_graph_hil_boundary(graph; command_input=:command, frame_output=:frame)
    boundary = Boundary(actual, graph, graph_input(graph, :command), graph_output(graph, :frame), Counts(0, 0, 0))
    return (; definition, graph, boundary, frame_period_s=get(settings, :period_s, 0.002),
        fault=get(settings, :fault, "none"))
end
function pipewire_configuration(system, remote; frame_node_name, command_node_name,
        frame_encoding, frame_schema, command_schema, command_scale)
    fault = system.fault
    return PipeWireHILConfiguration(;
        remote=fault == "remote" ? remote * "-wrong" : remote,
        frame_node_name, command_node_name,
        frame_encoding=fault == "encoding" ? :float32 : frame_encoding,
        frame_schema=fault == "schema" ? "wrong.frame/1" : frame_schema,
        command_schema, command_scale=fault == "scale" ? 1f0 : command_scale,
        rate=SPA.Fraction(fault == "rate" ? 501 : 500, 1),
        exposure_duration_ns=fault == "exposure" ? 2_000_000 : 1_896_000)
end
end

function instrument_document(; backend="cpu", package="CountingInstrument", settings=Dict())
    return Dict{String,Any}(
        "version" => 2, "plant" => Dict("package" => package, "settings" => settings),
        "command_input" => "command", "frame_output" => "frame",
        "command_count" => 3, "frame_shape" => [2, 3],
        "rate" => 500, "exposure_ns" => 1_896_000, "pacing_rate_hz" => 10,
        "backend" => backend, "device" => 0, "frame_encoding" => "uint16",
        "frame_schema" => "pipewireao/raw-detector-pixels-u16/1",
        "command_schema" => "pipewireao/dm-command-opd-um-f32/1", "command_scale" => 1e-6)
end

function instrument_options(document, path, plant_module)
    write(path, JSON.json(document))
    return merge(InstrumentOwner.configuration(path),
        (; remote="/tmp/aos-instrument-preparation", control_node="simulator-wfs", plant_module))
end

@testset "Managed builder warms and resets its exact boundary once" begin
    mktempdir() do directory
        graph_path = joinpath(directory, "model.yaml")
        write(graph_path, """
            schema_version: 1
            name: "counted_instrument"
            parameters:
              - binding: "basis"
                destination: "modal.basis"
              - binding: "pupil"
                destination: "modal.pupil_support"
            nodes:
              - type: "modal_opd_expansion_f32"
                name: "modal"
                config:
                  basis_schema: "test.aos.basis/1"
                  pupil_columns: 3
                  coefficients_schema: "test.aos.command/1"
                  opd_schema: "test.aos.frame/1"
                  pupil_support_schema: "test.aos.pupil/1"
                  mode_count: 3
                  pupil_rows: 2
            outputs:
              - source: "modal.opd"
                name: "frame"
            inputs:
              - binding: "command"
                name: "command"
                destination: "modal.coefficients"
            """)
        document = instrument_document(settings=Dict{String,Any}("graph_path" => graph_path))
        path = joinpath(directory, "owner.conf")
        options = instrument_options(document, path, CountingInstrument)
        science = InstrumentOwner.prepare_science(options)
        counts = science.boundary.counts
        @test (counts.steps, counts.adoptions, counts.resets) == (1, 1, 1)
        @test model_time_sequence(science.driver) == 0
        @test graph_step_sequence(science.graph) == 0
        @test science.boundary.graph === science.graph
        @test science.configuration.remote == options.remote
        @test science.configuration.frame_encoding === :uint16
        @test science.configuration.command_scale == 1f-6
        @test isconcretetype(typeof(science))
        @test all(iszero, hil_command_buffer(science.boundary))
        properties = InstrumentExtension.simulation_properties(options, science)
        @test properties isa Dict{String,String}
        @test !haskey(properties, "aos.simulation.atmosphere-rng-seed")
        @test !haskey(properties, "aos.simulation.detector-rng-seed")
        @test !haskey(properties, "aos.simulation.configuration-sha256")
        @test !haskey(properties, "aos.simulation.calibration-identity")
        @test !haskey(properties, "aos.simulation.profile")
        @test !haskey(properties, "aos.simulation.package-version")
        @test InstrumentExtension.atmosphere_seed((; rng_seed=5)) === nothing
        @test InstrumentExtension.detector_seed((; rng_seed=5)) === nothing
        @test (counts.steps, counts.adoptions, counts.resets) == (1, 1, 1)
        frame = step_hil_frame_at!(science.boundary, science.driver)
        @test frame.sequence == 1
        @test (counts.steps, counts.adoptions, counts.resets) == (2, 1, 1)
        adopt_hil_command!(science.boundary, frame.sequence)
        for fault in ("remote", "encoding", "schema", "scale", "rate", "exposure")
            invalid = deepcopy(document)
            invalid["plant"]["settings"]["fault"] = fault
            @test_throws ArgumentError InstrumentOwner.prepare_science(
                instrument_options(invalid, path, CountingInstrument))
        end
        invalid = deepcopy(document)
        invalid["plant"]["settings"]["period_s"] = 0.003
        @test_throws ArgumentError InstrumentOwner.prepare_science(
            instrument_options(invalid, path, CountingInstrument))
        for (field, value) in (("command_count", 4), ("frame_shape", [3, 2]),
                ("command_input", "unknown"), ("frame_output", "unknown"))
            invalid = deepcopy(document)
            invalid[field] = value
            @test_throws Exception InstrumentOwner.prepare_science(
                instrument_options(invalid, path, CountingInstrument))
        end
    end
end

@testset "Classic managed $(InstrumentBackend) preparation without transport" begin
    mktempdir() do directory
        write(joinpath(directory,"mirror-description.json"),
            PipeWireAORTC.InstrumentDefinition.mirror_description_json(ENV["REVOLT_CLASSIC_MIRROR_DESCRIPTION"]))
        document = instrument_document(backend=string(InstrumentBackend), package="REVOLTClassicSim",
            settings=Dict("profile" => "grid_gaussian", "mirror_description"=>"mirror-description.json"))
        document["command_input"] = "pdm_command"
        document["frame_output"] = "shwfs_frame"
        document["command_count"] = 277
        document["frame_shape"] = [352, 352]
        document["calibration_identity"] = "declared-classic-startup-calibration"
        options = instrument_options(document, joinpath(directory, "owner.conf"), REVOLTClassicSim)
        options = merge(options, (; configuration_sha256=PipeWireAORTC.Common.sha256_file(options.config_path)))
        science = InstrumentOwner.prepare_science(options)
        @test options.graph === nothing
        @test science.definition !== nothing
        @test size(hil_frame_buffer(science.boundary)) == (352, 352)
        @test size(hil_command_buffer(science.boundary)) == (277,)
        @test all(iszero, hil_command_buffer(science.boundary))
        @test model_time_sequence(science.driver) == 0
        @test graph_step_sequence(science.graph) == 0
        @test science.configuration.rate.num == 500
        @test science.configuration.rate.denom == 1
        @test science.configuration.exposure_duration_ns == 1_896_000
        @test science.configuration.frame_encoding === :uint16
        @test science.configuration.command_scale == 1f-6
        @test isconcretetype(typeof(science))
        properties = InstrumentExtension.simulation_properties(options, science)
        @test properties isa Dict{String,String}
        @test properties["aos.simulation.package"] == "REVOLTClassicSim"
        @test properties["aos.simulation.package-version"] == string(pkgversion(REVOLTClassicSim))
        @test properties["aos.simulation.profile"] == "grid_gaussian"
        @test properties["aos.simulation.backend"] == string(InstrumentBackend)
        @test properties["aos.simulation.device"] == "0"
        @test properties["aos.simulation.model-period-ns"] == "2000000"
        @test properties["aos.simulation.exposure-ns"] == "1896000"
        @test properties["aos.simulation.configuration-sha256"] == options.configuration_sha256
        @test properties["aos.simulation.calibration-identity"] == "declared-classic-startup-calibration"
        @test properties["aos.simulation.atmosphere-rng-seed"] == "1"
        @test properties["aos.simulation.detector-rng-seed"] == "0"
        no_profile = merge(options, (; plant=merge(options.plant, (; settings=NamedTuple()))))
        @test !haskey(InstrumentExtension.simulation_properties(no_profile, science), "aos.simulation.profile")
        legacy = merge(options, (; plant=nothing))
        @test !haskey(InstrumentExtension.simulation_properties(legacy, science), "aos.simulation.package")
        atmosphere = only(filter(node -> InstrumentExtension.atmosphere_seed(node.config) !== nothing,
            science.definition.nodes))
        second_atmosphere = algorithm_node(:second_atmosphere,
            AdaptiveOpticsSim.AlgorithmGraphs.MultiLayerAtmosphereOPDNode{Float32}, atmosphere.config)
        ambiguous = algorithm_graph((atmosphere, second_atmosphere); name=:multiple_atmospheres)
        @test InstrumentExtension.single_seed(ambiguous, InstrumentExtension.atmosphere_seed) === nothing
        detector = only(filter(node -> InstrumentExtension.detector_seed(node.config) !== nothing,
            science.definition.nodes))
        second_detector = algorithm_node(:second_detector,
            AdaptiveOpticsSim.AlgorithmGraphs.CMOSDetectorAcquisitionNode{Float32}, detector.config)
        ambiguous = algorithm_graph((detector, second_detector); name=:multiple_detectors)
        @test InstrumentExtension.single_seed(ambiguous, InstrumentExtension.detector_seed) === nothing
        @test model_time_sequence(science.driver) == 0
        @test graph_step_sequence(science.graph) == 0
        frame = step_hil_frame_at!(science.boundary, science.driver)
        @test frame.sequence == 1
        @test all(value -> isfinite(value) && 0 <= value <= 65535, hil_frame_buffer(science.boundary))
        adopt_hil_command!(science.boundary, frame.sequence)
        println("MANAGED_CLASSIC_PREPARATION backend=$InstrumentBackend frame_shape=(352,352) command_count=277 sequence=$(frame.sequence) transport=false")
    end
end
