"""Prepare data-only instrument applications without installing or launching processes."""
module InstrumentExport

using TOML
using YAML
using ..Common
using ..RuntimeExport
using ..ScienceExport
using ..InstrumentConfiguration
import PipeWireAO
import ..InstrumentDefinition
import ..DeploymentConfiguration as D
import ..resource_root

public prepare, seal!, prepare_session_configuration!, graph_port_contracts,
    simulator_port_contracts

const PROFILE_FIELDS = Set(["placement", "bindings", "environment", "analysis", "simulation",
    "mode", "devices", "calibration"])
const RUNTIME_BINDINGS = Set(["PACKAGE", "PREFIX", "REMOTE", "RUNTIME", "SOURCE_OWNER_INSTANCE"])
const TEMPLATE_BINDINGS = ("CORE_CPU", "OBSERVER_CPU", "JULIA_CPU", "RT_PRIORITY")
const TEMPLATE_FILES = ("core.conf.in", "client-rtc.conf.in", "client-julia.conf.in",
    "client-simulator.conf.in", "client-analysis.conf.in")

include("instrument_modes.jl")
include("graph_configuration.jl")
include("session_configuration.jl")

outside(path) = path == ".." || startswith(path, ".." * string(Base.Filesystem.path_separator))

function checked_path(path)
    absolute = abspath(path)
    current = dirname(absolute)
    while true
        islink(current) && throw(ArgumentError("export paths must not traverse symbolic links: $current"))
        parent = dirname(current)
        parent == current && break
        current = parent
    end
    islink(absolute) && throw(ArgumentError("export path must not be a symbolic link: $absolute"))
    return absolute
end

function application_files(root)
    files = String[]
    for (directory, directories, names) in walkdir(root)
        for name in directories
            islink(joinpath(directory, name)) && throw(ArgumentError("linked application directory: $name"))
        end
        for name in names
            path = joinpath(directory, name)
            isfile(path) && !islink(path) || throw(ArgumentError("application assets must be regular files: $path"))
            push!(files, relpath(path, root))
        end
    end
    return sort!(files)
end

"""Seal every regular application file except the deployment manifest itself."""
function seal!(application::AbstractString)
    root = checked_path(application)
    deployment = joinpath(root, "deployment.conf")
    spec = Common.read_json(deployment)
    spec["artifacts"] = Dict(path => Common.sha256_file(joinpath(root, path))
        for path in application_files(root) if path != "deployment.conf")
    Common.write_json(deployment, spec; atomic=true)
    return deployment
end

binding_value(value::AbstractString) = occursin('\0', value) ?
    throw(ArgumentError("export bindings must not contain NUL")) : String(value)
binding_value(value::Integer) = string(value)
binding_value(::Bool) = throw(ArgumentError("export bindings must be strings or integers"))
binding_value(value) = throw(ArgumentError("export bindings must be strings or integers"))

function substitute(value::AbstractString, bindings)
    return replace(value, r"@([A-Z][A-Z0-9_]*)@" => function(token)
        key = String(token[2:end-1])
        haskey(bindings, key) && return bindings[key]
        (key in RUNTIME_BINDINGS || startswith(key, "BOOTSTRAP_INSTANCE_")) && return String(token)
        throw(ArgumentError("missing deployment profile binding: $key"))
    end)
end
function substitute(value::AbstractDict, bindings)
    pairs = [substitute(key, bindings) => substitute(item, bindings) for (key, item) in value]
    length(unique(first.(pairs))) == length(pairs) || throw(ArgumentError("duplicate bound configuration key"))
    return Dict{String,Any}(pairs)
end
substitute(value::AbstractVector, bindings) = [substitute(item, bindings) for item in value]
substitute(value, bindings) = value

function profile_bindings(profile, julia)
    raw = get(profile, "bindings", Dict())
    raw isa AbstractDict || throw(ArgumentError("profile bindings must be an object"))
    all(key -> key isa String && occursin(r"^[A-Z][A-Z0-9_]*$", key), keys(raw)) ||
        throw(ArgumentError("profile binding names must be uppercase identifiers"))
    reserved = union(RUNTIME_BINDINGS, Set(["JULIA"]))
    any(key -> key in reserved || startswith(key, "BOOTSTRAP_INSTANCE_"), keys(raw)) &&
        throw(ArgumentError("profile bindings cannot replace runtime or Julia executable bindings"))
    bindings = Dict(String(key) => binding_value(value) for (key, value) in raw)
    bindings["JULIA"] = String(julia)
    for name in TEMPLATE_BINDINGS
        value = get(raw, name, nothing)
        typeof(value) === Int || throw(ArgumentError("profile requires integer binding $name"))
        (name == "RT_PRIORITY" ? 0 <= value <= 99 : value >= 2) ||
            throw(ArgumentError("profile binding $name is outside its supported range"))
    end
    return bindings
