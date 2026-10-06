module HeartOwner

using JSON3, Sockets, PipeWireAO
using ..Common
using ..Placement
import ..NativeControlClient
import ..NativeControlEndpoint
import ..NativeControlCodec
import ..NativeHeartCodec

export read_requirements, read_placement, validate_placement, acknowledged,
    guard_port, listener_ready, thread_snapshot, Owner,
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
const Codec = NativeHeartCodec
const Endpoint = NativeControlEndpoint
const Commands = Union{Codec.HeartCommand{:status},Codec.HeartCommand{:reset},
    Codec.HeartCommand{:connect},Codec.HeartCommand{:shutdown}}

struct NativeRuntime{C,E}
    loop::ThreadLoop
    context::Context
    core::C
    endpoint::E
    acknowledged_sequence::Base.RefValue{Cint}
end

function NativeRuntime(remote, name, instance::Int64)
    loop = ThreadLoop("rtc.heart.owner")
    context = core = endpoint = nothing
    endpoint_ref = Ref{Union{Nothing,Endpoint.Endpoint}}(nothing)
    acknowledged_sequence = Ref{Cint}(-1)
    connection_failure = Ref{Union{Nothing,String}}(nothing)
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name"=>remote),
                on_done=(core, id, sequence) -> (id == 0 && (acknowledged_sequence[] = sequence); nothing),
                on_error=(core, id, sequence, error) -> begin
                    connection_failure[] = sprint(showerror, error)
                    current = endpoint_ref[]
                    current === nothing || (current.failure = connection_failure[])
                    nothing
                end)
            endpoint = Endpoint.Endpoint(Codec.HEART_PROFILE, Commands, loop, core,
                name, instance, Codec.Preparing)
            endpoint_ref[] = endpoint
            connection_failure[] === nothing || (endpoint.failure = connection_failure[])
        end
        start!(loop)
        return NativeRuntime(loop, context, core, endpoint, acknowledged_sequence)
    catch primary
        failures = Exception[primary]
        with_thread_loop_lock(loop) do _
            for resource in (endpoint, core, context)
                resource === nothing && continue
                try close(resource) catch cleanup; push!(failures, cleanup) end
            end
        end
        try close(loop) catch cleanup; push!(failures, cleanup) end
        length(failures) == 1 && rethrow()
        throw(CompositeException(failures))
    end
end

function Base.close(runtime::NativeRuntime)
    failures = Exception[]
    with_thread_loop_lock(runtime.loop) do _
        for resource in (runtime.endpoint, runtime.core, runtime.context)
            try close(resource) catch error; push!(failures, error) end
        end
    end
    try close(runtime.loop) catch error; push!(failures, error) end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

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
    stopping::Bool
    status_path::String
    ingress_environment::Union{Nothing,String}
    native::Union{Nothing,NativeRuntime}
    active_ticket::Union{Nothing,Endpoint.Ticket{Commands}}
    generation_report::String
    generation_report_sha256::String
    child_pid::Union{Nothing,UInt32}
end

function Owner(options::NamedTuple)
    Owner(options, Common.sha256_file(options.config), read_requirements(options.requirements),
        read_placement(get(options, :placement, nothing)), nothing, nothing, 0,
        false, joinpath(options.runtime, "heart-owner-status.json"), nothing,
        nothing, nothing, "", "", nothing)
end

function require_control(owner::Owner)
    owner.native === nothing && return nothing
    if owner.active_ticket === nothing
        Endpoint.poll!(owner.native.endpoint)
    else
        Endpoint.check_ticket(owner.native.endpoint, owner.active_ticket)
    end
    return nothing
end

function seal_generation!(owner::Owner)
    destination = joinpath(realpath(owner.options.runtime), "heart-generation-$(owner.generation).json")
    !ispath(destination) && !islink(destination) || error("HEART generation report already exists")
    cp(owner.status_path, destination)
    owner.generation_report = destination
    owner.generation_report_sha256 = Common.sha256_file(destination)
    return nothing
end

function snapshot(owner::Owner)
    child = owner.child
    alive = child !== nothing && process_running(child)
    pid = owner.child_pid
    code = child === nothing || alive ? nothing : Int32(child.exitcode)
    ingress = get(owner.options, :native_ingress_mode, "streaming") == "streaming" ?
        Codec.Streaming : Codec.Deferred
    return Codec.HeartSnapshot(Int64(owner.generation), pid, code, alive, ingress,
        owner.placement !== nothing && alive,
        !get(owner.options, :native_wfs_proc_debug, false) &&
            get(owner.options, :native_debug_stdio_wrapper, nothing) === nothing,
        owner.generation_report, owner.generation_report_sha256)
