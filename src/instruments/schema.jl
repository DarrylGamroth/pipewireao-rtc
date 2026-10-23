"""Validate declaration structure, references, and all application asset paths."""
function validate_declaration(document::AbstractDict, directory::AbstractString)
    top_fields = ("schema_version", "id", "defaults", "settings_schema", "wire_contracts",
        "deformable_mirrors", "wavefront_sensors", "graphs", "profiles",
        "bindings", "settings_bindings", "frame_period_s", "hil")
    fields(document, top_fields, top_fields, "instrument declaration")
    document["schema_version"] === 1 || throw(ArgumentError("unsupported instrument declaration schema"))
    InstrumentDefinition.identifier(document["id"]) || throw(ArgumentError("invalid instrument identifier"))
    for key in ("defaults", "settings_schema", "deformable_mirrors", "wavefront_sensors",
            "graphs", "profiles", "bindings")
        InstrumentDefinition.object_value(document[key]) || throw(ArgumentError("instrument $key must be an object"))
    end
    defaults = document["defaults"]
    settings_schema = document["settings_schema"]
    mirrors = document["deformable_mirrors"]
    sensors = document["wavefront_sensors"]
    profiles = document["profiles"]
    bindings = document["bindings"]
    1 <= length(mirrors) <= 16 || throw(ArgumentError("instrument requires 1:16 mirrors"))
    1 <= length(sensors) <= 16 || throw(ArgumentError("instrument requires 1:16 sensors"))
    isfinite_positive(document["frame_period_s"]) || throw(ArgumentError("frame_period_s must be finite and positive"))
    _declaration_object(settings_schema, "settings_schema")
    haskey(settings_schema, "type") && haskey(settings_schema, "properties") ||
        throw(ArgumentError("settings_schema must declare type and properties"))
    settings_schema["type"] == "object" && InstrumentDefinition.object_value(settings_schema["properties"]) ||
        throw(ArgumentError("settings_schema must declare object properties"))
    _validate_wire_contracts(document["wire_contracts"])

    graph_paths = _declaration_fields(document["graphs"], ("production", "calibration"),
        ("production", "calibration"), "graphs")
    graph_nodes = Dict{String,Set{String}}()
    graph_inputs = Dict{String,Set{String}}()
    graph_outputs = Dict{String,Set{String}}()
    for mode in ("production", "calibration")
        graph_path = D.relative_asset(directory, graph_paths[mode])
        graph = _declaration_graph(graph_path)
        graph_nodes[mode] = graph.nodes
        graph_inputs[mode] = graph.inputs
        graph_outputs[mode] = graph.outputs
    end
    all_graph_nodes = union(values(graph_nodes)...)
    _validate_profiles(profiles, bindings, all_graph_nodes)
    for name in keys(mirrors)
        _declaration_identifier(name, "mirror name")
        _validate_mirror_declaration(mirrors[name], directory, name, defaults, settings_schema, profiles)
    end
    for name in keys(sensors)
        _declaration_identifier(name, "sensor name")
        _validate_sensor_declaration(sensors[name], directory, name)
    end
    _validate_bindings(bindings, mirrors, defaults, settings_schema, profiles, directory)
    _validate_settings_bindings(document["settings_bindings"], profiles, defaults,
        settings_schema, all_graph_nodes)
    _validate_hil(document["hil"], graph_inputs, graph_outputs)
    return nothing
end

validate_declaration(document, directory) = throw(ArgumentError("instrument declaration and directory must have supported types"))

_declaration_object(value, label) = InstrumentDefinition.object_value(value) ? value :
    throw(ArgumentError("$label must be an object"))
function _declaration_fields(value, allowed, required, label)
    fields(_declaration_object(value, label), allowed, required, label)
end
_declaration_identifier(value, label) = InstrumentDefinition.identifier(value) ? value :
    throw(ArgumentError("invalid $label"))
_declaration_text(value, label) = InstrumentDefinition.nonempty_text(value) ? value :
    throw(ArgumentError("invalid $label"))
