#!/usr/bin/env julia
# Native control qualification of the existing two-window HEART correction fixture.
module NativeCorrectionQualification
include("qualify_calibration_native.jl")
const Cal = NativeCalibrationQualification
const Q, D, C = Cal.Q, Cal.D, Cal.C
const Campaign, Lifecycle, L, Native = Cal.Campaign, Cal.Lifecycle, Cal.L, Cal.Native
const Heart, H = Cal.Heart, Cal.H
const require, cursor = Cal.require, Cal.cursor

function selected_fixture(specification, provenance, contract, contract_sha256)
    profile = provenance["profile"]
    require(profile in ("classic","copper") && provenance["engine"] == "heart" &&
        Campaign.isint(contract["version"]) && contract["version"] == 1 && contract["profile"] == profile &&
        Campaign.isint(contract["frames"]) && contract["frames"] == 256 &&
        provenance["heart_correction"]["active_contract_sha256"] == contract_sha256,
        "sealed correction profile/256-frame active contract differs")
    source = only(filter(owner -> owner["role"] == specification["source-owner"],specification["owners"]))
    require(source["control-protocol"] == Native.profile_name(L.CORRECTION_PROFILE) &&
        source["instrument"] == profile && Cal.owner_argument(source,"--profile") == profile &&
        Cal.owner_argument(source,"--frames") == "256" &&
        Cal.owner_argument(source,"--heart-active-contract") == "@PACKAGE@/heart-active-contract.json" &&
        Cal.owner_argument(source,"--correction-diagnostics") == "true",
        "source is not the sealed native correction owner")
    ingress = profile == "classic" ? "streaming" : "deferred"
    require(contract["native_ingress_mode"] == ingress &&
        Cal.owner_argument(source,"--heart-native-ingress-mode") == ingress,
        "correction ingress differs from the existing scientific contract")
    evidence_directory = Cal.owner_argument(source,"--heart-probe-directory")
    require(isabspath(evidence_directory) &&
        ncodeunits(joinpath(evidence_directory,"window-2","probe-$(typemax(UInt64)).csv")) <= 127,
        "correction evidence directory violates the native path bound")
    budget = profile == "classic" ? 128*1024*1024 : 16*1024*1024
    require(tryparse(UInt64,Cal.owner_argument(source,"--heart-telemetry-max-bytes")) == budget &&
        get(contract,"native_telemetry_max_bytes",profile == "copper" ? budget : nothing) == budget,
        "correction telemetry capacity differs from the frozen contract")
    return (;profile,engine="heart",instrument=profile == "classic" ? L.Classic : L.Copper,
        backend=Cal.owner_argument(source,"--backend"),source_role=source["role"],
        source_node=source["control-node"],ingress,evidence_directory,telemetry_budget=budget,
        native_config_sha256=contract["native_config_sha256"],contract_sha256)
end

function heart_checkpoint(client, root, fixture, window; deadline,check,
        generation_report=Heart.generation_report)
    snapshot, saved = generation_report(client,root;deadline,check)
    require(snapshot.generation == window && snapshot.child_pid !== nothing && snapshot.alive &&
        snapshot.child_returncode === nothing && snapshot.placement_validated && snapshot.diagnostics_disabled &&
        snapshot.ingress === (fixture.ingress == "streaming" ? H.Streaming : H.Deferred),
        "correction HEART child generation/health/placement/ingress differs")
    report = C.parse_json(C.JSON3.write(saved))
    require(report["state"] == "paused" && report["error"] === nothing && report["sequence"] == 0 &&
        report["source_config_sha256"] == fixture.native_config_sha256 &&
        report["native_ingress"]["mode"] == fixture.ingress &&
        report["native_ingress"]["observed_environment"] == (fixture.ingress == "streaming" ? "0" : "1"),
        "published correction HEART generation/configuration differs")
    return snapshot,report
end

