module HeartOwner

using JSON3, Sockets
using ..Common
using ..Placement

export read_requirements, read_placement, validate_placement, acknowledged,
    guard_port, listener_ready, thread_snapshot, Owner, response, control,
    start, stop, run, arguments, main

const MAX_REQUEST_BYTES = 16 * 1024
const MAX_REPLY_BYTES = 64 * 1024
const COMMAND_TIMEOUT = 5.0
const START_TIMEOUT = 30.0
const STOP_TIMEOUT = 5.0
const RESET_TIMEOUT = 12.0
const POLL_SECONDS = 0.005
monotonic() = time_ns() / 1.0e9
const GMS_SECTIONS = Dict("clwcBlock" => "CLWFC", "tfcBlock" => "TFC")

function remaining_timeout(deadline, maximum)
    deadline === nothing && return maximum
    remaining = deadline - monotonic()
    remaining > 0 || throw(ErrorException("HEART reset exceeded its absolute deadline"))
    min(maximum, remaining)
end

function write_json_atomic(path, value)
    bytes = JSON3.write(value) * "\n"
    ncodeunits(bytes) <= MAX_REPLY_BYTES || throw(ArgumentError("response exceeds 64 KiB"))
    Common.write_json(path, value; atomic=true)
end

acknowledged(code, output) = code == 0 && occursin("ack<0><ACCEPTED>", output) &&
    occursin("status<0><SUCCESS>", output)

function guard_port()
    for address in (ip"0.0.0.0", ip"::")
        server = listen(address, 5001)
        close(server)
    end
end

function listener_ready(process::Base.Process)
    process_running(process) || error("HEART child exited with $(process.exitcode)")
    descriptors = "/proc/$(getpid(process))/fd"
    isdir(descriptors) || return false
    sockets = Set{String}()
    for descriptor in readdir(descriptors; join=true)
        link = try readlink(descriptor) catch; continue end
        startswith(link, "socket:[") && push!(sockets, link[9:end-1])
    end
    for table in ("/proc/net/tcp", "/proc/net/tcp6")
        lines = readlines(table)
        for line in lines[2:end]
            fields = split(line)
            if length(fields) >= 10 && fields[4] == "0A" &&
                parse(Int, split(fields[2], ':')[end]; base=16) == 5001 && fields[10] in sockets
                return true
            end
        end
    end
    false
end

function read_requirements(path)
    data = Common.read_json(path; maximum=MAX_REPLY_BYTES)
    requirements = get(data, "runtime_requirements", nothing)
    requirements isa AbstractVector || throw(ArgumentError("requirements must contain runtime_requirements"))
    flags = Tuple{String,String,Int}[]
    blocks = Dict{String,Any}()
    for requirement in requirements
        requirement isa AbstractDict || throw(ArgumentError("runtime requirement must be an object"))
        haskey(requirement, "block") || continue
        block = requirement["block"]
        haskey(GMS_SECTIONS, block) && get(requirement, "control", nothing) == "ENABLE_HRT_FLAGS" ||
            throw(ArgumentError("unsupported HEART runtime requirement"))
        values = get(requirement, "flags", nothing)
        !haskey(blocks, block) && values isa AbstractDict && !isempty(values) ||
            throw(ArgumentError("missing or repeated HEART flag block"))
        blocks[block] = values
        for (field, value) in values
            field isa String && occursin(r"^enable[A-Za-z0-9_]*$", field) &&
                ncodeunits(field) <= 128 && typeof(value) === Int && value in (0, 1) ||
                throw(ArgumentError("invalid HEART flag"))
            push!(flags, (GMS_SECTIONS[block], field, value))
        end
    end
    required = Dict("clwcBlock" => Dict("enableClippingFeedback" => 1,
            "enableNotClearingIntg" => 0),
        "tfcBlock" => Dict("enableInHoVect" => 1, "enableOutDmErrs" => 1))
    for (block, expected) in required
        all(get(get(blocks, block, Dict()), field, nothing) == value for (field, value) in expected) ||
            throw(ArgumentError("requirements omit meaningful matched Classic correction flags"))
    end
    flags
end

