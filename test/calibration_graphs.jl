# Optional cold CPU selector. Point at a built Classic application; no source
# instrument, PipeWire core, model stepping or accelerator is used.
using Test, SHA
using PipeWireAORTC, FilterGraphIsland, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration

const Calibration = PipeWireAORTC.InstrumentCalibration
const Deployment = PipeWireAORTC.DeploymentConfiguration
const application = ENV["PIPEWIREAORTC_CALIBRATION_APPLICATION"]
const prefix = get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
const frontend_inputs = (raw="pixel-calibration:raw",)
const frontend_outputs = (:slopes, :flux, :validity)
const command_inputs = (requested="pdm-command:requested",)
const command_outputs = (:demanded, Symbol("constraint-feedback"))

function application_hashes(directory)
    return Dict(relpath(joinpath(root, file), directory) =>
        bytes2hex(sha256(read(joinpath(root, file))))
        for (root, _, files) in walkdir(directory) for file in files)
end

@testset "cold projections retain regular Classic scientific authority" begin
    before = application_hashes(application)
    original = Deployment.decode(joinpath(application, "rtc", "graph.conf"), prefix)
    original_nodes = Dict(node["name"]=>node for node in original["filter.graph"]["nodes"])
    parameters = Calibration.read_parameters(application)
    frontend = command = nothing
    try
        frontend = Calibration.calibration_graph(application;
            inputs=frontend_inputs, outputs=frontend_outputs)
        command = Calibration.calibration_graph(application;
            inputs=command_inputs, outputs=command_outputs)
        @test Set(node["name"] for node in frontend.document["filter.graph"]["nodes"]) ==
            Set(("pixel-calibration", "shack-hartmann"))
        @test only(command.document["filter.graph"]["nodes"]) == original_nodes["pdm-command"]
        @test all(node == original_nodes[node["name"]] for node in frontend.document["filter.graph"]["nodes"])
        @test only(frontend.document["filter.graph"]["links"]) ==
            Dict("input"=>"shack-hartmann:image", "output"=>"pixel-calibration:calibrated")
        @test isempty(command.document["filter.graph"]["links"])
        @test Set(keys(frontend.parameters)) == Set(Symbol.(("background", "subaperture-origins",
            "coordinates", "reference-slopes", "thresholds", "active")))
        @test all(isequal(values, parameters[name]) for (name, values) in frontend.parameters)
        @test isempty(command.parameters) && isempty(command.bindings)
        @test all(entry.source.path == only(filter(original -> original.port == entry.port,
            PipeWireAORTC.GraphOwner.bindings(joinpath(application, "rtc", "parameters.conf")))).source.path
            for entry in frontend.bindings)
        raw = JuliaFilterGraph.input_formats(frontend.graph).raw
        @test raw.element_type === UInt16 && raw.shape == (352,352)
        measurements = JuliaFilterGraph.output_formats(frontend.graph)
        @test measurements.slopes.element_type === Float32 && measurements.slopes.shape == (188,2)
        @test measurements.flux.element_type === Float32 && measurements.flux.shape == (188,)
        @test measurements.validity.element_type === Bool && measurements.validity.shape == (188,)
        requested = JuliaFilterGraph.input_formats(command.graph).requested
        demanded = JuliaFilterGraph.output_formats(command.graph).demanded
        @test requested.element_type === Float32 && requested.shape == (277,)
        @test demanded.element_type === Float32 && demanded.shape == (277,)
        @test requested.schema == "pipewireao/requested-pdm-command-f32/1"
        @test demanded.schema == "pipewireao/dm-command-opd-um-f32/1"
        authority = Calibration.controller_graph(application)
        try
            @test demanded == JuliaFilterGraph.output_formats(authority).demanded
            @test all(getproperty(JuliaFilterGraph.parameter_formats(frontend.graph), name) ==
                getproperty(JuliaFilterGraph.parameter_formats(authority), name) for name in keys(frontend.parameters))
        finally
            FilterGraphIsland.close_execution(authority)
        end
        @test frontend.source_graph_sha256 == command.source_graph_sha256 == Calibration.digest(joinpath(application,"rtc","graph.conf"))
        @test_throws ArgumentError Calibration.calibration_graph(application;
            inputs=(requested="pdm-command:missing",), outputs=command_outputs)
        @test_throws ArgumentError Calibration.calibration_graph(application;
            inputs=merge(frontend_inputs, command_inputs), outputs=frontend_outputs)
        @test_throws ArgumentError Calibration.calibration_graph(application;
            inputs=frontend_inputs, outputs=(:missing,))
        @test_throws ArgumentError Calibration.calibration_graph(application;
            inputs=(background="pixel-calibration:background",), outputs=frontend_outputs)
        @test_throws ArgumentError Calibration.calibration_graph(application;
            inputs=(requested="pdm-command:requested", duplicate="pdm-command:requested"), outputs=command_outputs)
        for selection in ((physical=:demanded, residual=Symbol("constraint-feedback")),
                (physical="pdm-command:demanded", residual="pdm-command:constraint-feedback"))
            aliased = Calibration.calibration_graph(application; inputs=command_inputs, outputs=selection)
            try
                @test only(aliased.document["filter.graph"]["nodes"]) == original_nodes["pdm-command"]
                @test isempty(aliased.document["filter.graph"]["links"])
                formats=JuliaFilterGraph.output_formats(aliased.graph)
                @test keys(formats) == (:physical,:residual)
                @test formats.physical == demanded
                @test formats.residual == JuliaFilterGraph.output_formats(command.graph)[Symbol("constraint-feedback")]
                @test [port["endpoint"] for port in aliased.document["filter.graph"]["outputs"]] ==
                    ["pdm-command:demanded","pdm-command:constraint-feedback"]
            finally
                FilterGraphIsland.close_execution(aliased.graph)
            end
        end
        for selection in ((physical=:missing,), (physical="missing:demanded",),
                (physical=:demanded, duplicate=:demanded),
                (physical=:demanded, duplicate="pdm-command:demanded"))
            @test_throws ArgumentError Calibration.calibration_graph(application; inputs=command_inputs, outputs=selection)
        end
        for endpoint in ("pdm-command:missing","pdm-command:requested")
            @test_throws Exception Calibration.calibration_graph(application;
                inputs=command_inputs, outputs=(physical=endpoint,))
        end
        @test_throws Exception Calibration.calibration_graph(application;
            inputs=frontend_inputs, outputs=(parameter="shack-hartmann:active",))

        mktempdir() do directory
            cp(joinpath(application,"rtc"),joinpath(directory,"rtc"))
            cp(joinpath(application,"deployment.conf"),joinpath(directory,"deployment.conf"))
            cp(joinpath(application,"instrument.json"),joinpath(directory,"instrument.json"))
            symlink(joinpath(application,"calibration"),joinpath(directory,"calibration"))
            path = joinpath(directory,"rtc","parameters.conf")
            bindings = Deployment.decode(path,prefix)
            filter!(entry -> entry["port"] != "background",bindings["parameters"])
            PipeWireAORTC.ScienceExport.write_spa_config(path,bindings)
            error = try
                Calibration.calibration_graph(directory; inputs=frontend_inputs, outputs=frontend_outputs)
                nothing
            catch caught
                caught
            end
            @test error isa ArgumentError
            @test occursin("missing its FITS binding", sprint(showerror,error))
        end
    finally
        frontend === nothing || FilterGraphIsland.close_execution(frontend.graph)
        command === nothing || FilterGraphIsland.close_execution(command.graph)
    end
    @test application_hashes(application) == before
    @test !any(id.name in ("CUDA", "AMDGPU") for id in keys(Base.loaded_modules))
end
