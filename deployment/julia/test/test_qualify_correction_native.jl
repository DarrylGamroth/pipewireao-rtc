using Test
include(joinpath(@__DIR__,"../../qualify_correction_native.jl"))
const RQ = NativeCorrectionQualification
const RL, RH = RQ.L, RQ.H
const RE = RQ.Cal.PipeWireAODeployment.NativeControlCodec

function correction_fixture(profile)
    budget = profile == "classic" ? 128*1024*1024 : 16*1024*1024
    ingress = profile == "classic" ? "streaming" : "deferred"
    hash = repeat("a",64)
    contract = Dict{String,Any}("version"=>1,"profile"=>profile,"frames"=>256,
        "native_ingress_mode"=>ingress,"native_telemetry_max_bytes"=>budget,"native_config_sha256"=>hash)
    source = Dict("role"=>"simulator","instrument"=>profile,
        "control-protocol"=>"pipewireao.rtc.correction-lifecycle/1","control-node"=>"source.correction",
        "argv"=>["julia","--profile",profile,"--frames","256","--backend","cuda",
            "--heart-active-contract","@PACKAGE@/heart-active-contract.json","--correction-diagnostics","true",
            "--heart-native-ingress-mode",ingress,"--heart-probe-directory","/private/native-correction",
            "--heart-telemetry-max-bytes",string(budget)])
    specification = Dict("source-owner"=>"simulator","owners"=>[source])
    provenance = Dict{String,Any}("profile"=>profile,"engine"=>"heart",
        "heart_correction"=>Dict("active_contract_sha256"=>hash))
    return specification,provenance,contract,hash
end

function correction_reply(fixture; window=1,generation=window,phase="restored",sequence=256,
        model_ns=sequence == 0 ? 0 : (sequence-1)*2_000_000+1_896_000,
        lifecycle=RL.Connected,held=phase != "restored",restored=phase == "restored",
        running=phase == "correcting",completed=phase == "restored",published=true,domain=typemax(UInt64),result=0)
    c = RL.AcquisitionCursor(domain,generation,sequence,model_ns)
    snapshot = RL.Snapshot(fixture.instrument,c,published ? c : nothing,running,completed,phase,held,restored,UInt64(window))
    header = RE.ReplyHeader(RE.ControllerIdentity(UInt32(99),UInt64(100),Int64(2)),Int64(7),Int64(1),UInt32(1),Int32(result))
    return RL.Completion(header,lifecycle,snapshot,"")
end

function correction_heart(fixture,window=1; child_pid=1000+window,alive=true,generation=window)
    return RH.HeartSnapshot(Int64(generation),UInt32(child_pid),nothing,alive,
        fixture.ingress == "streaming" ? RH.Streaming : RH.Deferred,true,true,"/private/generation-$window.json",repeat("b",64))
end

@testset "Native correction fixture keeps sealed 256-frame profile" begin
    for profile in ("classic","copper")
        spec,provenance,contract,hash = correction_fixture(profile)
        f = RQ.selected_fixture(spec,provenance,contract,hash)
        @test f.profile == profile && f.instrument === (profile == "classic" ? RL.Classic : RL.Copper)
        @test f.telemetry_budget == (profile == "classic" ? 128 : 16)*1024*1024
        for mutate! in (c->(c["frames"]=64),c->(c["version"]=true),c->(c["profile"]="other"),
            c->(c["native_ingress_mode"]="wrong"),c->(c["native_telemetry_max_bytes"]=1))
            bad = deepcopy(contract);mutate!(bad)
            @test_throws ErrorException RQ.selected_fixture(spec,provenance,bad,hash)
        end
        bad=deepcopy(spec);bad["owners"][1]["control-protocol"]="pipewireao.rtc.calibration-lifecycle/1"
        @test_throws ErrorException RQ.selected_fixture(bad,provenance,contract,hash)
        bad=deepcopy(provenance);bad["heart_correction"]["active_contract_sha256"]=repeat("c",64)
        @test_throws ErrorException RQ.selected_fixture(spec,bad,contract,hash)
    end
end

