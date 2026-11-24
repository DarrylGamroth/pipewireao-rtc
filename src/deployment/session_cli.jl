#!/usr/bin/env julia
"""Installed RTC admission and one-shot systemd commands."""
module SessionCLI

import ..PipeWireAORTC
using PipeWireAO: with_thread_loop_lock
using JSON
using PrecompileTools: @compile_workload
import Clocks

import ..SessionConfiguration
import ..SessionLaunch
import ..SessionInstall

export main

const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const S = PipeWireAORTC.SystemdOwners
const P = PipeWireAORTC.Placement
const Discovery = PipeWireAORTC.SessionDiscovery
const Client = PipeWireAORTC.ControlClient
const Session = PipeWireAORTC.SessionCodec
const Profile = PipeWireAORTC.SessionProfile
const SessionClient = PipeWireAORTC.SessionClient
const Commands = PipeWireAORTC.RunnerCommands

function require_node_owners(spec)
    haskey(spec, "node-owners") ||
        throw(ArgumentError("one-shot session requires exact node-owners in deployment.conf"))
    return nothing
end

function confirm_ready(reply::Session.Completion)
    reply.header.operation == UInt32(3) &&
    reply.header.result == 0 &&
    reply.result !== nothing &&
    reply.error === nothing &&
    reply.lifecycle == Session.Runner.Ready ||
        throw(ArgumentError("fresh direct Status did not confirm Ready"))
    return nothing
end
confirm_ready(reply) = throw(ArgumentError("fresh direct Status did not confirm Ready"))

shutdown_completed(reply) = false
function shutdown_completed(reply::Session.Completion)
    return reply.header.result == 0 &&
           reply.error === nothing &&
           reply.lifecycle == Session.Runner.Offline &&
           reply.result !== nothing &&
           reply.result.details.shutdown === true
end

function confirm_shutdown(reply)
    shutdown_completed(reply) ||
        throw(ArgumentError("native systemd Quit did not complete Offline"))
    return nothing
end

function render!(spec, session, bindings, records, runtime; links = D.session_links(session))
    node_owners = Dict{String,String}(spec["node-owners"])
    return SessionConfiguration.write_session_config(
        spec, session, bindings, records, runtime; node_owners, links
    )
end

# Check the same pinned inputs the installer validated without reparsing the
# application manifest, probing Julia, or hashing large calibrations at restart.
function activation_document(package, digest)
    path = joinpath(package, "systemd", SessionLaunch.ACTIVATION_FILE)
    document = SessionLaunch.sealed_graph_document(path, digest)
    document["package"] == realpath(package) || throw(ArgumentError("RTC installation moved"))
    for (file, identity) in document["files"]
        SessionLaunch.graph_file_identity(file) == identity ||
            throw(ArgumentError("installed RTC input changed: $file"))
    end
    project = document["project"]
    all(name -> name in ("Project.toml", "Manifest.toml") || !D.julia_environment_file(name),
        readdir(project)) || throw(ArgumentError("installed RTC project selection changed"))
    if document["export-commit"] !== nothing
        withenv("PIPEWIREAO_RTC_EXPORT_COMMIT" => document["export-commit"]) do
            PipeWireAORTC.GitExport.verified_paths(package)
        end
    end
    return document
end

function activate_installed!(config)
    digest = get(ENV, SessionLaunch.ACTIVATION_ENV, nothing)
    digest === nothing && return nothing
    package = ENV[SessionLaunch.INSTALLATION_ENV]
    unit = ENV[SessionLaunch.ADMISSION_UNIT_ENV]
    root = PipeWireAORTC.SessionRuntime.runtime_directory(unit)
    invocation = S.valid_invocation(ENV["INVOCATION_ID"])
    config == joinpath(root, invocation, "rtc", "rtc.conf") ||
        throw(ArgumentError("RTC configuration is outside this systemd invocation"))
    activation = activation_document(package, digest)
    julia, project = activation["julia"], activation["project"]
    D.verify_session_process(getpid(), Dict("julia" => julia, "project" => project,
        "config" => config, "argv" => PipeWireAORTC.ScienceExport.rtc_arguments(julia, project, config)))
    request = SessionLaunch.Request(package, activation["prefix"], unit, activation["launcher"], root)
    SessionLaunch.prepare!(request; render!, validate_profile = require_node_owners, activation)
    return nothing
