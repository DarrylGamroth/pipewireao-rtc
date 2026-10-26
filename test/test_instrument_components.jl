using Test, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

function optical_components_document()
    schemas = Dict{String,Any}("pdm_command_schema" => "example.command-metres/1",
        "surface_opd_schema" => "example.surface-opd-metres/1",
        "actuator_coordinates_schema" => "example.coordinates/1",
        "actuator_grid_indices_schema" => "example.indices/1",
        "influence_functions_schema" => "example.influences/1")
    mirror = Dict{String,Any}("template" => "deformable_mirror", "mirror" => "woofer",
        "coupling" => 0.35, "config" => schemas, "influence_functions" => "influences.woofer")
    second = deepcopy(mirror)
    second["mirror"], second["influence_functions"] = "tweeter", "influences.tweeter"
    graph = Dict{String,Any}("schema_version" => 1, "name" => "two-mirror-optics",
        "nodes" => Any[Dict{String,Any}("name" => "woofer"), Dict{String,Any}("name" => "tweeter"),
            Dict("name" => "custom", "type" => "caller_supplied_type", "config" => Dict("scientific_value" => 3.0))],
        "inputs" => [Dict("name" => name * "_command", "binding" => name * "_command",
            "destination" => name * ".pdm_command") for name in ("woofer", "tweeter")],
        "outputs" => [Dict("name" => "frame", "source" => "custom.frame")], "links" => Any[])
    frames = [Dict("frame_encoding" => "float32", "frame_schema" => "example.frame/1"),
        Dict("frame_encoding" => "uint16", "frame_schema" => "example.pixels/1")]
    commands = [Dict("command_schema" => "example.command-metres/1", "command_scale" => 1),
        Dict("command_schema" => "example.command-micrometres/1", "command_scale" => 1e-6)]
    document = Dict{String,Any}("defaults" => Dict("profile" => "grid_gaussian"),
        "components" => Dict("woofer" => mirror, "tweeter" => second),
        "profiles" => Dict(name => Dict{String,Any}("template" => name) for name in IC.MIRROR_PROFILES),
        "graphs" => Dict("production" => graph, "calibration" => deepcopy(graph)),
        "wire_contracts" => Dict("frames" => frames, "commands" => commands,
            "additional" => [Dict("frame_encoding" => "uint16", "frame_schema" => "example.external-frame/1",
                "command_schema" => "example.external-command/1", "command_scale" => 1)]),
        "hil" => Dict("command" => "woofer.pdm_command", "frame" => "custom.frame"))
    instrument = Dict("deformable_mirrors" => Dict("woofer" => Dict(), "tweeter" => Dict()),
        "wavefront_sensors" => Dict("science_sensor" => Dict(), "guide_sensor" => Dict()))
    return document, instrument
end

@testset "reusable AOS components preserve explicit physical references" begin
    document, instrument = optical_components_document()
    original = deepcopy(document)
    expanded = IC.expand_simulation_components!(document, instrument, ".")
    graph = expanded.graphs["production"]
    @test [node["name"] for node in graph["nodes"]] == ["woofer", "tweeter", "custom"]
    @test graph["nodes"][3] == original["graphs"]["production"]["nodes"][3]
    @test graph["links"] == original["graphs"]["production"]["links"]
    @test document["hil"] == Dict("command_input" => "woofer_command", "frame_output" => "frame")
    for name in ("woofer", "tweeter")
        config = only(node for node in graph["nodes"] if node["name"] == name)["config"]
        @test config["actuator_count"] == Dict("\$ref" => "/instrument/deformable_mirrors/$name/actuator_count")
        @test config["actuator_pitch"] == Dict("\$ref" => "/instrument/deformable_mirrors/$name/pupil_registration/actuator_pitch_pupil_radius")
        @test config["pdm_command_schema"] == "example.command-metres/1"
        @test !haskey(config, "influence_functions_schema")
        @test document["bindings"][name * "_command"]["shape"] == [Dict("\$ref" => "/instrument/deformable_mirrors/$name/actuator_count")]
        @test document["bindings"][name * "_influence_functions"]["setting"] == "influences.$name"
        @test document["profiles"]["measured"]["settings_schema"]["influences"]["properties"][name]["readOnly"]
        grid = only(parameter for parameter in document["profiles"]["grid_gaussian"]["parameters"]
            if parameter["destination"] == name * ".actuator_grid_indices")
        @test grid["binding"] == name * "_actuator_grid_indices"
    end
    @test length(document["wire_contracts"]) == 5
    @test [(wire["frame_encoding"], wire["command_scale"]) for wire in document["wire_contracts"]] ==
        [("float32", 1), ("float32", 1e-6), ("uint16", 1), ("uint16", 1e-6), ("uint16", 1)]
    @test last(document["wire_contracts"])["command_schema"] == "example.external-command/1"
    @test IC.transform(0.2, Dict("transform" => "gaussian_width", "coupling" => 0.35)) == 0.2 / sqrt(-2log(0.35))
    @test Set(expanded.templates) == Set(IC.MIRROR_PROFILES)
    @test original["graphs"]["production"]["nodes"][1] == Dict("name" => "woofer")

    document, instrument = optical_components_document()
    document["components"]["woofer"]["bindings"] = Dict("actuator_grid_indices" => "physical_command_order")
    IC.expand_simulation_components!(document, instrument, ".")
    @test document["bindings"]["physical_command_order"] == Dict("kind" => "mirror_grid_indices", "mirror" => "woofer")
