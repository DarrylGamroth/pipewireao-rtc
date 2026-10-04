using Test, PipeWireAODeployment

@testset "Explicit bounded owner preparation timeout" begin
    D=PipeWireAODeployment.Deployment
    A=PipeWireAODeployment.CalibrationCampaign
    M=PipeWireAODeployment.CalibrationMethod
    default=D._options(["run","--deployment","fixture"])
    @test default.owner_preparation_timeout_seconds==90
    selected=D._options(["run","--deployment","fixture",
        "--owner-preparation-timeout-seconds","900"])
    @test selected.owner_preparation_timeout_seconds==900
    @test D.owner_preparation_timeout(3600)==3600
    for value in (nothing,0,-1,3601,Inf,NaN,true,1.5,"900")
        @test_throws D.DeploymentError D.owner_preparation_timeout(value)
    end
    for value in ("0","-1","3601","NaN","Inf","1.5","bad")
        @test_throws D.DeploymentError D._options(["run","--deployment","fixture",
            "--owner-preparation-timeout-seconds",value])
    end
    @test_throws D.DeploymentError D._options(["preflight","--deployment","fixture",
        "--owner-preparation-timeout-seconds","900"])
    @test_throws D.DeploymentError D._options(["run","--deployment","fixture",
        "--owner-preparation-timeout-seconds","900","--owner-preparation-timeout-seconds","900"])
    command=A.stage_command("/package","/runtime")
    index=findfirst(==("--owner-preparation-timeout-seconds"),command)
    @test command[index+1]=="90"
    command=A.stage_command("/package","/runtime";owner_preparation_timeout_seconds=900)
    @test command[index+1]=="900"
    for value in (0,-1,3601,Inf,NaN,true,1.5,"900")
        @test_throws ArgumentError A.stage_command("/package","/runtime";owner_preparation_timeout_seconds=value)
    end
    recipe=Dict("stage_timeout_seconds"=>3600)
    @test M.preparation_timeout((;),recipe)==90
    @test M.preparation_timeout((;owner_preparation_timeout_seconds="900"),recipe)==900
    @test M.preparation_timeout((;owner_preparation_timeout_seconds=900),recipe)==900
    for value in ("0","-1","3601","NaN","Inf","1.5","bad",false,1.5)
        @test_throws ArgumentError M.preparation_timeout((;owner_preparation_timeout_seconds=value),recipe)
    end
    @test_throws ArgumentError M.preparation_timeout((;owner_preparation_timeout_seconds="301"),
        Dict("stage_timeout_seconds"=>300))
end
