# Fresh-process optional CPU selector; application directly depends on AOS/HIL/Proper.
using Test, PipeWireAORTC
const Owner = PipeWireAORTC.AOSOwner
const IC = PipeWireAORTC.InstrumentConfiguration
const C = PipeWireAORTC.Common
Base.include(@__MODULE__, joinpath(@__DIR__, "aos_graph_documents.jl"))
loaded(name) = any(id -> id.name == name, keys(Base.loaded_modules))

@testset "selected imported graph loads Proper after Preparing and prepares CPU optics" begin
    @test !loaded("AdaptiveOpticsSim")
    @test !loaded("Proper")
    mktempdir() do directory
        (; document, path) = aos_graph_documents(directory)
        config = joinpath(directory, "simulation.conf")
        args = ["--config", config, "--remote", "/tmp/aos-selected-graph-loading",
            "--control-node", "simulator-wfs", "--bootstrap-node", "rtc.bootstrap.aos", "--bootstrap-instance", "7"]
        C.write_json(config, document)
        @test Owner._main(args; with_owner=(f, options) -> begin
            @test !loaded("AdaptiveOpticsSim") && !loaded("Proper")
            f(merge(options, (; owner_check=() -> nothing)))
        end, run=options -> begin
            @test loaded("AdaptiveOpticsSim") && loaded("AdaptiveOpticsSimPipeWireHIL")
            @test options.plant.graph == "production"
            @test !loaded("Proper")
        end) == 0
        simulation = C.read_yaml(path)
        delete!(simulation["graphs"], "dark") # This selector exercises optics and default loading, not a dark detector.
        native = deepcopy(simulation["components"]["optics"]["config"])
        delete!(native, "temperature_c")
        native["steps"] = [Dict("op" => "multiply", "amplitude" => 0.5)]
        for (name, graph) in simulation["graphs"]
            if name != "optical-reference"
                graph["nodes"] = [Dict("name" => "optics", "type" => "proper_optical_train_f32", "config" => deepcopy(native))]
            end
            resolution = name == "optical-reference" ? 4 : 8
            guide = Dict("name" => "guide", "type" => "shack_hartmann_rate_f32", "config" => Dict(
                "resolution" => resolution, "telescope_diameter_m" => 8, "n_lenslets" => 1,
                "n_pix_subap" => 4, "pixel_scale_arcsec" => 0.1, "source_wavelength_m" => 1.55e-6,
                "source_photon_irradiance_m2_s" => 1.0, "opd_schema" => "example.pupil-opd/1",
                "photon_rate_schema" => "example.rate/1"))
            push!(graph["nodes"], guide)
            binding = "guide_" * string(resolution)
            simulation["bindings"][binding] = Dict("kind" => "zeros", "type" => "Float32", "shape" => [resolution, resolution])
            push!(graph["inputs"], Dict("name" => "guide_opd", "binding" => binding, "destination" => "guide.opd"))
        end
        C.write_yaml(path, simulation)
        declaration = IC.load_simulation(path)
        document["prescription_identity"] = IC.prescription_identity(declaration, IC.settings(declaration))
        document["plant"]["graph"] = "optical-reference"
        C.write_json(config, document)
        with_owner = (f, options) -> begin
            @test !loaded("Proper")
            f(merge(options, (; owner_check=() -> nothing)))
        end
        @test Owner._main(args; with_owner, run=options -> begin
            @test loaded("AdaptiveOpticsSim") && loaded("AdaptiveOpticsSimPipeWireHIL") && loaded("Proper")
            @test options.plant.graph == "optical-reference"
            system = IC.prepare_system(options.plant.definition; settings=options.plant.settings,
                simulation_graph=options.plant.graph)
            AOS = Base.require(Main, :AdaptiveOpticsSim)
            graphs = AOS.AlgorithmGraphs
            @test first(IC.graph_document(system.declaration, system.configured; simulation_graph=options.plant.graph)["nodes"])["type"] == "proper_optical_train_f32"
            amplitude = graphs.graph_input(system.graph, :pupil_amplitude)
            fill!(amplitude, 1)
            graphs.step_graph!(system.graph)
            @test sum(graphs.graph_output(system.graph, :intensity)) ≈ 16
            properties = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).simulation_properties(options,
                (; definition=system.definition, configuration=(; exposure_duration_ns=options.exposure_ns)))
            @test properties["aos.simulation.graph"] == "optical-reference"
            selected = PipeWireAORTC.InstrumentExport.simulator_port_contracts(path; simulation_graph=options.plant.graph)
            default = PipeWireAORTC.InstrumentExport.simulator_port_contracts(path)
            @test selected["residual-wavefront"]["shape"] == [4, 4]
            @test default["residual-wavefront"]["shape"] == [8, 8]
            ref(pointer) = Dict("\$ref" => pointer)
            port = Dict("name" => "wavefront", "shape" => ref("/simulator/residual-wavefront/shape"),
                "element-type" => ref("/simulator/residual-wavefront/element-type"),
                "schema" => "example.wavefront/1", "layout" => "row-major", "rate" => "20/1")
            C.write_json(joinpath(directory, "session.conf"), Dict("queues" => [Dict("ports" => [port])]))
            C.write_json(joinpath(directory, "core.conf"), Dict("context.modules" => []))
            E = PipeWireAORTC.InstrumentExport
            prefix = String(Base.require(Main, :PipeWireAO).LibPipeWire.PipeWireAO_jll.artifact_dir)
            E.prepare_session_configuration!(directory, Dict("session" => "session.conf", "core" => "core.conf"),
                [], "instrument.json", prefix)
            resolved = PipeWireAORTC.DeploymentConfiguration.decode(joinpath(directory, "session.conf"), prefix)
            @test only(only(resolved["queues"])["ports"])["shape"] == [4, 4]
        end) == 0
    end
end
