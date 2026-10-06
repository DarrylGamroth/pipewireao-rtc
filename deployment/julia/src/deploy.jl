module Deployment

using JSON3, Sockets, UUIDs, TOML
using ..Common
using ..Placement
using ..ScienceExport
import ..NativeSourceClient
import ..ObservationBoundary
import ..NativeRunnerClient
import ..NativeHeartClient
import ..NativeControlClient
import ..NativeAcquisitionLifecycleCodec
import ..NativeAcquisitionLifecycleClient
import ..RunnerCommands
import ..NativeRunnerCodec
import ..NativeSupervisorCodec
import ..NativeSupervisorClient
import ..NativeSupervisorRuntime
import ..NativeSessionDiscovery
import ..NativeSessionClient
import ..NativeControlEndpoint
import ..NativeControlCodec
import ..NativeHeartCodec
using PipeWireAO: with_thread_loop_lock

export DeploymentError, digest, installed_paths, decode, profile, relative_asset,
    substitute, control, atomic_record, validate_source_reply, validate_control_request,
    DeploymentRunner, preflight, run, source_control, wait_state, shutdown, install, main

const MAX_CONFIG_BYTES = 16 * 1024 * 1024
const MAX_REPLY_BYTES = 64 * 1024
const MAX_REQUEST_BYTES = 16 * 1024
# Match the generated service's stop allowance. Source revocation, public
# control replies and per-owner process-group cleanup each have finite bounds.
const CLEANUP_TIMEOUT_SECONDS = 300.0
monotonic() = time_ns() / 1.0e9
const INSTALLED_ENTRYPOINTS = Dict(
    "calibration_campaign" => "CalibrationCampaign",
    "calibration_method" => "CalibrationMethod",
    "copper_reference" => "CopperReference",
    "copper_quality" => "CopperQuality",
    "export_calibration" => "CalibrationExport",
    "export_hil" => "HILExport",
    "export_heart_hil" => "HeartExport",
    "export_heart_calibration" => "HeartCalibrationExport",
    "export_heart_correction" => "HeartCorrectionExport")
const REQUIRED_KEYS = Set(["version", "name", "session", "core", "client", "placement",
    "owners", "environment", "artifacts", "cpu-latency-us"])

struct DeploymentError <: Exception
    message::String
end
Base.showerror(io::IO, error::DeploymentError) = print(io, error.message)
fail(message) = throw(DeploymentError(message))
require(condition, message) = condition || fail(message)
digest(path::AbstractString) = Common.sha256_file(path)
atomic_record(path::AbstractString, value) = Common.write_json(path, value; atomic=true)

function installed_paths(prefix::AbstractString)
    candidates = [joinpath(prefix, "lib"), joinpath(prefix, "lib64")]
    lib = joinpath(prefix, "lib")
    isdir(lib) && append!(candidates, readdir(lib; join=true))
    libraries = filter(path -> isfile(joinpath(path, "libpipewire-ao-0.3.so")), candidates)
    length(libraries) == 1 || fail("expected one installed PipeWireAO library directory in $prefix")
    library = only(libraries)
    paths = Dict("library" => library, "modules" => joinpath(library, "pipewire-ao-0.3"),
        "spa" => joinpath(library, "spa-ao-0.2"), "daemon" => joinpath(prefix, "bin/pipewire-ao"),
        "parser" => joinpath(prefix, "bin/pwao-spa-json-dump"))
    for (label, path) in paths
        ispath(path) || fail("missing installed $label: $path")
    end
    paths
end

function decode(path::AbstractString, prefix::AbstractString)
    filesize(path) <= MAX_CONFIG_BYTES || fail("deployment configuration exceeds 16 MiB")
    try
        return Common.read_json(path; maximum=MAX_CONFIG_BYTES)
    catch error
        error isa SystemError && rethrow()
        paths = installed_paths(prefix)
        env = merge(Dict(ENV), Dict("LD_LIBRARY_PATH" => paths["library"]))
        out, _, code = Common.run_checked([paths["parser"], "-N", "-R", path]; env, timeout=10)
        code == 0 || fail("installed SPA-JSON parser rejected $path")
        ncodeunits(out) <= MAX_CONFIG_BYTES || fail("decoded deployment configuration exceeds 16 MiB")
        return Common.parse_json(out)
    end
end

function validate_environment(value, label)
    require(value isa AbstractDict && all(value) do (key, item)
        key isa String && !isempty(key) && !occursin('=', key) && !occursin('\0', key) &&
            item isa String && !occursin('\0', item)
    end,
        "$label environment must map valid names to strings")
end

function relative_asset(package::AbstractString, name)
    require(name isa String && !isempty(name) && !occursin('\0', name) && !isabspath(name),
        "installed asset must be a package-relative path")
    candidate = realpath(joinpath(package, name))
    root = realpath(package)
    require(startswith(candidate, root * "/") && isfile(candidate),
        "asset escapes package or is not a file: $name")
    candidate
end

function valid_cpu_list(value)
    value isa AbstractVector || fail("process CPU envelope must be a list")
    Placement.cpu_set(value)
end

native_heart(owner) = get(owner, "control-protocol", nothing) == "pipewireao.rtc.heart/1"

native_source(owner) = get(owner, "control-protocol", nothing) == "pipewireao.source-control/1"

native_acquisition(owner) = get(owner, "control-protocol", nothing) in
    ("pipewireao.rtc.calibration-lifecycle/1", "pipewireao.rtc.correction-lifecycle/1")

function acquisition_profile(owner)
    protocol = owner["control-protocol"]
    protocol == "pipewireao.rtc.calibration-lifecycle/1" &&
        return NativeAcquisitionLifecycleCodec.CalibrationLifecycleProfile()
    protocol == "pipewireao.rtc.correction-lifecycle/1" &&
        return NativeAcquisitionLifecycleCodec.CorrectionLifecycleProfile()
    fail("unsupported acquisition lifecycle profile")
end

acquisition_instrument(owner) = owner["instrument"] == "classic" ?
    NativeAcquisitionLifecycleCodec.Classic : NativeAcquisitionLifecycleCodec.Copper

function validate_acquisition_arguments(owner)
    argv = owner["argv"]
    for flag in ("--prepared-event", "--connect-request", "--connect-reply", "--quit-request",
            "--control-request", "--control-reply")
        require(!(flag in argv), "native acquisition cannot use live file controls")
    end
    for (flag, value) in (("--control-node", owner["control-node"]),
            ("--control-instance", "@SOURCE_OWNER_INSTANCE@"),
            ("--profile", owner["instrument"]), ("--remote", "@RUNTIME@/@REMOTE@"))
        indices = findall(==(flag), argv)
        require(length(indices) == 1 && only(indices) < length(argv) && argv[only(indices) + 1] == value,
            "native acquisition requires the exact $flag binding")
    end
    return nothing
end

