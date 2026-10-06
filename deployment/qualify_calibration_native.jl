#!/usr/bin/env julia
# Installed functional calibration qualification; no inverse estimation or tuning.
module NativeCalibrationQualification
using PipeWireAODeployment
include("qualify_sustained.jl")
const Q = SustainedQualification
const D = PipeWireAODeployment.Deployment
const C = PipeWireAODeployment.Common
const Campaign = PipeWireAODeployment.CalibrationCampaign
const Actions = PipeWireAODeployment.NativeCalibrationActionClient
const Wire = PipeWireAODeployment.NativeCalibrationActionCodec
const Lifecycle = PipeWireAODeployment.NativeAcquisitionLifecycleClient
const L = PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const Native = PipeWireAODeployment.NativeControlClient

require(value, message) = value === true || error(message)
cursor(c) = (c.domain, c.generation, c.sequence, c.model_ns)
cursor(::Nothing) = nothing

"Accept success only with all required effects, cleanup, and no recorded failure."
function qualification_exit_code(record)
    Q.qualification_exit_code(record) == 0 || return 1
    all(get(record,key,false) === true for key in ("restoration_confirmed","release_confirmed")) || return 1
    get(record,"client_cleanup_failure",nothing) === nothing || return 1
    get(record,"cleanup_failure",nothing) === nothing || return 1
    cleanup = get(record,"cleanup",Dict())
    get(cleanup,"launcher_exited",false) === true || return 1
    groups = get(cleanup,"groups",Dict())
    !isempty(groups) && all(get(group,"status","unknown") == "complete" for group in values(groups)) || return 1
    return 0
end
function verified_report(connection, path, startup; deadline, check,
        status=Lifecycle.status, read_report=Campaign.completed_owner_report)
    while true
        Native.deadline_check(deadline,check)
        reply = status(connection; deadline,check)
        snapshot = reply.snapshot
        require(reply.lifecycle === L.Connected && !snapshot.held &&
            snapshot.restored && snapshot.phase == "released",
            "owner did not retain restored Release facts")
        if !snapshot.running && snapshot.completed && snapshot.report_cursor !== nothing &&
                cursor(snapshot.report_cursor) == cursor(snapshot.cursor)
            rendered = Dict("ok"=>true,"operation"=>"status","native_token"=>reply.header.token,
                "id"=>reply.header.token,"endpoint_instance"=>reply.header.endpoint_instance,
                "lifecycle"=>"Connected","state"=>"paused","held"=>snapshot.held,
                "restored"=>snapshot.restored,"phase"=>snapshot.phase,"completed"=>snapshot.completed,
                "cursor"=>snapshot.cursor,"report_cursor"=>snapshot.report_cursor)
            return reply, read_report(path,rendered,startup)
        end
        sleep(min(0.01,max(0.0,deadline-Native.monotonic())))
    end
end

"Verify stored Rust output against the declared finite plan and model identity."
function verify_collect(result, plan, startup)
    require(result["version"] == 1 && result["run"] == plan["run"] &&
        result["phase"] == "complete" && result["failure"] === nothing &&
        result["recovery_failure"] === nothing && result["restoration_confirmed"] === true &&
        result["resume_permitted"] === true,"Rust calibration did not complete restored")
    batches = result["responses"]
    require(length(batches) == length(plan["probes"]),"response batch count differs")
    domain = startup["acquisition_domain_mapping"]["opaque_domain"]
    generation = startup["acquisition_generation"]
    duration = round(Int,startup["detector_config"]["exposure_duration_s"]*1e9)
    previous = nothing
    for batch in batches
        require(batch["valid"] === true && length(batch["values"]) == plan["measurements"] &&
            all(x -> x isa Real && !(x isa Bool) && isfinite(Float32(x)),batch["values"]),
            "response is not a valid finite Float32 vector of the declared extent")
        exposures = batch["exposures"]
        require(length(exposures) == plan["frames_per_probe"],"exposure count differs")
        for (index,e) in enumerate(exposures)
            require(all(x -> x isa Integer && !(x isa Bool) && 0 <= x <= typemax(UInt64),values(e)),
                "exposure identity is outside UInt64")
            require(e["domain"] == domain && e["generation"] == generation &&
                e["sequence"] > 0 && e["duration_ns"] == duration,"exposure model identity differs")
            finish = Int128(e["start_model_ns"])+Int128(e["duration_ns"])
            require(finish <= typemax(UInt64),"exposure model time overflow")
            if previous !== nothing
                require(e["sequence"] > previous["sequence"] &&
                    Int128(e["start_model_ns"]) >= Int128(previous["start_model_ns"])+duration,
                    "duplicate, stale, overlapping or unrelated exposure")
                index == 1 || require(e["sequence"] == previous["sequence"]+1,
                    "response exposures are not consecutive")
                if index == 1 && plan["settling"]["kind"] == "discard_exposures"
                    require(Int128(e["sequence"]) >= Int128(previous["sequence"])+
                        plan["settling"]["frames"]+1,"declared settling exposures were not discarded")
                end
            elseif plan["settling"]["kind"] == "discard_exposures"
                require(e["sequence"] >= plan["settling"]["frames"]+1,
                    "first response did not follow settling")
            end
            previous = e
        end
    end
    return previous