function verify_held(reply, fixture, window; previous=nothing)
    s = reply.snapshot
    require(reply.header.result == 0 && reply.lifecycle === L.Connected && s !== nothing &&
        s.instrument === fixture.instrument && s.window == window && s.phase == "initial" &&
        s.held && !s.restored && !s.running && !s.completed &&
        s.cursor !== nothing && s.cursor.sequence == 0 && s.cursor.model_ns == 0 &&
        cursor(s.report_cursor) == cursor(s.cursor),"native correction is not held before public Resume")
    previous === nothing || require(s.cursor.domain == previous.cursor.domain &&
        s.cursor.generation == Base.checked_add(previous.cursor.generation,UInt64(1)),
        "correction Reset did not preserve domain and advance acquisition generation")
    return s
end

function verify_restored(reply, fixture, window)
    s = reply.snapshot
    require(reply.header.result == 0 && reply.lifecycle === L.Connected && s !== nothing &&
        s.instrument === fixture.instrument && s.window == window && s.cursor !== nothing,
        "native correction window identity differs")
    require(s.phase != "fault","native correction owner faulted")
    return s.phase == "restored" && !s.held && s.restored && !s.running && s.completed &&
        s.cursor.sequence == 256 && cursor(s.report_cursor) == cursor(s.cursor)
end

function verify_first_window(reply,fixture)
    s = reply.snapshot
    require(reply.header.result == 0 && reply.lifecycle === L.Connected && s !== nothing &&
        s.instrument === fixture.instrument && s.window == 1 && s.cursor !== nothing &&
        s.phase in ("startup_run","correcting","restore_run","restored") &&
        s.cursor.sequence <= 256,
        "deployment did not admit the first native correction window")
    return nothing
end