function profile(path::AbstractString, prefix::AbstractString)
    value = decode(path, prefix)
    require(value isa AbstractDict && REQUIRED_KEYS ⊆ Set(keys(value)) ⊆
        union(REQUIRED_KEYS, Set(["source-owner","detector-observation"])) && get(value, "version", nothing) === 1,
        "expected version 1 deployment with the documented fields")
    require(value["name"] isa String && occursin(r"^[a-z0-9][a-z0-9-]{0,39}$", value["name"]),
        "deployment name must use 1..40 lowercase letters, digits or hyphens")
    owners = value["owners"]
    require(owners isa AbstractVector && length(owners) <= 4,
        "deployment permits at most four external owners")
    validate_environment(value["environment"], "deployment")
    roles = Set(["core", "rtc"])
    source_role = get(value, "source-owner", nothing)
    require(source_role === nothing || source_role isa String && !isempty(source_role),
        "source-owner must name an existing external owner")
    markers = Set{String}()
    for owner in owners
        require(owner isa AbstractDict, "external owner fields do not match the deployment contract")
        fields = native_heart(owner) || native_acquisition(owner) ? Set(["role", "argv", "environment", "control-protocol", "control-node"]) :
            Set(["role", "argv", "environment", "prepared", "connect", "connected", "quit"])
        if native_acquisition(owner)
            push!(fields, "instrument")
            require(get(owner, "role", nothing) == source_role,
                "native acquisition lifecycle must be the selected source owner")
            require(get(owner, "instrument", nothing) in ("classic", "copper"),
                "native acquisition requires an explicit Classic or Copper instrument")
            node = get(owner, "control-node", nothing)
            require(node isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$", node),
                "native acquisition requires a bounded exact node name")
        end
        if native_heart(owner)
            require(get(owner, "role", nothing) == "heart", "native HEART profile requires the heart role")
            node = get(owner, "control-node", nothing)
            require(node isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$", node),
                "native HEART requires a bounded exact node name")
        end
        if source_role !== nothing && get(owner, "role", nothing) == source_role
            native_acquisition(owner) || union!(fields, native_source(owner) ?
                ["control-protocol", "control-node"] : ["control-request", "control-reply"])
            if native_source(owner)
                node = get(owner,"control-node",nothing)
                require(node isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$",node),
                    "native source requires a bounded exact node name")
            end
        end
        require(Set(keys(owner)) == fields, "external owner fields do not match the deployment contract")
        role = owner["role"]
        require(role != "heart" || native_heart(owner), "HEART owner requires the native control profile")
        require(role isa String && !(role in roles) && occursin(r"^[a-z][a-z0-9-]{0,31}$", role),
            "external owner role must be unique and filesystem-safe")
        push!(roles, role)
        argv = owner["argv"]
        require(argv isa AbstractVector && 1 <= length(argv) <= 256 &&
            all(arg -> arg isa String && !occursin('\0', arg), argv) && !isempty(argv[1]),
            "owner argv must be a nonempty bounded string list")
        native_acquisition(owner) && validate_acquisition_arguments(owner)
        validate_environment(owner["environment"], "owner $role")
        names = Set{String}()
        marker_keys = native_heart(owner) || native_acquisition(owner) ? String[] : ["prepared", "connect", "connected", "quit"]
        role == source_role && !native_source(owner) && !native_acquisition(owner) &&
            append!(marker_keys, ["control-request", "control-reply"])
        for key in marker_keys
            marker = owner[key]
            require(marker isa String && !(marker in (".", "..")) &&
                occursin(r"^[a-zA-Z0-9_.-]{1,64}$", marker), "owner $key must be a marker basename")
            push!(names, marker)
        end
        require(length(names) == length(marker_keys) && isempty(intersect(names, markers)),
            "owner markers must be distinct")
        union!(markers, names)
    end
    require(source_role === nothing || source_role in (owner["role"] for owner in owners),
        "source-owner must name an existing external owner")
    require(!haskey(value,"detector-observation") || value["detector-observation"] isa Bool,
        "detector-observation must be a Boolean")
    require(!get(value,"detector-observation",false) || source_role !== nothing &&
        native_source(only(filter(owner->owner["role"] == source_role,owners))),
        "detector observation requires an admitted native source owner")
    reserved = union(roles, Set(["control.sock", "native-control.sock", "native-prefix", "julia-depot"]))
    require(isempty(intersect(markers, reserved)), "owner markers conflict with deployment runtime paths")
    source = source_role === nothing ? nothing : only(filter(owner -> owner["role"] == source_role, owners))
    if source !== nothing && !native_source(source) && !native_acquisition(source)
        staging = splitext(source["control-request"])[1] * ".new"
        require(!(staging in markers || staging in reserved), "source request staging path conflicts with runtime paths")
    end
    placements = value["placement"]
    require(placements isa AbstractDict && Set(keys(placements)) == roles,
        "each owned process requires an explicit placement contract")
    for (role, placement) in placements
        require(placement isa AbstractDict && Set(keys(placement)) ==
            Set(["cpus", "leader-cpu", "rt-priority", "threads", "locked-bytes"]),
            "invalid placement contract for $role")
        envelope = valid_cpu_list(placement["cpus"])
        require(typeof(placement["leader-cpu"]) === Int && placement["leader-cpu"] in envelope,
            "process leader CPU must belong to its declared envelope")
        priority = placement["rt-priority"]
        require(typeof(priority) === Int && 0 <= priority <= 99,
            "RT priority must be an integer in 0..99")
        require(typeof(placement["locked-bytes"]) === Int && placement["locked-bytes"] >= 0,
            "locked-bytes must be nonnegative")
        threads = placement["threads"]
        require(threads isa AbstractVector && length(threads) <= 128,
            "thread requirements must be a bounded list")
        for thread in threads
            require(thread isa AbstractDict && Set(["cpus", "policy", "priority", "count"]) ⊆ Set(keys(thread)) ⊆
                Set(["cpus", "policy", "priority", "count", "name"]), "invalid required thread fields")
            require(thread["cpus"] isa AbstractVector, "required thread CPUs must be a list")
            require(Placement.cpu_set(thread["cpus"]) ⊆ envelope, "required thread exceeds process envelope")
            require(thread["policy"] in ("fifo", "other") && typeof(thread["count"]) === Int &&
                typeof(thread["priority"]) === Int && 1 <= thread["count"] <= 128 &&
                thread["priority"] == (thread["policy"] == "fifo" ? priority : 0),
                "invalid required thread policy/count")
            require(!haskey(thread, "name") || thread["name"] isa String &&
                !isempty(thread["name"]) && !occursin('\0', thread["name"]),
                "required thread name must be a nonempty string")
        end
    end
    latency = value["cpu-latency-us"]
    require(latency === nothing || typeof(latency) === Int && 0 <= latency <= typemax(Int32),
        "cpu-latency-us must be null or a nonnegative Int32")
    require(value["client"] isa AbstractDict && Set(keys(value["client"])) == roles,
        "each owned process requires an explicit client configuration")
    for name in values(value["client"])
        relative_asset(dirname(path), name)
    end
    relative_asset(dirname(path), value["session"])
    relative_asset(dirname(path), value["core"])
    require(value["artifacts"] isa AbstractDict, "deployment artifacts must be a path/hash mapping")
    for (name, sha) in value["artifacts"]
        asset = relative_asset(dirname(path), name)
        require(sha isa String && occursin(r"^[0-9a-f]{64}$", sha) && digest(asset) == sha,
            "deployment artifact hash mismatch: $name")
    end
    Dict{String,Any}(value)
end

function substitute(value::AbstractString, bindings::AbstractDict; quoted=false)
    result = String(value)
    for (name, replacement) in bindings
        escaped = quoted ? String(JSON3.write(replacement))[2:end-1] : string(replacement)
        result = replace(result, "@$name@" => escaped)
    end
    occursin(r"@[A-Z_]+@", result) && fail("unresolved deployment binding in $(first(result, min(length(result), 200)))")
    result
end

function _read_line_bounded(socket, maximum, deadline)
    reader = @async begin
        data = UInt8[]
        while true
            block = readavailable(socket)
            isempty(block) && fail("control peer disconnected; mutation outcome may be unknown")
            append!(data, block)
            length(data) <= maximum || fail("control reply exceeds 64 KiB")
            index = findfirst(==(0x0a), data)
            index !== nothing && return data[1:index]
        end
    end
    timedwait(() -> istaskdone(reader), max(0, deadline-monotonic()); pollint=0.005) == :ok ||
        fail("control timed out; mutation outcome may be unknown")
    fetch(reader)
end

function fixture_socket_control(path::AbstractString, argv::AbstractVector; timeout=8,
                 request_id=nothing, allow_rejection=false, check=nothing)
    require(all(arg -> arg isa AbstractString, argv), "control argv must be a string list")
    require(isfinite(timeout) && timeout > 0, "control timeout must be finite and positive")
    require(length(argv) <= 128, "control request exceeds protocol limits")
    id = request_id === nothing ? replace(string(uuid4()), "-" => "") : request_id
    payload = String(JSON3.write(Dict("version" => 1, "id" => id, "argv" => String.(argv)))) * "\n"
    require(ncodeunits(payload) <= MAX_REQUEST_BYTES, "control request exceeds protocol limits")
    deadline = monotonic() + timeout
    # Socket connect itself is bounded by the task timer. Never retry a sent mutation.
    socket_task = @async Sockets.connect(path)
    timedwait(() -> istaskdone(socket_task), max(0, deadline-monotonic()); pollint=0.005) == :ok ||
        fail("control timed out; mutation outcome may be unknown")
    socket = fetch(socket_task)
    try
        check !== nothing && check()
        write(socket, payload)
        bytes = _read_line_bounded(socket, MAX_REPLY_BYTES, deadline)
        check !== nothing && check()
        reply = Common.parse_json(String(bytes))
        require(reply isa AbstractDict && get(reply, "version", nothing) === 1 &&
            get(reply, "id", nothing) == id && get(reply, "ok", nothing) isa Bool,
            "control reply does not match request identity")
        !reply["ok"] && !allow_rejection && fail("control rejected: $(get(reply, "error", nothing))")
        return reply
    catch error
        error isa EOFError && fail("control peer disconnected; mutation outcome may be unknown")
        rethrow()
    finally
        close(socket)
    end
end

function validate_source_reply(payload::AbstractVector{UInt8})
    require(length(payload) <= MAX_REPLY_BYTES, "source reply exceeds 64 KiB")
    reply = Common.parse_json(String(payload))
    keys_required = Set(["version", "id", "operation", "state", "sequence", "completed", "ok", "error"])
    require(Set(keys(reply)) == keys_required && get(reply, "version", nothing) === 1 &&
        typeof(reply["id"]) === Int && reply["id"] > 0 &&
        reply["operation"] in ("resume", "pause", "reset", "status") &&
        reply["state"] in ("running", "paused") &&
        typeof(reply["sequence"]) === Int && reply["sequence"] >= 0 &&
        reply["completed"] isa Bool && reply["ok"] isa Bool &&
        (reply["error"] === nothing || reply["error"] isa String) &&
        (!reply["ok"] || reply["error"] === nothing), "invalid source control reply")
    reply
end

function validate_control_request(payload::AbstractVector{UInt8})
    require(length(payload) <= MAX_REQUEST_BYTES, "control request exceeds 16 KiB")
    request = Common.parse_json(String(payload))
    require(Set(keys(request)) == Set(["version", "id", "argv"]) &&
        request["version"] === 1 && request["id"] isa String &&
        1 <= ncodeunits(request["id"]) <= 128 && request["argv"] isa AbstractVector &&
        length(request["argv"]) <= 128 && all(arg -> arg isa String, request["argv"]),
        "invalid version 1 control request")
    request
end

control_error(id, field, message) = Dict{String,Any}("version" => 1, "id" => id,
    "session_id" => nothing, "state" => nothing, "result" => nothing,
    "ok" => false, "error" => Dict("field" => field, "message" => message))

mutable struct DeploymentRunner
    options::NamedTuple
    package::String
    spec::Dict{String,Any}
    paths::Dict{String,String}
    inherited_cpus::Set{Int}
    processes::Vector{Tuple{String,Base.Process}}
    owned_pids::IdDict{Base.Process,Int}
    runtime::Union{Nothing,String}
    socket::Union{Nothing,String}
    runner_client::Any
    broker::Any
    broker_accept::Any
    latency_io::Any
    source_owner::Any
    source_client::Any
    source_id::Int
    source_state::Any
    source_failed::Bool
    native_shutdown::Bool
    stopping::Bool
    state_path::Union{Nothing,String}
    record::Dict{String,Any}
    heart_client::Union{Nothing,NativeControlClient.Client}
    observation_boundary::Any
    discovery::Union{Nothing,Tuple{String,NativeSessionDiscovery.SessionRecord}}
end

function owner_preparation_timeout(seconds)
    seconds isa Integer && !(seconds isa Bool) && 1 <= seconds <= 3600 ||
        fail("owner preparation timeout requires integer seconds in 1..3600")
    return seconds
end

function DeploymentRunner(options::NamedTuple)
    preparation_timeout = owner_preparation_timeout(get(options, :owner_preparation_timeout_seconds, 90))
    deployment = abspath(options.deployment)
    spec = profile(deployment, options.pipewire_prefix)
    source = get(spec, "source-owner", nothing)
    owner = source === nothing ? nothing : only(filter(o -> o["role"] == source, spec["owners"]))
    record = Dict{String,Any}("version" => 1, "name" => spec["name"], "phase" => "preflight",
        "pid" => getpid(), "admitted" => false, "processes" => Dict{String,Any}(), "error" => nothing,
        "owner_preparation_timeout_seconds" => preparation_timeout)
    DeploymentRunner(options, dirname(deployment), spec, installed_paths(options.pipewire_prefix),
        Placement.inherited_cpus(), Tuple{String,Base.Process}[], IdDict{Base.Process,Int}(), nothing, nothing, nothing,
        nothing, nothing, nothing, owner, nothing, 0, nothing, false, false, false, nothing, record, nothing, nothing, nothing)
