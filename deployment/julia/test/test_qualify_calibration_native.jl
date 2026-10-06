using Test
include(joinpath(@__DIR__,"../../qualify_calibration_native.jl"))
const CQ = NativeCalibrationQualification
const LCQ = CQ.L
const HCQ = CQ.PipeWireAODeployment.NativeControlCodec

@testset "Native qualifiers launch the sealed installed runtime" begin
    command=CQ.installed_command("/sealed/package","/fresh/runtime";owner_preparation_timeout_seconds=900)
    @test command[3:4] == ["--project=/sealed/package/julia","/sealed/package/julia/deploy_cli.jl"]
    @test command[end-1:end] == ["--owner-preparation-timeout-seconds","900"]
    @test_throws ArgumentError CQ.installed_command("unused","unused";owner_preparation_timeout_seconds=true)
    mktempdir() do package
        sdk=joinpath(package,"julia");mkpath(joinpath(sdk,"src"))
        for name in ("Project.toml","Manifest.toml","deploy_cli.jl","src/deploy.jl","src/native_control_client.jl")
            write(joinpath(sdk,name),name)
        end
        receipt=CQ.runtime_receipt(package)
        @test length(receipt) == 5
        @test receipt["julia/src/deploy.jl"] == CQ.C.sha256_file(joinpath(sdk,"src/deploy.jl"))
        rm(joinpath(sdk,"src/deploy.jl"));symlink("../deploy_cli.jl",joinpath(sdk,"src/deploy.jl"))
        @test_throws ErrorException CQ.runtime_receipt(package)
    end
end

function collect_fixture()
    plan = Dict("version"=>1,"run"=>82,"reference"=>zeros(Float32,277),
        "probes"=>[zeros(Float32,277) for _ in 1:4],"measurements"=>376,
        "frames_per_probe"=>16,"settling"=>Dict("kind"=>"discard_exposures","frames"=>1))
    startup = Dict("acquisition_domain_mapping"=>Dict("opaque_domain"=>1),
        "acquisition_generation"=>1,"detector_config"=>Dict("exposure_duration_s"=>0.001896))
    result = Dict("version"=>1,"run"=>82,"phase"=>"complete","failure"=>nothing,
        "recovery_failure"=>nothing,"restoration_confirmed"=>true,"resume_permitted"=>true,
        "responses"=>[Dict("valid"=>true,"values"=>zeros(Float32,376),
            "exposures"=>[Dict{String,Any}("domain"=>1,"generation"=>1,"sequence"=>(batch-1)*17+index+1,
                "start_model_ns"=>((batch-1)*17+index)*2_000_000,"duration_ns"=>1_896_000)
                for index in 1:16]) for batch in 1:4])
    return result,plan,startup
end

function selected_fixture_input(profile,engine)
    stage = engine == "heart" ? "nativepilot" : "interaction"
    _,payload = CQ.Campaign.capture_contract(profile)
    calibration = Dict{String,Any}("calibration_stage"=>stage,"stage"=>stage,"illumination"=>"lamp",
        "capture_max_payload_bytes"=>2payload,"native_ingress"=>Dict("mode"=>"streaming"),
        "owner_evidence_directory"=>"/private/evidence","telemetry_max_bytes_per_file"=>512*1024,
        "native_config_sha256"=>repeat("a",64))
    owner=Dict("role"=>"simulator","control-protocol"=>"pipewireao.rtc.calibration-lifecycle/1",
        "control-node"=>"source.calibration","instrument"=>profile,"argv"=>[
            "julia","--profile",profile,"--backend","cuda","--calibration-stage",stage,
            "--illumination","lamp","--capture-max-bytes",string(2payload),
            "--heart-native-ingress-mode","streaming","--heart-probe-directory","/private/evidence",
            "--heart-telemetry-max-bytes",string(512*1024)])
    specification=Dict("source-owner"=>"simulator","owners"=>[owner])
    provenance=merge(calibration,Dict("profile"=>profile,"engine"=>engine,"heart_calibration"=>calibration))
    plan=Dict("version"=>1,"run"=>82,"reference"=>zeros(Float32,277),"probes"=>[zeros(Float32,277)],
        "measurements"=>profile=="classic" ? 376 : 3600,"frames_per_probe"=>2,
        "settling"=>Dict("kind"=>"discard_exposures","frames"=>1),
        "timeouts_ns"=>Dict{String,Any}(key=>20_000_000_000 for key in ("ownership","adoption","settling","collection","restoration")))
    return specification,provenance,plan