function verify_report(report, reply, fixture, heart_snapshot, window)
    require(verify_restored(reply,fixture,window),"correction report has no current restored publication")
    require(all(Campaign.isint(report[key]) for key in ("version","native_window","completed_frames",
        "completed_commands","requested_frames","sequence")) &&
        report["version"] == 1 && report["profile"] == fixture.profile && report["engine"] == "heart" &&
        report["backend"] == fixture.backend && report["native_window"] == window &&
        report["active_contract_sha256"] == fixture.contract_sha256 &&
        report["state"] == "paused" && report["failure"] === nothing && report["completed"] === true &&
        report["completed_frames"] == report["completed_commands"] == report["requested_frames"] == report["sequence"] == 256 &&
        report["native_recording_retained"] === true && report["native_active"] === nothing &&
        report["native_controller_held"] === nothing,"retained correction window/restoration facts differ")
    proof = report["completed_correct_proof"]
    require(proof !== nothing && Campaign.isint(proof["child_pid"]) && Campaign.isint(proof["generation"]) &&
        proof["child_pid"] == heart_snapshot.child_pid &&
        proof["generation"] == heart_snapshot.generation == window &&
        proof["source_config_sha256"] == fixture.native_config_sha256 && proof["ingress_mode"] == fixture.ingress &&
        proof["ingress_environment"] == (fixture.ingress == "streaming" ? "0" : "1"),
        "retained CORRECT proof differs from the fresh owned HEART child")
    root = joinpath(fixture.evidence_directory,"window-$window")
    require(report["native_evidence_directory"] == root && !islink(root),"retained window is outside the sealed evidence root")
    journal = joinpath(root,"native-evidence.jsonl")
    bytes = Campaign.positive_integer(report["native_journal_bytes"],"correction journal bytes",16*1024*1024)
    require(!islink(journal) && isfile(journal),"retained correction journal is absent or linked")
    prefix = open(io -> read(io,Int(bytes)),journal)
    require(length(prefix) == bytes && C.bytes2hex(C.sha256(prefix)) == report["native_journal_prefix_sha256"],
        "retained correction journal prefix differs")
    records = [C.parse_json(line) for line in split(String(prefix),'\n') if !isempty(line)]
    commands = filter(record -> get(record,"kind",nothing) == "active_command",records)
    require(length(commands) == 256 && getindex.(commands,"sequence") == collect(1:256),
        "correction journal command count/sequence differs")
    expected = reply.snapshot.cursor
    require(length(report["model_timestamps_ns"]) == 256 &&
        all(t -> Campaign.isint(t) && 0 <= t <= typemax(Int64),report["model_timestamps_ns"]) &&
        Campaign.isint(report["exposure_ns"]) && 0 < report["exposure_ns"] <= typemax(Int64),
        "retained model times/exposure duration differ")
    for (index,command) in enumerate(commands)
        acquired = command["acquisition"]
        require(all(Campaign.isint(acquired[key]) for key in ("domain","generation","sequence","model_ns")) &&
            acquired["domain"] == expected.domain && acquired["generation"] == expected.generation &&
            acquired["sequence"] == index && acquired["model_ns"] ==
                Base.checked_add(report["model_timestamps_ns"][index],report["exposure_ns"]),
            "retained acquisition identities differ from the authoritative native cursor")
    end
    require(commands[end]["acquisition"]["model_ns"] == expected.model_ns,
        "last retained exposure differs from the current native model cursor")
    if window == 2
        resets = filter(record -> get(record,"kind",nothing) == "reset",records)
        require(length(resets) == 1,"second correction window has no unique reset record")
        reset = only(resets)
        require(Campaign.isint(reset["old_generation"]) && reset["old_generation"] == 1 &&
            reset["old_child_absent"] === true &&
            reset["new_native_hold"]["generation"] == heart_snapshot.generation &&
            reset["new_native_hold"]["child_pid"] == heart_snapshot.child_pid &&
            reset["pending_public_resume"] === true && reset["acquisition_generation"] == expected.generation &&
            Campaign.isint(reset["lifetime_probe_token_preserved"]) && reset["lifetime_probe_token_preserved"] > 0 &&
            commands[1]["relay_sequence"] > reset["lifetime_probe_token_preserved"],
            "correction reset did not retain its declared native hold and lifetime token")
    end
    return report
end

"Wait on native Status and its report cursor; read the saved report only after publication."
function wait_window(connection, fixture, heart_snapshot, window, report_path; deadline,check,
        status=Lifecycle.status, read_report=path -> C.read_json(path;maximum=256*1024),
        verify=verify_report)
    while true
        Native.deadline_check(deadline,check)
        reply = status(connection;deadline,check)
        if verify_restored(reply,fixture,window)
            report = read_report(report_path)
            owner_path = joinpath(fixture.evidence_directory,"window-$window","owner-report.json")
            require(read_report(owner_path) == report,"published external window report differs")
            return reply,verify(report,reply,fixture,heart_snapshot,window)
        end
        sleep(min(0.01,max(0.0,deadline-Native.monotonic())))
    end
end

function verify_reset(first, second, old_child, new_child; absent=Cal.heart_child_absent)
    require(first.snapshot.window == 1 && second.snapshot.window == 2 &&
        second.snapshot.cursor.domain == first.snapshot.cursor.domain &&
        second.snapshot.cursor.generation == Base.checked_add(first.snapshot.cursor.generation,UInt64(1)) &&
        old_child["pid"] != new_child["pid"] && absent(old_child),
        "native correction Reset did not retire and replace the owned child/acquisition generation")
    return nothing
end

function verify_reproducible(first,second)
    compared = Dict("adc"=>first["frame"]["sha256"] == second["frame"]["sha256"],
        "commands"=>first["command"]["sha256"] == second["command"]["sha256"],
        "truth"=>first["correction_truth"] == second["correction_truth"])
    require(all(values(compared)),"native correction reset payload/truth differs from the frozen fixture")
    return compared
end