end

mutable struct InstalledAdmission
    request::SessionLaunch.Request
    invocation::String
    config::String
    record::Dict{String,Any}
    process::Tuple{Int,UInt64,String}
    endpoint::Union{Nothing,Tuple{UInt32,UInt64}}
    discovery::Union{Nothing,String}
end

function _startup_deadline(deadline, clock)
    Clocks.time_nanos(clock) < deadline ||
        throw(ArgumentError("installed RTC exceeded its startup deadline"))
    return nothing
end

function _main_identity(request, invocation, record, config; deadline, clock)
    values = S.properties(
        request.unit;
        extra = "ExecStop,ExecStopPost," * SessionLaunch.LIFETIME_PROPERTIES,
        deadline,
        clock,
    )
    values["LoadState"] == "loaded" &&
    values["ActiveState"] == "activating" &&
    SessionLaunch.session_lifetime_valid(values) ||
        throw(ArgumentError("RTC unit has unexpected startup policy"))
    pid = getpid()
    S.valid_invocation(values["InvocationID"]) == invocation &&
    tryparse(Int, values["MainPID"]) == pid ||
        throw(ArgumentError("RTC is not this invocation's systemd MainPID"))
    group = values["ControlGroup"]
    ticks = S.start_ticks(pid)
    startswith(group, "/") && group != "/" && S.process_identity(pid, ticks, group) ||
        throw(ArgumentError("RTC MainPID is outside its unit cgroup"))
    SessionLaunch.cleanup_hook_valid(values["ExecStopPost"], request, record["source_role"]) ||
        throw(ArgumentError("RTC emergency cleanup hook changed"))
    SessionLaunch.stop_hook_valid(values["ExecStop"], request) ||
        throw(ArgumentError("RTC native stop hook changed"))
    record["config"] == record["session_process"]["config"] == config ||
        throw(ArgumentError("RTC configuration differs from prepared process binding"))
    D.verify_session_process(pid, record["session_process"])
    _startup_deadline(deadline, clock)
    return pid, ticks, group
end

"""
    installed_admission(config; clock=Clocks.SystemNanoClock())

Bind the installed RTC main process to its private activation ledger. Return
`nothing` for a direct unmanaged launch. Reject mismatched invocation, unit or
process identity before the RTC starts affecting the graph.
"""
function installed_admission(config::AbstractString; clock = Clocks.SystemNanoClock())
    unit = get(ENV, SessionLaunch.ADMISSION_UNIT_ENV, nothing)
    unit === nothing && return nothing
    invocation = S.valid_invocation(get(ENV, "INVOCATION_ID", ""))
    runtime_root = PipeWireAORTC.SessionRuntime.runtime_directory(unit)
    runtime = joinpath(runtime_root, invocation)
    config = String(config)
    config == get(ENV, "RTC_CONFIG", "") == joinpath(runtime, "rtc", "rtc.conf") ||
        throw(ArgumentError("RTC configuration is outside the prepared invocation"))
    SessionLaunch._rendered_session_configuration(config, runtime)
    record = SessionLaunch._read_ledger(runtime)
    SessionLaunch.validate_ledger(record)
    record["unit"] == unit &&
    record["invocation"] == invocation &&
    record["runtime"] == runtime &&
    record["phase"] == "prepared" ||
        throw(ArgumentError("launch ledger does not identify prepared RTC unit"))
    admission = record["admission"]
    request = SessionLaunch.Request(
        admission["package"], admission["prefix"], unit, admission["launcher"], runtime_root
    )
    deadline = Base.checked_add(Clocks.time_nanos(clock), Int64(10_000_000_000))
    process = _main_identity(request, invocation, record, config; deadline, clock)
    return InstalledAdmission(request, invocation, config, record, process, nothing, nothing)
