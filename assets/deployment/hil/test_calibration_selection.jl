using Test,LinearAlgebra,Random
include("calibration_selection.jl")
const Selection=CalibrationSelection

@testset "absolute input scoring exposes bias hidden by differences" begin
    B=Matrix{Float64}(I,2,2)
    figures=[.1 0.;-.1 0.;0. .2;0. -.2]
    reference=[0.,0.,1.]
    D=[1. 0.;0. 1.;0. 0.]
    responses=figures*D'.+permutedims(reference)
    groups=Dict("sparse"=>[1],"mixed"=>[2])
    unbiased=[1. 0. 0.;0. 1. 0.]
    biased=[1. 0. 1.;0. 1. 1.]
    good=Selection.score_inverse(unbiased,B,figures,responses;groups)
    bad=Selection.score_inverse(biased,B,figures,responses;groups)
    @test good.eligible
    @test good.absolute_physical_sse==0
    @test !bad.eligible
    @test bad.absolute_physical_sse≈8
    @test all(x.signed_difference_physical_sse<1e-30 for x in values(bad.groups))
    forward=Selection.score_forward(D,reference,figures,responses)
    @test forward.raw_signed_forward_sse==0
    @test forward.projected_signed_forward_sse==0
    @test_throws ArgumentError Selection.score_inverse(unbiased,B,figures,responses;groups=Dict("both"=>[1,1]))
    @test_throws ArgumentError Selection.score_inverse(unbiased,B,figures.+1,responses;groups)
    candidates=[(;eligible_rank=true,multiplier=1,cutoff=1.,family="zonal"),
        (;eligible_rank=true,multiplier=4,cutoff=4.,family="hadamard")]
    @test Selection.select_candidate(candidates,[[good,good],[good,good]])==2
    @test_throws ArgumentError Selection.select_candidate(candidates,[[bad],[bad]])
    @test_throws DimensionMismatch Selection.select_candidate(candidates,[[good]])
    differing_scales=[(;eligible_rank=true,multiplier=1,cutoff=10.,family="zonal"),
        (;eligible_rank=true,multiplier=4,cutoff=4.,family="hadamard")]
    @test Selection.select_candidate(differing_scales,[[good,good],[good,good]])==1
    @test_throws ArgumentError Selection.select_candidate(candidates,[[good],[good]])
end

@testset "repeat scale uses orthonormal physical coordinates" begin
    rng=Xoshiro(717)
    B=hcat(zeros(3),Matrix{Float64}(I,3,3))
    D=randn(rng,8,3)
    noise=.001randn(rng,8,3)
    reference=randn(rng,8)
    candidates=Selection.family_candidates("zonal",D+noise,D-noise,B,reference)
    @test length(candidates)==3
    @test [c.multiplier for c in candidates]==[1,2,4]
    @test all(c.interaction≈D for c in candidates)
    @test all(all(iszero,c.matrix[1,:]) for c in candidates)
    expected=opnorm(Selection.Inverse.reject_reference(noise,reference))
    @test all(c.repeat_scale≈expected for c in candidates)
    @test all(c.eligible_rank for c in candidates)
    @test_throws ArgumentError Selection.family_candidates("zonal",D,D,B,reference)
    @test_throws DimensionMismatch Selection.family_candidates("zonal",D,D[:,1:2],B,reference)
end
