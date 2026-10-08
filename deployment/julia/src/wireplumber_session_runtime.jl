"""Bounded operator client for an installed WirePlumber RTC systemd session.

This module starts and stops an exclusive unit, reads its retained launch ledger,
and checks live native identities. It does not coordinate session effects.
"""
module WirePlumberSessionRuntime

using UUIDs
import ..Common
import ..DeploymentConfiguration
import ..SystemdOwners
import ..NativeSessionDiscovery
import ..NativeSessionClient
import ..NativeSessionCodec
import ..NativeAcquisitionLifecycleClient
import ..NativeAcquisitionLifecycleCodec

const S = SystemdOwners
const Discovery = NativeSessionDiscovery
const Session = NativeSessionClient
const Acquisition = NativeAcquisitionLifecycleClient
const AcquisitionCodec = NativeAcquisitionLifecycleCodec
const UNIT = r"^pipewireao-session@([a-z0-9][a-z0-9-]{0,39})\.service$"

export Handle, start!, attach, ready, running!, control!, source_status, stop!,
    shutdown!, reconcile_shutdown!, reconcile_cleanup!, reconcile_stop!, final_record

mutable struct Handle
    unit::String
    runtime_root::String
    invocation::String
    main_pid::Int
    start_ticks::UInt64
    cgroup::String
    stop_attempted::Bool
    shutdown_attempted::Bool
    shutdown_accepted::Bool
    stage_root::Union{Nothing,String}
end

monotonic() = time_ns() / 1.0e9
remaining(deadline::Real, limit::Real) = begin
    seconds = min(Float64(deadline) - monotonic(), Float64(limit))
    isfinite(seconds) && seconds > 0 || throw(ArgumentError("session operation deadline expired"))
    seconds
end

function checked(argv, deadline; limit=20)
    result = Common.run_checked(argv; timeout=remaining(deadline, limit),
        maximum_output_bytes=64 * 1024)
    result.returncode == 0 ||
        throw(ArgumentError("systemd session operation failed ($(result.returncode)): $(strip(result.stderr))"))
    return result
end

function _unit_link(unit)
    joinpath(dirname(runtime_directory(unit)), "systemd", "user", unit)
end

function _owned_link(unit, unit_file)
    link = _unit_link(unit)
    (ispath(link) || islink(link)) || return false
    isfile(unit_file) && islink(link) && realpath(link) == realpath(unit_file) ||
        throw(ArgumentError("session unit link differs from the installed instance"))
    return true
end

function _unlink_owned_link!(unit, unit_file, deadline)
    _owned_link(unit, unit_file) || return nothing
    checked(["systemctl", "--user", "disable", "--runtime", unit], deadline)
    !(ispath(_unit_link(unit)) || islink(_unit_link(unit))) ||
        throw(ArgumentError("stopped session unit link remains installed"))
    return nothing
end

function _unit_has_jobs(unit, deadline)
    result = checked(["systemctl", "--user", "list-jobs", "--all", "--plain",
        "--no-legend", "--no-pager"], deadline)
    any(split(result.stdout, '\n'; keepempty=false)) do line
        fields = split(strip(line))
        length(fields) >= 3 && fields[2] == unit
    end
end

function _unrun_fields(values, root)
    values["ActiveState"] == "inactive" && values["MainPID"] == "0" &&
        isempty(values["InvocationID"]) && isempty(values["ControlGroup"]) &&
        !(ispath(root) || islink(root)) || return false
    if values["LoadState"] == "not-found"
        return isempty(values["FragmentPath"])
    end
    fragment = values["FragmentPath"]
    return values["LoadState"] == "loaded" &&
        basename(fragment) == "pipewireao-session@.service" && isfile(fragment)
end

_unrun_instance(values, unit, root, deadline) =
    _unrun_fields(values, root) && !_unit_has_jobs(unit, deadline)

_exact_fragment(fragment, unit_file) =
    isfile(fragment) && isfile(unit_file) && realpath(fragment) == realpath(unit_file)