function thread_snapshot(pid::Integer)
    directory = "/proc/$pid/task"
    before = sort!(parse.(Int, readdir(directory)))
    threads = Dict{String,Any}[]
    for tid in before
        cpus = Placement.cpus_from_list(Placement.proc_field("$directory/$tid/status", "Cpus_allowed_list"))
        policy, priority = Placement.scheduler(tid)
        push!(threads, Dict("tid" => tid, "name" => strip(read("$directory/$tid/comm", String)),
            "cpus" => cpus, "policy" => policy, "priority" => priority))
    end
    before == sort!(parse.(Int, readdir(directory))) ||
        error("HEART thread set changed during placement observation")
    threads
end

function read_placement(path)
    path === nothing && return nothing
    data = Common.read_json(path; maximum=MAX_REPLY_BYTES)
    data isa AbstractDict && isempty(setdiff(Set(keys(data)),
        Set(["cpus", "workers", "allowed_priorities"]))) ||
        throw(ArgumentError("invalid HEART placement declaration"))
    cpus = Placement.cpu_set(get(data, "cpus", nothing))
    priorities = get(data, "allowed_priorities", [5, 10, 15, 20])
    priorities isa AbstractVector && !isempty(priorities) &&
        all(value -> typeof(value) === Int && value in (5, 10, 15, 20), priorities) ||
        throw(ArgumentError("invalid HEART allowed FIFO priorities"))
    data["allowed_priorities"] = priorities
    workers = get(data, "workers", nothing)
    workers isa AbstractVector || throw(ArgumentError("HEART placement workers must be a list"))
    names = Set{String}()
    for worker in workers
        worker isa AbstractDict && Set(keys(worker)) == Set(["name", "cpus", "policy", "priority"]) ||
            throw(ArgumentError("invalid HEART worker placement"))
        name = worker["name"]
        name isa String && !isempty(name) && ncodeunits(name) <= 15 && !(name in names) &&
            Placement.cpu_set(worker["cpus"]) ⊆ cpus &&
            typeof(worker["policy"]) === Int && typeof(worker["priority"]) === Int &&
            (worker["policy"], worker["priority"]) in
                vcat([(0, 0)], [(1, value) for value in priorities]) ||
            throw(ArgumentError("invalid HEART worker placement"))
        push!(names, name)
    end
    data
end

function validate_placement(threads, declaration)
    envelope = Set(declaration["cpus"])
    policies = Set(vcat([(0, 0)], [(1, value) for value in declaration["allowed_priorities"]]))
    for thread in threads
        !isempty(thread["cpus"]) && Set(thread["cpus"]) ⊆ envelope ||
            error("HEART thread $(thread["name"]) affinity exceeds declared CPUs")
        (thread["policy"], thread["priority"]) in policies ||
            error("HEART thread $(thread["name"]) scheduling policy/priority differs")
    end
    for worker in declaration["workers"]
        matches = filter(thread -> thread["name"] == worker["name"], threads)
        length(matches) == 1 || error("HEART worker $(worker["name"]) must match exactly one native thread")
        thread = only(matches)
        Set(thread["cpus"]) == Set(worker["cpus"]) &&
            thread["policy"] == worker["policy"] && thread["priority"] == worker["priority"] ||
            error("HEART worker $(worker["name"]) placement differs")
    end
    nothing
end

mutable struct Owner
    options::NamedTuple
    source_config_sha256::String
    flags::Vector{Tuple{String,String,Int}}
    placement::Any
    child::Any
    child_log::Any
    generation::Int
    last_id::Int
    last_payload::Any
    last_reply::Any
    stopping::Bool
    status_path::String
end

function Owner(options::NamedTuple)
    Owner(options, Common.sha256_file(options.config), read_requirements(options.requirements),
        read_placement(get(options, :placement, nothing)), nothing, nothing, 0, 0,
        nothing, nothing, false, joinpath(options.runtime, "heart-owner-status.json"))
end

