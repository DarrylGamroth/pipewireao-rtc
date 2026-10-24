# Host scheduling is compiled into the native contexts by declared loop name.
# Template selection is explicit in the application; owner kinds and argv are
# deliberately irrelevant to this boundary.
function native_template(path)
    path isa AbstractString || throw(ArgumentError("native template path must be text"))
    name = basename(path)
    name in TEMPLATE_FILES && path == "shared-runtime/" * name ||
        throw(ArgumentError("unsupported native runtime template: $path"))
    return joinpath(resource_root(), "templates", "instrument", name)
end

function native_scheduling!(config, scheduling, role; allow_extra_loops=false)
    properties = get(config, "context.properties", Dict())
    loops = get(properties, "context.data-loops", [])
    loops isa AbstractVector || throw(ArgumentError("native data loops must be a list: $role"))
    names = String[]
    for loop in loops
        name = get(loop, "loop.name", nothing)
        name isa String || throw(ArgumentError("native data loop requires a name: $role"))
        push!(names, name)
    end
    length(unique(names)) == length(names) ||
        throw(ArgumentError("native data loop names must be unique: $role"))
    selected = get(scheduling, "data-loops", Dict())
    selected isa AbstractDict && (allow_extra_loops ? Set(names) ⊆ Set(keys(selected)) :
        Set(keys(selected)) == Set(names)) ||
        throw(ArgumentError("host data-loops must name every native loop exactly once: $role"))
    priority = scheduling["rt-priority"]
    for loop in loops
        cpus = selected[loop["loop.name"]]
        D.valid_cpu_list(cpus)
        loop["thread.affinity"] = deepcopy(cpus)
        loop["loop.rt-prio"] = priority
    end
    for module_ in get(config, "context.modules", [])
        get(module_, "name", nothing) == "libpipewire-module-rt" || continue
        args = get!(module_, "args", Dict{String,Any}())
        args["rt.prio"] = priority
    end
    return config
end

"""Compile declared host process/loop scheduling into owned native templates."""
function render_templates!(application, spec, profile, prefix)
    runtime = joinpath(application, "shared-runtime")
    !ispath(runtime) || throw(ArgumentError("instrument source must not contain generated runtime templates"))
    processes = profile["scheduling"]["processes"]
    corepath = spec["core"]
    corepath == "shared-runtime/core.conf.in" ||
        throw(ArgumentError("native core requires the shared core template"))
    core = D.decode(native_template(corepath), prefix)
    native_scheduling!(core, processes["core"], "core")
    modules = D.decode(joinpath(application, "rtc", "core.conf"), prefix)
    modules isa AbstractDict && Set(keys(modules)) == Set(["context.modules"]) ||
        throw(ArgumentError("instrument rtc/core.conf must contain only context.modules"))
    declarations = modules["context.modules"]
    declarations isa AbstractVector || throw(ArgumentError("instrument context.modules must be a list"))
    append!(core["context.modules"], declarations)
    telemetry_queues!(core)
    outputs = Dict{String,Any}(corepath => core)
    clients = Dict{String,String}()
    for (role, path) in spec["client"]
        role isa String && occursin(r"^[a-z][a-z0-9-]{0,31}$", role) ||
            throw(ArgumentError("invalid native client role: $role"))
        config = D.decode(native_template(path), prefix)
        basename(path) != "core.conf.in" ||
            throw(ArgumentError("client role cannot select the core template: $role"))
        if haskey(processes, role)
            # The daemon context already checked the complete core loop set.
            # Its one-shot client context can use a subset of those same loops.
            native_scheduling!(config, processes[role], role; allow_extra_loops=role == "core")
        elseif role != "analysis"
            throw(ArgumentError("native client role has no host scheduling declaration: $role"))
        end
        destination = "shared-runtime/client-" * role * ".conf.in"
        outputs[destination] = config
        clients[role] = destination
    end
    mkpath(runtime)
    for (relative, config) in outputs
        path = joinpath(application, relative)
        ScienceExport.write_spa_config(path, config)
        D.decode(path, prefix)
    end
    spec["client"] = clients
    return runtime
end

# Check after mode composition, which may declare additional native clocks.
function validate_telemetry_groups(core)
    groups = Set(get(object["args"], "node.group", nothing)
        for object in get(core, "context.objects", [])
        if get(object, "factory", nothing) == "spa-node-factory" &&
            get(get(object, "args", Dict()), "factory.name", nothing) == "support.node.driver")
    for declaration in get(core, "context.modules", [])
        get(declaration, "name", nothing) == "libpipewire-module-queue" || continue
        args = declaration["args"]
        get(args, "queue.storage", nothing) == "copy" &&
            get(args, "queue.overflow", nothing) == "drop-oldest" || continue
        group = get(get(args, "playback.props", Dict()), "node.group", nothing)
        group isa AbstractString && !isempty(group) && group in groups ||
            throw(ArgumentError("copy/drop-oldest queue playback requires an owned driver group: " *
                string(get(args, "node.name", "unnamed queue"))))
    end
    return nothing
end

function telemetry_queues!(core)
    # Copy/drop-oldest playback is independent of the control clock. Without an
    # explicit driver group, the scheduler can attach it to the active RTC driver
    # when the last GUI driver disappears, adding completion dependencies mid-cycle.
    for declaration in get(core, "context.modules", [])
        get(declaration, "name", nothing) == "libpipewire-module-queue" || continue
        args = declaration["args"]
        get(args, "queue.storage", nothing) == "copy" &&
            get(args, "queue.overflow", nothing) == "drop-oldest" || continue
        playback = get!(args, "playback.props", Dict{String,Any}())
        get!(playback, "node.group", "pipewireao-telemetry")
    end
    return nothing
end
