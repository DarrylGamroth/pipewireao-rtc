module GraphConfigurationTests

using Test, PipeWireAORTC

const E = PipeWireAORTC.InstrumentExport
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const PREFIX = get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
reference(pointer) = Dict("\$ref" => pointer)

function instrument()
    Dict("deformable_mirrors" => Dict("mirror-one" => Dict("layout" =>
            Dict("command_positions" => [[1, 1], [2, 1], [3, 1]]))),
        "wavefront_sensors" => Dict("sensor-one" => Dict("layout" =>
            Dict("detector_shape" => [3, 7], "subaperture_shape" => [1, 2],
                "subaperture_origins" => [[0, 0], [1, 2]]))))
end

dimensions(n=5) = Dict("controller_command_count" => n)

function graph()
    Dict("node.name" => "generic-graph", "filter.graph" => Dict(
        "nodes" => [Dict("name" => "arbitrary-node", "label" => "arbitrary-algorithm",
            "props" => Dict("gain" => -0.3), "config" => Dict(
                "image_size" => reference("/instrument/wavefront_sensors/sensor-one/layout/detector_shape"),
                "actuator_count" => reference("/instrument/deformable_mirrors/mirror-one/actuator_count"),
                "controller_command_count" => reference("/rtc/dimensions/controller_command_count"),
                "nested" => [reference("/instrument/wavefront_sensors/sensor-one/subaperture_count"), 9]))],
        "links" => [], "inputs" => ["arbitrary-node:input"], "outputs" => ["arbitrary-node:output"]))
end

@testset "typed graph references retain instrument and coordinate meanings" begin
    scientific = instrument()
    context = E.graph_context(scientific; dimensions=dimensions())
    resolved = E.resolve_graph_configuration(graph(), context)
    node = only(resolved["filter.graph"]["nodes"])
    @test node["config"]["image_size"] == [3, 7]
    @test node["config"]["actuator_count"] == 3
    @test node["config"]["controller_command_count"] == 5
    @test node["config"]["nested"] == [2, 9]
    @test node["props"] == Dict("gain" => -0.3)
    @test resolved["filter.graph"]["inputs"] == graph()["filter.graph"]["inputs"]
    @test !haskey(scientific["deformable_mirrors"]["mirror-one"], "actuator_count")
    node["config"]["image_size"][1] = 99
    @test context["instrument"]["wavefront_sensors"]["sensor-one"]["layout"]["detector_shape"] == [3, 7]
    @test haskey(only(graph()["filter.graph"]["nodes"])["config"]["image_size"], "\$ref")
    @test !haskey(context, "parameters")
    @test_throws ArgumentError E.graph_pointer(context, "/parameters/projection/shape/0")

end

@testset "selected-pixel validity uses the selected extent" begin
    context = E.graph_context(instrument(); dimensions=Dict("selected_pixel_count"=>3))
    @test E.graph_pointer(context,"/rtc/selected_pixel_mask") == trues(3)
    @test_throws ArgumentError E.graph_context(instrument(); dimensions=Dict("selected_pixel_count"=>0))
end

@testset "pyramid graph and session references share the declared calibration context" begin
    scientific = Dict("deformable_mirrors" => instrument()["deformable_mirrors"],
        "wavefront_sensors" => Dict("sensor-one" => Dict("layout" => Dict(
            "kind" => "pyramid", "detector_shape" => [8, 12], "pupil_shape" => [2, 3],
            "pupil_origins" => [[1, 1], [5, 1], [1, 8], [5, 8]]))))
    calibration = Dict("pupil" => Dict("shape" =>
        reference("/instrument/wavefront_sensors/sensor-one/layout/pupil_shape"),
        "selected_pixel_count" => 5))
    context = E.graph_context(scientific; calibration)
    @test context["calibration"]["pupil"]["shape"] == [2, 3]
    @test !haskey(context["instrument"]["wavefront_sensors"]["sensor-one"], "subaperture_count")
    @test haskey(calibration["pupil"]["shape"], "\$ref")
    mktempdir() do directory
        C.write_json(joinpath(directory, "instrument.json"), scientific)
        declaration = graph()
        only(declaration["filter.graph"]["nodes"])["config"] = Dict("count" =>
            reference("/calibration/pupil/selected_pixel_count"))
        C.write_json(joinpath(directory, "graph.conf"), declaration)
        E.prepare_graph_configurations!(directory, [Dict("path" => "graph.conf")],
            "instrument.json", PREFIX; calibration)
        @test only(D.decode(joinpath(directory, "graph.conf"), PREFIX)["filter.graph"]["nodes"])["config"]["count"] == 5
        C.write_json(joinpath(directory, "session.conf"), Dict("shape" => reference("/calibration/pupil/shape")))
        C.write_json(joinpath(directory, "core.conf"), Dict())
        E.prepare_session_configuration!(directory, Dict("session" => "session.conf", "core" => "core.conf"),
            [], "instrument.json", PREFIX; calibration)
        @test D.decode(joinpath(directory, "session.conf"), PREFIX)["shape"] == [2, 3]
    end
end

@testset "JSON Pointer preserves escaping and rejects invalid references" begin
    context = Dict("" => 4, "a/b" => Dict("~key" => [3, 7]), "~1" => 8)
    @test E.graph_pointer(context, "") === context
    @test E.graph_pointer(context, "/") == 4
    @test E.graph_pointer(context, "/a~1b/~0key/1") == 7
    @test E.graph_pointer(context, "/~01") == 8
    for pointer in ("#/~01", "a~1b", "/missing", "/a~2b", "/a~", "/a~1b/~0key/2",
            "/a~1b/~0key/01", "/a~1b/~0key/0\n", "/a~1b/~0key/-1", "/a~1b/~0key/-",
            "/a~1b/~0key/9999999999999999999999999999", "/~01/child")
        @test_throws ArgumentError E.graph_pointer(context, pointer)
    end
    for invalid in (Dict("\$ref" => 3), Dict("\$ref" => "/", "extra" => 1))
        @test_throws ArgumentError E.graph_configuration_value(invalid, context)
    end
