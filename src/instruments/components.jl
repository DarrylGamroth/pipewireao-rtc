# Cold, bounded reuse of existing AOS node declarations. Templates contain only
# references and AOS type/config names; instrument values and topology stay data.
const COMPONENT_TEMPLATES = ("coordinate_gaussian", "grid_gaussian", "measured",
    "multilayer_atmosphere_opd_f32", "pupil_opd_composition_f32",
    "shack_hartmann_rate_f32", "pyramid", "cmos", "emccd", "ingaas", "hgcdte_linear_avalanche_array",
    "pixel_mtf", "proper_optical_train_f64", "proper_optical_train_f32")
const MIRROR_PROFILES = ("coordinate_gaussian", "grid_gaussian", "measured")
const PREPARED_OPTICAL_CONFIG = ("resolution", "pupil_resolution", "diameter_m", "wavelength_um", "temperature_c")
const OPTIONAL_OPTICAL_CONFIG = ("pupil_opd_schema", "pupil_amplitude_schema", "output_schema", "output_sampling_m", "phase_screens", "pupil_grid", "output_quantity")

function component_preparation(selection, instrument, directory)
    haskey(selection, "preparation") || return nothing
    selection["template"] in ("proper_optical_train_f32", "proper_optical_train_f64") ||
        throw(ArgumentError("Zemax component preparation requires a PROPER optical train template"))
    preparation = fields(selection["preparation"], ("kind", "recipe", "branch"),
        ("kind", "recipe", "branch"), "component preparation")
    preparation["kind"] == "zemax" || throw(ArgumentError("unsupported component preparation kind"))
    get(get(instrument, "optical_prescription", Dict()), "format", nothing) == "zemax" ||
        throw(ArgumentError("Zemax component requires a physical Zemax optical prescription"))
    _declaration_identifier(preparation["branch"], "Zemax component branch")
    recipe = _declaration_text(preparation["recipe"], "component preparation recipe")
    !isabspath(recipe) && normpath(recipe) == recipe && !occursin('\0', recipe) &&
        all(part -> !(part in (".", "..", "generated")), splitpath(recipe)) ||
        throw(ArgumentError("component preparation recipe must be a normalized authored path inside the instrument"))
    isfile(joinpath(directory, recipe)) || throw(ArgumentError("component preparation recipe must be an existing file"))
    resolved = D.relative_asset(directory, recipe)
    "generated" in splitpath(relpath(resolved, realpath(directory))) &&
        throw(ArgumentError("component preparation recipe must be authored outside generated"))
    prepared_component_config(selection["config"])
    return preparation
end

function prepared_component_config(config)
    fields(config, (PREPARED_OPTICAL_CONFIG..., OPTIONAL_OPTICAL_CONFIG...), PREPARED_OPTICAL_CONFIG,
        "prepared optical component config")
    return config
end

function component_template_path(name)
    name in COMPONENT_TEMPLATES || throw(ArgumentError("unknown simulation component template $name"))
    directory = joinpath(@__DIR__, "..", "..", "data", "simulation", "components")
    path = joinpath(directory, name * ".yaml")
    dirname(realpath(path)) == realpath(directory) ||
        throw(ArgumentError("component template escapes the package catalog"))
    return path
end

function component_template(name, templates)
    path = component_template_path(name)
    push!(templates, name)
    result = Common.read_yaml(path; maximum=65536)
    InstrumentDefinition.bounded(result, Ref(16384))
    fields(result, ("type", "detector", "config", "optional_config", "binding_roles"), ("type", "config"), "AOS component template")
    _declaration_text(result["type"], "AOS component type")
    haskey(result, "detector") && _declaration_text(result["detector"], "AOS detector model")
    _declaration_object(result["config"], "AOS component config")
    _declaration_object(get(result, "optional_config", Dict()), "AOS optional component config")
    return result
end

pointer_key(name) = replace(replace(name, "~" => "~0"), "/" => "~1")
reference(pointer) = Dict("\$ref" => pointer)