end

@testset "component sensor and source choices remain explicit" begin
    selection = Dict{String,Any}("template" => "shack_hartmann_rate_f32", "sensor" => "science_sensor",
        "source" => "off_axis", "config" => Dict("opd_schema" => "example.opd/1", "photon_rate_schema" => "example.rate/1"))
    node = IC.component_node("science", selection, selection["template"], Set{String}())
    @test node["config"]["n_lenslets"] == Dict("\$ref" => "/instrument/wavefront_sensors/science_sensor/optical_prescription/n_lenslets")
    @test node["config"]["source_separation_arcsec"] == Dict("\$ref" => "/simulation/sources/off_axis/source_separation_arcsec")
    selection["sensor"], selection["source"] = "guide_sensor", "on_axis"
    other = IC.component_node("guide", selection, selection["template"], Set{String}())
    @test other["config"]["n_lenslets"] != node["config"]["n_lenslets"]
    @test other["config"]["source_wavelength_m"] != node["config"]["source_wavelength_m"]
    @test !haskey(node["config"], "photon_noise")
end

@testset "bounded component preparation rejects ambiguity and unsupported data" begin
    for mutate! in (
            document -> (document["components"]["woofer"]["template"] = "../../outside"),
            document -> (document["components"]["woofer"]["mirror"] = "absent"),
            document -> (document["components"]["woofer"]["coupling"] = 1.0),
            document -> delete!(document["components"]["woofer"], "coupling"),
            document -> (document["components"]["woofer"]["arbitrary"] = true),
            document -> (document["components"]["woofer"]["config"]["arbitrary"] = true),
            document -> (document["components"]["woofer"]["config"]["actuator_count"] = 17),
            document -> (document["components"]["woofer"]["config"]["actuator_pitch"] = 0.1),
            document -> (document["graphs"]["production"]["nodes"][1]["config"] = Dict("actuator_count" => 17)),
            document -> (document["graphs"]["production"]["nodes"][1]["config"] = Dict("actuator_pitch" => 0.1)),
            document -> (document["graphs"]["production"]["nodes"][1]["config"] = Dict("pdm_command_schema" => "example.other/1")),
            document -> (document["graphs"]["production"]["nodes"][1]["props"] = Dict()),
            document -> (document["components"]["woofer"]["bindings"] = Dict("actuator_grid_indices" => "../path")),
            document -> (document["graphs"]["production"]["nodes"][1]["config"] = Dict("unknown" => 1)),
            document -> push!(document["graphs"]["production"]["nodes"], Dict("name" => "absent")),
            document -> (document["hil"]["command"] = "tweeter.missing_port"),
            document -> push!(document["graphs"]["production"]["inputs"], Dict("name" => "second", "binding" => "second", "destination" => "woofer.pdm_command")),
            document -> (document["graphs"]["production"]["inputs"][1]["destination"] = "custom.same_shape_is_insufficient"),
            document -> (document["wire_contracts"]["commands"][1]["unknown"] = 1),
            document -> (document["profiles"]["grid_gaussian"]["template"] = "unsupported"))
        document, instrument = optical_components_document()
        mutate!(document)
        @test_throws ArgumentError IC.expand_simulation_components!(document, instrument, ".")
    end
    for (field, value) in (("profiles", Dict("invalid" => true)), ("bindings", true), ("settings_bindings", true), ("defaults", true))
        document, instrument = optical_components_document()
        document[field] = value
        @test_throws ArgumentError IC.expand_simulation_components!(document, instrument, ".")
    end
    @test_throws ArgumentError IC.component_template_path("../grid_gaussian")
    @test_throws ArgumentError IC.expand_wire_contracts(Dict("frames" => fill(Dict(), 9), "commands" => fill(Dict(), 8)))
