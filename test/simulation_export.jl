# Optional CPU selector: author once, export, then run the public HIL loader
# in a process that never imports RTC. No core, service or GPU is opened.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: copyto_graph_input!
using PipeWireAO: LibPipeWire, SPA
include(joinpath(@__DIR__, "aos_graph_documents.jl"))
const ExportConfiguration = PipeWireAORTC.InstrumentConfiguration
const ExportCommon = PipeWireAORTC.Common

@testset "standalone HIL export preserves authored graphs and typed bindings" begin
    mktempdir() do directory
        source = joinpath(directory, "source")
        mkpath(source)
        (; path, basis) = modal_simulation_source(source)
        before = Dict(
            joinpath(root, name) => read(joinpath(root, name)) for
            (root, _, names) in walkdir(source) for name in names
        )
        wire = PipeWireHILConfiguration(;
            remote = "standalone-export-test",
            frame_node_name = "simulation-frame",
            command_node_name = "simulation-command",
            frame_schema = "test.export.opd/1",
            command_schema = "test.export.coefficients/1",
            rate = SPA.Fraction(500, 1),
            exposure_duration_ns = 2_000_000,
        )
        product = joinpath(directory, "product")
        manifest = ExportConfiguration.export_simulation(
            path, product; configuration = wire
        )
        @test manifest == joinpath(product, "simulation.yaml")
        @test all(read(file) == bytes for (file, bytes) in before)
        @test startswith(read(manifest, String), "# Generated")
        @test startswith(read(joinpath(product, "graph.yaml"), String), "# Generated")
        @test !occursin(abspath(source), read(manifest, String))
        configuration = AdaptiveOpticsSimPipeWireHIL.Simulation.load(manifest)
        prepared = AdaptiveOpticsSimPipeWireHIL.Simulation.prepare(configuration)
        reference = ExportConfiguration.prepare_system(path)
        @test graph_input(prepared.graph, :command) ==
            graph_input(reference.graph, :command)
        for command in (Float32[0, 0], Float32[1, -2], Float32[-3, 4])
            copyto_graph_input!(prepared.graph, :command, command)
            copyto_graph_input!(reference.graph, :command, command)
            step_graph!(prepared.graph)
            step_graph!(reference.graph)
            @test graph_output(prepared.graph, :frame) ==
                graph_output(reference.graph, :frame)
            @test graph_output(prepared.graph, :frame) ==
                (basis[:, :, 1] .* command[1] .+ basis[:, :, 2] .* command[2]) .*
                  Bool[1 0; 1 1]
        end
        @test prepared.configuration.frame_schema == wire.frame_schema
        @test prepared.configuration.command_scale == wire.command_scale
        @test_throws ArgumentError ExportConfiguration.export_simulation(
            path, product; configuration = wire
        )
        incompatible = PipeWireHILConfiguration(;
            remote = wire.remote,
            frame_node_name = wire.frame_node_name,
            command_node_name = wire.command_node_name,
            frame_schema = "test.incompatible-frame/1",
            command_schema = wire.command_schema,
            rate = wire.rate,
            exposure_duration_ns = wire.exposure_duration_ns,
        )
        rejected = joinpath(directory, "rejected")
        @test_throws ArgumentError ExportConfiguration.export_simulation(
            path, rejected; configuration = incompatible
        )
        @test !ispath(rejected)
        relocated = joinpath(directory, "relocated")
        mv(product, relocated)
        # Run independently: the source files and RTC package are not loaded.
        rm(source; recursive = true)
        code =
            "using AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsSim; " *
            "S = AdaptiveOpticsSimPipeWireHIL.Simulation; " *
            "p = S.prepare(S.load(ARGS[1])); " *
            "@assert size(AdaptiveOpticsSim.AlgorithmGraphs.hil_frame_buffer(p.boundary)) == (2, 2); " *
            "@assert all(id -> id.name != \"PipeWireAORTC\", keys(Base.loaded_modules)); " *
            "println(\"PASS: relocated HIL product loads without RTC or original authoring files\")"
        @test success(
            `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $code $(joinpath(relocated, "simulation.yaml"))`,
        )
    end