function component_reference(value::AbstractDict, selection)
    if haskey(value, "\$ref")
        pointer = Common.configuration_reference_pointer(value)
        for (prefix, key, base) in (("/mirror/", "mirror", "/instrument/deformable_mirrors/"),
                ("/sensor/", "sensor", "/instrument/wavefront_sensors/"),
                ("/response/", "sensor", "/simulation/sensors/"),
                ("/source/", "source", "/simulation/sources/"))
            startswith(pointer, prefix) || continue
            haskey(selection, key) || throw(ArgumentError("component template requires $key"))
            return reference(base * pointer_key(selection[key]) * "/" * pointer[length(prefix)+1:end])
        end
        if startswith(pointer, "/schemas/") || startswith(pointer, "/values/")
            key = last(split(pointer, '/'))
            config = get(selection, "config", Dict())
            haskey(config, key) || throw(ArgumentError("component requires explicit config.$key"))
            return deepcopy(config[key])
        end
        return deepcopy(value)
    end
    return Dict(key => component_reference(item, selection) for (key, item) in value)
end
component_reference(value::AbstractVector, selection) = [component_reference(item, selection) for item in value]
component_reference(value, selection) = deepcopy(value)

function validate_component(selection, instrument, document)
    fields(selection, ("template", "mirror", "sensor", "source", "coupling", "bindings", "influence_functions", "config", "props", "preparation"),
        ("template", "config"), "simulation component selection")
    _declaration_object(selection["config"], "component config")
    template = selection["template"]
    _declaration_text(template, "component template")
    if template == "deformable_mirror"
        haskey(selection, "mirror") || throw(ArgumentError("deformable mirror component requires mirror"))
        haskey(selection, "coupling") && !_valid_coupling(selection["coupling"]) &&
            throw(ArgumentError("Gaussian mirror coupling must be finite and in (0,1)"))
        aliases = get(selection, "bindings", Dict())
        fields(aliases, ("actuator_coordinates", "actuator_grid_indices", "influence_functions"), (), "mirror bindings")
        all(InstrumentDefinition.identifier, values(aliases)) || throw(ArgumentError("invalid mirror binding name"))
        if haskey(selection, "influence_functions")
            path = _declaration_text(selection["influence_functions"], "influence function setting")
            all(part -> InstrumentDefinition.identifier(String(part)), split(path, '.')) || throw(ArgumentError("invalid influence function setting path"))
        end
    else
        template in COMPONENT_TEMPLATES && !(template in MIRROR_PROFILES) ||
            throw(ArgumentError("unknown simulation component template $template"))
        any(key -> haskey(selection, key), ("mirror", "coupling", "influence_functions")) &&
            throw(ArgumentError("mirror fields require a deformable mirror component"))
        haskey(selection, "bindings") && template != "pixel_mtf" &&
            throw(ArgumentError("component bindings require a pixel MTF or deformable mirror component"))
    end
    for (key, collection) in (("mirror", instrument["deformable_mirrors"]),
            ("sensor", instrument["wavefront_sensors"]), ("source", get(document, "sources", Dict())))
        haskey(selection, key) || continue
        name = _declaration_text(selection[key], "component $key")
        haskey(collection, name) || throw(ArgumentError("component references absent $key $name"))
    end
    if template == "pyramid"
        haskey(selection, "sensor") || throw(ArgumentError("Pyramid component requires sensor"))
        sensor = instrument["wavefront_sensors"][selection["sensor"]]
        get(sensor, "kind", nothing) == "pyramid" || throw(ArgumentError("Pyramid component requires a pyramid sensor"))
        for key in ("pupil_shape", "pupil_separation_pixels", "pupil_edge_pixels")
            pair = sensor_pixel_pair(sensor[key], "Pyramid $key"; positive=key == "pupil_shape")
            pair[1] == pair[2] || throw(ArgumentError("Pyramid optical component requires equal row and column $key"))
        end
    end
    haskey(selection, "props") && _declaration_object(selection["props"], "component props")
    return nothing
end

function component_input(value::AbstractDict)
    haskey(value, "\$ref") || return false
    pointer = Common.configuration_reference_pointer(value)
    return startswith(pointer, "/schemas/") || startswith(pointer, "/values/")
end
component_input(value) = false
component_config_fields(template) = union(Set(key for (key, value) in template["config"] if component_input(value)),
    Set(keys(get(template, "optional_config", Dict()))))

