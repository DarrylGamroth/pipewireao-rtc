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
const Heart = PipeWireAODeployment.NativeHeartClient
const H = PipeWireAODeployment.NativeHeartCodec

require(value, message) = value === true || error(message)
cursor(c) = (c.domain, c.generation, c.sequence, c.model_ns)
cursor(::Nothing) = nothing

"Launch the sealed installed deployment SDK, retaining the current Julia executable."
function installed_command(package,runtime;owner_preparation_timeout_seconds=300)
    Campaign.positive_integer(owner_preparation_timeout_seconds,"owner preparation timeout seconds",3600)
    sdk=joinpath(package,"julia")
    return [Base.julia_cmd().exec[1],"--startup-file=no","--project="*sdk,
        joinpath(sdk,"deploy_cli.jl"),"run","--deployment",joinpath(package,"deployment.conf"),
        "--runtime",runtime,"--pipewire-prefix","/opt/pipewireao",
        "--owner-preparation-timeout-seconds",string(owner_preparation_timeout_seconds)]
end

function runtime_receipt(package)
    sdk=joinpath(package,"julia")
    files=[joinpath(sdk,name) for name in ("Project.toml","Manifest.toml","deploy_cli.jl")]
    append!(files,filter(path->endswith(path,".jl"),readdir(joinpath(sdk,"src");join=true)))
    require(all(path->!islink(path) && isfile(path),files),"installed runtime source is absent or linked")
    return Dict(relpath(path,package)=>C.sha256_file(path) for path in sort!(files))
end

function owner_argument(owner, name)
    positions = findall(==(name),owner["argv"])
    require(length(positions) == 1 && only(positions) < length(owner["argv"]),
        "sealed owner argument $name is missing or duplicated")
    return owner["argv"][only(positions)+1]
end

