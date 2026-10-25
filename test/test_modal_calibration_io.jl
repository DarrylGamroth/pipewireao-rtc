using Test, PipeWireAORTC
const K=PipeWireAORTC.InstrumentCalibration
const A=PipeWireAORTC.Artifacts
@testset "calibration FITS preserves non-square and coefficient-bank axes" begin
    mktempdir() do directory
        for shape in ((3,7),(5,2,3),(9,))
            values=reshape(Float32.(1:prod(shape)),shape)
            path=joinpath(directory,"coefficients.fits")
            K.write_fits(path,values)
            artifact=A.FITSArtifact(path;axes=reverse(ntuple(identity,length(shape))))
            @test A.prepare(artifact,Float32,shape).data==values
        end
    end
end

@testset "shape calibration aliases track completion dimensions and owned values" begin
    for prefix in ("","mirror-")
        key(suffix)=Symbol(prefix*suffix)
        parameters=Dict{Symbol,Array{Float32}}(
            key("active-to-full")=>Float32[1 0;0 1;0.5 0.5],
            key("pdm-to-vdm")=>Float32[1 0 0;0 1 0;0 0 1],
            key("shape-active-to-full")=>zeros(Float32,3,1),
            key("shape-pdm-to-vdm")=>zeros(Float32,3,3),
            key("shape-offset")=>fill(1f0,3))
        @test K.initialize_shape_offsets!(parameters,prefix)===parameters
        for (alias,source) in (("shape-active-to-full","active-to-full"),("shape-pdm-to-vdm","pdm-to-vdm"))
            @test parameters[key(alias)]==parameters[key(source)]
            @test parameters[key(alias)]!==parameters[key(source)]
        end
        @test all(iszero,parameters[key("shape-offset")])
        delete!(parameters,key("shape-offset"))
        @test K.initialize_shape_offsets!(parameters,prefix)===parameters
        @test !haskey(parameters,key("shape-offset"))
        delete!(parameters,key("shape-pdm-to-vdm"))
        @test_throws ArgumentError K.initialize_shape_offsets!(parameters,prefix)
    end
    absent=Dict{Symbol,Array{Float32}}()
    @test K.initialize_shape_offsets!(absent)===absent && isempty(absent)
    parameters=Dict{Symbol,Array{Float32}}(Symbol("pdm-to-vdm")=>Float32[1 0 0;0 1 0;0 0 1],
        Symbol("shape-active-to-full")=>zeros(Float32,3,1),
        Symbol("shape-pdm-to-vdm")=>zeros(Float32,3,3),Symbol("shape-offset")=>fill(1f0,3))
    completion=Float32[1 0;0 1;0.5 0.5]
    K.allocation_parameters(parameters,completion,[1,2];measurement_count=4)
    @test parameters[Symbol("shape-active-to-full")]==completion
    @test all(iszero,parameters[Symbol("shape-offset")])
end
