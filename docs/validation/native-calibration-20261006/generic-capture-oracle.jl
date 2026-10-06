using Test
include(joinpath(@__DIR__,"../../../deployment/qualify_calibration_native.jl"))
const CQ = NativeCalibrationQualification
mutable struct CaptureEndpoint
    serial::UInt64
    records::Vector{String}
end
function request_capture(endpoint,action,expected;kwargs...)
    endpoint.serial += 1
    push!(endpoint.records,expected)
    current = Dict("domain"=>1,"generation"=>1,"sequence"=>0,"model_ns"=>0)
    expected in ("held","settled") && return Dict("cursor"=>current)
    expected == "adopted" && return Dict("cursor"=>current,"clipped"=>false,"figure"=>action.figure)
    expected == "restored" && return Dict("clipped"=>false,"figure"=>action.figure)
    Dict{String,Any}()
end
@testset "Capture verification follows actual selected profile and stage" begin
    plan=Dict("run"=>82,"reference"=>zeros(Float32,277),"probes"=>[zeros(Float32,277)],
        "settling"=>Dict("kind"=>"discard_exposures","frames"=>1))
    for (profile,stage) in (("classic","interaction"),("copper","nativepilot"))
        endpoint=CaptureEndpoint(0,String[])
        startup=Dict("profile"=>profile,"calibration_stage"=>stage)
        verify=(root,completion;kwargs...)->Dict("profile"=>kwargs[:profile],"stage"=>kwargs[:stage])
        result=CQ.capture!(endpoint,plan,startup,"unused","unused";deadline=1.0,check=()->nothing,
            request_action=request_capture,copy_captured=(args...)->nothing,verify_capture=verify)
        @test result["manifest"]["profile"] == profile
        @test result["manifest"]["stage"] == stage
        @test endpoint.records == ["held","adopted","settled","captured","restored","released"]
    end
end