"Derive the action fixture from sealed owner/provenance declarations before launch."
function selected_fixture(specification, provenance, plan; mode)
    profile,engine = provenance["profile"],provenance["engine"]
    require(profile in ("classic","copper") && engine in ("fgn","jfg","heart"),
        "unsupported calibration profile or engine")
    source = only(filter(owner -> owner["role"] == specification["source-owner"],specification["owners"]))
    require(source["control-protocol"] == Native.profile_name(L.CALIBRATION_PROFILE) &&
        source["instrument"] == profile && owner_argument(source,"--profile") == profile,
        "sealed source is not the selected native calibration owner")
    calibration = engine == "heart" ? provenance["heart_calibration"] : provenance
    stage = engine == "heart" ? calibration["stage"] : calibration["calibration_stage"]
    require(stage isa String && occursin(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$",stage) &&
        owner_argument(source,"--calibration-stage") == stage &&
        owner_argument(source,"--illumination") == calibration["illumination"],
        "sealed calibration stage or illumination differs from owner arguments")
    budget = Campaign.positive_integer(calibration["capture_max_payload_bytes"],"Capture budget",1024^3)
    require(tryparse(UInt64,owner_argument(source,"--capture-max-bytes")) == budget,
        "sealed Capture budget differs from owner arguments")
    Campaign.fields(plan,("version","run","reference","probes","measurements",
        "frames_per_probe","settling","timeouts_ns"),"functional action plan")
    require(Campaign.isint(plan["version"]) && plan["version"] == 1,"invalid action plan version")
    Campaign.positive_integer(plan["run"],"action run",typemax(UInt64))
    measurements = profile == "classic" ? 376 : 3600
    require(Campaign.isint(plan["measurements"]) && plan["measurements"] == measurements,
        "action plan measurement extent differs from selected owner")
    Campaign.positive_integer(length(plan["probes"]),"probe count",16384)
    for figure in Iterators.flatten(((plan["reference"],),plan["probes"]))
        require(figure isa AbstractVector && length(figure) == 277,"action figure requires 277 physical coordinates")
        foreach(Campaign.wire_float32,figure)
    end
    frames = Campaign.positive_integer(plan["frames_per_probe"],"frames per probe",64)
    Campaign.validate_settling(plan["settling"];copper=profile == "copper")
    Campaign.fields(plan["timeouts_ns"],("ownership","adoption","settling","collection","restoration"),"action timeouts")
    foreach(value -> Campaign.positive_integer(value,"action timeout",30_000_000_000),values(plan["timeouts_ns"]))
    Wire.preflight_collect_reply(measurements,frames)
    _,payload = Campaign.capture_contract(profile)
    required_payload = Base.checked_mul(payload,2)
    mode == "capture" && require(budget >= required_payload,"two-frame Capture exceeds the sealed payload budget")
    ingress = engine == "heart" ? calibration["native_ingress"]["mode"] : nothing
    engine == "heart" && require(ingress in ("streaming","deferred") &&
        owner_argument(source,"--heart-native-ingress-mode") == ingress,
        "sealed HEART ingress differs from source arguments")
    if engine == "heart"
        require(isabspath(calibration["owner_evidence_directory"]) &&
            owner_argument(source,"--heart-probe-directory") == calibration["owner_evidence_directory"] &&
            tryparse(UInt64,owner_argument(source,"--heart-telemetry-max-bytes")) ==
                Campaign.positive_integer(calibration["telemetry_max_bytes_per_file"],"native evidence budget",1024^3),
            "sealed HEART evidence directory/budget differs from source arguments")
    end
    return (;profile,engine,instrument=profile == "classic" ? L.Classic : L.Copper,
        stage,illumination=calibration["illumination"],budget,required_payload,
        backend=owner_argument(source,"--backend"),source_role=source["role"],source_node=source["control-node"],
        ingress,evidence_directory=engine == "heart" ? calibration["owner_evidence_directory"] : nothing,
        telemetry_budget=engine == "heart" ? calibration["telemetry_max_bytes_per_file"] : nothing,
        native_config_sha256=engine == "heart" ? calibration["native_config_sha256"] : nothing)
end

function verify_startup(startup, initial, fixture, plant_sha256)
    require(initial.lifecycle === L.Connected && initial.snapshot.instrument === fixture.instrument &&
        initial.snapshot.running && initial.snapshot.cursor.sequence == 0 &&
        initial.snapshot.phase == "initial" && !initial.snapshot.held,
        "owner is not a fresh selected calibration instance")
    require(startup["profile"] == fixture.profile && startup["backend"] == fixture.backend &&
        startup["calibration_stage"] == fixture.stage && startup["illumination"] == fixture.illumination &&
        startup["phase"] == "initial" && startup["failure"] === nothing && !startup["ownership_held"] &&
        startup["sequence"] == initial.snapshot.cursor.sequence &&
        startup["acquisition_generation"] == initial.snapshot.cursor.generation &&
        startup["cursor_model_ns"] == initial.snapshot.cursor.model_ns &&
        startup["acquisition_domain_mapping"]["opaque_domain"] == initial.snapshot.cursor.domain &&
        startup["graph_sha256"] == plant_sha256,
        "saved startup report differs from the selected owner cursor/plant/settings")
    return nothing
end

function verify_heart_snapshot(snapshot, fixture; previous=nothing)
    require(snapshot.generation == 1 && snapshot.child_pid !== nothing && snapshot.alive &&
        snapshot.child_returncode === nothing && snapshot.placement_validated && snapshot.diagnostics_disabled &&
        snapshot.ingress === (fixture.ingress == "streaming" ? H.Streaming : H.Deferred),
        "HEART child is not a healthy fresh placed generation with diagnostics disabled")
    previous === nothing || require(snapshot.generation == previous.generation &&
        snapshot.child_pid == previous.child_pid && snapshot.report_path == previous.report_path &&
        snapshot.report_sha256 == previous.report_sha256,"HEART child identity or generation publication changed")
    return nothing
end

function verify_heart_hold(report, snapshot, fixture)
    held = report["native_controller_held"]
    require(held !== nothing && all(Campaign.isint(held[field]) for field in ("child_pid","generation","admitted_frames")) &&
        held["child_pid"] == snapshot.child_pid && held["generation"] == snapshot.generation &&
        held["run_acknowledged"] === true && held["endpoints_acknowledged"] === true &&
        held["endpoint_enable_command"] == "startup CORRECT" && held["admitted_frames"] == 0 &&
        occursin(r"^[0-9a-f]{64}$",held["endpoint_reply_sha256"]) &&
        held["ingress_mode"] == fixture.ingress &&
        held["ingress_environment"] == (fixture.ingress == "streaming" ? "0" : "1"),
        "saved calibration native hold differs from the fresh HEART child/enable proof")
    bound = held["snapshot"]
    require(bound !== nothing && bound["generation"] == snapshot.generation && bound["child_pid"] == snapshot.child_pid &&
        bound["alive"] === true && bound["placement_validated"] === true && bound["diagnostics_disabled"] === true &&
        bound["report_path"] == snapshot.report_path && bound["report_sha256"] == snapshot.report_sha256,
        "saved calibration hold has no matching native HEART snapshot")
    return held
end

function heart_checkpoint(client, root, fixture; deadline,check,previous=nothing,
        generation_report=Heart.generation_report)
    snapshot, saved = generation_report(client,root;deadline,check)
    verify_heart_snapshot(snapshot,fixture;previous)
    report = C.parse_json(C.JSON3.write(saved))
    require(report["state"] == "paused" && report["error"] === nothing && report["sequence"] == 0 &&
        report["source_config_sha256"] == fixture.native_config_sha256 &&
        report["native_ingress"]["mode"] == fixture.ingress &&
        report["native_ingress"]["observed_environment"] == (fixture.ingress == "streaming" ? "0" : "1"),
        "published HEART generation differs from the sealed native configuration/ingress")
    return snapshot,report
end

function heart_child_identity(snapshot, wrapper_pid, identities; observe=Q.process_identity)
    observed = observe(snapshot.child_pid)
    owned = identities["heart"]
    require(owned["ownership_confirmed"] && observed !== nothing && observed.parent_pid == wrapper_pid &&
        observed.group_pid == observed.session_pid == owned["pid"],"HEART child is outside the confirmed owned wrapper group")
    return Dict(string(k)=>v for (k,v) in pairs(observed))
end

function heart_child_absent(identity; observe=Q.process_identity)
    current = observe(identity["pid"])
    return current === nothing || current.start_ticks != identity["start_ticks"]
end

same_child_identity(a,b) = all(a[field] == b[field] for field in
    ("pid","parent_pid","group_pid","session_pid","start_ticks"))

function retain_heart_evidence(report, fixture, output)
    evidence = report["native_evidence"]
    path = joinpath(fixture.evidence_directory,"native-evidence.jsonl")
    require(evidence["path"] == path && !islink(path) && isfile(path),"native evidence is outside the sealed owner directory")
    bytes = Campaign.positive_integer(evidence["bytes"],"native evidence bytes",fixture.telemetry_budget)
    require(Campaign.isint(evidence["records"]) && evidence["records"] > 0 &&
        filesize(path) == bytes && C.sha256_file(path) == evidence["sha256"] &&
        countlines(path) == evidence["records"],"native evidence count/bytes/hash differs from published owner report")
    destination = joinpath(output,"native-evidence.jsonl")
    cp(path,destination)
    require(filesize(destination) == bytes && C.sha256_file(destination) == evidence["sha256"],
        "retained native evidence differs from published owner bytes")
    return merge(evidence,Dict("retained_path"=>destination))
end

"Retain the owner report on a failed qualification without hiding its primary error."
function retain_failure_owner_report!(record, instance, output)
    instance === nothing && return
    source = joinpath(instance,"simulator-result.json")
    isfile(source) && !islink(source) || return
    delete!(record,"failure_owner_report_sha256")
    delete!(record,"failure_owner_report_copy_failure")
    destination = joinpath(output,"failure-owner-report.json")
    try
        cp(source,destination;force=true)
        record["failure_owner_report_sha256"] = C.sha256_file(destination)
    catch copy_failure
        record["failure_owner_report_copy_failure"] = sprint(showerror,copy_failure)
    end
    return
end

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
    if get(record,"engine",nothing) == "heart"
        all(get(record,key,false) === true for key in ("heart_child_identity_confirmed",
            "heart_health_confirmed","heart_child_cleanup_confirmed")) || return 1
    end
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

function capture!(endpoint, plan, startup, instance, output; deadline,check,
        request_action=Actions.request!, copy_captured=Campaign.copy_tree,
        verify_capture=Campaign.verify_capture)
    request(action,expected) = request_action(endpoint,action,expected;deadline,check)
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
    copy_captured(joinpath(instance,"captured"),joinpath(output,"captured"))
    manifest = verify_capture(joinpath(output,"captured"),completion;
        run=plan["run"],serial,stage=startup["calibration_stage"],frames=2,
        after=settled["cursor"],startup,profile=startup["profile"],probe=0)
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
    specification = D.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")
    provenance = C.read_json(joinpath(package,"provenance.json"))
    fixture = selected_fixture(specification,provenance,plan;mode)
    declared_plan = fixture.engine == "heart" ? provenance["heart_calibration"]["frozen_plan"] : nothing
    if declared_plan !== nothing
        require(declared_plan["path"] == "heart-calibration-plan.json" &&
            C.sha256_file(joinpath(package,declared_plan["path"])) == declared_plan["sha256"],
            "declared HEART export plan bytes differ")
    end
    mkpath(output)
    record = Dict{String,Any}("scope"=>"installed functional calibration; no inverse/numerical/rate/hardware acceptance",
        "mode"=>mode,"package"=>package,"profile"=>fixture.profile,"engine"=>fixture.engine,
        "backend"=>fixture.backend,"calibration_stage"=>fixture.stage,
        "plan_sha256"=>C.sha256_file(plan_path),"declared_export_plan"=>declared_plan,
        "exporter_full_plan_gate"=>"not evaluated; separate functional action caller",
        "package_deployment_sha256"=>C.sha256_file(joinpath(package,"deployment.conf")),
        "qualifier_sha256"=>C.sha256_file(@__FILE__),
        "installed_runtime_sha256"=>runtime_receipt(package),
        "native_runner_sha256"=>C.sha256_file(joinpath(package,"bin/pipewireao-rtc")),
        "calibration_cli_sha256"=>C.sha256_file(joinpath(package,"bin/rtc-calibrate")),
        "restoration_confirmed"=>false,"release_confirmed"=>false,
        "shutdown_confirmed"=>false,"success"=>false)
    command = installed_command(package,runtime;owner_preparation_timeout_seconds=300)
    record["run_argv"] = command
    process = endpoint = lifecycle = heart = instance = nothing
    heart_initial = child_identity = nothing
    identities = Dict{String,Any}()
    try
        open(joinpath(output,"deployment.log"),"w") do log
            process = run(pipeline(Cmd(command),stdout=log,stderr=log);wait=false)
            D.wait_state(runtime,state->get(state,"admitted",false) && get(state,"state",nothing)=="Running";
                    timeout=360,process) do ready,supervisor
                check() = begin
                    process_running(process) || error("owned supervisor exited")
                    heart === nothing || Heart.require_ready(heart,heart_initial)
                    nothing
                end
                try
                    Q.verify_admission_client(supervisor,ready,getpid(process))
                    identities = Q.owned_process_identities(ready["processes"],getpid(process))
                    record["ready"] = ready
                    record["owned_processes"] = identities
                    instance = ready["private_runtime"]
                    source = ready["source_endpoint"]
                    require(source["node"] == fixture.source_node && source["instrument"] == fixture.profile &&
                        source["owner_pid"] == identities[fixture.source_role]["pid"],
                        "native supervisor admitted another source binding/instrument")
                    if fixture.engine == "heart"
                        binding = ready["heart_endpoint"]
                        expected_owner = only(filter(D.native_heart,specification["owners"]))
                        require(binding["node"] == expected_owner["control-node"] &&
                            binding["owner_pid"] == identities["heart"]["pid"],
                            "native supervisor admitted another HEART wrapper")
                        heart = Heart.connect(ready["observation_remote"],binding["node"],
                            binding["owner_pid"],binding["instance"];
                            deadline=Native.monotonic()+20,check=()->(process_running(process) || error("owned supervisor exited")))
                        heart_initial,generation = heart_checkpoint(heart,joinpath(instance,"heart/native"),fixture;
                            deadline=Native.monotonic()+20,check=()->(process_running(process) || error("owned supervisor exited")))
                        child_identity = heart_child_identity(heart_initial,binding["owner_pid"],identities)
                        record["heart_initial"] = generation
                        record["heart_child_identity"] = child_identity
                        record["heart_required_flags_sha256"] = C.sha256_file(joinpath(package,"heart/requirements.json"))
                        record["heart_child_identity_confirmed"] = true
                    end
                    lifecycle = Lifecycle.connect(L.CALIBRATION_PROFILE,ready["observation_remote"],
                        source["node"],source["owner_pid"],source["instance"],fixture.instrument;
                        deadline=Native.monotonic()+20,check)
                    initial = Lifecycle.status(lifecycle;deadline=Native.monotonic()+20,check)
                    startup = C.read_json(joinpath(instance,"simulator-result.json"))
                    verify_startup(startup,initial,fixture,C.sha256_file(joinpath(package,"hil/plant.toml")))
                    fixture.engine == "heart" && verify_heart_hold(startup,heart_initial,fixture)
                    record["startup_report"] = startup
                    binding = Actions.Binding(ready["observation_remote"],source["node"]*".actions",
                        source["owner_pid"],source["instance"])
                    if mode == "collect"
                        argv = [joinpath(package,"bin/rtc-calibrate"),"--remote",binding.remote,
                            "--node",binding.node,"--owner-pid",string(binding.owner_pid),
                            "--owner-instance",string(binding.instance),"--plan",plan_path,
                            "--evidence",joinpath(output,"calibration-completions.jsonl")]
                        record["calibration_argv"] = argv
                        response = Campaign.run_checked(argv;timeout=180,
                            maximum_output_bytes=Campaign.interaction_result_output_limit_bytes(plan_path))
                        write(joinpath(output,"rtc-calibrate.json"),response.stdout)
                        write(joinpath(output,"rtc-calibrate.stderr"),response.stderr)
                        evidence_path = joinpath(output,"calibration-completions.jsonl")
                        if isfile(evidence_path) && !islink(evidence_path)
                            record["calibration_completions_evidence"] = Dict(
                                "path"=>evidence_path,"sha256"=>C.sha256_file(evidence_path))
                        end
                        response.returncode == 0 || retain_failure_owner_report!(record,instance,output)
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
                    if fixture.engine == "heart"
                        current,generation = heart_checkpoint(heart,joinpath(instance,"heart/native"),fixture;
                            deadline=Native.monotonic()+20,check,previous=heart_initial)
                        verify_heart_hold(report,current,fixture)
                        require(same_child_identity(heart_child_identity(current,heart.observation.owner_pid,identities),child_identity),
                            "owned HEART child process identity changed during calibration")
                        record["heart_final"] = generation
                        record["native_evidence"] = retain_heart_evidence(report,fixture,output)
                        record["heart_health_confirmed"] = true
                    end
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
                    if heart !== nothing
                        close(heart); heart=nothing
                    end
                    Q.native_control(supervisor,["session-stop"];timeout=20)
                    Q.native_control(supervisor,["quit"];timeout=30)
                    record["final"] = D.wait_final_report(runtime,process;owner_pid=getpid(process),timeout=55)
                    require(success(process) && record["final"]["phase"] == "stopped" &&
                        !ispath(instance),"native owned shutdown failed")
                    record["shutdown_confirmed"] = true
                    record["cleanup"] = Q.observed_cleanup(process,identities)
                    require(record["cleanup"]["status"] == "complete","owned child cleanup unresolved")
                    if child_identity !== nothing
                        record["heart_child_cleanup_confirmed"] = heart_child_absent(child_identity)
                        require(record["heart_child_cleanup_confirmed"],"owned HEART child survived native shutdown")
                    end
                catch primary
                    record["success"] = false
                    record["failure"] = sprint(showerror,primary)
                    retain_failure_owner_report!(record,instance,output)
                    rethrow()
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
        for client in (endpoint,lifecycle,heart)
            client === nothing && continue
            try close(client) catch cleanup
                record["success"] = false
                record["client_cleanup_failure"] = sprint(showerror,cleanup)
            end
        end
        record["success"] || retain_failure_owner_report!(record,instance,output)
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
