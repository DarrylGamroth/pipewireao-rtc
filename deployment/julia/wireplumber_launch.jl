"""One-shot preparation for a WirePlumber-owned RTC session.

The installed WirePlumber unit calls `prepare!` from ExecStartPre. Its direct
ExecStart runs WirePlumber after this function returns. This module creates
processes and configuration; it never admits a session or issues source/link
operations. The Lua session profile owns those actions.

Owner names are exclusive per systemd invocation. A query followed by a stop
cannot be atomic; manual replacement of the same name is outside this workflow.
Observed retained PID, invocation, or cgroup mismatches fence cleanup.
"""
module WirePlumberLaunch

using PipeWireAODeployment
using Sockets
using UUIDs

const D = PipeWireAODeployment.DeploymentConfiguration
const C = PipeWireAODeployment.Common
const S = PipeWireAODeployment.SystemdOwners
const N = PipeWireAODeployment.NativeControlClient
const E = PipeWireAODeployment.ScienceExport
const P = PipeWireAODeployment.Placement

export Request, Prepared, prepare!, cleanup_invocation!, main

struct LaunchError <: Exception
    message::String
end
Base.showerror(io::IO, error::LaunchError) = print(io, error.message)
fail(message) = throw(LaunchError(message))
monotonic() = time_ns() / 1.0e9

struct Request
    package::String
    prefix::String
    unit::String
    launcher::String
    runtime_root::String
    function Request(package::AbstractString, prefix::AbstractString, unit::AbstractString,
                     launcher::AbstractString, runtime_root::AbstractString)
        paths = (package, prefix, launcher, runtime_root)
        all(isabspath, paths) || fail("package, prefix, launcher and runtime root must be absolute")
        all(value -> !occursin(r"[\n\r\0;]", value), paths) || fail("invalid launch path")
        occursin(r"^[A-Za-z0-9_.@-]+\.service$", unit) || fail("invalid WirePlumber unit name")
        new(String(package), String(prefix), String(unit), String(launcher), String(runtime_root))
    end
end

struct Prepared
    invocation::String
    runtime::String
    remote::String
    config::String
    owners::Dict{String,Any}
end

function cleanup_hook_valid(value::AbstractString, request::Request, source_role::AbstractString)
    prefix = "{ path=" * request.launcher * " ; argv[]=" * request.launcher *
        " cleanup --invocation \${INVOCATION_ID} --runtime-root " * request.runtime_root *
        " --source-role " * source_role * " ; ignore_errors=no ; "
    startswith(value, prefix) || return false
    suffix = chopprefix(value, prefix)
    occursin(r"^start_time=[^;{}]* ; stop_time=[^;{}]* ; pid=[0-9]+ ; code=[^;{}]* ; status=[^;{}]* \}$", suffix)
end

function preparation_identity(request::Request, source_role::AbstractString)
    values = S.properties(request.unit; extra="ControlPID,ExecStopPost,Restart,KillMode,Type")
    values["LoadState"] == "loaded" && values["ActiveState"] == "activating" ||
        fail("WirePlumber unit is not in start preparation")
    tryparse(Int, values["ControlPID"]) == getpid() ||
        fail("launcher is not the unit ExecStartPre ControlPID")
    invocation = S.valid_invocation(values["InvocationID"])
    S.valid_invocation(get(ENV, "INVOCATION_ID", "")) == invocation ||
        fail("launcher invocation environment differs from systemd")
    group = values["ControlGroup"]
    observed = S.proc_cgroup(getpid())
    startswith(group, "/") && group != "/" &&
        (observed == group || startswith(observed, group * "/")) ||
        fail("launcher is outside the WirePlumber unit cgroup")
    values["Restart"] == "no" && values["KillMode"] == "control-group" &&
        values["Type"] == "exec" || fail("WirePlumber unit has unexpected lifetime policy")
    cleanup_hook_valid(values["ExecStopPost"], request, source_role) ||
        fail("WirePlumber unit lacks its exact emergency cleanup hook")
    return S.Coordinator(request.unit, invocation, group, request.launcher)
end

function launch_record!(runtime, record)
    C.write_json(joinpath(runtime, "launch.json"), record; atomic=true)
end

