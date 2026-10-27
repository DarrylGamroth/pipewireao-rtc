"Validate physical instrument data without loading a simulation or controller."
function validate_declaration(document::AbstractDict, directory::AbstractString)
    required = ("schema_version", "id", "deformable_mirrors", "wavefront_sensors")
    fields(document, (required..., "telescope"), required, "physical instrument")
    document["schema_version"] === 1 || throw(ArgumentError("unsupported physical instrument schema"))
    _declaration_identifier(document["id"], "instrument identifier")
    haskey(document, "telescope") && _validate_telescope(document["telescope"])
    for key in ("deformable_mirrors", "wavefront_sensors")
        values = _declaration_object(document[key], key)
        1 <= length(values) <= 16 || throw(ArgumentError("instrument requires 1:16 $key"))
        for (name, value) in values
            _declaration_identifier(name, key)
            key == "deformable_mirrors" ? _validate_mirror_declaration(value, directory, name) :
                _validate_sensor_declaration(value, directory, name)
        end
    end
    return nothing
end
validate_declaration(document, directory) = throw(ArgumentError("physical instrument must be an object"))

function validate_simulation(document, instrument, directory, graphs)
    document["schema_version"] === 1 || throw(ArgumentError("unsupported simulation definition schema"))
    _declaration_identifier(document["id"], "simulation identifier")
    defaults = document["defaults"]
    settings_schema = document["settings_schema"]
    mirrors = instrument["deformable_mirrors"]
    sensors = instrument["wavefront_sensors"]
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
    for key in ("defaults", "profiles", "bindings", "sensors", "sources")
        _declaration_object(get(document,key,Dict()), "simulation $key")
    end
    for (name, response) in get(document,"sensors",Dict())
        haskey(sensors,name) || throw(ArgumentError("simulation response names an unknown sensor"))
        fields(response,("post_readout_gain", "diffraction_padding", "half_pixel_shift", "shannon_sampling",
            "threshold_convolution", "valid_subaperture_threshold"),("post_readout_gain",),"simulation sensor response")
        gain = response["post_readout_gain"]
        isfinite_positive(gain) && isfinite_positive(Float32(gain)) ||
            throw(ArgumentError("simulation post_readout_gain must be positive and finite in Float32"))
        haskey(response,"diffraction_padding") && !isfinite_positive(response["diffraction_padding"]) &&
            throw(ArgumentError("simulation diffraction_padding must be positive and finite"))
        for key in ("half_pixel_shift", "shannon_sampling")
            haskey(response,key) && !(response[key] === true || response[key] === false) &&
                throw(ArgumentError("simulation $key must be Boolean"))
        end
        for key in ("threshold_convolution", "valid_subaperture_threshold")
            haskey(response,key) && !isfinite_real(response[key]) && throw(ArgumentError("simulation $key must be finite"))
        end
    end
    for (name, source) in get(document,"sources",Dict())
        _declaration_identifier(name,"simulation source")
        names = ("source_band", "source_magnitude", "source_position_angle_deg",
            "source_separation_arcsec", "source_wavelength_m")
        fields(source,names,names,"simulation source")
        _declaration_text(source["source_band"],"source band")
        all(isfinite_real, (source["source_magnitude"],source["source_position_angle_deg"],
            source["source_separation_arcsec"])) &&
            isfinite_positive(source["source_wavelength_m"]) ||
            throw(ArgumentError("simulation source requires finite photometry and positive wavelength"))
    end

    validate_imaging(document)

    graph_paths = _declaration_fields(document["graphs"], ("production", "calibration"),
        ("production", "calibration"), "graphs")
    graph_nodes = Dict{String,Set{String}}()
    graph_inputs = Dict{String,Set{String}}()
    graph_outputs = Dict{String,Set{String}}()
    for mode in ("production", "calibration")
        graph = _declaration_graph(graphs[mode])
        for entry in graphs[mode]["nodes"]
            node_configuration_bindings(entry, bindings)
        end
        graph_nodes[mode] = graph.nodes
        graph_inputs[mode] = graph.inputs
        graph_outputs[mode] = graph.outputs
    end
    all_graph_nodes = union(values(graph_nodes)...)
    _validate_profiles(profiles, bindings, all_graph_nodes)
    _validate_bindings(bindings, mirrors, defaults, settings_schema, profiles, directory)
    _validate_settings_bindings(document["settings_bindings"], profiles, defaults,
        settings_schema, all_graph_nodes)
    _validate_hil(document["hil"], graph_inputs, graph_outputs)
    validate_responses(document, graph_inputs["production"])
    for contract in document["wire_contracts"]
        validate_boundary_contract(document["hil"]["command_input"],contract["command_schema"])
    end
    return nothing
