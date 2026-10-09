using Test, LinearAlgebra, Random
include("calibration_inverse_analysis.jl")
const CIA = CalibrationInverseAnalysis

@testset "physical coordinates and matrix-only reference rejection" begin
    rng = Xoshiro(817)
    B = hcat(zeros(5, 3), randn(rng, 5, 3))
    D = randn(rng, 12, 5)
    r = randn(rng, 12)
    original = (copy(B), copy(D), copy(r))
    result = CIA.candidate(D, B, r, CIA.Reconstructors.ExactPseudoInverse())
    @test (B, D, r) == original
    @test result.coordinates.rank == 3
    @test result.coordinates.null_coordinates == [1, 2, 3]
    @test all(iszero, result.matrix[1:3, :])
    @test result.effective_rank == 3
    @test B * result.coordinates.to_controller ≈ result.coordinates.basis atol=1e-14
    @test norm(B * Float64.(result.matrix) * r) < 1e-6
    @test B * Float64.(result.matrix) * D * result.coordinates.basis ≈
        result.coordinates.basis atol=1e-6
    @test result.packed_reference_command_norm < 1e-6
    @test result.rejected_response_frobenius > 0
    @test_throws ArgumentError CIA.candidate(D, B, zeros(12), CIA.Reconstructors.ExactPseudoInverse())
    @test_throws ArgumentError CIA.candidate(D, B, fill(NaN, 12), CIA.Reconstructors.ExactPseudoInverse())
    @test_throws DimensionMismatch CIA.candidate(D, B, zeros(11), CIA.Reconstructors.ExactPseudoInverse())
    @test_throws DimensionMismatch CIA.candidate(D[:, 1:4], B, r, CIA.Reconstructors.ExactPseudoInverse())
    @test_throws ArgumentError CIA.physical_coordinates(zeros(5, 6))
    @test_throws ArgumentError CIA.physical_coordinates(B; rtol=-1)
    @test_throws ArgumentError CIA.physical_coordinates(B; rtol=NaN)
    @test_throws ArgumentError CIA.candidate(fill(NaN, 12, 5), B, r, CIA.Reconstructors.ExactPseudoInverse())
    @test_throws ArgumentError CIA.physical_coordinates(zeros(0, 6))
end

@testset "projection before fitting is required" begin
    rng = Xoshiro(991)
    B = randn(rng, 5, 3)
    D = randn(rng, 12, 5)
    r = randn(rng, 12)
    coordinates = CIA.physical_coordinates(B)
    naive = coordinates.to_controller * pinv(D * coordinates.basis)
    projected_after_fit = CIA.reject_reference_input(naive, r)
    proper = CIA.candidate(D, B, r, CIA.Reconstructors.ExactPseudoInverse())
    @test norm(B * naive * r) > 1e-3
    @test norm(B * projected_after_fit * r) < 1e-12
    @test norm(B * projected_after_fit * D * coordinates.basis - coordinates.basis) > 1e-3
    @test norm(B * Float64.(proper.matrix) * D * coordinates.basis - coordinates.basis) < 1e-6
    truncated = CIA.candidate(D, B, r, CIA.Reconstructors.TSVDInverse(n_trunc=3))
    @test truncated.effective_rank == 0
    @test all(iszero, truncated.matrix)
end