end

@testset "Sealed six-profile fixture derives extents and rejects before launch" begin
    for profile in ("classic","copper"), engine in ("fgn","jfg","heart")
        specification,provenance,plan=selected_fixture_input(profile,engine)
        fixture=CQ.selected_fixture(specification,provenance,plan;mode="capture")
        @test fixture.profile==profile && fixture.engine==engine && fixture.backend=="cuda"
        @test fixture.instrument === (profile=="classic" ? LCQ.Classic : LCQ.Copper)
        @test fixture.stage == (engine=="heart" ? "nativepilot" : "interaction")
        @test fixture.required_payload == fixture.budget == (profile=="classic" ? 500504 : 45192)
        for (expected,mutate!) in (
            (ErrorException,p->(p["measurements"]=profile=="classic" ? 3600 : 376)),
            (ErrorException,p->pop!(p["reference"])),
            (ErrorException,p->pop!(first(p["probes"]))),
            (ArgumentError,p->(p["reference"][1]=NaN32)),
            (ArgumentError,p->(p["probes"][1][1]=Inf32)),
            (ArgumentError,p->(p["run"]=true)),
            (ArgumentError,p->(p["timeouts_ns"]["collection"]=true)),
            (ArgumentError,p->(p["timeouts_ns"]["collection"]=30_000_000_001)),
        )
            changed=deepcopy(plan);mutate!(changed)
            @test_throws expected CQ.selected_fixture(specification,provenance,changed;mode="capture")
        end
        changed=deepcopy(specification);changed["owners"][1]["instrument"] = profile=="classic" ? "copper" : "classic"
        @test_throws ErrorException CQ.selected_fixture(changed,provenance,plan;mode="capture")
        changed=deepcopy(provenance)
        target=engine=="heart" ? changed["heart_calibration"] : changed
        target["capture_max_payload_bytes"]=1
        changed_spec=deepcopy(specification)
        argv=changed_spec["owners"][1]["argv"];argv[findfirst(==("--capture-max-bytes"),argv)+1]="1"
        @test_throws ErrorException CQ.selected_fixture(changed_spec,changed,plan;mode="capture")
    end
end

@testset "Fresh startup matches selected native instrument/settings" begin
    header=HCQ.ReplyHeader(HCQ.ControllerIdentity(UInt32(1234),UInt64(8),Int64(1)),Int64(7),Int64(2),UInt32(1),Int32(0))
    for profile in ("classic","copper")
        specification,provenance,plan=selected_fixture_input(profile,"fgn")
        fixture=CQ.selected_fixture(specification,provenance,plan;mode="collect")
        cursor=LCQ.AcquisitionCursor(typemax(UInt64),1,0,0)
        initial=LCQ.Completion(header,LCQ.Connected,
            LCQ.Snapshot(fixture.instrument,cursor,nothing,true,false,"initial",false,false,nothing),"")
        startup=Dict("profile"=>profile,"backend"=>"cuda","calibration_stage"=>"interaction","illumination"=>"lamp",
            "phase"=>"initial","failure"=>nothing,"ownership_held"=>false,"sequence"=>0,"acquisition_generation"=>1,
            "cursor_model_ns"=>0,"acquisition_domain_mapping"=>Dict("opaque_domain"=>typemax(UInt64)),"graph_sha256"=>"sealed")
        @test CQ.verify_startup(startup,initial,fixture,"sealed") === nothing
        for key in ("profile","backend","calibration_stage","illumination","graph_sha256")
            changed=copy(startup);changed[key]="another"
            @test_throws ErrorException CQ.verify_startup(changed,initial,fixture,"sealed")
        end
    end
