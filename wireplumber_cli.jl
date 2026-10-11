#!/usr/bin/env julia
"""One-shot systemd commands for the opt-in WirePlumber RTC unit."""
module WirePlumberCLI

using PipeWireAODeployment
using PipeWireAO: with_thread_loop_lock
using JSON3

include("wireplumber_configuration.jl")
include("wireplumber_launch.jl")
include("wireplumber_install.jl")

const C = PipeWireAODeployment.Common
const D = PipeWireAODeployment.DeploymentConfiguration
const S = PipeWireAODeployment.SystemdOwners
const P = PipeWireAODeployment.Placement
const Discovery = PipeWireAODeployment.NativeSessionDiscovery
const Client = PipeWireAODeployment.NativeControlClient
const Session = PipeWireAODeployment.NativeSessionCodec
const Profile = PipeWireAODeployment.NativeSessionProfile
const SessionClient = PipeWireAODeployment.NativeSessionClient
const Commands = PipeWireAODeployment.RunnerCommands

export main

function node_owners(spec)
    mapping = get(spec, "node-owners", nothing)
    mapping isa AbstractDict ||
        throw(ArgumentError("one-shot session requires exact node-owners in deployment.conf"))
    return Dict{String,String}(mapping)
end

function render!(spec, session, bindings, records, runtime)
    return WirePlumberConfiguration.write_session_config(
        spec, session, bindings, records, runtime; node_owners=node_owners(spec))
end

function _preflight(argv)
    args = C.cli_arguments(argv;
        required=["package", "prefix", "unit", "launcher", "runtime-root"])
    spec = D.profile(joinpath(args.package, "deployment.conf"), args.prefix)
    node_owners(spec)
    return nothing
end

function _unit_identity(unit, invocation, runtime_root, launcher, source_role)
    values = S.properties(unit; extra="ControlPID,ExecStop,ExecStopPost,Restart,KillMode,Type")
    values["LoadState"] == "loaded" &&
        values["ActiveState"] in ("activating", "active") &&
        values["Type"] == "exec" && values["Restart"] == "no" &&
        values["KillMode"] == "control-group" ||
        throw(ArgumentError("WirePlumber unit has unexpected post-start policy"))
    S.valid_invocation(values["InvocationID"]) == invocation &&
        tryparse(Int, values["ControlPID"]) == getpid() ||
        throw(ArgumentError("publisher is not this unit's ExecStartPost process"))
    group = values["ControlGroup"]
    startswith(group, "/") && group != "/" &&
        (S.proc_cgroup(getpid()) == group ||
         startswith(S.proc_cgroup(getpid()), group * "/")) ||
        throw(ArgumentError("publisher is outside the WirePlumber unit cgroup"))
    request = WirePlumberLaunch.Request(dirname(launcher), dirname(launcher),
        unit, launcher, runtime_root)
    WirePlumberLaunch.cleanup_hook_valid(values["ExecStopPost"], request, source_role) ||
        throw(ArgumentError("WirePlumber emergency cleanup hook changed"))
    WirePlumberLaunch.stop_hook_valid(values["ExecStop"], request) ||
        throw(ArgumentError("WirePlumber native stop hook changed"))
    pid = tryparse(Int, values["MainPID"])
    pid !== nothing && 0 < pid <= typemax(UInt32) ||
        throw(ArgumentError("WirePlumber MainPID is unavailable"))
    ticks = S.start_ticks(pid)
    observed = S.proc_cgroup(pid)
    (observed == group || startswith(observed, group * "/")) ||
        throw(ArgumentError("WirePlumber MainPID left its unit cgroup"))
    return pid, ticks, group
end

function _verified_discovery!(record, session_record)
    # NativeSessionDiscovery.publish! remains owner-only. ExecStartPost is a
    # distinct process, so this narrow path writes only after live systemd and
    # direct native Status proof in publish! below.
    directory = Discovery.registry_directory()
    pod = Discovery.encode_record(session_record)
    path = joinpath(directory, "session-" * session_record.session_id * ".pod")
    Discovery._with_registry_lock(directory) do
        if Discovery._check_file(path; absent_ok=true) !== nothing
            prior = Discovery._read_record(path)
            (prior.session_id, prior.owner_pid, prior.incarnation, prior.remote, prior.node_name) ==
                (session_record.session_id, session_record.owner_pid,
                 session_record.incarnation, session_record.remote, session_record.node_name) ||
                throw(ArgumentError("different session already owns discovery UUID"))
        end
        Discovery._atomic_replace(directory, path, pod)
    end
    record["discovery_locator"] = path
    return path