end

function _verify_main(context::InstalledAdmission; deadline, clock)
    _main_identity(
        context.request, context.invocation, context.record, context.config; deadline, clock
    ) == context.process || throw(ArgumentError("installed RTC process changed during startup"))
    return nothing
end

function _endpoint_identity(context::InstalledAdmission, endpoint)
    record = context.record
    (
        endpoint.session_id, endpoint.instance, endpoint.remote, endpoint.node_name,
        endpoint.owner_pid,
    ) == (
        record["session_uuid"], record["session_control_instance"], record["remote"],
        "pipewireao.rtc.session." * record["name"], context.process[1],
    ) &&
    0 < endpoint.global_id < typemax(UInt32) &&
    0 < endpoint.serial <= typemax(UInt64) ||
        throw(ArgumentError("native endpoint differs from the prepared RTC session"))
    return UInt32(endpoint.global_id), UInt64(endpoint.serial)
end

function _verified_discovery!(record, session_record)
    SessionLaunch.validate_ledger(record)
    session_record.owner_pid == UInt32(getpid()) ||
        throw(ArgumentError("only the owning session may publish its locator"))
    directory = Discovery.registry_directory()
    pod = Discovery.encode_record(session_record)
    path = joinpath(directory, "session-" * session_record.session_id * ".pod")
    Discovery._with_registry_lock(directory) do
        if Discovery._check_file(path; absent_ok = true) !== nothing
            prior = Discovery._read_record(path)
            (
                prior.session_id,
                prior.owner_pid,
                prior.incarnation,
                prior.remote,
                prior.node_name,
            ) == (
                session_record.session_id,
                session_record.owner_pid,
                session_record.incarnation,
                session_record.remote,
                session_record.node_name,
            ) || throw(ArgumentError("different session already owns discovery UUID"))
        end
        Discovery._atomic_replace(directory, path, pod)
    end
    return path
end

function _placement_snapshot(context::InstalledAdmission; deadline, clock)
    request = context.request
    record = context.record
    pid, _, group = context.process
    owner = S.Coordinator(request.unit, context.invocation, group, request.launcher)
    manifest = get(record["admission"], "graph_manifest_sha256", nothing)
    persistent = if manifest === nothing
        nothing
    else
        data = SessionLaunch.sealed_graph_document(
            joinpath(request.package, "systemd", SessionLaunch.GRAPH_MANIFEST), manifest
        )
        SessionLaunch.verify_graph_assets!(data["assets"], data["asset-sha256"])
        data["owners"]
    end
    snapshots = Dict{String,Any}()
    for (role, item) in record["owners"]
        SessionLaunch.optional_role(record, role) && continue
        item["role"] == role && item["state"] == "running" ||
            throw(ArgumentError("recorded owner is not running at session publication"))
        service = SessionLaunch.recorded_service(owner, role, item)
        S.verify!(service; deadline, clock)
        snapshots[role] = P.snapshot(service.main_pid, item["placement"])
        S.verify!(service; deadline, clock)
        if get(item, "persistent", false)
            persistent === nothing &&
                throw(ArgumentError("persistent owner lacks an installed graph manifest"))
            SessionLaunch.verify_persistent_service!(
                service, persistent[role]; deadline, clock, attached = true
            )
        end
    end
    snapshots["session"] = P.snapshot(pid, record["admission"]["placement"])
    _startup_deadline(deadline, clock)
    return snapshots
end

"""
    verify_admission!(context, endpoint; deadline, clock)

Verify the native endpoint and systemd invocation before internal admission.
Retain the exact observed endpoint identity for the Ready publication check.
"""
function verify_admission!(context::InstalledAdmission, endpoint; deadline, clock)
    observed = _endpoint_identity(context, endpoint)
    _verify_main(context; deadline, clock)
    context.endpoint = observed
    return nothing
end