function _no_exact_unit_file!(unit, deadline)
    result = checked(["systemd-analyze", "--user", "unit-paths"], deadline)
    paths = split(strip(result.stdout), '\n'; keepempty=false)
    isempty(paths) && throw(ArgumentError("user systemd unit search paths are unavailable"))
    for directory in paths
        isabspath(directory) && !occursin('\0', directory) ||
            throw(ArgumentError("invalid user systemd unit search path"))
        candidate = joinpath(directory, unit)
        !(ispath(candidate) || islink(candidate)) ||
            throw(ArgumentError("fresh session has an existing exact instance unit file"))
    end
    return nothing
end

function _assert_fresh_instance!(unit, root, deadline)
    values = S.properties(unit; extra="FragmentPath", deadline)
    _unrun_instance(values, unit, root, deadline) ||
        throw(ArgumentError("fresh session unit has an existing instance or execution"))
    _no_exact_unit_file!(unit, deadline)
    return nothing
end

function _assert_installed_instance!(unit, root, unit_file, deadline)
    _owned_link(unit, unit_file) ||
        throw(ArgumentError("fresh session exact instance link is unavailable"))
    values = S.properties(unit; extra="FragmentPath", deadline)
    fragment = values["FragmentPath"]
    values["LoadState"] == "loaded" && values["ActiveState"] == "inactive" &&
        values["MainPID"] == "0" && isempty(values["InvocationID"]) &&
        isempty(values["ControlGroup"]) && !(ispath(root) || islink(root)) &&
        !_unit_has_jobs(unit, deadline) && _exact_fragment(fragment, unit_file) ||
        throw(ArgumentError("fresh session manager did not load the exact installed instance"))
    return nothing
end

function runtime_directory(unit::AbstractString)
    matched = match(UNIT, unit)
    matched === nothing && throw(ArgumentError("invalid WirePlumber session unit name"))
    user_runtime = get(ENV, "XDG_RUNTIME_DIR", "")
    isabspath(user_runtime) && isdir(user_runtime) ||
        throw(ArgumentError("XDG_RUNTIME_DIR must identify the user manager runtime"))
    return joinpath(user_runtime, "pipewireao-session-" * matched.captures[1])
end

function _identity(unit, runtime_root; deadline=monotonic()+8)
    values = S.properties(unit; extra="Type,Restart,KillMode", deadline)
    values["LoadState"] == "loaded" && values["ActiveState"] == "active" &&
        values["Type"] == "exec" && values["Restart"] == "no" &&
        values["KillMode"] == "control-group" ||
        throw(ArgumentError("WirePlumber session unit is not active with the installed policy"))
    invocation = S.valid_invocation(values["InvocationID"])
    pid = tryparse(Int, values["MainPID"])
    pid !== nothing && 0 < pid <= typemax(UInt32) ||
        throw(ArgumentError("WirePlumber MainPID is unavailable"))
    cgroup = values["ControlGroup"]
    startswith(cgroup, "/") && cgroup != "/" &&
        (S.proc_cgroup(pid) == cgroup || startswith(S.proc_cgroup(pid), cgroup * "/")) ||
        throw(ArgumentError("WirePlumber MainPID left its unit cgroup"))
    runtime_root == runtime_directory(unit) ||
        throw(ArgumentError("session runtime root differs from the unit instance"))
    return Handle(String(unit), String(runtime_root), invocation, pid,
        S.start_ticks(pid), cgroup, false, false, false, nothing)
end

function _ledger(handle::Handle)
    path = joinpath(handle.runtime_root, handle.invocation, "launch.json")
    record = Common.read_json(path; maximum=1024 * 1024)
    record["unit"] == handle.unit && record["invocation"] == handle.invocation &&
        record["runtime"] == dirname(path) &&
        record["wireplumber_pid"] == handle.main_pid &&
        UInt64(record["wireplumber_start_ticks"]) == handle.start_ticks ||
        throw(ArgumentError("retained launch ledger differs from the live WirePlumber unit"))
    return record
end

function _receipt(base, handle::Handle)
    Common.write_json(joinpath(base, "session.json"), Dict(
        "unit" => handle.unit, "runtime_root" => handle.runtime_root,
        "invocation" => handle.invocation, "main_pid" => handle.main_pid,
        "start_ticks" => handle.start_ticks, "cgroup" => handle.cgroup);
        atomic=true)
    return nothing
