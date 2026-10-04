using Test, JSON3, SHA
include("heart_calibration_method.jl")
const Method = HeartCalibrationMethod

function write_json(path, value)
    open(path, "w") do io
        JSON3.write(io, value); write(io, '\n')
    end
end

@testset "native sealed methods use public AOC preparation, chronology and estimation" begin
    mktempdir() do directory
        package = joinpath(directory, "package"); mkdir(package)
        method_directory = joinpath(package, "heart-method"); mkdir(method_directory)
        mkpath(joinpath(package, "hil"))
        cp(joinpath(@__DIR__, "calibration_client.jl"), joinpath(package, "hil/calibration_client.jl"))
        specification = (; run=1, reference=zeros(Float32, 2), amplitudes=fill(0.1f0, 2), measurements=1,
            frames_per_probe=2, settling=(; kind="discard_exposures", frames=1),
            timeouts_ns=(; ownership=1, adoption=1, settling=1, collection=1, restoration=1))
        canonical = Method.CalibrationClient.prepare_plan(specification)
        permutation = collect(4:-1:1)
        chronological = merge(canonical, (; figures=canonical.figures[permutation, :],
            plan=merge(canonical.plan, (; probes=canonical.plan.probes[permutation]))))
        data = Dict("recipe.json"=>(; seeds=(; interaction=531)), "method.json"=>(; version=1, run=1, order="reverse"),
            "prepared-specification.json"=>specification, "canonical-order.json"=>(; chronology_to_canonical=permutation),
            "canonical-plan.json"=>canonical.plan, "interaction-plan.json"=>chronological.plan,
            "base-identity.json"=>(; profile="synthetic", coordinates=2))
        foreach(pair -> write_json(joinpath(method_directory, first(pair)), last(pair)), data)
        files = Dict(name=>Method.digest(joinpath(method_directory, name)) for name in Method.INPUTS)
        identity = (; files, aoc_package_files=Dict("hil/calibration_client.jl"=>Method.digest(joinpath(package, "hil/calibration_client.jl"))), interaction_seed=531)
        write_json(joinpath(method_directory, "identity.json"), identity)
        expected = Method.digest(joinpath(method_directory, "identity.json"))
        selected = Method.prepared_method(method_directory, expected)
        @test selected.permutation == permutation
        @test selected.canonical.figures == canonical.figures
        @test selected.chronological.figures == chronological.figures
        responses = [begin
            value = sum(chronological.figures[row, :] .* Float32[2, 3])
            (; values=[value], valid=true, exposures=[(; domain=1, generation=1, sequence=2(row-1)+index,
                start_model_ns=2(row-1)+index-1, duration_ns=1) for index in 1:2])
        end for row in 1:4]
        result = (; version=1, run=1, phase="complete", restoration_confirmed=true, resume_permitted=true,
            failure=nothing, recovery_failure=nothing, responses)
        result_path = joinpath(directory, "result.json"); write_json(result_path, result)
        output = joinpath(directory, "candidate")
        record = Method.reduce_method(method_directory, expected, result_path, output, "0"^64, "1"^64)
        @test record.shape == (1, 2)
        @test reinterpret(Float32, read(joinpath(output, "candidate-response.f32le"))) ≈ Float32[2, 3]
        @test record.status == "complete-unaccepted-candidate"
        @test record.chronology_to_canonical == permutation
        @test_throws ArgumentError Method.reduce_method(method_directory, expected, result_path, output, "0"^64, "1"^64)
        write_json(joinpath(method_directory, "method.json"), (; version=1, run=1, order="forward"))
        @test_throws ArgumentError Method.prepared_method(method_directory, expected)
    end
end