function private_remote_environment(env, runtime, bindings)
    for (key, value) in ("PIPEWIREAO_RUNTIME_DIR" => runtime,
                         "PIPEWIRE_RUNTIME_DIR" => runtime,
                         "PIPEWIREAO_REMOTE" => bindings["REMOTE"],
                         "PIPEWIRE_REMOTE" => bindings["REMOTE"])
        get(env, key, nothing) == value ||
            fail("owner environment overrides private remote binding $key")
    end
    return env
end

function owner_environment(paths, spec, bindings, runtime, role)
    env = Dict{String,String}(ENV)
    for key in ("NOTIFY_SOCKET", "INVOCATION_ID", "JOURNAL_STREAM", "SYSTEMD_EXEC_PID")
        delete!(env, key)
    end
    merge!(env, Dict("LD_LIBRARY_PATH" => paths["library"],
        "PIPEWIREAO_RUNTIME_DIR" => runtime,
        "PIPEWIRE_RUNTIME_DIR" => runtime,
        "PIPEWIREAO_CONFIG_DIR" => joinpath(runtime, role),
        "PIPEWIREAO_MODULE_DIR" => paths["modules"],
        "PIPEWIREAO_SPA_PLUGIN_DIR" => paths["spa"],
        "PIPEWIREAO_FITS_PLUGIN" => joinpath(paths["spa"], "fits/libspa-fits.so"),
        "PIPEWIREAO_DISCARD_PLUGIN" => joinpath(paths["spa"], "discard/libspa-pipewireao-discard.so"),
        "PIPEWIREAO_REMOTE" => bindings["REMOTE"],
        "PIPEWIRE_REMOTE" => bindings["REMOTE"]))
    for (key, value) in spec["environment"]
        env[key] = D.substitute(value, bindings)
    end
    private_remote_environment(env, runtime, bindings)
    if !isempty(spec["owners"])
        env["JULIA_DEPOT_PATH"] = joinpath(runtime, "julia-depot") * ":" *
            get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia") * ":")
    end
    return env
end

function render_inputs!(request, spec, bindings, runtime)
    roles = collect(keys(spec["placement"]))
    for role in roles
        directory = joinpath(runtime, role)
        mkdir(directory; mode=0o700)
        for (key, output) in (("client", "client.conf"), ("core", "daemon.conf"),
                              ("session", "session.conf"))
            relative = key == "client" ? spec["client"][role] : spec[key]
            source = D.relative_asset(request.package, relative)
            write(joinpath(directory, output),
                D.substitute(read(source, String), bindings; quoted=true))
        end
    end
    graphs = joinpath(request.package, "graphs")
    if isdir(graphs)
        for name in readdir(graphs)
            endswith(name, ".conf.in") || continue
            source = D.relative_asset(request.package, joinpath("graphs", name))
            write(joinpath(runtime, name[1:end-3]),
                D.substitute(read(source, String), bindings; quoted=true))
        end
    end
    return D.decode(joinpath(runtime, "core", "session.conf"), request.prefix)
end

function prepare_julia_overlay!(request, paths, spec, runtime)
    isempty(spec["owners"]) && return nothing
    overlay = joinpath(runtime, "native-prefix")
    mkdir(overlay; mode=0o700)
    symlink(paths["library"], joinpath(overlay, "lib"))
    for name in ("bin", "share", "etc", "include")
        path = joinpath(request.prefix, name)
        ispath(path) && symlink(realpath(path), joinpath(overlay, name))
    end
    artifacts = joinpath(runtime, "julia-depot", "artifacts")
    mkpath(artifacts)
    write(joinpath(artifacts, "Overrides.toml"),
        "[cde84cf6-9a21-5ce0-b5e3-1526e778c30b]\nPipeWireAO = " *
        String(C.JSON3.write(overlay)) * "\n")
    return nothing
end