end

function profile!(spec, profile, bindings)
    Set(keys(profile)) ⊆ PROFILE_FIELDS && haskey(profile, "placement") ||
        throw(ArgumentError("profile requires placement and only documented fields"))
    roles = Set(["core", "rtc"])
    haskey(spec, "session-runtime") && push!(roles, "session")
    union!(roles, (owner["role"] for owner in spec["owners"]))
    placement = profile["placement"]
    placement isa AbstractDict && Set(keys(placement)) == roles ||
        throw(ArgumentError("profile placement must name every application process exactly once"))
    D.validate_placements(placement, roles)
    spec["placement"] = deepcopy(placement)
    environments = get(profile, "environment", Dict())
    environments isa AbstractDict && Set(keys(environments)) ⊆ roles ||
        throw(ArgumentError("profile environment contains an unknown application role"))
    for (role, environment) in environments
        D.validate_environment(environment, role)
        if role == "session"
            merge!(spec["session-runtime"]["environment"], substitute(environment, bindings))
        elseif role in (owner["role"] for owner in spec["owners"])
            owner = only(filter(owner -> owner["role"] == role, spec["owners"]))
            merge!(owner["environment"], substitute(environment, bindings))
        else
            throw(ArgumentError("profile environment overrides require an external owner or session role: $role"))
        end
    end
    if haskey(profile, "analysis")
        overrides = profile["analysis"]
        overrides isa AbstractDict || throw(ArgumentError("profile analysis must map declared analysis names to CPU lists"))
        entries = get(spec, "analysis", [])
        Set(keys(overrides)) ⊆ Set(entry["name"] for entry in entries) ||
            throw(ArgumentError("profile analysis names must already be declared by the application"))
        for entry in entries
            haskey(overrides, entry["name"]) || continue
            cpus = overrides[entry["name"]]
            D.valid_cpu_list(cpus)
            entry["cpus"] = deepcopy(cpus)
        end
    end
    for entry in get(spec, "analysis", [])
        haskey(entry, "cpus") || throw(ArgumentError("profile must provide CPU placement for each optional analysis process"))
        D.valid_cpu_list(entry["cpus"])
    end
    return spec
end

function render_templates!(application, bindings, prefix)
    runtime = joinpath(application, "shared-runtime")
    !ispath(runtime) || throw(ArgumentError("instrument source must not contain generated runtime templates"))
    mkpath(runtime)
    for name in TEMPLATE_FILES
        template = joinpath(resource_root(), "templates", "instrument", name)
        write(joinpath(runtime, name), substitute(read(template, String), bindings))
    end
    path = joinpath(runtime, "core.conf.in")
    core = D.decode(path, prefix)
    modules = D.decode(joinpath(application, "rtc", "core.conf"), prefix)
    modules isa AbstractDict && Set(keys(modules)) == Set(["context.modules"]) ||
        throw(ArgumentError("instrument rtc/core.conf must contain only context.modules"))
    declarations = modules["context.modules"]
    declarations isa AbstractVector || throw(ArgumentError("instrument context.modules must be a list"))
    append!(core["context.modules"], declarations)
    ScienceExport.write_spa_config(path, core)
    for name in TEMPLATE_FILES
        D.decode(joinpath(runtime, name), prefix)
    end
    return runtime
end

