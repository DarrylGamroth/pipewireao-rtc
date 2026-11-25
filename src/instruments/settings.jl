settings_mismatch(error::ArgumentError) = false
settings_mismatch(error) = rethrow()

"""
    json_value(value)

Convert typed metadata to the representation used by the JSON configuration contracts.
"""
json_value(@nospecialize(value)) = Common.parse_json(String(Common.metadata_json(value)))

"""
    merge_settings(base, overrides, schema)

Apply settings overrides using the declared schema and its replacement rules.
"""
function merge_settings(
    defaults::AbstractDict, overrides::AbstractDict, schema::AbstractDict
)
    result = deepcopy(defaults)
    for (key, value) in overrides
        haskey(schema["properties"], key) ||
            throw(ArgumentError("unknown simulator setting $key"))
        result[key] = merge_setting(
            get(defaults, key, nothing), value, schema["properties"][key]
        )
    end
    return result
end

merge_setting(default, value, schema) = deepcopy(value)
merge_setting(default::AbstractDict, value::AbstractDict, schema) =
    haskey(schema, "oneOf") ? deepcopy(value) : merge_settings(default, value, schema)

function matching_settings_branches(alternatives, value)
    return findall(alternatives) do branch
        try
            validate_settings(branch, value, value)
            true
        catch error
            settings_mismatch(error)
        end
    end
end

function contains_readonly_setting(schema, value)
    get(schema, "readOnly", false) && return true
    if haskey(schema, "oneOf")
        return any(schema["oneOf"]) do branch
            matches = try
                validate_settings(branch, value, value)
                true
            catch error
                settings_mismatch(error)
            end
            matches && contains_readonly_setting(branch, value)
        end
    elseif get(schema, "type", nothing) == "object"
        return contains_readonly_object(schema, value)
    elseif get(schema, "type", nothing) == "array"
        return contains_readonly_array(schema, value)
    end
    return false
end

contains_readonly_object(schema, value) = false
contains_readonly_object(schema, value::AbstractDict) =
    any(get(schema, "properties", Dict())) do (key, property)
        haskey(value, key) && contains_readonly_setting(property, value[key])
    end
contains_readonly_array(schema, value) = false
contains_readonly_array(schema, value::AbstractVector) =
    any(item -> contains_readonly_setting(schema["items"], item), value)

"Enforce the declared editable shape; physical validation remains with the plant."
validate_settings(schema, proposed, current; path = "settings", readonly = false) =
    throw(ArgumentError("invalid settings schema"))
function validate_settings(
    schema::AbstractDict, proposed, current; path = "settings", readonly = false
)
    readonly |= get(schema, "readOnly", false) === true
    readonly &&
        proposed != current &&
        throw(ArgumentError("$path requires a separate calibration/deployment change"))
    if haskey(schema, "oneOf")
        alternatives = schema["oneOf"]
        before = matching_settings_branches(alternatives, current)
        after = matching_settings_branches(alternatives, proposed)
        if length(before) == length(after) == 1 && only(before) != only(after)
            (
                contains_readonly_setting(alternatives[only(before)], current) ||
                contains_readonly_setting(alternatives[only(after)], proposed)
            ) && throw(
                ArgumentError("$path requires a separate calibration/deployment change")
            )
        end
        matches = count(schema["oneOf"]) do branch
            try
                validate_settings(branch, proposed, current; path, readonly)
                true
            catch error
                settings_mismatch(error)
            end
        end
        matches == 1 ||
            throw(ArgumentError("$path must match exactly one settings schema alternative"))
        return nothing
    end
    kind = get(schema, "type", nothing)
    if kind == "object"
        validate_object_settings(schema, proposed, current, path, readonly)
    elseif kind == "array"
        validate_array_settings(schema, proposed, current, path, readonly)
    elseif kind in ("number", "integer")
        validate_number_setting(proposed, path)
        kind == "integer" && validate_integer_setting(proposed, path)
        for (key, compare) in (
            ("minimum", >=),
            ("maximum", <=),
            ("exclusiveMinimum", >),
            ("exclusiveMaximum", <),
        )
            haskey(schema, key) &&
                !compare(proposed, schema[key]) &&
                throw(ArgumentError("$path violates $key"))
        end
    elseif kind == "string"
        validate_string_setting(proposed, path)
    elseif kind == "boolean"
        validate_boolean_setting(proposed, path)
    else
        throw(ArgumentError("unsupported settings schema type $kind"))
    end
    haskey(schema, "enum") &&
        proposed ∉ schema["enum"] &&
        throw(ArgumentError("$path is not an admitted value"))
    return nothing