end

@testset "HEART child generation and published hold stay exact" begin
    specification,provenance,plan=selected_fixture_input("copper","heart")
    fixture=CQ.selected_fixture(specification,provenance,plan;mode="collect")
    H=CQ.H
    snapshot=H.HeartSnapshot(1,UInt32(12345),nothing,true,H.Streaming,true,true,"/native/heart-generation-1.json",repeat("b",64))
    @test CQ.verify_heart_snapshot(snapshot,fixture) === nothing
    for changed in (
        H.HeartSnapshot(2,snapshot.child_pid,nothing,true,H.Streaming,true,true,snapshot.report_path,snapshot.report_sha256),
        H.HeartSnapshot(1,nothing,Int32(1),false,H.Streaming,true,true,snapshot.report_path,snapshot.report_sha256),
        H.HeartSnapshot(1,snapshot.child_pid,nothing,true,H.Deferred,true,true,snapshot.report_path,snapshot.report_sha256),
        H.HeartSnapshot(1,snapshot.child_pid,nothing,true,H.Streaming,false,true,snapshot.report_path,snapshot.report_sha256),
        H.HeartSnapshot(1,snapshot.child_pid,nothing,true,H.Streaming,true,false,snapshot.report_path,snapshot.report_sha256),
    )
        @test_throws ErrorException CQ.verify_heart_snapshot(changed,fixture)
    end
    replacement=H.HeartSnapshot(1,UInt32(12346),nothing,true,H.Streaming,true,true,snapshot.report_path,snapshot.report_sha256)
    @test_throws ErrorException CQ.verify_heart_snapshot(replacement,fixture;previous=snapshot)
    hold=Dict{String,Any}("child_pid"=>12345,"generation"=>1,"run_acknowledged"=>true,"endpoints_acknowledged"=>true,
        "endpoint_enable_command"=>"startup CORRECT","endpoint_reply_sha256"=>repeat("c",64),"admitted_frames"=>0,
        "ingress_mode"=>"streaming","ingress_environment"=>"0","snapshot"=>Dict(
            "generation"=>1,"child_pid"=>12345,"alive"=>true,"placement_validated"=>true,"diagnostics_disabled"=>true,
            "report_path"=>snapshot.report_path,"report_sha256"=>snapshot.report_sha256))
    @test CQ.verify_heart_hold(Dict("native_controller_held"=>hold),snapshot,fixture) === hold
    for mutate! in (
        h->(h["child_pid"]=12346),h->(h["generation"]=2),h->(h["generation"]=true),
        h->(h["admitted_frames"]=false),h->(h["endpoints_acknowledged"]=false),
        h->(h["snapshot"]["report_sha256"]=repeat("d",64)),h->(h["snapshot"]["alive"]=false),
    )
        changed=deepcopy(hold);mutate!(changed)
        @test_throws ErrorException CQ.verify_heart_hold(Dict("native_controller_held"=>changed),snapshot,fixture)
    end
    report=Dict("state"=>"paused","error"=>nothing,"sequence"=>0,"source_config_sha256"=>repeat("a",64),
        "native_ingress"=>Dict("mode"=>"streaming","observed_environment"=>"0"))
    query=(client,root;kwargs...)->(snapshot,report)
    actual,saved=CQ.heart_checkpoint(nothing,"unused",fixture;deadline=1.0,check=()->nothing,generation_report=query)
    @test actual === snapshot && saved==report
    changed=deepcopy(report);changed["source_config_sha256"]=repeat("e",64)
    @test_throws ErrorException CQ.heart_checkpoint(nothing,"unused",fixture;deadline=1.0,check=()->nothing,
        generation_report=(args...;kwargs...)->(snapshot,changed))
    observed=(;pid=12345,state="S",parent_pid=1234,group_pid=1234,session_pid=1234,start_ticks=UInt64(88))
    identity=CQ.heart_child_identity(snapshot,1234,Dict("heart"=>Dict("pid"=>1234,"ownership_confirmed"=>true));observe=pid->observed)
    @test !CQ.heart_child_absent(identity;observe=pid->observed)
    @test CQ.heart_child_absent(identity;observe=pid->nothing)
    @test CQ.heart_child_absent(identity;observe=pid->merge(observed,(;start_ticks=UInt64(89))))
    rescheduled=copy(identity);rescheduled["state"]="R"
    @test CQ.same_child_identity(identity,rescheduled)
    rescheduled["start_ticks"]=UInt64(89)
    @test !CQ.same_child_identity(identity,rescheduled)
    @test_throws ErrorException CQ.heart_child_identity(snapshot,1234,
        Dict("heart"=>Dict("pid"=>1234,"ownership_confirmed"=>true));observe=pid->merge(observed,(;group_pid=999)))
