# Framework adapters interpret worker roles. Application role names identify
# instances only; executable strings and observed OS thread names select nothing.
"Set the default Julia thread count for a declared process launcher."
function julia_threads!(argv, count)
    positions = findall(arg -> startswith(arg, "--threads="), argv)
    length(positions) <= 1 && !("--threads" in argv) && !("-t" in argv) ||
        throw(ArgumentError("Julia owner permits at most one --threads= argument"))
    if isempty(positions)
        # Keep the launcher-derived option before the project/entrypoint, matching
        # the ordinary --startup-file, --threads, --project authoring order.
        position = findfirst(
            arg ->
                startswith(arg, "--project") ||
                arg in ("-e", "--eval", "-E", "--print", "-L", "--load", "--"),
            argv,
        )
        insert!(argv, something(position, 2), "--threads=$count,0")
    else
        argv[only(positions)] = "--threads=$count,0"
    end
    return nothing
end

function owner_scheduling!(::Val{:jfg}, owner, process)
    workers = process["workers"]
    Set(keys(workers)) == Set(["julia"]) || throw(
        ArgumentError("FilterGraphPipeWire owner requires only ordered julia worker CPUs"),
    )
    cpus = workers["julia"]
    length(cpus) >= 2 || throw(
        ArgumentError(
            "FilterGraphPipeWire owner requires at least two default Julia threads"
        ),
    )
    first(cpus) == process["leader-cpu"] || throw(
        ArgumentError("FilterGraphPipeWire thread one must use the process leader CPU")
    )
    argv = owner["argv"]
    any(arg -> first(split(arg, '=')) == "--pin-cpus", argv) &&
        throw(ArgumentError("launcher owns FilterGraphPipeWire --pin-cpus"))
    julia_threads!(argv, length(cpus))
    append!(argv, ["--pin-cpus", join(cpus, ',')])
    return nothing
end

"Apply the selected process placement adapter before sealing a deployment."
owner_scheduling!(kind::Val, owner, process) =
    throw(ArgumentError("unknown owner scheduling kind $kind"))

owner_scheduling!(kind, owner, process) =
    throw(ArgumentError("owner kind must be a string"))
owner_scheduling!(kind::AbstractString, owner, process) =
    owner_scheduling!(Val(Symbol(kind)), owner, process)

function prepare_owner_scheduling!(spec, profile)
    processes = profile["scheduling"]["processes"]
    for owner in spec["owners"]
        D.validate_owner_argv(owner["argv"])
        role = owner["role"]
        haskey(processes, role) ||
            throw(ArgumentError("missing owner process scheduling for $role"))
        kind = pop!(owner, "kind", nothing)
        if role in get(spec, "auxiliary-source-owners", String[])
            D.uses_source_control_protocol(owner) ||
                throw(ArgumentError("auxiliary source owner requires SourceControl"))
        end
        if kind === nothing
            isempty(processes[role]["workers"]) ||
                throw(ArgumentError("worker placement requires an explicit owner kind"))
        else
            owner_scheduling!(kind, owner, processes[role])
        end
    end
    owners = Set(owner["role"] for owner in spec["owners"])
    for (role, process) in processes
        role in owners ||
            isempty(process["workers"]) ||
            throw(
                ArgumentError("worker placement requires an explicit owner kind for $role")
            )
    end
    return spec
end
