#!/usr/bin/env julia
# Opt-in actual WirePlumber/systemd qualification; never attaches to a live session.
using Test, PipeWireAO, PipeWireAORTC

const W = PipeWireAORTC.WirePlumberSessionRuntime
const S = PipeWireAORTC.SystemdOwners
const C = PipeWireAORTC.Common
const D = PipeWireAORTC.DeploymentConfiguration
const Command = PipeWireAORTC.NativeSessionCodec.RunnerCommand
const USAGE = """
usage: julia --startup-file=no --project=. test/integration/session_faults.jl \
  SEALED_NON_ACTUATING_PACKAGE FRESH_STAGE_ROOT [options]
  --case NAME              sink-removal (default), link-removal, controller-exit
  --sink NAME              Exact declared sink node; required for sink-removal
  --controller-role ROLE   Exact external graph owner; required for controller-exit
  --prefix PATH            Installed PipeWireAO prefix (default: /opt/pipewireao)
"""
clock() = time_ns() / 1e9
function checked(condition, message)
    @test condition
    condition || error(message)
    return nothing
end

function options(args)
    any(==("--help"), args) && return nothing
    length(args) >= 2 || throw(ArgumentError(USAGE))
    iseven(length(args) - 2) || throw(ArgumentError(USAGE))
    values = Dict("--case" => "sink-removal", "--prefix" => "/opt/pipewireao")
    for index in 3:2:length(args)
        args[index] in ("--case", "--prefix", "--sink", "--controller-role") ||
            throw(ArgumentError("unknown option $(args[index])"))
        values[args[index]] = args[index + 1]
    end
    case = values["--case"]
    case in ("sink-removal", "link-removal", "controller-exit") ||
        throw(ArgumentError("unknown fault case $case"))
    required = case == "sink-removal" ? "--sink" :
        case == "controller-exit" ? "--controller-role" : nothing
    required === nothing || haskey(values, required) ||
        throw(ArgumentError("$case requires $required"))
    return (; package=realpath(args[1]), stage=abspath(args[2]), case,
        prefix=values["--prefix"], sink=get(values, "--sink", nothing),
        controller=get(values, "--controller-role", nothing))
end

function await(predicate, seconds, description)
    deadline = clock() + seconds
    while true
        result = predicate()
        result === nothing || return result
        clock() < deadline || error("deadline expired: $description")
        sleep(0.02)
    end
end