function component_node(name, selection, model, templates)
    template = component_template(model, templates)
    prepared = haskey(selection, "preparation")
    config = if prepared
        deepcopy(prepared_component_config(selection["config"]))
    else
        result = component_reference(template["config"], selection)
        for (key, value) in get(template, "optional_config", Dict())
            haskey(selection["config"], key) && (result[key] = component_reference(value, selection))
        end
        result
    end
    # Only explicit scientific values and schema inputs belong to application
    # config. Physical geometry and settings references remain template-owned.
    if !prepared && selection["template"] != "deformable_mirror"
        unknown = setdiff(keys(selection["config"]), component_config_fields(template))
        isempty(unknown) || throw(ArgumentError("unknown component config fields: $(join(unknown, ", "))"))
    end
    node = Dict{String,Any}("name" => name, "type" => template["type"], "config" => config)
    prepared && (node["preparation"] = deepcopy(selection["preparation"]))
    haskey(template, "detector") && (node["detector"] = template["detector"])
    if haskey(template, "binding_roles")
        bindings = _declaration_object(get(selection, "bindings", Dict()), "component bindings")
        Set(keys(bindings)) == Set(template["binding_roles"]) ||
            throw(ArgumentError("component requires explicit construction bindings $(template["binding_roles"])"))
        node["bindings"] = deepcopy(bindings)
    end
    haskey(selection, "props") && (node["props"] = deepcopy(selection["props"]))
    return node
end

component_binding(name, selection, port) = get(get(selection, "bindings", Dict()), port, name * "_" * port)
function add_component_binding!(bindings, name, value)
    if haskey(bindings, name)
        bindings[name] == value || throw(ArgumentError("conflicting simulation binding $name"))
    else
        bindings[name] = value
    end
    return name
end

function mirror_parameters!(bindings, name, selection, model)
    mirror = selection["mirror"]
    ports = model == "grid_gaussian" ? ("actuator_grid_indices",) : model == "measured" ?
        ("actuator_coordinates", "influence_functions") : ("actuator_coordinates",)
    return map(collect(ports)) do port
        kind = port == "actuator_coordinates" ? "mirror_coordinates" : port == "actuator_grid_indices" ?
            "mirror_grid_indices" : "measured_influences"
        spec = Dict{String,Any}("kind" => kind, "mirror" => mirror)
        port == "influence_functions" && (spec["setting"] = get(selection, "influence_functions", "influence_functions"))
        alias = add_component_binding!(bindings, component_binding(name, selection, port), spec)
        return Dict("binding" => alias, "destination" => name * "." * port)
    end
end

function expand_wire_contracts(value::AbstractDict)
    fields(value, ("frames", "commands", "additional"), ("frames", "commands"), "wire contract combinations")
    frames = _declaration_array(value["frames"], "wire frames"; nonempty=true)
    commands = _declaration_array(value["commands"], "wire commands"; nonempty=true)
    extra = _declaration_array(get(value, "additional", []), "additional wire contracts")
    length(frames) * length(commands) + length(extra) <= 64 || throw(ArgumentError("wire contracts exceed 64 pairs"))
    for frame in frames
        fields(frame, ("frame_encoding", "frame_schema"), ("frame_encoding", "frame_schema"), "wire frame")
    end
    for command in commands
        fields(command, ("command_schema", "command_scale"), ("command_schema", "command_scale"), "wire command")
    end
    return vcat([merge(deepcopy(frame), deepcopy(command)) for frame in frames for command in commands], deepcopy(extra))
end
expand_wire_contracts(value) = value

function simulation_graph_source(directory, source::AbstractString)
    return bounded_yaml(D.relative_asset(directory, source))
end
simulation_graph_source(directory, source::AbstractDict) = deepcopy(source)
simulation_graph_source(directory, source) = throw(ArgumentError("graph source must be a relative filename or an AOS graph object"))

