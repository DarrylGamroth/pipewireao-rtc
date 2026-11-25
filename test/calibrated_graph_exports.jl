# Optional cold owner-compiler and numerical check; no core, GPU or optical preparation.
# Run in the science environment with PIPEWIREAO_PREFIX set to its native SDK.
using Test, PipeWireAORTC, FilterGraphAlgorithms, FilterGraphPipeWire, FilterGraphs

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const S = PipeWireAORTC.Schemas.CATALOG

function command_graph()
    Dict(
        "node.name" => "command-exports",
        "filter.graph" => Dict(
            "nodes" => [
                Dict(
                    "name" => "completion",
                    "type" => "ndarray",
                    "label" => "vdm-to-pdm-f32",
                    "config" => Dict(
                        "active_vdm_count" => 2,
                        "full_vdm_count" => 3,
                        "physical_actuator_count" => 4,
                    ),
                ),
                Dict(
                    "name" => "command",
                    "type" => "ndarray",
                    "label" => "pdm-command-f32",
                    "config" => Dict(
                        "actuator_count" => 4,
                        "command_limits" => [-0.5, 0.5],
                        "slew_limit" => nothing,
                        "initial_current" => nothing,
                        "quantization_origin" => nothing,
                        "quantization_step" => nothing,
                        "dither_seed" => nothing,
                    ),
                ),
            ],
            "links" => [
                Dict(
                    "output" => "completion:requested-pdm-command",
                    "input" => "command:requested",
                ),
            ],
            "inputs" => [
                Dict("name" => "input", "endpoint" => "completion:vdm-command"),
                Dict("name" => "completion", "endpoint" => "completion:active-to-full"),
                Dict("name" => "projection", "endpoint" => "completion:vdm-to-pdm"),
            ],
            "outputs" => [Dict("name" => "demanded", "endpoint" => "command:demanded")],
        ),
    )
end

