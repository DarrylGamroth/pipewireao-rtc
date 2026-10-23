using Test, JSON, YAML, FITSIO, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

@testset "instrument declaration schema" begin

    function declaration_fixture(directory)
        write_json(path, value) = open(path, "w") do io
            JSON.print(io, value)
        end

        open(joinpath(directory, "production.yaml"), "w") do io
            YAML.write(io, Dict(
                "name" => "test-graph",
                "nodes" => [Dict("name" => "source"), Dict("name" => "mirror")],
                "inputs" => [Dict("name" => "command", "binding" => "commands")],
                "outputs" => [Dict("name" => "frame")],
            ))
        end
        open(joinpath(directory, "calibration.yaml"), "w") do io
            YAML.write(io, Dict(
                "name" => "test-graph",
                "nodes" => [Dict("name" => "source"), Dict("name" => "mirror")],
                "inputs" => [Dict("name" => "command", "binding" => "commands")],
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
                "shape_control" => Dict("bases" => [
                    Dict("id"=>"zernike","name"=>"Zernike","units"=>"m","coefficient_limit"=>1.0,
                        "normalization"=>"sampled_peak","provenance"=>"synthetic test declaration",
                        "definition"=>Dict("kind"=>"zernike","modes"=>[Dict("n"=>2,"m"=>0,"name"=>"defocus")])),
                    Dict("id"=>"fourier","name"=>"Fourier","units"=>"m","coefficient_limit"=>1.0,
                        "normalization"=>"sampled_rms","provenance"=>"synthetic test declaration",
                        "definition"=>Dict("kind"=>"fourier","max_frequency"=>2)),
                ]),
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
        declared = deepcopy(declaration)
        declared["dimensions"] = Dict("controller_command_count" => 5, "active_vdm_count" => 3)
        @test IC.validate_declaration(declared, directory) === nothing
        for dimensions in (Dict("controller_command_count" => 0),
                Dict("controller_command_count" => -1), Dict("controller_command_count" => true),
                Dict("controller_command_count" => 2.5), Dict("bad name" => 2),
                Dict("controller_command_count" => [2, 3]), [2, 3])
            invalid = deepcopy(declaration)
            invalid["dimensions"] = dimensions
            @test_throws ArgumentError IC.validate_declaration(invalid, directory)
        end

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

    @testset "sampled artifact publication preserves scientific values and identity" begin
        mktempdir() do directory
            declaration = declaration_fixture(directory)
            declaration["deformable_mirrors"]["primary"]["pupil_registration_setting"] = "pupil_registration"
            mirror = Dict("schema_version"=>1,"id"=>"test-mirror","manufacturer"=>"Example","model"=>"Three commands",
                "layout"=>Dict("schema_version"=>1,"name"=>"Test grid","grid_shape"=>[5,5],
                    "axis_labels"=>["source column","source row"],"command_positions"=>[[3,1],[1,3],[2,2]],
                    "command_order"=>"physical","provenance"=>"explicit physical order"))
            write(joinpath(directory,"mirror.json"),JSON.json(mirror))
            origins = declaration["wavefront_sensors"]["sensor"]["subaperture_origins"]
            origins["shape"] = [1,2]
            FITS(joinpath(directory,"artifact.fits"),"w") do fits
                write(fits,zeros(Float32,1,2))
            end
            samples = Float32[0.25 2.0; -0.5 0.0; 1.0 -1.0]
            write_samples(values) = FITS(joinpath(directory,"modes.fits"),"w") do fits
                # On-disk axes deliberately differ from logical command/mode axes.
                write(fits,permutedims(values))
            end
            write_samples(samples)
            basis = Dict{String,Any}("id"=>"custom","name"=>"Custom modes","units"=>"m","coefficient_limit"=>0.2,
                "normalization"=>"supplied","provenance"=>"test calibration",
                "definition"=>Dict("kind"=>"sampled","command_order"=>"mirror","names"=>["First","Second"],
                    "artifact"=>Dict("path"=>"modes.fits","hdu"=>1,"axes"=>[2,1],"type"=>"Float32","shape"=>[3,2])))
            push!(declaration["deformable_mirrors"]["primary"]["shape_control"]["bases"],basis)
            path = joinpath(directory,"instrument.conf")
            write_declaration() = write(path,JSON.json(declaration))
            write_declaration()
            @test IC.validate_declaration(declaration,directory) === nothing
            publication = IC.publication(path,NamedTuple();calibration_identity="sha256:"*repeat("a",64))
            @test publication.schema_version == 2
            definitions = publication.deformable_mirrors.primary.shape_control.bases
            @test map(b -> b.definition.kind,definitions) == ("zernike","fourier","sampled")
            @test definitions[1].normalization == "sampled_peak"
            @test definitions[2].normalization == "sampled_rms"
            @test definitions[3].definition.modes[1].values == Tuple(samples[:,1])
            @test definitions[3].definition.modes[2].values == Tuple(samples[:,2])
            @test definitions[3].definition.artifact_sha256 == PipeWireAORTC.Common.sha256_file(joinpath(directory,"modes.fits"))
            original_identity = IC.scientific_definition(path).prescription_identity
            changed = copy(samples); changed[1,1] = 0.75f0
            write_samples(changed)
            @test IC.scientific_definition(path).prescription_identity != original_identity
            write_samples(zeros(Float32,3,2))
            @test_throws ArgumentError IC.scientific_definition(path)
            changed[1,1] = Inf32; write_samples(changed)
            @test_throws ArgumentError IC.scientific_definition(path)
            write_samples(samples)
            for mutation in (
                    d -> (d["command_order"] = "source-grid"),
                    d -> (d["names"] = ["First","First"]),
                    d -> (d["names"] = ["First"]),
                    d -> (d["artifact"]["axes"] = [1,1]),
                    d -> (d["artifact"]["shape"] = [6]),
                )
                invalid = deepcopy(declaration)
                mutation(invalid["deformable_mirrors"]["primary"]["shape_control"]["bases"][3]["definition"])
                @test_throws ArgumentError IC.validate_declaration(invalid,directory)
            end
            basis["definition"]["artifact"]["shape"] = [2,2]
            write_declaration()
            @test_throws DimensionMismatch IC.scientific_definition(path)
            oversized = [deepcopy(declaration["deformable_mirrors"]["primary"]["shape_control"]["bases"][1]) for _ in 1:16]
            for (index,entry) in enumerate(oversized)
                entry["id"] = "basis-$index"
                entry["provenance"] = repeat("p",4096)
            end
            declaration["deformable_mirrors"]["primary"]["shape_control"]["bases"] = oversized
            original = declaration["deformable_mirrors"]["primary"]
            declaration["deformable_mirrors"] = Dict("mirror-$i"=>deepcopy(original) for i in 1:4)
            write_declaration()
            target = joinpath(directory,"publication.json")
            write(target,"existing sealed publication")
            write(joinpath(directory,"simulation.conf"),JSON.json(Dict(
                "version"=>3,"plant"=>Dict("definition"=>"instrument.conf","settings"=>Dict()),
                "instrument"=>"publication.json","calibration_identity"=>"sha256:"*repeat("a",64))))
            @test_throws r"256 KiB" IC.prepare_publication(directory)
            @test read(target,String) == "existing sealed publication"

        end
    end

    if haskey(ENV, "MONOREPO_CLASSIC")
        classic = ENV["MONOREPO_CLASSIC"]
        classic_path = joinpath(classic, "instrument.conf")
        document = JSON.parsefile(classic_path; dicttype=Dict{String,Any}, duplicate_keys=:error)
        @test IC.validate_declaration(document, classic) === nothing
    end
end