end

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

# Expected controller dimensions belong to the RTC, not to an artifact file.
function _validate_dimensions(dimensions)
    _declaration_object(dimensions, "RTC dimensions")
    for (name, count) in dimensions
        _declaration_identifier(name, "dimension name")
        valid = name == "hidden_mode_count" ? isnonnegative_integer(count) : ispositive_integer(count)
        valid && count <= typemax(Int) ||
            throw(ArgumentError("RTC dimension $name must be a positive Int"))
    end
    return nothing
end

function _validate_mirror_declaration(spec, directory, name)
    mirror = _declaration_fields(spec,
        ("description", "pupil_registration", "pupil", "units", "command_scale_m"),
        ("description", "pupil_registration", "units", "command_scale_m"), "mirror $name")
    mirror_description_path(directory, mirror["description"])
    _pupil_registration(_instrument_seal(mirror["pupil_registration"]))
    haskey(mirror,"pupil") && InstrumentDefinition.validate_pupil(mirror["pupil"])
    _declaration_text(mirror["units"], "mirror units")
    isfinite_positive(mirror["command_scale_m"]) || throw(ArgumentError("mirror command_scale_m must be finite and positive"))
    return nothing
end

function _validate_limiter(value)
    limiter = _declaration_fields(value, ("kind", "lower", "upper"),
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
    return nothing
end

isfinite_real(value::Real) = isfinite(value)
isfinite_real(::Bool) = false
isfinite_real(value) = false

function _validate_shape_control(value, units, directory)
    shape = _declaration_fields(value,("bases","controlled_actuators"),("bases",),"shape_control")
    if haskey(shape,"controlled_actuators")
        selection = _declaration_fields(shape["controlled_actuators"],
            ("graph","bindings","active_to_full","pdm_to_vdm"),
            ("graph","bindings","active_to_full","pdm_to_vdm"),"controlled actuator selection")
        for key in ("graph","bindings")
            D.relative_asset(directory,_declaration_text(selection[key],"controlled actuator $key"))
        end
        for key in ("active_to_full","pdm_to_vdm")
            _declaration_identifier(selection[key],"controlled actuator parameter")
        end
    end
    bases = _declaration_array(shape["bases"],"bases")
    length(bases) <= 16 || throw(ArgumentError("shape_control requires at most 16 bases"))
    ids = Set{String}()
    for basis in bases
        definition = InstrumentDefinition.basis_header(basis,units)
        basis["id"] in ids && throw(ArgumentError("duplicate basis id"))
        push!(ids,basis["id"])
        kind = definition["kind"]
        validate_basis_definition(definition)
        if kind == "sampled"
            definition["command_order"] == "mirror" || throw(ArgumentError("sampled command_order must be mirror"))
            _validate_artifact(definition["artifact"],directory,"sampled basis artifact")
            shape = definition["artifact"]["shape"]
            length(shape) == 2 || throw(ArgumentError("sampled basis artifact must have rank 2"))
            names = _declaration_array(definition["names"],"sampled mode names";nonempty=true)
            length(names) == shape[2] && length(names) <= 64 && all(InstrumentDefinition.bounded_text,names) &&
                length(unique(names)) == length(names) || throw(ArgumentError("sampled modes require 1:64 unique names matching artifact columns"))
        end
    end
    return nothing
end

function _validate_sensor_declaration(spec, directory, name)
    sensor = _declaration_object(spec, "sensor $name")
    _validate_sensor_declaration(sensor_kind(sensor), sensor, directory, name)
    haskey(sensor, "acquisition") && _validate_acquisition(sensor["acquisition"])
    _declaration_text(sensor["expected_schema"], "sensor expected_schema")
    return nothing
end

sensor_kind(spec::AbstractDict) = sensor_kind(get(spec, "kind", "shack_hartmann"))
sensor_kind(kind::AbstractString) = kind == "shack_hartmann" ? Val(:shack_hartmann) :
    kind == "pyramid" ? Val(:pyramid) : throw(ArgumentError("unsupported sensor kind"))
sensor_kind(kind) = throw(ArgumentError("sensor kind must be shack_hartmann or pyramid"))

function _validate_sensor_declaration(::Val{:shack_hartmann}, spec, directory, name)
    sensor = _declaration_fields(spec,
        ("kind", "detector_shape", "subaperture_shape", "subaperture_origins", "expected_schema", "optical_prescription", "acquisition"),
        ("detector_shape", "subaperture_shape", "subaperture_origins", "expected_schema"),
        "sensor $name")
    _validate_positive_shape(sensor["detector_shape"], "sensor detector_shape")
    _validate_positive_shape(sensor["subaperture_shape"], "sensor subaperture_shape")
    haskey(sensor, "optical_prescription") && _validate_sensor_optics(sensor)
    _validate_artifact(sensor["subaperture_origins"], directory, "subaperture_origins")
    return nothing
end

function _validate_sensor_declaration(::Val{:pyramid}, spec, directory, name)
    required = ("kind", "detector_shape", "pupil_shape", "pupil_separation_pixels",
        "pupil_edge_pixels", "expected_schema")
    sensor = _declaration_fields(spec, (required..., "acquisition"), required, "sensor $name")
    pyramid_geometry(sensor)
    return nothing
end

function sensor_pixel_pair(value, label; positive=false)
    pair = _declaration_array(value, label)
    valid = positive ? ispositive_integer : isnonnegative_integer
    length(pair) == 2 && all(x -> valid(x) && x <= typemax(Int), pair) ||
        throw(ArgumentError("$label requires two $(positive ? "positive" : "nonnegative") Int [row,column] values"))
    return (Int(pair[1]), Int(pair[2]))
end

function pyramid_geometry(sensor)
    detector_shape = sensor_pixel_pair(sensor["detector_shape"], "sensor detector_shape"; positive=true)
    pupil_shape = sensor_pixel_pair(sensor["pupil_shape"], "sensor pupil_shape"; positive=true)
    separation = sensor_pixel_pair(sensor["pupil_separation_pixels"], "sensor pupil_separation_pixels")
    edge = sensor_pixel_pair(sensor["pupil_edge_pixels"], "sensor pupil_edge_pixels")
    # Subtract each extent before adding origins, so even Int-sized inputs
    # reject an overflowing or out-of-detector four-pupil arrangement.
    all(axis -> pupil_shape[axis] <= detector_shape[axis] &&
        edge[axis] <= detector_shape[axis] - pupil_shape[axis] &&
        pupil_shape[axis] <= detector_shape[axis] - pupil_shape[axis] - edge[axis] &&
        separation[axis] <= detector_shape[axis] - pupil_shape[axis] - edge[axis] - pupil_shape[axis], 1:2) ||
        throw(ArgumentError("pyramid pupil region lies outside the detector"))
    far = ntuple(axis -> edge[axis] + pupil_shape[axis] + separation[axis], 2)
    pupil_origins = ((edge[1], edge[2]), (far[1], edge[2]),
        (edge[1], far[2]), (far[1], far[2]))
    return (;detector_shape, pupil_shape, pupil_origins)
end

function _validate_acquisition(value)
    acquisition = _declaration_fields(value,
        ("roi_origin", "exposure_duration_s"),
        ("roi_origin", "exposure_duration_s"), "sensor acquisition")
    origin = acquisition["roi_origin"]
    InstrumentDefinition.array_value(origin) && length(origin) == 2 &&
        all(x -> isnonnegative_integer(x) && x <= typemax(Int32), origin) ||
        throw(ArgumentError("ROI origin requires two nonnegative Int32 [row,column] offsets"))
    for name in ("exposure_duration_s",)
        number = acquisition[name]
        isfinite_positive(number) && isfinite_positive(Float32(number)) ||
            throw(ArgumentError("sensor $name must be positive and finite in Float32"))
    end
    nanoseconds = acquisition["exposure_duration_s"] * 1e9
    isfinite(nanoseconds) && 1 <= nanoseconds < typemax(UInt64) ||
        throw(ArgumentError("sensor exposure must fit positive UInt64 nanoseconds"))
    return nothing
end

function _validate_telescope(value)
    telescope = _declaration_fields(value,
        ("telescope_diameter_m", "central_obstruction_ratio", "pupil_reflectivity", "aperture_revision"),
        ("telescope_diameter_m", "central_obstruction_ratio", "pupil_reflectivity", "aperture_revision"), "telescope")
    for key in ("telescope_diameter_m", "central_obstruction_ratio", "pupil_reflectivity")
        number = telescope[key]
        isfinite_real(number) && isfinite(Float32(number)) || throw(ArgumentError("invalid telescope $key"))
    end
    isfinite_positive(Float32(telescope["telescope_diameter_m"])) || throw(ArgumentError("invalid telescope diameter"))
    0 <= telescope["central_obstruction_ratio"] < 1 && Float32(telescope["central_obstruction_ratio"]) < 1 ||
        throw(ArgumentError("invalid central obstruction ratio"))
    0 < telescope["pupil_reflectivity"] <= 1 && Float32(telescope["pupil_reflectivity"]) > 0 ||
        throw(ArgumentError("invalid pupil reflectivity"))
    ispositive_integer(telescope["aperture_revision"]) || throw(ArgumentError("invalid aperture revision"))
    return nothing
end

function _validate_sensor_optics(sensor)
    # Explicit lenslet geometry is independent of the selected active-subaperture mask.
    optics = _declaration_fields(sensor["optical_prescription"],
        ("n_lenslets", "pixel_scale_arcsec"),
        ("n_lenslets",), "sensor optical_prescription")
    count = optics["n_lenslets"]
    ispositive_integer(count) || throw(ArgumentError("n_lenslets must be a positive integer"))
    detector, subaperture = sensor["detector_shape"], sensor["subaperture_shape"]
    length(detector) == length(subaperture) == 2 && detector[1] == detector[2] && subaperture[1] == subaperture[2] ||
        throw(ArgumentError("Shack-Hartmann optical prescription requires square detector and subapertures"))
    all(axis -> BigInt(count) * subaperture[axis] == detector[axis], 1:2) ||
        throw(ArgumentError("lenslet geometry differs from the declared detector shape"))
    haskey(optics,"pixel_scale_arcsec") && !isfinite_positive(optics["pixel_scale_arcsec"]) &&
        throw(ArgumentError("invalid sensor pixel_scale_arcsec"))
    return nothing
end

function _validate_artifact(value, directory, label)
    artifact = _declaration_fields(value, ("path", "hdu", "axes", "type", "shape"),
        ("path", "hdu", "axes", "type", "shape"), label)
    return _validate_artifact_values(artifact, directory, label)
end

function _validate_artifact_values(artifact, directory, label; check_file=true)
    path = artifact["path"]
    InstrumentDefinition.nonempty_text(path) && !occursin('\0', path) && !isabspath(path) ||
        throw(ArgumentError("$label path must be a relative filename"))
    relative = normpath(path)
    relative != ".." && !startswith(relative, ".." * string(Base.Filesystem.path_separator)) ||
        throw(ArgumentError("$label path escapes the instrument directory"))
    # Selected bindings repeat canonical path/file checks when materialized.
    # Other profiles need not have calibration files available on this host.
    check_file && D.relative_asset(directory, path)
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
            node = _declaration_fields(node_value, ("name", "type", "config", "props", "bindings"),
                ("name", "type", "config"), "profile $name node")
            node_name = _declaration_text(node["name"], "profile $name node name")
            node_name in node_names && throw(ArgumentError("profile $name repeats node $node_name"))
            node_name in graph_nodes || throw(ArgumentError("profile $name targets absent graph node $node_name"))
            push!(node_names, node_name)
            _declaration_text(node["type"], "profile $name node type")
            _declaration_object(node["config"], "profile $name node config")
            node_configuration_bindings(node, bindings)
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
        validate_command_contract(contract["command_schema"],contract["command_scale"])
    end
    return nothing
end

function validate_command_contract(schema::AbstractString,scale::Real)
    _declaration_text(schema,"wire contract command_schema")
    isfinite_positive(scale) && isfinite_positive(Float32(scale)) ||
        throw(ArgumentError("wire command_scale must be finite and positive in Float32"))
    return nothing
end
function validate_command_contract(schemas::AbstractDict,scales::AbstractDict)
    1 <= length(schemas) <= 16 && Set(keys(schemas)) == Set(keys(scales)) ||
        throw(ArgumentError("wire command schema/scale maps require the same 1:16 names"))
    for name in keys(schemas)
        _declaration_identifier(name,"wire command name")
        validate_command_contract(_declaration_text(schemas[name],"wire command schema"),scales[name])
    end
    return nothing
end
validate_command_contract(schemas,scales) = throw(ArgumentError("wire commands require scalar or matching named schema/scale maps"))

validate_boundary_contract(::AbstractString,::AbstractString) = nothing
function validate_boundary_contract(names::AbstractVector,schemas::AbstractDict)
    Set(names) == Set(keys(schemas)) || throw(ArgumentError("wire command names differ from the HIL boundary"))
    return nothing
end
validate_boundary_contract(names,schemas) = throw(ArgumentError("wire command contracts must match the scalar or named HIL boundary"))

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
        elseif kind in ("pupil_coordinates", "pupil_support")
            binding = _declaration_fields(binding_value, ("kind", "resolution"),
                ("kind", "resolution"), "pupil binding $name")
            _valid_zero_extent(binding["resolution"], defaults, settings_schema, profiles) ||
                throw(ArgumentError("pupil binding resolution must be a positive extent or existing setting"))
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
            _validate_artifact_values(binding, directory, "FITS binding $name"; check_file=false)
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
function _valid_zero_extent(value::AbstractDict, defaults, settings_schema, profiles)
    Set(keys(value)) == Set(("\$ref",)) && value["\$ref"] isa AbstractString &&
        startswith(value["\$ref"], "/") || throw(ArgumentError("invalid zero binding reference"))
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
            ("setting", "value", "nodes", "config", "profiles", "transform", "coupling"),
            ("nodes",), "settings binding")
        haskey(entry,"setting") != haskey(entry,"value") ||
            throw(ArgumentError("settings binding requires exactly one setting or value"))
        haskey(entry,"setting") && _validate_setting_reference(entry["setting"], defaults, settings_schema, profiles,
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
            entry["transform"] in ("identity", "reciprocal", "gaussian_width") ||
                throw(ArgumentError("unknown settings binding transform $(entry["transform"])"))
            entry["transform"] != "gaussian_width" && haskey(entry, "coupling") &&
                throw(ArgumentError("settings binding coupling requires gaussian_width transform"))
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
    command_inputs = hil_command_endpoints(hil["command_input"])
    foreach(name -> _declaration_identifier(name,"HIL command_input"),command_inputs)
    frame_output = _declaration_text(hil["frame_output"], "HIL frame_output")
    all(name in graph_inputs[mode] for name in command_inputs for mode in keys(graph_inputs)) ||
        throw(ArgumentError("HIL command_input is absent from a declared graph"))
    all(frame_output in graph_outputs[mode] for mode in keys(graph_outputs)) ||
        throw(ArgumentError("HIL frame_output is absent from a declared graph"))
    return nothing
end

"Validate explicit construction binding roles without loading science packages or arrays."
function node_configuration_bindings(entry, specs)
    bindings = _declaration_object(get(entry, "bindings", Dict()), "node bindings")
    config = _declaration_object(get(entry, "config", Dict()), "node config")
    for (role, name) in bindings
        _declaration_identifier(role, "node binding role")
        _declaration_identifier(name, "node binding name")
        haskey(config, role) && throw(ArgumentError("node binding role duplicates a config field: $role"))
        haskey(specs, name) || throw(ArgumentError("node names an undeclared array binding: $name"))
    end
    return bindings
end

_declaration_graph(path::AbstractString) = _declaration_graph(bounded_yaml(path))
function _declaration_graph(graph)
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

# Imaging reuses the composed pupil OPD; a separate atmospheric line of sight
# requires a separately rendered graph output, not a new observer setting.
function validate_imaging(document)
    haskey(document, "imaging") || return nothing
    imaging = fields(document["imaging"], ("source", "zero_padding"), ("source",), "simulation imaging")
    source = _declaration_identifier(imaging["source"], "imaging source")
    haskey(get(document, "sources", Dict()), source) ||
        throw(ArgumentError("imaging references absent source $source"))
    padding = get(imaging, "zero_padding", 2)
    padding isa Integer && !(padding isa Bool) && 1 <= padding <= 16 ||
        throw(ArgumentError("imaging zero_padding must be an integer in 1:16"))
    return nothing
end