end

function _placement_snapshot(record, unit, invocation, launcher, group, wp_pid, wp_contract)
    owner = S.Coordinator(unit, invocation, group, launcher)
    snapshots = Dict{String,Any}()
    for (role, item) in record["owners"]
        item["role"] == role && item["state"] == "running" ||
            throw(ArgumentError("recorded owner is not running at session publication"))
        service = S.Service(owner, role)
        item["unit"] == service.unit ||
            throw(ArgumentError("recorded owner unit differs from exclusive invocation name"))
        service.main_pid = Int(item["pid"])
        service.invocation = String(item["invocation"])
        service.start_ticks = UInt64(item["start-ticks"])
        service.cgroup = String(item["cgroup"])
        service.state = :running
        S.verify!(service)
        snapshots[role] = P.snapshot(service.main_pid, item["placement"])
        S.verify!(service)
    end
    snapshots["wireplumber"] = P.snapshot(wp_pid, wp_contract)
    return snapshots
end

function publish!(args)
    invocation = S.valid_invocation(get(ENV, "INVOCATION_ID", ""))
    runtime = joinpath(args.runtime_root, invocation)
    ledger = joinpath(runtime, "launch.json")
    record = C.read_json(ledger; maximum=1024 * 1024)
    record["unit"] == args.unit && record["invocation"] == invocation &&
        record["phase"] == "prepared" ||
        throw(ArgumentError("launch ledger does not identify prepared WirePlumber unit"))
    package = D.profile(joinpath(args.package, "deployment.conf"), args.prefix)
    name = package["name"]
    source_role = package["source-owner"]
    name isa String && occursin(r"^[a-z0-9][a-z0-9-]{0,39}$", name) &&
        name == record["name"] &&
        source_role == record["source_role"] ||
        throw(ArgumentError("deployment identity differs from prepared invocation"))
    launcher = joinpath(args.package, "bin", "pipewireao-rtc-session")
    pid, ticks, group = _unit_identity(args.unit, invocation, args.runtime_root,
        launcher, source_role)
    expected = Int64(record["session_control_instance"])
    uuid = String(record["session_uuid"])
    remote = String(record["remote"])
    node = "pipewireao.rtc.session." * name
    deadline = Client.monotonic() + (haskey(package, "startup-timeout-ms") ?
        D.startup_timeout_ms(package) / 1000 : 240)
    client = Client.connect(Profile.Profile(), remote, node, UInt32(pid), expected;
        deadline=min(deadline, Client.monotonic() + 30),
        controller_instance=Int64(record["admission_controller_instance"]))
    snapshots = nothing
    try
        while true
            Client.monotonic() < deadline ||
                throw(ArgumentError("direct session did not warm before publication deadline"))
            warm = Client.request!(client, Session.WarmupCommand();
                deadline=min(deadline, Client.monotonic() + 10))
            warm isa Session.AdministrativeCompletion &&
                warm.header.operation == UInt32(15) && warm.header.result == 0 &&
                warm.error === nothing && warm.lifecycle == Session.Runner.Configuring ||
                throw(ArgumentError("direct session warmup query did not retain Configuring"))
            warm.warmed === true && break
            sleep(min(0.1, max(0.0, deadline - Client.monotonic())))
        end
        latest_pid, latest_ticks, latest_group = _unit_identity(args.unit, invocation,
            args.runtime_root, launcher, source_role)
        (pid, ticks, group) == (latest_pid, latest_ticks, latest_group) ||
            throw(ArgumentError("WirePlumber process changed during warmup"))
        snapshots = _placement_snapshot(record, args.unit, invocation, launcher, group,
            pid, package["placement"]["wireplumber"])
        latest_pid, latest_ticks, latest_group = _unit_identity(args.unit, invocation,
            args.runtime_root, launcher, source_role)
        (pid, ticks, group) == (latest_pid, latest_ticks, latest_group) ||
            throw(ArgumentError("WirePlumber process changed during placement inspection"))
        record["placement_snapshot"] = snapshots
        C.write_json(ledger, record; atomic=true)
        admit = Client.request!(client, Session.AdmitCommand();
            deadline=min(deadline, Client.monotonic() + 10))
        admit isa Session.AdministrativeCompletion &&
            admit.header.operation == UInt32(16) && admit.header.result == 0 &&
            admit.error === nothing && admit.warmed === true &&
            admit.lifecycle == Session.Runner.Ready ||
            throw(ArgumentError("direct session admission did not reach Ready"))
        completion = Client.request!(client, Session.RunnerCommand(:status);
            deadline=min(deadline, Client.monotonic() + 10))
        completion isa Session.Completion &&
            completion.header.operation == UInt32(3) && completion.header.result == 0 &&
            completion.result !== nothing && completion.error === nothing &&
            completion.lifecycle == Session.Runner.Ready ||
            throw(ArgumentError("fresh direct Status did not confirm Ready"))
        with_thread_loop_lock(client.loop) do _
            Client.healthy(client)
            client.observation.node_identity == uuid &&
                client.observation.owner_pid == UInt32(pid) &&
                client.observation.instance == expected &&
                client.global_id > 0 && client.global_id < typemax(UInt32) &&
                client.serial > 0 ||
                throw(ArgumentError("direct native Status identity differs from prepared session"))
        end
    finally
        close(client)
    end
    latest_pid, latest_ticks, latest_group = _unit_identity(args.unit, invocation,
        args.runtime_root, launcher, source_role)
    (pid, ticks, group) == (latest_pid, latest_ticks, latest_group) ||
        throw(ArgumentError("WirePlumber process changed during direct Status proof"))
    session_record = Discovery.SessionRecord(name, uuid, UInt32(pid), expected, remote, node)
    directory = Discovery.registry_directory()
    record["wireplumber_pid"] = pid
    record["wireplumber_start_ticks"] = ticks
    record["placement_snapshot"] = snapshots
    record["discovery_locator"] = joinpath(directory, "session-" * uuid * ".pod")
    C.write_json(ledger, record; atomic=true)
    _verified_discovery!(record, session_record)
    return nothing