end

function preflight(deployment::DeploymentRunner)
    for (role, contract) in deployment.spec["placement"]
        Placement.cpu_set(contract["cpus"]) ⊆ deployment.inherited_cpus ||
            fail("$role CPUs unavailable in inherited affinity: $(sort!(collect(deployment.inherited_cpus)))")
    end
    contracts = collect(values(deployment.spec["placement"]))
    priority = maximum(contract["rt-priority"] for contract in contracts)
    locked = maximum(contract["locked-bytes"] for contract in contracts)
    rights = Placement.credentials(priority, locked, deployment.spec["cpu-latency-us"])
    if deployment.source_owner === nothing
        fits = get(deployment.options, :fits, nothing)
        fits !== nothing && isfile(fits) || fail("recorded FITS source is missing: $fits")
    end
    dependencies = [("RTC", joinpath(deployment.package, "bin/pipewireao-rtc"))]
    get(deployment.spec,"detector-observation",false) && push!(dependencies,
        ("bounded detector queue module",joinpath(deployment.paths["modules"],"libpipewire-module-queue.so")))
    if deployment.source_owner === nothing
        append!(dependencies, [("FITS plugin", joinpath(deployment.paths["spa"], "fits/libspa-fits.so")),
            ("discard plugin", joinpath(deployment.paths["spa"], "discard/libspa-pipewireao-discard.so"))])
    end
    for (label, path) in dependencies
        isfile(path) || fail("missing $label: $path")
    end
    rights
end

function environment(deployment::DeploymentRunner, role, bindings)
    runtime = something(deployment.runtime)
    paths = deployment.paths
    env = Dict{String,String}(ENV)
    pop!(env, "NOTIFY_SOCKET", nothing)
    merge!(env, Dict("LD_LIBRARY_PATH" => paths["library"],
        "PIPEWIREAO_RUNTIME_DIR" => runtime, "PIPEWIREAO_CONFIG_DIR" => joinpath(runtime, role),
        "PIPEWIREAO_MODULE_DIR" => paths["modules"], "PIPEWIREAO_SPA_PLUGIN_DIR" => paths["spa"],
        "PIPEWIREAO_FITS_PLUGIN" => joinpath(paths["spa"], "fits/libspa-fits.so"),
        "PIPEWIREAO_DISCARD_PLUGIN" => joinpath(paths["spa"], "discard/libspa-pipewireao-discard.so"),
        "PIPEWIREAO_REMOTE" => bindings["REMOTE"], "PIPEWIRE_REMOTE" => bindings["REMOTE"]))
    if deployment.source_owner === nothing
        env["PIPEWIREAO_RTC_FITS_PATH"] = realpath(deployment.options.fits)
    end
    merge!(env, Dict(key => substitute(value, bindings) for (key, value) in deployment.spec["environment"]))
    if !isempty(deployment.spec["owners"])
        env["JULIA_DEPOT_PATH"] = joinpath(runtime, "julia-depot") * ":" *
            get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia") * ":")
    end
    env
end

function prepare_julia_override(deployment::DeploymentRunner)
    isempty(deployment.spec["owners"]) && return
    runtime = something(deployment.runtime)
    overlay = joinpath(runtime, "native-prefix")
    mkdir(overlay)
    symlink(deployment.paths["library"], joinpath(overlay, "lib"))
    for name in ("bin", "share", "etc", "include")
        path = joinpath(deployment.options.pipewire_prefix, name)
        ispath(path) && symlink(realpath(path), joinpath(overlay, name))
    end
    artifacts = joinpath(runtime, "julia-depot/artifacts")
    mkpath(artifacts)
    write(joinpath(artifacts, "Overrides.toml"),
        "[cde84cf6-9a21-5ce0-b5e3-1526e778c30b]\nPipeWireAO = " *
        String(JSON3.write(overlay)) * "\n")
end

function spawn(deployment::DeploymentRunner, role, argv, env)
    cpu = string(deployment.spec["placement"][role]["leader-cpu"])
    command = Cmd(Cmd(["taskset", "--cpu-list", cpu, argv...]);
        dir=joinpath(something(deployment.runtime), role), detach=true)
    # Base.run(wait=false) defaults detached child output to devnull. Keep the
    # launcher's supervised log as the shared diagnostic stream for each owner.
    process = Base.run(pipeline(setenv(command, env);
        stdin=devnull, stdout=stdout, stderr=stderr); wait=false)
    pid = getpid(process)
    push!(deployment.processes, (role, process))
    deployment.owned_pids[process] = pid
    deployment.record["processes"][role] = Dict("pid" => pid)
    process
end

function check_processes(deployment::DeploymentRunner; ignore_roles=())
    for (role, process) in deployment.processes
        if !(role in ignore_roles) && !process_running(process)
            fail("required $role exited with status $(process.exitcode)")
        end
    end
end

function check(deployment::DeploymentRunner)
    if deployment.broker isa NativeSupervisorRuntime.Runtime && !deployment.broker.closed &&
            deployment.broker.endpoint.lifecycle === NativeSupervisorCodec.Preparing
        serve_control(deployment)
    end
    deployment.stopping && throw(InterruptException())
    check_processes(deployment)
end

function wait_until(deployment::DeploymentRunner, predicate, stage; timeout=90)
    deadline = monotonic() + timeout
    while true
        check(deployment)
        predicate() && return
        monotonic() < deadline || fail("timed out waiting for $stage")
        sleep(0.05)
    end
end

struct SourceHealth{D}
    deployment::D
    shutdown::Bool
end

function (probe::SourceHealth)()
    return probe.shutdown ? check_processes(probe.deployment; ignore_roles=("rtc",)) :
        check(probe.deployment)
end

function source_control(deployment::DeploymentRunner, operation::AbstractString;
                        initial=false, shutdown=false, allow_rejection=false, deadline=nothing, check=nothing)
    deployment.source_owner !== nothing || fail("source owner is not configured")
    native_acquisition(deployment.source_owner) && return acquisition_control(deployment, operation;
        initial, shutdown, allow_rejection, deadline, check)
    native_source(deployment.source_owner) || return source_file_control(deployment,operation;
        initial,shutdown,allow_rejection)
    operation in ("resume", "pause", "reset", "status") || fail("invalid source control operation")
    check_owner = check === nothing ? SourceHealth(deployment, shutdown) : check
    try
        deployment.source_failed && fail("source coordination already failed; source outcome unknown")
        if deployment.source_client === nothing
            initial || fail("native source client was not prepared; source outcome unknown")
            preparation_deadline = deadline === nothing ? monotonic() +
                get(deployment.options, :owner_preparation_timeout_seconds, 90) : deadline
            owner_pid = deployment.record["processes"][deployment.source_owner["role"]]["pid"]
            deployment.source_client = NativeSourceClient.connect(joinpath(something(deployment.runtime), deployment.record["remote"]),
                deployment.source_owner["control-node"],owner_pid;
                deadline=preparation_deadline,check=check_owner)
            NativeSourceClient.prepare_requests!(deployment.source_client;
                deadline=preparation_deadline,check=check_owner)
        end
        # Cold discovery and compilation are bounded preparation, while the
        # source is held. Every real control starts a fresh finite budget.
        deadline === nothing && (deadline = monotonic() + (operation == "reset" ? 16 : 8))
        deployment.source_id = Base.checked_add(deployment.source_id,1)
        reply = NativeSourceClient.request!(deployment.source_client,String(operation),
            Int64(deployment.source_id);deadline,check=check_owner)
        reply["id"] == deployment.source_id && reply["operation"] == operation ||
            fail("source ACK does not match request identity/operation")
        expected = operation == "resume" ? "running" : operation == "status" ? reply["state"] : "paused"
        if !reply["ok"] && !allow_rejection
            fail("source $operation rejected: $(reply["error"])")
        end
        reply["ok"] && reply["state"] != expected && fail("source $operation ACK has wrong state")
        (initial || operation == "reset") && reply["sequence"] != 0 &&
            fail("source admission/reset requires sequence zero")
        monotonic() < deadline || fail("source $operation ACK timed out")
        deployment.source_state = reply["state"]
        deployment.record["source"] = reply
        return reply
    catch error
        deployment.source_failed = true
        merge!(deployment.record,Dict("phase"=>"failed","admitted"=>false))
        if deployment.record["error"] === nothing
            deployment.record["error"] = sprint(showerror,error)
        else
            push!(get!(deployment.record,"cleanup_errors",String[]),sprint(showerror,error))
        end
        deployment.state_path !== nothing && atomic_record(deployment.state_path,deployment.record)
        fail("source coordination failed: $(sprint(showerror,error))")
    end
end

acquisition_snapshot(completion::NativeAcquisitionLifecycleCodec.Completion) = completion.snapshot
acquisition_snapshot(::NativeAcquisitionLifecycleCodec.Rejection) = nothing

function acquisition_reply(completion, operation, id)
    snapshot = acquisition_snapshot(completion)
    cursor = snapshot === nothing ? nothing : snapshot.cursor
    report_cursor = snapshot === nothing ? nothing : snapshot.report_cursor
    return Dict{String,Any}("version" => 1, "id" => id, "operation" => operation,
        "native_token" => completion.header.token,
        "endpoint_instance" => completion.header.endpoint_instance,
        "ok" => completion.header.result == 0,
        "error" => completion.header.result == 0 ? nothing : completion.message,
        "state" => snapshot === nothing ? nothing : snapshot.running ? "running" : "paused",
        "sequence" => cursor === nothing ? nothing : cursor.sequence,
        "completed" => snapshot === nothing ? nothing : snapshot.completed,
        "cursor" => cursor, "report_cursor" => report_cursor,
        "phase" => snapshot === nothing ? nothing : snapshot.phase,
        "held" => snapshot === nothing ? nothing : snapshot.held,
        "restored" => snapshot === nothing ? nothing : snapshot.restored,
        "window" => snapshot === nothing ? nothing : snapshot.window,
        "lifecycle" => string(completion.lifecycle))
end

