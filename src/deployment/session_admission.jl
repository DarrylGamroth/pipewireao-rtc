"""Verify installed session identity and placement and publish its discovery record."""
module SessionAdmission

import Clocks
using UUIDs: uuid4

import ..PipeWireAORTC
import ..Common as C
import ..ControlClient as Client
import ..DeploymentConfiguration as D
import ..Placement as P
import ..SessionConfiguration
import ..SessionDiscovery as Discovery
import ..SessionLaunch
import ..SystemdOwners as S

function require_node_owners(spec)
    haskey(spec, "node-owners") ||
        throw(ArgumentError("one-shot session requires exact node-owners in deployment.conf"))
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

function with_installed_attachment(f, config)
    digest = get(ENV, SessionLaunch.ACTIVATION_ENV, nothing)
    digest === nothing && return f(nothing)
    package = ENV[SessionLaunch.INSTALLATION_ENV]
    unit = ENV[SessionLaunch.ADMISSION_UNIT_ENV]
    root = PipeWireAORTC.SessionRuntime.runtime_directory(unit)
    invocation = S.valid_invocation(ENV["INVOCATION_ID"])
    activation = activation_document(package, digest)
    if haskey(activation, "config")
        return with_direct_attachment(f, config, activation, unit, root, invocation)
    end
    config == joinpath(root, invocation, "rtc", "rtc.conf") ||
        throw(ArgumentError("RTC configuration is outside this systemd invocation"))
    D.verify_session_process(getpid(), D.session_process_binding(activation, config))
    request = SessionLaunch.Request(package, activation["prefix"], unit, activation["launcher"], root)
    SessionLaunch.prepare!(request; render!, validate_profile = require_node_owners, activation)
    return f(nothing)
end

mutable struct InstalledAdmission
    request::SessionLaunch.Request
    invocation::String
    config::String
    record::Dict{String,Any}
    process::Tuple{Int,UInt64,String}
    endpoint::Union{Nothing,Tuple{UInt32,UInt64}}
    discovery::Union{Nothing,String}
    manager::Union{Nothing,S.UserManager}
end

struct DirectAttachment
    config::Dict{String,Any}
    deadline::Int64
    deployment::InstalledAdmission
    link_plan::Union{Nothing,SessionConfiguration.LinkPlan}
end

function _startup_deadline(deadline, clock)
    Clocks.time_nanos(clock) < deadline ||
        throw(ArgumentError("installed RTC exceeded its startup deadline"))
    return nothing
end

function _main_identity(request, invocation, record, config; manager = nothing, deadline, clock)
    values = S.unit_properties(
        manager, request.unit;
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
    S.parsed_pid(values) == pid ||
        throw(ArgumentError("RTC is not this invocation's systemd MainPID"))
    group = values["ControlGroup"]
    ticks = S.start_ticks(pid)
    startswith(group, "/") && group != "/" && S.process_identity(pid, ticks, group) ||
        throw(ArgumentError("RTC MainPID is outside its unit cgroup"))
    direct = get(record, "direct_attach", false)
    (direct ? SessionLaunch.direct_retirement_hook_valid(values["ExecStopPost"], request) :
        SessionLaunch.cleanup_hook_valid(values["ExecStopPost"], request, record["source_role"])) ||
        throw(ArgumentError("RTC emergency cleanup hook changed"))
    SessionLaunch.stop_hook_valid(values["ExecStop"], request; direct) ||
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
    return InstalledAdmission(request, invocation, config, record, process, nothing, nothing, nothing)
end

include("direct_attachment.jl")

function _verify_main(context::InstalledAdmission; deadline, clock)
    _main_identity(
        context.request, context.invocation, context.record, context.config; manager = context.manager, deadline, clock
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
            get(record["admission"], "graph_manifest", joinpath(request.package, "systemd", SessionLaunch.GRAPH_MANIFEST)), manifest
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
        S.verify!(context.manager, service; deadline, clock)
        snapshots[role] = P.snapshot(service.main_pid, item["placement"])
        S.verify!(context.manager, service; deadline, clock)
        if role == "parameters" && haskey(record["admission"], "parameter_service")
            SessionLaunch.verify_persistent_service!(
                service, record["admission"]["parameter_service"]; manager = context.manager, deadline, clock,
                attached = true, instance_template = true,
            )
        elseif persistent !== nothing && haskey(persistent, role)
            SessionLaunch.verify_persistent_service!(
                service, persistent[role]; manager = context.manager, deadline, clock, attached = true
            )
        elseif get(item, "persistent", false) && !get(record, "direct_attach", false)
            throw(ArgumentError("persistent owner lacks an installed graph manifest"))
        end
    end
    snapshots["session"] = P.snapshot(pid, record["admission"]["placement"])
    _startup_deadline(deadline, clock)
    return snapshots
end

units_changed(context::InstalledAdmission; deadline, clock) = context.manager !== nothing &&
    S.check_unit_changes!(context.manager; deadline, clock)

# A unit can change while the native Status reply and publication are in flight.
# Recheck identity, placement and installed graph bindings for a dirty snapshot.
function check_ready_units!(context::InstalledAdmission; deadline, clock)
    while units_changed(context; deadline, clock)
        _startup_deadline(deadline, clock)
        _verify_main(context; deadline, clock)
        context.record["placement_snapshot"] = _placement_snapshot(context; deadline, clock)
    end
    return nothing
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
    check_ready_units!(context; deadline, clock)
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

end # module