function parameter_owner!(request, spec, session, bindings, runtime)
    sources = filter(source -> get(source, "factory", nothing) ==
        "pipewireao.runtime-parameter", session["sources"])
    isempty(sources) && return nothing
    any(owner -> owner["role"] == "parameters", spec["owners"]) &&
        fail("parameter transport role conflicts with a declared owner")
    directory = joinpath(runtime, "parameters")
    mkdir(directory; mode=0o700)
    client = D.relative_asset(request.package, spec["client"]["rtc"])
    write(joinpath(directory, "client.conf"), D.substitute(read(client, String), bindings; quoted=true))
    declarations = Any[]
    for source in sources
        ports = source["ports"]
        length(ports) == 1 || fail("parameter source must have exactly one declared output")
        port = only(ports)
        get(port, "parameter", false) === true && port["direction"] == "output" &&
            port["name"] == "output_1" && port["element-type"] == "F32_LE" ||
            fail("unsupported parameter source contract")
        address = source["node.name"] * ":" * port["name"]
        links = filter(link -> link["output"] == address, session["links"])
        length(links) == 1 || fail("parameter source needs one exact declared destination")
        target = only(links)["input"]
        names = split(target, ':'; limit=2)
        length(names) == 2 || fail("invalid parameter destination")
        graphs = filter(graph -> graph["node.name"] == names[1], session["graphs"])
        length(graphs) == 1 || fail("parameter destination graph is undeclared")
        inputs = filter(input -> input["name"] == names[2] && input["direction"] == "input",
            only(graphs)["ports"])
        length(inputs) == 1 || fail("parameter destination port is undeclared")
        input = only(inputs)
        get(input, "parameter", false) === true && all(key ->
            get(input, key, nothing) == get(port, key, nothing),
            ("element-type", "shape", "schema")) || fail("parameter contracts differ")
        layout = get(port, "layout", "ROW_MAJOR")
        layout in ("ROW_MAJOR", "COLUMN_MAJOR") && get(input, "layout", layout) == layout ||
            fail("parameter layouts differ")
        row = Dict{String,Any}("node_name" => source["node.name"], "graph" => String(names[1]),
            "inlet" => String(names[2]), "shape" => port["shape"], "element_type" => "F32_LE",
            "schema" => get(port, "schema", ""),
            "layout" => layout == "ROW_MAJOR" ? "row-major" : "column-major")
        initial = get(get(session, "parameters", Dict()), target, nothing)
        if initial !== nothing
            initial isa String && startswith(initial, "PIPEWIREAO_RTC_PARAMETER_") ||
                fail("initial parameter must name a declared artifact binding")
            value = get(spec["environment"], initial, nothing)
            value isa String || fail("initial parameter artifact binding is absent")
            row["initial_payload_path"] = D.substitute(value, bindings)
        end
        push!(declarations, row)
    end
    config = joinpath(directory, "sources.json")
    C.write_json(config, Dict("version" => 1, "sources" => declarations))
    chmod(config, 0o600)
    executable = realpath(Base.julia_cmd().exec[1])
    isfile(executable) && Sys.isexecutable(executable) ||
        fail("Current Julia runtime is unavailable for parameter transport")
    script = D.relative_asset(request.package, "julia/assets/deployment/hil/parameter_source.jl")
    bootstrap = "pipewireao.rtc.bootstrap.parameters"
    control = "pipewireao.rtc.parameters." * spec["name"]
    bindings["BOOTSTRAP_INSTANCE_PARAMETERS"] = string(N.next_instance())
    bindings["PARAMETER_OWNER_INSTANCE"] = string(N.next_instance())
    return Dict{String,Any}("role" => "parameters", "bootstrap-node" => bootstrap,
        "bootstrap-protocol" => "pipewireao.rtc.owner-bootstrap/1",
        "control-node" => control, "control-protocol" => "pipewireao.rtc.parameter-source/1",
        "control-instance" => bindings["PARAMETER_OWNER_INSTANCE"],
        "environment" => Dict("OPENBLAS_NUM_THREADS" => "1"),
        "argv" => [executable, "--startup-file=no", "--threads=2,0",
            "--project=" * joinpath(request.package, "julia"), script,
            "--config", config, "--remote", joinpath(runtime, bindings["REMOTE"]),
            "--bootstrap-node", bootstrap, "--bootstrap-instance", bindings["BOOTSTRAP_INSTANCE_PARAMETERS"],
            "--control-node", control, "--control-instance", bindings["PARAMETER_OWNER_INSTANCE"]])
end