_declaration_array(value, label; nonempty=false) =
    InstrumentDefinition.array_value(value) && (!nonempty || !isempty(value)) ? value :
        throw(ArgumentError("$label must be an array$(nonempty ? " with at least one entry" : "")"))

isfinite_positive(value::Real) = isfinite(value) && value > 0
isfinite_positive(::Bool) = false
isfinite_positive(value) = false
ispositive_integer(value::Integer) = value > 0
ispositive_integer(::Bool) = false
ispositive_integer(value) = false
isinteger_value(::Integer) = true
isinteger_value(::Bool) = false
isinteger_value(value) = false
isnonnegative_integer(value::Integer) = value >= 0
isnonnegative_integer(::Bool) = false
isnonnegative_integer(value) = false

function _validate_mirror_declaration(spec, directory, name, defaults, settings_schema, profiles)
    mirror = _declaration_fields(spec,
        ("description", "pupil_registration_setting", "units", "command_scale_m", "limiter", "shape_control"),
        ("description", "pupil_registration_setting", "units", "command_scale_m", "limiter", "shape_control"),
        "mirror $name")
    D.relative_asset(directory, mirror["description"])
    _validate_setting_reference(mirror["pupil_registration_setting"], defaults, settings_schema,
        profiles, "mirror pupil registration setting")
    _declaration_text(mirror["units"], "mirror units")
    isfinite_positive(mirror["command_scale_m"]) || throw(ArgumentError("mirror command_scale_m must be finite and positive"))
    limiter = _declaration_fields(mirror["limiter"], ("kind", "lower", "upper"),
        ("kind", "lower", "upper"), "mirror limiter")
    limiter["kind"] == "amplitude" || throw(ArgumentError("mirror limiter kind must be amplitude"))
    for key in ("lower", "upper")
        value = limiter[key]
        if InstrumentDefinition.array_value(value)
            !isempty(value) && all(isfinite_real, value) || throw(ArgumentError("mirror limiter $key must contain finite values"))
        else
            isfinite_real(value) || throw(ArgumentError("mirror limiter $key must be finite"))
        end
    end
    _validate_shape_control(mirror["shape_control"])
    return nothing
end

isfinite_real(value::Real) = isfinite(value)
isfinite_real(::Bool) = false
isfinite_real(value) = false

function _validate_shape_control(value)
    shape = _declaration_fields(value, ("coefficient_limit", "zernike", "fourier", "provenance"),
        ("coefficient_limit", "zernike", "fourier", "provenance"), "shape_control")
    isfinite_positive(shape["coefficient_limit"]) || throw(ArgumentError("shape coefficient_limit must be finite and positive"))
    _declaration_text(shape["provenance"], "shape-control provenance")
    zernike = _declaration_fields(shape["zernike"], ("modes",), ("modes",), "Zernike settings")
    modes = _declaration_array(zernike["modes"], "Zernike modes"; nonempty=true)
    for mode in modes
        entry = _declaration_fields(mode, ("n", "m", "name"), ("n", "m", "name"), "Zernike mode")
        isnonnegative_integer(entry["n"]) || throw(ArgumentError("Zernike n must be a nonnegative integer"))
        isinteger_value(entry["m"]) || throw(ArgumentError("Zernike m must be an integer"))
        _declaration_text(entry["name"], "Zernike mode name")
    end
    fourier = _declaration_fields(shape["fourier"], ("max_frequency",),
        ("max_frequency",), "Fourier settings")
    isnonnegative_integer(fourier["max_frequency"]) || throw(ArgumentError("Fourier max_frequency must be a nonnegative integer"))
    return nothing
end

