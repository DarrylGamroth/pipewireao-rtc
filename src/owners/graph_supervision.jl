# Cold graph-owner configuration. Numerical policy belongs to CorrectionSupervision.
struct SupervisionCondition
    output::Symbol
    schema::String
    tolerance::Float64
    configuration::CorrectionSupervision.Configuration
end

supervision_ms(value, name) = throw(ArgumentError("$name must be integer milliseconds in 1:3600000"))
supervision_ms(::Bool, name) = throw(ArgumentError("$name must be integer milliseconds in 1:3600000"))
function supervision_ms(value::Integer, name)
    1 <= value <= 3_600_000 || throw(ArgumentError("$name must be integer milliseconds in 1:3600000"))
    return UInt64(value) * UInt64(1_000_000)
end

supervision_tolerance(value) = throw(ArgumentError("absolute_tolerance must be finite and nonnegative"))
supervision_tolerance(::Bool) = throw(ArgumentError("absolute_tolerance must be finite and nonnegative"))
function supervision_tolerance(value::Real)
    isfinite(value) && value >= 0 || throw(ArgumentError("absolute_tolerance must be finite and nonnegative"))
    result = Float64(value)
    isfinite(result) || throw(ArgumentError("absolute_tolerance does not fit Float64"))
    return result
end

function read_supervision(path::AbstractString)
    filesize(path) <= 65536 || throw(ArgumentError("supervision YAML exceeds 64 KiB"))
    return supervision_conditions(Schemas.resolve(Common.read_yaml(path)))
end

supervision_conditions(document) = throw(ArgumentError("supervision requires schema_version and conditions"))
function supervision_conditions(document::AbstractDict)
    Set(keys(document)) == Set(("schema_version", "conditions")) &&
        get(document, "schema_version", nothing) === 1 ||
        throw(ArgumentError("supervision requires schema_version: 1 and conditions"))
    return supervision_conditions(document["conditions"], Val(:conditions))
end

supervision_conditions(entries, ::Val{:conditions}) = throw(ArgumentError("supervision conditions must be an array"))
function supervision_conditions(entries::AbstractVector, ::Val{:conditions})
    1 <= length(entries) <= 8 || throw(ArgumentError("supervision requires 1 to 8 conditions"))
    conditions = map(supervision_condition, entries)
    allunique(condition.output for condition in conditions) || throw(ArgumentError("duplicate supervision output"))
    return Tuple(conditions)
end

supervision_condition(entry) = throw(ArgumentError("supervision condition must be a mapping"))
function supervision_condition(entry::AbstractDict)
    required = Set(("output", "schema", "absolute_tolerance", "trip_fraction", "clear_fraction",
        "persistence_ms", "max_gap_ms"))
    fields = Set(keys(entry))
    required ⊆ fields && fields ⊆ union(required, Set(("enabled", "action"))) ||
        throw(ArgumentError("invalid supervision condition fields"))
    output = entry["output"]
    supervision_output(output) || throw(ArgumentError("invalid supervision output name"))
    schema = entry["schema"]
    schema == Schemas.identifier("pdm_constraint_feedback") ||
        throw(ArgumentError("supervision requires the declared PDM constraint-feedback schema"))
    enabled = get(entry, "enabled", true)
    enabled === true || enabled === false || throw(ArgumentError("enabled must be Boolean"))
    action = get(entry, "action", "monitor_only")
    action in ("monitor_only", "restore_reference") || throw(ArgumentError("invalid supervision action"))
    configuration = CorrectionSupervision.Configuration(;
        trip_fraction=entry["trip_fraction"], clear_fraction=entry["clear_fraction"],
        persistence_ns=supervision_ms(entry["persistence_ms"], "persistence_ms"),
        max_gap_ns=supervision_ms(entry["max_gap_ms"], "max_gap_ms"), enabled, action=Symbol(action))
    return SupervisionCondition(Symbol(output), schema,
        supervision_tolerance(entry["absolute_tolerance"]), configuration)
end

supervision_output(_) = false
supervision_output(value::AbstractString) = occursin(r"^[a-zA-Z0-9_.-]{1,128}$", value)