end

function verify_reset_rejection(connection, before; deadline,check,
        request=Lifecycle.request!, status=Lifecycle.status)
    rejected = request(connection,:reset;deadline,check)
    require(rejected isa L.Completion && rejected.header.result == -95 &&
        rejected.lifecycle === L.Connected &&
        occursin("fresh instance",rejected.message),"calibration Reset was not explicitly unsupported")
    after = status(connection;deadline,check)
    a,b = before.snapshot,after.snapshot
    require(before.lifecycle === L.Connected && after.lifecycle === before.lifecycle &&
        cursor(a.cursor) == cursor(b.cursor) && cursor(a.report_cursor) == cursor(b.report_cursor) && a.phase == b.phase &&
        a.held == b.held && a.restored == b.restored && a.completed == b.completed &&
        a.running == b.running,"rejected Reset changed owner facts")
    return Dict("result"=>rejected.header.result,"message"=>rejected.message,
        "instance"=>rejected.header.endpoint_instance,"token"=>rejected.header.token,
        "before_cursor"=>Actions._cursor_document(a.cursor),
        "after_cursor"=>Actions._cursor_document(b.cursor),"facts_unchanged"=>true)
end

function capture!(endpoint, plan, startup, instance, output; deadline,check)
    request(action,expected) = Actions.request!(endpoint,action,expected;deadline,check)
    reference,figure = Float32.(plan["reference"]),Float32.(first(plan["probes"]))
    held = request(Wire.Hold(),"held")
    adopted = request(Wire.Adopt(UInt32(0),figure),"adopted")
    require(!adopted["clipped"] && Campaign.same_figure(adopted["figure"],figure) &&
        adopted["cursor"] == held["cursor"],"Capture probe adoption changed or clipped")
    after = Actions._cursor(adopted["cursor"])
    rule = Actions._rule(plan["settling"])
    settled = request(Wire.Settle(UInt32(0),after,rule),"settled")
    completion = request(Wire.Capture(UInt32(0),Actions._cursor(settled["cursor"]),UInt32(2)),"captured")
    serial = endpoint.serial
    Campaign.copy_tree(joinpath(instance,"captured"),joinpath(output,"captured"))
    manifest = Campaign.verify_capture(joinpath(output,"captured"),completion;
        run=plan["run"],serial,stage="native-functional",frames=2,
        after=settled["cursor"],startup,profile="classic",probe=0)
    restored = request(Wire.Restore(reference,rule),"restored")
    require(!restored["clipped"] && Campaign.same_figure(restored["figure"],reference),
        "Capture reference restoration changed or clipped")
    request(Wire.Release(),"released")
    return Dict("completion"=>completion,"manifest"=>manifest,"requests"=>endpoint.records,
        "restoration_confirmed"=>true,"release_confirmed"=>true)
end