end

@testset "graph materialization is declared, generated and validated before writing" begin
    mktempdir() do directory
        C.write_json(joinpath(directory, "instrument.json"), instrument())
        C.write_json(joinpath(directory, "graph.conf"), graph())
        entries = [Dict("path" => "graph.conf")]
        E.prepare_graph_configurations!(directory, entries, "instrument.json", PREFIX; dimensions=dimensions(11))
        text = read(joinpath(directory, "graph.conf"), String)
        @test startswith(text, "# Generated by PipeWireAORTC")
        @test occursin("do not edit", text)
        @test occursin("instrument definition", first(split(text, '\n')))
        compiled = D.decode(joinpath(directory, "graph.conf"), PREFIX)
        @test only(compiled["filter.graph"]["nodes"])["config"]["controller_command_count"] == 11
        @test !occursin("\$ref", text)
        # No first-file overwrite if a later declaration fails to resolve.
        C.write_json(joinpath(directory, "graph.conf"), graph())
        broken = graph()
        only(broken["filter.graph"]["nodes"])["config"]["image_size"] = reference("/missing")
        C.write_json(joinpath(directory, "broken.conf"), broken)
        before = read(joinpath(directory, "graph.conf"))
        @test_throws ArgumentError E.prepare_graph_configurations!(directory,
            [entries[1], Dict("path" => "broken.conf")],
            "instrument.json", PREFIX; dimensions=dimensions(11))
        @test read(joinpath(directory, "graph.conf")) == before
        @test_throws ArgumentError E.prepare_graph_configurations!(directory,
            [entries[1], entries[1]], "instrument.json", PREFIX; dimensions=dimensions(11))
        mktemp() do outside, stream
            @test_throws D.DeploymentError E.prepare_graph_configurations!(directory,
                [Dict("path" => relpath(outside, directory))], "instrument.json", PREFIX; dimensions=dimensions(11))
        end
        @test_throws ArgumentError E.prepare_graph_configurations!(directory,
            [Dict("path" => "graph.conf", "unknown" => true)], "instrument.json", PREFIX; dimensions=dimensions(11))
        @test_throws ArgumentError E.prepare_graph_configurations!(directory,
            Dict(), "instrument.json", PREFIX; dimensions=dimensions(11))
    end
end

@testset "calibrated graph exports preserve exact scientific fields and output order" begin
    frozen = E.resolve_graph_configuration(graph(),E.graph_context(instrument();dimensions=dimensions()))
    frozen["filter.graph"] = Dict{String,Any}(frozen["filter.graph"])
    frozen["filter.graph"]["outputs"] = Any[Dict("name"=>"command","endpoint"=>"arbitrary-node:output"),
        Dict("name"=>"status","endpoint"=>"arbitrary-node:status")]
    @test isempty(E.calibrated_graph_exports(deepcopy(frozen),frozen))
    for change in (
        row -> row["filter.graph"]["nodes"][1]["props"]["gain"] = -0.31,
        row -> row["filter.graph"]["nodes"][1]["config"]["actuator_count"] = 3.0,
        row -> row["filter.graph"]["nodes"][1]["config"]["actuator_count"] = true,
        row -> pop!(row["filter.graph"]["nodes"]),
        row -> push!(row["filter.graph"]["links"],Dict("output"=>"arbitrary-node:output","input"=>"other:input")),
        row -> push!(row["filter.graph"]["inputs"],"arbitrary-node:other"),
        row -> pop!(row["filter.graph"]["outputs"]),
        row -> reverse!(row["filter.graph"]["outputs"]),
        row -> row["filter.graph"]["outputs"][1]["name"] = "renamed",
        row -> row["filter.graph"]["outputs"][1]["endpoint"] = "arbitrary-node:other",
        row -> row["node.name"] = "another-graph",
        row -> row["unknown"] = nothing,
    )
        changed = deepcopy(frozen); change(changed)
        @test_throws ArgumentError E.calibrated_graph_exports(changed,frozen)
    end
    for output in (Dict("name"=>"command","endpoint"=>"arbitrary-node:extra"),
        Dict("name"=>"extra","endpoint"=>"arbitrary-node:output"),
        Dict("name"=>"extra","endpoint"=>"arbitrary-node"),
        Dict("name"=>"extra","endpoint"=>"arbitrary-node:extra","unknown"=>true))
        changed = deepcopy(frozen); push!(changed["filter.graph"]["outputs"],output)
        @test_throws ArgumentError E.calibrated_graph_exports(changed,frozen)
    end
    @test !E.exact_graph_value(Dict("value"=>true),Dict("value"=>1))
    @test !E.exact_graph_value(Dict("value"=>1),Dict("value"=>1.0))
    absent = deepcopy(frozen); delete!(absent["filter.graph"],"outputs")
    @test isempty(E.calibrated_graph_exports(absent,absent))
    empty = deepcopy(absent); empty["filter.graph"]["outputs"] = Any[]
    @test_throws ArgumentError E.calibrated_graph_exports(empty,absent)
    null = deepcopy(absent); null["filter.graph"]["outputs"] = nothing
    @test_throws ArgumentError E.calibrated_graph_exports(null,null)
    @test frozen["filter.graph"]["outputs"][1]["name"] == "command"
end

end