function acquisition_control(deployment::DeploymentRunner, operation::AbstractString;
        initial=false, shutdown=false, allow_rejection=false, deadline=nothing, check=nothing)
    operation in ("resume", "pause", "reset", "status") || fail("invalid acquisition operation")
    try
        deployment.source_failed && fail("source coordination already failed; source outcome unknown")
        deployment.source_client === nothing && fail("acquisition lifecycle client was not prepared")
        deadline === nothing && (deadline = monotonic() + (operation == "reset" ? 30 : 8))
        deployment.source_id = Base.checked_add(deployment.source_id, 1)
        completion = NativeAcquisitionLifecycleClient.request!(deployment.source_client,
            Symbol(operation); deadline, check=check === nothing ? SourceHealth(deployment, shutdown) : check)
        reply = acquisition_reply(completion, operation, deployment.source_id)
        if !reply["ok"]
            allow_rejection || fail("source $operation rejected: $(reply["error"])")
            return reply
        end
        completion.lifecycle === NativeAcquisitionLifecycleCodec.Connected ||
            fail("source $operation changed acquisition readiness")
        expected = operation == "resume" ? "running" : operation == "status" ? reply["state"] : "paused"
        reply["state"] == expected || fail("source $operation ACK has wrong state")
        (initial || operation == "reset") && reply["sequence"] != 0 &&
            fail("source admission/reset requires sequence zero")
        deployment.source_state = reply["state"]
        deployment.record["source"] = reply
        return reply
    catch error
        deployment.source_failed = true
        merge!(deployment.record, Dict("phase" => "failed", "admitted" => false))
        if deployment.record["error"] === nothing
            deployment.record["error"] = sprint(showerror, error)
        else
            push!(get!(deployment.record, "cleanup_errors", String[]), sprint(showerror, error))
        end
        deployment.state_path !== nothing && atomic_record(deployment.state_path, deployment.record)
        fail("source coordination failed: $(sprint(showerror, error))")
    end
end

function source_file_control(deployment::DeploymentRunner, operation::AbstractString;
                        initial=false, shutdown=false, allow_rejection=false)
    operation in ("resume", "pause", "reset", "status") && deployment.source_owner !== nothing ||
        fail("invalid source control operation")
    deployment.source_id += 1
    request = Dict("version" => 1, "id" => deployment.source_id, "operation" => operation)
    deadline = monotonic() + (operation == "reset" ? 16 : 8)
    try
        atomic_record(joinpath(something(deployment.runtime), deployment.source_owner["control-request"]), request)
        reply_path = joinpath(something(deployment.runtime), deployment.source_owner["control-reply"])
        while true
            shutdown ? check_processes(deployment; ignore_roles=("rtc",)) : check(deployment)
            monotonic() < deadline || fail("source $operation ACK timed out")
            if !ispath(reply_path)
                sleep(0.05)
                continue
            end
            # O_NOFOLLOW binds validation and reading to the same opened inode.
            flags = Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_NOFOLLOW |
                Base.Filesystem.JL_O_NONBLOCK
            io = Base.Filesystem.open(reply_path, flags)
            payload = try
                info = stat(io)
                info.uid == ccall(:getuid, Cuint, ()) &&
                    (info.mode & 0o170000) == 0o100000 ||
                    fail("source reply must be an owner-owned regular file")
                read(io, MAX_REPLY_BYTES + 1)
            finally
                close(io)
            end
            reply = validate_source_reply(payload)
            if reply["id"] < deployment.source_id
                sleep(0.05)
                continue
            end
            reply["id"] == deployment.source_id && reply["operation"] == operation ||
                fail("source ACK does not match request identity/operation")
            expected = operation == "resume" ? "running" : operation == "status" ? reply["state"] : "paused"
            if !reply["ok"] && allow_rejection
                deployment.source_state = reply["state"]
                deployment.record["source"] = reply
                return reply
            end
            reply["ok"] && reply["state"] == expected || fail("source $operation rejected: $(reply["error"])")
            (initial || operation == "reset") && reply["sequence"] != 0 &&
                fail("source admission/reset requires sequence zero")
            monotonic() < deadline || fail("source $operation ACK timed out")
            deployment.source_state = reply["state"]
            deployment.record["source"] = reply
            return reply
        end
    catch error
        deployment.source_failed = true
        merge!(deployment.record, Dict("phase" => "failed", "admitted" => false))
        if deployment.record["error"] === nothing
            deployment.record["error"] = sprint(showerror, error)
        else
            push!(get!(deployment.record, "cleanup_errors", String[]), sprint(showerror, error))
        end
        deployment.state_path !== nothing && atomic_record(deployment.state_path, deployment.record)
        fail("source coordination failed: $(sprint(showerror, error))")
    end
end

function native_control(deployment::DeploymentRunner, argv; request_id=nothing, shutdown=false,
        command=RunnerCommands.parse(argv), deadline=monotonic() + 8, check=nothing)
    deployment.runner_client === nothing && fail("native runner client was not prepared")
    ignore_roles = argv in (["quit"], ["exit"]) ? ("rtc",) : ()
    check_fn = check !== nothing ? check : shutdown ? (() -> check_processes(deployment; ignore_roles)) :
        argv in (["quit"], ["exit"]) ?
            (() -> check_processes(deployment; ignore_roles)) : (() -> Deployment.check(deployment))
    reply = NativeRunnerClient.request!(deployment.runner_client, command;
        deadline, check=check_fn)
    return RunnerCommands.render(reply; request_id)
end

function fixture_coordinate(deployment::DeploymentRunner, argv, request_id)
    command = try
        RunnerCommands.parse(argv)
    catch error
        error isa ArgumentError || rethrow()
        return control_error(request_id, "control.command", sprint(showerror, error))
    end
    if deployment.source_owner === nothing
        reply = native_control(deployment, argv; request_id, command)
        if reply["ok"] && argv in (["quit"], ["exit"])
            deployment.native_shutdown = true
            deployment.stopping = true
        end
        return reply
    end
    if argv == ["status"]
        reply = native_control(deployment,argv;request_id,command)
        reply["ok"] && (reply["source"] = source_control(deployment,"status"))
        return reply
    end
    stopping = argv in (["session-stop"], ["source-ended"], ["quit"], ["exit"]) ||
        length(argv) == 2 && argv[1] == "stop"
    starting = argv == ["session-start"] || length(argv) == 2 && argv[1] == "start"
    resetting = argv == ["reset"]
    if resetting && native_acquisition(deployment.source_owner) &&
            deployment.source_owner["control-protocol"] == "pipewireao.rtc.calibration-lifecycle/1"
        return control_error(request_id, "source.reset", "calibration reset requires a fresh instance")
    end
    (stopping || starting || resetting) || return native_control(deployment, argv; request_id, command)
    observed = native_control(deployment, ["status"])
    if !observed["ok"] || resetting && observed["state"] != "Ready"
        return native_control(deployment, argv; request_id, command)
    end
    source = source_control(deployment, "status")
    if starting && source["completed"]
        reply = copy(observed)
        merge!(reply, Dict("id" => request_id, "ok" => false, "result" => nothing,
            "error" => Dict("field" => "source.state",
                "message" => "finite source completed; reset before start")))
        return reply
    end
    was_running = source["state"] == "running"
    stopping && (source = source_control(deployment, "pause"))
    reply = native_control(deployment, argv; request_id, command)
    if reply["ok"]
        if starting && reply["state"] == "Running"
            resumed = source_control(deployment, "resume"; allow_rejection=true)
            if !resumed["ok"]
                reply = copy(reply)
                merge!(reply, Dict("ok" => false,
                    "error" => Dict("field" => "source.state",
                        "message" => something(resumed["error"], "source rejected resume")),
                    "result" => Dict("native" => get(reply, "result", nothing), "source" => resumed)))
            end
        elseif resetting
            source_control(deployment, "reset")
        end
        if argv in (["quit"], ["exit"])
            deployment.native_shutdown = true
            deployment.stopping = true
        end
    elseif stopping && was_running && !source["completed"]
        source_control(deployment, "resume")
    end
    reply
end

function fixture_serve_control(deployment::DeploymentRunner)
    broker = something(deployment.broker)
    deployment.broker_accept === nothing && (deployment.broker_accept = @async begin
        try
            accept(broker)
        catch error
            # SIGINT may arrive in this owned task rather than the lifecycle
            # owner. Propagate only interruption as a graceful-stop signal.
            error isa InterruptException || rethrow()
            nothing
        end
    end)
    status = timedwait(() -> istaskdone(deployment.broker_accept), 0.1; pollint=0.005)
    status == :timed_out && return
    client = fetch(deployment.broker_accept)
    deployment.broker_accept = nothing
    client === nothing && throw(InterruptException())
    failure = nothing
    request_id = nothing
    try
        deadline = monotonic() + 1
        payload = _read_line_bounded(client, MAX_REQUEST_BYTES, deadline)
        request = validate_control_request(payload)
        request_id = request["id"]
        reply = try
            fixture_coordinate(deployment, request["argv"], request_id)
        catch error
            failure = error
            control_error(request_id, "control.outcome", sprint(showerror, error))
        end
        bytes = String(JSON3.write(reply)) * "\n"
        if ncodeunits(bytes) > MAX_REPLY_BYTES
            bytes = String(JSON3.write(control_error(request_id, "protocol.reply", "reply exceeds 64 KiB"))) * "\n"
        end
        write(client, bytes)
    catch error
        if failure === nothing
            bytes = String(JSON3.write(control_error(request_id, "protocol.request", sprint(showerror, error)))) * "\n"
            try
                write(client, bytes)
            catch
            end
        end
    finally
        close(client)
    end
    failure === nothing || throw(failure)
end

include("supervisor_controls.jl")

function notify(message)
    haskey(ENV, "NOTIFY_SOCKET") || return
    # NotifyAccess=main checks the sender's kernel credentials. Send from this
    # process; systemd-notify would make its short-lived helper the sender.
    result = ccall((:sd_notify, "libsystemd.so.0"), Cint,
        (Cint, Cstring), 0, message)
    result > 0 || fail("systemd notification failed: sd_notify returned $result")
end

function _enable_subreaper()
    # Orphaned descendants of detached owners must remain attributable to this
    # supervisor after the owner exits. PR_SET_CHILD_SUBREAPER is Linux prctl 36.
    ccall(:prctl, Cint, (Cint, Culong, Culong, Culong, Culong), 36, 1, 0, 0, 0) == 0 ||
        fail("cannot enable Linux child subreaper for owned-process cleanup")
