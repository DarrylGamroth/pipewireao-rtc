const INSTRUMENT_PROFILE_FIELDS = Set(["mode", "bindings", "devices", "calibration"])
const HOST_PROFILE_FIELDS = Set(["scheduling", "bindings", "environment", "analysis", "simulation", "runtime-backends"])

function runtime_backends(profile)
    selected = get(profile,"runtime-backends",String[])
    selected isa AbstractVector && all(backend->backend isa AbstractString && backend in ("cuda","amdgpu"),selected) &&
        length(unique(selected))==length(selected) ||
        throw(ArgumentError("runtime-backends must list distinct known accelerator backends: cuda, amdgpu"))
    return selected
end

function profile_fields(document, allowed, label)
    document isa AbstractDict || throw(ArgumentError("$label must be a mapping"))
    InstrumentDefinition.bounded(document, Ref(131072))
    Set(keys(document)) ⊆ allowed || throw(ArgumentError("unknown $label fields"))
    runtime_backends(document)
    bindings = get(document, "bindings", Dict())
    bindings isa AbstractDict || throw(ArgumentError("$label bindings must be a mapping"))
    for (name, value) in bindings
        occursin(r"^[A-Z][A-Z0-9_]*$", name) ||
            throw(ArgumentError("profile binding names must be uppercase identifiers"))
        (name in RUNTIME_BINDINGS || name == "JULIA" || startswith(name, "BOOTSTRAP_INSTANCE_")) &&
            throw(ArgumentError("profile bindings cannot replace runtime or Julia executable bindings"))
        binding_value(value)
    end
    return document
end

function merge_profile(profile::AbstractDict, host::AbstractDict, path="")
    combined = Dict{String,Any}(key => deepcopy(value) for (key, value) in profile)
    for (key, value) in host
        field = isempty(path) ? key : "$path.$key"
        if !haskey(combined, key)
            combined[key] = deepcopy(value)
        elseif combined[key] isa AbstractDict && value isa AbstractDict
            combined[key] = merge_profile(combined[key], value, field)
        elseif !isequal(combined[key], value)
            throw(ArgumentError("conflicting instrument and host profile field: $field"))
        end
    end
    return combined
end

"""Combine portable instrument choices and host configuration without overriding values.

The instrument profile accepts `mode`, device `bindings`, `devices` and
`calibration`. The host accepts `scheduling`, non-scheduling `bindings`, `environment`,
`analysis`, `simulation` and optional `runtime-backends`. The latter promotes
declared accelerator packages into the generated runtime without changing the
simulation backend or importing those packages. Named loops and workers let launcher adapters derive native placement,
client configuration and worker arguments from the same process declaration. Host
configuration cannot replace instrument choices. Mappings
merge recursively; repeated leaves must be identical, and lists never append.
The ordinary exporter still requires exact placement for all selected roles.
"""
function combine_profile(profile, host=nothing)
    profile_fields(profile, INSTRUMENT_PROFILE_FIELDS, "instrument profile")
    for name in keys(get(profile, "bindings", Dict()))
        (name == "RT_PRIORITY" || endswith(name, "_CPU") || endswith(name, "_CPUS")) &&
            throw(ArgumentError("host placement binding belongs in the host profile: $name"))
    end
    host === nothing && return deepcopy(profile)
    profile_fields(host, HOST_PROFILE_FIELDS, "host profile")
    for name in keys(get(host, "bindings", Dict()))
        (name == "RT_PRIORITY" || endswith(name, "_CPU") || endswith(name, "_CPUS")) &&
            throw(ArgumentError("scheduling binding must be derived from host scheduling: $name"))
    end
    compiled = host_scheduling(host)
    profile_fields(compiled, union(HOST_PROFILE_FIELDS, Set(["placement"])), "resolved host profile")
    return merge_profile(profile, compiled)
end

"Read bounded YAML instrument and optional host profiles before export."
function load_profile(path::AbstractString; host=nothing)
    profile = InstrumentConfiguration.bounded_yaml(path)
    host_profile = host === nothing ? nothing : InstrumentConfiguration.bounded_yaml(host)
    return combine_profile(profile, host_profile)
end