function report(owner::Owner, error_message=nothing)
    threads = Dict{String,Any}[]
    observation_error = nothing
    if owner.child !== nothing && process_running(owner.child)
        try
            threads = thread_snapshot(getpid(owner.child))
        catch error
            observation_error = sprint(showerror, error)
        end
    end
    write_json_atomic(owner.status_path, Dict{String,Any}(
        "version" => 1, "owner_pid" => getpid(),
        "child_pid" => owner.child === nothing ? nothing : getpid(owner.child),
        "child_returncode" => owner.child === nothing || process_running(owner.child) ? nothing : owner.child.exitcode,
        "generation" => owner.generation, "native_threads" => threads,
        "placement_observation_error" => observation_error,
        "placement_validated" => owner.placement !== nothing && error_message === nothing,
        "placement_declaration" => owner.placement,
        "source_config" => owner.options.config,
        "source_config_sha256" => owner.source_config_sha256,
        "rendered_config" => joinpath(owner.options.runtime, "config/heart.yaml"),
        "state" => error_message === nothing ? "paused" : "failed", "sequence" => 0,
        "completed" => false, "error" => error_message,
        "flag_verification" => "command SUCCESS acknowledgements only; no effective readback"))
end

function command(owner::Owner, name; flag=nothing, required=true, deadline=nothing)
    required && (owner.stopping || ispath(owner.options.quit_request)) &&
        error("HEART command interrupted by owner shutdown")
    argv = [owner.options.client, "-cmdName", name, "-address", "127.0.0.1", "-port", "5001"]
    if flag !== nothing
        section, field, value = flag
        append!(argv, ["-configEnableHrtFlag", string(value),
            "-configEnableHrtFlagField", field, "-configEnableHrtFlagSec", section])
    end
    suffix = flag === nothing ? "" : "-" * join(flag, "-")
    log = joinpath(owner.options.runtime, "command-$(owner.generation)-$name$suffix.log")
    errlog = log * ".stderr"
    result = Common.run_checked(argv; cwd=owner.options.runtime,
        stdout_path=log, stderr_path=errlog,
        timeout=remaining_timeout(deadline, COMMAND_TIMEOUT))
    output = result.stdout * result.stderr
    text = ncodeunits(output) > MAX_REPLY_BYTES ? last(output, MAX_REPLY_BYTES) : output
    success = acknowledged(result.returncode, text)
    required && !success && error("HEART $name did not acknowledge SUCCESS; see $log")
    success
end

function start(owner::Owner; deadline=nothing)
    remaining_timeout(deadline, START_TIMEOUT)
    guard_port()
    owner.generation += 1
    owner.child_log = open(joinpath(owner.options.runtime, "heart-$(owner.generation).log"), "a")
    env = Dict{String,String}(ENV)
    env["HRT_CPU_MACHINE_FILE"] = joinpath(owner.options.runtime, "config/host.cpu")
    env["HRT_THREAD_MAP_FILE"] = joinpath(owner.options.runtime, "config/host.threads")
    child_cmd = Cmd(Cmd([owner.options.executable, "-shm", "-config",
        joinpath(owner.options.runtime, "config/heart.yaml")]); dir=owner.options.runtime)
    owner.child = Base.run(pipeline(setenv(child_cmd, env); stdin=devnull,
        stdout=owner.child_log, stderr=owner.child_log); wait=false)
    listener_deadline = monotonic() + remaining_timeout(deadline, START_TIMEOUT)
    while !listener_ready(owner.child)
        (owner.stopping || ispath(owner.options.quit_request)) &&
            error("HEART preparation interrupted")
        monotonic() < listener_deadline || error("HEART command listener timed out")
        sleep(POLL_SECONDS)
    end
    command(owner, "INIT"; deadline)
    command(owner, "RUN"; deadline)
    for flag in owner.flags
        command(owner, "ENABLE_HRT_FLAGS"; flag, deadline)
    end
    command(owner, "CORRECT"; deadline)
    process_running(owner.child) || error("HEART child exited with $(owner.child.exitcode)")
    placement_deadline = monotonic() + remaining_timeout(deadline, 2.0)
    threads = nothing
    while threads === nothing
        try
            threads = thread_snapshot(getpid(owner.child))
        catch error
            (!process_running(owner.child) || monotonic() >= placement_deadline) && rethrow()
            sleep(POLL_SECONDS)
        end
    end
    owner.placement !== nothing && validate_placement(threads, owner.placement)
    remaining_timeout(deadline, COMMAND_TIMEOUT)
    report(owner)
    remaining_timeout(deadline, COMMAND_TIMEOUT)