end

function _owned_group_members(group_pid::Integer)
    members = NamedTuple[]
    for name in readdir("/proc")
        all(isdigit, name) || continue
        pid = try parse(Int, name) catch; continue end
        stat_path = "/proc/$pid/stat"
        line = try read(stat_path, String) catch; continue end
        closing = findlast(==(')'), line)
        closing === nothing && continue
        fields = split(strip(line[closing+1:end]))
        length(fields) >= 4 || continue
        state = fields[1]
        ppid = try parse(Int, fields[2]) catch; continue end
        pgrp = try parse(Int, fields[3]) catch; continue end
        session = try parse(Int, fields[4]) catch; continue end
        pgrp == group_pid && session == group_pid &&
            push!(members, (; pid, ppid, state))
    end
    members
end

function _live_owned_orphans(group_pid::Integer)
    filter(member -> member.pid != group_pid && member.ppid == getpid() &&
        !(member.state in ("Z", "X")),
        _owned_group_members(group_pid))
end

function _reap_owned_orphans(group_pid::Integer)
    for member in _owned_group_members(group_pid)
        if member.pid != group_pid && member.ppid == getpid() && member.state in ("Z", "X")
            status = Ref{Cint}(0)
            ccall(:waitpid, Cint, (Cint, Ref{Cint}, Cint), member.pid, status, 1)
        end
    end
end

_owned_wait(deployment::DeploymentRunner, process::Base.Process, grace::Real) =
    _owned_wait(process, deployment.owned_pids[process], grace)

function _owned_wait(process::Base.Process, group_pid::Integer, grace::Real)
    # The group ID is reserved by its live leader or by a confirmed adopted
    # descendant. Never signal a reused numeric group ID without that evidence.
    active() = process_running(process) || !isempty(_live_owned_orphans(group_pid))
    deadline = monotonic() + grace
    while active() && monotonic() < deadline
        _reap_owned_orphans(group_pid)
        sleep(0.02)
    end
    if active()
        ccall(:kill, Cint, (Cint, Cint), -group_pid, Base.SIGTERM)
        deadline = monotonic() + 5
        while active() && monotonic() < deadline
            _reap_owned_orphans(group_pid)
            sleep(0.02)
        end
    end
    if active()
        ccall(:kill, Cint, (Cint, Cint), -group_pid, Base.SIGKILL)
        deadline = monotonic() + 5
        while active() && monotonic() < deadline
            _reap_owned_orphans(group_pid)
            sleep(0.02)
        end
    end
    active() && fail("owned process group $group_pid did not exit by cleanup deadline")
    wait(process)
    _reap_owned_orphans(group_pid)
end

function _touch(path)
    flags = Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_EXCL
    close(Base.Filesystem.open(path, flags, 0o600))
end

function _is_socket(path)
    islink(path) && return false
    try
        return (stat(path).mode & 0o170000) == 0o140000
    catch
        return false
    end
end

function stop_owner!(deployment::DeploymentRunner, owner)
    if native_heart(owner)
        child = findfirst(pair -> first(pair) == owner["role"], deployment.processes)
        child === nothing && return nothing
        process_running(last(deployment.processes[child])) || return nothing
        client = deployment.heart_client
        # Failed preparation cannot be reconnected during cleanup. The final
        # owned-process-group pass still revokes any children in that case.
        client === nothing && return nothing
        NativeHeartClient.shutdown!(client; deadline=monotonic() + 30,
            check=() -> nothing)
    elseif native_acquisition(owner)
        child = findfirst(pair -> first(pair) == owner["role"], deployment.processes)
        child === nothing && return nothing
        process_running(last(deployment.processes[child])) || return nothing
        client = deployment.source_client
        client === nothing && return nothing
        completion = NativeAcquisitionLifecycleClient.request!(client, :shutdown;
            deadline=monotonic() + 30, check=() -> nothing)
        completion.header.result == 0 &&
            completion.lifecycle === NativeAcquisitionLifecycleCodec.Stopped ||
            fail("acquisition owner shutdown was not completed: $(completion.message)")
    else
        _touch(joinpath(something(deployment.runtime), owner["quit"]))
    end
    return nothing
end

function _stop_processes(deployment, errors; source=false)
    runtime = deployment.runtime
    if source
        owner = deployment.source_owner
        source_started = any(role == owner["role"] for (role, _) in deployment.processes)
        paused = deployment.native_shutdown && deployment.source_state == "paused"
        if source_started && !deployment.source_failed && !paused
            try
                source_control(deployment, "pause"; shutdown=true)
                paused = true
            catch error
                push!(errors, error)
            end
        end
        revoked = paused
        if !paused
            revoked = true
            for (role, process) in deployment.processes
                if role in (owner["role"], "core")
                    try
                        _owned_wait(deployment, process, 0)
                    catch error
                        revoked = false
                        push!(errors, error)
                    end
                end
            end
        end
        revoked && close_observation!(deployment,errors)
        # A revoked private core cannot carry a native request. Process-group
        # cleanup remains available when no live native endpoint can respond.
        if paused && deployment.runner_client !== nothing
            try
                observed = native_control(deployment, ["status"]; shutdown=true)
                observed["state"] == "Running" && native_control(deployment, ["session-stop"]; shutdown=true)
            catch
            end
            try
                native_control(deployment, ["quit"]; shutdown=true)
            catch
            end
        end
        for (role, process) in deployment.processes
            if role == "rtc"
                try _owned_wait(deployment, process, 8) catch error push!(errors, error) end
            end
        end
        source_closed = !source_started
        if runtime !== nothing && revoked
            try
                stop_owner!(deployment, owner)
                for (role, process) in deployment.processes
                    role == owner["role"] && _owned_wait(deployment, process, 8)
                end
                source_closed = true
            catch error
                push!(errors, error)
            end
            if source_closed
                for other in deployment.spec["owners"]
                    other === owner && continue
                    try stop_owner!(deployment, other) catch error push!(errors, error) end
                end
            else
                for (role, process) in deployment.processes
                    if role in ("core", owner["role"])
                        try _owned_wait(deployment, process, 0) catch error push!(errors, error) end
                    end
                end
            end
        end
        for (role, process) in reverse(deployment.processes)
            try
                _owned_wait(deployment, process, revoked && source_closed && !(role in ("core", "rtc")) ? 8 : 0)
            catch error
                push!(errors, error)
            end
        end
    else
        ingress_stopped = deployment.native_shutdown
        if deployment.runner_client !== nothing && !deployment.native_shutdown
            try
                observed = native_control(deployment, ["status"]; shutdown=true)
                observed["state"] == "Running" &&
                    (observed = native_control(deployment, ["session-stop"]; shutdown=true))
                ingress_stopped = observed["state"] == "Ready"
            catch
            end
            try native_control(deployment, ["quit"]; shutdown=true) catch end
        end
        for (role, process) in deployment.processes
            if role == "rtc"
                try _owned_wait(deployment, process, 8) catch error push!(errors, error) end
            end
        end
        if !ingress_stopped
            for (role, process) in deployment.processes
                if role == "core"
                    try
                        _owned_wait(deployment, process, 0)
                        ingress_stopped = true
                    catch error
                        push!(errors, error)
                    end
                end
            end
        end
        if runtime !== nothing && ingress_stopped
            for owner in deployment.spec["owners"]
                try stop_owner!(deployment, owner) catch error push!(errors, error) end
            end
        end
        for (role, process) in reverse(deployment.processes)
            try _owned_wait(deployment, process, role in ("core", "rtc") ? 0 : 8) catch error push!(errors, error) end
        end
    end
end

function stop(deployment::DeploymentRunner)
    deployment.record["admitted"] = false
    errors = Any[]
    if deployment.broker isa NativeSupervisorRuntime.Runtime && !deployment.broker.closed
        try close(deployment.broker) catch error push!(errors,error) end
    end
    try retire_discovery!(deployment) catch error push!(errors,error) end
    try notify("STOPPING=1\nSTATUS=Stopping RTC deployment") catch error push!(errors, error) end
    _stop_processes(deployment, errors; source=deployment.source_owner !== nothing)
    close_observation!(deployment,errors)
    if deployment.latency_io !== nothing
        try close(deployment.latency_io) catch error push!(errors, error) end
        deployment.latency_io = nothing
    end
    isempty(errors) || fail("deployment cleanup failed: $(sprint(showerror, first(errors)))")
end

"Publish only the existing supervisor endpoint's immutable native identity."
function publish_discovery!(deployment::DeploymentRunner, remote, node_name)
    supervisor = deployment.broker::NativeSupervisorRuntime.Runtime
    directory = NativeSessionDiscovery.registry_directory()
    record = NativeSessionDiscovery.SessionRecord(deployment.spec["name"],
        supervisor.uuid, UInt32(getpid()), supervisor.endpoint.instance, remote, node_name)
    # Retain the identity before publication so cleanup can also remove a record
    # if an error occurs after the atomic rename.
    deployment.discovery = (directory,record)
    deployment.record["discovery_locator"] = NativeSessionDiscovery.publish!(directory,record)
    return nothing
end

"Remove only this supervisor incarnation; a replacement publication survives."
function retire_discovery!(deployment::DeploymentRunner)
    publication = deployment.discovery
    publication === nothing && return nothing
    directory, record = publication
    NativeSessionDiscovery.remove!(directory,record)
    deployment.discovery = nothing
    return nothing
end

"List unverified local hints without querying or controlling any endpoint."
function list_sessions()
    directory = NativeSessionDiscovery.existing_registry_directory()
    directory === nothing && return NativeSessionDiscovery.DiscoveryEntry[]
    return NativeSessionDiscovery.list_sessions(directory)
end

function session_entry(session_id::AbstractString)
    NativeSupervisorCodec.validate_uuid(String(session_id))
    entries = filter(list_sessions()) do entry
        entry.record !== nothing && entry.record.session_id == session_id
    end
    length(entries) == 1 || fail("selected RTC session is absent from the local listing")
    return only(entries)
end

session_connection(connection::NativeSessionClient.Connection) = connection
session_connection(entry::NativeSessionDiscovery.DiscoveryEntry) =
    fail("selected RTC session is $(entry.verification): $(entry.detail)")

