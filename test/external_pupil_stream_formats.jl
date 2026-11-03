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

function sensor_native_buffer(count;requirements=())
    native = PipeWireAO.LibPipeWire
    memory = zeros(UInt8,4count)
    chunk = Ref(native.spa_chunk(UInt32(0),UInt32(length(memory)),Int32(4),UInt32(0)))
    records=MetadataSnapshot((MetadataRequirement(SPA.META_HEADER),requirements...))
    metadata=records.descriptors
    data = Ref(native.spa_data(native.SPA_DATA_MemPtr,SPA.DATA_FLAG_READWRITE,Int64(-1),UInt32(0),
        UInt32(length(memory)),pointer(memory),Base.unsafe_convert(Ptr{native.spa_chunk},chunk)))
    spa_buffer = Ref(native.spa_buffer(records.count,UInt32(1),pointer(metadata),Base.unsafe_convert(Ptr{native.spa_data},data)))
    native_buffer = Ref(native.pw_buffer(Base.unsafe_convert(Ptr{native.spa_buffer},spa_buffer),C_NULL,UInt64(0),UInt64(0),UInt64(0)))
    buffer = StreamBuffer(Base.unsafe_convert(Ptr{native.pw_buffer},native_buffer))
    return (;memory,chunk,records,metadata,data,spa_buffer,native_buffer,buffer)
end

@testset "sensors publish independent records with independent classification" begin
    science = sensor_stream_science(;chopped=true)
    streams = StreamOwner.stream_options(science,"test.pupil",(;llowfs="test.llowfs",scc="test.scc"))
    @test Set(r.type for r in streams[2].metadata) == Set((SPA.META_ACQUISITION_IDENTITY,
        SPA.META_EXPOSURE_TIMING,SPA.META_REFERENCE_TIMESTAMP))
    @test Set(r.type for r in streams[3].metadata) == Set((SPA.META_ACQUISITION_IDENTITY,
        SPA.META_EXPOSURE_TIMING,SPA.META_REFERENCE_TIMESTAMP,SPA.META_OPTICAL_CHOPPING,SPA.META_ELECTRICAL_TRIGGER))
    HIL = AdaptiveOpticsSimPipeWireHIL
    native = PipeWireAO.LibPipeWire
    option = streams[2]
    parameters = HIL._stream_parameters(option.format,option.schema;
        buffers=option.buffers,metadata=option.metadata)
    object = PipeWireAO.pod_value(SPA.Parameter,parameters[4]).object
    @test PipeWireAO.pod_value(SPA.Id,object[SPA.META_PARAM_TYPE].value) == SPA.Id(SPA.META_ACQUISITION_IDENTITY)
    @test PipeWireAO.pod_value(Int32,object[SPA.META_PARAM_SIZE].value) == 40
    @test PipeWireAO.pod_value(Bool,object[native.SPA_PARAM_META_required].value)
    state = HIL.ArrayStreamState(6)
    identity = AcquisitionIdentity(AcquisitionDomain(ntuple(UInt8,16)),UInt64(2),UInt64(7))
    classification = StreamOwner.trigger_state(science,:llowfs,(;sequence=UInt64(7)))
    @test classification == ACQUISITION_TRIGGER_ABSENT
    state.values .= Float32.(1:6)
    HIL._set_array_receipt!(state.receipt,Int64(60_000_000),UInt64(7),UInt64(10_000_000),identity,UInt64(0),classification,false,nothing,nothing)
    storage = sensor_native_buffer(6;requirements=option.metadata)
    process = HIL.ArrayStreamProcess(state,storage.buffer,false,12,option.metadata,option.reference_clock)
    GC.@preserve storage begin
        @test HIL._write_array!(process) === nothing
        metadata = metadata_records(storage.buffer)
        @test metadata_records_valid(metadata,option.metadata)
        @test trigger_classification(metadata) === nothing
        @test optical_classification(metadata) === nothing
        @test reference_timestamp(metadata)!==nothing
        @test acquisition_identity(metadata) == identity
        @test exposure_timing(metadata).duration_nanoseconds == 10_000_000
        @test buffer_header(storage.buffer).sequence == 7
        @test buffer_header(storage.buffer).pts == 60_000_000
        @test reinterpret(Float32,storage.memory) == state.values
        received = HIL.ArrayStreamState(6)
        reader = HIL.ArrayStreamProcess(received,storage.buffer,true,12,option.metadata,option.reference_clock)
        @test HIL._read_array!(reader)
        @test received.values == state.values
        @test received.receipt.identity == identity
        @test received.receipt.trigger_state == ACQUISITION_TRIGGER_ABSENT
    end