@testset "Controller resize regenerates the saved calibration and port contracts" begin
    calibration = PipeWireAORTC.InstrumentCalibration
    instrument = PipeWireAORTC.InstrumentConfiguration
    write_config = PipeWireAORTC.ScienceExport.write_spa_config
    decode = PipeWireAORTC.DeploymentConfiguration.decode
    prefix = ENV["PIPEWIREAO_PREFIX"]
    reference(path) = Dict("\$ref" => path)

    mktempdir() do application
        rtc = mkdir(joinpath(application, "rtc"))
        gui = mkdir(joinpath(application, "gui"))
        positions = [[1, 1], [2, 1], [1, 2], [2, 2]]
        C.write_yaml(joinpath(application, "mirror.yaml"), Dict(
            "schema_version" => 1, "id" => "resize-mirror", "manufacturer" => "Example",
            "model" => "Four commands", "layout" => Dict(
                "schema_version" => 1, "name" => "Ordered commands", "grid_shape" => [2, 2],
                "command_positions" => positions, "axis_labels" => ["column", "row"],
                "command_order" => "listed",
            ),
        ))
        C.write_yaml(joinpath(application, "instrument.yaml"), Dict(
            "schema_version" => 1, "id" => "resize-instrument",
            "wavefront_sensors" => Dict("camera" => Dict(
                "kind" => "scc", "expected_schema" => "test/resize-detector/1",
                "detector" => Dict("name" => "camera", "rows" => 2, "columns" => 2,
                    "pixel_sampling_m" => [1e-6, 1e-6]),
            )),
            "deformable_mirrors" => Dict("primary" => Dict(
                "description" => "mirror.yaml", "units" => "m OPD", "command_scale_m" => 1e-6,
                "pupil_registration" => Dict("actuator_pitch_pupil_radius" => 0.2),
            )),
        ))
        controls_path = joinpath(rtc, "mirror-controls.yaml")
        C.write_yaml(controls_path, Dict(
            "schema_version" => 1, "deformable_mirrors" => Dict("primary" => Dict(
                "limiter" => Dict("kind" => "amplitude", "lower" => -0.5, "upper" => 0.5),
                "shape_control" => Dict("bases" => []),
            )),
        ))
        configuration = joinpath(rtc, "configuration.yaml")
        active = reference("/rtc/controller/command_count")
        C.write_yaml(configuration, Dict(
            "schema_version" => 1, "instrument" => "../instrument.yaml",
            "controller" => Dict("command_count" => 2, "hidden_modes" => ["mean-command"]),
            "dimensions" => Dict("active_vdm_count" => active),
            "mirror_controls" => "rtc/mirror-controls.yaml", "publication" => "instrument.json",
            "calibration_identity" => "sha256:" * "0"^64,
        ))
        publication_path = instrument.prepare_publication(application)

        template = command_graph()
        completion_node, command_node = template["filter.graph"]["nodes"]
        input_ports = template["filter.graph"]["inputs"]
        completion_port, projection_port = Symbol("active-to-full"), Symbol("vdm-to-pdm")
        input_ports[2]["name"] = string(completion_port)
        input_ports[3]["name"] = string(projection_port)
        completion_node["config"] = merge(completion_node["config"], Dict(
            "active_vdm_count" => reference("/rtc/dimensions/active_vdm_count"),
        ))
        command_node["config"]["command_limits"] = [
            reference("/rtc/deformable_mirrors/primary/limiter/$bound") for bound in ("lower", "upper")
        ]
        template_path = joinpath(rtc, "graph.conf.in")
        graph_path = joinpath(rtc, "graph.conf")
        write_config(template_path, template)
        write_config(graph_path, E.resolve_graph_configuration(
            template, E.graph_context(instrument.load_rtc(configuration)),
        ))
        write_config(joinpath(rtc, "application.conf"), Dict("graph-configurations" => [
            Dict("path" => "rtc/graph.conf", "source" => "rtc/graph.conf.in"),
        ]))
        projection = Float32[1 0 0; 0 1 0; 0 0 1; 0 0 0]
        original = Dict(completion_port => Float32[1 0; 0 1; 0.5 -0.5], projection_port => projection)
        write_config(joinpath(rtc, "parameters.conf"), Dict("parameters" => [
            Dict("port" => string(port), "path" => "$port.fits", "axes" => [2, 1])
            for port in (completion_port, projection_port)
        ]))
        for (port, data) in original
            calibration.write_fits(joinpath(rtc, "$port.fits"), data)
        end
        @test Dict(calibration.read_parameters(application)) == original

        graph = template["node.name"]
        port(name) = Dict("name" => name, "shape" => [3, 2], "element-type" => "F32_LE")
        session_path = joinpath(rtc, "session.conf.in")
        write_config(session_path, Dict(
            "graphs" => [Dict("node.name" => graph, "ports" => [
                merge(port(string(completion_port)), Dict("parameter" => true)),
            ])],
            "sources" => [Dict("node.name" => "parameters", "ports" => [port(string(completion_port))])],
            "links" => [Dict(
                "output" => "parameters:$completion_port", "input" => "$graph:$completion_port",
            )],
        ))
        views_path = joinpath(gui, "operator-views.yaml")
        C.write_yaml(views_path, Dict("views" => [Dict("binding" => Dict(
            "graph" => graph, "parameter" => string(completion_port), "shape" => [3, 2],
        ))]))

        parameters = merge(original, Dict(
            completion_port => reshape(Float32[1, -0.5, 0.25], 3, 1),
            Symbol("shape-to-hidden") => ones(Float32, 1, 1),
            Symbol("hidden-to-shape") => ones(Float32, 1, 1),
        ))
        limits = (; lower = -0.25, upper = 0.75)
        result = calibration.replace_dimensions!(application, parameters, 1;
            measurement_count = 2, command_limits = limits)
        @test result === nothing

        resized = instrument.load_rtc(configuration)
        @test resized.document["dimensions"] == Dict(
            "controller_command_count" => 1, "active_vdm_count" => 1, "hidden_mode_count" => 1,
        )
        @test resized.authoring["dimensions"]["active_vdm_count"] == active
        @test decode(template_path, prefix) == template
        nodes = decode(graph_path, prefix)["filter.graph"]["nodes"]
        @test first(nodes)["config"]["active_vdm_count"] == 1
        @test last(nodes)["config"]["command_limits"] == [-0.25, 0.75]
        @test Dict(calibration.read_parameters(application)) ==
            Dict(completion_port => parameters[completion_port], projection_port => projection)
        prepared = calibration.controller_graph(application)
        try
            output = (demanded = zeros(Float32, 4),)
            @test FilterGraphs.process!(output, prepared, (input = Float32[2],)) ==
                (demanded = true,)
            @test output.demanded == Float32[0.75, -0.25, 0.5, 0]
        finally
            FilterGraphPipeWire.close_execution(prepared)
        end
        published = C.read_json(publication_path)["deformable_mirrors"]["primary"]
        @test published["layout"]["command_positions"] == positions
        @test published["limiter"]["lower"] == fill(limits.lower, length(positions))
        @test published["limiter"]["upper"] == fill(limits.upper, length(positions))
        session = decode(session_path, prefix)
        for section in ("graphs", "sources")
            parameter_port = only(only(session[section])["ports"])
            @test parameter_port["shape"] == [3, 1]
            @test parameter_port["element-type"] == "F32_LE"
        end
        @test only(C.read_yaml(views_path)["views"])["binding"]["shape"] == [3, 1]
    end
