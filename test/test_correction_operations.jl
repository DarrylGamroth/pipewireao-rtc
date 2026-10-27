# Optional CPU scientific selector; no PipeWire core, instrument or GPU.
using Test, FilterGraphAlgorithms
const FGA = FilterGraphAlgorithms

@testset "Coupled correction hold, resume and reset semantics" begin
    controller = prepare_algorithm(ClosedLoopIntegratorF32,
        ClosedLoopIntegratorF32Configuration(state_length=1))
    controller.plan = FGA.prepare_properties(controller.plan, (
        PropertyAssignment(FGA.CLOSED_LOOP_CORRECTION_GAIN_PROPERTY, 0.25f0),
        PropertyAssignment(FGA.CLOSED_LOOP_CORRECTION_POLE_PROPERTY, 0.8f0),
        PropertyAssignment(FGA.CLOSED_LOOP_CORRECTION_ANTI_WINDUP_GAIN_PROPERTY, 0.5f0)))
    correction, state = zeros(Float32, 1), zeros(Float32, 1)
    @test FGA.process!(correction, state, controller, Float32[4], Float32[NaN]) === nothing
    @test correction == Float32[1]
    @test FGA.process!(correction, state, controller, Float32[0.8], Float32[0]) === nothing
    @test correction == Float32[1]
    @test any(!iszero, state)
    held_state = copy(state)
    controller.plan = FGA.prepare_properties(controller.plan,
        (PropertyAssignment(FGA.CLOSED_LOOP_CORRECTION_CLOSED_PROPERTY, false),))
    for (residual, feedback) in ((100f0, 0.1f0), (-200f0, -0.2f0), (3f0, 0.5f0))
        @test FGA.process!(correction, state, controller, [residual], [feedback]) === nothing
        @test correction == Float32[1]
        @test state == held_state
    end
    @test FGA.process!(correction, state, controller, Float32[NaN], Float32[0]) ===
        ClosedLoopCorrectionNonFiniteInput
    @test FGA.process!(correction, state, controller, Float32[0], Float32[NaN]) ===
        ClosedLoopCorrectionNonFiniteFeedback
    @test correction == Float32[1] && state == held_state
    controller.plan = FGA.prepare_properties(controller.plan,
        (PropertyAssignment(FGA.CLOSED_LOOP_CORRECTION_CLOSED_PROPERTY, true),))
    @test FGA.process!(correction, state, controller, Float32[2], Float32[0.5]) === nothing
    @test correction ≈ Float32[0.8 * (1 - 0.5 * 0.5) + 0.25 * 2]
    before_reset = copy(correction)
    FGA.reset!(controller)
    @test correction == before_reset # reset itself does not publish an output
    @test controller.plan.closed && controller.plan.gain == 0.25f0
    @test FGA.closed_loop_correction_last_output(controller.workspace) === nothing
    @test FGA.process!(correction, state, controller, Float32[2], Float32[NaN]) === nothing
    @test correction == Float32[0.5] # first sample has no preceding feedback
end

@testset "Held correction does not freeze downstream slew" begin
    stage = CorrectorStagePlan(ones(Float32, 1, 1), ones(Float32, 1, 1);
        lower_limits=Float32[-2], upper_limits=Float32[2], slew_limits=Float32[0.25])
    plan = CorrectorAllocationPlan([stage])
    workspace = CorrectorAllocationWorkspace(plan)
    command, feedback = zeros(Float32, 1), zeros(Float32, 1)
    for expected in (0.25f0, 0.5f0, 0.75f0, 1f0)
        @test FGA.process!(command, feedback, workspace, plan, Float32[1]) === nothing
        FGA.commit!(workspace)
        @test command == [expected]
        @test feedback == [1f0 - expected]
    end
end
