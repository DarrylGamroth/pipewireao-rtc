using Test, PipeWireAO
include("managed_session_optical.jl")
const Optical = ManagedSessionOptical

@testset "bounded paired RMS samples preserve identities and settling prefix" begin
    domain = AcquisitionDomain(ntuple(i -> UInt8(i),PipeWireAO.ACQUISITION_DOMAIN_SIZE))
    samples = Optical.RMSSamples(64)
    for sequence in 1:64
        identity = AcquisitionIdentity(domain,UInt64(1),UInt64(sequence))
        Optical.record!(samples,Float32[1000,sequence <= 32 ? 1000 : 100],identity)
        Optical.record!(samples,Float32[1,1],identity) # Duplicate does not replace a paired sample.
    end
    result = Optical.summary(samples)
    @test result["sample_count"] == 64
    @test result["trailing_uncorrected_mean_nm"] == 1000
    @test result["trailing_corrected_mean_nm"] == 100
    @test result["residual_ratio"] == 0.1
    @test result["identities"][end]["sequence"] == 64
    @test samples.count == 64
    fresh = Optical.RMSSamples(64)
    first = AcquisitionIdentity(domain,UInt64(1),UInt64(1))
    Optical.record!(fresh,Float32[1000,100],first)
    @test_throws ErrorException Optical.record!(fresh,Float32[-1,1],AcquisitionIdentity(domain,UInt64(1),UInt64(2)))
    @test_throws ErrorException Optical.record!(fresh,Float32[1,1],AcquisitionIdentity(domain,UInt64(2),UInt64(2)))
    @test_throws ErrorException Optical.summary(fresh)
end