end

function report(owner::Owner, error_message=nothing)
    threads = Dict{String,Any}[]
    observation_error = nothing
    if owner.child !== nothing && process_running(owner.child)
        try
            threads = thread_snapshot(owner.child_pid)
        catch error
            observation_error = sprint(showerror, error)
        end
    end
    write_json_atomic(owner.status_path, Dict{String,Any}(
        "version" => 1, "owner_pid" => getpid(),
        "child_pid" => owner.child_pid,
        "child_returncode" => owner.child === nothing || process_running(owner.child) ? nothing : owner.child.exitcode,
        "generation" => owner.generation, "native_threads" => threads,
        "placement_observation_error" => observation_error,
        "placement_validated" => owner.placement !== nothing && error_message === nothing,
        "placement_declaration" => owner.placement,
        "source_config" => owner.options.config,
        "source_config_sha256" => owner.source_config_sha256,
        "rendered_config" => joinpath(owner.options.runtime, "config/heart.yaml"),
        "native_ingress" => Dict("mode"=>get(owner.options, :native_ingress_mode, "streaming"),
            "environment_key"=>"HRT_DEFER_WFS_INGRESS", "observed_environment"=>owner.ingress_environment,
            "qualification"=>get(owner.options, :native_ingress_mode, "streaming") == "deferred" ?
                "comparison fixture; completion calibration only; ordinary streaming and cadence unqualified" : "ordinary streaming"),
        "native_diagnostics" => Dict("wfs_proc_debug"=>get(owner.options, :native_wfs_proc_debug, false),
            "stdio_wrapper"=>get(owner.options, :native_debug_stdio_wrapper, nothing),
            "stdio_wrapper_sha256"=>get(owner.options, :native_debug_stdio_wrapper, nothing) === nothing ? nothing :
                Common.sha256_file(owner.options.native_debug_stdio_wrapper),
            "child_argv"=>hasproperty(owner.options, :executable) ? child_arguments(owner.options) : nothing,
            "qualification"=>get(owner.options, :native_wfs_proc_debug, false) ?
                "diagnostic only; cadence and scientific acceptance excluded" : "diagnostics disabled"),
        "state" => error_message === nothing ? (owner.stopping ? "stopped" : "paused") : "failed", "sequence" => 0,
        "completed" => false, "error" => error_message,
        "flag_verification" => "command SUCCESS acknowledgements only; no effective readback"))
end

function command(owner::Owner, name; flag=nothing, required=true, deadline=nothing)
    required && require_control(owner)
    required && owner.stopping &&
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

function ingress_setting(mode)
    mode in ("streaming", "deferred") || throw(ArgumentError("native ingress mode must be streaming or deferred"))
    return mode == "deferred" ? "1" : "0"
end

function ingress_environment(bytes::AbstractString)
    ncodeunits(bytes) <= 1024 * 1024 || throw(ArgumentError("native child environment exceeds its bound"))
    entries = filter(entry -> startswith(entry, "HRT_DEFER_WFS_INGRESS="), split(bytes, '\0'))
    length(entries) == 1 || throw(ArgumentError("native child ingress environment is missing or repeated"))
    value = split(only(entries), '='; limit=2)[2]
    value in ("0", "1") || throw(ArgumentError("invalid native child ingress environment"))
    return String(value)
end

function child_environment(options, inherited=ENV)
    env = Dict{String,String}(inherited)
    env["HRT_CPU_MACHINE_FILE"] = joinpath(options.runtime, "config/host.cpu")
    env["HRT_THREAD_MAP_FILE"] = joinpath(options.runtime, "config/host.threads")
    env["HRT_DEFER_WFS_INGRESS"] = ingress_setting(get(options, :native_ingress_mode, "streaming"))
    return env
end

function child_arguments(options)
    argv = [options.executable, "-shm", "-config", joinpath(options.runtime, "config/heart.yaml")]
    if get(options, :native_wfs_proc_debug, false)
        append!(argv, ["-moduleDebug", "hrtWfsProcBlock_debugLevel", "-moduleDebugLevel", "4"])
    end
    wrapper = get(options, :native_debug_stdio_wrapper, nothing)
    wrapper === nothing || prepend!(argv, [wrapper, "-oL", "-eL"])
    return argv
end

