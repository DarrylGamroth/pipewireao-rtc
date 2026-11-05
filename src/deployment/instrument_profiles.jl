_runtime_backends(selected) = throw(
    ArgumentError(
        "runtime-backends must list distinct known accelerator backends: cuda, amdgpu",
    ),
)
function _runtime_backends(selected::AbstractVector)
    foreach(_runtime_backend, selected)
    length(unique(selected))==length(selected) || throw(
        ArgumentError(
            "runtime-backends must list distinct known accelerator backends: cuda, amdgpu",
        ),
    )
    return nothing
end
_runtime_backend(backend) = throw(
    ArgumentError(
        "runtime-backends must list distinct known accelerator backends: cuda, amdgpu",
    ),
)
_runtime_backend(backend::AbstractString) =
    backend in ("cuda", "amdgpu") || throw(
        ArgumentError(
            "runtime-backends must list distinct known accelerator backends: cuda, amdgpu",
        ),
    )
_profile_bindings_mapping(bindings, label) =
    throw(ArgumentError("$label bindings must be a mapping"))
_profile_bindings_mapping(::AbstractDict, label) = nothing
_merge_profile_field(base::AbstractDict, value::AbstractDict, field) =
    merge_profile(base, value, field)
function _merge_profile_field(base, value, field)
    isequal(base, value) ||
        throw(ArgumentError("conflicting instrument and host profile field: $field"))
    return base
end

const INSTRUMENT_PROFILE_FIELDS =
    Set(["application", "mode", "bindings", "devices", "calibration"])
const HOST_PROFILE_FIELDS = Set([
    "scheduling",
    "bindings",
    "environment",
    "analysis",
    "simulation",
    "runtime-backends",
])

function runtime_backends(profile)
    selected = get(profile, "runtime-backends", String[])
    _runtime_backends(selected)
    return selected
end

profile_fields(document, allowed, label) = throw(ArgumentError("$label must be a mapping"))
function profile_fields(document::AbstractDict, allowed, label)
    InstrumentDefinition.bounded(document, Ref(131072))
    Set(keys(document)) ⊆ allowed || throw(ArgumentError("unknown $label fields"))
    runtime_backends(document)
    application_file(document)
    bindings = get(document, "bindings", Dict())
    _profile_bindings_mapping(bindings, label)
    for (name, value) in bindings
        occursin(r"^[A-Z][A-Z0-9_]*$", name) ||
            throw(ArgumentError("profile binding names must be uppercase identifiers"))
        (
            name in RUNTIME_BINDINGS ||
            name == "JULIA" ||
            startswith(name, "BOOTSTRAP_INSTANCE_")
        ) && throw(
            ArgumentError(
                "profile bindings cannot replace runtime or Julia executable bindings",
            ),
        )
        binding_value(value)
    end
    return document
end

function merge_profile(profile::AbstractDict, host::AbstractDict, path = "")
    combined = Dict{String,Any}(key => deepcopy(value) for (key, value) in profile)
    for (key, value) in host
        field = isempty(path) ? key : "$path.$key"
        if !haskey(combined, key)
            combined[key] = deepcopy(value)
        else
            combined[key] = _merge_profile_field(combined[key], value, field)
        end
    end
    return combined
end

"""Combine portable instrument choices and host configuration without overriding values.

The instrument profile accepts `application`, `mode`, device `bindings`, `devices` and
`calibration`. The host accepts `scheduling`, non-scheduling `bindings`, `environment`,
`analysis`, `simulation` and optional `runtime-backends`. The latter promotes
declared accelerator packages into the generated runtime without changing the
simulation backend or importing those packages. Named loops and workers let launcher adapters derive native placement,
client configuration and worker arguments from the same process declaration. Host
configuration cannot replace instrument choices. Mappings
merge recursively; repeated leaves must be identical, and lists never append.
The ordinary exporter still requires exact placement for all selected roles.
"""
function combine_profile(profile, host = nothing)
    profile_fields(profile, INSTRUMENT_PROFILE_FIELDS, "instrument profile")
    for name in keys(get(profile, "bindings", Dict()))
        (name == "RT_PRIORITY" || endswith(name, "_CPU") || endswith(name, "_CPUS")) &&
            throw(
                ArgumentError("host placement binding belongs in the host profile: $name"),
            )
    end
    host === nothing && return deepcopy(profile)
    profile_fields(host, HOST_PROFILE_FIELDS, "host profile")
    for name in keys(get(host, "bindings", Dict()))
        (name == "RT_PRIORITY" || endswith(name, "_CPU") || endswith(name, "_CPUS")) &&
            throw(
                ArgumentError(
                    "scheduling binding must be derived from host scheduling: $name",
                ),
            )
    end
    compiled = host_scheduling(host)
    profile_fields(
        compiled,
        union(HOST_PROFILE_FIELDS, Set(["placement"])),
        "resolved host profile",
    )
    return merge_profile(profile, compiled)
end

"Read bounded YAML instrument and optional host profiles before export."
function load_profile(path::AbstractString; host = nothing)
    profile = InstrumentConfiguration.bounded_yaml(path)
    host_profile = host === nothing ? nothing : InstrumentConfiguration.bounded_yaml(host)
    return combine_profile(profile, host_profile)
end
