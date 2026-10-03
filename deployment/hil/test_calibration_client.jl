using Test
using JSON3
using AdaptiveOpticsCalibration

include("calibration_client.jl")
using .CalibrationClient

function complete_result(prepared, observations)
    responses = map(enumerate(eachrow(observations))) do (index, row)
        (; values=collect(row), valid=true,
            exposures=[(; domain=1, generation=1, sequence=index, start_model_ns=index * 100,
                duration_ns=100)])
    end
    return (; version=1, run=prepared.plan.run, phase="complete",
        restoration_confirmed=true, resume_permitted=true, failure=nothing,
        recovery_failure=nothing, responses)
end

@testset "operational calibration client" begin
    specification = (; run=7, reference=Float32[0.1, -0.2],
        amplitudes=Float32[0.25, 0.5], measurements=3, frames_per_probe=1,
        settling=(; kind="immediate"), timeouts_ns=(; ownership=1, adoption=1,
            settling=1, collection=1, restoration=1))
    prepared = prepare_plan(specification)
    @test prepared.figures == Float32[0.35 -0.2;  -0.15 -0.2; 0.1 0.3; 0.1 -0.7]
    @test prepared.plan.probes == [collect(row) for row in eachrow(prepared.figures)]

    expected = Float32[2 -1; 0.5 3; -4 1.25]
    baseline = Float32[11, -2, 0.75]
    observations = Matrix{Float32}(undef, 4, 3)
    for output in 1:3
        observations[1, output] = baseline[output] + prepared.amplitudes[1] * expected[output, 1]
        observations[2, output] = baseline[output] - prepared.amplitudes[1] * expected[output, 1]
        observations[3, output] = baseline[output] + prepared.amplitudes[2] * expected[output, 2]
        observations[4, output] = baseline[output] - prepared.amplitudes[2] * expected[output, 2]
    end
    result = complete_result(prepared, observations)
    measured = validate_result(result, prepared)
    @test measured == observations
    @test estimate_interaction_matrix(prepared, measured) ≈ expected
    @test_throws ArgumentError estimate_interaction_matrix(prepared, fill(1e100, 4, 3))
    @test_throws ArgumentError estimate_interaction_matrix(prepared, fill(1e-50, 4, 3))
    overflow_responses = Float32[1f38 1f38 1f38; -1f38 -1f38 -1f38;
        0 0 0; 0 0 0]
    @test_throws ArgumentError estimate_interaction_matrix(prepared, overflow_responses)
    @test_throws ArgumentError prepare_plan(merge(specification, (; amplitudes=Float64[1e-50, 0.5])))
    @test_throws ArgumentError prepare_plan(merge(specification, (; amplitudes=Float64[1e100, 0.5])))
    @test_throws ArgumentError prepare_plan(merge(specification, (; reference=Float32[1f20, 0],
        amplitudes=Float32[1, 0.5])))

    duplicate_exposure = (; domain=1, generation=1, sequence=1,
        start_model_ns=100, duration_ns=100)
    duplicate_batch = merge(result.responses[2], (; exposures=[duplicate_exposure]))
    duplicate_result = merge(result, (; responses=vcat(result.responses[1:1], [duplicate_batch], result.responses[3:end])))
    for bad in (
        merge(result, (; phase="aborted")),
        merge(result, (; restoration_confirmed=false)),
        merge(result, (; resume_permitted=false)),
        merge(result, (; failure="ProbeClipped")),
        merge(result, (; responses=result.responses[1:end-1])),
        merge(result, (; responses=vcat([merge(result.responses[1], (; valid=false))], result.responses[2:end]))),
        merge(result, (; responses=vcat([merge(result.responses[1], (; values=Float32[1, 2]))], result.responses[2:end]))),
        merge(result, (; responses=vcat([merge(result.responses[1], (; values=Float32[1, NaN, 3]))], result.responses[2:end]))),
        merge(result, (; responses=vcat([merge(result.responses[1], (; values=[1e-50, 2, 3]))], result.responses[2:end]))),
        merge(result, (; responses=vcat([merge(result.responses[1], (; values=[1e100, 2, 3]))], result.responses[2:end]))),
        duplicate_result,
        merge(result, (; responses=vcat(result.responses[1:1],
            [merge(result.responses[2], (; exposures=[(; domain=1, generation=1, sequence=2,
                start_model_ns=150, duration_ns=100)]))], result.responses[3:end]))),
        merge(result, (; responses=vcat(result.responses[1:1],
            [merge(result.responses[2], (; exposures=[(; domain=1, generation=1, sequence=2,
                start_model_ns=typemax(UInt64), duration_ns=UInt64(1))]))], result.responses[3:end]))),
    )
        @test_throws ArgumentError validate_result(bad, prepared)
    end
    @test_throws DimensionMismatch estimate_interaction_matrix(prepared, observations[1:3, :])
end