@testset "Native correction lifecycle gates precede report reads" begin
    spec,provenance,contract,hash=correction_fixture("classic")
    f=RQ.selected_fixture(spec,provenance,contract,hash)
    held=correction_reply(f;phase="initial",sequence=0,completed=false)
    @test RQ.verify_held(held,f,1) === held.snapshot
    active=correction_reply(f;phase="correcting",sequence=20)
    @test RQ.verify_first_window(active,f) === nothing
    completed=correction_reply(f)
    @test RQ.verify_first_window(completed,f) === nothing
    @test_throws ErrorException RQ.verify_first_window(held,f)
    @test !RQ.verify_restored(active,f,1)
    @test RQ.verify_restored(completed,f,1)
    @test !RQ.verify_restored(correction_reply(f;published=false),f,1)
    reads=Ref(0);calls=Ref(0)
    status=(c;kwargs...)->begin
        calls[] += 1
        calls[] == 1 ? correction_reply(f;published=false) : completed
    end
    report=Dict("native"=>true)
    read_report=path->(reads[]+=1;report)
    reply,result=RQ.wait_window(nothing,f,nothing,1,"unused";deadline=RQ.Native.monotonic()+5,
        check=()->nothing,status,read_report,verify=(args...)->report)
    @test reply === completed && result === report
    @test calls[] == 2 && reads[] == 2
    for bad in (correction_reply(f;lifecycle=RL.Stopped),correction_reply(f;window=2),
        correction_reply(f;phase="fault",completed=false),correction_reply(f;result=-5))
        reads[]=0
        @test_throws ErrorException RQ.wait_window(nothing,f,nothing,1,"unused";
            deadline=RQ.Native.monotonic()+5,check=()->nothing,status=(c;kwargs...)->bad,
            read_report,verify=(args...)->report)
        @test reads[] == 0
    end
    second=correction_reply(f;window=2,phase="initial",sequence=0,completed=false)
    @test RQ.verify_held(second,f,2;previous=completed.snapshot) === second.snapshot
    @test_throws ErrorException RQ.verify_held(correction_reply(f;window=2,generation=1,phase="initial",sequence=0,completed=false),
        f,2;previous=completed.snapshot)
end

function correction_report(fixture,reply,heart,root,window;mutate_commands! = commands->nothing)
    directory=joinpath(root,"window-$window");mkpath(directory)
    commands=[Dict{String,Any}("kind"=>"active_command","sequence"=>i,"relay_sequence"=>258*(window-1)+i+1,
        "acquisition"=>Dict("domain"=>reply.snapshot.cursor.domain,"generation"=>reply.snapshot.cursor.generation,
            "sequence"=>i,"model_ns"=>(i-1)*2_000_000+1_896_000)) for i in 1:256]
    mutate_commands!(commands)
    records=copy(commands)
    if window == 2
        pushfirst!(records,Dict("kind"=>"reset","old_generation"=>1,"old_child_absent"=>true,
            "new_native_hold"=>Dict("generation"=>2,"child_pid"=>heart.child_pid),
            "pending_public_resume"=>true,"acquisition_generation"=>reply.snapshot.cursor.generation,
            "lifetime_probe_token_preserved"=>258))
    end
    journal=joinpath(directory,"native-evidence.jsonl")
    open(journal,"w") do io
        for record in records
            println(io,RQ.C.JSON3.write(record))
        end
    end
    return Dict{String,Any}("version"=>1,"profile"=>fixture.profile,"engine"=>"heart","backend"=>"cuda",
        "native_window"=>window,"active_contract_sha256"=>fixture.contract_sha256,"state"=>"paused",
        "failure"=>nothing,"completed"=>true,"completed_frames"=>256,"completed_commands"=>256,
        "requested_frames"=>256,"sequence"=>256,"native_recording_retained"=>true,"native_active"=>nothing,
        "native_controller_held"=>nothing,"native_evidence_directory"=>directory,
        "native_journal_bytes"=>filesize(journal),"native_journal_prefix_sha256"=>RQ.C.sha256_file(journal),
        "model_timestamps_ns"=>collect(0:255).*2_000_000,"exposure_ns"=>1_896_000,
        "acquisition_generation"=>0,"completed_correct_proof"=>Dict("child_pid"=>heart.child_pid,
            "generation"=>window,"source_config_sha256"=>fixture.native_config_sha256,"ingress_mode"=>fixture.ingress,
            "ingress_environment"=>fixture.ingress == "streaming" ? "0" : "1"))
