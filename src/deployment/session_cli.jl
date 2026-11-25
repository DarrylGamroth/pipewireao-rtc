#!/usr/bin/env julia
"""Operator session commands and one-shot systemd hooks."""
module SessionCLI

import ..PipeWireAORTC
using PipeWireAO: with_thread_loop_lock
using JSON
using PrecompileTools: @compile_workload
import Clocks

using ..SessionAdmission: render!, require_node_owners, retire!, retire_record!
import ..SessionLaunch
import ..SessionInstall

export main

const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const S = PipeWireAORTC.SystemdOwners
const Discovery = PipeWireAORTC.SessionDiscovery
const Client = PipeWireAORTC.ControlClient
const Session = PipeWireAORTC.SessionCodec
const Profile = PipeWireAORTC.SessionProfile
const SessionClient = PipeWireAORTC.SessionClient
const Commands = PipeWireAORTC.RunnerCommands

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

function _direct_stop_record(args, invocation; missing_ok = false)
    args.runtime_root == PipeWireAORTC.SessionRuntime.runtime_directory(args.unit) ||
        throw(ArgumentError("direct stop runtime differs from the unit instance"))
    record = PipeWireAORTC.SessionRuntime._direct_launch_record(args.runtime_root)
    if record === nothing || record["invocation"] != invocation
        missing_ok && return nothing
        throw(ArgumentError("direct launch receipt belongs to a different invocation"))
    end
    record["unit"] == args.unit ||
        throw(ArgumentError("direct launch receipt belongs to a different unit"))
    return record
end

function _record_direct_stop!(args, invocation, pid, ticks)
    record = _direct_stop_record(args, invocation)
    record["session_pid"] == pid && UInt64(record["session_start_ticks"]) == ticks ||
        throw(ArgumentError("direct shutdown receipt belongs to a different RTC process"))
    get(record, "cleanup_complete", false) === true &&
    record["phase"] == "stopped" &&
    get(record, "error", nothing) === nothing &&
    isempty(get(record, "cleanup_errors", [])) ||
        throw(ArgumentError("direct RTC exited without completing cleanup"))
    record["systemd_quit"] = Dict("attempted" => true, "accepted" => true)
    C.write_json(joinpath(args.runtime_root, "launch.json"), record; atomic = true)
    return nothing
end

