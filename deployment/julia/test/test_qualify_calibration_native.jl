using Test
include(joinpath(@__DIR__,"../../qualify_calibration_native.jl"))
const CQ = NativeCalibrationQualification
const LCQ = CQ.L
const HCQ = CQ.PipeWireAODeployment.NativeControlCodec

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