function launch_owner!(coordinator, role, argv, env, cwd, placement, runtime, record)
    service = S.Service(coordinator, role)
    saved() = merge(S.record(service), Dict{String,Any}(
        "role" => role, "placement" => deepcopy(placement)))
    record["owners"][role] = saved()
    launch_record!(runtime, record) # Retain the name before systemd-run is submitted.
    command = S.launch_command(service, argv, env, cwd, placement)
    before = S.properties(service.unit)
    before["LoadState"] == "not-found" || fail("owner unit name is already reserved: $(service.unit)")
    any(pair -> pair.second == service.unit, S.listed_jobs(coordinator.invocation)) &&
        fail("owner unit has a pending start job")
    service.state = :launching
    record["owners"][role] = saved()
    launch_record!(runtime, record)
    result_error = nothing
    try
        result = S.checked(command; timeout=20)
        result.returncode == 0 || (result_error = "systemd-run failed with status $(result.returncode)")
    catch error
        result_error = "systemd-run outcome uncertain: " * sprint(showerror, error)
    end
    try
        values = S.properties(service.unit)
        values["LoadState"] == "not-found" && fail("owner unit is not visible after launch")
        S.retain!(service, values)
        record["owners"][role] = saved()
        launch_record!(runtime, record)
        result_error === nothing || fail(result_error)
        return service
    catch error
        service.state = :uncertain
        service.error = sprint(showerror, error)
        record["owners"][role] = saved()
        launch_record!(runtime, record)
        rethrow()
    end
end

function wait_core!(service, socket; seconds=15)
    deadline = monotonic() + seconds
    while monotonic() < deadline
        S.alive(service) || fail("private core exited before its socket was available")
        if ispath(socket)
            try
                close(Sockets.connect(socket))
                return nothing
            catch error
                error isa IOError || error isa SystemError || rethrow()
            end
        end
        sleep(0.05)
    end
    fail("private core socket did not become available")
end

function fgn_graphs(session)
    graphs = get(session, "graphs", Any[])
    graphs isa AbstractVector || fail("session graphs must be a list")
    return filter(graph -> get(graph, "factory", nothing) == "pipewireao.fgn-native", graphs)
end

function graph_arguments(graph, env, runtime, prefix)
    get(graph, "module", nothing) == "libpipewire-module-ndarray-filter-chain" ||
        fail("FGN host requires the maintained ndarray filter-chain module")
    token = get(graph, "config.path", nothing)
    token isa String || fail("FGN graph has no configuration path")
    match_result = match(r"^\$\{([A-Z][A-Z0-9_]*)\}$", token)
    match_result === nothing && fail("FGN graph configuration must use a declared environment binding")
    path = get(env, match_result.captures[1], "")
    isfile(path) && startswith(realpath(path), realpath(runtime) * "/") ||
        fail("FGN graph configuration is not a rendered invocation asset")
    args = D.decode(path, prefix)
    get(args, "node.name", nothing) == get(graph, "node.name", nothing) &&
        get(graph, "node.name", nothing) isa String ||
        fail("FGN graph node differs from its rendered host module")
    return args
end

function render_fgn_host!(request, spec, session, env, runtime)
    graphs = fgn_graphs(session)
    isempty(graphs) && return String[]
    host = joinpath(runtime, "fgn")
    mkdir(host; mode=0o700)
    template = D.relative_asset(request.package, spec["client"]["rtc"])
    config = D.decode(template, request.prefix)
    context = config["context.properties"]
    context["core.daemon"] = false
    for graph in graphs
        push!(config["context.modules"], Dict("name" => graph["module"],
            "args" => graph_arguments(graph, env, runtime, request.prefix)))
    end
    E.write_spa_config(joinpath(host, "client-host.conf"), config)
    names = String[graph["node.name"] for graph in graphs]
    length(unique(names)) == length(names) || fail("FGN graph names must be unique")
    return names
end

function atomic_environment(path, values)
    temporary, io = mktemp(dirname(path); cleanup=false)
    try
        chmod(temporary, 0o600)
        for key in sort!(collect(keys(values)))
            occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", key) ||
                fail("invalid WirePlumber environment key")
            value = values[key]
            !occursin(r"[\n\r\0]", value) || fail("invalid WirePlumber environment path")
            escaped = replace(value, "\\" => "\\\\", "\"" => "\\\"")
            write(io, key, "=\"", escaped, "\"\n")
        end
        close(io)
        mv(temporary, path; force=true)
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    return path
end