"""
    publish_ready!(check, context, endpoint; deadline, clock)

After native Ready, verify required owner and RTC placement before retaining
startup evidence and publishing discovery. Run the
session's readiness check immediately before and after publishing discovery.
Withdraw the locator if the final check fails.
"""
function publish_ready!(check, context::InstalledAdmission, endpoint; deadline, clock)
    observed = _endpoint_identity(context, endpoint)
    observed == context.endpoint ||
        throw(ArgumentError("native endpoint changed after installed admission"))
    context.discovery === nothing ||
        throw(ArgumentError("installed RTC discovery was already published"))
    _verify_main(context; deadline, clock)
    pid, ticks, _ = context.process
    record = context.record
    record["placement_snapshot"] = _placement_snapshot(context; deadline, clock)
    _verify_main(context; deadline, clock)
    session_record = Discovery.SessionRecord(
        record["name"], endpoint.session_id, UInt32(pid), Int64(endpoint.instance),
        endpoint.remote, endpoint.node_name,
    )
    directory = Discovery.registry_directory()
    record["session_pid"] = pid
    record["session_start_ticks"] = ticks
    record["discovery_locator"] = joinpath(directory, "session-" * endpoint.session_id * ".pod")
    SessionLaunch.launch_record!(record["runtime"], record)
    check()
    _startup_deadline(deadline, clock)
    context.discovery = _verified_discovery!(record, session_record)
    try
        check()
        _startup_deadline(deadline, clock)
    catch primary
        try
            retire_admission!(context)
        catch cleanup
            throw(CompositeException([primary, cleanup]))
        end
        rethrow()
    end
    return nothing
end

"""
    notify_ready!()

Notify systemd from the RTC main process after accepting the completed startup
publication. Throw if systemd's notification socket could not be reached.
"""
function notify_ready!()
    result = ccall((:sd_notify, "libsystemd.so.0"), Cint, (Cint, Cstring), 0, "READY=1")
    result > 0 || throw(ArgumentError("systemd readiness notification failed (result $result)"))
    return nothing
end

"""
    retire_admission!(context)

Withdraw the installed session locator if this invocation published it.
"""
retire_admission!(::Nothing) = nothing
function retire_admission!(context::InstalledAdmission)
    retire_record!(context.record, context.discovery)
    context.discovery = nothing
    return nothing
end

function retire!(runtime_root)
    invocation = S.valid_invocation(get(ENV, "INVOCATION_ID", ""))
    ledger = joinpath(runtime_root, invocation, "launch.json")
    isfile(ledger) || return nothing
    record = C.read_json(ledger; maximum = 1024 * 1024)
    SessionLaunch.validate_ledger(record)
    record["invocation"] == invocation ||
        throw(ArgumentError("retirement ledger has a different invocation"))
    return retire_record!(record, get(record, "discovery_locator", nothing))
end

retire_record!(record, path) = SessionLaunch.validate_ledger(record)
function retire_record!(record, path::String)
    SessionLaunch.validate_ledger(record)
    directory = Discovery.existing_registry_directory()
    directory === nothing && return nothing
    path == joinpath(directory, "session-" * record["session_uuid"] * ".pod") ||
        throw(ArgumentError("discovery locator escaped this session UUID"))
    Discovery._with_registry_lock(directory) do
        Discovery._check_file(path; absent_ok = true) === nothing && return nothing
        current = Discovery._read_record(path)
        (current.session_id, current.owner_pid, current.incarnation) == (
            record["session_uuid"],
            UInt32(record["session_pid"]),
            Int64(record["session_control_instance"]),
        ) || return nothing
        rm(path)
    end
    return nothing
end

"Run only as this invocation's ExecStop, before systemd revokes RTC."
function stop!(args; clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock())
    invocation = S.valid_invocation(get(ENV, "INVOCATION_ID", ""))
    previous = Clocks.time_nanos(clock)
    deadline = Base.checked_add(previous, Int64(30_000_000_000))
    trace = Client.Trace(Profile.Profile())
    result = (outcome = :failed, process_exit_at = nothing)
    try
        result = stop_invocation!(args, invocation, previous, deadline, trace, clock)
    finally
        try
            summary = stop_timing(args.unit, invocation, deadline, trace, result)
            println(stderr, "RTC systemd stop timing ", JSON.json(summary))
        catch
            # Journal output must not replace the shutdown result or error.
        end
    end
    return nothing
