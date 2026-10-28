using Test, PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration
Base.include(@__MODULE__, joinpath(@__DIR__, "zemax_component_documents.jl"))

@testset "imported optical components remain ordinary cold graph declarations" begin
    mktempdir() do directory
        physical, simulation = zemax_component_documents(directory)
        path = write_external_optical_documents(directory, physical, simulation)
        declaration = IC.load_simulation(path)
        @test Set(declaration.templates) == Set(("proper_optical_train_f32",))
        @test IC.physical_definition(declaration.instrument).optical_planes.entrance_pupil.diameter_m == 0.012
        node = only(declaration.graphs["scc"]["nodes"])
        @test node["type"] == "proper_optical_train_f32"
        @test node["preparation"] == simulation["components"]["optics"]["preparation"]
        @test !haskey(node["config"], "steps")
        @test !isdir(joinpath(directory, "generated"))
        error = try IC.graph_document(declaration, IC.settings(declaration); simulation_graph="scc") catch error; error end
        @test error isa ArgumentError
        @test occursin("requires AdaptiveOpticsSim", sprint(showerror, error))
        @test all(id -> id.name ∉ ("AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", "CUDA", "AMDGPU", "Proper"), keys(Base.loaded_modules))
    end
end

@testset "pupil amplitude authoring requires an explicit real floating-point type" begin
    configured = Dict("pupil_resolution" => 4)
    schema = Dict("properties" => Dict("pupil_resolution" => Dict("type" => "integer")))
    for datatype in ("Float32", "Float64"), resolution in (4, "pupil_resolution", Dict("\$ref" => "/settings/pupil_resolution"))
        binding = Dict("kind" => "pupil_amplitude", "resolution" => resolution, "type" => datatype)
        @test IC._validate_bindings(Dict("amplitude" => binding), Dict(), configured,
            schema, Dict(), @__DIR__) === nothing
    end
    for binding in (Dict("kind" => "pupil_amplitude", "resolution" => 4),
            (Dict("kind" => "pupil_amplitude", "resolution" => 4, "type" => T)
                for T in ("Bool", "UInt16", "Float16"))...)
        @test_throws ArgumentError IC._validate_bindings(Dict("amplitude" => binding),
            Dict(), configured, schema, Dict(), @__DIR__)
    end
end

@testset "component import validates bounded fields and contained authored sources" begin
    for mutate! in (
            (physical, simulation) -> (simulation["components"]["optics"]["template"] = "ingaas"),
            (physical, simulation) -> (simulation["components"]["optics"]["preparation"]["kind"] = "other"),
            (physical, simulation) -> (simulation["components"]["optics"]["preparation"]["branch"] = "../branch"),
            (physical, simulation) -> (simulation["components"]["optics"]["preparation"]["unknown"] = 1),
            (physical, simulation) -> (simulation["components"]["optics"]["preparation"]["recipe"] = "../outside.yaml"),
            (physical, simulation) -> (simulation["components"]["optics"]["preparation"]["recipe"] = "simulation/missing.yaml"),
            (physical, simulation) -> (simulation["components"]["optics"]["preparation"]["recipe"] = "simulation/../simulation/zemax.yaml"),
            (physical, simulation) -> (simulation["components"]["optics"]["config"]["steps"] = []),
            (physical, simulation) -> (simulation["components"]["optics"]["config"]["channels"] = []),
            (physical, simulation) -> delete!(simulation["components"]["optics"]["config"], "temperature_c"),
            (physical, simulation) -> (only(simulation["graphs"]["scc"]["nodes"])["config"] = Dict("steps" => [])),
            (physical, simulation) -> delete!(physical, "optical_prescription"),
            (physical, simulation) -> (physical["optical_planes"] = Dict()),
            (physical, simulation) -> (physical["optical_planes"]["entrance_pupil"]["diameter_m"] = 0),
            (physical, simulation) -> (physical["optical_planes"]["entrance_pupil"]["diameter_m"] = true),
            (physical, simulation) -> (physical["optical_planes"]["entrance_pupil"]["aperture_m"] = 0.1),
            (physical, simulation) -> (physical["optical_planes"]["invalid/plane"] = Dict("diameter_m" => 0.1)))
        mktempdir() do directory
            physical, simulation = zemax_component_documents(directory)
            mutate!(physical, simulation)
            path = write_external_optical_documents(directory, physical, simulation)
            @test_throws ArgumentError IC.load_simulation(path)
        end
    end
    @test_throws ArgumentError IC._validate_optical_planes(Dict("entrance_pupil" => Dict("diameter_m" => Inf)))
    mktempdir() do directory
        physical, simulation = zemax_component_documents(directory)
        mktempdir() do outside
            write(joinpath(outside, "recipe.yaml"), "schema_version: 1\n")
            symlink(joinpath(outside, "recipe.yaml"), joinpath(directory, "simulation", "escape.yaml"))
            simulation["components"]["optics"]["preparation"]["recipe"] = "simulation/escape.yaml"
            @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError IC.load_simulation(write_external_optical_documents(directory, physical, simulation))
        end
        mkpath(joinpath(directory, "generated"))
        write(joinpath(directory, "generated", "recipe.yaml"), "schema_version: 1\n")
        simulation["components"]["optics"]["preparation"]["recipe"] = "generated/recipe.yaml"
        @test_throws ArgumentError IC.load_simulation(write_external_optical_documents(directory, physical, simulation))
    end