"""Prepare a fresh invocation in ExecStartPre. The callback writes standard
WirePlumber SPA-JSON and returns its absolute path. It receives the validated
deployment spec, decoded rendered session, resolved bindings, exact owner
records, and invocation runtime.
It must not release the source or realize links.
"""
function prepare!(request::Request; render!::Function)
    package = realpath(request.package)
    prefix = realpath(request.prefix)
    spec = D.profile(joinpath(package, "deployment.conf"), prefix)
    spec["cpu-latency-us"] === nothing ||
        fail("WirePlumber session does not yet retain a CPU DMA latency lease; cpu-latency-us must be null")
    source_role = get(spec, "source-owner", nothing)
    source_role isa String && any(owner -> owner["role"] == source_role, spec["owners"]) ||
        fail("WirePlumber session requires a declared held source owner")
    coordinator = preparation_identity(request, source_role)
    invocation = coordinator.invocation
    root = request.runtime_root
    isdir(root) && !islink(root) || fail("private runtime root is unavailable")
    stat(root).uid == ccall(:getuid, Cuint, ()) && (stat(root).mode & 0o777) == 0o700 ||
        fail("private runtime root must be owned with mode 0700")
    locator = joinpath(root, "current.env")
    ispath(locator) && rm(locator) # A stale ExecStart environment cannot be reused.
    runtime = joinpath(root, invocation)
    mkdir(runtime; mode=0o700) # Never reuse a previous invocation directory.
    chmod(runtime, 0o700)
    remote_name = "rtc-" * invocation[1:12]
    remote = joinpath(runtime, remote_name)
    ncodeunits(remote) <= 100 || fail("private core socket path exceeds the Unix socket bound")
    session_uuid = string(uuid4())
    bindings = Dict{String,String}("PACKAGE" => package, "PREFIX" => prefix,
        "RUNTIME" => runtime, "REMOTE" => remote_name, "INSTANCE" => invocation,
        "SESSION_UUID" => session_uuid,
        "ADMISSION_CONTROLLER_INSTANCE" => string(N.next_instance()),
        "SESSION_CONTROL_INSTANCE" => string(N.next_instance()),
        "SESSION_CONTROLLER_INSTANCE" => string(N.next_instance()))
    for owner in spec["owners"]
        D.native_bootstrap(owner) || continue
        bindings[D.bootstrap_instance_key(owner["role"])] = string(N.next_instance())
    end
    if any(D.native_heart, spec["owners"])
        heart = only(filter(D.native_heart, spec["owners"]))
        bindings["HEART_OWNER_NODE"] = heart["control-node"]
        bindings["HEART_OWNER_INSTANCE"] = string(N.next_instance())
    end
    source = only(filter(owner -> owner["role"] == source_role, spec["owners"]))
    D.native_acquisition(source) &&
        (bindings["SOURCE_OWNER_INSTANCE"] = string(N.next_instance()))
    paths = D.installed_paths(prefix)
    session = render_inputs!(request, spec, bindings, runtime)
    parameters = parameter_owner!(request, spec, session, bindings, runtime)
    if parameters !== nothing
        push!(spec["owners"], parameters)
        spec["placement"]["parameters"] = deepcopy(spec["placement"]["wireplumber"])
        contract = spec["placement"]["parameters"]
        push!(contract["threads"], Dict("cpus" => [contract["leader-cpu"]],
            "policy" => "other", "priority" => 0, "name" => "rtc-bootstrap", "count" => 1))
    end
    !isempty(fgn_graphs(session)) && any(owner -> owner["role"] == "fgn", spec["owners"]) &&
        fail("FGN host role conflicts with a declared external owner")
    prepare_julia_overlay!(request, paths, spec, runtime)
    record = Dict{String,Any}("version" => 1, "phase" => "preparing", "name" => spec["name"],
        "unit" => request.unit, "invocation" => invocation, "session_uuid" => session_uuid,
        "session_control_instance" => parse(Int64, bindings["SESSION_CONTROL_INSTANCE"]),
        "session_controller_instance" => parse(Int64, bindings["SESSION_CONTROLLER_INSTANCE"]),
        "admission_controller_instance" => parse(Int64, bindings["ADMISSION_CONTROLLER_INSTANCE"]),
        "source_role" => source_role, "runtime" => runtime, "remote" => remote,
        "owners" => Dict{String,Any}(), "error" => nothing)
    launch_record!(runtime, record)
    try
        contracts = collect(values(spec["placement"]))
        priority = maximum(contract["rt-priority"] for contract in contracts)
        locked = maximum(contract["locked-bytes"] for contract in contracts)
        record["credentials"] = P.credentials(priority, locked, spec["cpu-latency-us"])
        launch_record!(runtime, record)
        core_env = owner_environment(paths, spec, bindings, runtime, "core")
        core = launch_owner!(coordinator, "core", [paths["daemon"], "-c", "daemon.conf"],
            core_env, joinpath(runtime, "core"), spec["placement"]["core"], runtime, record)
        wait_core!(core, remote)
        owner_records = record["owners"]
        for owner in spec["owners"]
            role = owner["role"]
            env = owner_environment(paths, spec, bindings, runtime, role)
            for (key, value) in owner["environment"]
                env[key] = D.substitute(value, bindings)
            end
            private_remote_environment(env, runtime, bindings)
            argv = [D.substitute(arg, bindings) for arg in owner["argv"]]
            service = launch_owner!(coordinator, role, argv, env,
                joinpath(runtime, role), spec["placement"][role], runtime, record)
            D.native_heart(owner) && (bindings["HEART_OWNER_PID"] = string(S.pid(service)))
            control_instance = D.native_heart(owner) ? bindings["HEART_OWNER_INSTANCE"] :
                D.native_acquisition(owner) ? bindings["SOURCE_OWNER_INSTANCE"] :
                get(owner, "control-instance", nothing)
            owner_records[role] = merge(owner_records[role], Dict{String,Any}(
                "bootstrap-node" => get(owner, "bootstrap-node", nothing),
                "bootstrap-instance" => get(bindings, D.bootstrap_instance_key(role), nothing),
                "control-node" => get(owner, "control-node", nothing),
                "control-protocol" => get(owner, "control-protocol", nothing),
                "control-instance" => control_instance))
            launch_record!(runtime, record)
        end
        host_env = owner_environment(paths, spec, bindings, runtime, "fgn")
        fgn_nodes = render_fgn_host!(request, spec, session, host_env, runtime)
        if !isempty(fgn_nodes)
            host = launch_owner!(coordinator, "fgn", [paths["daemon"], "-c", "client-host.conf"],
                host_env, joinpath(runtime, "fgn"), spec["placement"]["rtc"], runtime, record)
            owner_records["fgn"]["graph-nodes"] = fgn_nodes
            launch_record!(runtime, record)
            S.alive(host) || fail("FGN client host exited during preparation")
        end
        config = render!(spec, session, bindings, deepcopy(owner_records), runtime)
        config isa AbstractString && isabspath(config) && isfile(config) &&
            startswith(realpath(config), realpath(runtime) * "/") ||
            fail("session generator did not return a private invocation configuration")
        generated = D.decode(String(config), prefix)
        all(haskey(generated, key) for key in
            ("context.properties", "wireplumber.profiles", "wireplumber.components")) ||
            fail("session generator did not emit a standard WirePlumber SPA-JSON configuration")
        get(generated["context.properties"], "remote.name", nothing) == remote ||
            fail("WirePlumber configuration targets a different private core")
        final_coordinator = preparation_identity(request, source_role)
        final_coordinator.invocation == invocation &&
            final_coordinator.cgroup == coordinator.cgroup ||
            fail("WirePlumber unit incarnation changed during preparation")
        for (role, item) in owner_records
            service = S.Service(coordinator, role)
            service.main_pid = Int(item["pid"])
            service.invocation = String(item["invocation"])
            service.start_ticks = UInt64(item["start-ticks"])
            service.cgroup = String(item["cgroup"])
            service.state = :running
            S.verify!(service)
        end
        record["phase"] = "prepared"
        record["config"] = String(config)
        launch_record!(runtime, record)
        wp_env = Dict{String,String}(
            "WIREPLUMBER_CONFIG_DIR" => dirname(String(config)),
            "WIREPLUMBER_CONFIG" => String(config),
            "PIPEWIRE_RUNTIME_DIR" => runtime,
            "PIPEWIRE_REMOTE" => remote,
            "PIPEWIREAO_REMOTE" => remote,
            "LD_LIBRARY_PATH" => paths["library"],
            "PIPEWIREAO_MODULE_DIR" => paths["modules"],
            "PIPEWIREAO_SPA_PLUGIN_DIR" => paths["spa"])
        if haskey(spec, "session-manager")
            for (key, value) in spec["session-manager"]["environment"]
                key in ("INVOCATION_ID", "NOTIFY_SOCKET", "SYSTEMD_EXEC_PID") &&
                    fail("session manager environment cannot override systemd identity")
                wp_env[key] = D.substitute(value, bindings)
            end
        end
        for (key, value) in ("PIPEWIRE_RUNTIME_DIR" => runtime, "PIPEWIRE_REMOTE" => remote,
                             "WIREPLUMBER_CONFIG_DIR" => dirname(String(config)),
                             "WIREPLUMBER_CONFIG" => String(config))
            get(wp_env, key, nothing) == value ||
                fail("session manager environment overrides private binding $key")
        end
        atomic_environment(locator, wp_env)
        return Prepared(invocation, runtime, remote, String(config), deepcopy(owner_records))
    catch error
        record["phase"] = "failed"
        record["error"] = sprint(showerror, error)
        launch_record!(runtime, record)
        # ExecStopPost runs after a failed ExecStartPre. It performs the same
        # core/source-first cleanup using this retained launch ledger.
        rethrow()
    end
