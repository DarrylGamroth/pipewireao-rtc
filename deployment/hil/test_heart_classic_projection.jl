using Test
include("heart_classic_projection.jl")
const Geometry=HeartClassicProjection
@testset "Classic selected inverse uses explicit nontrivial native coordinates" begin
    indices=vcat(collect(1:220),267)
    T=zeros(Float32,221,277);for (row,index) in enumerate(indices);T[row,index]=1;end
    E=zeros(Float32,277,277);for index in 1:277;E[index,index]=1;end
    E[277,267]=0.25f0
    B=E[:,indices];R=zeros(Float32,221,376);R[221,1]=.125f0
    lifted=Geometry.lift(R,T,E,B)
    @test lifted.indices==indices
    @test size(lifted.padded)==(277,376)
    @test lifted.padded[267,1]==.125f0
    @test lifted.padded[221,1]==0
    @test all(iszero,lifted.padded[setdiff(1:277,indices),:])
    @test reinterpret(UInt32,vec(E[:,lifted.indices]))==reinterpret(UInt32,vec(B))
    wrong=copy(T);wrong[221,:].=T[220,:]
    @test_throws ArgumentError Geometry.lift(R,wrong,E,B)
    wrong=copy(T);wrong[1,2]=.1
    @test_throws ArgumentError Geometry.lift(R,wrong,E,B)
    wrong=copy(T);wrong[1,2]=-0f0
    @test_throws ArgumentError Geometry.lift(R,wrong,E,B)
    wrong=copy(B);wrong[1,1]=2
    @test_throws ArgumentError Geometry.lift(R,T,E,wrong)
    @test_throws DimensionMismatch Geometry.lift(R,T[:,1:221],E,B)
    wrong=copy(R);wrong[1,1]=NaN
    @test_throws ArgumentError Geometry.lift(wrong,T,E,B)
end