end

function retire!(runtime_root)
    invocation = S.valid_invocation(get(ENV, "INVOCATION_ID", ""))
    ledger = joinpath(runtime_root, invocation, "launch.json")
    isfile(ledger) || return nothing
    record = C.read_json(ledger; maximum=1024 * 1024)
    record["invocation"] == invocation ||
        throw(ArgumentError("retirement ledger has a different invocation"))
    path = get(record, "discovery_locator", nothing)
    path isa String || return nothing
    directory = Discovery.existing_registry_directory()
    directory === nothing && return nothing
    path == joinpath(directory, "session-" * record["session_uuid"] * ".pod") ||
        throw(ArgumentError("discovery locator escaped this session UUID"))
    Discovery._with_registry_lock(directory) do
        Discovery._check_file(path; absent_ok=true) === nothing && return nothing
        current = Discovery._read_record(path)
        (current.session_id, current.owner_pid, current.incarnation) ==
            (record["session_uuid"], UInt32(record["wireplumber_pid"]),
             Int64(record["session_control_instance"])) || return nothing
        rm(path)
    end
    return nothing
end

"Run only as this invocation's ExecStop, before systemd revokes WirePlumber."
function stop!(args)
    invocation = S.valid_invocation(get(ENV, "INVOCATION_ID", ""))
    deadline = Client.monotonic() + 30
    values = S.properties(args.unit;
        extra="ControlPID,Type,Restart,KillMode", deadline)
    values["LoadState"] == "loaded" && values["ActiveState"] == "deactivating" &&
        values["Type"] == "exec" && values["Restart"] == "no" &&
        values["KillMode"] == "control-group" &&
        S.valid_invocation(values["InvocationID"]) == invocation &&
        tryparse(Int, values["ControlPID"]) == getpid() ||
        throw(ArgumentError("native stop is not this session's ExecStop"))
    group = values["ControlGroup"]
    observed = S.proc_cgroup(getpid())
    startswith(group, "/") && group != "/" &&
        (observed == group || startswith(observed, group * "/")) ||
        throw(ArgumentError("native stop is outside this session's cgroup"))
    # A successful public Quit or unexpected process exit can invoke ExecStop
    # after MainPID has already disappeared. Cleanup remains ExecStopPost's job.
    values["MainPID"] == "0" && return nothing
    runtime = joinpath(args.runtime_root, invocation)
    ledger = joinpath(runtime, "launch.json")
    record = C.read_json(ledger; maximum=1024 * 1024)
    pid = tryparse(Int, values["MainPID"])
    record["unit"] == args.unit && record["invocation"] == invocation &&
        record["runtime"] == runtime && pid == record["wireplumber_pid"] &&
        S.start_ticks(pid) == UInt64(record["wireplumber_start_ticks"]) ||
        throw(ArgumentError("native stop ledger differs from the live session"))
    main_group = S.proc_cgroup(pid)
    (main_group == group || startswith(main_group, group * "/")) ||
        throw(ArgumentError("WirePlumber MainPID left its session cgroup before stop"))
    haskey(record, "systemd_quit") &&
        throw(ArgumentError("native systemd Quit was already attempted; refusing to retry"))
    client = Client.connect(Profile.Profile(), record["remote"],
        "pipewireao.rtc.session." * record["name"], UInt32(pid),
        Int64(record["session_control_instance"]); deadline)
    try
        status = Client.request!(client, Session.RunnerCommand(:status); deadline)
        status isa Session.Completion && status.header.result == 0 &&
            status.error === nothing && status.lifecycle in
                (Session.Runner.Ready, Session.Runner.Running) ||
            throw(ArgumentError("native stop requires an admitted healthy session"))
        with_thread_loop_lock(client.loop) do _
            Client.healthy(client)
            client.observation.node_identity == record["session_uuid"] ||
                throw(ArgumentError("native stop selected a different session UUID"))
        end
        # Fence submission durably. Unknown outcomes proceed only to emergency
        # process cleanup, never to another native mutation.
        record["systemd_quit"] = Dict("attempted" => true, "accepted" => false)
        C.write_json(ledger, record; atomic=true)
        completion = Client.request!(client, Session.RunnerCommand(:quit);
            deadline=min(deadline, Client.monotonic() + 8))
        completion isa Session.Completion && completion.header.result == 0 &&
            completion.error === nothing && completion.lifecycle == Session.Runner.Offline &&
            completion.result !== nothing && completion.result.details.shutdown === true ||
            throw(ArgumentError("native systemd Quit did not complete Offline"))
        record["systemd_quit"]["accepted"] = true
        C.write_json(ledger, record; atomic=true)
    finally
        close(client)
    end
    # A terminal native reply proves session cleanup. Give the same exact
    # WirePlumber process time to finish its publication fence and exit before
    # returning to systemd's signal phase, within this helper's original budget.
    while Client.monotonic() < deadline
        current = S.properties(args.unit; deadline)
        S.valid_invocation(current["InvocationID"]) == invocation ||
            throw(ArgumentError("session incarnation changed after native Quit"))
        current["MainPID"] == "0" && return nothing
        tryparse(Int, current["MainPID"]) == pid ||
            throw(ArgumentError("WirePlumber process changed after native Quit"))
        # /proc may disappear after systemd's query and before this read.
        # Require a fresh MainPID=0 proof on the next pass; PID reuse still faults.
        current_ticks = S.maybe_start_ticks(pid)
        current_ticks === nothing || current_ticks == UInt64(record["wireplumber_start_ticks"]) ||
            throw(ArgumentError("WirePlumber PID was reused after native Quit"))
        sleep(min(0.005, max(0.0, deadline - Client.monotonic())))
    end
    throw(ArgumentError("WirePlumber did not exit after native Quit before the stop deadline"))