end

function _wait_child(child::Base.Process, timeout)
    deadline = monotonic() + timeout
    while process_running(child) && monotonic() < deadline
        sleep(0.01)
    end
    !process_running(child)
end

function stop(owner::Owner; deadline=nothing)
    child = owner.child
    try
        if child !== nothing && process_running(child)
            try
                listener_ready(child) && command(owner, "SHUTDOWN"; required=false, deadline)
            catch
            end
            if !_wait_child(child, remaining_timeout(deadline, STOP_TIMEOUT))
                kill(child, Base.SIGTERM)
                if !_wait_child(child, remaining_timeout(deadline, STOP_TIMEOUT))
                    kill(child, Base.SIGKILL)
                    _wait_child(child, remaining_timeout(deadline, STOP_TIMEOUT)) ||
                        error("HEART child did not exit after SIGKILL")
                end
            end
            wait(child)
        elseif child !== nothing
            wait(child)
        end
    catch error
        if child !== nothing && process_running(child)
            kill(child, Base.SIGKILL)
            _wait_child(child, 1) && wait(child)
        end
        rethrow(error)
    finally
        if owner.child_log !== nothing
            close(owner.child_log)
            owner.child_log = nothing
        end
    end
end

response(_, request_id, operation, error_message=nothing) = Dict{String,Any}(
    "version" => 1, "id" => request_id, "operation" => operation,
    "state" => "paused", "sequence" => 0, "completed" => false,
    "ok" => error_message === nothing, "error" => error_message)

function control(owner::Owner, payload::AbstractVector{UInt8})
    request_id, operation = 0, "invalid"
    request = try
        length(payload) <= MAX_REQUEST_BYTES || throw(ArgumentError("oversized"))
        Common.parse_json(String(payload))
    catch
        return response(owner, request_id, operation, "invalid JSON request")
    end
    request isa AbstractDict || return response(owner, request_id, operation, "invalid JSON request")
    raw_id = get(request, "id", nothing)
    raw_operation = get(request, "operation", nothing)
    typeof(raw_id) === Int && 1 <= raw_id <= typemax(Int64) && (request_id = raw_id)
    raw_operation isa String && ncodeunits(raw_operation) <= 32 && (operation = raw_operation)
    if Set(keys(request)) != Set(["version", "id", "operation"]) ||
        get(request, "version", nothing) !== 1 || request_id == 0 ||
        !(operation in ("reset", "status"))
        return response(owner, request_id, operation,
            "expected version 1, positive integer id and reset or status")
    end
    request_id > owner.last_id || return response(owner, request_id, operation, "stale request id")
    owner.last_id = request_id
    if operation == "reset"
        deadline = monotonic() + RESET_TIMEOUT
        try
            stop(owner; deadline)
            start(owner; deadline)
        catch
            try stop(owner; deadline=monotonic()) catch end
            rethrow()
        end
    else
        report(owner)
    end
    response(owner, request_id, operation)
end

function run(owner::Owner)
    start(owner)
    write_json_atomic(owner.options.prepared_event,
        Dict("version" => 1, "state" => "prepared", "sequence" => 0))
    connected = false
    while !owner.stopping && !ispath(owner.options.quit_request)
        process_running(owner.child) ||
            error("HEART child exited unexpectedly with $(owner.child.exitcode)")
        if !connected && ispath(owner.options.connect_request)
            write_json_atomic(owner.options.connect_reply,
                Dict("version" => 1, "state" => "connected", "sequence" => 0))
            connected = true
        end
        if isfile(owner.options.control_request)
            payload = open(owner.options.control_request) do io
                read(io, MAX_REQUEST_BYTES + 1)
            end
            if payload != owner.last_payload
                owner.last_payload = payload
                owner.last_reply = control(owner, payload)
                write_json_atomic(owner.options.control_reply, owner.last_reply)
            end
        end
        sleep(POLL_SECONDS)
    end
end

