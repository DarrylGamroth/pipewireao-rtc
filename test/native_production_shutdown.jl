# Opt-in system/application qualification against an explicitly supplied sealed
# REVOLT SDK. No SDK source, algorithm, graph, placement or deadline is changed.
using REVOLTRTC
const P = REVOLTRTC
const C = P.Common
const W = P.WirePlumberSessionRuntime
const S = P.SystemdOwners
include(ENV["RTC_OPERATOR_VIEW_WRITER"])
if length(ARGS) == 4 && (last(ARGS) == "systemd" || get(ENV, "RTC_FINITE_CONTROLS", "0") == "1")
    include(joinpath(first(ARGS), "hil", "source_control.jl"))
    include(ENV["RTC_SOURCE_QUERY_CLIENT"])
    # Bootstrap has already performed warm run/pause/reset requests. The
    # legacy client required untouched token-zero Props; this test accepts
    # validated committed Props. Session Ready governs frame admission.
    function NativeSourceClient.initial_ready(observation::NativeSourceClient.Observation)
        run, reset, snapshot = observation.run, observation.reset, observation.snapshot
        (run === nothing || reset === nothing || snapshot === nothing) && return false
        observation.failure === nothing || error(observation.failure)
        NativeSourceClient.valid_snapshot(snapshot, observation.instance) ||
            error("source initial snapshot failed V1 validation")
        return true
    end
end
clock() = time_ns() / 1e9

function require_proof(condition, detail)
    condition || error(detail)
end

function wait_proof(predicate, seconds, label)
    deadline = clock() + seconds
    while !predicate()
        clock() < deadline || error("qualification deadline expired: $label")
        sleep(0.02)
    end
end

