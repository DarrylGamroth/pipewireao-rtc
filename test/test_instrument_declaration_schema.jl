using Test, JSON, YAML, FITSIO, PipeWireAORTC

const C = PipeWireAORTC.Common
const IC = PipeWireAORTC.InstrumentConfiguration

@testset "instrument declaration schema" begin

    function declaration_documents(directory)
        write_json(path, value) = open(path, "w") do io
            JSON.print(io, value)
        end

        open(joinpath(directory, "production.yaml"), "w") do io
            YAML.write(io, Dict(
                "schema_version" => 1,
                "name" => "test-graph",
                "nodes" => [Dict("name" => "source", "type" => "declared_source", "config" => Dict()),
                    Dict("name" => "mirror", "type" => "declared_mirror", "config" => Dict())],
                "inputs" => [Dict("name" => "command", "binding" => "commands", "destination" => "mirror.command")],
                "outputs" => [Dict("name" => "frame", "source" => "source.frame")],
            ))
        end
        open(joinpath(directory, "calibration.yaml"), "w") do io
            YAML.write(io, Dict(
                "schema_version" => 1,
                "name" => "test-graph",
                "nodes" => [Dict("name" => "source", "type" => "declared_source", "config" => Dict()),
                    Dict("name" => "mirror", "type" => "declared_mirror", "config" => Dict())],
                "inputs" => [Dict("name" => "command", "binding" => "commands", "destination" => "mirror.command")],
                "outputs" => [Dict("name" => "frame", "source" => "source.frame")],
            ))
        end
        write_json(joinpath(directory, "mirror.json"), Dict(
            "schema_version" => 1,
            "id" => "synthetic-mirror",
            "manufacturer" => "Example",
            "model" => "Synthetic",
            "layout" => Dict("schema_version" => 1, "name" => "Test grid",
                "grid_shape" => [5, 5], "command_positions" => [[3, 1], [1, 3]],
                "axis_labels" => ["source column", "source row"],
                "command_order" => "physical"),
        ))
        FITS(joinpath(directory, "artifact.fits"), "w") do fits
            write(fits, zeros(Float32, 1, 2))
        end

        simulation = Dict{String,Any}(
            "schema_version" => 1,
            "id" => "synthetic-simulation",
            "instrument" => "../instrument.yaml",
            "defaults" => Dict(
                "profile" => "basic",
                "atmosphere" => Dict("r0" => 0.2),
                "actuator_count" => 2,
            ),
            "settings_schema" => Dict("type" => "object", "properties" => Dict(
                "profile" => Dict("type" => "string"),
                "atmosphere" => Dict("type" => "object", "properties" => Dict(
                    "r0" => Dict("type" => "number"),
                )),
                "actuator_count" => Dict("type" => "integer"),
            )),
            "wire_contracts" => [Dict(
                "frame_encoding" => "float32",
                "frame_schema" => "example.frame/1",
                "command_schema" => "example.command/1",
                "command_scale" => 1.0,
            )],
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
        physical = Dict{String,Any}(
            "schema_version" => 1,
            "id" => "synthetic-instrument",
            "deformable_mirrors" => Dict("primary" => Dict(
                "description" => "mirror.json",
                "pupil_registration" => Dict("actuator_pitch_pupil_radius" => 0.2),
                "units" => "m",
                "command_scale_m" => 1e-6,
            )),
            "wavefront_sensors" => Dict("sensor" => Dict(
                "detector_shape" => [2, 2],
                "subaperture_shape" => [1, 1],
                "subaperture_origins" => Dict("path" => "artifact.fits", "hdu" => 1,
                    "axes" => [1, 2], "type" => "Float32", "shape" => [1, 2]),
                "expected_schema" => "test-v1",
            )),
        )
        controls = Dict{String,Any}("schema_version" => 1,
            "deformable_mirrors" => Dict("primary" => Dict(
                "limiter" => Dict("kind" => "amplitude", "lower" => -1.0, "upper" => 1.0),
                "shape_control" => Dict("bases" => [
                    Dict("id"=>"zernike","name"=>"Zernike","units"=>"m","coefficient_limit"=>1.0,
                        "normalization"=>"sampled_peak",
                        "definition"=>Dict("kind"=>"zernike","modes"=>[Dict("n"=>2,"m"=>0,"name"=>"defocus")])),
                    Dict("id"=>"fourier","name"=>"Fourier","units"=>"m","coefficient_limit"=>1.0,
                        "normalization"=>"sampled_rms",
                        "definition"=>Dict("kind"=>"fourier","max_frequency"=>2)),
                ]),
            )))
        rtc = Dict{String,Any}("schema_version" => 1,
            "instrument" => "../instrument.yaml", "dimensions" => Dict{String,Any}(),
            "mirror_controls" => "rtc/mirror-controls.yaml",
            "publication" => "publication.json", "calibration_identity" => "sha256:" * repeat("a", 64))
        mkpath(joinpath(directory, "simulation"))
        mkpath(joinpath(directory, "rtc"))
        paths = (;physical=joinpath(directory, "instrument.yaml"),
            simulation=joinpath(directory, "simulation", "definition.yaml"),
            rtc=joinpath(directory, "rtc", "configuration.yaml"),
            controls=joinpath(directory, "rtc", "mirror-controls.yaml"))
        documents = (;physical, simulation, rtc, controls, paths)
        write_documents(documents)
        return documents
    end

    function write_documents(documents)
        C.write_yaml(documents.paths.physical, documents.physical)
        C.write_yaml(documents.paths.rtc, documents.rtc)
        for name in (:simulation, :controls)
            open(getproperty(documents.paths, name), "w") do io
                YAML.write(io, getproperty(documents, name))
            end
        end
    end

    function write_simulator(directory)
        write(joinpath(directory, "simulation.conf"), JSON.json(Dict(
            "version" => 3, "rtc_configuration" => "rtc/configuration.yaml",
            "plant" => Dict("definition" => "simulation/definition.yaml", "settings" => Dict()),
            "instrument" => Dict("\$ref" => "/rtc/publication"),
            "calibration_identity" => Dict("\$ref" => "/rtc/calibration_identity"))))
    end

    mktempdir() do directory
        documents = declaration_documents(directory)
        physical, declaration = documents.physical, documents.simulation
        graphs = Dict(mode => C.read_yaml(joinpath(directory, declaration["graphs"][mode])) for mode in ("production", "calibration"))
        @test IC.validate_declaration(physical, directory) === nothing
        @test IC.validate_simulation(declaration, physical, directory, graphs) === nothing
        signed_source = deepcopy(declaration)
        signed_source["sources"] = Dict("guide" => Dict("source_band" => "R", "source_magnitude" => 2,
            "source_wavelength_m" => 0.8e-6, "source_separation_arcsec" => -2.0, "source_position_angle_deg" => 30.0))
        @test IC.validate_simulation(signed_source, physical, directory, graphs) === nothing
        for field in ("height", "source_height_m")
            finite_source = deepcopy(signed_source)
            finite_source["sources"]["guide"][field] = 90000
            @test_throws ArgumentError IC.validate_simulation(finite_source, physical, directory, graphs)
        end
        @test IC.load(documents.paths.physical).document == physical
        @test IC.load_simulation(documents.paths.simulation).document == declaration
        loaded = IC.load_simulation(documents.paths.simulation)
        context = IC.configuration_context(loaded, IC.settings(loaded))
        @test context["simulation"]["frame_period_ns"] == UInt64(10_000_000)
        @test context["simulation"]["rate"] == 100
        with_response = deepcopy(declaration)
        with_response["responses"] = Dict("command"=>Dict("kind"=>"second_order",
            "natural_frequency_hz"=>20, "damping_ratio"=>0.7,
            "schema"=>Dict("\$ref"=>"/schemas/tip_tilt_opd_coefficients_m/id")))
        C.write_yaml(documents.paths.simulation, with_response)
        loaded_response = IC.load_simulation(documents.paths.simulation)
        @test loaded_response.document["responses"]["command"]["schema"] ==
            PipeWireAORTC.Schemas.CATALOG["tip_tilt_opd_coefficients_m"]["id"]
        resolved_response = IC.graph_document(loaded_response,IC.settings(loaded_response))
        @test only(n for n in resolved_response["nodes"] if n["name"]=="command_response")["config"]["schema"] ==
            PipeWireAORTC.Schemas.CATALOG["tip_tilt_opd_coefficients_m"]["id"]
        C.write_yaml(documents.paths.simulation, declaration)
        documents.rtc["dimensions"] = Dict("controller_command_count" => 5, "active_vdm_count" => 3)
        write_documents(documents)
        @test IC.load_rtc(documents.paths.rtc).document["dimensions"] == documents.rtc["dimensions"]
        for dimensions in (Dict("controller_command_count" => 0),
                Dict("controller_command_count" => -1), Dict("controller_command_count" => true),
                Dict("controller_command_count" => 2.5), Dict("bad name" => 2),
                Dict("controller_command_count" => [2, 3]), [2, 3])
            invalid = deepcopy(documents.rtc)
            invalid["dimensions"] = dimensions
            C.write_yaml(documents.paths.rtc, invalid)
            @test_throws ArgumentError IC.load_rtc(documents.paths.rtc)
        end
        write_documents(documents)

        invalid_wire_contract = deepcopy(declaration)
        invalid_wire_contract["wire_contracts"][1]["command_scale"] = true
        @test_throws ArgumentError IC.validate_simulation(invalid_wire_contract, physical, directory, graphs)

        unknown_parameter = deepcopy(declaration)
        unknown_parameter["profiles"]["basic"]["parameters"][1]["paramaters"] =
            unknown_parameter["profiles"]["basic"]["parameters"][1]["destination"]
        @test_throws ArgumentError IC.validate_simulation(unknown_parameter, physical, directory, graphs)

        unknown_binding = deepcopy(declaration)
        unknown_binding["bindings"]["commands"]["shpae"] =
            unknown_binding["bindings"]["commands"]["shape"]
        @test_throws ArgumentError IC.validate_simulation(unknown_binding, physical, directory, graphs)

        inactive_profile_typo = deepcopy(declaration)
        inactive_profile_typo["settings_bindings"] = [Dict(
            "setting" => "atmosphere.r0",
            "nodes" => ["mirror"],
            "profiles" => ["grid_gaussain"],
        )]
        @test_throws ArgumentError IC.validate_simulation(inactive_profile_typo, physical, directory, graphs)

        unknown_transform = deepcopy(declaration)
        unknown_transform["settings_bindings"] = [Dict(
            "setting" => "atmosphere.r0",
            "nodes" => ["mirror"],
            "transform" => "gaussian_wdith",
        )]
        @test_throws ArgumentError IC.validate_simulation(unknown_transform, physical, directory, graphs)

        misplaced_coupling = deepcopy(declaration)
        misplaced_coupling["settings_bindings"] = [Dict(
            "setting" => "atmosphere.r0",
            "nodes" => ["mirror"],
            "transform" => "identity",
            "coupling" => 0.35,
        )]
        @test_throws ArgumentError IC.validate_simulation(misplaced_coupling, physical, directory, graphs)

        absent_mirror = deepcopy(declaration)
        absent_mirror["bindings"]["coordinates"] = Dict("kind" => "mirror_coordinates", "mirror" => "missing")
        @test_throws ArgumentError IC.validate_simulation(absent_mirror, physical, directory, graphs)

        for setting in ("missing", "atmosphere.missing")
            invalid = deepcopy(declaration)
            invalid["settings_bindings"] = [Dict("setting" => setting, "nodes" => ["mirror"])]
            @test_throws ArgumentError IC.validate_simulation(invalid, physical, directory, graphs)
        end

        for (key, value) in (("defaults", declaration["defaults"]), ("dimensions", documents.rtc["dimensions"]))
            invalid = deepcopy(physical)
            invalid[key] = value
            @test_throws ArgumentError IC.validate_declaration(invalid, directory)
        end
        for key in ("limiter", "shape_control")
            invalid = deepcopy(physical)
            invalid["deformable_mirrors"]["primary"][key] = documents.controls["deformable_mirrors"]["primary"][key]
            @test_throws ArgumentError IC.validate_declaration(invalid, directory)
        end
        invalid = deepcopy(physical)
        invalid["wavefront_sensors"]["sensor"]["post_readout_gain"] = 1.0
        @test_throws ArgumentError IC.validate_declaration(invalid, directory)
        for key in ("dimensions", "mirror_controls", "deformable_mirrors")
            invalid = deepcopy(declaration)
            invalid[key] = Dict()
            open(documents.paths.simulation, "w") do io
                YAML.write(io, invalid)
            end
            @test_throws ArgumentError IC.load_simulation(documents.paths.simulation)
        end
        invalid = deepcopy(documents.rtc)
        invalid["defaults"] = declaration["defaults"]
        C.write_yaml(documents.paths.rtc, invalid)
        @test_throws ArgumentError IC.load_rtc(documents.paths.rtc)
    end

    @testset "physical loading and RTC publication are independent of simulation" begin
        mktempdir() do directory
            documents = declaration_documents(directory)
            rm(dirname(documents.paths.simulation); recursive=true)
            rm(joinpath(directory, "production.yaml"))
            rm(joinpath(directory, "calibration.yaml"))
            @test IC.load(documents.paths.physical).document == documents.physical
            @test !isfile(joinpath(directory, "simulation.conf"))
            publication = IC.publication(documents.paths.rtc)
            @test publication.id == "synthetic-instrument"
            @test length(publication.deformable_mirrors.primary.layout.command_positions) == 2
            target = IC.prepare_publication(directory)
            @test JSON.parsefile(target)["scientific_identity"] == publication.scientific_identity
            @test !isfile(joinpath(directory, "simulation.conf"))
        end
    end

    @testset "pyramid publication and bounded calibration context export without simulation" begin
        mktempdir() do directory
            documents = declaration_documents(directory)
            documents.physical["wavefront_sensors"]["sensor"] = Dict(
                "kind" => "pyramid", "detector_shape" => [8, 12],
                "pupil_shape" => [2, 3], "pupil_separation_pixels" => [2, 4],
                "pupil_edge_pixels" => [1, 1], "expected_schema" => "test.pyramid/1")
            documents.rtc["calibration"] = "rtc/calibration.yaml"
            calibration_path = joinpath(directory, "rtc", "calibration.yaml")
            C.write_yaml(calibration_path, Dict("pupil" => Dict("selected_pixel_count" => 5)))
            write_documents(documents)
            rm(dirname(documents.paths.simulation); recursive=true)
            @test IC.load_rtc(documents.paths.rtc).calibration ==
                Dict("pupil" => Dict("selected_pixel_count" => 5))
            target = IC.prepare_publication(directory)
            sensor = JSON.parsefile(target)["wavefront_sensors"]["sensor"]["layout"]
            @test sensor == Dict("kind" => "pyramid", "detector_shape" => [8, 12],
                "pupil_shape" => [2, 3], "pupil_origins" => [[1, 1], [5, 1], [1, 8], [5, 8]],
                "expected_schema" => "test.pyramid/1")
            @test !haskey(sensor, "subaperture_origins")
            for value in ([], 1, "invalid")
                write(calibration_path, JSON.json(value))
                @test_throws ArgumentError IC.load_rtc(documents.paths.rtc)
            end
            C.write_yaml(calibration_path, Dict())
            mktemp() do outside, _
                documents.rtc["calibration"] = relpath(outside, directory)
                C.write_yaml(documents.paths.rtc, documents.rtc)
                @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError IC.load_rtc(documents.paths.rtc)
            end
        end
    end

    @testset "explicit optical pupil follows physical and published identity" begin
        mktempdir() do directory
            documents = declaration_documents(directory)
            physical = IC.physical_definition(IC.load(documents.paths.physical))
            publication = IC.publication(documents.paths.rtc)
            scientific = IC.scientific_definition(documents.paths.simulation)
            @test !hasproperty(physical.deformable_mirrors.primary,:pupil)
            @test !hasproperty(publication.deformable_mirrors.primary,:pupil)
            original_coordinates = publication.deformable_mirrors.primary.pupil_coordinates
            original_layout = publication.deformable_mirrors.primary.layout
            mirror = documents.physical["deformable_mirrors"]["primary"]
            pupil = Dict("outer_radius"=>1.125,"inner_radius"=>0.3)
            mirror["pupil"] = pupil
            write_documents(documents)
            declared = IC.load(documents.paths.physical)
            with_pupil = IC.publication(documents.paths.rtc)
            scientific_pupil = IC.scientific_definition(documents.paths.simulation)
            @test IC.physical_definition(declared).deformable_mirrors.primary.pupil ==
                scientific_pupil.deformable_mirrors.primary.pupil ==
                with_pupil.deformable_mirrors.primary.pupil == (;outer_radius=1.125,inner_radius=0.3)
            @test with_pupil.deformable_mirrors.primary.pupil_coordinates == original_coordinates
            @test with_pupil.deformable_mirrors.primary.layout == original_layout
            @test with_pupil.scientific_identity != publication.scientific_identity
            @test scientific_pupil.prescription_identity != scientific.prescription_identity
            target = IC.prepare_publication(directory)
            @test JSON.parsefile(target)["deformable_mirrors"]["primary"]["pupil"] == pupil
            documents.physical["telescope"] = Dict("telescope_diameter_m"=>8.0,
                "central_obstruction_ratio"=>0.2,"pupil_reflectivity"=>0.9,"aperture_revision"=>1)
            write_documents(documents)
            # An explicit per-mirror pupil takes precedence over the telescope fallback.
            @test IC.publication(documents.paths.rtc).deformable_mirrors.primary.pupil ==
                with_pupil.deformable_mirrors.primary.pupil
            delete!(mirror,"pupil")
            write_documents(documents)
            @test IC.publication(documents.paths.rtc).deformable_mirrors.primary.pupil ==
                (;outer_radius=1.0,inner_radius=0.2)
            delete!(documents.physical,"telescope")
            write_documents(documents)
            @test !hasproperty(IC.publication(documents.paths.rtc).deformable_mirrors.primary,:pupil)
            for invalid in (Dict("outer_radius"=>1.0), Dict("outer_radius"=>true,"inner_radius"=>0.0),
                    Dict("outer_radius"=>1.0,"inner_radius"=>1e-100),
                    Dict("outer_radius"=>1e100,"inner_radius"=>0.0),
                    Dict("outer_radius"=>nextfloat(1.0),"inner_radius"=>1.0))
                mirror["pupil"] = invalid
                @test_throws ArgumentError IC.validate_declaration(documents.physical,directory)
            end
            delete!(mirror,"pupil")
            # The existing required mirror declaration fields remain required.
            for field in ("description","pupil_registration","units","command_scale_m")
                invalid = deepcopy(documents.physical)
                delete!(invalid["deformable_mirrors"]["primary"],field)
                @test_throws ArgumentError IC.validate_declaration(invalid,directory)
            end
        end
    end

    @testset "mirror clear aperture follows physical and published identity" begin
        mktempdir() do directory
            documents = declaration_documents(directory)
            original = IC.publication(documents.paths.rtc)
            original_scientific = IC.scientific_definition(documents.paths.simulation)
            @test !hasproperty(original.deformable_mirrors.primary,:clear_aperture)
            mirror_path = joinpath(directory,"mirror.json")
            description = JSON.parsefile(mirror_path)
            description["actuator_pitch_m"] = 0.0015
            description["clear_aperture_diameter_m"] = 0.0245
            write(mirror_path,JSON.json(description))
            physical = IC.physical_definition(IC.load(documents.paths.physical))
            scientific = IC.scientific_definition(documents.paths.simulation)
            publication = IC.publication(documents.paths.rtc)
            @test physical.deformable_mirrors.primary.clear_aperture ==
                scientific.deformable_mirrors.primary.clear_aperture ==
                publication.deformable_mirrors.primary.clear_aperture
            @test publication.deformable_mirrors.primary.clear_aperture.radius ≈ 0.0245 / 0.0015 / 2 * 0.2
            @test !hasproperty(publication.deformable_mirrors.primary,:pupil)
            @test publication.deformable_mirrors.primary.pupil_coordinates == original.deformable_mirrors.primary.pupil_coordinates
            @test publication.deformable_mirrors.primary.layout == original.deformable_mirrors.primary.layout
            @test publication.deformable_mirrors.primary.shape_control == original.deformable_mirrors.primary.shape_control
            @test publication.scientific_identity != original.scientific_identity
            @test scientific.prescription_identity != original_scientific.prescription_identity
            target = IC.prepare_publication(directory)
            @test JSON.parsefile(target)["deformable_mirrors"]["primary"]["clear_aperture"]["radius"] ==
                publication.deformable_mirrors.primary.clear_aperture.radius
            for diameter in (1e100,1e-100)
                description["clear_aperture_diameter_m"] = diameter
                write(mirror_path,JSON.json(description))
                @test_throws ArgumentError IC.publication(documents.paths.rtc)
            end
        end
    end

    @testset "sampled artifact publication preserves scientific values and identity" begin
        mktempdir() do directory
            documents = declaration_documents(directory)
            declaration, controls = documents.physical, documents.controls
            mirror = Dict("schema_version"=>1,"id"=>"test-mirror","manufacturer"=>"Example","model"=>"Three commands",
                "layout"=>Dict("schema_version"=>1,"name"=>"Test grid","grid_shape"=>[5,5],
                    "axis_labels"=>["source column","source row"],"command_positions"=>[[3,1],[1,3],[2,2]],
                    "command_order"=>"physical"))
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
                "normalization"=>"supplied",
                "definition"=>Dict("kind"=>"sampled","command_order"=>"mirror","names"=>["First","Second"],
                    "artifact"=>Dict("path"=>"modes.fits","hdu"=>1,"axes"=>[2,1],"type"=>"Float32","shape"=>[3,2])))
            push!(controls["deformable_mirrors"]["primary"]["shape_control"]["bases"],basis)
            path = documents.paths.rtc
            write_declaration() = write_documents(documents)
            write_declaration()
            @test IC.validate_declaration(declaration,directory) === nothing
            publication = IC.publication(path)
            @test publication.schema_version == 2
            @test publication.deformable_mirrors.primary.shape_control.controlled_actuators === (true,true,true)
            for selector in ([],Dict("graph"=>"production.yaml"),
                    Dict("graph"=>"production.yaml","bindings"=>"production.yaml",
                        "active_to_full"=>"missing","pdm_to_vdm"=>"inverse","extra"=>true))
                invalid_controls=IC.json_value(controls)
                invalid_controls["deformable_mirrors"]["primary"]["shape_control"]["controlled_actuators"]=selector
                C.write_yaml(documents.paths.controls,invalid_controls)
                @test_throws ArgumentError IC.load_rtc(path)
            end
            write_declaration()
            definitions = publication.deformable_mirrors.primary.shape_control.bases
            @test map(b -> b.definition.kind,definitions) == ("zernike","fourier","sampled")
            @test definitions[1].normalization == "sampled_peak"
            @test definitions[2].normalization == "sampled_rms"
            @test definitions[3].definition.modes[1].values == Tuple(samples[:,1])
            @test definitions[3].definition.modes[2].values == Tuple(samples[:,2])
            @test definitions[3].definition.artifact_sha256 == PipeWireAORTC.Common.sha256_file(joinpath(directory,"modes.fits"))
            original_identity = publication.scientific_identity
            simulation_identity = IC.scientific_definition(documents.paths.simulation).prescription_identity
            @test !hasproperty(IC.scientific_definition(documents.paths.simulation).deformable_mirrors.primary, :shape_control)
            controls_text = read(documents.paths.controls, String)
            rm(documents.paths.controls)
            @test IC.scientific_definition(documents.paths.simulation).prescription_identity == simulation_identity
            write(documents.paths.controls, controls_text)
            changed = copy(samples); changed[1,1] = 0.75f0
            write_samples(changed)
            @test IC.publication(path).scientific_identity != original_identity
            @test IC.scientific_definition(documents.paths.simulation).prescription_identity == simulation_identity
            write_samples(zeros(Float32,3,2))
            @test_throws ArgumentError IC.publication(path)
            changed[1,1] = Inf32; write_samples(changed)
            @test_throws ArgumentError IC.publication(path)
            write_samples(samples)
            for mutation in (
                    d -> (d["command_order"] = "source-grid"),
                    d -> (d["names"] = ["First","First"]),
                    d -> (d["names"] = ["First"]),
                    d -> (d["artifact"]["axes"] = [1,1]),
                    d -> (d["artifact"]["shape"] = [6]),
                )
                invalid = deepcopy(controls)
                mutation(invalid["deformable_mirrors"]["primary"]["shape_control"]["bases"][3]["definition"])
                open(documents.paths.controls, "w") do io
                    YAML.write(io, invalid)
                end
                @test_throws ArgumentError IC.load_rtc(path)
            end
            basis["definition"]["artifact"]["shape"] = [2,2]
            write_declaration()
            @test_throws DimensionMismatch IC.publication(path)
            basis["definition"]["artifact"]["shape"] = [3,2]
            write_declaration()
            write_simulator(directory)
            simulation_text = read(joinpath(directory, "simulation.conf"), String)
            target = IC.prepare_publication(directory)
            @test read(joinpath(directory, "simulation.conf"), String) == simulation_text
            IC.prepare_simulation_configuration!(directory)
            generated = PipeWireAORTC.DeploymentConfiguration.decode(joinpath(directory, "simulation.conf"), get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
            @test generated["prescription_identity"] == simulation_identity
            @test JSON.parsefile(target)["scientific_identity"] == original_identity
            @test IC.prepare_publication(directory) == target
            # Bound publication using actual FITS-backed sampled modes, not padding text.
            write_samples(repeat(reshape(Float32[1.234567f-20,-2.345678f-20,3.456789f-20],3,1),1,64))
            basis["definition"]["names"] = ["Calibrated interaction-matrix reconstruction singular vector $i" for i in 1:64]
            basis["definition"]["artifact"]["shape"] = [3,64]
            oversized = [deepcopy(basis) for _ in 1:16]
            for (index,entry) in enumerate(oversized)
                entry["id"] = "basis-$index"
            end
            controls["deformable_mirrors"]["primary"]["shape_control"]["bases"] = oversized
            original_control = controls["deformable_mirrors"]["primary"]
            controls["deformable_mirrors"] = Dict("mirror-$i"=>deepcopy(original_control) for i in 1:8)
            original = declaration["deformable_mirrors"]["primary"]
            declaration["deformable_mirrors"] = Dict("mirror-$i"=>deepcopy(original) for i in 1:8)
            write_declaration()
            target = joinpath(directory,"publication.json")
            write(target,"existing sealed publication")
            write_simulator(directory)
            @test_throws r"1 MiB" IC.prepare_publication(directory)
            @test read(target,String) == "existing sealed publication"

        end
    end

    if haskey(ENV, "MONOREPO_CLASSIC")
        classic = ENV["MONOREPO_CLASSIC"]
        classic_path = joinpath(classic, "instrument.yaml")
        document = C.read_yaml(classic_path)
        @test IC.validate_declaration(document, classic) === nothing
    end
end