"Explicit session selection retains the exact client used for its read-only Status."
function select_session(session_id::AbstractString; deadline=monotonic()+30)
    return session_connection(NativeSessionClient.select_session(session_entry(session_id);
        deadline=Float64(deadline)))
end

function session_status(connection::NativeSessionClient.Connection)
    selected = connection.selected
    status = selected.status
    return Dict("label"=>selected.record.label,"session_id"=>status.session_id,
        "owner_pid"=>status.owner_pid,"instance"=>status.incarnation,
        "remote"=>status.remote,"node"=>status.node_name,
        "global_id"=>status.global_id,"serial"=>status.object_serial,
        "native_token"=>status.query_token,"lifecycle"=>String(status.lifecycle),
        "authority"=>String(status.authority))
end

function control_session(session_id::AbstractString, argv; timeout=30)
    require(isfinite(timeout) && timeout>0,"control timeout must be finite and positive")
    # Validate the explicit command before establishing a connection.
    command = RunnerCommands.parse(argv)
    deadline = monotonic()+timeout
    connection = select_session(session_id;deadline)
    try
        completion = NativeSessionClient.request!(connection,command;deadline)
        reply = NativeSupervisorClient.render(completion;
            owner_pid=connection.selected.status.owner_pid)
        reply["deployment_uuid"] = connection.selected.status.session_id
        return reply
    finally
        close(connection)
    end
end

function close_observation!(deployment::DeploymentRunner, errors=Any[])
    boundary = deployment.observation_boundary
    deployment.observation_boundary = nothing
    boundary === nothing && return nothing
    try close(boundary) catch failure push!(errors,failure) end
    return nothing
end

function prepare_observation!(deployment::DeploymentRunner)
    get(deployment.spec,"detector-observation",false) || return nothing
    source = something(deployment.source_client)
    try
        deployment.observation_boundary = ObservationBoundary.connect(
            joinpath(something(deployment.runtime),deployment.record["remote"]),
            source.node_name,source.global_id,source.serial;
            deadline=monotonic()+8,check=SourceHealth(deployment,false))
        deployment.record["detector-observation"] = Dict("state"=>"available",
            "node"=>ObservationBoundary.OUTPUT_NAME,"media"=>"detector-image")
    catch failure
        failure isa InterruptException && rethrow()
        # A required-owner loss still fails normal admission. Only the optional
        # boundary's own preparation failure is contained here.
        check(deployment)
        deployment.record["detector-observation"] = Dict("state"=>"unavailable","error"=>sprint(showerror,failure))
    end
    return nothing
end

function observe_boundary!(deployment::DeploymentRunner)
    boundary = deployment.observation_boundary
    boundary === nothing && return nothing
    failure = ObservationBoundary.failure(boundary)
    failure === nothing && return nothing
    errors = Any[]
    close_observation!(deployment,errors)
    deployment.record["detector-observation"] = Dict("state"=>"unavailable","error"=>failure)
    isempty(errors) || (deployment.record["detector-observation"]["cleanup_errors"] = sprint.(showerror,errors))
    deployment.state_path === nothing || atomic_record(deployment.state_path,deployment.record)
    return nothing
end

"Select the admitted placement without making an absent optional observer mandatory."
function admission_placement(deployment::DeploymentRunner, role::AbstractString)
    contract = deployment.spec["placement"][role]
    role == "core" && get(deployment.spec,"detector-observation",false) &&
        deployment.observation_boundary === nothing || return contract
    selected = copy(contract)
    selected["threads"] = filter(contract["threads"]) do thread
        !(get(thread,"name",nothing) == "observer-loop" && get(thread,"count",nothing) === 1)
    end
    return selected
end

function _render(deployment, bindings)
    runtime = something(deployment.runtime)
    for role in keys(deployment.spec["placement"])
        directory = joinpath(runtime, role)
        mkdir(directory)
        chmod(directory, 0o700)
        for key in ("client", "core", "session")
            name = key == "client" ? deployment.spec["client"][role] : deployment.spec[key]
            source = relative_asset(deployment.package, name)
            target = joinpath(directory, (key == "core" ? "daemon" : key) * ".conf")
            write(target, substitute(read(source, String), bindings; quoted=true))
        end
    end
    graphs = joinpath(deployment.package, "graphs")
    if isdir(graphs)
        for name in readdir(graphs)
            endswith(name, ".conf.in") || continue
            source = joinpath(graphs, name)
            write(joinpath(runtime, name[1:end-3]), substitute(read(source, String), bindings; quoted=true))
        end
    end
end

function runner_admission(reply, expected_state)
    require(get(reply, "ok", false) === true && get(reply, "state", nothing) == expected_state,
        "RTC admission requires a successful $expected_state completion")
    return reply
end

function _run_locked(deployment::DeploymentRunner, base)
    deployment.state_path = joinpath(base, "state.json")
    deployment.runtime = mktempdir(base; prefix="run-")
    chmod(deployment.runtime, 0o700)
    primary_error = nothing
    try
        runtime = something(deployment.runtime)
        deployment.socket = joinpath(base, "control.json")
        bindings = Dict("PACKAGE" => deployment.package,
            "PREFIX" => abspath(deployment.options.pipewire_prefix),
            "RUNTIME" => runtime, "REMOTE" => "rtc-" * first(replace(string(uuid4()), "-" => ""), 12))
        if any(owner -> owner["role"] == "heart", deployment.spec["owners"])
            heart = only(filter(native_heart, deployment.spec["owners"]))
            bindings["HEART_OWNER_NODE"] = heart["control-node"]
            bindings["HEART_OWNER_INSTANCE"] = string(Int64(time_ns() % UInt64(typemax(Int64) - 1)) + 1)
        end
        if deployment.source_owner !== nothing && native_acquisition(deployment.source_owner)
            bindings["SOURCE_OWNER_INSTANCE"] = string(Int64(time_ns() % UInt64(typemax(Int64) - 1)) + 1)
            deployment.record["source_endpoint"] = Dict("node" => deployment.source_owner["control-node"],
                "instance" => parse(Int64, bindings["SOURCE_OWNER_INSTANCE"]),
                "profile" => deployment.source_owner["control-protocol"],
                "instrument" => deployment.source_owner["instrument"])
        end
        deployment.source_owner === nothing && (bindings["FITS"] = realpath(deployment.options.fits))
        merge!(deployment.record, Dict("instance" => basename(runtime),
            "remote" => bindings["REMOTE"], "control_locator" => deployment.socket))
        if deployment.source_owner === nothing
            deployment.record["fits_sha256"] = digest(deployment.options.fits)
        else
            merge!(deployment.record, Dict("source-owner" => deployment.source_owner["role"],
                "control_operation_bound_seconds" => 40, "control_client_timeout_seconds" => 48))
        end
        prepare_julia_override(deployment)
        _render(deployment, bindings)
        atomic_record(deployment.state_path, deployment.record)
        latency = deployment.spec["cpu-latency-us"]
        if latency !== nothing
            deployment.latency_io = open("/dev/cpu_dma_latency", "w")
            write(deployment.latency_io, htol(Int32(latency))) == 4 ||
                fail("short cpu_dma_latency request write")
            flush(deployment.latency_io)
        end
        spawn(deployment, "core", [deployment.paths["daemon"], "-c", "daemon.conf"],
            environment(deployment, "core", bindings))
        wait_until(deployment, () -> _is_socket(joinpath(runtime, bindings["REMOTE"])), "private core")
        supervisor_node = "pipewireao.rtc.deployment-supervisor.$(deployment.spec["name"])"
        supervisor_instance = NativeControlClient.next_instance()
        remote = joinpath(runtime,bindings["REMOTE"])
        deployment.broker = NativeSupervisorRuntime.Runtime(NativeSupervisorCodec.PROFILE,remote,
            supervisor_node,supervisor_instance)
        atomic_record(deployment.socket,Dict("version"=>1,"profile"=>NativeControlClient.profile_name(NativeSupervisorCodec.PROFILE),
            "remote"=>remote,"node"=>supervisor_node,"owner_pid"=>getpid(),"instance"=>supervisor_instance))
        deployment.record["supervisor_endpoint"] = Dict("node"=>supervisor_node,"instance"=>supervisor_instance,
            "profile"=>NativeControlClient.profile_name(NativeSupervisorCodec.PROFILE),"uuid"=>deployment.broker.uuid)
        publish_discovery!(deployment,remote,supervisor_node)
        atomic_record(deployment.state_path,deployment.record)
        for owner in deployment.spec["owners"]
            role = owner["role"]
            env = environment(deployment, role, bindings)
            merge!(env, Dict(key => substitute(value, bindings) for (key, value) in owner["environment"]))
            process = spawn(deployment, role, [substitute(arg, bindings) for arg in owner["argv"]], env)
            if native_heart(owner)
                bindings["HEART_OWNER_PID"] = string(getpid(process))
                deadline = monotonic() + get(deployment.options, :owner_preparation_timeout_seconds, 90)
                deployment.heart_client = NativeHeartClient.connect(joinpath(runtime, bindings["REMOTE"]),
                    bindings["HEART_OWNER_NODE"], getpid(process), parse(Int64, bindings["HEART_OWNER_INSTANCE"]);
                    deadline, check=() -> check(deployment))
                NativeHeartClient.connect!(deployment.heart_client; deadline, check=() -> check(deployment))
            elseif native_acquisition(owner)
                deadline = monotonic() + get(deployment.options, :owner_preparation_timeout_seconds, 90)
                deployment.source_client = NativeAcquisitionLifecycleClient.connect(acquisition_profile(owner),
                    joinpath(runtime, bindings["REMOTE"]), owner["control-node"], getpid(process),
                    parse(Int64, bindings["SOURCE_OWNER_INSTANCE"]), acquisition_instrument(owner);
                    deadline, check=() -> check(deployment))
                NativeAcquisitionLifecycleClient.connect_owner!(deployment.source_client;
                    deadline, check=() -> check(deployment))
            else
                wait_until(deployment, () -> isfile(joinpath(runtime, owner["prepared"])), "$role preparation";
                    timeout=get(deployment.options, :owner_preparation_timeout_seconds, 90))
                _touch(joinpath(runtime, owner["connect"]))
                wait_until(deployment, () -> isfile(joinpath(runtime, owner["connected"])), "$role connection")
            end
        end
        deployment.source_owner !== nothing && source_control(deployment, "pause"; initial=true)
        runner_node = "pipewireao.rtc.runner.$(deployment.spec["name"])"
        runner_instance = Int64(time_ns() % UInt64(typemax(Int64) - 1)) + 1
        remote = joinpath(runtime, bindings["REMOTE"])
        rtc = spawn(deployment, "rtc", [joinpath(deployment.package, "bin/pipewireao-rtc"),
            "--config", joinpath(runtime, "rtc/session.conf"), "--remote", remote,
            "--start-paused", "--control-node", runner_node,
            "--control-instance", string(runner_instance)],
            environment(deployment, "rtc", bindings))
        deployment.runner_client = NativeRunnerClient.connect(remote, runner_node, getpid(rtc), runner_instance;
            deadline=monotonic() + 90, check=() -> check(deployment))
        deployment.record["runner"] = Dict("node" => runner_node, "instance" => runner_instance)
        ready = runner_admission(native_control(deployment, ["status"]), "Ready")
        # Negotiate required links before the optional passive boundary, with
        # source ingress still held and native runner admission preserved.
        prepare_observation!(deployment)
        placements = Dict{String,Any}()
        for (role, process) in deployment.processes
            placements[role] = Placement.snapshot(getpid(process), admission_placement(deployment, role))
        end
        check(deployment)
        merge!(deployment.record, Dict("phase" => "prepared", "placement" => placements, "ready" => ready))
        atomic_record(deployment.state_path, deployment.record)
        started = runner_admission(native_control(deployment, ["session-start"]), "Running")
        if deployment.source_owner !== nothing
            source_control(deployment, "resume")
        end
        NativeSupervisorRuntime.lifecycle!(deployment.broker,NativeSupervisorCodec.Admitted)
        merge!(deployment.record, Dict("phase" => "running", "admitted" => true, "start" => started))
        atomic_record(deployment.state_path, deployment.record)
        println("DEPLOYMENT_READY name=$(deployment.spec["name"]) control_locator=$(deployment.socket)")
        flush(stdout)
        notify("READY=1\nSTATUS=RTC admitted; local control available")
        while !deployment.stopping
            check(deployment)
            observe_boundary!(deployment)
            serve_control(deployment)
            sleep(0.005)
        end
    catch error
        if !(error isa InterruptException)
            primary_error = error
            merge!(deployment.record, Dict("phase" => "failed", "error" => sprint(showerror, error),
                "admitted" => false))
            atomic_record(deployment.state_path, deployment.record)
            rethrow()
        end
    finally
        try
            stop(deployment)
        catch error
            push!(get!(deployment.record, "cleanup_errors", String[]), sprint(showerror, error))
            deployment.record["error"] === nothing && (deployment.record["error"] = sprint(showerror, error))
            primary_error === nothing && rethrow()
        finally
            try
                deployment.runner_client !== nothing && close(deployment.runner_client)
            catch error
                push!(get!(deployment.record,"cleanup_errors",String[]),sprint(showerror,error))
                deployment.record["error"] === nothing && (deployment.record["error"] = sprint(showerror,error))
            end
            try
                deployment.source_client !== nothing && close(deployment.source_client)
            catch error
                push!(get!(deployment.record,"cleanup_errors",String[]),sprint(showerror,error))
                deployment.record["error"] === nothing && (deployment.record["error"] = sprint(showerror,error))
            end
            try
                deployment.heart_client !== nothing && close(deployment.heart_client)
            catch error
                push!(get!(deployment.record,"cleanup_errors",String[]),sprint(showerror,error))
                deployment.record["error"] === nothing && (deployment.record["error"] = sprint(showerror,error))
            end
            deployment.broker !== nothing && close(deployment.broker)
            merge!(deployment.record, Dict("phase" => deployment.record["error"] === nothing ? "stopped" : "failed",
                "admitted" => false))
            atomic_record(deployment.state_path, deployment.record)
            rm(something(deployment.runtime); recursive=true, force=true)
        end
    end