end

@testset "Bounded HEART evidence remains tied to published bytes" begin
    mktempdir() do root
        directory=joinpath(root,"native");output=joinpath(root,"retained");mkpath(directory);mkpath(output)
        path=joinpath(directory,"native-evidence.jsonl");write(path,"{\"kind\":\"exposure\"}\n")
        fixture=(;evidence_directory=directory,telemetry_budget=512*1024)
        evidence=Dict("path"=>path,"bytes"=>filesize(path),"records"=>1,"sha256"=>CQ.C.sha256_file(path))
        result=CQ.retain_heart_evidence(Dict("native_evidence"=>evidence),fixture,output)
        @test read(result["retained_path"])==read(path)
        for (key,value) in (("path",joinpath(root,"other")),("bytes",filesize(path)+1),("records",2),("sha256",repeat("0",64)))
            changed=copy(evidence);changed[key]=value
            @test_throws ErrorException CQ.retain_heart_evidence(Dict("native_evidence"=>changed),fixture,output)
        end
    end
end

@testset "Native calibration success requires failure-free owned cleanup" begin
    complete = Dict{String,Any}("success"=>true,"restoration_confirmed"=>true,
        "release_confirmed"=>true,"shutdown_confirmed"=>true,
        "cleanup"=>Dict("status"=>"complete","launcher_exited"=>true,
            "groups"=>Dict("simulator"=>Dict("status"=>"complete"))))
    @test CQ.qualification_exit_code(complete) == 0
    for name in ("success","restoration_confirmed","release_confirmed","shutdown_confirmed")
        bad = deepcopy(complete); bad[name] = false
        @test CQ.qualification_exit_code(bad) == 1
    end
    for name in ("failure","client_cleanup_failure","cleanup_failure")
        bad = deepcopy(complete); bad[name] = "deliberate close failure after effects"
        @test CQ.qualification_exit_code(bad) == 1
    end
    for mutate! in (
        r->(r["cleanup"]["status"]="unresolved"),
        r->(r["cleanup"]["launcher_exited"]=false),
        r->empty!(r["cleanup"]["groups"]),
        r->(r["cleanup"]["groups"]["simulator"]["status"]="unknown"),
    )
        bad = deepcopy(complete); mutate!(bad)
        @test CQ.qualification_exit_code(bad) == 1
    end
    native_heart=deepcopy(complete);native_heart["engine"]="heart"
    @test CQ.qualification_exit_code(native_heart) == 1
    for key in ("heart_child_identity_confirmed","heart_health_confirmed","heart_child_cleanup_confirmed")
        native_heart[key]=true
    end
    @test CQ.qualification_exit_code(native_heart) == 0
    for key in ("heart_child_identity_confirmed","heart_health_confirmed","heart_child_cleanup_confirmed")
        bad=deepcopy(native_heart);bad[key]=false
        @test CQ.qualification_exit_code(bad) == 1
    end
