# Optional CPU-only stream/POD checks; no optical preparation or PipeWire core.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, PipeWireAO
const StreamOwner = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).ExternalPupilOwner

function sensor_stream_science(; durations=(llowfs=2_000_000, scc=10_000_000), samples=1, chopped=false)
    sensors = map(keys(durations)) do name
        (;image=zeros(Float32, 2, 3), schema="example.$name/1",
            properties=Dict("optics.spectral-samples"=>string(samples)))
    end
    return (;pupil=(;shape=(2,2,3), schema="example.pupil/1", properties=Dict()),
        sensors=NamedTuple{keys(durations)}(sensors),
        plant=(;exposures=map(duration -> (;duration_ns=duration), durations)),
        chopping=chopped ? (;scc=(;initial_phase="fringed")) : NamedTuple())
end

function stream_formats(science)
    return StreamOwner.stream_options(science,"test.pupil",(;llowfs="test.llowfs",scc="test.scc"))
end

@testset "sensor native formats retain independent exposure rates" begin
    for samples in (1,2), chopped in (false,true)
        science = sensor_stream_science(;samples,chopped)
        streams = stream_formats(science)
        @test streams[1].format.rate === nothing
        @test NdArrayFormat(ndarray_format(streams[1].format)).rate === nothing
        for (stream, expected) in zip(streams[2:3], (SPA.Fraction(500,1),SPA.Fraction(100,1)))
            @test stream.format.rate == expected
            @test NdArrayFormat(ndarray_format(stream.format;schema=stream.schema)).rate == expected
            @test stream.format.shape == (2,3)
            @test stream.format.layout == NdArray.ROW_MAJOR
            @test Dict(stream.properties)["optics.spectral-samples"] == string(samples)
        end
        @test streams[2].acquisition_version == 2
        @test streams[3].acquisition_version == (chopped ? 3 : 2)
        @test science.plant.exposures.scc.duration_ns == 10_000_000
    end
end

@testset "exposure rates reduce exactly within native fraction widths" begin
    science = sensor_stream_science(;durations=(llowfs=3_000_000,scc=7_000_000))
    streams = stream_formats(science)
    @test streams[2].format.rate == SPA.Fraction(1000,3)
    @test streams[3].format.rate == SPA.Fraction(1000,7)
    @test stream_formats(sensor_stream_science(;durations=(llowfs=1,scc=10_000_000)))[2].format.rate == SPA.Fraction(1_000_000_000,1)
    longest = Int64(typemax(UInt32)) * 1_000_000_000
    streams = stream_formats(sensor_stream_science(;durations=(llowfs=6_000_000_000,scc=longest)))
    @test streams[2].format.rate == SPA.Fraction(1,6)
    @test streams[3].format.rate == SPA.Fraction(1,typemax(UInt32))
    for duration in (0,-1,Int64(typemax(UInt32))+2)
        @test_throws ArgumentError stream_formats(sensor_stream_science(;durations=(llowfs=duration,scc=10_000_000)))
    end
    @test all(id->id.name ∉ ("CUDA","AMDGPU","Proper"), keys(Base.loaded_modules))
end