function main(args=ARGS)
    length(args) == 5 || error("usage: PACKAGE FRESH_RUNTIME FRESH_OUTPUT PLAN collect|capture")
    package,runtime,output,plan_path = abspath.(args[1:4])
    mode = args[5]
    mode in ("collect","capture") || error("unsupported qualification mode")
    !ispath(runtime) && !islink(runtime) && !ispath(output) && !islink(output) || error("fresh paths required")
    plan = C.read_json(plan_path)
    D.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")
    Wire.preflight_collect_reply(plan["measurements"],plan["frames_per_probe"])
    mkpath(output)
    record = Dict{String,Any}("scope"=>"installed functional calibration; no inverse/numerical/rate/hardware acceptance",
        "mode"=>mode,"package"=>package,"plan_sha256"=>C.sha256_file(plan_path),
        "package_deployment_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
        "qualifier_sha256"=>C.sha256_file(@__FILE__),
        "native_runner_sha256"=>C.sha256_file(joinpath(package,"bin/pipewireao-rtc")),
        "calibration_cli_sha256"=>C.sha256_file(joinpath(package,"bin/rtc-calibrate")),
        "restoration_confirmed"=>false,"release_confirmed"=>false,
        "shutdown_confirmed"=>false,"success"=>false)
    command = Campaign.stage_command(package,runtime;owner_preparation_timeout_seconds=300)
    record["run_argv"] = command
    process = endpoint = lifecycle = nothing
    identities = Dict{String,Any}()
    try
        open(joinpath(output,"deployment.log"),"w") do log
            process = run(pipeline(Cmd(command),stdout=log,stderr=log);wait=false)
            D.wait_state(runtime,state->get(state,"admitted",false) && get(state,"state",nothing)=="Running";
                    timeout=360,process) do ready,supervisor
                check() = (process_running(process) || error("owned supervisor exited"))
                try
                    Q.verify_admission_client(supervisor,ready,getpid(process))
                    identities = Q.owned_process_identities(ready["processes"],getpid(process))
                    record["ready"] = ready
                    record["owned_processes"] = identities
                    instance = ready["private_runtime"]
                    source = ready["source_endpoint"]
                    lifecycle = Lifecycle.connect(L.CALIBRATION_PROFILE,ready["observation_remote"],
                        source["node"],source["owner_pid"],source["instance"],L.Classic;
                        deadline=Native.monotonic()+20,check)
                    initial = Lifecycle.status(lifecycle;deadline=Native.monotonic()+20,check)
                    require(initial.lifecycle === L.Connected && initial.snapshot.running &&
                        initial.snapshot.cursor.sequence == 0 &&
                        initial.snapshot.phase == "initial" && !initial.snapshot.held,"owner is not a fresh calibration instance")
                    startup = C.read_json(joinpath(instance,"simulator-result.json"))
                    require(startup["profile"] == "classic" && startup["phase"] == "initial" &&
                        startup["failure"] === nothing && !startup["ownership_held"] &&
                        startup["sequence"] == initial.snapshot.cursor.sequence &&
                        startup["acquisition_generation"] == initial.snapshot.cursor.generation &&
                        startup["cursor_model_ns"] == initial.snapshot.cursor.model_ns &&
                        startup["acquisition_domain_mapping"]["opaque_domain"] == initial.snapshot.cursor.domain &&
                        startup["graph_sha256"] == C.sha256_file(joinpath(package,"hil/plant.toml")),
                        "saved startup report differs from the fresh owner cursor/plant")
                    record["startup_report"] = startup
                    binding = Actions.Binding(ready["observation_remote"],source["node"]*".actions",
                        source["owner_pid"],source["instance"])
                    if mode == "collect"
                        argv = [joinpath(package,"bin/rtc-calibrate"),"--remote",binding.remote,
                            "--node",binding.node,"--owner-pid",string(binding.owner_pid),
                            "--owner-instance",string(binding.instance),"--plan",plan_path]
                        record["calibration_argv"] = argv
                        response = Campaign.run_checked(argv;timeout=180,
                            maximum_output_bytes=Campaign.interaction_result_output_limit_bytes(plan_path))
                        write(joinpath(output,"rtc-calibrate.json"),response.stdout)
                        write(joinpath(output,"rtc-calibrate.stderr"),response.stderr)
                        require(response.returncode == 0,"Rust calibration process failed")
                        result = C.parse_json(response.stdout)
                        last = verify_collect(result,plan,startup)
                        record["collect"] = result
                        record["last_exposure"] = last
                    else
                        endpoint = Actions.connect(binding,plan["run"],20_000_000_000;
                            deadline=Native.monotonic()+20,check)
                        record["capture"] = capture!(endpoint,plan,startup,instance,output;
                            deadline=Native.monotonic()+20,check)
                        close(endpoint); endpoint=nothing
                    end
                    record["restoration_confirmed"] = record["release_confirmed"] = true
                    final,report = verified_report(lifecycle,joinpath(instance,"simulator-result.json"),startup;
                        deadline=Native.monotonic()+20,check)
                    record["completed_report"] = report
                    record["completed_report_sha256"] = C.sha256_file(joinpath(instance,"simulator-result.json"))
                    cp(joinpath(instance,"simulator-result.json"),joinpath(output,"completed-owner-report.json"))
                    if mode == "collect"
                        last = record["last_exposure"]
                        require(final.snapshot.cursor.domain == last["domain"] &&
                            final.snapshot.cursor.generation == last["generation"] &&
                            final.snapshot.cursor.sequence > last["sequence"] &&
                            Int128(final.snapshot.cursor.model_ns) >
                                Int128(last["start_model_ns"])+Int128(last["duration_ns"]),
                            "reference restoration did not fence a fresh settling exposure")
                    end
                    record["reset_rejection"] = verify_reset_rejection(lifecycle,final;
                        deadline=Native.monotonic()+20,check)
                    close(lifecycle); lifecycle=nothing
                    Q.native_control(supervisor,["session-stop"];timeout=20)
                    Q.native_control(supervisor,["quit"];timeout=30)
                    record["final"] = D.wait_final_report(runtime,process;owner_pid=getpid(process),timeout=55)
                    require(success(process) && record["final"]["phase"] == "stopped" &&
                        !ispath(instance),"native owned shutdown failed")
                    record["shutdown_confirmed"] = true
                    record["cleanup"] = Q.observed_cleanup(process,identities)
                    require(record["cleanup"]["status"] == "complete","owned child cleanup unresolved")
                finally
                    if process_running(process)
                        # Use the retained admitted client while it is available.
                        # Quit may reject an unresolved hold; record that result,
                        # then let the owned supervisor reconcile its children.
                        attempts = Any[]
                        for operation in ("session-stop","quit")
                            try
                                push!(attempts,Q.native_control(supervisor,[operation];timeout=20))
                            catch cleanup
                                push!(attempts,Dict("operation"=>operation,"failure"=>sprint(showerror,cleanup)))
                            end
                        end
                        record["native_cleanup_attempts"] = attempts
                    end
                end
            end
        end
        # wait_state owns the retained client's finally-close. That entire
        # scope and the log close must return before success becomes possible.
        record["success"] = true
    catch primary
        record["success"] = false
        record["failure"] = sprint(showerror,primary)
    finally
        # Unknown outcomes retain owner hold/fault; this coordinator never sends
        # speculative Restore/Release after a lost action completion.
        for client in (endpoint,lifecycle)
            client === nothing && continue
            try close(client) catch cleanup
                record["success"] = false
                record["client_cleanup_failure"] = sprint(showerror,cleanup)
            end
        end
        if process !== nothing && process_running(process)
            record["success"] = false
            try record["cleanup"] = Q.fallback_cleanup(process,identities)
            catch cleanup; record["cleanup_failure"] = sprint(showerror,cleanup) end
        end
        record["success"] = qualification_exit_code(record) == 0
        C.write_json(joinpath(output,"qualification.json"),record)
    end
    println(joinpath(output,"qualification.json"))
    return qualification_exit_code(record)
end
end
abspath(PROGRAM_FILE) == (@__FILE__) && exit(NativeCalibrationQualification.main(ARGS))
