# Resolve authoring once; native process contracts and template consumers remain
# unchanged. References use the same RFC 6901 resolver as instrument metadata.
const SCHEDULING_DEFAULTS = Dict{String,Any}("rt-priority" => 0,
    "locked-bytes" => 0, "threads" => [])

function scheduling_binding(value::Integer)
    typeof(value) === Int || throw(ArgumentError("scheduling binding must be an integer or CPU list"))
    return value
end
function scheduling_binding(value::AbstractVector)
    D.valid_cpu_list(value)
    return join(value, ',')
end
scheduling_binding(value) = throw(ArgumentError("scheduling binding must select an integer or CPU list"))

function scheduling_reference(selector::AbstractDict, context)
    pointer = Common.configuration_reference_pointer(selector)
    startswith(pointer, "/processes/") || throw(ArgumentError("scheduling binding must reference a process"))
    return Common.configuration_pointer(context, pointer)
end
scheduling_reference(selectors::AbstractVector, context) =
    [scheduling_reference(selector, context) for selector in selectors]
scheduling_reference(selector, context) = throw(ArgumentError("scheduling binding requires JSON Pointer references"))

function host_scheduling(host)
    result = Dict{String,Any}(key => deepcopy(value) for (key, value) in host)
    scheduling = pop!(result, "scheduling", nothing)
    scheduling === nothing && throw(ArgumentError("host profile requires scheduling"))
    InstrumentConfiguration.fields(scheduling, ("processes", "bindings", "defaults"),
        ("processes", "bindings"), "host scheduling")
    processes = InstrumentConfiguration._declaration_object(scheduling["processes"], "scheduled processes")
    isempty(processes) && throw(ArgumentError("host scheduling requires at least one process"))
    defaults = get(scheduling, "defaults", Dict())
    InstrumentConfiguration.fields(defaults, ("rt-priority", "locked-bytes", "threads"), (), "scheduling defaults")
    placement = Dict(role => deepcopy(merge(SCHEDULING_DEFAULTS, defaults,
        InstrumentConfiguration._declaration_object(contract, "process scheduling")))
        for (role, contract) in processes)
    D.validate_placements(placement, Set(keys(placement)))
    selectors = InstrumentConfiguration._declaration_object(scheduling["bindings"], "scheduling bindings")
    context = Dict("processes" => placement)
    bindings = Dict{String,Any}(key => deepcopy(value) for (key, value) in get(result, "bindings", Dict()))
    result["bindings"] = bindings
    for (name, selector) in selectors
        haskey(bindings, name) && throw(ArgumentError("duplicate scheduling binding $name"))
        bindings[name] = scheduling_binding(scheduling_reference(selector, context))
    end
    result["placement"] = placement
    return result
end