end

function stop_timing(unit, invocation, deadline, trace::Client.Trace, result)
    # Every value uses the overall helper deadline, including a reply received
    # after the shorter native request deadline.
    remaining(at) = at === nothing ? nothing : Base.checked_sub(deadline, at)
    reply = trace.matched_completion
    return (
        unit = unit,
        invocation = invocation,
        outcome = String(result.outcome),
        deadline_ns = deadline,
        capability_remaining_ns = remaining(trace.capability_at),
        completion_remaining_ns = remaining(trace.completion_at),
        rejection_remaining_ns = remaining(trace.rejection_at),
        controller_admission_remaining_ns = remaining(trace.controller_admission_at),
        connection_ready_remaining_ns = remaining(trace.connection_ready_at),
        quit_submission_remaining_ns = remaining(trace.submission_at),
        offline_remaining_ns = reply !== nothing && shutdown_completed(reply.value) ?
                               remaining(reply.at) : nothing,
        process_exit_remaining_ns = remaining(result.process_exit_at),
    )
end

function stop_invocation!(args, invocation, previous, deadline, trace, clock)
    values = S.properties(
        args.unit; extra = "ControlPID," * SessionLaunch.LIFETIME_PROPERTIES, deadline, clock
    )
    values["LoadState"] == "loaded" &&
    values["ActiveState"] == "deactivating" &&
    SessionLaunch.session_lifetime_valid(values; allow_exec = true) &&
    S.valid_invocation(values["InvocationID"]) == invocation &&
    tryparse(Int, values["ControlPID"]) == getpid() ||
        throw(ArgumentError("native stop is not this session's ExecStop"))
    group = values["ControlGroup"]
    observed = S.proc_cgroup(getpid())
    startswith(group, "/") &&
    group != "/" &&
    (observed == group || startswith(observed, group * "/")) ||
        throw(ArgumentError("native stop is outside this session's cgroup"))
    # A successful public Quit or unexpected process exit can invoke ExecStop
    # after MainPID has already disappeared. Cleanup remains ExecStopPost's job.
    values["MainPID"] == "0" &&
        return (outcome = :main_already_gone, process_exit_at = Clocks.time_nanos(clock))
    runtime = joinpath(args.runtime_root, invocation)
    ledger = joinpath(runtime, "launch.json")
    record = C.read_json(ledger; maximum = 1024 * 1024)
    SessionLaunch.validate_ledger(record)
    pid = tryparse(Int, values["MainPID"])
    record["unit"] == args.unit &&
    record["invocation"] == invocation &&
    record["runtime"] == runtime &&
    pid == record["session_pid"] &&
    S.start_ticks(pid) == UInt64(record["session_start_ticks"]) ||
        throw(ArgumentError("native stop ledger differs from the live session"))
    main_group = S.proc_cgroup(pid)
    (main_group == group || startswith(main_group, group * "/")) ||
        throw(ArgumentError("RTC MainPID left its session cgroup before stop"))
    haskey(record, "systemd_quit") &&
        throw(ArgumentError("native systemd Quit was already attempted; refusing to retry"))
    client = Client.connect(
        Profile.Profile(),
        record["remote"],
        "pipewireao.rtc.session." * record["name"],
        UInt32(pid),
        Int64(record["session_control_instance"]);
        deadline,
        clock,
        trace,
    )
    try
        # Discovery already bound the control node to this PID and instance.
        # Check its UUID locally. The session HSM owns admission of Quit.
        with_thread_loop_lock(client.loop) do _
            Client.healthy(client)
            client.observation.node_identity == record["session_uuid"] ||
                throw(ArgumentError("native stop selected a different session UUID"))
        end
        # Fence submission durably. Unknown outcomes proceed only to emergency
        # process cleanup, never to another native mutation.
        record["systemd_quit"] = Dict("attempted" => true, "accepted" => false)
        C.write_json(ledger, record; atomic = true)
        completion = Client.request!(
            client,
            Session.RunnerCommand(:quit);
            deadline = min(
                deadline, Base.checked_add(Clocks.time_nanos(clock), Int64(8_000_000_000))
            ),
        )
        confirm_shutdown(completion)
        record["systemd_quit"]["accepted"] = true
        C.write_json(ledger, record; atomic = true)
    finally
        close(client)
    end
    # A terminal native reply proves session cleanup. Give the same exact
    # RTC process time to finish its publication fence and exit before
    # returning to systemd's signal phase, within this helper's original budget.
    while true
        sampled = Clocks.time_nanos(clock)
        sampled >= previous || throw(ArgumentError("session stop clock regressed"))
        previous = sampled
        sampled < deadline || break
        current = S.properties(args.unit; deadline, clock)
        S.valid_invocation(current["InvocationID"]) == invocation ||
            throw(ArgumentError("session incarnation changed after native Quit"))
        current["MainPID"] == "0" &&
            return (outcome = :completed, process_exit_at = Clocks.time_nanos(clock))
        tryparse(Int, current["MainPID"]) == pid ||
            throw(ArgumentError("RTC process changed after native Quit"))
        # /proc may disappear after systemd's query and before this read.
        # Require a fresh MainPID=0 proof on the next pass; PID reuse still faults.
        current_ticks = S.maybe_start_ticks(pid)
        current_ticks === nothing ||
            current_ticks == UInt64(record["session_start_ticks"]) ||
            throw(ArgumentError("RTC PID was reused after native Quit"))
        sleep(min(Int64(5_000_000), Base.checked_sub(deadline, sampled)) / 1.0e9)
    end
    throw(ArgumentError("RTC did not exit after native Quit before the stop deadline"))
