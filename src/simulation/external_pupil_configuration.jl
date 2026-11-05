function verify_clocked_mirror_plane(node,mirror_config,schema,resolution)
    config = node["config"]
    plane = if node["type"] == "proper_optical_train_f32"
        steps = get(config,"steps",[])
        matches = filter(step -> get(step,"op",nothing) == "add_opd" && get(step,"input",nothing) == "dm_opd",steps)
        length(matches) == 1 || throw(ArgumentError("optical mirror input requires one declared physical plane"))
        only(matches)
    elseif node["type"] == "compiled_optical_paths_f32"
        grid = get(config,"dm_grid",nothing)
        clocked_mirror_grid(grid)
        merge(Dict{String,Any}(grid),Dict("schema"=>get(config,"dm_opd_schema",nothing)))
    else
        throw(ArgumentError("unsupported clocked optical mirror-plane owner"))
    end
    pitch = mirror_config["telescope_diameter_m"] / resolution
    center = fld(resolution,2) + 1
    get(plane,"schema",nothing) == schema && get(plane,"size",nothing) == [resolution,resolution] &&
        get(plane,"axes",nothing) == [1,2] && get(plane,"center_pixel",nothing) == [center,center] &&
        all(value -> isapprox(value,pitch;rtol=1e-6,atol=0),get(plane,"sampling_m",[])) && length(get(plane,"sampling_m",[])) == 2 ||
        throw(ArgumentError("optical mirror plane schema, axes or sampling differ"))
    return nothing
end

# Version 4 is an external optical input, with no mirror-command boundary.
external_pupil_chopping(value, declaration) = throw(ArgumentError("external-pupil chopping must be a mapping"))
function external_pupil_chopping(value::AbstractDict, declaration)
    foreach(chopping_name, keys(value))
    paths = get(declaration.instrument.document, "optical_paths", Dict())
    length(value) <= length(paths) || throw(ArgumentError("chopping must name physical optical paths"))
    names = Tuple(Symbol.(sort!(collect(keys(value)))))
    rows = map(names) do name
        key = string(name)
        haskey(paths, key) || throw(ArgumentError("chopping names an unknown optical path $key"))
        row = value[key]
        InstrumentConfiguration.fields(row, ("unfringed_graph", "initial_phase", "trigger_high_is_fringed"),
            ("unfringed_graph", "initial_phase", "trigger_high_is_fringed"), "chopping $key")
        graph = text(row["unfringed_graph"], "unfringed graph")
        haskey(declaration.graphs, graph) && !haskey(paths, graph) ||
            throw(ArgumentError("unfringed graph must name a distinct auxiliary optical graph"))
        phase = row["initial_phase"]
        phase in ("fringed", "unfringed") || throw(ArgumentError("initial_phase must be fringed or unfringed"))
        (; unfringed_graph=graph, initial_phase=phase,
            trigger_high_is_fringed=boolean(row["trigger_high_is_fringed"], "trigger_high_is_fringed"))
    end
    length(unique(row.unfringed_graph for row in rows)) == length(rows) ||
        throw(ArgumentError("chopped paths require distinct unfringed graph selections"))
    return NamedTuple{names}(Tuple(rows))
end