end

"List local POD hints without treating their presence as live-session proof."
function sessions()
    directory = Discovery.existing_registry_directory()
    entries = directory === nothing ? Discovery.DiscoveryEntry[] :
        Discovery.list_sessions(directory)
    return [Dict("verification"=>string(entry.verification),
        "detail"=>entry.detail, "record"=>entry.record) for entry in entries]
end

function _session_entry(session_id::AbstractString)
    id = Discovery._session_id(session_id)
    directory = Discovery.existing_registry_directory()
    directory === nothing && throw(ArgumentError("no local RTC session registry exists"))
    entries = filter(Discovery.list_sessions(directory)) do entry
        entry.record !== nothing && entry.record.session_id == id
    end
    length(entries) == 1 ||
        throw(ArgumentError("selected RTC session is absent from the local listing"))
    return only(entries)
end

"Retain the exact direct connection used to prove the selected session's Status."
function select_direct_session(session_id::AbstractString; deadline=Client.monotonic()+30)
    result = SessionClient.select_direct_session(_session_entry(session_id);
        deadline=Float64(deadline))
    result isa SessionClient.Connection && return result
    throw(ArgumentError("selected RTC session is $(result.verification): $(result.detail)"))
end

function session_status(connection::SessionClient.Connection)
    selected = connection.selected
    status = selected.status
    status.authority === :wireplumber_session ||
        throw(ArgumentError("selected endpoint is not a direct WirePlumber session"))
    return Dict("label"=>selected.record.label, "session_id"=>status.session_id,
        "owner_pid"=>status.owner_pid, "instance"=>status.incarnation,
        "remote"=>status.remote, "node"=>status.node_name,
        "global_id"=>status.global_id, "serial"=>status.object_serial,
        "native_token"=>status.query_token, "lifecycle"=>String(status.lifecycle),
        "authority"=>"wireplumber_session")
