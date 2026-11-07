# Optional CPU selector: author once, export, then run the public HIL loader
# in a process that never imports RTC. No core, service or GPU is opened.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, FITSIO
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: copyto_graph_input!
using PipeWireAO: SPA
include(joinpath(@__DIR__, "aos_graph_documents.jl"))
const ExportConfiguration = PipeWireAORTC.InstrumentConfiguration
const ExportCommon = PipeWireAORTC.Common

function exported_simulation_source(directory)
    (; path) = aos_graph_documents(directory)
    simulation = ExportCommon.read_yaml(path)
    graph = Dict(
        "schema_version" => 1,
        "name" => "modal_simulation",
        "nodes" => [
            Dict(
                "name" => "modal",
                "type" => "modal_opd_expansion_f32",
                "config" => Dict(
                    "pupil_rows" => 2,
                    "pupil_columns" => 2,
                    "mode_count" => 2,
                    "coefficients_schema" => "test.export.coefficients/1",
                    "opd_schema" => "test.export.opd/1",
                    "basis_schema" => "test.export.basis/1",
                    "pupil_support_schema" => "test.export.support/1",
                ),
            ),
        ],
        "inputs" => [
            Dict(
                "name" => "command",
                "destination" => "modal.coefficients",
                "binding" => "command",
            ),
        ],
        "outputs" => [Dict("name" => "frame", "source" => "modal.opd")],
        "parameters" => [
            Dict("destination" => "modal.basis", "binding" => "basis"),
            Dict("destination" => "modal.pupil_support", "binding" => "support"),
        ],
    )
    basis = reshape(Float32.(1:8), 2, 2, 2)
    FITS(joinpath(directory, "basis.fits"), "w") do fits
        write(fits, basis)
    end
    FITS(joinpath(directory, "support.fits"), "w") do fits
        write(fits, UInt8[1 0; 1 1])
    end
    simulation["graphs"] = Dict("production" => graph, "calibration" => deepcopy(graph))
    simulation["components"] = Dict()
    simulation["profiles"] = Dict("ordinary" => Dict("nodes" => [], "parameters" => []))
    simulation["defaults"]["profile"] = "ordinary"
    simulation["settings_schema"]["properties"]["profile"]["enum"] = ["ordinary"]
    simulation["bindings"] = Dict(
        "command" => Dict("kind" => "zeros", "type" => "Float32", "shape" => [2]),
        "basis" => Dict(
            "kind" => "fits",
            "type" => "Float32",
            "path" => "basis.fits",
            "hdu" => 1,
            "axes" => [1, 2, 3],
            "shape" => [2, 2, 2],
        ),
        "support" => Dict(
            "kind" => "fits",
            "type" => "Bool",
            "path" => "support.fits",
            "hdu" => 1,
            "axes" => [1, 2],
            "shape" => [2, 2],
        ),
    )
    simulation["hil"] = Dict("command" => "modal.coefficients", "frame" => "modal.opd")
    simulation["wire_contracts"] = [
        Dict(
            "frame_encoding" => "float32",
            "frame_schema" => "test.export.opd/1",
            "command_schema" => "test.export.coefficients/1",
            "command_scale" => 1,
        ),
    ]
    ExportCommon.write_yaml(path, simulation)
    return (; path, basis)
end

@testset "standalone HIL export preserves authored graphs and typed bindings" begin
    mktempdir() do directory
        source = joinpath(directory, "source")
        mkpath(source)
        (; path, basis) = exported_simulation_source(source)
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