function _validate_sensor_declaration(spec, directory, name)
    sensor = _declaration_fields(spec,
        ("detector_shape", "subaperture_shape", "subaperture_origins", "expected_schema", "provenance"),
        ("detector_shape", "subaperture_shape", "subaperture_origins", "expected_schema", "provenance"),
        "sensor $name")
    _validate_positive_shape(sensor["detector_shape"], "sensor detector_shape")
    _validate_positive_shape(sensor["subaperture_shape"], "sensor subaperture_shape")
    _validate_artifact(sensor["subaperture_origins"], directory, "subaperture_origins")
    _declaration_text(sensor["expected_schema"], "sensor expected_schema")
    _declaration_text(sensor["provenance"], "sensor provenance")
    return nothing
end

function _validate_artifact(value, directory, label)
    artifact = _declaration_fields(value, ("path", "hdu", "axes", "type", "shape"),
        ("path", "hdu", "axes", "type", "shape"), label)
    return _validate_artifact_values(artifact, directory, label)
end

function _validate_artifact_values(artifact, directory, label)
    D.relative_asset(directory, artifact["path"])
    ispositive_integer(artifact["hdu"]) || throw(ArgumentError("$label hdu must be a positive integer"))
    _validate_positive_shape(artifact["shape"], "$label shape")
    _validate_axes(artifact["axes"], length(artifact["shape"]), "$label axes")
    _validate_element_type(artifact["type"], label)
    return nothing
end

function _validate_positive_shape(value, label)
    shape = _declaration_array(value, label; nonempty=true)
    all(ispositive_integer, shape) || throw(ArgumentError("$label must contain positive integer extents"))
    return nothing
end

function _validate_axes(value, rank, label)
    axes = _declaration_array(value, label; nonempty=true)
    all(ispositive_integer, axes) && length(axes) == rank && Set(axes) == Set(1:rank) ||
        throw(ArgumentError("$label must be a permutation of axes 1:$rank"))
    return nothing
end

function _validate_element_type(value, label)
    _declaration_text(value, "$label element type")
    value in string.(Artifacts.TARGET_TYPES) || throw(ArgumentError("unsupported $label element type"))
    return nothing
end

function _validate_profiles(profiles, bindings, graph_nodes)
    !isempty(profiles) || throw(ArgumentError("instrument requires at least one profile"))
    for (name, profile_value) in profiles
        _declaration_identifier(name, "profile name")
        profile = _declaration_fields(profile_value, ("nodes", "parameters", "settings_schema"),
            ("nodes", "parameters"), "profile $name")
        if haskey(profile, "settings_schema")
            _declaration_object(profile["settings_schema"], "profile $name settings_schema")
        end
        node_names = Set{String}()
        for node_value in _declaration_array(profile["nodes"], "profile $name nodes")
            node = _declaration_fields(node_value, ("name", "type", "config", "props"),
                ("name", "type", "config"), "profile $name node")
            node_name = _declaration_text(node["name"], "profile $name node name")
            node_name in node_names && throw(ArgumentError("profile $name repeats node $node_name"))
            node_name in graph_nodes || throw(ArgumentError("profile $name targets absent graph node $node_name"))
            push!(node_names, node_name)
            _declaration_text(node["type"], "profile $name node type")
            _declaration_object(node["config"], "profile $name node config")
            haskey(node, "props") && _declaration_object(node["props"], "profile $name node props")
        end
        for parameter_value in _declaration_array(profile["parameters"], "profile $name parameters")
            parameter = _declaration_fields(parameter_value, ("destination", "binding"),
                ("destination", "binding"), "profile $name parameter")
            _declaration_text(parameter["destination"], "profile $name parameter destination")
            haskey(bindings, parameter["binding"]) || throw(ArgumentError(
                "profile $name references absent binding $(parameter["binding"])",
            ))
        end
    end
    return nothing
end

