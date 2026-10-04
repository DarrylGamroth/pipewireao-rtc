using Test, PipeWireAODeployment
const X=PipeWireAODeployment.HeartClassicTransfer
const C=PipeWireAODeployment.Common
@testset "Classic admission requires retained helpers and its actual decode closure" begin
    files=Dict("hil/"*name=>hash for (name,hash) in X.ORIGINAL_HELPERS)
    files["hil/heart_classic_calibration_evidence.jl"]=X.CLASSIC_EVIDENCE_SHA
    @test !haskey(files,"hil/heart_calibration_coordinates.jl")
    @test X.validate_helpers(files)===nothing
    for name in keys(files)
        absent=copy(files);delete!(absent,name)
        @test_throws ArgumentError X.validate_helpers(absent)
        changed=copy(files);changed[name]="changed"
        @test_throws ArgumentError X.validate_helpers(changed)
    end
end
@testset "Classic transfer admission precedes helper execution" begin
    mktempdir() do root
        package=joinpath(root,"package");evidence=joinpath(root,"evidence")
        mkpath(joinpath(package,"hil"));mkpath(evidence)
        marker=joinpath(root,"unsealed-executed")
        write(joinpath(package,"hil/heart_classic_calibration_evidence.jl"),"write("*repr(marker)*","*repr("unsealed")*")\n")
        output=joinpath(root,"score.json");lifecycle=joinpath(root,"lifecycle.json")
        @test_throws ArgumentError X.score_capture(package,evidence,lifecycle;output,forward_model="missing",accepted_preparation="missing")
        @test !ispath(marker)&&!ispath(output)&&!ispath(output*".stdout")
        for destination in (joinpath(package,"new-score.json"),joinpath(evidence,"new-score.json"))
            @test_throws ArgumentError X.score_capture(package,evidence,lifecycle;output=destination,forward_model="missing",accepted_preparation="missing")
        end
        C.write_json(lifecycle,Dict("capture_confirmed"=>false,"shutdown_confirmed"=>true))
        @test_throws ArgumentError X.admit(package,evidence,lifecycle)
        @test !ispath(marker)
        report=joinpath(root,"report.json");C.write_json(report,Dict("passed"=>true,"admission_passed"=>true))
        @test_throws ArgumentError X.replay_admission(package,evidence,lifecycle,report;reported_sha256="changed",forward_model="missing",accepted_preparation="missing")
        @test_throws ArgumentError X.replay_admission(package,evidence,lifecycle,report;reported_sha256=C.sha256_file(report),forward_model="missing",accepted_preparation="missing")
        @test !ispath(marker)&&!ispath(output)
        write(output,"occupied")
        @test_throws ArgumentError X.score_capture(package,evidence,lifecycle;output,forward_model="missing",accepted_preparation="missing")
    end
end
@testset "maintained Classic cold worker is contained and recorded" begin
    sources=X.source_inputs()
    worker=joinpath(PipeWireAODeployment.resource_root(),"hil",X.WORKER_NAME)
    @test sources[worker]==C.sha256_file(worker)==X.WORKER_SHA
    @test sources[joinpath(PipeWireAODeployment.package_root(),"src/heart_classic_transfer.jl")]==X.LOADED_SOURCE_SHA
    @test !occursin("/.cache/",read(worker,String))
    @test occursin("repeat(active;inner=2)",read(worker,String))
end