end

function load_record(runtime, invocation, source_role)
    path = joinpath(runtime, "launch.json")
    isfile(path) || fail("invocation launch ledger is unavailable")
    record = C.read_json(path; maximum=1024 * 1024)
    record["invocation"] == invocation && record["source_role"] == source_role ||
        fail("invocation launch ledger identity differs from cleanup request")
    return record
end

function retained_service(record, role)
    item = get(record["owners"], role, nothing)
    item isa AbstractDict || return nothing
    get(item, "state", "") in ("running", "uncertain") || return nothing
    get(item, "pid", 0) > 0 && !isempty(get(item, "invocation", "")) &&
        !isempty(get(item, "cgroup", "")) || return nothing
    owner = S.Coordinator(String(record["unit"]), String(record["invocation"]), "", "")
    service = S.Service(owner, role)
    service.main_pid = Int(item["pid"])
    service.invocation = String(item["invocation"])
    service.start_ticks = UInt64(item["start-ticks"])
    service.cgroup = String(item["cgroup"])
    service.state = :running
    return service
end

function cleanup_role!(record, role, deadline)
    invocation = record["invocation"]
    unit = S.PREFIX * invocation * "-" * role * ".service"
    for job in S.listed_jobs(invocation; deadline)
        job.second == unit && S.cancel_job(job.first; deadline)
    end
    retained = retained_service(record, role)
    if retained === nothing
        item = get(record["owners"], role, nothing)
        uncertain = item isa AbstractDict && get(item, "state", "") in ("launching", "uncertain")
        if uncertain && S.properties(unit; deadline)["LoadState"] == "not-found"
            fail("owner launch outcome remains uncertain for $unit")
        end
        S.cleanup_unit(unit; deadline)
    else
        # A retained PID/start time and cgroup fence a replaced unit. This
        # query/stop pair is not atomic; unit-name exclusivity is required.
        S.stop!(retained, 0)
    end
    return nothing