end

@testset "Retained native correction journal binds full-width cursor and safe release" begin
    for profile in ("classic","copper")
        spec,provenance,contract,hash=correction_fixture(profile)
        f=RQ.selected_fixture(spec,provenance,contract,hash)
        mktempdir() do root
            fixture=merge(f,(;evidence_directory=root))
            for window in 1:2
                reply=correction_reply(fixture;window,generation=window == 1 ? typemax(UInt64) : UInt64(2))
                heart=correction_heart(fixture,window)
                report=correction_report(fixture,reply,heart,root,window)
                @test RQ.verify_report(report,reply,fixture,heart,window) === report
                @test report["acquisition_generation"] == 0 # Historical field is not authority.
                for mutate! in (r->(r["failure"]="failed"),r->(r["native_recording_retained"]=false),
                    r->(r["native_controller_held"]=Dict()),r->(r["completed_correct_proof"]["child_pid"]=9),
                    r->(r["completed_correct_proof"]["generation"]=3),r->(r["native_window"]=3),
                    r->(r["active_contract_sha256"]=repeat("c",64)),r->(r["native_evidence_directory"]=root),
                    r->(r["native_journal_prefix_sha256"]=repeat("d",64)),r->(r["model_timestamps_ns"][1]=1))
                    bad=deepcopy(report);mutate!(bad)
                    @test_throws ErrorException RQ.verify_report(bad,reply,fixture,heart,window)
                end
                for mutate! in (c->(c[end]["acquisition"]["generation"]+=1),c->(c[end]["acquisition"]["domain"]-=1),
                    c->(c[end]["acquisition"]["sequence"]-=1),c->(c[end]["acquisition"]["model_ns"]+=1),c->pop!(c))
                    bad=correction_report(fixture,reply,heart,root,window;mutate_commands! = mutate!)
                    @test_throws ErrorException RQ.verify_report(bad,reply,fixture,heart,window)
                end
            end
        end
    end
end

@testset "Correction reset and unchanged scientific acceptance remain required" begin
    spec,provenance,contract,hash=correction_fixture("copper");f=RQ.selected_fixture(spec,provenance,contract,hash)
    first=correction_reply(f);second=correction_reply(f;window=2)
    old=Dict("pid"=>1001);new=Dict("pid"=>1002)
    @test RQ.verify_reset(first,second,old,new;absent=identity->true) === nothing
    @test_throws ErrorException RQ.verify_reset(first,second,old,new;absent=identity->false)
    @test_throws ErrorException RQ.verify_reset(first,second,old,old;absent=identity->true)
    report=Dict("frame"=>Dict{String,Any}("sha256"=>"frame"),"command"=>Dict{String,Any}("sha256"=>"command"),
        "correction_truth"=>Dict{String,Any}("direct"=>true))
    @test all(values(RQ.verify_reproducible(report,deepcopy(report))))
    for field in ("frame","command","correction_truth")
        bad=deepcopy(report);bad[field][Base.first(keys(bad[field]))]="changed"
        @test_throws ErrorException RQ.verify_reproducible(report,bad)
    end
    analysis=Dict{String,Any}("verified"=>true,"failure"=>nothing,"engine"=>"heart","native_window"=>1,
        "native_active_contract_sha256"=>f.contract_sha256,"windows"=>[
            Dict{String,Any}("first"=>17,"last"=>128,"complete"=>true,"residual_to_atmosphere_variance_ratio"=>0.5),
            Dict{String,Any}("first"=>129,"last"=>256,"complete"=>true,"residual_to_atmosphere_variance_ratio"=>0.6)])
    @test RQ.verify_analysis(analysis,f,1) === nothing
    for value in (1.0,1.1,NaN,Inf,true,nothing)
        bad=deepcopy(analysis);bad["windows"][2]["residual_to_atmosphere_variance_ratio"]=value
        @test_throws ErrorException RQ.verify_analysis(bad,f,1)
    end
    bad=deepcopy(analysis);bad["windows"][1]["first"]=1
    @test_throws ErrorException RQ.verify_analysis(bad,f,1)
    bad=deepcopy(analysis);bad["verified"]=false
    @test_throws ErrorException RQ.verify_analysis(bad,f,1)
