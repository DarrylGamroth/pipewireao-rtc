# Framework adapters interpret worker roles. Application role names identify
# instances only; executable strings and observed OS thread names select nothing.
function worker_cpu(workers, name)
    haskey(workers, name) || throw(ArgumentError("owner requires $name worker placement"))
    return only(workers[name])
end

function julia_threads!(argv, count)
    positions = findall(arg -> startswith(arg, "--threads="), argv)
    length(positions) == 1 || throw(ArgumentError("Julia owner requires exactly one --threads argument"))
    argv[only(positions)] = "--threads=$count,0"
    return nothing
end

function owner_scheduling!(::Val{:jfg}, owner, process)
    workers = process["workers"]
    Set(keys(workers)) == Set(["julia"]) || throw(ArgumentError("JFG owner requires only ordered julia worker CPUs"))
    cpus = workers["julia"]
    length(cpus) >= 2 || throw(ArgumentError("JFG owner requires at least two default Julia threads"))
    first(cpus) == process["leader-cpu"] || throw(ArgumentError("JFG thread one must use the process leader CPU"))
    argv = owner["argv"]
    any(arg -> first(split(arg, '=')) == "--pin-cpus", argv) &&
        throw(ArgumentError("launcher owns JFG --pin-cpus"))
    julia_threads!(argv, length(cpus))
    append!(argv, ["--pin-cpus", join(cpus, ',')])
    return nothing
end

function owner_scheduling!(::Val{:aos}, owner, process)
    workers = process["workers"]
    Set(keys(workers)) ⊆ Set(["pipewire", "optical-diagnostics", "pupil-output"]) || throw(ArgumentError("unknown AOS worker placement"))
    argv = owner["argv"]
    any(arg -> first(split(arg, '=')) in ("--pipewire-cpu", "--optical-diagnostics-cpu", "--pupil-output-cpu", "--transport-cpu"), argv) &&
        throw(ArgumentError("launcher owns AOS worker arguments"))
    haskey(owner["environment"], "PIPEWIREAO_OPTICAL_CPU") &&
        throw(ArgumentError("obsolete optical CPU environment setting"))
    julia_threads!(argv, haskey(workers, "pupil-output") ? 3 : 2)
    append!(argv, ["--pipewire-cpu", string(worker_cpu(workers, "pipewire"))])
    if haskey(workers, "optical-diagnostics")
        cpu = worker_cpu(workers, "optical-diagnostics")
        cpu != process["leader-cpu"] || throw(ArgumentError("optical diagnostics worker must differ from source CPU"))
        append!(argv, ["--optical-diagnostics-cpu", string(cpu)])
    end
    if haskey(workers, "pupil-output")
        cpu = worker_cpu(workers, "pupil-output")
        cpu != process["leader-cpu"] || throw(ArgumentError("pupil output worker must differ from source CPU"))
        (!haskey(workers, "optical-diagnostics") || cpu != worker_cpu(workers, "optical-diagnostics")) ||
            throw(ArgumentError("pupil output and optical diagnostics require distinct CPUs"))
        append!(argv, ["--pupil-output-cpu", string(cpu)])
    end
    return nothing
end
owner_scheduling!(kind::Val, owner, process) = throw(ArgumentError("unknown owner scheduling kind $kind"))

function prepare_owner_scheduling!(spec, profile)
    processes = profile["scheduling"]["processes"]
    for owner in spec["owners"]
        role = owner["role"]
        haskey(processes, role) || throw(ArgumentError("missing owner process scheduling for $role"))
        kind = pop!(owner, "kind", nothing)
        if kind === nothing
            isempty(processes[role]["workers"]) || throw(ArgumentError("worker placement requires an explicit owner kind"))
        else
            kind in ("jfg", "aos") || throw(ArgumentError("unknown owner kind $kind"))
            owner_scheduling!(Val(Symbol(kind)), owner, processes[role])
        end
    end
    owners = Set(owner["role"] for owner in spec["owners"])
    for (role, process) in processes
        role in owners || isempty(process["workers"]) ||
            throw(ArgumentError("worker placement requires an explicit owner kind for $role"))
    end
    return spec
end
