# Optional scientific dependency selector; does not prepare an optical plant.
using Test, PipeWireAORTC, FilterGraphAlgorithms
const K = PipeWireAORTC.InstrumentCalibration
const FGA = FilterGraphAlgorithms

@testset "prepared temporal section executes and resets in FGA" begin
    for T in (Float32,Float64)
        coefficients = K.lowpass_coefficients(T;cutoff_frequency_hz=25,sample_rate_hz=1000)
        plan = FGA.BiquadCascadePlan(reshape(coefficients,5,1,1),2)
        workspace = FGA.BiquadCascadeWorkspace(plan)
        output = zeros(T,2)
        @test all(iszero,FGA.biquad_cascade_state(workspace))
        @test FGA.process!(output,workspace,plan,zeros(T,2)) === output
        @test all(iszero,output)
        FGA.commit!(workspace)
        demand = T[1,-0.5]
        for _ in 1:256
            @test FGA.process!(output,workspace,plan,demand) === output
            FGA.commit!(workspace)
            # Command complement: the woofer receives the unallocated demand.
            woofer = demand-output
            @test output+woofer ≈ demand rtol=4eps(T)
        end
        @test output ≈ demand rtol=8eps(T)
        @test any(!iszero,FGA.biquad_cascade_state(workspace))
        FGA.reset!(workspace)
        @test all(iszero,FGA.biquad_cascade_state(workspace))
        @test FGA.process!(output,workspace,plan,zeros(T,2)) === output
        @test all(iszero,output)
        @test FGA.process!(output,workspace,plan,demand) === output
        @test output ≈ coefficients[1].*demand rtol=eps(T)
    end
end
