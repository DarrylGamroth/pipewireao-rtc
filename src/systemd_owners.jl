module SystemdOwners

using ..Common

export Coordinator, Service, pid, alive, failure, record, verify!, stop!

const PREFIX = "pipewireao-owner-"
const NONCE = r"^[0-9a-f]{32}$"
cohort_name(invocation) = PREFIX * valid_invocation(invocation) * "-cohort.target"
const ROLE = r"^[a-z][a-z0-9-]{0,31}$"
const SHOW_FIELDS = "Id,LoadState,ActiveState,MainPID,InvocationID,ControlGroup"
monotonic() = time_ns() / 1.0e9

struct OwnerError <: Exception
    message::String
end
Base.showerror(io::IO, error::OwnerError) = print(io, error.message)
fail(message) = throw(OwnerError(message))

struct Coordinator
    unit::String
    invocation::String
    cgroup::String
    launcher::String
end
Coordinator(unit::String, invocation::String, cgroup::String) = Coordinator(unit, invocation, cgroup, "")

mutable struct Service
    coordinator::Coordinator
    role::String
    unit::String
    main_pid::Int
    invocation::String
    start_ticks::UInt64
    cgroup::String
    state::Symbol
    error::String
end

function valid_invocation(value)
    text = lowercase(String(value))
    occursin(NONCE, text) || fail("invalid systemd invocation identity")
    return text
end

function Service(owner::Coordinator, role::AbstractString)
    occursin(ROLE, role) || fail("invalid owner role")
    Service(owner, String(role), PREFIX * owner.invocation * "-" * role * ".service",
            0, "", 0, "", :pending, "")
end

function checked(argv; timeout=5, deadline=nothing)
    if deadline !== nothing
        remaining = deadline - monotonic()
        remaining > 0 || fail("systemd owner operation exceeded its deadline")
        timeout = min(timeout, remaining)
    end
    Common.run_checked(argv; timeout, maximum_output_bytes=64 * 1024)
end

function properties(unit::AbstractString; extra="", deadline=nothing)
    base = endswith(unit, ".target") ? "Id,LoadState,ActiveState,InvocationID" : SHOW_FIELDS
    fields = isempty(extra) ? base : base * "," * extra
    result = checked(["systemctl", "--user", "show", "--no-pager", "--property=" * fields, String(unit)]; deadline)
    result.returncode == 0 || fail("cannot query systemd unit $unit: $(strip(result.stderr))")
    values = parse_properties(result.stdout)
    for field in split(fields, ',')
        haskey(values, field) || fail("missing systemd property $field for $unit")
    end
    if endswith(unit, ".target") # Targets own jobs, not processes or cgroups.
        values["MainPID"] = "0"
        values["ControlGroup"] = ""
    end
    get(values, "Id", "") == unit || fail("systemd returned a different unit identity for $unit")
    return values
end

function parse_properties(output::AbstractString)
    values = Dict{String,String}()
    for line in split(output, '\n'; keepempty=false)
        pair = split(line, '='; limit=2)
        length(pair) == 2 || fail("malformed systemd property output")
        haskey(values, pair[1]) && fail("duplicate systemd property $(pair[1])")
        values[pair[1]] = pair[2]
    end
    return values
end

function proc_cgroup(pid::Integer)
    for line in eachline("/proc/$pid/cgroup")
        startswith(line, "0::/") && return line[4:end]
    end
    fail("unified cgroup unavailable for process $pid")
end

function start_ticks(pid::Integer)
    stat = read("/proc/$pid/stat", String)
    close = findlast(')', stat)
    close === nothing && fail("malformed process stat for $pid")
    fields = split(strip(stat[nextind(stat, close):end]))
    length(fields) >= 20 || fail("incomplete process stat for $pid")
    value = tryparse(UInt64, fields[20]) # Field 22, after pid and comm.
    value === nothing && fail("invalid process start time for $pid")
    return value
end

function process_identity(pid::Integer, ticks::UInt64, group::AbstractString)
    old_process_exists(pid, ticks) || return false
    try
        observed = proc_cgroup(pid)
        return (observed == group || startswith(observed, group * "/")) && old_process_exists(pid, ticks)
    catch error
        (error isa IOError || error isa SystemError) && return false
        rethrow()
    end
end

function old_process_exists(pid::Integer, ticks::UInt64)
    pid > 0 && isfile("/proc/$pid/stat") || return false
    try
        return start_ticks(pid) == ticks
    catch error
        (error isa IOError || error isa SystemError) && return false
        rethrow()
    end
end

function maybe_start_ticks(pid::Integer)
    pid > 0 && isfile("/proc/$pid/stat") || return nothing
    try
        return start_ticks(pid)
    catch error
        (error isa IOError || error isa SystemError) && return nothing
        rethrow()
    end
end

function parsed_pid(values)
    value = tryparse(Int, values["MainPID"])
    value !== nothing && value > 0 || fail("owner systemd MainPID is unavailable")
    return value
end

