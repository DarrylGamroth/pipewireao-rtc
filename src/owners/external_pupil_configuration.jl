# Version 4 is an external optical input, with no mirror-command boundary.
function external_pupil_configuration(path, document)
    required = ("version", "mode", "plant", "pupil_node", "sensor_nodes", "backend", "device",
        "instrument", "rtc_configuration", "calibration_identity", "prescription_identity")
    InstrumentConfiguration.fields(document, required, required, "external-pupil owner")
    document["mode"] == "external-pupil" || throw(ArgumentError("version 4 requires mode external-pupil"))
    config_path = abspath(path)
    entry = document["plant"]
    InstrumentConfiguration.fields(entry, ("definition", "settings"), ("definition", "settings"), "external-pupil plant")
    definition = DeploymentConfiguration.relative_asset(dirname(config_path), entry["definition"])
    declaration = InstrumentConfiguration.load_simulation(definition)
    haskey(declaration.document, "hil") && throw(ArgumentError("external-pupil owner requires standalone optical paths"))
    isempty(declaration.instrument.document["deformable_mirrors"]) ||
        throw(ArgumentError("external-pupil instrument must be mirror-free"))
    configured = InstrumentConfiguration.settings(declaration, entry["settings"])
    paths = get(declaration.instrument.document, "optical_paths", Dict())
    1 <= length(paths) <= 16 || throw(ArgumentError("external-pupil owner requires 1:16 physical optical paths"))
    nodes = document["sensor_nodes"]
    nodes isa AbstractDict && Set(keys(nodes)) == Set(keys(paths)) ||
        throw(ArgumentError("sensor_nodes must name every physical optical path exactly once"))
    names = Tuple(Symbol.(sort!(collect(keys(paths)))))
    sensor_nodes = NamedTuple{names}(Tuple(node_name(nodes[string(name)], "sensor node") for name in names))
    pupil_node = node_name(document["pupil_node"], "pupil node")
    all_nodes = (pupil_node, values(sensor_nodes)...)
    length(unique(all_nodes)) == length(all_nodes) || throw(ArgumentError("pupil and sensor node names must differ"))
    for (name, optical_path) in paths
        haskey(declaration.graphs, name) || throw(ArgumentError("optical path has no graph $name"))
        sensor = declaration.instrument.document["wavefront_sensors"][optical_path["sensor"]]
        duration = get(get(sensor, "acquisition", Dict()), "exposure_duration_s", nothing)
        InstrumentConfiguration.isfinite_positive(duration) ||
            throw(ArgumentError("each optical sensor requires a positive exposure duration"))
    end
    backend = Symbol(text(document["backend"], "backend"))
    backend in (:cpu, :amdgpu) || throw(ArgumentError("external-pupil backend must be cpu or amdgpu"))
    device = integer(document["device"], "device", 0, typemax(Int32))
    (backend === :cpu ? device == 0 : device >= 1) || throw(ArgumentError("invalid external-pupil device ordinal"))
    instrument = DeploymentConfiguration.relative_asset(dirname(config_path), document["instrument"])
    rtc_configuration = DeploymentConfiguration.relative_asset(dirname(config_path), document["rtc_configuration"])
    return (; version=4, mode=:external_pupil, config_path,
        plant=(; definition, settings=plant_settings(configured)), graph=nothing,
        pupil_node, sensor_nodes, backend, device, instrument, rtc_configuration,
        calibration_identity=text(document["calibration_identity"], "calibration identity"),
        prescription_identity=text(document["prescription_identity"], "prescription identity"))
end

function verify_external_pupil_declaration(options)
    IC = InstrumentConfiguration
    actual = InstrumentDefinition.load(options.instrument).document
    actual == IC.json_value(IC.publication(options.rtc_configuration)) ||
        throw(ArgumentError("external-pupil publication differs from its RTC declaration"))
    declaration = IC.load_simulation(options.plant.definition)
    rtc = IC.load_rtc(options.rtc_configuration)
    rtc.instrument.path == declaration.instrument.path ||
        throw(ArgumentError("external-pupil simulation and RTC must reference the same instrument"))
    options.calibration_identity == rtc.document["calibration_identity"] ||
        throw(ArgumentError("external-pupil calibration identity differs"))
    configured = IC.settings(declaration, options.plant.settings)
    options.prescription_identity == IC.prescription_identity(declaration, configured) ||
        throw(ArgumentError("external-pupil prescription identity differs"))
    return nothing
end