end

@testset "catalog identity distinguishes inline schema property names" begin
    authoring = Dict("settings_schema" => "atmosphere", "profiles" => Dict("custom" => Dict(
        "settings_schema" => Dict("template" => Dict("type" => "string")))))
    @test Set(keys(IC.simulation_catalog_identities(authoring))) == Set(("atmosphere",))
end

@testset "detector calibration overrides only explicit scientific values" begin
    document, instrument = optical_components_document()
    document["sources"] = Dict("on_axis" => Dict())
    document["components"]["detector"] = Dict("template" => "cmos",
        "sensor" => "guide_sensor", "source" => "on_axis", "config" => Dict(
            "binning" => 1, "bits" => 12, "column_readout_noise_e" => 0.0,
            "dark_current_e_per_pixel_s" => 0.96, "frame_schema" => "example.frame/1",
            "full_well_e" => 94000.0, "photon_noise" => true, "photon_rate_schema" => "example.rate/1",
            "quantum_efficiency" => 0.27, "readout_noise" => true, "readout_noise_e" => 2.33,
            "rng_seed" => 0, "row_readout_noise_e" => 0.0))
    push!(document["graphs"]["production"]["nodes"], Dict("name" => "detector"))
    overrides = Dict("dark_current_e_per_pixel_s" => 0.0, "photon_noise" => false,
        "readout_noise" => false, "readout_noise_e" => 0.0)
    push!(document["graphs"]["calibration"]["nodes"], Dict("name" => "detector", "config" => overrides))
    original = deepcopy(document)
    expanded = IC.expand_simulation_components!(document, instrument, ".")
    detector(mode) = only(node for node in expanded.graphs[mode]["nodes"] if node["name"] == "detector")["config"]
    node = only(node for node in expanded.graphs["production"]["nodes"] if node["name"] == "detector")
    @test node["type"] == "detector"
    @test node["detector"] == "cmos"
    @test detector("production")["shutter"] == "global"
    @test detector("production")["photon_noise"]
    @test detector("production")["readout_noise_e"] == 2.33
    @test all(detector("calibration")[key] == value for (key, value) in overrides)
    @test detector("calibration")["rows"] == Dict("\$ref" => "/instrument/wavefront_sensors/guide_sensor/detector_shape/0")
    for field in ("rows", "exposure_duration_s", "gain", "shutter")
        invalid = deepcopy(original)
        invalid["components"]["detector"]["config"][field] = 8
        @test_throws ArgumentError IC.expand_simulation_components!(invalid, instrument, ".")
        invalid = deepcopy(original)
        last(invalid["graphs"]["calibration"]["nodes"])["config"][field] = 8
        @test_throws ArgumentError IC.expand_simulation_components!(invalid, instrument, ".")
    end
end

@testset "explicit measured profiles retain their AOS nodes without Gaussian inference" begin
    document, instrument = optical_components_document()
    IC.expand_simulation_components!(document, instrument, ".")
    measured = deepcopy(document["profiles"]["measured"])
    document["profiles"] = Dict("measured" => measured)
    document["defaults"]["profile"] = "measured"
    document["settings_bindings"] = Any[]
    for selection in values(document["components"])
        delete!(selection, "coupling")
    end
    expanded = IC.expand_simulation_components!(document, instrument, ".")
    @test isempty(document["settings_bindings"])
    for name in ("woofer", "tweeter")
        node = only(node for node in expanded.graphs["production"]["nodes"] if node["name"] == name)
        @test node == only(node for node in measured["nodes"] if node["name"] == name)
        @test node["type"] == "deformable_mirror_surface_f32"
        @test !haskey(node["config"], "influence_width")
    end
end

