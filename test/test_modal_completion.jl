module ModalCompletionTests
using Test, LinearAlgebra, PipeWireAORTC, FilterGraphAlgorithms
const IC = PipeWireAORTC.InstrumentConfiguration
const FGA = FilterGraphAlgorithms
const LA = LinearAlgebra
const GraphOwner = PipeWireAORTC.GraphOwner
include(joinpath(@__DIR__,"../ext/modal_completion.jl"))

grid_mirror(n) = (;layout=(;grid_shape=(n,n),
    command_positions=Tuple((column,row) for row in n:-1:1 for column in 1:n)))
const POLICY = Dict("kind"=>"thin_plate_annulus","guard_width_pitches"=>2)

@testset "Annular completion preserves geometry and reverse feedback" begin
    mirror = grid_mirror(9)
    registration = (;actuator_pitch_pupil_radius=0.3)
    result = modal_completion(mirror,registration,POLICY;obstruction=0.2)
    positions = IC.actuator_coordinates(mirror,Float64;pupil_registration=registration)
    supported = findall(!iszero,result.roles)
    fixed = findall(iszero,result.roles)
    extrapolated = findall(==(UInt8(2)),result.roles)
    @test !isempty(fixed) && !isempty(extrapolated)
    @test result.controlled == findall(==(UInt8(1)),result.roles)
    @test result.completion[result.controlled,:] == Matrix{Float32}(I,length(result.controlled),length(result.controlled))
    @test result.selector * result.completion == Matrix{Float32}(I,length(result.controlled),length(result.controlled))
    @test result.feedback * result.completion ≈ Matrix{Float32}(I,length(result.controlled),length(result.controlled)) atol=2e-6
    for values in (ones(size(positions,2)),positions[1,:],positions[2,:],
            0.7 .+ 0.2 .* positions[1,:] .- 0.4 .* positions[2,:])
        completed = result.completion * Float32.(values[result.controlled])
        @test completed[supported] ≈ values[supported] atol=2e-6
        @test all(iszero,completed[fixed])
    end
    @test all(iszero,result.feedback[:,fixed])
    @test any(!iszero,result.feedback[:,first(extrapolated)])
    @test all(iszero,result.selector[:,extrapolated])
    projection = FGA.VdmToPdmPlan(result.completion,Matrix{Float32}(I,length(result.roles),length(result.roles)))
    @test projection.correction_roles == result.roles
    no_guard = modal_completion(mirror,registration,merge(POLICY,Dict("guard_width_pitches"=>0));obstruction=0.2)
    @test count(!iszero,no_guard.roles) < count(!iszero,result.roles)
end