end

function run(deployment::DeploymentRunner)
    deployment.record["credentials"] = preflight(deployment)
    _enable_subreaper()
    cpu = deployment.spec["placement"]["rtc"]["leader-cpu"]
    deployment.record["supervisor_placement"] = Placement.pin_supervisor(cpu)
    base = abspath(deployment.options.runtime)
    islink(base) && fail("runtime base must not be a symlink")
    mkpath(base; mode=0o700)
    stat(base).uid == ccall(:getuid, Cuint, ()) && (stat(base).mode & 0o777) == 0o700 ||
        fail("runtime base must be an owner-only directory")
    open(joinpath(base, "deployment.lock"), "a") do lock
        ccall(:flock, Cint, (Cint, Cint), Base.fd(lock), 6) == 0 ||
            fail("deployment runtime is already owned by another launcher")
        _run_locked(deployment, base)
    end
end

function wait_state(runtime::AbstractString, predicate; timeout=30, process=nothing)
    isfinite(timeout)&&timeout>0 || fail("state wait timeout must be finite and positive")
    deadline=monotonic()+timeout
    locator=joinpath(runtime,"control.json")
    hints = nothing
    owner_pid = process === nothing ? nothing : getpid(process)
    while true
        process!==nothing&&!process_running(process) && fail("deployment launcher exited before requested native state")
        NativeControlClient.deadline_check(deadline,()->nothing)
        if isfile(locator)
            hints=NativeSupervisorClient.read_locator(locator)
            if owner_pid===nothing || hints.owner_pid==owner_pid
                break
            end
        end
        sleep(min(0.05,max(0.0,deadline-monotonic())))
    end
    client=NativeSupervisorClient.connect(hints;deadline)
    try
        uuid=NativeSupervisorClient.live_uuid(client)
        while true
            process!==nothing&&!process_running(process) && fail("deployment launcher exited before requested native state")
            completion=NativeSupervisorClient.request!(client,NativeRunnerCodec.RunnerCommand(:status);deadline)
            state=NativeSupervisorClient.render(completion;owner_pid=client.observation.owner_pid)
            state["deployment_uuid"]=uuid
            state["control_locator"]=locator
            state["private_runtime"]=dirname(hints.remote)
            state["observation_remote"]=hints.remote
            state["instance"]=basename(state["private_runtime"])
            state["remote"]=basename(hints.remote)
            if haskey(state,"runner_endpoint")
                state["runner"]=Dict("node"=>state["runner_endpoint"]["node"],"instance"=>state["runner_endpoint"]["instance"])
            end
            # Preserve non-live qualification/configuration facts as artifacts;
            # every live identity/state/source/phase value comes from this query.
            report_path=joinpath(runtime,"state.json")
            if isfile(report_path)
                artifacts=Common.read_json(report_path;maximum=MAX_REPLY_BYTES)
                for key in ("placement","supervisor_placement","credentials","fits_sha256","name","detector-observation","source-owner")
                    haskey(artifacts,key)&&(state[key]=artifacts[key])
                end
            end
            state["ok"]||fail("native supervisor Status failed: $(state["error"])")
            predicate(state)&&return state
            sleep(min(0.05,max(0.0,deadline-monotonic())))
        end
    finally
        close(client)
    end
end

"Read a final saved report only after observing this owned launcher's exit."
function wait_final_report(runtime::AbstractString,process::Base.Process;
        owner_pid::Integer, timeout=30)
    isfinite(timeout)&&timeout>0 || fail("final report wait must be finite and positive")
    !(owner_pid isa Bool) && 0 < owner_pid <= typemax(UInt32) ||
        fail("final report requires the PID captured from the owned launcher")
    deadline=monotonic()+timeout
    while process_running(process)
        monotonic()<deadline || fail("deployment launcher did not exit")
        sleep(0.05)
    end
    wait(process)
    final=Common.read_json(joinpath(runtime,"state.json");maximum=MAX_REPLY_BYTES)
    get(final,"pid",nothing)==owner_pid || fail("final report belongs to another launcher")
    return final
end

function shutdown(runtime::AbstractString, process::Base.Process; timeout=30)
    isfinite(timeout) && timeout > 0 || fail("shutdown timeout must be finite and positive")
    deadline = monotonic() + timeout
    state_path = joinpath(runtime,"state.json")
    locator=joinpath(runtime,"control.json")
    if process_running(process)
        observed=control(locator,["status"];deadline)
        if observed["admitted"]
            observed["state"]=="Running" && control(locator,["session-stop"];deadline)
            control(locator,["quit"];deadline)
        else
            fail("native supervisor was not admitted for public shutdown")
        end
    end
    while process_running(process) && monotonic() < deadline
        sleep(0.05)
    end
    process_running(process) && fail("deployment did not exit after public quit")
    wait(process)
    success(process) || fail("deployment launcher exited unsuccessfully")
    final = Common.read_json(state_path; maximum=MAX_REPLY_BYTES)
    get(final, "phase", nothing) == "stopped" && get(final, "admitted", nothing) === false ||
        fail("deployment final state does not confirm stopped")
    instance = get(final, "instance", nothing)
    instance isa String && !ispath(joinpath(runtime, instance)) ||
        fail("owned deployment instance remains after shutdown")
    final
end

function validate_runtime(root::AbstractString)
    isfile(joinpath(root, "src", "PipeWireAODeployment.jl")) ||
        fail("unsupported legacy include-loaded deployment runtime; preserve this sealed SDK and use its original launcher, or export a new SDK with the named package")
    for name in ("Project.toml", "Manifest.toml", "deploy_cli.jl", "test/Project.toml", "test/runtests.jl")
        isfile(joinpath(root, name)) || fail("installed Julia deployment runtime is incomplete: $name")
    end
    metadata = TOML.parsefile(joinpath(root, "Project.toml"))
    owner = parentmodule(@__MODULE__)
    get(metadata, "name", nothing) == "PipeWireAODeployment" &&
        get(metadata, "uuid", nothing) == string(Base.PkgId(owner).uuid) ||
        fail("installed Julia deployment runtime has an unsupported package identity")
    version = tryparse(VersionNumber, get(metadata, "version", ""))
    version !== nothing && version.major == Base.pkgversion(owner).major &&
        version.minor == Base.pkgversion(owner).minor ||
        fail("installed Julia deployment runtime version is unsupported by this installer")
    for name in readdir(joinpath(ScienceExport.package_root(), "src"))
        endswith(name, ".jl") || continue
        isfile(joinpath(root, "src", name)) || fail("installed Julia deployment runtime is incomplete: src/$name")
    end
    resources = joinpath(root, "assets", "deployment")
    for directory in ("hil", "templates")
        for (parent, dirs, files) in walkdir(joinpath(ScienceExport.resource_root(), directory))
            filter!(name -> !(name in ("__pycache__", ".git")) && !startswith(name, "test_"), dirs)
            for name in files
                (startswith(name, "test_") || endswith(name, ".py")) && continue
                relative = relpath(joinpath(parent, name), ScienceExport.resource_root())
                isfile(joinpath(resources, relative)) && !islink(joinpath(resources, relative)) ||
                    fail("installed Julia deployment resources are incomplete: $relative")
            end
        end
    end
    for name in readdir(ScienceExport.resource_root())
        (endswith(name, ".jl") && !startswith(name, "test_")) || name == "pipewireao-rtc@.service.in" || continue
        isfile(joinpath(resources, name)) && !islink(joinpath(resources, name)) ||
            fail("installed Julia deployment resources are incomplete: $name")
    end
    return root