end

function _failed_start_record(root, unit, invocation)
    isdir(root) || return nothing
    ids = filter(name -> occursin(r"^[0-9a-f]{32}$", name), readdir(root))
    length(ids) <= 1 || throw(ArgumentError("failed session start left multiple invocation ledgers"))
    isempty(ids) && return nothing
    id = only(ids)
    directory = joinpath(root, id)
    isdir(directory) && !islink(directory) &&
        isfile(joinpath(directory, "launch.json")) &&
        !islink(joinpath(directory, "launch.json")) ||
        throw(ArgumentError("failed session invocation ledger is unavailable"))
    invocation === nothing || id == invocation ||
        throw(ArgumentError("failed session ledger has a different invocation"))
    record = Common.read_json(joinpath(directory, "launch.json"); maximum=1024 * 1024)
    record["unit"] == unit && record["invocation"] == id &&
        record["runtime"] == joinpath(root, id) ||
        throw(ArgumentError("failed session ledger has a different unit or runtime"))
    return record
end

function _reconcile_failed_start!(target, unit, root, unit_file, start_attempted, primary)
    deadline = monotonic() + 320
    _owned_link(unit, unit_file) # Reject a same-name replacement before stopping.
    before = S.properties(unit; extra="FragmentPath", deadline)
    if !start_attempted && _unrun_instance(before, unit, root, deadline)
        # Link/daemon-reload failed before Start. The manager still exposes
        # only an unrun inherited template (or no unit), so no stop is owed.
        _unlink_owned_link!(unit, unit_file, deadline)
        Common.write_json(joinpath(target, "start-failure.json"), Dict(
            "unit" => unit, "invocation" => nothing,
            "cleanup_confirmed" => true,
            "failure" => sprint(showerror, primary)); atomic=true)
        return nothing
    end
    if before["LoadState"] != "not-found"
        fragment = before["FragmentPath"]
        _exact_fragment(fragment, unit_file) ||
            throw(ArgumentError("failed session unit uses a different installed file"))
    end
    invocation = isempty(before["InvocationID"]) ? nothing :
        S.valid_invocation(before["InvocationID"])
    pid = something(tryparse(Int, before["MainPID"]), 0)
    ticks = pid > 0 ? S.maybe_start_ticks(pid) : nothing
    group = before["ControlGroup"]
    stop_error = nothing
    if before["LoadState"] != "not-found" || start_attempted || _unit_has_jobs(unit, deadline)
        stop_error = try
            checked(["systemctl", "--user", "stop", unit], deadline; limit=300)
            nothing
        catch error
            error # A timeout may have completed the stop; observe before deciding.
        end
    end
    quiet_rounds = 0
    while true
        remaining(deadline, 5)
        values = S.properties(unit; extra="FragmentPath", deadline)
        if values["LoadState"] != "not-found"
            fragment = values["FragmentPath"]
            _exact_fragment(fragment, unit_file) ||
                throw(ArgumentError("failed session unit file changed during cleanup"))
        end
        observed_id = values["InvocationID"]
        if !isempty(observed_id)
            validated = S.valid_invocation(observed_id)
            if invocation === nothing
                invocation = validated
            else
                validated == invocation ||
                    throw(ArgumentError("failed session invocation changed during cleanup"))
            end
        end
        observed_group = values["ControlGroup"]
        isempty(group) && !isempty(observed_group) && (group = observed_group)
        isempty(observed_group) || observed_group == group ||
            throw(ArgumentError("failed session cgroup changed during cleanup"))
        quiet = values["MainPID"] == "0" &&
            (values["LoadState"] == "not-found" || values["ActiveState"] in ("inactive", "failed"))
        quiet &= !_unit_has_jobs(unit, deadline) &&
            (ticks === nothing || !S.old_process_exists(pid, ticks)) &&
            (isempty(group) || S.cgroup_empty(group))
        quiet_rounds = quiet ? quiet_rounds + 1 : 0
        quiet_rounds >= 3 && break
        sleep(min(0.05, remaining(deadline, 0.05)))
    end
    record = _failed_start_record(root, unit, invocation)
    if record === nothing
        !ispath(root) && invocation === nothing && pid == 0 && isempty(group) ||
            throw(ArgumentError("failed session start has no verifiable cleanup ledger"))
    else
        while get(record, "cleanup_complete", false) !== true
            isempty(get(record, "cleanup_errors", [])) ||
                throw(ArgumentError("failed session start retained owner cleanup errors"))
            sleep(min(0.05, remaining(deadline, 0.05)))
            record = _failed_start_record(root, unit, invocation)
            record === nothing &&
                throw(ArgumentError("failed session cleanup ledger disappeared"))
        end
        isempty(get(record, "cleanup_errors", [])) ||
            throw(ArgumentError("failed session start retained owner cleanup errors"))
        id = record["invocation"]
        isempty(S.listed_jobs(id; deadline)) &&
            all(name -> S.quiescent_unit(name; deadline), S.listed_units(id; deadline)) ||
            throw(ArgumentError("failed session retained a live owner or start job"))
        for item in Base.values(record["owners"])
            get(item, "pid", 0) > 0 && haskey(item, "start-ticks") &&
                S.old_process_exists(Int(item["pid"]), UInt64(item["start-ticks"])) &&
                throw(ArgumentError("failed session retained an owner process"))
            group = get(item, "cgroup", "")
            isempty(group) || S.cgroup_empty(group) ||
                throw(ArgumentError("failed session retained a populated owner cgroup"))
        end
        haskey(record, "wireplumber_pid") &&
            S.old_process_exists(Int(record["wireplumber_pid"]),
                UInt64(record["wireplumber_start_ticks"])) &&
            throw(ArgumentError("failed session retained the WirePlumber process"))
        Common.write_json(joinpath(target, "final-launch.json"), record; atomic=true)
    end
    _unlink_owned_link!(unit, unit_file, deadline)
    Common.write_json(joinpath(target, "start-failure.json"), Dict(
        "unit" => unit, "invocation" => invocation,
        "cleanup_confirmed" => true,
        "failure" => sprint(showerror, primary),
        "stop_command_error" => stop_error === nothing ? nothing : sprint(showerror, stop_error));
        atomic=true)
    return nothing
