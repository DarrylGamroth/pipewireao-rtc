# Source configuration describes process envelopes and named loop/worker CPUs.
# Native placement remains the existing runtime verification contract.
const SCHEDULING_DEFAULTS = Dict{String,Any}("rt-priority" => 0,
    "locked-bytes" => 0, "threads" => [])
const PLACEMENT_FIELDS = ("cpus", "leader-cpu", "rt-priority", "locked-bytes", "threads")

function host_scheduling(host)
    result = Dict{String,Any}(key => deepcopy(value) for (key, value) in host)
    scheduling = get(result, "scheduling", nothing)
    InstrumentConfiguration.fields(scheduling, ("processes", "defaults"), ("processes",), "host scheduling")
    declarations = InstrumentConfiguration._declaration_object(scheduling["processes"], "scheduled processes")
    isempty(declarations) && throw(ArgumentError("host scheduling requires at least one process"))
    defaults = get(scheduling, "defaults", Dict())
    InstrumentConfiguration.fields(defaults, ("rt-priority", "locked-bytes", "threads"), (), "scheduling defaults")
    processes = Dict{String,Any}()
    placement = Dict{String,Any}()
    for (role, declaration) in declarations
        InstrumentConfiguration.fields(declaration, (PLACEMENT_FIELDS..., "data-loops", "workers"),
            ("cpus", "leader-cpu"), "process scheduling")
        process = deepcopy(merge(SCHEDULING_DEFAULTS, defaults, declaration))
        envelope = D.valid_cpu_list(process["cpus"])
        for key in ("data-loops", "workers")
            assignments = InstrumentConfiguration._declaration_object(get!(process, key, Dict()), key)
            for (name, cpus) in assignments
                InstrumentDefinition.identifier(name) || throw(ArgumentError("invalid scheduled $key name"))
                D.valid_cpu_list(cpus) ⊆ envelope || throw(ArgumentError("$key CPUs exceed process envelope"))
            end
        end
        processes[role] = process
        placement[role] = Dict(key => deepcopy(process[key]) for key in PLACEMENT_FIELDS)
    end
    D.validate_placements(placement, Set(keys(placement)))
    result["scheduling"] = Dict("processes" => processes)
    result["placement"] = placement
    return result
end
