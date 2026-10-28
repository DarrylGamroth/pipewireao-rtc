json_value(value) = Common.parse_json(String(JSON.json(value)))

function merge_settings(defaults::AbstractDict, overrides::AbstractDict, schema::AbstractDict)
    result = deepcopy(defaults)
    for (key, value) in overrides
        haskey(schema["properties"], key) || throw(ArgumentError("unknown simulator setting $key"))
        result[key] = merge_setting(get(defaults,key,nothing),value,schema["properties"][key])
    end
    return result
end

merge_setting(default, value, schema) = deepcopy(value)
merge_setting(default::AbstractDict, value::AbstractDict, schema) =
    haskey(schema, "oneOf") ? deepcopy(value) : merge_settings(default,value,schema)

function matching_settings_branches(alternatives, value)
    return findall(alternatives) do branch
        try
            validate_settings(branch, value, value)
            true
        catch error
            error isa ArgumentError || rethrow()
            false
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
                error isa ArgumentError || rethrow()
                false
            end
            matches && contains_readonly_setting(branch, value)
        end
    elseif get(schema, "type", nothing) == "object" && value isa AbstractDict
        return any(get(schema, "properties", Dict())) do (key, property)
            haskey(value, key) && contains_readonly_setting(property, value[key])
        end
    elseif get(schema, "type", nothing) == "array" && value isa AbstractVector
        return any(item -> contains_readonly_setting(schema["items"], item), value)
    end
    return false
end

"Enforce the declared editable shape; physical validation remains with the plant."
function validate_settings(schema, proposed, current; path="settings", readonly=false)
    schema isa AbstractDict || throw(ArgumentError("invalid settings schema"))
    readonly |= get(schema, "readOnly", false) === true
    readonly && proposed != current && throw(ArgumentError("$path requires a separate calibration/deployment change"))
    if haskey(schema, "oneOf")
        alternatives = schema["oneOf"]
        before = matching_settings_branches(alternatives, current)
        after = matching_settings_branches(alternatives, proposed)
        if length(before) == length(after) == 1 && only(before) != only(after)
            (contains_readonly_setting(alternatives[only(before)], current) ||
                contains_readonly_setting(alternatives[only(after)], proposed)) &&
                throw(ArgumentError("$path requires a separate calibration/deployment change"))
        end
        matches = count(schema["oneOf"]) do branch
            try
                validate_settings(branch, proposed, current; path, readonly)
                true
            catch error
                error isa ArgumentError || rethrow()
                false
            end
        end
        matches == 1 || throw(ArgumentError("$path must match exactly one settings schema alternative"))
        return nothing
    end
    kind = get(schema, "type", nothing)
    if kind == "object"
        proposed isa AbstractDict && current isa AbstractDict || throw(ArgumentError("$path must be an object"))
        properties = get(schema, "properties", Dict())
        required = get(schema, "required", collect(keys(properties)))
        all(key -> haskey(properties, key), keys(proposed)) && all(key -> haskey(proposed, key), required) ||
            throw(ArgumentError("$path must contain the required declared settings"))
        for (key, property) in properties
            if haskey(proposed,key) != haskey(current,key)
                value = haskey(proposed,key) ? proposed[key] : current[key]
                contains_readonly_setting(property,value) &&
                    throw(ArgumentError("$path.$key requires a separate calibration/deployment change"))
            end
        end
        for key in keys(proposed)
            validate_settings(properties[key], proposed[key], get(current,key,proposed[key]); path="$path.$key", readonly)
        end
    elseif kind == "array"
        proposed isa AbstractVector && current isa AbstractVector || throw(ArgumentError("$path must be an array"))
        max_items = get(schema, "maxItems", readonly ? 4096 : 256)
        max_items isa Integer && !(max_items isa Bool) && 0 <= max_items <= 4096 ||
            throw(ArgumentError("$path has an invalid maxItems limit"))
        limit = readonly ? max_items : min(max_items, 256)
        length(proposed) <= limit || throw(ArgumentError("$path exceeds $limit values"))
        length(proposed) >= get(schema, "minItems", 0) || throw(ArgumentError("$path has too few values"))
        length(proposed) <= max_items || throw(ArgumentError("$path has too many values"))
        get(schema, "uniqueItems", false) && length(unique(proposed)) != length(proposed) &&
            throw(ArgumentError("$path requires unique values"))
        for (index, value) in enumerate(proposed)
            base = index <= length(current) ? current[index] : value
            validate_settings(schema["items"], value, base; path="$path[$index]", readonly)
        end
    elseif kind in ("number", "integer")
        proposed isa Real && !(proposed isa Bool) && isfinite(proposed) ||
            throw(ArgumentError("$path must be a finite number"))
        kind == "integer" && !(proposed isa Integer) && throw(ArgumentError("$path must be an integer"))
        for (key, compare) in (("minimum", >=), ("maximum", <=), ("exclusiveMinimum", >), ("exclusiveMaximum", <))
            haskey(schema, key) && !compare(proposed, schema[key]) && throw(ArgumentError("$path violates $key"))
        end
    elseif kind == "string"
        proposed isa AbstractString && !occursin('\0', proposed) && ncodeunits(proposed) <= 16 * 1024 ||
            throw(ArgumentError("$path must be a bounded string"))
    elseif kind == "boolean"
        proposed isa Bool || throw(ArgumentError("$path must be Boolean"))
    else
        throw(ArgumentError("unsupported settings schema type $kind"))
    end
    haskey(schema, "enum") && proposed ∉ schema["enum"] && throw(ArgumentError("$path is not an admitted value"))
    return nothing
end