end

validate_object_settings(schema, proposed, current, path, readonly) =
    throw(ArgumentError("$path must be an object"))
function validate_object_settings(
    schema, proposed::AbstractDict, current::AbstractDict, path, readonly
)
    properties = get(schema, "properties", Dict())
    required = get(schema, "required", collect(keys(properties)))
    all(key -> haskey(properties, key), keys(proposed)) &&
    all(key -> haskey(proposed, key), required) ||
        throw(ArgumentError("$path must contain the required declared settings"))
    for (key, property) in properties
        if haskey(proposed, key) != haskey(current, key)
            value = haskey(proposed, key) ? proposed[key] : current[key]
            contains_readonly_setting(property, value) && throw(
                ArgumentError(
                    "$path.$key requires a separate calibration/deployment change"
                ),
            )
        end
    end
    for key in keys(proposed)
        validate_settings(
            properties[key],
            proposed[key],
            get(current, key, proposed[key]);
            path = "$path.$key",
            readonly,
        )
    end
    return nothing
end
validate_array_settings(schema, proposed, current, path, readonly) =
    throw(ArgumentError("$path must be an array"))
function validate_array_settings(
    schema, proposed::AbstractVector, current::AbstractVector, path, readonly
)
    max_items = get(schema, "maxItems", readonly ? 4096 : 256)
    max_items = settings_max_items(max_items, path)
    limit = readonly ? max_items : min(max_items, 256)
    length(proposed) <= limit || throw(ArgumentError("$path exceeds $limit values"))
    length(proposed) >= get(schema, "minItems", 0) ||
        throw(ArgumentError("$path has too few values"))
    length(proposed) <= max_items || throw(ArgumentError("$path has too many values"))
    get(schema, "uniqueItems", false) &&
        length(unique(proposed)) != length(proposed) &&
        throw(ArgumentError("$path requires unique values"))
    for (index, value) in enumerate(proposed)
        base = index <= length(current) ? current[index] : value
        validate_settings(schema["items"], value, base; path = "$path[$index]", readonly)
    end
    return nothing
end
settings_max_items(value, path) =
    throw(ArgumentError("$path has an invalid maxItems limit"))
settings_max_items(value::Bool, path) = settings_max_items(nothing, path)
settings_max_items(value::Integer, path) =
    0 <= value <= 4096 ? value : settings_max_items(nothing, path)
validate_number_setting(value, path) = throw(ArgumentError("$path must be a finite number"))
validate_number_setting(value::Bool, path) = validate_number_setting(nothing, path)
validate_number_setting(value::Real, path) =
    isfinite(value) ? nothing : validate_number_setting(nothing, path)
validate_integer_setting(value, path) = throw(ArgumentError("$path must be an integer"))
validate_integer_setting(value::Integer, path) = nothing
validate_string_setting(value, path) =
    throw(ArgumentError("$path must be a bounded string"))
function validate_string_setting(value::AbstractString, path)
    !occursin('\0', value) && ncodeunits(value) <= 16 * 1024 ||
        return validate_string_setting(nothing, path)
    return nothing
end
validate_boolean_setting(value, path) = throw(ArgumentError("$path must be Boolean"))
validate_boolean_setting(value::Bool, path) = nothing