function start(owner::Owner; deadline=nothing)
    require_control(owner)
    remaining_timeout(deadline, START_TIMEOUT)
    guard_port()
    owner.generation += 1
    owner.generation_report = ""
    owner.generation_report_sha256 = ""
    owner.child_log = open(joinpath(owner.options.runtime, "heart-$(owner.generation).log"), "a")
    env = child_environment(owner.options)
    owner.ingress_environment = nothing
    child_cmd = Cmd(Cmd(child_arguments(owner.options)); dir=owner.options.runtime)
    owner.child = Base.run(pipeline(setenv(child_cmd, env); stdin=devnull,
        stdout=owner.child_log, stderr=owner.child_log); wait=false)
    owner.child_pid = UInt32(getpid(owner.child))
    listener_deadline = monotonic() + remaining_timeout(deadline, START_TIMEOUT)
    while !listener_ready(owner.child)
        require_control(owner)
        owner.stopping &&
            error("HEART preparation interrupted")
        monotonic() < listener_deadline || error("HEART command listener timed out")
        sleep(POLL_SECONDS)
    end
    if get(owner.options, :native_debug_stdio_wrapper, nothing) !== nothing
        readlink("/proc/$(owner.child_pid)/exe") == realpath(owner.options.executable) ||
            error("supervised HEART child has not execed the declared native executable")
    end
    observed = ingress_environment(open(io -> String(read(io, 1024 * 1024 + 1)), "/proc/$(owner.child_pid)/environ"))
    observed == env["HRT_DEFER_WFS_INGRESS"] || error("native child ingress environment differs from selected mode")
    owner.ingress_environment = observed
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
            threads = thread_snapshot(owner.child_pid)
        catch error
            (!process_running(owner.child) || monotonic() >= placement_deadline) && rethrow()
            sleep(POLL_SECONDS)
        end
    end
    owner.placement !== nothing && validate_placement(threads, owner.placement)
    remaining_timeout(deadline, COMMAND_TIMEOUT)
    report(owner)
    seal_generation!(owner)
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

function apply!(owner::Owner, ::Codec.HeartCommand{:status}, ticket)
    require_control(owner)
    owner.child !== nothing && process_running(owner.child) || error("HEART child is absent")
    report(owner)
    return snapshot(owner)
end

function apply!(owner::Owner, ::Codec.HeartCommand{:reset}, ticket)
    require_control(owner)
    deadline = min(ticket.deadline, monotonic() + RESET_TIMEOUT)
    Endpoint.state!(owner.native.endpoint, Codec.Preparing)
    try
        stop(owner; deadline)
        require_control(owner)
        start(owner; deadline)
    catch
        try stop(owner; deadline=monotonic()) catch end
        rethrow()
    end
    Endpoint.state!(owner.native.endpoint, Codec.Ready)
    return snapshot(owner)
end

function apply!(owner::Owner, ::Codec.HeartCommand{:connect}, ticket)
    # The old connection marker was only an acknowledgement. The actual links
    # remain owned by the RTC runner; this operation grants no correction state.
    return apply!(owner, Codec.HeartCommand(:status), ticket)
end

function apply!(owner::Owner, ::Codec.HeartCommand{:shutdown}, ticket)
    require_control(owner)
    stop(owner; deadline=ticket.deadline)
    require_control(owner)
    owner.child === nothing || !process_running(owner.child) || error("HEART child remains alive")
    Endpoint.state!(owner.native.endpoint, Codec.Stopped)
    owner.stopping = true
    report(owner)
    return snapshot(owner)
end

"Flush the terminal publication before endpoint removal, within the same budget."
function flush_terminal!(owner::Owner, ticket)
    runtime = owner.native
    sequence = with_thread_loop_lock(runtime.loop) do _
        Endpoint.operational(runtime.endpoint)
        sync!(runtime.core)
    end
    while true
        observed = with_thread_loop_lock(runtime.loop) do _
            Endpoint.operational(runtime.endpoint)
            runtime.acknowledged_sequence[] == sequence
        end
        monotonic() < ticket.deadline || error("HEART terminal publication deadline expired")
        observed && return nothing
        sleep(min(POLL_SECONDS, max(0.0, ticket.deadline - monotonic())))
    end
end