end

@testset "managed HIL preparation reloads the sealed application" begin
    simulation = AdaptiveOpticsSimPipeWireHIL.Simulation
    owner = PipeWireAORTC.AOSOwner
    prefix = String(LibPipeWire.PipeWireAO_jll.artifact_dir)
    withenv("PIPEWIREAO_PREFIX" => prefix) do
        mktempdir() do application
            wire_contract = Dict(
                "frame_encoding" => "uint16",
                "frame_schema" => "test.export.opd/1",
                "command_schema" => "test.export.coefficients/1",
                "command_scale" => 1,
            )
            (; document) = modal_simulation_source(application; wire_contract)
            physical_path = joinpath(application, "instrument.yaml")
            physical = ExportCommon.read_yaml(physical_path)
            merge!(
                physical["wavefront_sensors"]["sensor"],
                Dict(
                    "detector_shape" => [2, 2],
                    "pupil_shape" => [1, 1],
                    "expected_schema" => wire_contract["frame_schema"],
                ),
            )
            ExportCommon.write_yaml(physical_path, physical)
            ExportConfiguration.prepare_publication(application)
            merge!(
                document,
                wire_contract,
                Dict(
                    "command_input" => "command",
                    "frame_output" => "frame",
                    "frame_shape" => [2, 2],
                ),
            )
            config_path = joinpath(application, "simulation.conf")
            PipeWireAORTC.ScienceExport.write_spa_config(config_path, document)
            ExportConfiguration.prepare_simulation_configuration!(application)

            receipt_path = joinpath(application, ExportConfiguration.SIMULATOR_PREPARATION)
            ExportConfiguration.stage_simulator_preparation!(application, prefix)
            @test !isfile(receipt_path)
            load_receipt() = ExportConfiguration.read_simulator_preparation(
                owner.configuration(config_path),
            )
            @test load_receipt() === nothing
            environment = dirname(Base.active_project())
            for file in ("Project.toml", "Manifest.toml")
                cp(joinpath(environment, file), joinpath(application, file))
            end
            ExportConfiguration.stage_simulator_preparation!(application, prefix)
            deployment_path = joinpath(application, "deployment.conf")
            ExportCommon.write_json(deployment_path, Dict("artifacts" => Dict()))
            PipeWireAORTC.InstrumentExport.seal!(application)

            loaded = load_receipt()
            @test loaded.document == ExportConfiguration.json_value(
                ExportConfiguration.graph_document(loaded.declaration, loaded.configured)
            )
            @test simulation.prepare_lockstep_startup(config_path) === nothing

            deployment = ExportCommon.read_json(deployment_path)
            delete!(deployment["artifacts"], relpath(receipt_path, application))
            ExportCommon.write_json(deployment_path, deployment)
            @test_throws "simulator preparation input is not sealed" load_receipt()
            PipeWireAORTC.InstrumentExport.seal!(application)

            for path in (joinpath(application, "Manifest.toml"), config_path)
                original = read(path)
                open(io -> write(io, "\n"), path, "a")
                @test_throws "startup preparation differs from the sealed application" load_receipt()
                write(path, original)
            end

            receipt_bytes = read(receipt_path)
            receipt = ExportCommon.read_json(receipt_path)
            for identity in ("calibration_identity", "prescription_identity")
                original = receipt[identity]
                receipt[identity] = "sha256:" * repeat("0", 64)
                ExportCommon.write_json(receipt_path, receipt)
                @test_throws "startup preparation differs from the sealed application" load_receipt()
                receipt[identity] = original
            end
            write(receipt_path, receipt_bytes)
            @test load_receipt().document == loaded.document
        end
    end
end
