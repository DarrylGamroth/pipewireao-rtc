using Test, JSON, YAML, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

@testset "instrument declaration schema" begin

    function declaration_fixture(directory)
        write_json(path, value) = open(path, "w") do io
            JSON.print(io, value)
        end

        open(joinpath(directory, "production.yaml"), "w") do io
            YAML.write(io, Dict(
                "nodes" => [Dict("name" => "source"), Dict("name" => "mirror")],
                "inputs" => [Dict("name" => "command")],
                "outputs" => [Dict("name" => "frame")],
            ))
        end
        open(joinpath(directory, "calibration.yaml"), "w") do io
            YAML.write(io, Dict(
                "nodes" => [Dict("name" => "source"), Dict("name" => "mirror")],
                "inputs" => [Dict("name" => "command")],
                "outputs" => [Dict("name" => "frame")],
            ))
        end
        write_json(joinpath(directory, "mirror.json"), Dict(
            "schema_version" => 1,
            "id" => "synthetic-mirror",
            "manufacturer" => "Example",
            "model" => "Synthetic",
            "layout" => Dict("grid_shape" => [2, 2], "command_positions" => [[1, 1], [2, 2]]),
        ))
        write(joinpath(directory, "artifact.fits"), "fixture")

        return Dict{String,Any}(
            "schema_version" => 1,
            "id" => "synthetic-instrument",
            "defaults" => Dict(
                "profile" => "basic",
                "pupil_registration" => Dict("actuator_pitch" => 0.2),
                "actuator_count" => 2,
            ),
            "settings_schema" => Dict("type" => "object", "properties" => Dict(
                "profile" => Dict("type" => "string"),
                "pupil_registration" => Dict("type" => "object", "properties" => Dict(
                    "actuator_pitch" => Dict("type" => "number"),
                )),
                "actuator_count" => Dict("type" => "integer"),
            )),
            "wire_contracts" => [Dict(
                "frame_encoding" => "float32",
                "frame_schema" => "example.frame/1",
                "command_schema" => "example.command/1",
                "command_scale" => 1.0,
            )],
            "deformable_mirrors" => Dict("primary" => Dict(
                "description" => "mirror.json",
                "pupil_registration_setting" => "pupil_registration.actuator_pitch",
                "units" => "m",
                "command_scale_m" => 1e-6,
                "limiter" => Dict("kind" => "amplitude", "lower" => -1.0, "upper" => 1.0),
                "shape_control" => Dict(
                    "coefficient_limit" => 1.0,
                    "zernike" => Dict("modes" => [Dict("n" => 2, "m" => 0, "name" => "defocus")]),
                    "fourier" => Dict("max_frequency" => 2),
                    "provenance" => "synthetic test fixture",
                ),
            )),
            "wavefront_sensors" => Dict("sensor" => Dict(
                "detector_shape" => [2, 2],
                "subaperture_shape" => [1, 1],
                "subaperture_origins" => Dict("path" => "artifact.fits", "hdu" => 1,
                    "axes" => [1, 2], "type" => "Float32", "shape" => [2, 2]),
                "expected_schema" => "test-v1",
                "provenance" => "synthetic test fixture",
            )),
            "graphs" => Dict("production" => "production.yaml", "calibration" => "calibration.yaml"),
            "profiles" => Dict("basic" => Dict(
                "nodes" => [Dict("name" => "mirror", "type" => "Mirror", "config" => Dict())],
                "parameters" => [Dict("destination" => "mirror.command", "binding" => "commands")],
            )),
            "bindings" => Dict("commands" => Dict("kind" => "zeros", "shape" => ["actuator_count"], "type" => "Float32")),
            "settings_bindings" => Any[],
            "frame_period_s" => 0.01,
            "hil" => Dict("command_input" => "command", "frame_output" => "frame"),
        )
    end

    mktempdir() do directory
        declaration = declaration_fixture(directory)
        @test IC.validate_declaration(declaration, directory) === nothing

        invalid_wire_contract = deepcopy(declaration)
        invalid_wire_contract["wire_contracts"][1]["command_scale"] = true
        @test_throws ArgumentError IC.validate_declaration(invalid_wire_contract, directory)

        unknown_parameter = deepcopy(declaration)
        unknown_parameter["profiles"]["basic"]["parameters"][1]["paramaters"] =
            unknown_parameter["profiles"]["basic"]["parameters"][1]["destination"]
        @test_throws ArgumentError IC.validate_declaration(unknown_parameter, directory)

        unknown_binding = deepcopy(declaration)
        unknown_binding["bindings"]["commands"]["shpae"] =
            unknown_binding["bindings"]["commands"]["shape"]
        @test_throws ArgumentError IC.validate_declaration(unknown_binding, directory)

        inactive_profile_typo = deepcopy(declaration)
        inactive_profile_typo["settings_bindings"] = [Dict(
            "setting" => "pupil_registration.actuator_pitch",
            "nodes" => ["mirror"],
            "profiles" => ["grid_gaussain"],
        )]
        @test_throws ArgumentError IC.validate_declaration(inactive_profile_typo, directory)

        unknown_transform = deepcopy(declaration)
        unknown_transform["settings_bindings"] = [Dict(
            "setting" => "pupil_registration.actuator_pitch",
            "nodes" => ["mirror"],
            "transform" => "gaussian_wdith",
        )]
        @test_throws ArgumentError IC.validate_declaration(unknown_transform, directory)

        misplaced_coupling = deepcopy(declaration)
        misplaced_coupling["settings_bindings"] = [Dict(
            "setting" => "pupil_registration.actuator_pitch",
            "nodes" => ["mirror"],
            "transform" => "identity",
            "coupling" => 0.35,
        )]
        @test_throws ArgumentError IC.validate_declaration(misplaced_coupling, directory)

        absent_mirror = deepcopy(declaration)
        absent_mirror["bindings"]["coordinates"] = Dict("kind" => "mirror_coordinates", "mirror" => "missing")
        @test_throws ArgumentError IC.validate_declaration(absent_mirror, directory)
    end

    if haskey(ENV, "MONOREPO_CLASSIC")
        classic = ENV["MONOREPO_CLASSIC"]
        classic_path = joinpath(classic, "instrument.conf")
        document = JSON.parsefile(classic_path; dicttype=Dict{String,Any}, duplicate_keys=:error)
        @test IC.validate_declaration(document, classic) === nothing
    end
end
