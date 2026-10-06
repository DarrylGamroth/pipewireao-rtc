using Test
include(joinpath(@__DIR__,"../../../deployment/qualify_calibration_native.jl"))
const CQ=NativeCalibrationQualification
@testset "Installed consumer launches sealed SDK rather than source tools" begin
    command=if get(ENV,"INSTALLED_CONSUMER_BEFORE","false") == "true"
        CQ.Campaign.stage_command("/sealed/package","/fresh/runtime";owner_preparation_timeout_seconds=900)
    else
        CQ.installed_command("/sealed/package","/fresh/runtime";owner_preparation_timeout_seconds=900)
    end
    println("argv=",CQ.C.JSON3.write(command))
    @test command[3:4] == ["--project=/sealed/package/julia","/sealed/package/julia/deploy_cli.jl"]
    @test command[end-1:end] == ["--owner-preparation-timeout-seconds","900"]
end