end

"""Install a fresh sealed package and start one unique instance. Never retry a
start whose outcome is uncertain; stop that exact reserved name on failure.
"""
function start!(package::AbstractString, base::AbstractString;
                prefix::AbstractString="/opt/pipewireao", deadline=monotonic()+430)
    source = realpath(package)
    spec = DeploymentConfiguration.profile(joinpath(source, "deployment.conf"), prefix)
    haskey(spec, "session-manager") && haskey(spec, "node-owners") ||
        throw(ArgumentError("calibration package has no WirePlumber session contract"))
    target = abspath(base)
    !ispath(target) && !islink(target) ||
        throw(ArgumentError("session stage runtime must be fresh"))
    mkpath(dirname(target))
    mkdir(target; mode=0o700)
    installed = joinpath(target, "installed")
    julia = Base.julia_cmd().exec[1]
    launcher = joinpath(source, "julia", "wireplumber_cli.jl")
    isfile(launcher) || throw(ArgumentError("sealed session installer is unavailable"))
    checked([julia, "--startup-file=no", "--project=" * joinpath(source, "julia"),
        launcher, "install", "--package", source, "--destination", installed,
        "--pipewire-prefix", String(prefix)], deadline; limit=120)
    suffix = first(replace(string(uuid4()), "-" => ""), 12)
    unit = "pipewireao-session@" * suffix * ".service"
    root = runtime_directory(unit)
    _assert_fresh_instance!(unit, root, deadline)
    unit_file = joinpath(installed, "systemd", unit)
    write(unit_file, read(joinpath(installed, "systemd", "pipewireao-session@.service"), String))
    Common.write_json(joinpath(target, "pending-session.json"), Dict(
        "unit" => unit, "runtime_root" => root, "installed" => installed);
        atomic=true)
    start_attempted = false
    try
        checked(["systemctl", "--user", "link", "--runtime", unit_file], deadline)
        checked(["systemctl", "--user", "daemon-reload"], deadline)
        _assert_installed_instance!(unit, root, unit_file, deadline)
        start_attempted = true
        checked(["systemctl", "--user", "start", unit], deadline; limit=300)
        handle = _identity(unit, root; deadline)
        _ledger(handle)["phase"] == "prepared" ||
            throw(ArgumentError("WirePlumber session did not retain prepared launch evidence"))
        handle.stage_root = target
        _receipt(target, handle)
        return handle
    catch primary
        try
            _reconcile_failed_start!(target, unit, root, unit_file, start_attempted, primary)
        catch cleanup
            Common.write_json(joinpath(target, "start-failure.json"), Dict(
                "unit" => unit, "cleanup_confirmed" => false,
                "failure" => sprint(showerror, primary),
                "cleanup_error" => sprint(showerror, cleanup)); atomic=true)
            throw(CompositeException([primary, cleanup]))
        end
        rethrow()
    end
