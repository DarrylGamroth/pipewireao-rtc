Base.include(@__MODULE__, joinpath(@__DIR__, "zemax_component_documents.jl"))

function aos_graph_documents(directory)
    physical, simulation = zemax_component_documents(directory)
    C = PipeWireAORTC.Common
    IC = PipeWireAORTC.InstrumentConfiguration
    C.write_json(joinpath(directory, "mirror.json"), Dict("schema_version" => 1,
        "id" => "test-mirror", "manufacturer" => "Example", "model" => "Synthetic",
        "layout" => Dict("schema_version" => 1, "name" => "Test grid", "grid_shape" => [2, 2],
            "command_positions" => [[1, 1], [2, 2]], "axis_labels" => ["column", "row"], "command_order" => "physical")))
    physical["deformable_mirrors"] = Dict("primary" => Dict("description" => "mirror.json",
        "pupil_registration" => Dict("actuator_pitch_pupil_radius" => 0.2), "units" => "m", "command_scale_m" => 1))
    physical["wavefront_sensors"] = Dict("sensor" => Dict("kind" => "pyramid",
        "detector_shape" => [8, 8], "pupil_shape" => [4, 4], "pupil_separation_pixels" => [0, 0],
        "pupil_edge_pixels" => [0, 0], "expected_schema" => "example.frame/1"))
    imported = simulation["graphs"]["scc"]
    native = deepcopy(imported)
    native["nodes"] = [Dict("name" => "optics", "type" => "caller_supplied_optics", "config" => Dict())]
    simulation["graphs"] = Dict("production" => native, "calibration" => deepcopy(native),
        "internal-source" => deepcopy(native), "dark" => deepcopy(native), "optical-reference" => imported)
    simulation["hil"] = Dict("command" => "optics.pupil_opd", "frame" => "optics.output")
    simulation["wire_contracts"] = [Dict("frame_encoding" => "uint16", "frame_schema" => "example.frame/1",
        "command_schema" => "example.command/1", "command_scale" => 1)]
    path = write_external_optical_documents(directory, physical, simulation)
    mkpath(joinpath(directory, "rtc"))
    C.write_yaml(joinpath(directory, "rtc", "mirror-controls.yaml"), Dict("schema_version" => 1,
        "deformable_mirrors" => Dict("primary" => Dict(
            "limiter" => Dict("kind" => "amplitude", "lower" => -1, "upper" => 1),
            "shape_control" => Dict("bases" => [Dict("id" => "zernike", "name" => "Zernike", "units" => "m",
                "coefficient_limit" => 1, "normalization" => "sampled_peak",
                "definition" => Dict("kind" => "zernike", "modes" => [Dict("n" => 1, "m" => 1, "name" => "tilt")]))])))))
    rtc_path = joinpath(directory, "rtc", "configuration.yaml")
    calibration_identity = "sha256:" * repeat("a", 64)
    C.write_yaml(rtc_path, Dict("schema_version" => 1, "instrument" => "../instrument.yaml",
        "dimensions" => Dict(), "mirror_controls" => "rtc/mirror-controls.yaml",
        "publication" => "instrument.json", "calibration_identity" => calibration_identity))
    C.write_json(joinpath(directory, "instrument.json"), IC.publication(rtc_path))
    declaration = IC.load_simulation(path)
    document = Dict{String,Any}("version" => 3,
        "plant" => Dict{String,Any}("definition" => "simulation/definition.yaml", "settings" => Dict()),
        "rtc_configuration" => "rtc/configuration.yaml", "instrument" => "instrument.json",
        "calibration_identity" => calibration_identity,
        "prescription_identity" => IC.prescription_identity(declaration, IC.settings(declaration)),
        "command_input" => "pupil_opd", "frame_output" => "intensity", "command_count" => 2,
        "frame_shape" => [8, 8], "rate" => 500, "exposure_ns" => 2_000_000,
        "pacing_rate_hz" => 0, "backend" => "cpu", "device" => 0, "frame_encoding" => "uint16",
        "frame_schema" => "example.frame/1", "command_schema" => "example.command/1", "command_scale" => 1)
    return (; document, declaration, path)
end