function _validate_wire_contracts(value)
    contracts = _declaration_array(value, "wire_contracts"; nonempty=true)
    length(contracts) <= 64 || throw(ArgumentError("wire_contracts exceeds the bounded registry size"))
    for contract_value in contracts
        contract = _declaration_fields(contract_value,
            ("frame_encoding", "frame_schema", "command_schema", "command_scale"),
            ("frame_encoding", "frame_schema", "command_schema", "command_scale"),
            "wire contract")
        _declaration_text(contract["frame_encoding"], "wire contract frame_encoding")
        _declaration_text(contract["frame_schema"], "wire contract frame_schema")
        _declaration_text(contract["command_schema"], "wire contract command_schema")
        isfinite_positive(contract["command_scale"]) ||
            throw(ArgumentError("wire contract command_scale must be finite and positive"))
    end
    return nothing
end

function _validate_bindings(bindings, mirrors, defaults, settings_schema, profiles, directory)
    for (name, binding_value) in bindings
        _declaration_identifier(name, "binding name")
        InstrumentDefinition.object_value(binding_value) || throw(ArgumentError("binding $name must be an object"))
        kind = get(binding_value, "kind", nothing)
        if kind == "zeros"
            binding = _declaration_fields(binding_value, ("kind", "shape", "type"),
                ("kind", "shape", "type"), "zero binding $name")
            shape = _declaration_array(binding["shape"], "zero binding shape"; nonempty=true)
            all(extent -> _valid_zero_extent(extent, defaults, settings_schema, profiles), shape) ||
                throw(ArgumentError("zero binding shape must use positive extents or existing setting names"))
            _validate_element_type(binding["type"], "zero binding")
        elseif kind in ("mirror_coordinates", "mirror_grid_indices")
            binding = _declaration_fields(binding_value, ("kind", "mirror"),
                ("kind", "mirror"), "mirror geometry binding $name")
            _validate_mirror_reference(binding["mirror"], mirrors)
        elseif kind == "measured_influences"
            binding = _declaration_fields(binding_value, ("kind", "mirror", "setting"),
                ("kind", "mirror", "setting"), "measured influence binding $name")
            _validate_mirror_reference(binding["mirror"], mirrors)
            _validate_setting_reference(binding["setting"], defaults, settings_schema, profiles,
                "measured influence setting")
        elseif kind == "fits"
            binding = _declaration_fields(binding_value, ("kind", "path", "hdu", "axes", "type", "shape"),
                ("kind", "path", "hdu", "axes", "type", "shape"), "FITS binding $name")
            _validate_artifact_values(binding, directory, "FITS binding $name")
        else
            throw(ArgumentError("unknown instrument binding kind for $name"))
        end
    end
    return nothing
end

_valid_zero_extent(value::Integer, defaults, settings_schema, profiles) = ispositive_integer(value)
function _valid_zero_extent(value::AbstractString, defaults, settings_schema, profiles)
    _validate_setting_reference(value, defaults, settings_schema, profiles, "zero shape setting")
    return true
end
_valid_zero_extent(value, defaults, settings_schema, profiles) = false

function _validate_mirror_reference(name, mirrors)
    _declaration_text(name, "binding mirror reference")
    haskey(mirrors, name) || throw(ArgumentError("binding references absent mirror $name"))
    return nothing
end

function _validate_settings_bindings(entries, profiles, defaults, settings_schema, graph_nodes)
    for entry_value in _declaration_array(entries, "settings_bindings")
        entry = _declaration_fields(entry_value,
            ("setting", "nodes", "config", "profiles", "transform", "coupling"),
            ("setting", "nodes"), "settings binding")
        _validate_setting_reference(entry["setting"], defaults, settings_schema, profiles,
            "settings binding setting")
        nodes = _declaration_array(entry["nodes"], "settings binding nodes"; nonempty=true)
        for node in nodes
            _declaration_text(node, "settings binding target")
            node in graph_nodes || throw(ArgumentError("settings binding targets absent graph node $node"))
        end
        length(Set(nodes)) == length(nodes) || throw(ArgumentError("settings binding repeats a target node"))
        if haskey(entry, "profiles")
            selected = _declaration_array(entry["profiles"], "settings binding profiles"; nonempty=true)
            for profile in selected
                _declaration_text(profile, "settings binding profile")
                haskey(profiles, profile) || throw(ArgumentError("settings binding references absent profile $profile"))
            end
            length(Set(selected)) == length(selected) || throw(ArgumentError("settings binding repeats a profile"))
        end
        if haskey(entry, "transform")
            _declaration_text(entry["transform"], "settings binding transform")
            entry["transform"] in ("identity", "gaussian_width") ||
                throw(ArgumentError("unknown settings binding transform $(entry["transform"])"))
            entry["transform"] == "identity" && haskey(entry, "coupling") &&
                throw(ArgumentError("identity transform does not accept coupling"))
            if entry["transform"] == "gaussian_width"
                haskey(entry, "coupling") && _valid_coupling(entry["coupling"]) ||
                    throw(ArgumentError("gaussian_width transform requires a finite coupling in (0,1)"))
            end
        elseif haskey(entry, "coupling")
            throw(ArgumentError("settings binding coupling requires gaussian_width transform"))
        end
    end
    return nothing