function stop_invocation!(args, invocation, previous, deadline, trace, clock)
    direct = get(args, :direct, false)
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
    # After public Quit or an unexpected process exit, retire only this
    # invocation's locator. A failed activation can leave the prior receipt.
    if values["MainPID"] == "0"
        if direct
            record = _direct_stop_record(args, invocation; missing_ok = true)
            record === nothing || retire_record!(record, get(record, "discovery_locator", nothing))
        end
        return (outcome = :main_already_gone, process_exit_at = Clocks.time_nanos(clock))
    end
    runtime = direct ? args.runtime_root : joinpath(args.runtime_root, invocation)
    ledger = joinpath(runtime, "launch.json")
    record = direct ? _direct_stop_record(args, invocation) :
             C.read_json(ledger; maximum = 1024 * 1024)
    SessionLaunch.validate_ledger(record)
    pid = tryparse(Int, values["MainPID"])
    ticks = UInt64(record["session_start_ticks"])
    record["unit"] == args.unit &&
    record["invocation"] == invocation &&
    record["runtime"] == runtime &&
    pid == record["session_pid"] &&
    S.start_ticks(pid) == ticks ||
        throw(ArgumentError("native stop ledger differs from the live session"))
    main_group = S.proc_cgroup(pid)
    (main_group == group || startswith(main_group, group * "/")) ||
        throw(ArgumentError("RTC MainPID left its session cgroup before stop"))
    binding = get(record, "session_process", nothing)
    if direct || (binding !== nothing && haskey(binding, "sysimage"))
        config = direct ? joinpath(record["admission"]["package"], "systemd", "rtc.conf") :
                 joinpath(runtime, "rtc", "rtc.conf")
        record["config"] == binding["config"] == config ||
            throw(ArgumentError("native stop configuration differs from the prepared RTC"))
        D.verify_session_process(pid, binding)
    end
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
        # Retained launches pass the attempt to their independent cleanup hook.
        # In direct mode the main process owns the receipt until it exits.
        if !direct
            record["systemd_quit"] = Dict("attempted" => true, "accepted" => false)
            C.write_json(ledger, record; atomic = true)
        end
        completion = Client.request!(
            client,
            Session.RunnerCommand(:quit);
            deadline = min(
                deadline, Base.checked_add(Clocks.time_nanos(clock), Int64(8_000_000_000))
            ),
        )
        confirm_shutdown(completion)
        if !direct
            record["systemd_quit"]["accepted"] = true
            C.write_json(ledger, record; atomic = true)
        end
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
        if current["MainPID"] == "0"
            exited_at = Clocks.time_nanos(clock)
            direct && _record_direct_stop!(args, invocation, pid, ticks)
            return (outcome = :completed, process_exit_at = exited_at)
        end
        tryparse(Int, current["MainPID"]) == pid ||
            throw(ArgumentError("RTC process changed after native Quit"))
        # /proc may disappear after systemd's query and before this read.
        # Require a fresh MainPID=0 proof on the next pass; PID reuse still faults.
        current_ticks = S.maybe_start_ticks(pid)
        current_ticks === nothing ||
        current_ticks == ticks ||
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
            "expected export, install, prepare, stop, cleanup, sessions, select-session, control or restart",
        ),
    )
    command = first(argv)
    rest = argv[2:end]
    if command == "export"
        args = C.cli_arguments(rest; required = [
            "instrument", "profile", "host", "environment", "destination", "pipewire-prefix",
        ])
        # Resolve optional science packages in the site's pinned environment.
        runtime = Dict("kind" => "registered", "project" => ".")
        environment = D.application_environment(Dict("runtime" => runtime), args.environment)
        script = joinpath(PipeWireAORTC.package_root(), "scripts", "export_instrument.jl")
        julia = Base.julia_cmd().exec[1]
        inputs = [args.instrument, args.destination, args.profile, args.host]
        command = `$julia --startup-file=no --project=$environment $script $inputs`
        run(addenv(command, "JULIA_LOAD_PATH" => "@:@stdlib",
            "PIPEWIREAO_PREFIX" => abspath(args.pipewire_prefix)))
    elseif command == "install"
        SessionInstall.main(rest)
    elseif command == "prepare"
        SessionLaunch.main(argv; render!, validate_profile = require_node_owners)
    elseif command == "stop"
        args = C.cli_arguments(rest; required = ["unit", "runtime-root"], flags = ["direct"])
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
    precompile(
        Core.kwcall,
        (
            NamedTuple{(:links,),Tuple{Vector{D.LinkDeclaration}}},
            typeof(render!),
            Dict{String,Any},
            Dict{String,Any},
            Dict{String,String},
            Dict{String,Any},
            String,
        ),
    )
    precompile(stop!, (NamedTuple{(:unit, :runtime_root, :direct),Tuple{String,String,Bool}},))
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

# Exercise the generated session's heterogeneous maps and arrays in memory.
# Native parser validation and the final file write still run on activation.
@compile_workload begin
    config = Dict{String,Any}(
        "context.properties" => Dict{String,Any}(
            "library.use-fallback" => false, "remote.name" => "/run/rtc/core",
        ),
        "context.modules" => Any[Dict("name" => "libpipewire-module-protocol-native")],
        "pipewireao.session" => Dict{String,Any}(
            "session" => Dict{String,Any}(
                "links" => Any[Dict("output" => "source:pixels", "input" => "graph:pixels")],
            ),
            "node.pids" => Dict("source" => 42, "graph" => 43),
            "core.owner" => Dict("pid" => 41, "nodes" => String[]),
            "auxiliary-sources" => [Dict{String,Any}("role" => "lamp", "pid" => 44)],
            "startup.timeout-ms" => 300000,
        ),
    )
    PipeWireAORTC.ScienceExport.spa_config_payload(config, "Generated RTC session configuration.")
end

end # module
