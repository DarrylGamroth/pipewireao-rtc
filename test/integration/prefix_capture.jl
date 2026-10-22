# Focused regression for repeated masked image samples in opt-in capture clients.
module PrefixCaptureTests
using Test, PipeWireAO
include("classic_managed_replay.jl")
mutable struct Capture
    values::Vector{Float32}
    error::Union{Nothing,Exception}
    header::BufferHeader
    identity::Nothing
end
(capture::Capture)(stream)=nothing
@testset "Repeated masked observation payload" begin
    capture=Capture(Float32[NaN,2],nothing,BufferHeader(0,0,Int64(42),0,UInt64(1)),nothing)
    record=ClassicManagedReplay.PrefixCapture(capture,1)
    record(nothing)
    @test capture.error===nothing && record.seen[1]
    record(nothing)
    @test capture.error===nothing
    capture.values[2]=3
    record(nothing)
    @test capture.error isa ErrorException
end
@testset "Selected acquisition generation" begin
    domain=AcquisitionDomain(ntuple(_->0x01,16))
    previous=AcquisitionIdentity(domain,UInt64(1),UInt64(32))
    current=AcquisitionIdentity(domain,UInt64(2),UInt64(1))
    @test ClassicManagedReplay._classic_in_generation(nothing,nothing)
    @test !ClassicManagedReplay._classic_in_generation(previous,UInt64(2))
    @test ClassicManagedReplay._classic_in_generation(current,UInt64(2))
    @test_throws ErrorException ClassicManagedReplay._classic_in_generation(nothing,UInt64(2))
    @test_throws ErrorException ClassicManagedReplay._classic_in_generation(current,UInt64(1))
end
end