end

_valid_coupling(value::Real) = isfinite(value) && 0 < value < 1
_valid_coupling(::Bool) = false
_valid_coupling(value) = false

function _validate_setting_reference(path, defaults, settings_schema, profiles, label)
    _declaration_text(path, label)
    parts = split(path, '.')
    _path_exists(defaults, parts) && return nothing
    properties = get(settings_schema, "properties", Dict{String,Any}())
    _schema_path_exists(properties, parts) && return nothing
    for profile in values(profiles)
        properties = get(profile, "settings_schema", Dict{String,Any}())
        _schema_path_exists(properties, parts) && return nothing
    end
    throw(ArgumentError("$label references absent setting $path"))
end

function _path_exists(value::AbstractDict, parts)
    isempty(parts) && return true
    haskey(value, first(parts)) || return false
    return length(parts) == 1 || _path_exists(value[first(parts)], parts[2:end])
end
_path_exists(value, parts) = false

function _schema_path_exists(properties::AbstractDict, parts)
    isempty(parts) && return true
    haskey(properties, first(parts)) || return false
    length(parts) == 1 && return true
    schema = properties[first(parts)]
    InstrumentDefinition.object_value(schema) || return false
    return _schema_path_exists(get(schema, "properties", Dict{String,Any}()), parts[2:end])
end

function _validate_hil(value, graph_inputs, graph_outputs)
    hil = _declaration_fields(value, ("command_input", "frame_output"),
        ("command_input", "frame_output"), "HIL boundary")
    command_input = _declaration_text(hil["command_input"], "HIL command_input")
    frame_output = _declaration_text(hil["frame_output"], "HIL frame_output")
    all(command_input in graph_inputs[mode] for mode in keys(graph_inputs)) ||
        throw(ArgumentError("HIL command_input is absent from a declared graph"))
    all(frame_output in graph_outputs[mode] for mode in keys(graph_outputs)) ||
        throw(ArgumentError("HIL frame_output is absent from a declared graph"))
    return nothing
end

function _declaration_graph(path)
    graph = graph_file(path)
    InstrumentDefinition.object_value(graph) || throw(ArgumentError("declared graph must be an object"))
    nodes = _declaration_array(get(graph, "nodes", nothing), "graph nodes"; nonempty=true)
    inputs = _declaration_array(get(graph, "inputs", nothing), "graph inputs")
    outputs = _declaration_array(get(graph, "outputs", nothing), "graph outputs")
    node_names = _unique_names(nodes, "graph node", "name")
    input_names = _unique_names(inputs, "graph input", "name")
    output_names = _unique_names(outputs, "graph output", "name")
    return (; nodes=node_names, inputs=input_names, outputs=output_names)
end

function _unique_names(values, label, key)
    names = Set{String}()
    for value in values
        InstrumentDefinition.object_value(value) || throw(ArgumentError("$label must be an object"))
        name = _declaration_text(get(value, key, nothing), "$label $key")
        name in names && throw(ArgumentError("duplicate $label $name"))
        push!(names, name)
    end
    return names
end