end

"List local POD hints without treating their presence as live-session proof."
function sessions()
    directory = Discovery.existing_registry_directory()
    entries =
        directory === nothing ? Discovery.DiscoveryEntry[] :
        Discovery.list_sessions(directory)
    return [
        Dict(
            "verification" => string(entry.verification),
            "detail" => entry.detail,
            "record" => entry.record,
        ) for entry in entries
    ]
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
function select_direct_session(
    session_id::AbstractString;
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
    deadline = Base.checked_add(Clocks.time_nanos(clock), Int64(30_000_000_000)),
)
    result = SessionClient.select_direct_session(
        _session_entry(session_id); deadline = S.deadline_ns(deadline), clock
    )
    return selected_connection(result)
end

selected_connection(result::SessionClient.Connection) = result
selected_connection(result) =
    throw(ArgumentError("selected RTC session is $(result.verification): $(result.detail)"))

function session_status(connection::SessionClient.Connection)
    selected = connection.selected
    status = selected.status
    status.authority === :rtc_session ||
        throw(ArgumentError("selected endpoint is not a direct RTC session"))
    return Dict(
        "label" => selected.record.label,
        "session_id" => status.session_id,
        "owner_pid" => status.owner_pid,
        "instance" => status.incarnation,
        "remote" => status.remote,
        "node" => status.node_name,
        "global_id" => status.global_id,
        "serial" => status.object_serial,
        "native_token" => status.query_token,
        "lifecycle" => String(status.lifecycle),
        "authority" => "rtc_session",
    )
end

