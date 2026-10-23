# RFC 6901 plain JSON Pointer, deliberately without URIs or expression evaluation.
function configuration_pointer(context, pointer::AbstractString)
    isempty(pointer) && return context
    startswith(pointer, '/') || throw(ArgumentError("configuration reference must be a JSON Pointer: $pointer"))
    value = context
    for encoded in split(pointer[2:end], '/'; keepempty=true)
        occursin(r"~(?:[^01]|$)", encoded) &&
            throw(ArgumentError("invalid configuration reference escape: $pointer"))
        key = replace(replace(encoded, "~1" => "/"), "~0" => "~")
        value = configuration_pointer_entry(value, key, pointer)
    end
    return value
end
function configuration_pointer_entry(value::AbstractDict, key, pointer)
    haskey(value, key) || throw(ArgumentError("unknown configuration reference: $pointer"))
    return value[key]
end
function configuration_pointer_entry(value::AbstractVector, key, pointer)
    occursin(r"\A(0|[1-9][0-9]*)\z", key) ||
        throw(ArgumentError("configuration reference array index must be zero-based: $pointer"))
    index = tryparse(Int, key)
    index !== nothing && index < length(value) ||
        throw(ArgumentError("configuration reference array index out of bounds: $pointer"))
    return value[index + 1]
end
configuration_pointer_entry(value, key, pointer) =
    throw(ArgumentError("configuration reference traverses a scalar: $pointer"))

function configuration_value(value::AbstractDict, context)
    if haskey(value, "\$ref")
        return configuration_reference(configuration_reference_pointer(value), context)
    end
    return Dict(key => configuration_value(item, context) for (key, item) in value)
end
function configuration_reference_pointer(value::AbstractDict)
    Set(keys(value)) == Set(["\$ref"]) ||
        throw(ArgumentError("configuration reference requires only a string \$ref"))
    return configuration_reference_string(value["\$ref"])
end
configuration_reference_string(pointer::AbstractString) = pointer
configuration_reference_string(pointer) =
    throw(ArgumentError("configuration reference requires only a string \$ref"))
configuration_reference(pointer, context) = deepcopy(configuration_pointer(context, configuration_reference_string(pointer)))
configuration_value(value::AbstractVector, context) =
    [configuration_value(item, context) for item in value]
configuration_value(value, context) = deepcopy(value)

