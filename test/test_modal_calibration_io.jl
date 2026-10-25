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