function retain!(service::Service, values)
    values["LoadState"] == "loaded" || fail("owner unit did not load")
    group = values["ControlGroup"]
    startswith(group, "/") && group != "/" || fail("owner cgroup is unavailable")
    invocation = valid_invocation(values["InvocationID"])
    service.invocation = invocation
    service.cgroup = group
    main = parsed_pid(values)
    ticks = start_ticks(main)
    observed = proc_cgroup(main)
    (observed == group || startswith(observed, group * "/")) || fail("owner MainPID lies outside its unit cgroup")
    service.main_pid = main
    service.start_ticks = ticks
    service.state = :running
    return service
end

function validate_placement(placement)
    placement isa AbstractDict || fail("owner placement contract must be a mapping")
    cpus = get(placement, "cpus", nothing)
    cpu = get(placement, "leader-cpu", nothing)
    cpus isa AbstractVector && !isempty(cpus) && all(x -> typeof(x) === Int && x >= 2, cpus) &&
        length(unique(cpus)) == length(cpus) && typeof(cpu) === Int && cpu in cpus ||
        fail("invalid owner CPU envelope or leader")
    return cpu, sort(cpus)
end

pid(service::Service) = service.main_pid
function failure(service::Service)
    if isempty(service.error) && service.state == :running && !alive(service)
        detail = "owner process identity exited or left its cgroup"
        try
            values = properties(service.unit; extra="Result,ExecMainCode,ExecMainStatus")
            detail *= "; Result=$(values["Result"]), ExecMainCode=$(values["ExecMainCode"]), ExecMainStatus=$(values["ExecMainStatus"])"
        catch error
            detail *= "; systemd result unavailable: " * sprint(showerror, error)
        end
        service.error = detail
    end
    return service.error
end
function record(service::Service)
    Dict{String,Any}("unit" => service.unit, "pid" => service.main_pid,
        "invocation" => service.invocation, "start-ticks" => service.start_ticks,
        "cgroup" => service.cgroup, "state" => String(service.state), "error" => service.error)
end

function alive(service::Service)
    service.state == :running || return false
    process_identity(service.main_pid, service.start_ticks, service.cgroup)
end

function verify!(service::Service)
    service.state == :running || fail("owner service has no retained running identity")
    values = properties(service.unit)
    values["LoadState"] == "loaded" && values["ActiveState"] == "active" &&
        same_incarnation(service, values) && tryparse(Int, values["MainPID"]) == service.main_pid &&
        alive(service) ||
        fail("owner systemd identity differs from retained incarnation")
    return service
end

function same_incarnation(service::Service, values)
    lowercase(get(values, "InvocationID", "")) == service.invocation &&
        get(values, "ControlGroup", "") == service.cgroup &&
        tryparse(Int, get(values, "MainPID", "")) in (0, service.main_pid)
end

function parse_populated(output::AbstractString)
    found = nothing
    for line in split(output, '\n'; keepempty=false)
        parts = split(line)
        if length(parts) == 2 && parts[1] == "populated"
            found === nothing || fail("duplicate cgroup populated field")
            parts[2] in ("0", "1") || fail("invalid cgroup populated field")
            found = parts[2] == "1"
        end
    end
    found === nothing && fail("cgroup.events has no populated field")
    return found
end

function cgroup_empty(group::AbstractString)
    startswith(group, "/") && group != "/" && !any(==(".."), splitpath(group)) ||
        fail("unsafe cgroup identity")
    path = joinpath("/sys/fs/cgroup", lstrip(group, '/'), "cgroup.events")
    isfile(path) || return true
    return !parse_populated(read(path, String))
end

function wait_empty(group, deadline)
    while monotonic() < deadline
        cgroup_empty(group) && return true
        sleep(min(0.05, max(0, deadline - monotonic())))
    end
    return cgroup_empty(group)
end

function stop_impl!(service::Service, grace::Real)
    isfinite(grace) && grace >= 0 || fail("invalid owner exit grace")
    service.state == :stopped && return nothing
    service.state == :pending && return nothing
    deadline = monotonic() + grace
    while alive(service) && monotonic() < deadline
        sleep(min(0.05, max(0, deadline - monotonic())))
    end
    values = properties(service.unit)
    if isempty(service.invocation)
        if quiescent_unit(service.unit) &&
                !any(pair -> pair.second == service.unit, listed_jobs(service.coordinator.invocation))
            service.state = :stopped
            return nothing
        end
        service.state = :uncertain
        fail("owner launch identity was never retained; refusing to stop uncertain unit")
    end
    quiet = values["LoadState"] == "not-found" ||
        (values["ActiveState"] in ("inactive", "failed") && values["MainPID"] == "0" &&
         (isempty(values["InvocationID"]) || lowercase(values["InvocationID"]) == service.invocation))
    if quiet
        if !old_process_exists(service.main_pid, service.start_ticks) && cgroup_empty(service.cgroup) &&
                !any(pair -> pair.second == service.unit, listed_jobs(service.coordinator.invocation))
            service.state = :stopped
            return nothing
        end
        fail("owner unit is inactive while its retained process, cgroup or start job remains")
    end
    same_incarnation(service, values) ||
        fail("owner unit incarnation changed; refusing to stop it")
    result = checked(["systemctl", "--user", "stop", service.unit]; timeout=20)
    result.returncode == 0 || fail("systemd failed to stop owner $(service.unit)")
    wait_empty(service.cgroup, monotonic() + 16) || fail("owner cgroup remains populated after stop")
    old_process_exists(service.main_pid, service.start_ticks) &&
        fail("owner MainPID survived outside the retained cgroup")
    service.state = :stopped
    return nothing