end

@testset "Release completion waits for native report publication" begin
    header = HCQ.ReplyHeader(HCQ.ControllerIdentity(UInt32(1234),UInt64(8),Int64(1)),
        Int64(7),Int64(3),UInt32(1),Int32(0))
    cursor = LCQ.AcquisitionCursor(1,1,69,137_896_000)
    pending = LCQ.Completion(header,LCQ.Connected,
        LCQ.Snapshot(LCQ.Classic,cursor,nothing,true,false,"released",false,true,nothing),"")
    complete = LCQ.Completion(header,LCQ.Connected,
        LCQ.Snapshot(LCQ.Classic,cursor,cursor,false,true,"released",false,true,nothing),"")
    calls = Ref(0)
    status = (c;kwargs...)->begin
        calls[] += 1
        calls[] == 1 ? pending : complete
    end
    reads = Ref(0)
    read_report = (path,source,startup)->begin
        reads[] += 1
        @test source["completed"] === true && source["state"] == "paused"
        Dict("report"=>"verified")
    end
    reply,report = CQ.verified_report(nothing,"unused",Dict();
        deadline=time_ns()/1e9+5,check=()->nothing,status,read_report)
    @test reply === complete
    @test calls[] == 2 && reads[] == 1
    @test report == Dict("report"=>"verified")
end

@testset "Installed native calibration retained evidence" begin
    result,plan,startup = collect_fixture()
    @test CQ.verify_collect(result,plan,startup)["sequence"] == 68
    for mutate! in (
        r->(r["run"]=83),
        r->(r["restoration_confirmed"]=false),
        r->(r["resume_permitted"]=false),
        r->(r["responses"][1]["valid"]=false),
        r->pop!(r["responses"][1]["values"]),
        r->(r["responses"][1]["values"][1]=NaN32),
        r->pop!(r["responses"][1]["exposures"]),
        r->(r["responses"][1]["exposures"][1]["sequence"]=1),
        r->(r["responses"][1]["exposures"][2]["sequence"]=2),
        r->(r["responses"][1]["exposures"][2]["start_model_ns"]=0),
        r->(r["responses"][1]["exposures"][1]["generation"]=2),
        r->(r["responses"][1]["exposures"][1]["domain"]=2),
        r->(r["responses"][1]["exposures"][1]["duration_ns"]=2_000_000),
        r->(r["responses"][1]["exposures"][1]["sequence"]=true),
        r->(r["responses"][1]["exposures"][1]["start_model_ns"]=typemax(UInt64)),
        r->(r["responses"][2]["exposures"][1]["sequence"]=18),
    )
        bad = deepcopy(result); mutate!(bad)
        @test_throws ErrorException CQ.verify_collect(bad,plan,startup)
    end
end

@testset "Failed calibration retains the owner report without masking failure" begin
    mktempdir() do directory
        instance=joinpath(directory,"runtime");output=joinpath(directory,"output")
        mkpath(instance);mkpath(output)
        source=joinpath(instance,"simulator-result.json")
        write(source,"{\"state\":\"failed\"}")
        record=Dict{String,Any}("success"=>false,"failure"=>"primary failure")
        CQ.retain_failure_owner_report!(record,instance,output)
        retained=joinpath(output,"failure-owner-report.json")
        @test read(retained,String) == read(source,String)
        @test record["failure_owner_report_sha256"] == CQ.C.sha256_file(retained)
        @test record["failure"] == "primary failure"
        @test !record["success"]

        rm(source)
        CQ.retain_failure_owner_report!(record,instance,output)
        @test record["failure_owner_report_sha256"] == CQ.C.sha256_file(retained)
        @test !haskey(record,"failure_owner_report_copy_failure")
        @test record["failure"] == "primary failure"
        @test !record["success"]

        write(source,"{\"state\":\"new failure\"}")
        blocked_output=joinpath(directory,"blocked-output")
        write(blocked_output,"not a directory")
        CQ.retain_failure_owner_report!(record,instance,blocked_output)
        @test !haskey(record,"failure_owner_report_sha256")
        @test record["failure_owner_report_copy_failure"] isa String
        @test record["failure"] == "primary failure"
        @test !record["success"]
    end