end

"Attach to an exact installed session unit or a stage receipt."
function attach(path::AbstractString; deadline=monotonic()+8)
    root = abspath(path)
    receipt = joinpath(root, "session.json")
    if isfile(receipt)
        saved = Common.read_json(receipt; maximum=4096)
        handle = _identity(saved["unit"], saved["runtime_root"]; deadline)
        (handle.invocation, handle.main_pid, handle.start_ticks, handle.cgroup) ==
            (saved["invocation"], saved["main_pid"], UInt64(saved["start_ticks"]), saved["cgroup"]) ||
            throw(ArgumentError("session unit incarnation differs from its stage receipt"))
        handle.stage_root = root
        attempt = joinpath(root, "shutdown-attempt.json")
        if isfile(attempt)
            saved_attempt = Common.read_json(attempt; maximum=4096)
            saved_attempt["unit"] == handle.unit &&
                saved_attempt["invocation"] == handle.invocation ||
                throw(ArgumentError("native Quit attempt belongs to another session"))
            handle.shutdown_attempted = true
            handle.shutdown_accepted = get(saved_attempt, "accepted", false) === true
        end
        return handle
    end
    matched = match(r"^pipewireao-session-([a-z0-9][a-z0-9-]{0,39})$", basename(root))
    matched === nothing && throw(ArgumentError("runtime is not a session stage or systemd runtime root"))
    unit = "pipewireao-session@" * matched.captures[1] * ".service"
    return _identity(unit, root; deadline)
end

function _selected(record, deadline)
    directory = Discovery.existing_registry_directory()
    directory === nothing && throw(ArgumentError("no local RTC session registry exists"))
    entries = filter(Discovery.list_sessions(directory)) do entry
        entry.record !== nothing && entry.record.session_id == record["session_uuid"]
    end
    length(entries) == 1 || throw(ArgumentError("published session UUID is absent or ambiguous"))
    connection = Session.select_direct_session(only(entries); deadline=Float64(deadline))
    connection isa Session.Connection ||
        throw(ArgumentError("direct session verification failed: $(connection.detail)"))
    return connection
end

function _verify_owners(handle::Handle, record, deadline)
    coordinator = S.Coordinator(handle.unit, handle.invocation, handle.cgroup)
    for (role, item) in record["owners"]
        item["state"] == "running" ||
            throw(ArgumentError("recorded owner $role is not running"))
        service = S.Service(coordinator, role)
        item["unit"] == service.unit ||
            throw(ArgumentError("recorded owner unit differs from its invocation name"))
        service.main_pid = Int(item["pid"])
        service.invocation = String(item["invocation"])
        service.start_ticks = UInt64(item["start-ticks"])
        service.cgroup = String(item["cgroup"])
        service.state = :running
        values = S.properties(service.unit; deadline)
        values["LoadState"] == "loaded" && values["ActiveState"] == "active" &&
            S.same_incarnation(service, values) &&
            tryparse(Int, values["MainPID"]) == service.main_pid && S.alive(service) ||
            throw(ArgumentError("owner $role changed during session selection"))
    end
    return nothing
end