end

@testset "append-only command feedback exports retain calibrated CPU results" begin
    frozen = command_graph()
    graph = deepcopy(frozen)
    added = [
        Dict("name" => "correction-role", "endpoint" => "completion:correction-role"),
        Dict("name" => "constraint-feedback", "endpoint" => "command:constraint-feedback"),
    ]
    append!(graph["filter.graph"]["outputs"], added)
    @test E.calibrated_graph_exports(graph, frozen) == added
    @test length(frozen["filter.graph"]["outputs"]) == 1
    mktempdir() do directory
        path = joinpath(directory, "executed.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path, graph)
        contracts = E.graph_port_contracts(path)["outputs"]
        @test contracts["correction-role"]["shape"] == [4]
        @test contracts["correction-role"]["element-type"] == "U8"
        @test contracts["correction-role"]["schema"] == S["pdm_correction_role"]["id"]
        @test contracts["constraint-feedback"]["shape"] == [4]
        @test contracts["constraint-feedback"]["element-type"] == "F32_LE"
        @test contracts["constraint-feedback"]["schema"] ==
            S["pdm_constraint_feedback"]["id"]
        baselinepath = joinpath(directory, "calibrated.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(baselinepath, frozen)
        baseline = FilterGraphs.prepare_graph(
            baselinepath; algorithms = FilterGraphAlgorithms.algorithms()
        )
        executed = FilterGraphs.prepare_graph(
            path; algorithms = FilterGraphAlgorithms.algorithms()
        )
        for prepared in (baseline, executed)
            FilterGraphs.replace_parameters!(
                prepared,
                :completion => Float32[1 0; 0 1; 0.5 -0.5],
                :projection => Float32[1 0 0; 0 1 0; 0 0 1; 0 0 0],
            )
        end
        old = (demanded = zeros(Float32, 4),)
        output = NamedTuple{(
            :demanded, Symbol("correction-role"), Symbol("constraint-feedback")
        )}((zeros(Float32, 4), zeros(UInt8, 4), zeros(Float32, 4)))
        for input in (Float32[2, -1], Float32[-0.25, 0.5], Float32[0, 0])
            @test FilterGraphs.process!(old, baseline, (; input)) == (demanded = true,)
            @test all(values(FilterGraphs.process!(output, executed, (; input))))
            @test old.demanded == output.demanded
            @test getproperty(output, Symbol("correction-role")) == UInt8[1, 1, 2, 0]
            requested = Float32[input[1], input[2], 0.5f0*(input[1]-input[2]), 0]
            @test getproperty(output, Symbol("constraint-feedback")) ==
                requested - output.demanded
        end
    end
    for endpoint in ("missing:correction-role", "completion:missing")
        changed = deepcopy(frozen)
        push!(
            changed["filter.graph"]["outputs"],
            Dict("name" => "roles", "endpoint" => endpoint),
        )
        @test_throws FilterGraphs.GraphConfigurationError E.calibrated_graph_exports(
            changed, frozen
        )
    end
    @test !any(id -> id.name in ("AMDGPU", "CUDA", "Proper"), keys(Base.loaded_modules))
end

@testset "controlled actuator projection formats without graph preparation" begin
    extension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt)
    names = (:completion, :inverse)
    shape = Dict(
        "type" => "ndarray",
        "name" => "shape",
        "label" => "vdm-shape-offset-f32",
        "config" => Dict(
            "active_vdm_count" => 2,
            "full_vdm_count" => 3,
            "physical_actuator_count" => 4,
        ),
    )
    inputs = [
        Dict("name" => "completion", "endpoint" => "shape:active-to-full"),
        Dict("name" => "inverse", "endpoint" => "shape:pdm-to-vdm"),
    ]
    graph = Dict("filter.graph" => Dict("nodes" => [shape], "inputs" => inputs))
    @test extension.shape_parameter_formats(graph, names, 4) == (
        completion = (element_type = Float32, shape = (3, 2)),
        inverse = (element_type = Float32, shape = (3, 4)),
    )
    @test_throws ArgumentError extension.shape_parameter_formats(graph, names, 3)
    @test_throws ArgumentError extension.shape_parameter_formats(graph, reverse(names), 4)
    inputs[2]["endpoint"] = "other:pdm-to-vdm"
    @test_throws ArgumentError extension.shape_parameter_formats(graph, names, 4)
end