function arguments(argv=ARGS)
    names = ["executable", "client", "config", "requirements", "runtime", "prepared-event",
        "connect-request", "connect-reply", "quit-request", "control-request", "control-reply",
        "cpu-map", "thread-map"]
    raw = Common.cli_arguments(argv; required=names,
        allowed=["package", "calibration-root", "placement"])
    option_values = Dict{Symbol,Any}(name => abspath(value) for (name, value) in pairs(raw))
    if !haskey(option_values, :package)
        option_values[:package] = dirname(dirname(realpath(option_values[:config])))
    end
    options = (; option_values...)
    for name in (:prepared_event, :connect_request, :connect_reply,
        :quit_request, :control_request, :control_reply)
        islink(getproperty(options, name)) &&
            throw(ArgumentError("instance path is a symlink: $(getproperty(options, name))"))
    end
    inputs = [options.executable, options.client, options.config, options.requirements,
        options.cpu_map, options.thread_map]
    outputs = [options.prepared_event, options.connect_request, options.connect_reply,
        options.quit_request, options.control_request, options.control_reply,
        joinpath(options.runtime, "heart-owner-status.json")]
    reserved = [joinpath(options.runtime, "config", name) for name in
        ("heart.yaml", "host.cpu", "host.threads")]
    length(unique(outputs)) == length(outputs) && isempty(intersect(Set(inputs), Set(outputs))) &&
        isempty(intersect(Set(outputs), Set(reserved))) ||
        throw(ArgumentError("input, marker, control and report paths must differ"))
    all(isfile, inputs) || throw(ArgumentError("required file is missing"))
    for path in (options.executable, options.client)
        (stat(path).mode & 0o111) != 0 || throw(ArgumentError("required executable is not executable: $path"))
    end
    all(path -> !ispath(path) && !islink(path), outputs) ||
        throw(ArgumentError("instance path already exists"))
    !ispath(options.runtime) && !islink(options.runtime) ||
        throw(ArgumentError("instance runtime already exists"))
    mkdir(options.runtime)
    config_dir = joinpath(options.runtime, "config")
    mkdir(config_dir)
    cp(options.cpu_map, joinpath(config_dir, "host.cpu"))
    cp(options.thread_map, joinpath(config_dir, "host.threads"))
    calibration_root = get(options, :calibration_root, nothing)
    if calibration_root !== nothing
        isdir(calibration_root) || throw(ArgumentError("calibration root must be a directory"))
        for source in sort!(readdir(calibration_root; join=true))
            target = joinpath(config_dir, basename(source))
            isfile(source) && dirname(realpath(source)) == realpath(calibration_root) &&
                !ispath(target) && basename(source) != "heart.yaml" ||
                throw(ArgumentError("invalid or conflicting calibration file: $source"))
            symlink(realpath(source), target)
        end
    end
    configuration = read(options.config, String)
    if occursin("@PACKAGE@", configuration)
        package = options.package
        any(character -> character in ('"', '\\') || Int(character) < 32 || Int(character) == 127,
            package) && throw(ArgumentError("HEART package substitution cannot contain quote, backslash or control characters"))
        configuration = replace(configuration, "@PACKAGE@" => package)
    end
    for m in eachmatch(r"\"([^\"\n]*)\"", configuration)
        ncodeunits(m.captures[1]) < 128 ||
            throw(ArgumentError("HEART quoted configuration scalar must be shorter than 128 bytes"))
    end
    occursin(r"@[A-Z][A-Z_]*@", configuration) &&
        throw(ArgumentError("unresolved HEART configuration binding"))
    write(joinpath(config_dir, "heart.yaml"), configuration)
    options
end

function main(argv=ARGS)
    owner = nothing
    Base.exit_on_sigint(false)
    try
        owner = Owner(arguments(argv))
        atexit() do
            if owner !== nothing && owner.child !== nothing && process_running(owner.child)
                try stop(owner) catch end
            end
        end
        run(owner)
        return 0
    catch error
        error isa InterruptException && return 0
        if owner !== nothing
            rm(owner.options.prepared_event; force=true)
            rm(owner.options.connect_reply; force=true)
            report(owner, sprint(showerror, error))
            write_json_atomic(owner.options.control_reply,
                response(owner, owner.last_id, "failure", sprint(showerror, error)))
        end
        println(stderr, "HEART owner failed: ", sprint(showerror, error))
        return 1
    finally
        owner !== nothing && stop(owner)
    end
end

end