@testset "Selected GPI geometric partition" begin
    mirror = grid_mirror(48)
    registration = (;actuator_pitch_pupil_radius=2/43)
    result = modal_completion(mirror,registration,POLICY;obstruction=0.13178893)
    @test size(result.completion) == (2304,1412)
    @test (count(==(UInt8(1)),result.roles),count(==(UInt8(2)),result.roles),count(iszero,result.roles)) == (1412,304,588)
    coordinates = IC.actuator_coordinates(mirror,Float64;pupil_registration=registration)
    radii = hypot.(coordinates[1,:],coordinates[2,:])
    @test count(<(0.13178893),radii) == 24
    @test count(radius -> 1 < radius <= 1+4/43,radii) == 280
    @test result.controlled == findall(radius -> 0.13178893 <= radius <= 1,radii)
    affine = hcat(ones(2304),permutedims(coordinates))
    expected = Float32.(affine .* (result.roles .!= 0))
    error = result.completion * Float32.(affine[result.controlled,:]) - expected
    @test maximum(abs,error) <= 3e-6
    @info "Provisional GPI completion diagnostics" maximum_affine_error=maximum(abs,error) relative_affine_error=norm(error)/norm(expected) maximum_absolute_weight=maximum(abs,result.completion) completion_infinity_norm=opnorm(result.completion,Inf) feedback_infinity_norm=opnorm(result.feedback,Inf) feedback_two_norm=opnorm(result.feedback,2)
    @test result.feedback * result.completion ≈ Matrix{Float32}(I,1412,1412) atol=3e-6
    @test all(iszero,result.feedback[:,findall(iszero,result.roles)])
    guard = findfirst(radius -> 1 < radius <= 1+4/43,radii)
    @test any(!iszero,result.feedback[:,guard])
    @test FGA.VdmToPdmPlan(result.completion,Matrix{Float32}(I,2304,2304)).correction_roles == result.roles

    # The declared ±1 µm limits accept the direct ramp; only outer guard
    # extrapolation exceeds them. Exercise the production forward/clamp/reverse owners.
    identity = Matrix{Float32}(I,2304,2304)
    forward = FGA.prepare_algorithm(FGA.VdmToPdmF32,FGA.VdmToPdmF32Configuration(
        active_vdm_count=1412,full_vdm_count=2304,physical_actuator_count=2304))
    FGA.replace_parameter!(forward,"active-to-full",result.completion)
    FGA.replace_parameter!(forward,"vdm-to-pdm",identity)
    reverse = FGA.prepare_algorithm(FGA.PdmFeedbackToVdmF32,FGA.PdmFeedbackToVdmF32Configuration(
        active_vdm_count=1412,full_vdm_count=2304,physical_actuator_count=2304))
    FGA.replace_parameter!(reverse,"full-to-active",result.feedback)
    FGA.replace_parameter!(reverse,"pdm-to-vdm",identity)
    limit = 1f-6
    conditioner = FGA.prepare_algorithm(FGA.VectorConditioningF32,FGA.VectorConditioningF32Configuration(
        count=2304,requested_schema="test/requested-opd-m/1",demanded_schema="test/demanded-opd-m/1",
        feedback_schema="test/constraint-feedback-opd-m/1",command_limits=(-limit,limit),
        slew_limit=nothing,initial_current=nothing,quantization_origin=nothing,
        quantization_step=nothing,dither_seed=nothing))
    direct_x = Float32.(coordinates[1,result.controlled])
    active = (direct_x ./ maximum(abs,direct_x)) .* limit
    requested,demanded,physical_feedback = zeros(Float32,2304),zeros(Float32,2304),zeros(Float32,2304)
    active_feedback = zeros(Float32,1412)
    @test FGA.process!(requested,forward,active) === nothing
    @test maximum(abs,active) <= limit
    @test FGA.process!(demanded,physical_feedback,conditioner,requested) === nothing
    clipped = findall(!iszero,physical_feedback)
    @test !isempty(clipped) && all(index -> radii[index]>1 && result.roles[index]==2,clipped)
    @test demanded == clamp.(requested,-limit,limit)
    @test physical_feedback == requested-demanded
    @test all(index -> sign(physical_feedback[index]) == sign(requested[index]),clipped)
    @test FGA.process!(active_feedback,reverse,physical_feedback) === nothing
    @test active_feedback ≈ result.feedback * physical_feedback atol=1e-12
    @test any(!iszero,active_feedback)
    correction = result.completion * active_feedback
    @test dot(correction,physical_feedback)>0
    @test norm(requested-correction-demanded) < norm(physical_feedback)
    @test all(iszero,result.selector*physical_feedback)
    @test all(iszero,requested[findall(iszero,result.roles)])
    @info "GPI guard-only clipping pipeline" clipped_guard_channels=length(clipped) maximum_requested_m=maximum(abs,requested) maximum_feedback_m=maximum(abs,active_feedback)
end

@testset "Malformed completion policies and maps are rejected" begin
    mirror = grid_mirror(5)
    registration = (;actuator_pitch_pupil_radius=0.5)
    for guard in (-1,Inf,NaN,true,"2")
        @test_throws ArgumentError modal_completion(mirror,registration,
            Dict("kind"=>"thin_plate_annulus","guard_width_pitches"=>guard);obstruction=0.2)
    end
    for obstruction in (-0.1,1,Inf,NaN,true)
        @test_throws ArgumentError modal_completion(mirror,registration,POLICY;obstruction)
    end
    @test_throws ArgumentError modal_completion(mirror,registration,Dict("kind"=>"other");obstruction=0.2)
    @test_throws ArgumentError modal_completion(mirror,registration,merge(POLICY,Dict("unknown"=>1));obstruction=0.2)
    @test_throws ArgumentError modal_completion(mirror,(;actuator_pitch_pupil_radius=NaN),POLICY;obstruction=0.2)
    for positions in (((1,1),(1,1)),((0,1),(1,2)),((true,1),(1,2)),((1.5,1),(1,2)))
        invalid = (;layout=(;grid_shape=(5,5),command_positions=positions))
        @test_throws ArgumentError modal_completion(invalid,registration,POLICY;obstruction=0.2)
    end
    line = (;layout=(;grid_shape=(5,5),command_positions=((1,3),(2,3),(4,3),(5,3))))
    @test_throws ArgumentError modal_completion(line,registration,POLICY;obstruction=0.2)
    @test_throws ArgumentError modal_completion(mirror,(;actuator_pitch_pupil_radius=10),POLICY;obstruction=0.2)
end

@testset "Completion cannot replace the coupled tip/tilt basis" begin
    for dependency in (:AdaptiveOpticsSim,:AdaptiveOpticsSimPipeWireHIL,:AdaptiveOpticsCalibration,
            :FilterGraphIsland,:FilterGraphPipeWire,:JuliaFilterGraph)
        Base.require(Main,dependency)
    end
    recipe = Dict("mirrors"=>[Dict("name"=>"woofer","completion"=>POLICY)],
        "tiptilt"=>Dict("mirror"=>"woofer"))
    mktempdir() do temporary
        output = joinpath(temporary,"unwritten")
        @test_throws ArgumentError Base.invokelatest(PipeWireAORTC.InstrumentCalibration.calibrate_modal_system,
            "source-must-not-be-read",recipe,output)
        @test !ispath(output)
    end
end
end
