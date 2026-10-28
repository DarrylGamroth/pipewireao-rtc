"Read one bounded package-owned catalog entry without accepting an asset path."
function catalog_document(collection, template)
    collection in ("bases", "simulation") || throw(ArgumentError("unknown catalog collection"))
    InstrumentDefinition.nonempty_text(template) && occursin(r"^[a-z][a-z0-9_-]{0,63}$", template) ||
        throw(ArgumentError("invalid catalog template"))
    directory = normpath(joinpath(@__DIR__, "..", "..", "data", collection))
    path = joinpath(directory, template * ".yaml")
    isfile(path) || throw(ArgumentError("unknown $collection template $template"))
    dirname(realpath(path)) == realpath(directory) ||
        throw(ArgumentError("catalog template must remain inside the package"))
    document = Common.read_yaml(path; maximum=65536)
    InstrumentDefinition.bounded(document, Ref(16384))
    return document
end

"Resolve a shared scientific basis definition while retaining application units and limits."
function resolve_basis_definition(basis)
    _declaration_object(basis, "basis")
    InstrumentDefinition.bounded(basis)
    if !haskey(basis, "template")
        result = deepcopy(basis)
        InstrumentDefinition.basis_header(result, get(result, "units", nothing))
        validate_basis_definition(result["definition"])
        return result
    end
    required = ("id", "template", "name", "units", "coefficient_limit")
    fields(basis, (required..., "definition"), required, "basis template selection")
    entry = catalog_document("bases", basis["template"])
    fields(entry, ("normalization", "definition"),
        ("normalization", "definition"), "basis catalog entry")
    definition = entry["definition"]
    validate_basis_definition(definition)
    overrides = get(basis, "definition", Dict{String,Any}())
    kind = definition["kind"]
    allowed = kind == "zernike" ? ("modes",) : kind == "fourier" ? ("max_frequency",) : ()
    isempty(allowed) && throw(ArgumentError("unsupported shared basis kind $kind"))
    fields(overrides, allowed, (), "basis definition overrides")
    merge!(definition, deepcopy(overrides))
    result = Dict{String,Any}(key => deepcopy(basis[key]) for key in
        ("id", "name", "units", "coefficient_limit"))
    merge!(result, entry)
    InstrumentDefinition.basis_header(result, result["units"])
    validate_basis_definition(result["definition"])
    return deepcopy(result)
end

function validate_basis_definition(definition)
    _declaration_object(definition, "basis definition")
    kind = get(definition, "kind", nothing)
    if kind == "zernike"
        fields(definition, ("kind", "modes"), ("kind", "modes"), "Zernike definition")
        InstrumentDefinition.zernike_modes(definition["modes"])
    elseif kind == "fourier"
        fields(definition, ("kind", "max_frequency"), ("kind", "max_frequency"), "Fourier definition")
        cap = definition["max_frequency"]
        ispositive_integer(cap) && cap <= 64 || throw(ArgumentError("Fourier max_frequency must be in 1:64"))
    elseif kind == "sampled"
        fields(definition, ("kind", "artifact", "command_order", "names"),
            ("kind", "artifact", "command_order", "names"), "sampled definition")
        # File and mirror-dependent checks run in the ordinary shape-control validator.
        artifact = _declaration_fields(definition["artifact"], ("path", "hdu", "axes", "type", "shape"),
            ("path", "hdu", "axes", "type", "shape"), "sampled basis artifact")
        _declaration_text(artifact["path"], "sampled basis artifact path")
        ispositive_integer(artifact["hdu"]) || throw(ArgumentError("sampled basis hdu must be positive"))
        _validate_positive_shape(artifact["shape"], "sampled basis shape")
        length(artifact["shape"]) == 2 || throw(ArgumentError("sampled basis artifact must have rank 2"))
        _validate_axes(artifact["axes"], 2, "sampled basis axes")
        _validate_element_type(artifact["type"], "sampled basis")
        definition["command_order"] == "mirror" || throw(ArgumentError("sampled command_order must be mirror"))
        names = _declaration_array(definition["names"], "sampled mode names"; nonempty=true)
        length(names) == artifact["shape"][2] && length(names) <= 64 &&
            all(InstrumentDefinition.bounded_text, names) && length(unique(names)) == length(names) ||
            throw(ArgumentError("sampled modes require 1:64 unique names matching artifact columns"))
    else
        throw(ArgumentError("unknown basis kind $kind"))
    end
    return nothing
end

shared_settings_schema(::AbstractString) = true
shared_settings_schema(value::AbstractDict) = haskey(value, "template")
shared_settings_schema(value) = false