end

function stop!(service::Service, grace::Real=0)
    try
        return stop_impl!(service, grace)
    catch error
        service.state = :stop_failed
        service.error = sprint(showerror, error)
        rethrow()
    end
end

function listed_units(invocation; deadline=nothing)
    result = checked(["systemctl", "--user", "list-units", "--all", "--plain", "--no-legend", "--no-pager",
        PREFIX * invocation * "-*.service"]; deadline)
    result.returncode == 0 || fail("cannot list invocation owner units")
    return parse_units(result.stdout, invocation)
end

function parse_units(output, invocation)
    prefix = PREFIX * invocation * "-"
    units = String[]
    for line in split(output, '\n'; keepempty=false)
        fields = split(strip(line))
        isempty(fields) && continue
        name = fields[1] == "●" && length(fields) > 1 ? fields[2] : fields[1]
        startswith(name, prefix) && endswith(name, ".service") || continue
        role = name[length(prefix)+1:end-length(".service")]
        occursin(ROLE, role) && push!(units, name)
    end
    return unique(units)
end

function listed_jobs(invocation; deadline=nothing)
    result = checked(["systemctl", "--user", "list-jobs", "--all", "--plain", "--no-legend", "--no-pager"]; deadline)
    result.returncode == 0 || fail("cannot list invocation start jobs")
    return parse_jobs(result.stdout, invocation)
end

function parse_jobs(output, invocation)
    prefix = PREFIX * invocation * "-"
    jobs = Pair{String,String}[]
    for line in split(output, '\n'; keepempty=false)
        fields = split(strip(line))
        length(fields) >= 3 || continue
        job, name, operation = fields[1:3]
        occursin(r"^[0-9]+$", job) && startswith(name, prefix) &&
            (endswith(name, ".service") || name == cohort_name(invocation)) || continue
        if name == cohort_name(invocation)
            operation == "start" && push!(jobs, job => name)
        else
            role = name[length(prefix)+1:end-length(".service")]
            occursin(ROLE, role) && operation == "start" && push!(jobs, job => name)
        end
    end
    return jobs
end

function cancel_job(job; deadline=nothing)
    result = checked(["systemctl", "--user", "cancel", job]; timeout=5, deadline)
    result.returncode == 0 && return nothing
    # A job can finish between listing and cancellation.
    current = checked(["systemctl", "--user", "list-jobs", "--all", "--plain", "--no-legend", "--no-pager"]; deadline)
    current.returncode == 0 || fail("cannot recheck owner start job $job")
    any(line -> startswith(strip(line), job * " "), split(current.stdout, '\n')) &&
        fail("cannot cancel owner start job $job")
    return nothing
end

function cleanup_unit(unit; deadline=nothing)
    values = properties(unit; deadline)
    values["LoadState"] == "not-found" && return nothing
    group = values["ControlGroup"]
    if values["ActiveState"] in ("inactive", "failed") && isempty(group) && values["MainPID"] == "0"
        return nothing
    end
    if isempty(group) && values["MainPID"] == "0"
        result = checked(["systemctl", "--user", "stop", unit]; timeout=20, deadline)
        result.returncode == 0 || fail("cleanup could not stop $unit")
        quiescent_unit(unit; deadline) || fail("cleanup cannot establish quiescence for $unit")
        return nothing
    end
    startswith(group, "/") && group != "/" || fail("cleanup cannot establish cgroup for $unit")
    last(splitpath(group)) == unit || fail("cleanup found an unexpected cgroup for $unit")
    main = tryparse(Int, values["MainPID"])
    ticks = main === nothing ? nothing : maybe_start_ticks(main)
    result = checked(["systemctl", "--user", "stop", unit]; timeout=20, deadline)
    result.returncode == 0 || fail("cleanup could not stop $unit")
    wait_empty(group, min(monotonic() + 16, something(deadline, Inf))) ||
        fail("cleanup found populated cgroup for $unit")
    ticks === nothing || !old_process_exists(main, ticks) ||
        fail("cleanup found surviving MainPID for $unit")
    return nothing
end

function quiescent_unit(unit; deadline=nothing)
    values = properties(unit; deadline)
    values["LoadState"] == "not-found" && return true
    values["ActiveState"] in ("inactive", "failed") && values["MainPID"] == "0" || return false
    group = values["ControlGroup"]
    isempty(group) || cgroup_empty(group)
end

include("systemd_units.jl")
include("systemd_unit_files.jl")

end
