# Cold validation of supplied original frozen training/held-out directories.
# Pass method directories as arguments. This checks retained public results and
# plan reconstruction; it does not acquire or qualify native measurements.
using Test, JSON3, SHA
include("calibration_client.jl")
digest(path) = bytes2hex(open(sha256,path))

@testset "original frozen public plans, chronology and means" begin
    isempty(ARGS) && throw(ArgumentError("supply frozen method directories"))
    for directory in ARGS
        identity = JSON3.read(read(joinpath(directory,"prepared-identity.json"),String))
        for name in ("recipe.json","method.json","prepared-specification.json","canonical-order.json",
            "canonical-plan.json","interaction-plan.json","base-identity.json")
            @test digest(joinpath(directory,name)) == identity.files[name]
        end
        recipe = JSON3.read(read(joinpath(directory,"recipe.json"),String))
        method = JSON3.read(read(joinpath(directory,"method.json"),String))
        canonical = CalibrationClient.prepare_plan(JSON3.read(read(joinpath(directory,"prepared-specification.json"),String)))
        @test JSON3.write(canonical.plan) * "\n" == read(joinpath(directory,"canonical-plan.json"),String)
        count = size(canonical.figures,1)
        permutation = method.order == "forward" ? collect(1:count) : method.order == "reverse" ? collect(count:-1:1) : error("unknown chronology")
        @test collect(JSON3.read(read(joinpath(directory,"canonical-order.json"),String)).chronology_to_canonical) == permutation
        chronological = merge(canonical,(; figures=canonical.figures[permutation,:],
            plan=merge(canonical.plan,(; probes=canonical.plan.probes[permutation]))))
        @test JSON3.write(chronological.plan) * "\n" == read(joinpath(directory,"interaction-plan.json"),String)
        @test chronological.plan.frames_per_probe == recipe.frames_per_probe
        @test chronological.plan.settling == recipe.settling
        result_path = joinpath(directory,"evidence/rtc-calibrate.json")
        values = CalibrationClient.validate_result(read(result_path,String),chronological)
        @test size(values) == (count,3600)
        @test all(isfinite,values)
        result = JSON3.read(read(result_path,String))
        @test [receipt.sequence for response in result.responses for receipt in response.exposures] ==
            [UInt64((batch-1)*(recipe.frames_per_probe+recipe.settling.frames)+recipe.settling.frames+sample)
                for batch in 1:count for sample in 1:recipe.frames_per_probe]
    end
end
