using Test, PipeWireAORTC

const C = PipeWireAORTC.InstrumentCalibration
const Common = PipeWireAORTC.Common
Base.include(@__MODULE__, joinpath(@__DIR__, "external_optical_documents.jl"))

function recipe_application(directory, kind)
    physical, simulation = external_optical_documents()
    Common.write_json(
        joinpath(directory, "mirror.json"),
        Dict(
            "schema_version" => 1,
            "id" => "calibration-mirror",
            "manufacturer" => "Example",
            "model" => "Synthetic",
            "layout" => Dict(
                "schema_version" => 1,
                "name" => "Two actuators",
                "grid_shape" => [2, 2],
                "command_positions" => [[1, 1], [2, 2]],
                "axis_labels" => ["column", "row"],
                "command_order" => "physical",
            ),
        ),
    )
    physical["deformable_mirrors"]["primary"] = Dict(
        "description" => "mirror.json",
        "pupil_registration" => Dict("actuator_pitch_pupil_radius" => 0.2),
        "units" => "m",
        "command_scale_m" => 1,
    )
    sensor = if kind == "shack_hartmann"
        C.write_fits(joinpath(directory, "origins.fits"), zeros(Float32, 1, 2))
        Dict(
            "kind" => kind,
            "detector_shape" => [2, 2],
            "subaperture_shape" => [1, 1],
            "subaperture_origins" => Dict(
                "path" => "origins.fits",
                "hdu" => 1,
                "axes" => [2, 1],
                "type" => "Float32",
                "shape" => [1, 2],
            ),
            "expected_schema" => "test.frame/1",
        )
    elseif kind == "pyramid"
        Dict(
            "kind" => kind,
            "detector_shape" => [2, 2],
            "pupil_shape" => [1, 1],
            "pupil_separation_pixels" => [0, 0],
            "pupil_edge_pixels" => [0, 0],
            "expected_schema" => "test.frame/1",
        )
    else
        Dict("kind" => kind, "detector" => Dict("name" => "calibration-detector"))
    end
    physical["wavefront_sensors"] = Dict("sensor" => sensor)
    write_external_optical_documents(directory, physical, simulation)
    mkpath(joinpath(directory, "rtc"))
    Common.write_yaml(
        joinpath(directory, "rtc/configuration.yaml"),
        Dict(
            "schema_version" => 1,
            "instrument" => "../instrument.yaml",
            "dimensions" => Dict(),
            "mirror_controls" => "rtc/mirror-controls.yaml",
            "publication" => "instrument.json",
            "calibration_identity" => "sha256:" * repeat("a", 64),
        ),
    )
    Common.write_yaml(
        joinpath(directory, "rtc/mirror-controls.yaml"),
        Dict(
            "schema_version" => 1,
            "deformable_mirrors" => Dict(
                "primary" => Dict(
                    "limiter" =>
                        Dict("kind" => "amplitude", "lower" => -1, "upper" => 1),
                    "shape_control" => Dict("bases" => []),
                ),
            ),
        ),
    )
    for path in ("deployment.conf", "instrument.json", "rtc/parameters.conf")
        Common.write_json(joinpath(directory, path), Dict())
    end
    # A deliberately changed execution graph marks the boundary after all sensor
    # recipe validation, before optional graph preparation or optical loading.
    graph = Dict("filter.graph" => Dict("nodes" => []))
    Common.write_json(joinpath(directory, "graph-source.conf"), graph)
    Common.write_json(
        joinpath(directory, "graph.conf"), merge(graph, Dict("changed" => true))
    )
    recipe = Dict{String,Any}(
        "version" => 1,
        "simulation" => "simulation/definition.yaml",
        "rtc_configuration" => "rtc/configuration.yaml",
        "graph" => "graph.conf",
        "graph_source" => "graph-source.conf",
        "sensor" => "sensor",
        "poke_m" => 1e-8,
        "tsvd_rtol" => 1e-4,
    )
    if kind == "shack_hartmann"
        recipe["mirror"] = "primary"
        recipe["source_completion"] = Dict(
            "path" => "mirror.json",
            "sha256" => repeat("a", 64),
            "shape" => [2, 2],
            "axes" => [2, 1],
        )
        recipe["estimator"] = Dict(
            key => key for key in (
                "feedback_input",
                "detector_shape",
                "slopes_output",
                "validity_output",
                "measurement_count",
                "raw_input",
                "flux_output",
            )
        )
    else
        recipe["mirrors"] = [Dict("name" => "primary", "mode_count" => 2)]
        recipe["tiptilt"] = Dict(
            "command_input" => "requested",
            "mirror" => "primary",
            "command_limits_m" => [-1e-6, 1e-6],
        )
    end
    mkpath(joinpath(directory, "calibration"))
    return recipe
end

function read_recipe(directory, recipe)
    Common.write_json(joinpath(directory, "calibration/recipe.conf"), recipe)
    Common.write_yaml(joinpath(directory, "calibration/recipe.yaml"), recipe)
    return C.read_recipe(directory)
end

@testset "Supported sensor recipes preserve validation order" begin
    for kind in ("shack_hartmann", "pyramid")
        mktempdir() do directory
            recipe = recipe_application(directory, kind)
            @test_throws ArgumentError(
                "compiled calibration graph differs from its retained template; rebuild the application",
            ) read_recipe(directory, recipe)
            capture = Dict("channels" => ["raw", "slopes"], "maximum_bytes" => 65536)
            selected = merge(recipe, Dict("capture" => capture))
            @test_throws ArgumentError("unknown calibration recipe fields") read_recipe(
                directory, selected
            )
            unknown = merge(recipe, Dict("unknown" => true, "poke_m" => 0))
            @test_throws ArgumentError("unknown calibration recipe fields") read_recipe(
                directory, unknown
            )
            missing = deepcopy(recipe)
            delete!(missing, kind == "shack_hartmann" ? "mirror" : "mirrors")
            @test_throws ArgumentError("incomplete sensor calibration recipe") read_recipe(
                directory, missing
            )
            missing["poke_m"] = 0
            @test_throws ArgumentError(
                "calibration poke_m must be positive and finite in Float32"
            ) read_recipe(directory, missing)
            invalid_settings = merge(
                recipe, Dict("settings" => Dict("profile" => "missing"))
            )
            @test_throws ArgumentError("unsupported instrument profile missing") read_recipe(
                directory, invalid_settings
            )
        end
    end
    @test all(
        id ->
            id.name ∉ (
                "AdaptiveOpticsSim",
                "AdaptiveOpticsSimPipeWireHIL",
                "AdaptiveOpticsCalibration",
                "Proper",
                "CUDA",
                "AMDGPU",
            ),
        keys(Base.loaded_modules),
    )
end

@testset "Cold recipe rejects unsupported sensor procedures" begin
    for kind in ("scc", "llowfs")
        mktempdir() do directory
            recipe = recipe_application(directory, kind)
            error = ArgumentError("unsupported calibration sensor procedure: $kind")
            @test_throws error read_recipe(directory, recipe)
            @test !ispath(directory * "-calibration") && !ispath(directory * "-validation")
        end
    end
    @test all(
        id ->
            id.name ∉ (
                "AdaptiveOpticsSim",
                "AdaptiveOpticsSimPipeWireHIL",
                "AdaptiveOpticsCalibration",
                "Proper",
                "CUDA",
                "AMDGPU",
            ),
        keys(Base.loaded_modules),
    )
end
