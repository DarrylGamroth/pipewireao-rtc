# Optional CPU selector; no PipeWire core, services, device or GPU import.
# julia --project=/path/to/science-environment test/optical_exposure_publication.jl
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, PipeWireAO
const PublicationOwner = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).ExternalPupilOwner

mutable struct ExposureTransport
    events::Vector{Any}
    accept::Bool
    stage_error::Bool
    trigger_error::Bool
end
ExposureTransport() = ExposureTransport(Any[],true,false,false)

function AdaptiveOpticsSimPipeWireHIL.stage_pipewire_array!(owner::ExposureTransport,index,image;kwargs...)
    owner.stage_error && error("staging failed")
    push!(owner.events,(;index,image=copy(image),metadata=(;kwargs...)))
    return owner.accept
end
function PipeWireAO.trigger_process!(owner::ExposureTransport)
    owner.trigger_error && error("trigger failed")
    push!(owner.events,:trigger)
    return nothing
end

function stage_test_exposure!(publisher,index;sequence=UInt64(1))
    identity = AcquisitionIdentity(AcquisitionDomain(ntuple(UInt8,16)),UInt64(4),sequence)
    image = fill(Float32(index),2,3)
    return PublicationOwner.stage_exposure!(publisher,index,image,identity,Int64(12),UInt64(5),
        ACQUISITION_TRIGGER_HIGH;optical_classification=OPTICAL_FRINGED)
end

@testset "one optical source step publishes completed exposures together" begin
    transport = ExposureTransport()
    publisher = PublicationOwner.ExposurePublisher(transport)
    result = PublicationOwner.publish_exposures!(publisher) do
        @test stage_test_exposure!(publisher,2)
        @test stage_test_exposure!(publisher,3)
        :completed
    end
    @test result === :completed
    @test length(transport.events) == 3
    @test transport.events[end] === :trigger
    @test map(event->event.index,transport.events[1:2]) == [2,3]
    for event in transport.events[1:2]
        @test event.image == fill(Float32(event.index),2,3)
        @test event.metadata.identity.generation == 4
        @test event.metadata.identity.sequence == 1
        @test event.metadata.pts == 12
        @test event.metadata.duration == 5
        @test event.metadata.trigger_state == ACQUISITION_TRIGGER_HIGH
        @test event.metadata.optical_classification == OPTICAL_FRINGED
    end
    empty!(transport.events)
    PublicationOwner.publish_exposures!(publisher) do
        @test stage_test_exposure!(publisher,3;sequence=UInt64(2))
    end
    @test length(transport.events) == 2
    @test first(transport.events).index == 3
    @test last(transport.events) === :trigger
    empty!(transport.events)
    @test PublicationOwner.publish_exposures!(() -> :no_exposure,publisher) === :no_exposure
    @test isempty(transport.events)
    @test_throws ArgumentError stage_test_exposure!(publisher,2)
end

@testset "rejected staging still retries retained samples once" begin
    transport = ExposureTransport()
    publisher = PublicationOwner.ExposurePublisher(transport)
    transport.accept = false
    PublicationOwner.publish_exposures!(publisher) do
        @test !stage_test_exposure!(publisher,2)
        @test !stage_test_exposure!(publisher,3)
    end
    @test count(==(:trigger),transport.events) == 1
    transport.accept = true
    PublicationOwner.publish_exposures!(publisher) do
        @test stage_test_exposure!(publisher,2;sequence=UInt64(2))
    end
    @test count(==(:trigger),transport.events) == 2
end

@testset "failed source steps cannot publish partial staging later" begin
    for failure in (:source,:stage,:trigger)
        transport = ExposureTransport()
        publisher = PublicationOwner.ExposurePublisher(transport)
        @test_throws ErrorException PublicationOwner.publish_exposures!(publisher) do
            stage_test_exposure!(publisher,2)
            if failure === :source
                error("optical source step failed")
            elseif failure === :stage
                transport.stage_error = true
                stage_test_exposure!(publisher,3)
            else
                transport.trigger_error = true
            end
        end
        @test count(==(:trigger),transport.events) == 0
        calls = Ref(0)
        @test_throws ArgumentError PublicationOwner.publish_exposures!(publisher) do
            calls[] += 1
            stage_test_exposure!(publisher,3)
        end
        @test calls[] == 0
        @test count(==(:trigger),transport.events) == 0
    end
    transport = ExposureTransport()
    publisher = PublicationOwner.ExposurePublisher(transport)
    @test_throws ArgumentError PublicationOwner.publish_exposures!(publisher) do
        stage_test_exposure!(publisher,2)
        transport.stage_error = true
        @test_throws ErrorException stage_test_exposure!(publisher,3)
    end
    @test count(==(:trigger),transport.events) == 0
    @test !any(id->id.name in ("Proper","CUDA","AMDGPU"),keys(Base.loaded_modules))
end