"Return a compatibility view built from a live direct Status and exact launch ledger."
function ready(handle::Handle; deadline=monotonic()+30)
    live = _identity(handle.unit, handle.runtime_root; deadline)
    (live.invocation, live.main_pid, live.start_ticks, live.cgroup) ==
        (handle.invocation, handle.main_pid, handle.start_ticks, handle.cgroup) ||
        throw(ArgumentError("WirePlumber session unit incarnation changed"))
    record = _ledger(handle)
    record["phase"] == "prepared" ||
        throw(ArgumentError("WirePlumber launch is not prepared"))
    _verify_owners(handle, record, deadline)
    connection = _selected(record, deadline)
    lifecycle = nothing
    try
        status = connection.selected.status
        status.lifecycle in (:ready, :running) &&
            status.owner_pid == UInt32(handle.main_pid) &&
            status.incarnation == record["session_control_instance"] &&
            status.remote == record["remote"] ||
            throw(ArgumentError("direct session Status did not verify admitted WirePlumber"))
        lifecycle = status.lifecycle
    finally
        close(connection)
    end
    _verify_owners(handle, record, deadline)
    source_role = String(record["source_role"])
    source = record["owners"][source_role]
    instance = tryparse(Int64, string(source["control-instance"]))
    instance !== nothing && instance > 0 &&
        source["control-protocol"] == "pipewireao.rtc.calibration-lifecycle/1" ||
        throw(ArgumentError("calibration requires a retained native source endpoint"))
    processes = Dict{String,Any}(role => Dict("pid" => item["pid"],
        "invocation" => item["invocation"], "start-ticks" => item["start-ticks"],
        "cgroup" => item["cgroup"]) for (role, item) in record["owners"])
    return Dict{String,Any}(
        "unit" => handle.unit, "pid" => handle.main_pid,
        "wireplumber_start_ticks" => handle.start_ticks,
        "instance" => handle.invocation, "private_runtime" => record["runtime"],
        "observation_remote" => record["remote"], "source-owner" => source_role,
        "source_endpoint" => Dict("node" => source["control-node"],
            "instance" => instance, "profile" => source["control-protocol"]),
        "processes" => processes, "ready" => Dict("session_id" => record["session_uuid"]),
        "phase" => String(lifecycle), "admitted" => true)
end
ready(path::AbstractString; deadline=monotonic()+30) =
    ready(attach(path; deadline); deadline)

"Start a held Ready session once, then require a fresh native Running Status."
function running!(handle::Handle; deadline=monotonic()+30)
    observed = ready(handle; deadline)
    if observed["phase"] == "ready"
        completion = control!(handle, NativeSessionCodec.RunnerCommand(:session_start);
            deadline)
        completion["ok"] === true && completion["state"] == "Running" ||
            throw(ArgumentError("WirePlumber session Start did not complete Running"))
        observed = ready(handle; deadline)
    end
    observed["phase"] == "running" ||
        throw(ArgumentError("WirePlumber session did not retain Running"))
    return observed
end

"Send one typed native session command on the verified direct connection."
function control!(handle::Handle, command; deadline=monotonic()+8,
                  before_request=()->nothing)
    live = _identity(handle.unit, handle.runtime_root; deadline)
    (live.invocation, live.main_pid, live.start_ticks, live.cgroup) ==
        (handle.invocation, handle.main_pid, handle.start_ticks, handle.cgroup) ||
        throw(ArgumentError("WirePlumber unit incarnation changed before control"))
    record = _ledger(handle)
    connection = _selected(record, deadline)
    try
        status = connection.selected.status
        status.owner_pid == UInt32(handle.main_pid) &&
            status.incarnation == record["session_control_instance"] &&
            status.remote == record["remote"] ||
            throw(ArgumentError("direct control selected a different WirePlumber session"))
        before_request()
        reply = Session.request!(connection, command; deadline=Float64(deadline))
        return Session.render_direct(connection, reply)
    finally
        close(connection)
    end
end