end

"""ExecStopPost fallback. Revoke the private core and held source before any
consumer; each stop must confirm its cgroup is empty. A failed core/source
stop fences later cleanup and leaves diagnostics for operator recovery.
"""
function cleanup_invocation!(runtime_root::AbstractString, id::AbstractString;
                             source_role::AbstractString)
    invocation = S.valid_invocation(id)
    S.valid_invocation(get(ENV, "INVOCATION_ID", "")) == invocation ||
        fail("cleanup invocation differs from the WirePlumber service environment")
    occursin(S.ROLE, source_role) || fail("invalid source role for cleanup")
    runtime = joinpath(runtime_root, invocation)
    record = try
        load_record(runtime, invocation, source_role)
    catch error
        # If the ledger is unreadable, only ingress can be safely revoked by
        # the exact invocation names. Consumer cleanup remains fenced.
        deadline = monotonic() + 45
        for role in ("core", String(source_role))
            unit = S.PREFIX * invocation * "-" * role * ".service"
            for job in S.listed_jobs(invocation; deadline)
                job.second == unit && S.cancel_job(job.first; deadline)
            end
            S.cleanup_unit(unit; deadline)
        end
        fail("owner ledger unavailable after core/source revocation: " * sprint(showerror, error))
    end
    try
        cleanup_record!(runtime, record, invocation, source_role)
    catch error
        record["phase"] = "failed"
        record["error"] === nothing && (record["error"] = sprint(showerror, error))
        push!(get!(record, "cleanup_errors", String[]), sprint(showerror, error))
        launch_record!(runtime, record)
        rethrow()
    end
    return nothing