end

@testset "Frozen Copper small plan retains actual 3600 by two responses" begin
    plan=Dict("version"=>1,"run"=>1,"probes"=>[zeros(Float32,277) for _ in 1:2],"measurements"=>3600,
        "frames_per_probe"=>2,"settling"=>Dict("kind"=>"discard_exposures","frames"=>1))
    startup=Dict("acquisition_domain_mapping"=>Dict("opaque_domain"=>typemax(UInt64)),
        "acquisition_generation"=>typemax(UInt64),"detector_config"=>Dict("exposure_duration_s"=>0.002))
    result=Dict("version"=>1,"run"=>1,"phase"=>"complete","failure"=>nothing,"recovery_failure"=>nothing,
        "restoration_confirmed"=>true,"resume_permitted"=>true,"responses"=>[
            Dict("valid"=>true,"values"=>zeros(Float32,3600),"exposures"=>[
                Dict{String,Any}("domain"=>typemax(UInt64),"generation"=>typemax(UInt64),
                    "sequence"=>(batch-1)*3+index+1,"start_model_ns"=>((batch-1)*3+index)*2_000_000,"duration_ns"=>2_000_000)
                for index in 1:2]) for batch in 1:2])
    @test CQ.verify_collect(result,plan,startup)["sequence"] == 6
    changed=deepcopy(result);pop!(changed["responses"][1]["values"])
    @test_throws ErrorException CQ.verify_collect(changed,plan,startup)
end

@testset "Unsupported Reset retains calibration owner facts" begin
    header = HCQ.ReplyHeader(HCQ.ControllerIdentity(UInt32(1234),UInt64(8),Int64(1)),Int64(7),Int64(2),UInt32(4),Int32(-95))
    cursor = LCQ.AcquisitionCursor(1,1,69,137_896_000)
    snapshot = LCQ.Snapshot(LCQ.Classic,cursor,cursor,false,true,"released",false,true,nothing)
    before = LCQ.Completion(header,LCQ.Connected,snapshot,"")
    rejection = LCQ.Completion(header,LCQ.Connected,snapshot,"calibration reset requires a fresh instance")
    request = (c,op;kwargs...)->(@test op === :reset; rejection)
    status = (c;kwargs...)->before
    proof = CQ.verify_reset_rejection(nothing,before;deadline=1.0,check=()->nothing,request,status)
    @test proof["facts_unchanged"]
    @test proof["result"] == -95
    moved = LCQ.AcquisitionCursor(1,2,0,0)
    changed = LCQ.Completion(header,LCQ.Connected,
        LCQ.Snapshot(LCQ.Classic,moved,moved,false,true,"released",false,true,nothing),"")
    @test_throws ErrorException CQ.verify_reset_rejection(nothing,before;
        deadline=1.0,check=()->nothing,request,status=(c;kwargs...)->changed)
    for after in (
        LCQ.Completion(header,LCQ.Stopped,snapshot,""),
        LCQ.Completion(header,LCQ.Connected,
            LCQ.Snapshot(LCQ.Classic,cursor,nothing,false,true,"released",false,true,nothing),""),
        LCQ.Completion(header,LCQ.Connected,
            LCQ.Snapshot(LCQ.Classic,cursor,moved,false,true,"released",false,true,nothing),""),
    )
        @test_throws ErrorException CQ.verify_reset_rejection(nothing,before;
            deadline=1.0,check=()->nothing,request,status=(c;kwargs...)->after)
    end
end