function expand_simulation_components!(document, instrument, directory)
    templates = Set{String}()
    components = _declaration_object(get(document, "components", Dict()), "simulation components")
    length(components) <= 64 || throw(ArgumentError("simulation components exceed 64 entries"))
    for (name, selection) in components
        _declaration_identifier(name, "component name")
        validate_component(selection, instrument, document)
        component_preparation(selection, instrument, directory)
    end
    bindings = _declaration_object(get!(document, "bindings", Dict{String,Any}()), "simulation bindings")
    settings_bindings = _declaration_array(get!(document, "settings_bindings", Any[]), "settings_bindings")
    _declaration_object(document["defaults"], "simulation defaults")
    profiles = _declaration_object(document["profiles"], "simulation profiles")
    1 <= length(profiles) <= 16 || throw(ArgumentError("simulation requires 1:16 profiles"))
    graph_sources = simulation_graph_sources(document)
    profile_models = Dict(name => get(_declaration_object(profile, "simulation profile"), "template", nothing)
        for (name, profile) in profiles)
    mirror_components = Dict(name => selection for (name, selection) in components if selection["template"] == "deformable_mirror")
    for (profile_name, profile) in profiles
        haskey(profile, "template") || continue
        fields(profile, ("template", "settings_schema"), ("template",), "mirror profile selection")
        model = profile["template"]
        model in MIRROR_PROFILES || throw(ArgumentError("unknown mirror profile template $model"))
        nodes, parameters = Any[], Any[]
        for name in sort!(collect(keys(mirror_components)))
            selection = mirror_components[name]
            model != "measured" && !haskey(selection, "coupling") &&
                throw(ArgumentError("Gaussian mirror component requires coupling"))
            push!(nodes, component_node(name, selection, model, templates))
            append!(parameters, mirror_parameters!(bindings, name, selection, model))
        end
        isempty(nodes) && throw(ArgumentError("mirror profile requires a deformable mirror component"))
        delete!(profile, "template")
        profile["nodes"], profile["parameters"] = nodes, parameters
        if model == "measured"
            schema = haskey(profile, "settings_schema") ? resolve_profile_settings_schema(profile["settings_schema"]) : Dict{String,Any}()
            influence = resolve_profile_settings_schema("measured_influences")["influence_functions"]
            for selection in values(mirror_components)
                path = split(get(selection, "influence_functions", "influence_functions"), '.')
                properties = schema
                for key in path[1:end-1]
                    field = get!(properties, key, Dict("type" => "object", "properties" => Dict{String,Any}()))
                    get(field, "type", nothing) == "object" || throw(ArgumentError("influence setting traverses a non-object schema"))
                    properties = get!(field, "properties", Dict{String,Any}())
                end
                get!(properties, last(path), deepcopy(influence))
            end
            profile["settings_schema"] = schema
        end
    end
    gaussian_profiles = sort!([name for (name, model) in profile_models if model in ("grid_gaussian", "coordinate_gaussian")])
    if !isempty(gaussian_profiles)
        for (name, selection) in mirror_components
            push!(settings_bindings, Dict("value" => reference("/instrument/deformable_mirrors/" *
                pointer_key(selection["mirror"]) * "/pupil_registration/actuator_pitch_pupil_radius"),
                "config" => "influence_width", "coupling" => selection["coupling"], "nodes" => [name],
                "profiles" => gaussian_profiles, "transform" => "gaussian_width"))
        end
    end
    # Validate all mirror fields against the union of their adopted AOS types.
    for selection in values(mirror_components)
        allowed = Set{String}()
        for model in MIRROR_PROFILES
            union!(allowed, component_config_fields(component_template(model, templates)))
        end
        isempty(setdiff(keys(selection["config"]), allowed)) || throw(ArgumentError("unknown mirror component config field"))
    end
    graphs = Dict{String,Any}()
    references = Dict(name => 0 for name in keys(components))
    for (mode, source) in graph_sources
        graph = simulation_graph_source(directory, source)
        _declaration_graph(graph)
        for (index, node) in enumerate(graph["nodes"])
            name = node["name"]
            if !haskey(node, "type")
                fields(node, ("name", "config", "props"), ("name",), "component node reference")
                haskey(components, name) || throw(ArgumentError("graph references absent component $name"))
                selection = components[name]
                if selection["template"] == "deformable_mirror" &&
                        (haskey(node, "config") || haskey(node, "props"))
                    throw(ArgumentError("mirror graph nodes cannot override component/profile config or props"))
                end
                model = selection["template"]
                expanded = if model == "deformable_mirror"
                    selected_profile = get(document["defaults"], "profile", nothing)
                    haskey(profiles, selected_profile) || throw(ArgumentError("component graph requires a declared default profile"))
                    replacements = [node for node in get(profiles[selected_profile], "nodes", []) if node["name"] == name]
                    length(replacements) == 1 || throw(ArgumentError("mirror component requires one explicit or templated profile node $name"))
                    deepcopy(only(replacements))
                else
                    component_node(name, selection, model, templates)
                end
                if haskey(node, "config")
                    overrides = _declaration_object(node["config"], "component node config overrides")
                    allowed = haskey(selection, "preparation") ? Set((PREPARED_OPTICAL_CONFIG..., OPTIONAL_OPTICAL_CONFIG...)) :
                        component_config_fields(component_template(model, templates))
                    isempty(setdiff(keys(overrides), allowed)) ||
                        throw(ArgumentError("unknown component node config override"))
                    merge!(expanded["config"], deepcopy(overrides))
                end
                haskey(node, "props") && (expanded["props"] = deepcopy(node["props"]))
                graph["nodes"][index] = expanded
                references[name] += 1
            end
        end
        # Only known physical port contracts supply shared zero initial storage.
        # No connection or physical mapping is derived from an array's shape.
        for input in graph["inputs"]
            haskey(bindings, input["binding"]) && continue
            endpoint = split(input["destination"], '.')
            length(endpoint) == 2 || throw(ArgumentError("invalid graph input destination"))
            name, port = endpoint
            shape = if haskey(mirror_components, name) && port == "pdm_command"
                [reference("/instrument/deformable_mirrors/" * pointer_key(mirror_components[name]["mirror"]) * "/actuator_count")]
            elseif haskey(components, name) && components[name]["template"] == "pupil_opd_composition_f32" && port == "uncompensated_opd"
                resolution = only(node for node in graph["nodes"] if node["name"] == name)["config"]["resolution"]
                [deepcopy(resolution), deepcopy(resolution)]
            else
                throw(ArgumentError("graph input requires explicit binding $(input["binding"])"))
            end
            add_component_binding!(bindings, input["binding"], Dict("kind" => "zeros", "shape" => shape, "type" => "Float32"))
        end
        graphs[mode] = graph
    end
    all(>(0), values(references)) || throw(ArgumentError("simulation declares an unused component"))
    haskey(document, "wire_contracts") &&
        (document["wire_contracts"] = expand_wire_contracts(document["wire_contracts"]))
    hil = get(document, "hil", Dict())
    if haskey(hil, "command") || haskey(hil, "frame")
        fields(hil, ("command", "frame"), ("command", "frame"), "HIL endpoints")
        inputs, outputs = Vector{String}[], Set{String}()
        for graph in values(graphs)
            endpoints = hil_command_endpoints(hil["command"])
            commands = map(endpoints) do endpoint
                matches = [entry["name"] for entry in graph["inputs"] if entry["destination"] == endpoint]
                length(matches) == 1 || throw(ArgumentError("HIL command endpoint must name exactly one graph input"))
                only(matches)
            end
            frames = [entry["name"] for entry in graph["outputs"] if entry["source"] == hil["frame"]]
            length(frames) == 1 || throw(ArgumentError("HIL frame endpoint must name exactly one graph output"))
            push!(inputs, collect(commands)); push!(outputs, only(frames))
        end
        all(==(first(inputs)), inputs) && length(outputs) == 1 || throw(ArgumentError("HIL boundary names differ across graphs"))
        commands = first(inputs)
        document["hil"] = Dict("command_input" => hil_command_selection(hil["command"], commands), "frame_output" => only(outputs))
    end
    return (;graphs, templates=Tuple(sort!(collect(templates))))
end

hil_command_endpoints(value::AbstractString) = (value,)
function hil_command_endpoints(value::AbstractVector)
    1 <= length(value) <= 16 && all(InstrumentDefinition.nonempty_text, value) &&
        length(unique(value)) == length(value) || throw(ArgumentError("HIL commands require 1:16 unique endpoints"))
    return value
end
hil_command_endpoints(value) = throw(ArgumentError("HIL command must be an endpoint or endpoint array"))
hil_command_selection(::AbstractString, names) = only(names)
hil_command_selection(::AbstractVector, names) = collect(names)