end

function cleanup_record!(runtime, record, invocation, source_role)
    deadline = monotonic() + 240
    units = S.listed_units(invocation; deadline)
    jobs = S.listed_jobs(invocation; deadline)
    names = Set(vcat(units, last.(jobs)))
    roles = Set{String}()
    prefix = S.PREFIX * invocation * "-"
    for unit in names
        startswith(unit, prefix) && endswith(unit, ".service") || continue
        role = unit[ncodeunits(prefix)+1:end-ncodeunits(".service")]
        occursin(S.ROLE, role) && push!(roles, role)
    end
    union!(roles, String.(keys(record["owners"])))
    for role in ("core", String(source_role))
        role in roles || continue
        cleanup_role!(record, role, deadline)
    end
    for role in sort!(collect(setdiff(roles, Set(["core", String(source_role)]))))
        cleanup_role!(record, role, deadline)
    end
    # Start requests may materialize after the first enumeration. Repeat the
    # exact-prefix sweep; never accept a single empty listing as completion.
    quiet = 0
    while monotonic() < deadline
        units = S.listed_units(invocation; deadline)
        jobs = S.listed_jobs(invocation; deadline)
        if isempty(jobs) && all(unit -> S.quiescent_unit(unit; deadline), units)
            quiet += 1
            quiet >= 3 && break
            sleep(0.05)
            continue
        end
        quiet = 0
        for role in ("core", String(source_role))
            cleanup_role!(record, role, deadline)
        end
        for unit in units
            startswith(unit, prefix) && endswith(unit, ".service") || continue
            role = unit[ncodeunits(prefix)+1:end-ncodeunits(".service")]
            role in ("core", source_role) && continue
            occursin(S.ROLE, role) && cleanup_role!(record, role, deadline)
        end
    end
    quiet >= 3 || fail("WirePlumber invocation cleanup exceeded its deadline")
    result = get(ENV, "SERVICE_RESULT", "")
    record["service_result"] = result
    record["cleanup_complete"] = true
    if result == "success" && record["error"] === nothing
        record["phase"] = "stopped"
    else
        record["phase"] = "failed"
        record["error"] === nothing &&
            (record["error"] = "WirePlumber service exited with result " *
                (isempty(result) ? "unknown" : result))
    end
    launch_record!(runtime, record)
    return nothing
end

"""Thin CLI adapter for an installed launcher entrypoint. The entrypoint
provides the session renderer; this module supplies no fallback policy.
"""
function main(argv=ARGS; render! = nothing)
    isempty(argv) && fail("expected prepare or cleanup")
    command = first(argv)
    if command == "prepare"
        render! isa Function || fail("WirePlumber session renderer is unavailable")
        args = C.cli_arguments(argv[2:end];
            required=["package", "prefix", "unit", "launcher", "runtime-root"])
        request = Request(args.package, args.prefix, args.unit, args.launcher, args.runtime_root)
        prepare!(request; render! = render!)
    elseif command == "cleanup"
        args = C.cli_arguments(argv[2:end]; required=["invocation", "runtime-root", "source-role"])
        cleanup_invocation!(args.runtime_root, args.invocation; source_role=args.source_role)
    else
        fail("unknown WirePlumber launch command")
    end
    return 0
end

end # module