"Retain the exact published report bytes before Reset or shutdown can update the live report."
function retain_report(fixture,window,destination,expected)
    path=joinpath(fixture.evidence_directory,"window-$window","owner-report.json")
    require(!islink(path) && isfile(path) && filesize(path) <= 256*1024 &&
        !ispath(destination) && !islink(destination),"invalid correction report retention path")
    require(C.read_json(path;maximum=256*1024) == expected,"native window report changed before retention")
    hash=C.sha256_file(path)
    cp(path,destination)
    require(C.sha256_file(path) == hash == C.sha256_file(destination) &&
        C.read_json(destination;maximum=256*1024) == expected,"retained correction report bytes changed")
    return Dict("source"=>path,"report"=>destination,"sha256"=>hash)
end

function verify_analysis(analysis, fixture, window)
    require(analysis["verified"] === true && analysis["failure"] === nothing &&
        analysis["engine"] == "heart" && analysis["native_window"] == window &&
        analysis["native_active_contract_sha256"] == fixture.contract_sha256,
        "existing native scientific correction analysis failed")
    windows = analysis["windows"]
    require(length(windows) == 2 && [(w["first"],w["last"]) for w in windows] == [(17,128),(129,256)] &&
        all(w -> w["complete"] === true && w["residual_to_atmosphere_variance_ratio"] isa Real &&
            !(w["residual_to_atmosphere_variance_ratio"] isa Bool) &&
            isfinite(w["residual_to_atmosphere_variance_ratio"]) &&
            0 <= w["residual_to_atmosphere_variance_ratio"] < 1,windows),
        "native correction utility is not positive in both existing declared windows")
    return nothing
end

function qualification_exit_code(record)
    Cal.qualification_exit_code(record) == 0 || return 1
    all(get(record,key,false) === true for key in ("batches_confirmed","reset_confirmed",
        "reset_reproducible","replays_confirmed")) || return 1
    get(record,"replay_failure",nothing) === nothing || return 1
    return 0
end