"Query the acquisition owner directly after public Release."
function source_status(ready_record, instrument::AbstractString; deadline=monotonic()+8)
    kind = instrument == "classic" ? AcquisitionCodec.Classic :
        instrument == "copper" ? AcquisitionCodec.Copper :
        throw(ArgumentError("unsupported calibration instrument"))
    source = ready_record["source_endpoint"]
    role = ready_record["source-owner"]
    connection = Acquisition.connect(AcquisitionCodec.CALIBRATION_PROFILE,
        ready_record["observation_remote"], source["node"],
        ready_record["processes"][role]["pid"], source["instance"], kind;
        deadline=Float64(deadline))
    try
        reply = Acquisition.status(connection; deadline=Float64(deadline))
        snapshot = reply.snapshot
        snapshot === nothing && throw(ArgumentError("source Status has no live snapshot"))
        return Dict{String,Any}("ok" => true, "operation" => "status",
            "id" => reply.header.token, "native_token" => reply.header.token,
            "endpoint_instance" => reply.header.endpoint_instance,
            "lifecycle" => string(reply.lifecycle),
            "state" => snapshot.running ? "running" : "paused",
            "cursor" => snapshot.cursor, "report_cursor" => snapshot.report_cursor,
            "sequence" => snapshot.cursor === nothing ? nothing : snapshot.cursor.sequence,
            "completed" => snapshot.completed, "phase" => snapshot.phase,
            "held" => snapshot.held, "restored" => snapshot.restored,
            "window" => snapshot.window)
    finally
        close(connection)
    end
end

"Read-only observation after an uncertain stop; never sends another stop."
function _stopped_record(handle::Handle, deadline)
    while true
        remaining(deadline, 5)
        values = S.properties(handle.unit; deadline)
        invocation = values["InvocationID"]
        isempty(invocation) || S.valid_invocation(invocation) == handle.invocation ||
            throw(ArgumentError("WirePlumber unit incarnation changed after stop"))
        group = values["ControlGroup"]
        isempty(group) || group == handle.cgroup ||
            throw(ArgumentError("WirePlumber unit cgroup changed after stop"))
        quiet = values["MainPID"] == "0" &&
            (values["LoadState"] == "not-found" || values["ActiveState"] in ("inactive", "failed"))
        if quiet && !_unit_has_jobs(handle.unit, deadline) &&
                !S.old_process_exists(handle.main_pid, handle.start_ticks) &&
                S.cgroup_empty(handle.cgroup)
            record = _ledger(handle)
            if get(record, "cleanup_complete", false) === true
                isempty(get(record, "cleanup_errors", [])) ||
                    throw(ArgumentError("WirePlumber emergency cleanup retained errors"))
                return record
            end
        end
        sleep(min(0.05, remaining(deadline, 0.05)))
    end
end

function _retain_stopped!(handle::Handle, deadline)
    record = _stopped_record(handle, deadline)
    handle.stage_root === nothing || Common.write_json(
        joinpath(handle.stage_root, "final-launch.json"), record; atomic=true)
    record["phase"] == "stopped" && get(record, "error", nothing) === nothing ||
        throw(ArgumentError("WirePlumber stopped with a retained service failure"))
    handle.stage_root === nothing || _unlink_owned_link!(handle.unit,
        joinpath(handle.stage_root, "installed", "systemd", handle.unit), deadline)
    return record
end

"Read-only cleanup after an attempted native Quit, including an unknown reply."
function reconcile_cleanup!(handle::Handle; deadline=monotonic()+320)
    handle.shutdown_attempted || handle.stop_attempted ||
        throw(ArgumentError("session cleanup has not been attempted"))
    return _retain_stopped!(handle, deadline)
end

"Confirm cleanup only after a successful native Quit completion proved Offline."
function reconcile_shutdown!(handle::Handle; deadline=monotonic()+320)
    handle.shutdown_accepted ||
        throw(ArgumentError("native Quit has no accepted Offline completion"))
    return _retain_stopped!(handle, deadline)
end