end

@testset "Fresh HEART correction checkpoints distinguish deliberate generation replacement" begin
    spec,provenance,contract,hash=correction_fixture("copper");f=RQ.selected_fixture(spec,provenance,contract,hash)
    for window in 1:2
        current=correction_heart(f,window)
        saved=Dict("state"=>"paused","error"=>nothing,"sequence"=>0,"source_config_sha256"=>f.native_config_sha256,
            "native_ingress"=>Dict("mode"=>"deferred","observed_environment"=>"1"))
        snapshot,report=RQ.heart_checkpoint(nothing,"unused",f,window;deadline=1.0,check=()->nothing,
            generation_report=(args...;kwargs...)->(current,saved))
        @test snapshot === current && report == saved
        @test_throws ErrorException RQ.heart_checkpoint(nothing,"unused",f,window;deadline=1.0,check=()->nothing,
            generation_report=(args...;kwargs...)->(correction_heart(f,window;generation=window+1),saved))
        @test_throws ErrorException RQ.heart_checkpoint(nothing,"unused",f,window;deadline=1.0,check=()->nothing,
            generation_report=(args...;kwargs...)->(correction_heart(f,window;alive=false),saved))
        bad=deepcopy(saved);bad["source_config_sha256"]=repeat("c",64)
        @test_throws ErrorException RQ.heart_checkpoint(nothing,"unused",f,window;deadline=1.0,check=()->nothing,
            generation_report=(args...;kwargs...)->(current,bad))
    end
end

@testset "Correction success remains false after missing effects or cleanup" begin
    gates=("batches_confirmed","reset_confirmed","reset_reproducible","replays_confirmed",
        "restoration_confirmed","release_confirmed","shutdown_confirmed","heart_child_identity_confirmed",
        "heart_health_confirmed","heart_child_cleanup_confirmed")
    good=Dict{String,Any}(key=>true for key in gates)
    merge!(good,Dict("success"=>true,"engine"=>"heart","cleanup"=>Dict("status"=>"complete","launcher_exited"=>true,
        "groups"=>Dict("heart"=>Dict("status"=>"complete")))))
    @test RQ.qualification_exit_code(good) == 0
    for key in gates
        bad=deepcopy(good);bad[key]=false
        @test RQ.qualification_exit_code(bad) == 1
    end
    for key in ("failure","client_cleanup_failure","cleanup_failure","replay_failure")
        bad=deepcopy(good);bad[key]="failed"
        @test RQ.qualification_exit_code(bad) == 1
    end
end

@testset "Correction report retention preserves exact published bytes" begin
    mktempdir() do directory
        root=joinpath(directory,"native");mkpath(joinpath(root,"window-1"))
        source=joinpath(root,"window-1","owner-report.json")
        text="{\"completed\": true, \"identity\": 18446744073709551615}\n"
        write(source,text)
        report=RQ.C.parse_json(text);fixture=(;evidence_directory=root)
        target=joinpath(directory,"window-1.json")
        proof=RQ.retain_report(fixture,1,target,report)
        @test read(target,String) == text
        @test proof["sha256"] == RQ.C.sha256_file(source) == RQ.C.sha256_file(target)
        @test_throws ErrorException RQ.retain_report(fixture,1,target,report)
        report["completed"]=false
        @test_throws ErrorException RQ.retain_report(fixture,1,joinpath(directory,"changed.json"),report)
        rm(source);symlink(target,source)
        @test_throws ErrorException RQ.retain_report(fixture,1,joinpath(directory,"linked.json"),report)
    end
end