@testset "Pyramid and EMCCD components share named source photometry" begin
    document, instrument = optical_components_document()
    document["sources"] = Dict("guide" => Dict())
    sensor = Dict("kind" => "pyramid", "pupil_shape" => [60, 60],
        "pupil_separation_pixels" => [60, 60], "pupil_edge_pixels" => [30, 30])
    instrument["wavefront_sensors"]["guide_sensor"] = sensor
    pyramid = Dict("template" => "pyramid", "sensor" => "guide_sensor", "source" => "guide",
        "config" => Dict{String,Any}("modulation" => 3, "modulation_points" => 24,
            "modulation_propagation_strategy" => "pupil_tilt", "pupil_shift_x_pixels" => [0, 0, 0, 0],
            "pupil_shift_y_pixels" => [0, 0, 0, 0], "opd_schema" => "example.opd/1",
            "photon_rate_schema" => "example.rate/1"))
    config = Dict{String,Any}("rows" => 240, "columns" => 240, "gain" => 5000, "em_gain_max" => 5000,
        "quantum_efficiency" => 0.9, "rng_seed" => 2, "photon_noise" => true, "readout_noise" => true,
        "readout_noise_e" => 678.3218668753427, "excess_noise_factor" => sqrt(2),
        "normalized_pupil_sampling" => 1/60, "clock_induced_charge_e_per_pixel_frame" => 0.000828,
        "dark_current_e_per_pixel_s" => 0, "frame_schema" => "example.electrons/1",
        "photon_rate_schema" => "example.rate/1")
    detector = Dict("template" => "emccd", "sensor" => "guide_sensor", "source" => "guide", "config" => config)
    document["components"]["pyramid"], document["components"]["detector"] = pyramid, detector
    overrides = Dict("photon_noise" => false, "readout_noise" => false, "readout_noise_e" => 0,
        "excess_noise_factor" => 1, "clock_induced_charge_e_per_pixel_frame" => 0)
    push!(document["graphs"]["production"]["nodes"], Dict("name" => "pyramid"), Dict("name" => "detector"))
    push!(document["graphs"]["calibration"]["nodes"], Dict("name" => "pyramid"),
        Dict("name" => "detector", "config" => overrides))
    original = deepcopy(document)
    expanded = IC.expand_simulation_components!(document, instrument, ".")
    node(mode, name) = only(node for node in expanded.graphs[mode]["nodes"] if node["name"] == name)
    @test node("production", "pyramid")["config"]["source_wavelength_m"] ==
        node("production", "detector")["config"]["wavelength_m"] ==
        Dict("\$ref" => "/simulation/sources/guide/source_wavelength_m")
    @test node("production", "pyramid")["config"]["pupil_samples"] ==
        Dict("\$ref" => "/instrument/wavefront_sensors/guide_sensor/pupil_shape/0")
    @test node("production", "detector")["type"] == "detector"
    @test node("production", "detector")["detector"] == "emccd"
    @test node("production", "detector")["config"]["shutter"] == "global"
    @test all(node("calibration", "detector")["config"][key] == value for (key, value) in overrides)
    @test config["readout_noise_e"] == node("production", "detector")["config"]["readout_noise_e"]
    for key in ("pupil_shape", "pupil_separation_pixels", "pupil_edge_pixels")
        physical = deepcopy(instrument)
        physical["wavefront_sensors"]["guide_sensor"][key][2] += 1
        @test_throws ArgumentError IC.expand_simulation_components!(deepcopy(original), physical, ".")
    end
    for key in ("wavelength_m", "exposure_duration_s", "shutter")
        invalid = deepcopy(original)
        invalid["components"]["detector"]["config"][key] = 1
        @test_throws ArgumentError IC.expand_simulation_components!(invalid, instrument, ".")
        invalid = deepcopy(original)
        last(invalid["graphs"]["calibration"]["nodes"])["config"][key] = 1
        @test_throws ArgumentError IC.expand_simulation_components!(invalid, instrument, ".")
    end
end

@testset "imaging declaration names an explicit bounded source and sampling" begin
    @test isnothing(IC.validate_imaging(Dict()))
    for imaging in (Dict("source" => "science"), Dict("source" => "science", "zero_padding" => 3))
        @test isnothing(IC.validate_imaging(Dict("sources" => Dict("science" => Dict()), "imaging" => imaging)))
    end
    for imaging in (true, Dict(), Dict("source" => "absent"),
            Dict("source" => "science", "exposure_duration_s" => 1),
            (Dict("source" => "science", "zero_padding" => value) for value in (true, 0, -1, 1.5, 17, Inf))...)
        @test_throws ArgumentError IC.validate_imaging(Dict("sources" => Dict("science" => Dict()), "imaging" => imaging))
    end
end