function consume_native!(owner::Owner)
    endpoint = owner.native.endpoint
    ticket = Endpoint.take!(endpoint)
    ticket === nothing && return nothing
    owner.active_ticket = ticket
    try
        current = apply!(owner, ticket.command, ticket)
        header = NativeControlCodec.ReplyHeader(ticket.header.controller, endpoint.instance,
            ticket.header.token, ticket.header.operation, Int32(0))
        reply = NativeControlClient.encode_completion(Codec.HEART_PROFILE,
            header, endpoint.lifecycle, current, "")
        Endpoint.complete!(endpoint, ticket, reply)
        owner.stopping && flush_terminal!(owner, ticket)
    catch primary
        # The existing wrapper fails closed. A negative completion carries no
        # invented child facts if the effect did not leave a verified snapshot.
        try
            Endpoint.state!(endpoint, Codec.Fault)
            header = NativeControlCodec.ReplyHeader(ticket.header.controller, endpoint.instance,
                ticket.header.token, ticket.header.operation, Int32(-5))
            message = sprint(showerror, primary)
            message = first(message, min(length(message), 1024))
            if endpoint.pending === ticket
                Endpoint.complete!(endpoint, ticket, NativeControlClient.encode_completion(
                    Codec.HEART_PROFILE, header, Codec.Fault, nothing, message))
            end
        catch publication
            throw(CompositeException([primary, publication]))
        end
        rethrow()
    finally
        owner.active_ticket = nothing
    end
    return nothing
end

function run(owner::Owner)
    owner.native = NativeRuntime(owner.options.remote, owner.options.control_node,
        owner.options.control_instance)
    start(owner)
    Endpoint.state!(owner.native.endpoint, Codec.Ready)
    while !owner.stopping
        process_running(owner.child) ||
            error("HEART child exited unexpectedly with $(owner.child.exitcode)")
        consume_native!(owner)
        sleep(POLL_SECONDS)
    end
end

function arguments(argv=ARGS)
    names = ["executable", "client", "config", "requirements", "runtime",
        "remote", "control-node", "control-instance",
        "cpu-map", "thread-map"]
    raw = Common.cli_arguments(argv; required=names,
        allowed=["package", "calibration-root", "placement", "native-wfs-proc-debug", "native-debug-stdio-wrapper", "native-ingress-mode"])
    ingress_mode = get(raw, :native_ingress_mode, "streaming")
    ingress_setting(ingress_mode)
    instance = tryparse(Int64, raw.control_instance)
    instance !== nothing && instance > 0 || throw(ArgumentError("control instance must be positive"))
    occursin(r"^[a-zA-Z0-9_.-]{1,128}$", raw.control_node) || throw(ArgumentError("invalid HEART control node"))
    remote = NativeControlClient.private_remote(raw.remote)
    debug_option = get(raw, :native_wfs_proc_debug, "false")
    debug_option in ("true", "false") || throw(ArgumentError("native WFS processing debug must be true or false"))
    wrapper = get(raw, :native_debug_stdio_wrapper, nothing)
    if wrapper !== nothing
        debug_option == "true" || throw(ArgumentError("native stdio wrapper requires explicit diagnostic mode"))
        isfile(wrapper) && stat(wrapper).mode & 0o111 != 0 || throw(ArgumentError("native diagnostic stdio wrapper is unavailable"))
        basename(wrapper) == "stdbuf" || throw(ArgumentError("native diagnostic stdio wrapper must be stdbuf"))
        wrapper = realpath(wrapper)
    end
    option_values = Dict{Symbol,Any}(name => abspath(value) for (name, value) in pairs(raw)
        if !(name in (:native_wfs_proc_debug, :native_debug_stdio_wrapper, :native_ingress_mode,
            :remote, :control_node, :control_instance)))
    if !haskey(option_values, :package)
        option_values[:package] = dirname(dirname(realpath(option_values[:config])))
    end
    options = (; option_values..., remote, control_node=String(raw.control_node), control_instance=instance,
        native_ingress_mode=ingress_mode, native_wfs_proc_debug=debug_option == "true", native_debug_stdio_wrapper=wrapper)
    inputs = [options.executable, options.client, options.config, options.requirements,
        options.cpu_map, options.thread_map]
    outputs = [joinpath(options.runtime, "heart-owner-status.json")]
    reserved = [joinpath(options.runtime, "config", name) for name in
        ("heart.yaml", "host.cpu", "host.threads")]
    length(unique(outputs)) == length(outputs) && isempty(intersect(Set(inputs), Set(outputs))) &&
        isempty(intersect(Set(outputs), Set(reserved))) ||
        throw(ArgumentError("input and report paths must differ"))
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
            owner.native === nothing || try Endpoint.state!(owner.native.endpoint, Codec.Fault) catch end
            report(owner, sprint(showerror, error))
        end
        println(stderr, "HEART owner failed: ", sprint(showerror, error))
        return 1
    finally
        if owner !== nothing
            try
                stop(owner)
            finally
                owner.native === nothing || close(owner.native)
            end
        end
    end
end

end