function with_registry(f, remote)
    loop = ThreadLoop("rtc-session-fault-test")
    context = core = registry = nothing
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => remote))
            registry = Registry(core)
        end
        start!(loop)
        roundtrip(core)
        return f(loop, core, registry)
    finally
        with_thread_loop_lock(loop) do _
            for resource in (registry, core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
    end
end

identity(object) = (; id=object.id, serial=parse(UInt64, object.properties["object.serial"]))
function snapshot(loop, registry)
    return with_thread_loop_lock(loop) do _
        [(; interface=object.type, identity=identity(object),
            properties=copy(object.properties)) for object in globals(registry)
            if haskey(object.properties, "object.serial")]
    end
end
nodes(objects, name) = filter(x -> x.interface == "PipeWire:Interface:Node" &&
    get(x.properties, "node.name", "") == name, objects)
cohort_links(objects) = filter(x -> x.interface == "PipeWire:Interface:Link" &&
    startswith(get(x.properties, "object.path", ""), "pipewireao/session/"), objects)

function owned_nodes(objects, spec, ledger)
    result = Dict{String,Any}()
    for (name, role) in spec["node-owners"]
        object = only(nodes(objects, name))
        owner = ledger["owners"][role]
        client_id = get(object.properties, "client.id", nothing)
        if role != "core"
            client = only(filter(x -> x.interface == "PipeWire:Interface:Client" &&
                string(x.identity.id) == client_id, objects))
            get(client.properties, "pipewire.sec.pid", "") == string(owner["pid"]) ||
                error("declared node $name belongs to a different process")
        end
        result[name] = object
    end
    return result
end

function verify_owners(ledger; missing=nothing)
    for (role, owner) in ledger["owners"]
        role == missing && continue
        values = S.properties(owner["unit"]; deadline=clock()+8)
        checked(values["InvocationID"] == owner["invocation"], "owner invocation changed: $role")
        checked(values["MainPID"] == string(owner["pid"]), "owner PID changed: $role")
        checked(S.process_identity(owner["pid"], UInt64(owner["start-ticks"]), owner["cgroup"]),
            "owner process incarnation changed: $role")
    end
end

function verify_nodes(captured, objects, spec, selected)
    for (name, old) in captured
        removed = selected.case == "sink-removal" && name == selected.sink ||
            selected.case == "controller-exit" && spec["node-owners"][name] == selected.controller
        observed = nodes(objects, name)
        if removed
            checked(isempty(observed), "removed endpoint reappeared: $name")
        else
            checked(length(observed) == 1 && only(observed).identity == old.identity,
                "surviving node incarnation changed: $name")
        end
    end
end

function inject!(selected, spec, session, ledger, loop, core, registry, captured, links)
    if selected.case == "controller-exit"
        role = selected.controller
        role != ledger["source_role"] && role != "core" || error("controller must be a graph owner")
        graph_names = getindex.(session["graphs"], "node.name")
        any(name -> spec["node-owners"][name] == role, graph_names) ||
            error("selected controller role owns no declared graph")
        owner = ledger["owners"][role]
        values = S.properties(owner["unit"]; deadline=clock()+8)
        values["InvocationID"] == owner["invocation"] &&
            values["MainPID"] == string(owner["pid"]) &&
            S.process_identity(owner["pid"], UInt64(owner["start-ticks"]), owner["cgroup"]) ||
            error("controller process identity changed before injection")
        # Revalidate immediately before signaling only the retained child PID.
        S.old_process_exists(owner["pid"], UInt64(owner["start-ticks"])) || error("controller exited")
        result = C.run_checked(["systemctl", "--user", "kill", "--kill-whom=main",
            "--signal=SIGTERM", owner["unit"]]; timeout=8, maximum_output_bytes=4096)
        result.returncode == 0 || error("owned controller signal failed: $(result.stderr)")
        await(15, "owned controller process exit") do
            S.old_process_exists(owner["pid"], UInt64(owner["start-ticks"])) ? nothing : true
        end
        return (; role, process=owner)
    end
    target = if selected.case == "sink-removal"
        selected.sink in getindex.(session["sinks"], "node.name") || error("sink is not declared")
        captured[selected.sink]
    else
        first(sort(links; by=x -> x.properties["object.path"]))
    end
    roundtrip(core)
    current = only(filter(x -> x.identity == target.identity && x.interface == target.interface,
        snapshot(loop, registry)))
    checked(current.properties == target.properties, "injection target properties changed")
    with_thread_loop_lock(loop) do _
        destroy_global!(registry, target.identity.id)
    end
    roundtrip(core)
    return target
end

function cleanup_evidence(destination)
    path = joinpath(destination, "observed-cleanup.json")
    return isfile(path) ? C.read_json(path) :
        Dict{String,Any}("observation_errors" => Any[])
end
save_cleanup(destination, evidence) = C.write_json(
    joinpath(destination, "observed-cleanup.json"), evidence; atomic=true)

function observe_cleanup!(handle, destination; failed)
    evidence = cleanup_evidence(destination)
    try
        record = await(30, "retained cleanup receipt") do
            value = W.final_record(destination)
            get(value, "cleanup_complete", false) === true ? value : nothing
        end
        checks = Dict(
            "no_cleanup_errors" => isempty(get(record, "cleanup_errors", [])),
            "unit_quiescent" => S.quiescent_unit(handle.unit; deadline=clock()+8),
            "manager_exited" => !S.old_process_exists(handle.main_pid, handle.start_ticks),
            "manager_cgroup_empty" => S.cgroup_empty(handle.cgroup),
        )
        for (role, owner) in record["owners"]
            checks[role * "_exited"] = !S.old_process_exists(owner["pid"], UInt64(owner["start-ticks"]))
            checks[role * "_cgroup_empty"] = S.cgroup_empty(owner["cgroup"])
        end
        failed || (checks["successful_stop"] = get(evidence, "stop_error", nothing) === nothing)
        evidence["checks"], evidence["record"] = checks, record
        save_cleanup(destination, evidence)
        checked(all(values(checks)), "exact session cleanup was not confirmed")
        return record
    catch error
        push!(evidence["observation_errors"], sprint(showerror, error))
        save_cleanup(destination, evidence)
        rethrow()
    end
end

function cleanup!(handle, destination; failed)
    evidence = cleanup_evidence(destination)
    evidence["stop_attempted"] = true
    save_cleanup(destination, evidence)
    evidence["stop_error"] = try
        W.stop!(handle; deadline=clock()+320)
        nothing
    catch error
        sprint(showerror, error)
    end
    save_cleanup(destination, evidence) # Persist the stop outcome before observing it.
    return observe_cleanup!(handle, destination; failed)
end

function reconcile_cleanup!(handle, destination)
    evidence = cleanup_evidence(destination)
    evidence["reconciliation_error"] = try
        W.reconcile_stop!(handle; deadline=clock()+30)
        nothing
    catch error
        sprint(showerror, error)
    end
    save_cleanup(destination, evidence)
    return observe_cleanup!(handle, destination; failed=true)
end

function qualification_source(spec)
    source = only(filter(x -> x["role"] == spec["source-owner"], spec["owners"]))
    protocol = get(source, "control-protocol", nothing)
    if protocol == "pipewireao.rtc.calibration-lifecycle/1"
        get(source, "instrument", nothing) in ("classic", "copper") || error("unsupported source instrument")
    elseif protocol == "pipewireao.source-control/1"
        get(source, "control-node", nothing) isa String || error("native source has no control node")
    else
        error("unsupported source control protocol")
    end
    return source
end

startup_budget(spec) = D.startup_timeout_ms(spec) / 1000 + 130 # Bounded installer and manager setup.

function session_phase(handle, expected; start=false)
    if start
        reply = W.control!(handle, Command(:session_start); deadline=clock()+30)
        checked(reply["ok"] === true && reply["state"] == "Running", "session Start did not reach Running")
    end
    reply = W.control!(handle, Command(:status); deadline=clock()+8)
    checked(reply["ok"] === true && reply["state"] == expected, "session did not remain $expected")
    return reply
end

function source_fields(node, prefix, names)
    records = filter(get(node["info"]["params"], "Props", [])) do record
        fields = get(record, "params", [])
        any(index -> fields[index] isa String && startswith(fields[index], prefix), 1:2:length(fields))
    end
    length(records) == 1 || throw(ArgumentError("source must publish one $prefix record"))
    fields = only(records)["params"]
    iseven(length(fields)) || throw(ArgumentError("malformed source named fields"))
    values = Dict{String,Any}()
    for index in 1:2:length(fields)
        key = fields[index]
        key isa String && startswith(key, prefix) && !haskey(values, key) ||
            throw(ArgumentError("invalid or duplicate source field"))
        values[key] = fields[index+1]
    end
    Set(keys(values)) == Set(names) || throw(ArgumentError("source field set differs from native contract"))
    return Dict(replace(key, prefix => ""; count=1) => value for (key,value) in values)
end

function source_integer(value, label; positive=false)
    value isa Integer && !(value isa Bool) && (positive ? value > 0 : value >= 0) &&
        value <= typemax(Int64) || throw(ArgumentError("invalid source $label"))
    return Int64(value)
end

"Decode retained public ACKs, binding the exact node, mailbox instance and authenticated client PID."
function decode_aos_source(objects, source, owner, node_identity; instance=nothing)
    name = source["control-node"]
    get(owner, "control-node", nothing) == name &&
        get(owner, "control-protocol", nothing) == source["control-protocol"] ||
        throw(ArgumentError("source declaration differs from retained owner control identity"))
    node = only(filter(objects) do object
        get(object, "type", nothing) == "PipeWire:Interface:Node" &&
            get(get(get(object, "info", Dict()), "props", Dict()), "node.name", nothing) == name
    end)
    properties = node["info"]["props"]
    string(get(properties, "pipewireao.run-control", nothing)) == "true" &&
        string(get(properties, "pipewireao.source-snapshot.version", nothing)) == "1" ||
        throw(ArgumentError("source native control capabilities are missing"))
    node["id"] == node_identity.id && parse(UInt64, string(properties["object.serial"])) == node_identity.serial ||
        throw(ArgumentError("source node incarnation changed"))
    pid = parse(Int64, string(properties["pipewireao.source-control.owner-pid"]))
    pid == owner["pid"] || throw(ArgumentError("source metadata owner PID differs from ledger"))
    client_id = parse(UInt32, string(properties["client.id"]))
    client = only(filter(object -> get(object, "type", nothing) == "PipeWire:Interface:Client" &&
        object["id"] == client_id, objects))
    parse(Int64, string(client["info"]["props"]["pipewire.sec.pid"])) == pid ||
        throw(ArgumentError("source authenticated client PID differs from ledger"))
    mailbox = parse(Int64, string(properties["pipewireao.source-control.instance"]))
    mailbox > 0 && (instance === nothing || mailbox == instance) ||
        throw(ArgumentError("source mailbox incarnation changed"))
    names = PipeWireAORTC.NativeSourceControl.SNAPSHOT_NAMES
    snapshot = source_fields(node, "pipewireao.source-snapshot.", names)
    for key in ("version", "instance", "generation", "report-generation")
        source_integer(snapshot[key], key; positive=true)
    end
    for key in ("kind", "completed-token", "result", "sequence", "report-sequence")
        source_integer(snapshot[key], key)
    end
    snapshot["version"] == 1 && snapshot["instance"] == mailbox && snapshot["result"] == 0 &&
        snapshot["kind"] <= 3 || throw(ArgumentError("invalid native source snapshot identity/result"))
    snapshot["running"] isa Bool && snapshot["completed"] isa Bool &&
        !(snapshot["running"] && snapshot["completed"]) || throw(ArgumentError("invalid native source run state"))
    snapshot["report-generation"] <= snapshot["generation"] &&
        (snapshot["report-generation"] != snapshot["generation"] ||
            snapshot["report-sequence"] <= snapshot["sequence"]) ||
        throw(ArgumentError("source report cursor exceeds acquisition cursor"))
    run_names = ("pipewireao.run-control.version", "pipewireao.run-control.completed-token",
        "pipewireao.run-control.result", "pipewireao.run-control.actual-state")
    run = source_fields(node, "pipewireao.run-control.", run_names)
    source_integer(run["version"], "run version"; positive=true)
    source_integer(run["result"], "run result")
    source_integer(run["completed-token"], "run completed-token"; positive=true)
    run["version"] == 1 && run["result"] == 0 && run["actual-state"] in ("running", "stopped") ||
        throw(ArgumentError("invalid native source run acknowledgement"))
    snapshot["completed-token"] >= run["completed-token"] ||
        throw(ArgumentError("source snapshot predates run acknowledgement"))
    return Dict("profile" => source["control-protocol"], "node" => name,
        "node_id" => node_identity.id, "node_serial" => node_identity.serial,
        "owner_pid" => pid, "instance" => mailbox, "snapshot" => snapshot, "run_ack" => run)
end

function validate_source_report(report, observation)
    snapshot = observation["snapshot"]
    for key in ("owner_pid", "source_instance", "generation")
        source_integer(report[key], "report " * key; positive=true)
    end
    source_integer(report["sequence"], "report sequence")
    report["owner_pid"] == observation["owner_pid"] &&
        report["source_instance"] == observation["instance"] &&
        report["generation"] == snapshot["report-generation"] &&
        report["sequence"] == snapshot["report-sequence"] ||
        throw(ArgumentError("saved source report differs from acknowledged report cursor/owner"))
    isempty(get(report, "failures", [])) || throw(ArgumentError("source report retains failures"))
    return nothing
end

function inspect_aos_source(selected, destination, ledger, source, node_identity, name; instance=nothing)
    owner = ledger["owners"][ledger["source_role"]]
    S.process_identity(owner["pid"], UInt64(owner["start-ticks"]), owner["cgroup"]) ||
        error("source process incarnation changed before inspection")
    paths = D.installed_paths(selected.prefix)
    result = C.run_checked([joinpath(selected.prefix, "bin/pwao-dump"), "-N", "-r", ledger["remote"]];
        env=merge(Dict(ENV), Dict("LD_LIBRARY_PATH" => paths["library"])), timeout=8,
        maximum_output_bytes=16*1024*1024)
    result.returncode == 0 || error("source native inspection failed: $(result.stderr)")
    path = joinpath(destination, name * "-graph.json")
    write(path, result.stdout)
    observation = decode_aos_source(C.read_json(path), source, owner, node_identity; instance)
    report = C.read_json(joinpath(dirname(ledger["remote"]), source["control-node"] * "-report.json"))
    validate_source_report(report, observation)
    observation["report"] = report
    S.process_identity(owner["pid"], UInt64(owner["start-ticks"]), owner["cgroup"]) ||
        error("source process incarnation changed during inspection")
    return observation
end

function require_aos_hold(before, after)
    snapshot, previous = after["snapshot"], before["snapshot"]
    all(key -> after[key] == before[key], ("node_id", "node_serial", "owner_pid", "instance")) ||
        throw(ArgumentError("source identity changed across fault"))
    !snapshot["running"] && after["run_ack"]["actual-state"] == "stopped" &&
        after["run_ack"]["completed-token"] > before["run_ack"]["completed-token"] &&
        snapshot["generation"] == previous["generation"] && snapshot["sequence"] >= previous["sequence"] ||
        throw(ArgumentError("source has no fresh held acknowledgement after fault"))
    return nothing
end

function run_case(selected)
    !ispath(selected.stage) && !islink(selected.stage) || error("stage root must be fresh")
    spec = D.profile(joinpath(selected.package, "deployment.conf"), selected.prefix)
    session = D.decode(D.relative_asset(selected.package, spec["session"]), selected.prefix)
    get(session, "profile", nothing) == "development" &&
        get(session, "authority", nothing) == "none" ||
        error("qualification requires session profile=development and authority=none")
    source = qualification_source(spec)
    aos_source = source["control-protocol"] == "pipewireao.source-control/1"
    if selected.case == "sink-removal"
        selected.sink in getindex.(session["sinks"], "node.name") || error("sink is not declared")
    elseif selected.case == "controller-exit"
        role = selected.controller
        role != spec["source-owner"] && role != "core" &&
            any(owner -> owner["role"] == role, spec["owners"]) &&
            any(graph -> spec["node-owners"][graph["node.name"]] == role, session["graphs"]) ||
            error("controller role must be a declared external graph owner")
    end
    mkpath(selected.stage; mode=0o700)
    receipt = Dict{String,Any}("case" => selected.case, "package" => selected.package,
        "deployment_sha256" => C.sha256_file(joinpath(selected.package, "deployment.conf")),
        "sealed_policy" => Dict(k => v for (k,v) in spec["artifacts"] if
            endswith(k, "ao/session.lua") || endswith(k, "lib/ao-connections.lua")),
        "source_protocol" => source["control-protocol"], "startup_budget_s" => startup_budget(spec),
        "test_sha256" => C.sha256_file(@__FILE__),
        "rtc_version" => string(pkgversion(PipeWireAORTC)),
        "sdk_version" => string(pkgversion(PipeWireAO)),
        "runtime_source_sha256" => C.sha256_file(joinpath(pkgdir(PipeWireAORTC),
            "src", "deployment", "wireplumber_session_runtime.jl")),
        "completed" => false)
    save() = C.write_json(joinpath(selected.stage, "qualification.json"), receipt; atomic=true)
    save()
    handle = nothing
    first_stage = joinpath(selected.stage, "faulted")
    try
        handle = W.start!(selected.package, first_stage; prefix=selected.prefix, deadline=clock()+startup_budget(spec))
        ready = aos_source ? nothing : W.ready(handle; deadline=clock()+30)
        ledger = W.final_record(first_stage)
        receipt["first_ledger"] = ledger
        receipt["ready_status"] = session_phase(handle, "Ready")
        receipt["running_status"] = session_phase(handle, "Running"; start=true)
        verify_owners(ledger)
        with_registry(ledger["remote"]) do loop, core, registry
            before = snapshot(loop, registry)
            captured = owned_nodes(before, spec, ledger)
            links = cohort_links(before)
            checked(!isempty(links), "admitted session has no captured links")
            owned_ids = Set(x.identity.id for x in values(captured))
            all(x -> parse(UInt32, x.properties["link.output.node"]) in owned_ids &&
                parse(UInt32, x.properties["link.input.node"]) in owned_ids, links) ||
                error("session link escapes the captured node cohort")
            receipt["nodes_before"], receipt["links_before"] = captured, links
            source_before = if aos_source
                observation = inspect_aos_source(selected, first_stage, ledger, source,
                    captured[source["control-node"]].identity, "source-before-fault")
                checked(observation["snapshot"]["running"], "source did not acknowledge Running before fault")
                receipt["source_before_fault"] = observation
                observation
            else
                nothing
            end
            receipt["injection"] = inject!(selected, spec, session, ledger, loop, core, registry, captured, links)
            save()
            status = await(15, "Fault publication") do
                value = W.control!(handle, Command(:status); deadline=clock()+8)
                value["state"] == "Fault" ? value : nothing
            end
            checked(status["ok"] === true, "Fault Status request failed")
            receipt["fault_status"] = status
            await(15, "session link withdrawal") do
                isempty(cohort_links(snapshot(loop, registry))) ? true : nothing
            end
            source_status = if aos_source
                await(15, "fresh native source held acknowledgement") do
                    observation = inspect_aos_source(selected, first_stage, ledger, source,
                        captured[source["control-node"]].identity, "source-after-fault";
                        instance=source_before["instance"])
                    if observation["snapshot"]["running"] ||
                            observation["run_ack"]["completed-token"] <= source_before["run_ack"]["completed-token"]
                        return nothing
                    end
                    require_aos_hold(source_before, observation)
                    observation
                end
            else
                value = W.source_status(ready, source["instrument"]; deadline=clock()+8)
                checked(value["ok"] === true && value["state"] == "paused",
                    "source did not confirm paused state after fault")
                value
            end
            receipt["source_after_fault"] = source_status
            # A finite observation window checks this cohort; it is not a general timing proof.
            for _ in 1:3
                sleep(0.2)
                checked(W.control!(handle, Command(:status); deadline=clock()+8)["state"] == "Fault",
                    "faulted session changed lifecycle without readmission")
                objects = snapshot(loop, registry)
                checked(isempty(cohort_links(objects)), "session links reappeared")
                verify_nodes(captured, objects, spec, selected)
                verify_owners(ledger; missing=selected.case == "controller-exit" ? selected.controller : nothing)
            end
        end
        receipt["fault_cleanup"] = cleanup!(handle, first_stage; failed=true)
        handle = nothing
        second_stage = joinpath(selected.stage, "readmitted")
        handle = W.start!(selected.package, second_stage; prefix=selected.prefix, deadline=clock()+startup_budget(spec))
        aos_source || W.ready(handle; deadline=clock()+30)
        fresh = session_phase(handle, "Ready")
        second = W.final_record(second_stage)
        checked(second["session_uuid"] != ledger["session_uuid"], "fresh session reused UUID")
        checked(handle.invocation != ledger["invocation"], "fresh session reused invocation")
        for (role, old) in ledger["owners"]
            new = second["owners"][role]
            checked((new["pid"], new["start-ticks"], new["invocation"]) !=
                (old["pid"], old["start-ticks"], old["invocation"]), "fresh owner reused incarnation: $role")
        end
        receipt["fresh_ready_status"] = fresh
        receipt["fresh_running_status"] = session_phase(handle, "Running"; start=true)
        verify_owners(second)
        receipt["fresh_ledger"] = second
        receipt["fresh_cleanup"] = cleanup!(handle, second_stage; failed=false)
        handle = nothing
        receipt["completed"] = true
        save()
    catch error
        receipt["failure"] = sprint(showerror, error)
        save()
        rethrow()
    finally
        if handle !== nothing
            cleanup_error = try
                if handle.stop_attempted
                    reconcile_cleanup!(handle, handle.stage_root)
                else
                    cleanup!(handle, handle.stage_root; failed=true)
                end
                nothing
            catch error
                sprint(showerror, error)
            end
            receipt["failure_cleanup_error"] = cleanup_error
            save()
        end
    end
end

function main(args=ARGS)
    selected = options(args)
    if selected === nothing
        print(USAGE)
    else
        @testset "actual RTC $(selected.case)" begin
            run_case(selected)
        end
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