end

@testset "sensor emitter owns host storage and preserves transport conversion" begin
    for T in (Float32, Float64)
        science = sensor_stream_science()
        sensors = map(sensor -> merge(sensor, (;image=T.(sensor.image))), science.sensors)
        science = merge(science, (;sensors))
        execution = StreamOwner.stream_execution((;version=4), science, StreamOwner.OwnerState())
        metadata = (;sequence=UInt64(1))
        image = T[11 12 13; 21 22 23]
        expected = Float32.(image)
        for index in eachindex(execution.frames)
            @test eltype(execution.frames[index]) === T
            @test eltype(execution.buffers[index]) === Float32
            @test (execution.frames[index] === execution.buffers[index]) == (T === Float32)
            @test execution.frames[index] !== values(science.sensors)[index].image
            @test execution.buffers[index] !== image
        end
        @test execution.buffers[1] !== execution.buffers[2]
        @test execution.frames[1] !== execution.frames[2]
        execution.emit(:llowfs, image, metadata)
        @test execution.buffers[1] == expected
        @test size(execution.buffers[1]) == (2,3)
        @test all(iszero, execution.buffers[2])
        fill!(image, 0)
        @test execution.buffers[1] == expected
        execution.emit(:scc, fill(T(7),2,3), metadata)
        @test execution.buffers[1] == expected
        @test execution.buffers[2] == fill(7f0,2,3)
        execution.emit(:llowfs, fill(T(floatmax(Float32)),2,3), metadata)
        @test execution.buffers[1] == fill(floatmax(Float32),2,3)
        @test_throws ArgumentError execution.emit(:llowfs, fill(T(NaN),2,3), metadata)
        @test_throws ArgumentError execution.emit(:llowfs, fill(T(Inf),2,3), metadata)
        if T === Float64
            @test_throws ArgumentError execution.emit(:llowfs, fill(floatmax(Float64),2,3), metadata)
        end
    end
    @test all(id->id.name ∉ ("CUDA","AMDGPU","Proper"), keys(Base.loaded_modules))
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
            @test Dict(stream.properties)["pipewireao.header.pts.clock"] == "model"
            @test Dict(stream.properties)["pipewireao.header.pts.absolute-conversion"] == "unavailable"
        end
        @test all(r -> r.required,streams[2].metadata)
        @test length(streams[2].metadata)==3
        @test length(streams[3].metadata)==(chopped ? 5 : 3)
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

@testset "optical classification is independent of trigger polarity" begin
    required = Set((SPA.META_ACQUISITION_IDENTITY,SPA.META_EXPOSURE_TIMING,SPA.META_REFERENCE_TIMESTAMP,
        SPA.META_OPTICAL_CHOPPING,SPA.META_ELECTRICAL_TRIGGER))
    science = sensor_stream_science(;chopped=true)
    streams = StreamOwner.stream_options(science,"test.pupil",(;llowfs="test.llowfs",scc="test.scc"))
    @test any(r -> r.type==SPA.META_ACQUISITION_IDENTITY && r.required,streams[1].metadata)
    @test Set(r.type for r in streams[3].metadata if r.required) == required
    @test Set(r.type for r in streams[2].metadata if r.required) == setdiff(required,
        Set((SPA.META_OPTICAL_CHOPPING,SPA.META_ELECTRICAL_TRIGGER)))
    for polarity in (true,false)
        configured = merge(science,(;chopping=(;scc=(;trigger_high_is_fringed=polarity))))
        for (kind,optical) in ((:fringed,OPTICAL_FRINGED),(:unfringed,OPTICAL_UNFRINGED),(:mixed,OPTICAL_MIXED))
            metadata = (;chopped_image_kind=kind)
            @test StreamOwner.sensor_optical_classification(configured,:scc,metadata) == optical
            expected = kind === :mixed ? ACQUISITION_TRIGGER_MIXED :
                ((kind === :fringed) == polarity ? ACQUISITION_TRIGGER_HIGH : ACQUISITION_TRIGGER_LOW)
            @test StreamOwner.trigger_state(configured,:scc,metadata) == expected
        end
        @test StreamOwner.sensor_optical_classification(configured,:llowfs,(;)) == OPTICAL_ABSENT
        @test_throws ArgumentError StreamOwner.sensor_optical_classification(configured,:scc,(;))
    end
end