end

@testset "named HIL optical reference preserves unselected production and native schemas" begin
    mktempdir() do directory
        physical, simulation = zemax_component_documents(directory)
        PipeWireAORTC.Common.write_json(joinpath(directory, "mirror.json"), Dict(
            "schema_version" => 1, "id" => "reference-mirror", "manufacturer" => "Example", "model" => "Synthetic",
            "layout" => Dict("schema_version" => 1, "name" => "Reference grid", "grid_shape" => [2, 2],
                "command_positions" => [[1, 1]], "axis_labels" => ["column", "row"], "command_order" => "physical")))
        physical["deformable_mirrors"] = Dict("reference" => Dict("description" => "mirror.json",
            "pupil_registration" => Dict("actuator_pitch_pupil_radius" => 0.2), "units" => "m", "command_scale_m" => 1))
        # A native, unimported branch remains executable in the core-only loader.
        native = deepcopy(only(simulation["graphs"]["scc"]["nodes"]))
        native["name"], native["type"], native["config"] = "optics", "caller_supplied_optics", Dict("value" => 2)
        graphs = Dict{String,Any}("optical-reference" => simulation["graphs"]["scc"])
        for mode in ("production", "calibration")
            graph = deepcopy(simulation["graphs"]["llowfs"])
            graph["nodes"] = [deepcopy(native)]
            graphs[mode] = graph
        end
        simulation["graphs"] = graphs
        simulation["hil"] = Dict("command" => "optics.pupil_opd", "frame" => "optics.output")
        simulation["wire_contracts"] = [Dict("frame_encoding" => "uint16", "frame_schema" => "example.raw-adc/1",
            "command_schema" => "example.command/1", "command_scale" => 1)]
        path = write_external_optical_documents(directory, physical, simulation)
        declaration = IC.load_simulation(path)
        @test Set(keys(declaration.graphs)) == Set(("production", "calibration", "optical-reference"))
        graph = IC.graph_document(declaration, IC.settings(declaration))
        @test only(graph["nodes"])["config"] == Dict("value" => 2)
        @test declaration.document["wire_contracts"] == simulation["wire_contracts"]
        @test declaration.document["hil"] == Dict("command_input" => "pupil_opd", "frame_output" => "intensity")
        @test "simulation/zemax.yaml" in IC.artifact_paths(declaration, IC.settings(declaration))
        @test_throws ArgumentError IC.graph_document(declaration, IC.settings(declaration); simulation_graph="optical-reference")
        @test_throws ArgumentError IC.simulation_graph_sources(Dict("hil" => Dict(), "graphs" => Dict("optical-reference" => Dict())))
        @test_throws ArgumentError IC.simulation_graph_sources(Dict("graphs" => Dict("invalid/name" => Dict())))
    end
end
