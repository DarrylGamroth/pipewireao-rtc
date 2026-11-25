function clocked_optical_documents(directory)
    (; physical, simulation, document, config) = pupil_source_documents(directory)
    C = PipeWireAORTC.Common
    IC = PipeWireAORTC.InstrumentConfiguration
    optical_physical, optical_simulation = external_optical_documents()
    physical["wavefront_sensors"] = optical_physical["wavefront_sensors"]
    physical["optical_paths"] = Dict(
        "scc" => Dict("sensor" => "scc", "lyot_stop_port" => "transmitted"),
    )
    physical["wavefront_sensors"]["scc"]["acquisition"] =
        Dict("exposure_duration_s" => 0.002)

    optical = optical_simulation["components"]["optics"]
    optical["template"] = "proper_optical_train_f32"
    optical["config"]["steps"] = [
        Dict(
            "op" => "add_opd", "name" => "physical_mirror", "input" => "dm_opd",
            "size" => [4, 4], "axes" => [1, 2], "center_pixel" => [3, 3],
            "sampling_m" => [0.003, 0.003], "schema" => "example.surface/1",
            "outside_opd_m" => 0.0,
        ),
    ]
    simulation["components"] = Dict("optics" => optical)
    simulation["profiles"] =
        Dict("grid_gaussian" => Dict("nodes" => Any[], "parameters" => Any[]))
    graph = optical_simulation["graphs"]["scc"]
    push!(
        graph["inputs"],
        Dict("name" => "dm_opd", "binding" => "dm_opd", "destination" => "optics.dm_opd"),
    )

    simulation["graphs"]["scc"] = graph
    delete!(simulation["graphs"], "calibration")
    simulation["graphs"]["plant"] = Dict(
        "schema_version" => 1,
        "name" => "clocked_source",
        "nodes" => [
            Dict(
                "name" => "primary", "type" => "deformable_mirror_surface_f32",
                "config" => Dict(
                    "actuator_count" => 2, "resolution" => 4, "telescope_diameter_m" => 0.012,
                    "pdm_command_schema" => "example.command/1",
                    "surface_opd_schema" => "example.surface/1",
                    "actuator_coordinates_schema" => "example.coordinates/1",
                    "influence_functions_schema" => "example.influences/1",
                ),
            ),
            Dict(
                "name" => "residual", "type" => "spatial_ao_residual_f32",
                "config" => Dict(
                    "resolution" => 4, "telescope_diameter_m" => 0.012, "r0" => 0.15,
                    "reference_wavelength_m" => 500e-9, "fractional_cn2" => [1.0],
                    "wind_speed" => [1.0], "wind_direction_deg" => [0.0],
                    "altitude" => [0.0], "layer_ids" => ["ground"],
                    "atmosphere_step" => 0.002, "rng_seed" => 17,
                    "control_cutoff_cycles_per_m" => 10.0, "residual_amplitude" => 0.25,
                    "residual_opd_schema" => "example.pupil-opd/1",
                ),
            ),
        ],
        "inputs" => [Dict("name" => "command", "binding" => "command", "destination" => "primary.pdm_command")],
        "outputs" => [
            Dict("name" => "pupil_opd", "source" => "residual.residual_opd"),
            Dict("name" => "dm_opd", "source" => "primary.surface_opd"),
        ],
        "parameters" => [
            Dict("binding" => "coordinates", "destination" => "primary.actuator_coordinates"),
            Dict("binding" => "influences", "destination" => "primary.influence_functions"),
        ],
    )
    bindings = simulation["bindings"]
    for binding in ("pupil_opd", "dm_opd")
        bindings[binding] = Dict("kind" => "zeros", "type" => "Float32", "shape" => [4, 4])
    end
    bindings["coordinates"] = Dict("kind" => "mirror_coordinates", "mirror" => "primary")
    bindings["influences"] = Dict("kind" => "zeros", "type" => "Float32", "shape" => [16, 2])
    delete!(bindings, "residual")
    amplitude = joinpath(directory, "amplitude.fits")
    samples = reshape(Float32.(1:16), 4, 4) ./ 16
    PipeWireAORTC.Artifacts.FITSIO.FITS(amplitude, "w") do file
        write(file, samples)
    end
    bindings["source_amplitude"] = Dict(
        "kind" => "fits", "path" => "amplitude.fits", "type" => "Float32",
        "hdu" => 1, "shape" => [4, 4], "axes" => [1, 2], "sha256" => C.sha256_file(amplitude),
    )

    path = write_external_optical_documents(directory, physical, simulation)
    rtc = joinpath(directory, "rtc/configuration.yaml")
    C.write_json(joinpath(directory, "instrument.json"), IC.publication(rtc))
    declaration = IC.load_simulation(path)
    delete!(document["plant"], "graph")
    merge!(
        document,
        Dict(
            "version" => 6, "mode" => "clocked-optical",
            "sensor_nodes" => Dict("scc" => "optical-scc"),
            "source_graph" => "plant", "source_amplitude_binding" => "source_amplitude",
            "source_pupil_axes" => [2, 1], "source_dm_axes" => ["y", "x"],
            "command_node" => "mirror-command", "command_schema" => "example.command/1",
            "command_units" => "m", "command_limit" => 1.0,
            "prescription_identity" => IC.prescription_identity(declaration, IC.settings(declaration)),
        ),
    )
    C.write_json(config, document)
    return (; config, path, document, simulation, amplitude, samples)
end
