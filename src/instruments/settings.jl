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
merge_setting(default::AbstractDict, value::AbstractDict, schema) = merge_settings(default,value,schema)

"Enforce the declared editable shape; physical validation remains with the plant."
function validate_settings(schema, proposed, current; path="settings", readonly=false)
    schema isa AbstractDict || throw(ArgumentError("invalid settings schema"))
    readonly |= get(schema, "readOnly", false) === true
    readonly && proposed != current && throw(ArgumentError("$path requires a separate calibration/deployment change"))
    kind = get(schema, "type", nothing)
    if kind == "object"
        proposed isa AbstractDict && current isa AbstractDict || throw(ArgumentError("$path must be an object"))
        properties = get(schema, "properties", Dict())
        Set(keys(proposed)) == Set(keys(current)) == Set(keys(properties)) ||
            throw(ArgumentError("$path must contain exactly the declared settings"))
        for key in keys(properties)
            validate_settings(properties[key], proposed[key], current[key]; path="$path.$key", readonly)
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