function main(args=ARGS)
    length(args) == 3 || error("usage: PACKAGE FRESH_RUNTIME FRESH_OUTPUT")
    package,runtime,output = abspath.(args)
    all(path -> !ispath(path) && !islink(path),(runtime,output)) || error("fresh paths required")
    specification = D.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")
    provenance = C.read_json(joinpath(package,"provenance.json"))
    contract_path = joinpath(package,"heart-active-contract.json")
    fixture = selected_fixture(specification,provenance,C.read_json(contract_path),C.sha256_file(contract_path))
    !ispath(fixture.evidence_directory) && !islink(fixture.evidence_directory) || error("fresh external evidence required")
    mkpath(output;mode=0o700)
    record = Dict{String,Any}("version"=>1,"engine"=>"heart","profile"=>fixture.profile,
        "package"=>package,"runtime"=>runtime,"native_evidence_directory"=>fixture.evidence_directory,
        "descriptor_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
        "active_contract_sha256"=>fixture.contract_sha256,"qualifier_sha256"=>C.sha256_file(@__FILE__),
        "installed_runtime_sha256"=>Cal.runtime_receipt(package),
        "native_runner_sha256"=>C.sha256_file(joinpath(package,"bin/pipewireao-rtc")),
        "initial_hold_observed"=>false,
        "initial_window_authority"=>"deployment auto-Resume before Running; fresh correction/HEART status and bound journal",
        "scope"=>"two existing native CORRECT windows, frozen reset/utility gates; no hardware/cadence/latency claim",
        "success"=>false,"restoration_confirmed"=>false,"release_confirmed"=>false,"shutdown_confirmed"=>false)
    command = Cal.installed_command(package,runtime;owner_preparation_timeout_seconds=900)
    record["run_argv"] = command
    process = lifecycle = heart = nothing
    identities = Dict{String,Any}(); children = Any[]; reports = Any[]
    try
        open(joinpath(output,"deployment.log"),"w") do log
            process = run(pipeline(Cmd(command),stdout=log,stderr=log);wait=false)
            D.wait_state(runtime,state -> get(state,"admitted",false) && get(state,"state",nothing) == "Running";
                    timeout=900,process) do ready,supervisor
                try
                    Q.verify_admission_client(supervisor,ready,getpid(process))
                    identities = Q.owned_process_identities(ready["processes"],getpid(process))
                    record["ready"]=ready;record["owned_processes"]=identities
                    instance = ready["private_runtime"]; source=ready["source_endpoint"]; binding=ready["heart_endpoint"]
                    wrapper = only(filter(D.native_heart,specification["owners"]))
                    require(source["node"] == fixture.source_node && source["instrument"] == fixture.profile &&
                        source["owner_pid"] == identities[fixture.source_role]["pid"] &&
                        binding["node"] == wrapper["control-node"] && binding["owner_pid"] == identities["heart"]["pid"],
                        "native supervisor admitted another correction source/wrapper")
                    process_check() = (process_running(process) || error("owned supervisor exited");nothing)
                    heart = Heart.connect(ready["observation_remote"],binding["node"],binding["owner_pid"],binding["instance"];
                        deadline=Native.monotonic()+20,check=process_check)
                    current,generation = heart_checkpoint(heart,joinpath(instance,"heart/native"),fixture,1;
                        deadline=Native.monotonic()+20,check=process_check)
                    check() = (process_check();Heart.require_ready(heart,current))
                    lifecycle = Lifecycle.connect(L.CORRECTION_PROFILE,ready["observation_remote"],source["node"],
                        source["owner_pid"],source["instance"],fixture.instrument;deadline=Native.monotonic()+20,check)
                    initial = Lifecycle.status(lifecycle;deadline=Native.monotonic()+20,check)
                    # Deployment has already acknowledged Connect and Resume
                    # before Running admission; never issue a duplicate Resume.
                    verify_first_window(initial,fixture)
                    record["heart_generations"] = Any[generation]
                    push!(children,Cal.heart_child_identity(current,binding["owner_pid"],identities))
                    record["heart_children"]=children;record["heart_child_identity_confirmed"]=true
                    previous = nothing
                    for window in 1:2
                        if window == 2
                            # Reset changes the child deliberately. Its accepted deadline is
                            # never refreshed, and readiness is checked again after completion.
                            record["stop"]=Q.native_control(supervisor,["session-stop"];timeout=30)
                            record["reset"]=Q.native_control(supervisor,["reset"];timeout=30)
                            reset = Lifecycle.status(lifecycle;deadline=Native.monotonic()+20,check=process_check)
                            verify_held(reset,fixture,window;previous=previous.snapshot)
                            current,generation = heart_checkpoint(heart,joinpath(instance,"heart/native"),fixture,window;
                                deadline=Native.monotonic()+20,check=process_check)
                            child = Cal.heart_child_identity(current,binding["owner_pid"],identities)
                            verify_reset(previous,reset,children[end],child)
                            push!(children,child);push!(record["heart_generations"],generation)
                            record["reset_confirmed"]=true
                        end
                        window == 2 && (record["restart"]=Q.native_control(supervisor,["session-start"];timeout=30))
                        completed,report = wait_window(lifecycle,fixture,current,window,joinpath(instance,"simulator-result.json");
                            deadline=Native.monotonic()+600,check)
                        fresh,_ = heart_checkpoint(heart,joinpath(instance,"heart/native"),fixture,window;
                            deadline=Native.monotonic()+20,check)
                        require(fresh.child_pid == current.child_pid && fresh.report_sha256 == current.report_sha256 &&
                            Cal.same_child_identity(Cal.heart_child_identity(fresh,binding["owner_pid"],identities),children[end]),
                            "correction child identity/publication changed within its window")
                        path=joinpath(output,"window-$window.json")
                        retained=retain_report(fixture,window,path,report)
                        push!(reports,report)
                        record["window_$window"]=merge(retained,Dict(
                            "cursor"=>Cal.Actions._cursor_document(completed.snapshot.cursor),
                            "instance"=>completed.header.endpoint_instance,"token"=>completed.header.token))
                        previous=completed
                    end
                    record["batches_confirmed"]=true
                    record["reset_comparison"]=verify_reproducible(reports...)
                    record["reset_reproducible"]=true
                    record["restoration_confirmed"]=record["release_confirmed"]=record["heart_health_confirmed"]=true
                    close(lifecycle);lifecycle=nothing;close(heart);heart=nothing
                    Q.native_control(supervisor,["session-stop"];timeout=20)
                    Q.native_control(supervisor,["quit"];timeout=30)
                    record["final"]=D.wait_final_report(runtime,process;owner_pid=getpid(process),timeout=55)
                    require(success(process) && record["final"]["phase"] == "stopped" && !ispath(instance),
                        "native correction shutdown failed")
                    record["shutdown_confirmed"]=true
                    record["cleanup"]=Q.observed_cleanup(process,identities)
                    require(record["cleanup"]["status"] == "complete","owned correction groups remain")
                    record["heart_child_cleanup_confirmed"]=all(Cal.heart_child_absent,children)
                    require(record["heart_child_cleanup_confirmed"],"an owned correction child survived shutdown")
                finally
                    if process_running(process)
                        attempts=Any[]
                        for operation in ("session-stop","quit")
                            try push!(attempts,Q.native_control(supervisor,[operation];timeout=20))
                            catch cleanup;push!(attempts,Dict("operation"=>operation,"failure"=>sprint(showerror,cleanup))) end
                        end
                        record["native_cleanup_attempts"]=attempts
                    end
                end
            end
        end
        # Scientific replay follows complete native shutdown. Existing analyzer
        # gates and coefficients remain unchanged; non-convergence is a failure.
        analyses=Any[]
        for window in 1:2
            analysis_path=joinpath(output,"window-$window-analysis.json")
            argv=[Base.julia_cmd().exec[1],"--startup-file=no","--project="*joinpath(package,"hil"),
                joinpath(package,"hil/heart_correction_analysis.jl"),"--package",package,
                "--report",joinpath(output,"window-$window.json"),"--output",analysis_path]
            result=C.run_checked(argv;timeout=900)
            write(joinpath(output,"window-$window-analysis.log"),result.stdout*result.stderr)
            require(result.returncode == 0,"native correction scientific replay failed")
            analysis=C.read_json(analysis_path;maximum=4*1024*1024)
            verify_analysis(analysis,fixture,window)
            push!(analyses,Dict("path"=>analysis_path,"sha256"=>C.sha256_file(analysis_path),"argv"=>argv))
        end
        record["analyses"]=analyses;record["replays_confirmed"]=true
        record["success"]=true
    catch primary
        record["success"]=false;record["failure"]=sprint(showerror,primary)
    finally
        # Unknown native outcomes retain owner hold/fault; no speculative release.
        for client in (lifecycle,heart)
            client === nothing && continue
            try close(client) catch cleanup
                record["success"]=false;record["client_cleanup_failure"]=sprint(showerror,cleanup)
            end
        end
        if process !== nothing && process_running(process)
            record["success"]=false
            try record["cleanup"]=Q.fallback_cleanup(process,identities)
            catch cleanup;record["cleanup_failure"]=sprint(showerror,cleanup) end
        end
        record["success"]=qualification_exit_code(record) == 0
        C.write_json(joinpath(output,"qualification.json"),record)
    end
    println(joinpath(output,"qualification.json"))
    return qualification_exit_code(record)
end
end
abspath(PROGRAM_FILE) == (@__FILE__) && exit(NativeCorrectionQualification.main(ARGS))
