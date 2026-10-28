using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsCalibration, FilterGraphAlgorithms, JuliaFilterGraph
using FilterGraphIsland, FilterGraphPipeWire
const FIELD_VALIDATION=Base.get_extension(PipeWireAORTC,:PipeWireAORTCCalibrationExt)
@testset "Propagated pupil-field validation metric" begin
    field=ComplexF32[1 2im; 3+4im 0]
    @test FIELD_VALIDATION.pupil_field_overlap(field,field)≈1
    @test FIELD_VALIDATION.pupil_field_overlap(field,3cis(0.8).*field)≈1
    @test FIELD_VALIDATION.pupil_field_overlap(ComplexF64[1,0],ComplexF64[0,1])==0
    @test FIELD_VALIDATION.pupil_field_overlap(ComplexF64[1,1],ComplexF64[1,-1])==0
    @test FIELD_VALIDATION.pupil_field_overlap(ComplexF64[1,1],ComplexF64[1,0])≈0.5
    @test_throws DimensionMismatch FIELD_VALIDATION.pupil_field_overlap(field,vec(field))
    @test_throws ArgumentError FIELD_VALIDATION.pupil_field_overlap(field,zero(field))
    @test_throws ArgumentError FIELD_VALIDATION.pupil_field_overlap(ComplexF32[Inf],ComplexF32[1])
    @test_throws ArgumentError FIELD_VALIDATION.pupil_field_overlap(ComplexF32[NaN],ComplexF32[1])
end