function qualify(package, stage, evidence, phase)
    phase in ("finite", "systemd") || error("phase must be finite or systemd")
    ispath(evidence) && error("evidence directory must be fresh")
    mkpath(evidence; mode=0o700)
    spec = C.read_json(joinpath(package, "deployment.conf"); maximum=16*1024*1024)
    source = only(filter(owner -> owner["role"] == spec["source-owner"], spec["owners"]))
    argv = source["argv"]
    option(flag) = argv[only(findall(==(flag), argv)) + 1]
    require_proof(option("--total-exchanges") == "8192", "requires selected finite8192 SDK")
    require_proof(option("--frames") == "256", "requires retained/warm prefix256")
    require_proof(all(owner -> !any(key -> occursin("PROFILE", key) || occursin("CALLBACK_METRICS", key),
        keys(get(owner, "environment", Dict()))), spec["owners"]), "profiling instrumentation is forbidden")
    records = Any[]
    result = Dict{String,Any}("version"=>1, "package"=>realpath(package), "phase"=>phase,
        "scope"=>"selected sealed simulated native profile; software/application validation",
        "controls"=>records, "completed"=>false, "failure"=>nothing)
    if phase == "systemd" || get(ENV, "RTC_FINITE_CONTROLS", "0") == "1"
        client_path = ENV["RTC_SOURCE_QUERY_CLIENT"]
        result["source_query_client"] = Dict("path"=>realpath(client_path), "sha256"=>C.sha256_file(client_path),
            "scope"=>"existing native V1 typed read-only query client; no source owner modification")
    end
    save() = C.write_json(joinpath(evidence, "qualification.json"), result; atomic=true)
    handle = nothing
    source_client = nothing
    report_path = nothing
    function control(command; seconds=8, before_request=()->nothing)
        before = time_ns()
        reply = W.control!(handle, P.RunnerCommands.parse(command); deadline=clock()+seconds, before_request)
        push!(records, Dict("command"=>command, "before_ns"=>before, "after_ns"=>time_ns(), "reply"=>reply))
        save()
        require_proof(reply["ok"] === true, "native command did not complete: $command")
        return reply
    end
    source_status() = NativeSourceClient.request!(source_client, "status", Int64(time_ns()); deadline=clock()+8)
    try
        result["launch_before_ns"] = time_ns(); save()
        handle = get(ENV, "RTC_ATTACH_READY", "0") == "1" ?
            W.attach(stage; deadline=clock()+48) : P.Installation.start!(package, stage; deadline=clock()+1100)
        result["ready_ns"] = time_ns()
        result["unit"], result["invocation"] = handle.unit, handle.invocation
        ledger = C.read_json(joinpath(handle.runtime_root, handle.invocation, "launch.json"))
        result["session_uuid"], result["remote"] = ledger["session_uuid"], ledger["remote"]
        C.write_json(joinpath(evidence, "launch.json"), ledger; atomic=true)
        ready = control(["status"]; seconds=48)
        require_proof(ready["state"] == "Ready", "fresh session is not Ready")
        C.write_json(joinpath(evidence, "ready.json"), ready; atomic=true)
        if phase == "systemd" || get(ENV, "RTC_FINITE_CONTROLS", "0") == "1"
            owner = ledger["owners"][ledger["source_role"]]
            source_client = NativeSourceClient.connect(ledger["remote"], owner["control-node"], owner["pid"]; deadline=clock()+48)
            result["source_initial_values"] = NativeSourceClient.with_thread_loop_lock(source_client.loop) do _
                observation = source_client.observation
                Dict("run"=>observation.run, "reset"=>observation.reset, "snapshot"=>collect(observation.snapshot))
            end
            result["held_source_status"] = source_status()
            require_proof(result["held_source_status"]["ok"] === true && result["held_source_status"]["sequence"] == 0,
                "Ready source query did not prove sequence zero")
        end
        ClassicDeployment.write_operator_views(package, joinpath(evidence, "operator-view.toml"),
            "/opt/pipewireao"; runtime=handle)
        report_path = joinpath(ledger["runtime"], "simulator-result.json.sustained.json")
        # A test coordination gate lets the external native observer attach
        # while held. It is not a live readiness or production control record.
        save()
        println("PRODUCTION_READY phase=$phase unit=$(handle.unit) uuid=$(ledger["session_uuid"]) remote=$(ledger["remote"]) evidence=$evidence")
        flush(stdout)
        if get(ENV, "RTC_HOLD_READY", "0") == "1"
            wait_proof(() -> isfile(joinpath(evidence, "release-start")), 180, "external observer handoff")
        end
        require_proof(control(["session-start"])["state"] == "Running", "Start did not complete Running")
        println("PRODUCTION_RUNNING phase=$phase unit=$(handle.unit)"); flush(stdout)
        if phase == "finite"
            if source_client !== nothing
                status = source_status()
                wait_proof(30, "finite steady controls after prefix") do
                    status = source_status()
                    return status["state"] == "running" && status["completed"] === false && status["sequence"] >= 512
                end
                result["source_before_finite_controls"] = status; save()
                close(source_client); source_client = nothing
                C.write_json(joinpath(evidence, "source-steady-controls.json"),
                    Dict("status"=>status, "observed_ns"=>time_ns(), "session_uuid"=>ledger["session_uuid"]);
                    atomic=true)
                println("PRODUCTION_FINITE_CONTROLS unit=$(handle.unit) sequence=$(status["sequence"]) evidence=$evidence"); flush(stdout)
            end
            wait_proof(240, "finite completion") do
                isfile(report_path) || return false
                report = C.read_json(report_path; maximum=512*1024)
                report["failure"] === nothing || error("scientific fault: $(report["failure"])")
                return report["completed"] === true
            end
            report = C.read_json(report_path; maximum=512*1024)
            require_proof(report["completed_frames"] == report["completed_commands"] == 8192, "finite matching counts differ")
            allocation = report["allocation"]
            require_proof(allocation["completed_exchanges"] == 7936, "wrong measured exchange count")
            require_proof(allocation["allocated_bytes"] == allocation["gc_pauses"] ==
                allocation["gc_time_ns"] == allocation["full_sweeps"] == 0,
                "whole simulator process allocation/GC gate failed")
            require_proof(all(iszero, values(allocation["allocations"])), "simulator allocation counters are not zero")
            cp(report_path, joinpath(evidence, "finite-sustained.json"))
            result["finite_report"] = report; save()
            if get(ENV, "RTC_HOLD_FINISH", "0") == "1"
                wait_proof(() -> isfile(joinpath(evidence, "release-finish")), 180, "observer/control detachment")
                # Finite counts/allocations and operator acceptance are separate
                # scopes. Preserve the original receipt when later source review
                # adjudicates an optimistic helper completion.
                completion_path = joinpath(evidence, "release-finish-adjudicated.json")
                isfile(completion_path) || (completion_path = joinpath(evidence, "release-finish"))
                result["operator_controls"] = Dict(
                    "file"=>basename(completion_path), "sha256"=>C.sha256_file(completion_path),
                    "receipt"=>C.read_json(completion_path; maximum=512*1024),
                    "scope"=>"external operator receipt; finite count/allocation completion is independent")
                save()
            end
            require_proof(control(["session-stop"])["state"] == "Ready", "Stop did not complete Ready")
            result["quit_before_ns"] = time_ns(); save()
            W._native_quit!(handle) do mark_attempt!
                control(["quit"]; before_request=mark_attempt!)
            end
            result["shutdown"] = W.reconcile_shutdown!(handle; deadline=clock()+320)
            result["quit_after_cleanup_ns"] = time_ns()
            require_proof(handle.shutdown_accepted, "Quit did not complete Offline")
        else
            status = source_status()
            wait_proof(30, "actual advancing source") do
                status = source_status()
                return status["state"] == "running" && status["completed"] === false &&
                    status["sequence"] !== nothing && status["sequence"] >= 512
            end
            if get(ENV, "RTC_HOLD_SYSTEMD_STOP", "0") == "1"
                println("PRODUCTION_SYSTEMD_HOLD unit=$(handle.unit) sequence=$(status["sequence"]) evidence=$evidence"); flush(stdout)
                wait_proof(() -> isfile(joinpath(evidence, "release-systemd-stop")), 120, "controlled live test handoff")
                status = source_status()
            end
            result["source_before_systemd_stop"] = status
            require_proof(status["sequence"] < 8192, "source already reached finite limit")
            close(source_client); source_client = nothing
            live = W._identity(handle.unit, handle.runtime_root; deadline=clock()+8)
            require_proof((live.invocation, live.main_pid, live.start_ticks, live.cgroup) ==
                (handle.invocation, handle.main_pid, handle.start_ticks, handle.cgroup), "owned incarnation changed")
            handle.stop_attempted = true
            result["systemd_stop_before_ns"] = time_ns(); save()
            stopped = C.run_checked(["systemctl", "--user", "stop", handle.unit]; timeout=320,
                maximum_output_bytes=64*1024)
            result["systemd_stop_after_ns"] = time_ns()
            result["systemd_returncode"] = stopped.returncode
            properties = S.properties(handle.unit; extra="Result,ExecMainCode,ExecMainStatus")
            result["systemd_properties"] = properties
            require_proof(stopped.returncode == 0 && properties["Result"] == "success", "systemd stop failed")
            result["shutdown"] = W.reconcile_stop!(handle; deadline=clock()+320)
            require_proof(result["shutdown"]["systemd_quit"]["accepted"] === true, "ExecStop native Quit was not accepted")
            report = C.read_json(report_path; maximum=512*1024)
            require_proof(report["failure"] === nothing && report["completed_frames"] == report["completed_commands"],
                "early stop lost a matching command or faulted")
            require_proof(status["sequence"] <= report["completed_frames"] < 8192, "stop did not interrupt advancing finite acquisition")
            cp(report_path, joinpath(evidence, "systemd-stop-sustained.json"))
            result["partial_report"] = report
        end
        require_proof(S.quiescent_unit(handle.unit), "session cgroup remains active")
        require_proof(result["shutdown"]["cleanup_complete"] === true && result["shutdown"]["error"] === nothing,
            "cleanup receipt retained a failure")
        result["completed"] = true
        println("PRODUCTION_PASS phase=$phase unit=$(handle.unit)"); flush(stdout)
    catch error
        result["failure"] = sprint(showerror, error)
        println(stderr, "PRODUCTION_FAILURE ", result["failure"]); flush(stderr)
        # No mutation retry. Parent receives the retained evidence and can
        # adjudicate any exact-incarnation emergency cleanup separately.
    finally
        source_client === nothing || close(source_client)
        # Adjudication may arrive while native cleanup is completing.
        adjudicated_path = joinpath(evidence, "release-finish-adjudicated.json")
        if isfile(adjudicated_path)
            result["operator_controls"] = Dict(
                "file"=>basename(adjudicated_path), "sha256"=>C.sha256_file(adjudicated_path),
                "receipt"=>C.read_json(adjudicated_path; maximum=512*1024),
                "scope"=>"external adjudicated operator receipt; finite completion is independent")
        end
        if handle !== nothing
            for (name, unit) in (("session", handle.unit),
                ("simulator", "pipewireao-owner-" * handle.invocation * "-simulator.service"),
                ("julia", "pipewireao-owner-" * handle.invocation * "-julia.service"))
                captured = C.run_checked(["journalctl", "--user", "-u", unit, "--no-pager", "-o", "short-monotonic"];
                    timeout=15, maximum_output_bytes=4*1024*1024)
                write(joinpath(evidence, name * "-journal.log"), captured.stdout)
            end
            report_path !== nothing && isfile(report_path) && cp(report_path, joinpath(evidence, "final-sustained.json"); force=true)
        end
        save()
    end
    return result
end

length(ARGS) == 4 || error("usage: SEALED_PACKAGE FRESH_STAGE FRESH_EVIDENCE finite|systemd")
result = qualify(ARGS...)
exit(result["completed"] ? 0 : 1)