function control_session(
    session_id::AbstractString,
    argv;
    timeout = 30,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    isfinite(timeout) && timeout > 0 ||
        throw(ArgumentError("control timeout must be finite and positive"))
    command = Commands.parse(argv)
    deadline = Base.checked_add(Clocks.time_nanos(clock), S.duration_ns(timeout))
    connection = select_direct_session(session_id; deadline, clock)
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
    args = C.cli_arguments(argv[1:(separator-1)]; required = ["session"])
    command = argv[(separator+1):end]
    isempty(command) && throw(ArgumentError("control requires a native command"))
    return args.session, command
end

function restart_step!(connection, operation, state, deadline)
    command = Session.RunnerCommand(operation)
    completion = SessionClient.request!(connection, command; deadline)
    reply = SessionClient.render_direct(connection, completion)
    reply["ok"] === true && reply["state"] == state ||
        throw(ArgumentError("RTC $operation did not complete in $state: $(reply["error"])"))
    return reply
end

function restart_session(session_id::AbstractString; clock = Clocks.SystemNanoClock())
    started = Clocks.time_nanos(clock)
    deadline = Base.checked_add(started, S.duration_ns(30))
    connection = select_direct_session(session_id; deadline, clock)
    try
        hold = restart_step!(connection, :session_stop, "Ready", deadline)
        reset = restart_step!(connection, :reset, "Ready", deadline)
        ready_elapsed_ns = Clocks.time_nanos(clock) - started
        start = restart_step!(connection, :session_start, "Running", deadline)
        running_elapsed_ns = Clocks.time_nanos(clock) - started
        return (; hold, reset, start, ready_elapsed_ns, running_elapsed_ns)
    finally
        close(connection)
    end
end

"""
    main(argv=ARGS)

Run one session command, write its report to standard output, and return the
process exit code `0` on success. Invalid arguments and operation failures
throw; the executable wrapper preserves Julia's error reporting and exit status.
"""
function main(argv = ARGS)
    isempty(argv) && throw(
        ArgumentError(
            "expected install, prepare, stop, cleanup, sessions, select-session, control or restart",
        ),
    )
    command = first(argv)
    rest = argv[2:end]
    if command == "install"
        SessionInstall.main(rest)
    elseif command == "prepare"
        SessionLaunch.main(argv; render!, validate_profile = require_node_owners)
    elseif command == "stop"
        args = C.cli_arguments(rest; required = ["unit", "runtime-root"])
        stop!(args)
    elseif command == "cleanup"
        runtime_root =
            C.cli_arguments(rest; required = ["invocation", "runtime-root", "source-role"]).runtime_root
        cleanup_error = nothing
        try
            SessionLaunch.main(argv)
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
        println(JSON.json(sessions()))
    elseif command == "select-session"
        args = C.cli_arguments(rest; required = ["session"])
        connection = select_direct_session(args.session)
        try
            println(JSON.json(session_status(connection)))
        finally
            close(connection)
        end
    elseif command == "control"
        session_id, fields = _control_arguments(rest)
        println(JSON.json(control_session(session_id, fields)))
    elseif command == "restart"
        args = C.cli_arguments(rest; required = ["session"])
        println(JSON.json(restart_session(args.session)))
    else
        throw(ArgumentError("unknown one-shot RTC command"))
    end
    return 0
end

@main

# Compile the installed CLI entry and shutdown specializations without opening a
# PipeWire connection or contacting the user systemd manager.
@compile_workload begin
    precompile(main, (Vector{String},))
    precompile(D.profile, (String, String))
    precompile(D.validate_application, (Dict{String,Any}, String, String))
    precompile(stop!, (NamedTuple{(:unit, :runtime_root),Tuple{String,String}},))
    precompile(
        Core.kwcall,
        (
            NamedTuple{(:source_role,),Tuple{String}},
            typeof(SessionLaunch.cleanup_invocation!),
            String,
            String,
        ),
    )

    precompile(
        Core.kwcall,
        (
            NamedTuple{(:clock,),Tuple{Clocks.SystemNanoClock}},
            typeof(SessionLaunch.cleanup_record!),
            String,
            Dict{String,Any},
            String,
            String,
        ),
    )
    precompile(
        Core.kwcall,
        (NamedTuple{(:atomic,),Tuple{Bool}}, typeof(C.write_json), String, Dict{String,Any}),
    )
end

# Both hooks read and update the invocation record. Exercise the bounded JSON
# codec in memory so its dynamically dispatched object and array readers are cached.
@compile_workload begin
    record = C.parse_json("""
        {"phase":"stopped","owners":{"core":{"pid":42}},"links":[1,2],
         "systemd_quit":{"attempted":true,"accepted":true}}
        """)
    C.finite_json(record)
    JSON.json(record)
end

end # module