function external_pupil_configuration(path, document)
    required = ("version", "mode", "plant", "sensor_nodes", "backend", "device",
        "instrument", "rtc_configuration", "calibration_identity", "prescription_identity")
    clocked = document["version"] === 6
    additional = clocked ? ("source_graph","source_amplitude_binding","source_pupil_axes","source_dm_axes","command_input","command_node","command_schema","command_units","command_limit","mirror","rate","pacing_rate_hz") : ("pupil_node",)
    optional = clocked ? ("command_buffers",) : ()
    InstrumentConfiguration.fields(document, (required...,"sensor_buffers","reference_clock",additional...,optional...), (required...,additional...), "optical owner")
    document["mode"] == (clocked ? "clocked-optical" : "external-pupil") || throw(ArgumentError("optical owner mode differs from version"))
    config_path = abspath(path)
    entry = document["plant"]
    InstrumentConfiguration.fields(entry, ("definition", "settings", "chopping"), ("definition", "settings"), "external-pupil plant")
    definition = DeploymentConfiguration.relative_asset(dirname(config_path), entry["definition"])
    declaration = InstrumentConfiguration.load_simulation(definition)
    haskey(declaration.document, "hil") && throw(ArgumentError("external-pupil owner requires standalone optical paths"))
    clocked || isempty(declaration.instrument.document["deformable_mirrors"]) ||
        throw(ArgumentError("external-pupil instrument must be mirror-free"))
    configured = InstrumentConfiguration.settings(declaration, entry["settings"])
    chopping = external_pupil_chopping(get(entry, "chopping", Dict()), declaration)
    paths = get(declaration.instrument.document, "optical_paths", Dict())
    1 <= length(paths) <= 16 || throw(ArgumentError("external-pupil owner requires 1:16 physical optical paths"))
    nodes = document["sensor_nodes"]
    optical_sensor_nodes(nodes, paths)
    names = Tuple(Symbol.(sort!(collect(keys(paths)))))
    sensor_nodes = NamedTuple{names}(Tuple(node_name(nodes[string(name)], "sensor node") for name in names))
    pupil_node = clocked ? nothing : node_name(document["pupil_node"], "pupil node")
    all_nodes = (clocked ? document["command_node"] : pupil_node, values(sensor_nodes)...)
    length(unique(all_nodes)) == length(all_nodes) || throw(ArgumentError("pupil and sensor node names must differ"))
    for (name, optical_path) in paths
        haskey(declaration.graphs, name) || throw(ArgumentError("optical path has no graph $name"))
        sensor = declaration.instrument.document["wavefront_sensors"][optical_path["sensor"]]
        duration = get(get(sensor, "acquisition", Dict()), "exposure_duration_s", nothing)
        InstrumentConfiguration.isfinite_positive(duration) ||
            throw(ArgumentError("each optical sensor requires a positive exposure duration"))
    end
    backend = Symbol(text(document["backend"], "backend"))
    backend in (:cpu, :cuda, :amdgpu) || throw(ArgumentError("external-pupil backend must be cpu, cuda or amdgpu"))
    device = integer(document["device"], "device", 0, typemax(Int32))
    (backend === :cpu ? device == 0 : backend !== :amdgpu || device >= 1) || throw(ArgumentError("invalid external-pupil device ordinal"))
    instrument = DeploymentConfiguration.relative_asset(dirname(config_path), document["instrument"])
    rtc_configuration = DeploymentConfiguration.relative_asset(dirname(config_path), document["rtc_configuration"])
    sensor_buffers=integer(get(document,"sensor_buffers",3),"sensor_buffers",2,64)
    source = if clocked
        command_buffers = integer(get(document,"command_buffers",3),"command_buffers",2,64)
        source_graph = text(document["source_graph"],"optical source graph")
        haskey(declaration.graphs,source_graph) && source_graph != "calibration" || throw(ArgumentError("unknown optical source graph"))
        mirror = text(document["mirror"],"optical mirror")
        mirrors = declaration.instrument.document["deformable_mirrors"]
        haskey(mirrors,mirror) && mirrors[mirror]["units"] == document["command_units"] ||
            throw(ArgumentError("clocked optical command units differ from physical mirror"))
        command_count = length(InstrumentConfiguration.json_value(InstrumentConfiguration.physical_definition(declaration.instrument))["deformable_mirrors"][mirror]["layout"]["command_positions"])
        command_input = identifier(document["command_input"],"optical source command input")
        graph_document = InstrumentConfiguration.graph_document(declaration,configured;simulation_graph=source_graph)
        inputs = filter(row -> row["name"] == string(command_input),graph_document["inputs"])
        length(inputs) == 1 && only(inputs)["destination"] == mirror*".pdm_command" ||
            throw(ArgumentError("clocked optical command must bind the declared physical mirror input"))
        nodes = filter(row -> row["name"] == mirror,graph_document["nodes"])
        length(nodes) == 1 || throw(ArgumentError("clocked optical source requires one mirror"))
        only(nodes)["type"] == "deformable_mirror_surface_f32" ||
            throw(ArgumentError("clocked optical mirror requires a Float32 surface model"))
        command_binding = declaration.document["bindings"][only(inputs)["binding"]]
        get(command_binding,"type",nothing) == "Float32" && get(command_binding,"shape",nothing) == [command_count] ||
            throw(ArgumentError("clocked optical command binding differs from its physical mirror port"))
        mirror_config = only(nodes)["config"]
        get(mirror_config,"pdm_command_schema",nothing) == document["command_schema"] ||
            throw(ArgumentError("clocked optical command schema differs from mirror port"))
        rtc = InstrumentConfiguration.load_rtc(rtc_configuration)
        limiter = rtc.controls["deformable_mirrors"][mirror]["limiter"]
        get(limiter,"kind",nothing) == "amplitude" &&
            get(limiter,"lower",nothing) == -document["command_limit"] &&
            get(limiter,"upper",nothing) == document["command_limit"] ||
            throw(ArgumentError("clocked optical command limit differs from RTC mirror limiter"))
        required_outputs = Set(("pupil_opd","dm_opd"))
        required_outputs ⊆ Set(row["name"] for row in graph_document["outputs"]) ||
            throw(ArgumentError("clocked optical source requires explicit entrance pupil and physical mirror OPD outputs"))
        only(filter(row -> row["name"] == "dm_opd",graph_document["outputs"]))["source"] == mirror*".surface_opd" ||
            throw(ArgumentError("clocked optical mirror OPD must retain the measured mirror output"))
        rate = integer(document["rate"],"rate",1,1_000_000_000)
        period_ns = UInt64(div(1_000_000_000+div(rate,2),rate))
        round(UInt64,Float64(Float32(declaration.document["frame_period_s"]))*1e9) == period_ns ||
            throw(ArgumentError("clocked optical source cadence differs from its graph"))
        limit = document["command_limit"]
        InstrumentConfiguration.isfinite_positive(limit) && isfinite(Float32(limit)) || throw(ArgumentError("invalid native command amplitude limit"))
        document["source_dm_axes"] == ["y","x"] ||
            throw(ArgumentError("clocked optical DM raster must declare [y,x] axes"))
        mirror_schema = get(mirror_config,"surface_opd_schema",nothing)
        mirror_resolution = get(mirror_config,"resolution",nothing)
        physical_mirror_raster(mirror_schema, mirror_resolution) ||
            throw(ArgumentError("physical mirror must declare an OPD schema and raster"))
        optical_graphs = vcat(collect(keys(paths)),[row.unfringed_graph for row in values(chopping)])
        for optical_graph in optical_graphs
            graph = InstrumentConfiguration.graph_document(declaration,configured;simulation_graph=optical_graph)
            dm_inputs = filter(row -> row["name"] == "dm_opd",graph["inputs"])
            length(dm_inputs) == 1 || throw(ArgumentError("optical graph must expose the physical mirror OPD"))
            input = only(dm_inputs)
            binding = declaration.document["bindings"][input["binding"]]
            get(binding,"type",nothing) == "Float32" && get(binding,"shape",nothing) == [mirror_resolution,mirror_resolution] ||
                throw(ArgumentError("optical mirror raster type or shape differs"))
            owner = first(split(input["destination"],"."))
            nodes = filter(row -> row["name"] == owner,graph["nodes"])
            length(nodes) == 1 || throw(ArgumentError("optical mirror input has no unique owner"))
            verify_clocked_mirror_plane(only(nodes),mirror_config,mirror_schema,mirror_resolution)
        end
        source_amplitude_binding = text(document["source_amplitude_binding"],"source amplitude binding")
        haskey(declaration.document["bindings"],source_amplitude_binding) || throw(ArgumentError("unknown static pupil amplitude binding"))
        amplitude_binding = declaration.document["bindings"][source_amplitude_binding]
        get(amplitude_binding,"kind",nothing) == "fits" && get(amplitude_binding,"type",nothing) == "Float32" &&
            length(get(amplitude_binding,"shape",[])) == 2 && get(amplitude_binding,"axes",nothing) == [1,2] &&
            InstrumentConfiguration.valid_sha256(get(amplitude_binding,"sha256",nothing)) ||
            throw(ArgumentError("clocked optical amplitude must be hashed Float32 FITS with explicit [y,x] axes"))
        source_pupil_axes = document["source_pupil_axes"]
        pupil_output = only(filter(row -> row["name"] == "pupil_opd",graph_document["outputs"]))
        pupil_owner = first(split(pupil_output["source"],"."))
        pupil_nodes = filter(row -> row["name"] == pupil_owner,graph_document["nodes"])
        length(pupil_nodes) == 1 && only(pupil_nodes)["type"] == "spatial_ao_residual_f32" &&
            source_pupil_axes == [2,1] || throw(ArgumentError("clocked source requires native [x,y] spatial AO OPD transformed to [y,x]"))
        (;source_graph,source_amplitude_binding,source_pupil_axes=Tuple(source_pupil_axes),command_input,command_count,command_node=node_name(document["command_node"],"optical command node"),
            command_schema=text(document["command_schema"],"optical command schema"),command_units=text(document["command_units"],"optical command units"),
            command_limit=Float32(limit),command_buffers,mirror,rate,period_ns,pacing_rate_hz=document["pacing_rate_hz"],
            pacing_period_ns=pacing_period(document["pacing_rate_hz"],rate))
    else
        (;)
    end
    return merge((; reference_clock=reference_clock_configuration(get(document,"reference_clock",nothing)),
        version=clocked ? 6 : 4, mode=clocked ? :clocked_optical : :external_pupil, config_path, sensor_buffers,
        plant=(; definition, settings=plant_settings(configured), chopping), graph=nothing,
        pupil_node, sensor_nodes, backend, device, instrument, rtc_configuration,
        calibration_identity=text(document["calibration_identity"], "calibration identity"),
        prescription_identity=text(document["prescription_identity"], "prescription identity")),source)
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

clocked_mirror_grid(value::AbstractDict) = value
clocked_mirror_grid(value) = throw(ArgumentError("compiled optical mirror grid must be explicit"))

chopping_name(value::String) = value
chopping_name(value) = throw(ArgumentError("chopping names must be strings"))

optical_sensor_nodes(value, paths) = throw(ArgumentError("sensor_nodes must name every physical optical path exactly once"))
function optical_sensor_nodes(value::AbstractDict, paths)
    Set(keys(value)) == Set(keys(paths)) || return optical_sensor_nodes(nothing, paths)
    return value
end

physical_mirror_raster(schema::String, resolution) = InstrumentConfiguration.ispositive_integer(resolution)
physical_mirror_raster(schema, resolution) = false
