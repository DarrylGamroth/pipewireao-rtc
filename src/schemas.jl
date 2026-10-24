"""Cold references to the shared scientific payload declarations."""
module Schemas

import ..Common

const CATALOG_PATH = joinpath(@__DIR__, "..", "data", "schemas.yaml")
Base.include_dependency(CATALOG_PATH)
const CATALOG = Common.read_yaml(CATALOG_PATH)
const BY_ID = Dict(contract["id"] => contract for contract in values(CATALOG))

declaration(name::AbstractString) = CATALOG[name]
identifier(name::AbstractString) = declaration(name)["id"]
context() = Dict("schemas" => CATALOG)

"Reject contradictory representations for a known payload contract."
function validate_schema(schema::AbstractString, value)
    contract = get(BY_ID, schema, nothing)
    contract === nothing && return nothing
    for field in ("element-type", "element_type")
        haskey(value, field) || continue
        value[field] in (contract["wire_type"], contract["element_type"]) ||
            throw(ArgumentError("schema $schema requires $(contract["wire_type"]), received $(value[field])"))
    end
    return nothing
end
validate_schema(schema, value) = nothing
function validate(value::AbstractDict)
    validate_schema(get(value, "schema", nothing), value)
    foreach(validate, values(value))
    return nothing
end
validate(value::AbstractVector) = foreach(validate, value)
validate(value) = nothing

"Resolve only schema references; retain instrument/settings references for their owners."
function resolve(value::AbstractDict)
    if haskey(value, "\$ref")
        pointer = Common.configuration_reference_pointer(value)
        return startswith(pointer, "/schemas/") ?
            Common.configuration_value(value, context()) : deepcopy(value)
    end
    return Dict{String,Any}(key => resolve(item) for (key, item) in value)
end
resolve(value::AbstractVector) = [resolve(item) for item in value]
resolve(value) = deepcopy(value)

end