"Send one public native Quit, then observe the unit and ExecStopPost cleanup."
function _native_quit!(send, handle::Handle)
    handle.shutdown_attempted &&
        throw(ArgumentError("native Quit was already attempted for this session"))
    handle.stop_attempted &&
        throw(ArgumentError("emergency stop was already attempted for this session"))
    mark_attempt!() = begin
        handle.stage_root === nothing || Common.write_json(
            joinpath(handle.stage_root, "shutdown-attempt.json"),
            Dict("unit" => handle.unit, "invocation" => handle.invocation,
                "accepted" => false); atomic=true)
        handle.shutdown_attempted = true
    end
    completion = send(mark_attempt!)
    handle.shutdown_attempted ||
        throw(ArgumentError("native Quit sender omitted its attempt fence"))
    completion["ok"] === true && completion["state"] == "Offline" &&
        get(completion["result"], "shutdown", false) === true ||
        throw(ArgumentError("native Quit did not complete Offline"))
    handle.shutdown_accepted = true
    handle.stage_root === nothing || Common.write_json(
        joinpath(handle.stage_root, "shutdown-attempt.json"),
        Dict("unit" => handle.unit, "invocation" => handle.invocation,
            "accepted" => true); atomic=true)
    return completion
end

function shutdown!(handle::Handle; deadline=monotonic()+320)
    _native_quit!(handle) do mark_attempt!
        control!(handle, NativeSessionCodec.RunnerCommand(:quit);
            deadline=min(deadline, monotonic()+8), before_request=mark_attempt!)
    end
    return reconcile_shutdown!(handle; deadline)
end

"Reconcile a submitted stop without repeating its effect."
function reconcile_stop!(handle::Handle; deadline=monotonic()+320)
    handle.stop_attempted ||
        throw(ArgumentError("session stop has not been submitted"))
    return _retain_stopped!(handle, deadline)
end

"Stop only the retained unit incarnation; verify ExecStopPost's cleanup receipt."
function stop!(handle::Handle; deadline=monotonic()+320)
    handle.stop_attempted && throw(ArgumentError("session stop was already attempted"))
    live = _identity(handle.unit, handle.runtime_root; deadline)
    (live.invocation, live.main_pid, live.start_ticks, live.cgroup) ==
        (handle.invocation, handle.main_pid, handle.start_ticks, handle.cgroup) ||
        throw(ArgumentError("WirePlumber unit incarnation changed before stop"))
    timeout = remaining(deadline, 320)
    handle.stop_attempted = true # This command may have an unknown effect.
    command_error = try
        result = Common.run_checked(["systemctl", "--user", "stop", handle.unit];
            timeout, maximum_output_bytes=64 * 1024)
        result.returncode == 0 ? nothing :
            ArgumentError("systemd session stop failed ($(result.returncode)): $(strip(result.stderr))")
    catch error
        error
    end
    try
        return reconcile_stop!(handle; deadline)
    catch observation_error
        command_error === nothing && rethrow()
        throw(CompositeException([command_error, observation_error]))
    end
end

"Read the retained stopped ledger, including its invocation identity."
function final_record(path::AbstractString; invocation=nothing, unit=nothing)
    base = abspath(path)
    receipt_path = joinpath(base, "session.json")
    if isfile(receipt_path)
        receipt = Common.read_json(receipt_path; maximum=4096)
        unit = String(receipt["unit"])
        invocation = receipt["invocation"]
        matched = match(UNIT, unit)
        matched === nothing && throw(ArgumentError("session receipt has an invalid unit"))
        root = String(receipt["runtime_root"])
        isabspath(root) && basename(root) == "pipewireao-session-" * matched.captures[1] ||
            throw(ArgumentError("session receipt runtime root changed"))
    else
        unit isa AbstractString && invocation isa AbstractString ||
            throw(ArgumentError("stopped systemd runtime needs its captured unit and invocation"))
        root = runtime_directory(unit)
        base == root || throw(ArgumentError("stopped runtime differs from the captured unit"))
    end
    id = S.valid_invocation(invocation)
    retained = joinpath(base, "final-launch.json")
    source = isfile(retained) ? retained : joinpath(root, id, "launch.json")
    record = Common.read_json(source; maximum=1024 * 1024)
    record["unit"] == unit && record["invocation"] == id ||
        throw(ArgumentError("stopped session ledger differs from the stage receipt"))
    return record
end

end # module WirePlumberSessionRuntime