"Resolve a simulator settings schema from package data or an inline object schema."
resolve_settings_schema(template::AbstractString) = resolve_settings_schema(Dict("template" => template))
function resolve_settings_schema(selection::AbstractDict)
    InstrumentDefinition.bounded(selection)
    if !haskey(selection, "template")
        result = deepcopy(selection)
    else
        fields(selection, ("template", "title", "description", "properties"),
            ("template",), "settings schema template selection")
        result = catalog_document("simulation", selection["template"])
        for key in ("title", "description")
            haskey(selection, key) && (result[key] = deepcopy(selection[key]))
        end
        if haskey(selection, "properties")
            properties = _declaration_object(selection["properties"], "settings schema properties")
            merge!(result["properties"], deepcopy(properties))
        end
    end
    validate_settings_schema(result)
    get(result, "type", nothing) == "object" ||
        throw(ArgumentError("settings schema must declare object properties"))
    return deepcopy(result)
end
resolve_settings_schema(selection) = throw(ArgumentError("settings schema must be an object or template name"))

function validate_settings_schema(schema)
    _declaration_object(schema, "settings schema")
    if haskey(schema, "oneOf")
        fields(schema, ("oneOf", "readOnly", "title", "description"), ("oneOf",), "settings schema alternatives")
        haskey(schema, "readOnly") && !(schema["readOnly"] isa Bool) &&
            throw(ArgumentError("settings schema readOnly must be Boolean"))
        for key in ("title", "description")
            haskey(schema, key) && _declaration_text(schema[key], "settings schema $key")
        end
        alternatives = _declaration_array(schema["oneOf"], "settings schema alternatives"; nonempty=true)
        length(alternatives) <= 16 || throw(ArgumentError("settings schema allows at most 16 alternatives"))
        foreach(validate_settings_schema, alternatives)
        return nothing
    end
    common = ("\$schema", "type", "title", "description", "readOnly", "enum",
        "x-display-scale", "x-display-title")
    kind = get(schema, "type", nothing)
    specific = kind == "object" ? ("properties", "additionalProperties", "required") :
        kind == "array" ? ("items", "minItems", "maxItems", "uniqueItems") :
        kind in ("number", "integer") ? ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum") :
        kind == "string" ? ("minLength", "maxLength") : kind == "boolean" ? () :
        throw(ArgumentError("unsupported settings schema type $kind"))
    fields(schema, (common..., specific...), ("type",), "settings schema")
    for key in ("\$schema", "title", "description", "x-display-title")
        haskey(schema, key) && _declaration_text(schema[key], "settings schema $key")
    end
    for key in ("readOnly", "additionalProperties", "uniqueItems")
        haskey(schema, key) && !(schema[key] === true || schema[key] === false) &&
            throw(ArgumentError("settings schema $key must be Boolean"))
    end
    for key in ("minItems", "maxItems", "minLength", "maxLength")
        haskey(schema, key) && !isnonnegative_integer(schema[key]) &&
            throw(ArgumentError("settings schema $key must be a nonnegative integer"))
    end
    for key in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "x-display-scale")
        haskey(schema, key) && !isfinite_real(schema[key]) &&
            throw(ArgumentError("settings schema $key must be finite"))
    end
    haskey(schema, "enum") && _declaration_array(schema["enum"], "settings schema enum"; nonempty=true)
    if kind == "object"
        properties = _declaration_object(get(schema, "properties", nothing), "settings schema properties")
        for (name, property) in properties
            _declaration_text(name, "settings schema property name")
            validate_settings_schema(property)
        end
        if haskey(schema, "required")
            required = _declaration_array(schema["required"], "required settings")
            all(name -> haskey(properties, name), required) && length(unique(required)) == length(required) ||
                throw(ArgumentError("required settings must name unique declared properties"))
        end
    elseif kind == "array"
        haskey(schema, "items") || throw(ArgumentError("settings array schema requires items"))
        validate_settings_schema(schema["items"])
    end
    return nothing
end

# A profile schema is a property map, so a schema-valued property named
# "template" is ordinary application data rather than a catalog selector.
resolve_profile_settings_schema(selection::AbstractString) = resolve_settings_schema(selection)["properties"]
resolve_profile_settings_schema(selection::AbstractDict) = profile_schema(get(selection,"template",nothing),selection)
resolve_profile_settings_schema(selection) = throw(ArgumentError("profile settings schema must be a property map or template name"))
profile_schema(template::AbstractString,selection) = resolve_settings_schema(selection)["properties"]
profile_schema(template,selection) = deepcopy(selection)