end

function control_session(session_id::AbstractString, argv; timeout=30)
    isfinite(timeout) && timeout > 0 ||
        throw(ArgumentError("control timeout must be finite and positive"))
    command = Commands.parse(argv)
    deadline = Client.monotonic() + timeout
    connection = select_direct_session(session_id; deadline)
    try
        completion = SessionClient.request!(connection, command; deadline)
        return SessionClient.render_direct(connection, completion)
    finally
        close(connection)
    end
end

function _control_arguments(argv)
    separator = findfirst(==("--"), argv)
    separator === nothing &&
        throw(ArgumentError("control requires -- between --session and the native command"))
    args = C.cli_arguments(argv[1:separator-1]; required=["session"])
    command = argv[separator+1:end]
    isempty(command) && throw(ArgumentError("control requires a native command"))
    return args.session, command
end

function main(argv=ARGS)
    isempty(argv) && throw(ArgumentError(
        "expected install, prepare, publish, stop, cleanup, sessions, select-session or control"))
    command = first(argv)
    rest = argv[2:end]
    if command == "install"
        WirePlumberInstall.main(rest)
    elseif command == "prepare"
        _preflight(rest)
        WirePlumberLaunch.main(argv; render!)
    elseif command == "publish"
        args = C.cli_arguments(rest; required=["package", "prefix", "unit", "runtime-root"])
        publish!(args)
    elseif command == "stop"
        args = C.cli_arguments(rest; required=["unit", "runtime-root"])
        stop!(args)
    elseif command == "cleanup"
        runtime_root = C.cli_arguments(rest;
            required=["invocation", "runtime-root", "source-role"]).runtime_root
        cleanup_error = nothing
        try
            WirePlumberLaunch.main(argv)
        catch error
            cleanup_error = error
        end
        try
            retire!(runtime_root)
        catch error
            cleanup_error === nothing && rethrow(error)
        end
        cleanup_error === nothing || throw(cleanup_error)
    elseif command == "sessions"
        isempty(rest) || throw(ArgumentError("sessions takes no arguments"))
        println(JSON3.write(sessions()))
    elseif command == "select-session"
        args = C.cli_arguments(rest; required=["session"])
        connection = select_direct_session(args.session)
        try
            println(JSON3.write(session_status(connection)))
        finally
            close(connection)
        end
    elseif command == "control"
        session_id, fields = _control_arguments(rest)
        println(JSON3.write(control_session(session_id, fields)))
    else
        throw(ArgumentError("unknown one-shot WirePlumber command"))
    end
    return 0
end

end # module

abspath(PROGRAM_FILE) == abspath(@__FILE__) && exit(WirePlumberCLI.main(ARGS))