function simulation_override!(application, profile)
    overrides = get(profile, "simulation", Dict())
    overrides isa AbstractDict && Set(keys(overrides)) ⊆ Set(["backend", "device", "wall_rate"]) ||
        throw(ArgumentError("profile simulation permits only backend, device and wall_rate"))
    path = joinpath(application, "simulation.conf")
    simulation = D.decode(path, get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    backend = get(overrides, "backend", simulation["backend"])
    backend in ("cpu", "cuda") || throw(ArgumentError("unsupported simulation backend"))
    device = get(overrides, "device", simulation["device"])
    typeof(device) === Int && 0 <= device <= typemax(Int32) || throw(ArgumentError("simulation device must be a nonnegative integer"))
    backend == "cpu" && device != 0 && throw(ArgumentError("CPU simulation backend requires device 0"))
    wall_rate = get(overrides, "wall_rate", simulation["wall_rate"])
    typeof(wall_rate) === Int && 0 <= wall_rate <= simulation["rate"] ||
        throw(ArgumentError("simulation wall_rate must be an integer between zero and the model rate"))
    merge!(simulation, overrides)
    Common.write_json(path, simulation; atomic=true)
    return path
end

"Copy instrument source, localizing shared mirror descriptions for independent deployment."
function copy_source(source::AbstractString, destination::AbstractString)
    path = joinpath(source, "instrument.yaml")
    document = isfile(path) ? InstrumentConfiguration.bounded_yaml(path) : nothing
    descriptions = Pair{String,String}[]
    if document !== nothing
        for mirror in values(get(document, "deformable_mirrors", Dict()))
            name = mirror["description"]
            checked_path(joinpath(source, name))
            from = InstrumentConfiguration.mirror_description_path(source, name)
            startswith(name, "../mirrors/") || continue
            local_name = name[4:end]
            !ispath(joinpath(source, local_name)) ||
                throw(ArgumentError("shared mirror conflicts with instrument asset: $local_name"))
            push!(descriptions, from => local_name)
            mirror["description"] = local_name
        end
    end
    RuntimeExport.copy_tree(source, destination)
    for (from, name) in unique(descriptions)
        RuntimeExport.copy_file(from, joinpath(destination, name))
    end
    isempty(descriptions) || Common.write_yaml(joinpath(destination, "instrument.yaml"), document;
        header="Generated by PipeWireAORTC from instrument source; shared mirror references localized.")
    return destination
end

"""Copy an instrument into a fresh application and seal its prepared files.

A supplied registered Manifest is validated through the ordinary deployment
contract. Without one the result supports offline preparation only; the normal
installer still requires a sealed registered dependency closure.
"""
function prepare(source::AbstractString, destination::AbstractString;
        profile::AbstractDict, julia=Base.julia_cmd().exec[1], manifest=nothing,
        prefix=get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
    source, destination = checked_path(source), checked_path(destination)
    isdir(source) || throw(ArgumentError("instrument source must be a directory"))
    !ispath(destination) && !islink(destination) || throw(ArgumentError("instrument export destination must be fresh"))
    outside(relpath(destination, source)) || throw(ArgumentError("instrument export destination must be outside source"))
    application_files(source)
    bindings = profile_bindings(profile, julia)
    authoring = D.decode(joinpath(source, "rtc", "application.conf"), prefix)
    mode = selected_mode(source, profile)
    authoring = merge_configuration(authoring, mode["application"])
    graph_configurations = pop!(authoring, "graph-configurations", [])
    configurations = pop!(authoring, "configuration-files", [])
    configuration = pop!(authoring, "configuration", nothing)
    append!(authoring["owners"], get(profile, "devices", []))
    authoring = substitute(authoring, bindings)
    !haskey(authoring, "artifacts") && !haskey(authoring, "placement") ||
        throw(ArgumentError("instrument application must not contain generated seals or machine placement"))
    metadata = TOML.parsefile(joinpath(source, "Project.toml"))
    !haskey(metadata, "sources") || throw(ArgumentError("instrument Project.toml must not override package sources"))
    spec = profile!(substitute(authoring, bindings), profile, bindings)
    mkpath(dirname(destination))
    staging = mktempdir(dirname(destination); prefix="instrument-export-")
    # copy_tree requires a new destination; only this function owns staging.
    application = joinpath(staging, "application")
    try
        copy_source(source, application)
        manifest === nothing || RuntimeExport.copy_file(checked_path(manifest), joinpath(application, "Manifest.toml"))
        render_templates!(application, bindings, prefix)
        prepare_mode!(application, spec, mode, profile, bindings, prefix;
            configuration=something(configuration, "rtc/configuration.yaml"))
        instrument = configuration === nothing ? InstrumentConfiguration.prepare_publication(application) :
            InstrumentConfiguration.prepare_publication(application; configuration)
        spec["instrument"] = relpath(instrument, application)
        if isfile(joinpath(application,"simulation.conf"))
            simulation = D.decode(joinpath(application,"simulation.conf"),prefix)
            get(simulation,"version",nothing) == 3 && InstrumentConfiguration.prepare_simulation_configuration!(application)
            simulation_override!(application, profile)
        end
        rtc = InstrumentConfiguration.load_rtc(D.relative_asset(application,
            something(configuration, "rtc/configuration.yaml")))
        prepare_graph_configurations!(application, graph_configurations,
            relpath(instrument, application), prefix; dimensions=rtc.document["dimensions"],
            mirror_controls=rtc.controls["deformable_mirrors"])
        prepare_session_configuration!(application, spec, graph_configurations,
            relpath(instrument, application), prefix;
            dimensions=rtc.document["dimensions"], mirror_controls=rtc.controls["deformable_mirrors"], configurations)
        Common.write_json(joinpath(application, "deployment.conf"), spec; atomic=true)
        seal!(application)
        D.validate_application(Common.read_json(joinpath(application, "deployment.conf")),
            joinpath(application, "deployment.conf"), prefix)
        !isfile(joinpath(application, "Manifest.toml")) || D.profile(joinpath(application, "deployment.conf"), prefix)
        mv(application, destination)
    finally
        rm(staging; force=true, recursive=true)
    end
    return destination
end

end # module InstrumentExport