end

function selected_julia_executable(path::AbstractString)
    isabspath(path) && !occursin('\0', path) && !occursin('\n', path) &&
        !occursin('\r', path) || fail("--julia-executable must be an absolute executable path")
    isfile(path) && isexecutable(path) || fail("selected Julia executable is missing or not executable: $path")
    executable = realpath(path)
    probe = try
        Common.run_checked([executable, "--startup-file=no", "--history-file=no", "-e",
            "print(VERSION, '\\n', Base.julia_cmd().exec[1])"];
            timeout=15, maximum_output_bytes=4096)
    catch error
        fail("cannot validate selected Julia executable $path: $(sprint(showerror, error))")
    end
    fields = split(strip(probe.stdout), '\n')
    version = tryparse(VersionNumber, first(fields))
    probe.returncode == 0 && version !== nothing && v"1.12" <= version < v"2" ||
        fail("selected Julia executable must run Julia >= 1.12 and < 2: $path")
    length(fields) == 2 && isabspath(fields[2]) && isfile(fields[2]) && isexecutable(fields[2]) ||
        fail("selected Julia executable did not report its absolute runtime executable: $path")
    # Pin the managed runtime itself when selection was through juliaup.
    return realpath(fields[2])
end

shell_quote(value::AbstractString) = "'" * replace(value, "'" => "'\"'\"'") * "'"

function installed_wrappers(julia::AbstractString)
    executable = shell_quote(julia)
    scripts = Dict("pipewireao-rtc-deploy" => "#!/bin/sh\nexec $executable --startup-file=no --project=\"\$(dirname \"\$0\")/../julia\" \"\$(dirname \"\$0\")/../julia/deploy_cli.jl\" \"\$@\"\n")
    for (name, owner) in INSTALLED_ENTRYPOINTS
        scripts[name] = "#!/bin/sh\njulia_dir=\"\$(dirname \"\$0\")/../julia\"\n" *
            "exec $executable --startup-file=no --project=\"\$julia_dir\" -e " *
            "'using PipeWireAODeployment; " *
            "exit(PipeWireAODeployment.$owner.main(ARGS))' -- \"\$@\"\n"
    end
    return scripts
end

function install(options::NamedTuple)
    source = realpath(options.package)
    destination = abspath(options.destination)
    (source == destination || ispath(destination)) && fail("install destination must be a new directory")
    source_spec = profile(joinpath(source, "deployment.conf"), options.pipewire_prefix)
    source_runtime = joinpath(source, "julia")
    isdir(source_runtime) && validate_runtime(source_runtime)
    julia = selected_julia_executable(get(options, :julia_executable, Base.julia_cmd().exec[1]))
    scripts = installed_wrappers(julia)
    for (name, script) in scripts
        relative = "bin/$name"
        if haskey(source_spec["artifacts"], relative)
            read(joinpath(source, relative), String) == script ||
                fail("sealed $relative does not use the selected Julia executable; export a fresh SDK without installed wrappers and install it with --julia-executable $julia")
        end
    end
    cp(source, destination; force=false, follow_symlinks=true)
    installed_julia = joinpath(destination, "julia")
    isdir(installed_julia) || ScienceExport.copy_deployment_runtime(destination; copy_service=false)
    validate_runtime(installed_julia)
    bin = joinpath(destination, "bin")
    mkpath(bin)
    wrapper = joinpath(bin, "pipewireao-rtc-deploy")
    # Installation owns unsealed wrappers; sealed artifacts retain their bytes.
    for (name, script) in scripts
        entrypoint = joinpath(bin, name)
        if !haskey(source_spec["artifacts"], "bin/$name")
            write(entrypoint, script)
        end
        chmod(entrypoint, 0o755)
    end
    template = joinpath(installed_julia, "assets", "deployment", "pipewireao-rtc@.service.in")
    bin_template = joinpath(bin, basename(template))
    haskey(source_spec["artifacts"], "bin/" * basename(template)) ||
        cp(template, bin_template; force=true)
    unit = read(template, String)
    quote_unit(value) = String(JSON3.write(replace(value, "%" => "%%")))
    unit = replace(unit, "@LAUNCHER@" => quote_unit(wrapper),
        "@PIPEWIRE_PREFIX@" => quote_unit(abspath(options.pipewire_prefix)))
    spec = profile(joinpath(destination, "deployment.conf"), options.pipewire_prefix)
    cpus = sort!(collect(Set(cpu for contract in values(spec["placement"]) for cpu in contract["cpus"])))
    unit = replace(unit, "@CPUS@" => join(cpus, " "),
        "@FITS_ARGUMENT@" => (haskey(spec, "source-owner") ? "" :
            " --fits %h/.config/pipewireao-rtc/%i/input.fits"))
    systemd = joinpath(destination, "systemd")
    mkpath(systemd)
    write(joinpath(systemd, "pipewireao-rtc@.service"), unit)
    println(destination)
    destination
end

function _options(argv)
    isempty(argv) && fail("expected install, preflight, run, control, sessions or select-session")
    command = first(argv)
    command in ("install", "preflight", "run", "control", "sessions", "select-session") || fail("unknown command: $command")
    positionals = String[]
    parsed = Dict{String,String}()
    index = 2
    while index <= length(argv)
        arg = argv[index]
        if arg == "--" && command == "control"
            append!(positionals, argv[index+1:end])
            break
        elseif startswith(arg, "--")
            index < length(argv) || fail("missing value for $arg")
            haskey(parsed, arg) && fail("duplicate option: $arg")
            parsed[arg] = argv[index+1]
            index += 2
        else
            command == "control" || fail("unexpected argument: $arg")
            push!(positionals, arg)
            index += 1
        end
    end
    allowed = command == "install" ? Set(["--package", "--destination", "--pipewire-prefix", "--julia-executable"]) :
        command == "control" ? Set(["--runtime", "--session"]) :
        command == "sessions" ? Set{String}() :
        command == "select-session" ? Set(["--session"]) :
        Set(["--deployment", "--pipewire-prefix", "--fits", "--runtime"])
    command == "run" && push!(allowed, "--owner-preparation-timeout-seconds")
    isempty(setdiff(Set(keys(parsed)), allowed)) || fail("unsupported option for $command")
    preparation_timeout = tryparse(Int, get(parsed, "--owner-preparation-timeout-seconds", "90"))
    owner_preparation_timeout(preparation_timeout)
    options = (; command, deployment=get(parsed, "--deployment", ""),
        pipewire_prefix=get(parsed, "--pipewire-prefix", "/opt/pipewireao"),
        runtime=get(parsed, "--runtime", joinpath(get(ENV, "XDG_RUNTIME_DIR", "/run/user/$(ccall(:getuid, Cuint, ()))"), "pipewireao-rtc")),
        fits=get(parsed, "--fits", nothing), package=get(parsed, "--package", ""),
        destination=get(parsed, "--destination", ""), argv=positionals,
        session_id=get(parsed,"--session",nothing),
        julia_executable=get(parsed, "--julia-executable", Base.julia_cmd().exec[1]),
        owner_preparation_timeout_seconds=preparation_timeout)
    if command == "install"
        isempty(options.package) && fail("missing --package")
        isempty(options.destination) && fail("missing --destination")
    elseif command in ("preflight", "run")
        isempty(options.deployment) && fail("missing --deployment")
    elseif command == "control"
        xor(haskey(parsed,"--runtime"),haskey(parsed,"--session")) ||
            fail("control requires exactly one of --runtime or --session")
    elseif command == "select-session"
        options.session_id === nothing && fail("missing --session")
    end
    options.session_id === nothing || NativeSupervisorCodec.validate_uuid(options.session_id)
    options
end

function main(argv=ARGS)
    try
        options = _options(argv)
        if options.command == "install"
            install(options)
        elseif options.command == "sessions"
            println(JSON3.write([Dict("verification"=>string(entry.verification),
                "detail"=>entry.detail,"record"=>entry.record) for entry in list_sessions()]))
        elseif options.command == "select-session"
            connection = select_session(options.session_id)
            try
                println(JSON3.write(session_status(connection)))
            finally
                close(connection)
            end
        elseif options.command == "control"
            reply = options.session_id === nothing ?
                control(joinpath(options.runtime,"control.json"),options.argv;timeout=30) :
                control_session(options.session_id,options.argv;timeout=30)
            println(JSON3.write(reply))
        else
            deployment = DeploymentRunner(options)
            if options.command == "preflight"
                println(JSON3.write(preflight(deployment)))
            else
                Base.exit_on_sigint(false)
                atexit() do
                    if deployment.runtime !== nothing && ispath(deployment.runtime)
                        try
                            stop(deployment)
                            deployment.record["phase"] = "stopped"
                        catch error
                            deployment.record["phase"] = "failed"
                            deployment.record["error"] = sprint(showerror, error)
                        finally
                            deployment.record["admitted"] = false
                            try atomic_record(something(deployment.state_path), deployment.record) catch end
                            try rm(deployment.runtime; recursive=true, force=true) catch end
                        end
                    end
                end
                run(deployment)
            end
        end
        return 0
    catch error
        println(stderr, "pipewireao-rtc-deploy: ", sprint(showerror, error))
        return 1
    end
end

end
