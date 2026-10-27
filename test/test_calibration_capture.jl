using Test, PipeWireAO, AdaptiveOpticsSim, PipeWireAORTC
include(joinpath(@__DIR__,"..","ext","calibration_capture.jl"))
const CC = CalibrationCapture
const AG = AdaptiveOpticsSim.AlgorithmGraphs
const PW = PipeWireAO.LibPipeWire

function capture_declarations(prefix="test.capture")
    descriptor(name,T,shape) = (;name="$prefix.$name",format=NdArrayFormat(T,shape;
        layout=NdArray.ROW_MAJOR,rate=SPA.Fraction(1000,1)),schema="test.capture.$name/1")
    return (;raw=descriptor("raw",NdArray.U16_LE,(2,3)),
        slopes=descriptor("slopes",NdArray.F32_LE,(2,2)),
        flux=descriptor("flux",NdArray.F32_LE,(2,)),
        validity=descriptor("validity",NdArray.BOOL8,(2,)))
end

function capture_payload(::Type{T}, count) where {T}
    memory = zeros(UInt8,count*sizeof(T))
    chunk = Ref(PW.spa_chunk(UInt32(0),UInt32(length(memory)),Int32(sizeof(T)),Int32(0)))
    header = Ref(PW.spa_meta_header(UInt32(0),UInt32(0),Int64(9000),Int64(0),UInt64(1)))
    acquisition = zeros(UInt64,Int(PW.SPA_META_ACQUISITION_SIZE)÷8)
    metadata = PW.spa_meta[
        PW.spa_meta(PW.SPA_META_Header,UInt32(sizeof(PW.spa_meta_header)),Base.unsafe_convert(Ptr{Cvoid},header)),
        PW.spa_meta(PW.SPA_META_Acquisition,UInt32(sizeof(acquisition)),Ptr{Cvoid}(pointer(acquisition)))]
    data = Ref(PW.spa_data(PW.SPA_DATA_MemPtr,SPA.DATA_FLAG_READWRITE,Int64(-1),UInt32(0),
        UInt32(length(memory)),pointer(memory),Base.unsafe_convert(Ptr{PW.spa_chunk},chunk)))
    spa_buffer = Ref(PW.spa_buffer(UInt32(2),UInt32(1),pointer(metadata),Base.unsafe_convert(Ptr{PW.spa_data},data)))
    native_buffer = Ref(PW.pw_buffer(Base.unsafe_convert(Ptr{PW.spa_buffer},spa_buffer),C_NULL,0,0,0))
    buffer = StreamBuffer(Base.unsafe_convert(Ptr{PW.pw_buffer},native_buffer))
    return (;memory,chunk,header,acquisition,metadata,data,spa_buffer,native_buffer,buffer)
end

const DOMAIN = AcquisitionDomain(ntuple(UInt8,16))
identity(sequence=1,generation=1) = AcquisitionIdentity(DOMAIN,UInt64(generation),UInt64(sequence))
exposure(sequence=1,generation=1) = (;identity=identity(sequence,generation),
    timestamp=AG.ModelTimestamp(100),exposure_duration_nanoseconds=UInt64(10))

function owned_test_capture(f)
    loop = ThreadLoop("test.capture.owned")
    context,core = with_thread_loop_lock(loop) do _
        context=Context(loop)
        context,CoreConnection(context;self=true)
    end
    declarations=capture_declarations()
    slots=(;raw=CC._slot(declarations.raw,UInt16,2),slopes=CC._slot(declarations.slopes,Float32,2),
        flux=CC._slot(declarations.flux,Float32,1),validity=CC._slot(declarations.validity,Bool,1))
    capture=CC.Capture(core,slots,NamedTuple(),Base.AsyncCondition(),true,CC.IDLE,:none,nothing,nothing,Int64(0),UInt64(0),nothing,true,false)
    try
        f(capture)
    finally
        close(capture)
        with_thread_loop_lock(loop) do _
            close(core);close(context)
        end
        close(loop)
    end
end

function initialize_payload!(fixture, id=identity();duration=10)
    set_buffer_header!(fixture.buffer,BufferHeader(UInt32(0),UInt32(0),Int64(9000),Int64(0),id.sequence))
    metadata=buffer_acquisition(fixture.buffer)
    initialize_acquisition!(metadata)
    set_acquisition_identity!(metadata,id)
    set_acquisition_exposure_duration!(metadata,UInt64(duration))
end

@testset "owned acquisition slots preserve row-major values and provenance" begin
    owned_test_capture() do capture
        CC.arm!(capture,exposure())
        @test_throws InvalidStateException CC.arm!(capture,exposure())
        @test_throws InvalidStateException CC.snapshot(capture)
        for name in keys(capture.slots)
            slot=getproperty(capture.slots,name)
            T=eltype(slot.wire)
            fixture=capture_payload(T,length(slot.wire))
            GC.@preserve fixture begin
                initialize_payload!(fixture)
                wire=T===Bool ? Bool[false,true] : T.(1:length(slot.wire))
                fixture.memory .= reinterpret(UInt8,wire)
                CC._read!(capture,slot,fixture.buffer)
                @test slot.phase == CC.COMPLETE
                @test slot.receipt.identity == identity()
                @test slot.receipt.model_start_ns == 100
                @test slot.receipt.header.pts == 9000
                @test slot.receipt.duration_ns == 10
                @test slot.receipt.wire_start === nothing
                @test slot.wire == wire
            end
        end
        result=CC.await!(capture;deadline=PipeWireAORTC.NativeControlClient.monotonic()+1)
        @test result.arrays.raw == UInt16[1 2 3;4 5 6]
        @test result.arrays.slopes == Float32[1 2;3 4]
        @test result.arrays.validity == [false,true] # no implicit scientific policy
        @test result.arrays.raw === capture.slots.raw.array
        @test_throws ArgumentError CC.arm!(capture,exposure())
        @test_throws ArgumentError CC.arm!(capture,exposure(3))
        CC.arm!(capture,exposure(2))
        @test capture.phase == CC.ARMED
    end
end

@testset "wrong, stale, duplicate and invalid wire records cannot complete" begin
    for failure in (:identity,:sequence,:duration,:gap,:corrupted,:payload,:duplicate,:missing_header,:missing_acquisition,:missing_identity,:missing_duration)
        owned_test_capture() do capture
            CC.arm!(capture,exposure())
            fixture=capture_payload(UInt16,6)
            GC.@preserve fixture begin
                initialize_payload!(fixture)
                if failure===:missing_header || failure===:missing_acquisition
                    failure===:missing_header && (fixture.metadata[1]=fixture.metadata[2])
                    fixture.spa_buffer[]=PW.spa_buffer(UInt32(1),UInt32(1),pointer(fixture.metadata),Base.unsafe_convert(Ptr{PW.spa_data},fixture.data))
                elseif failure===:missing_identity || failure===:missing_duration
                    metadata=buffer_acquisition(fixture.buffer)
                    initialize_acquisition!(metadata)
                    failure===:missing_duration && set_acquisition_identity!(metadata,identity())
                elseif failure===:identity
                    set_acquisition_identity!(buffer_acquisition(fixture.buffer),identity(1,2))
                elseif failure===:sequence
                    set_buffer_header!(fixture.buffer,BufferHeader(UInt32(0),UInt32(0),Int64(0),Int64(0),UInt64(2)))
                elseif failure===:duration
                    set_acquisition_exposure_duration!(buffer_acquisition(fixture.buffer),UInt64(11))
                elseif failure in (:gap,:corrupted)
                    flags=failure===:gap ? SPA.META_HEADER_FLAG_GAP : SPA.META_HEADER_FLAG_CORRUPTED
                    set_buffer_header!(fixture.buffer,BufferHeader(flags,UInt32(0),Int64(0),Int64(0),UInt64(1)))
                elseif failure===:payload
                    set_chunk!(buffer_data(fixture.buffer);size=10,stride=2)
                elseif failure===:duplicate
                    CC._read!(capture,capture.slots.raw,fixture.buffer)
                end
                CC._read!(capture,capture.slots.raw,fixture.buffer)
                @test capture.failure !== :none
                @test_throws InvalidStateException CC.snapshot(capture)
                @test_throws InvalidStateException CC.await!(capture;deadline=PipeWireAORTC.NativeControlClient.monotonic()+1)
            end
        end
    end
    owned_test_capture() do capture
        CC.arm!(capture,exposure())
        fixture=capture_payload(Bool,2)
        GC.@preserve fixture begin
            initialize_payload!(fixture)
            fixture.memory .= UInt8[0,2]
            CC._read!(capture,capture.slots.validity,fixture.buffer)
            @test capture.failure===:boolean_encoding
        end
    end
    owned_test_capture() do capture
        CC.arm!(capture,exposure())
        @test_throws InvalidStateException CC.await!(capture;deadline=PipeWireAORTC.NativeControlClient.monotonic()+0.01)
        @test capture.failure===:deadline
    end
    owned_test_capture() do capture
        @test_throws ArgumentError CC.arm!(capture,(;identity=identity(),timestamp=AG.ModelTimestamp(typemax(Int64)),exposure_duration_nanoseconds=UInt64(1)))
    end
end

@testset "close wakes an active capture waiter without closing borrowed wakeups" begin
    owned_test_capture() do capture
        CC.arm!(capture,exposure())
        waiter=@async try
            CC.await!(capture;deadline=PipeWireAORTC.NativeControlClient.monotonic()+5)
        catch error
            error
        end
        yield()
        @test capture.waiting
        @test_throws InvalidStateException CC.await!(capture;deadline=PipeWireAORTC.NativeControlClient.monotonic()+1)
        close(capture)
        @test fetch(waiter) isa InvalidStateException
        @test !isopen(capture.wakeup)
    end
end

@testset "scientific rejection policy stays outside the collector" begin
    owned_test_capture() do capture
        CC.arm!(capture,exposure())
        fixture=capture_payload(Float32,2)
        GC.@preserve fixture begin
            initialize_payload!(fixture)
            fixture.memory .= reinterpret(UInt8,Float32[NaN,Inf])
            CC._read!(capture,capture.slots.flux,fixture.buffer)
            @test isequal(capture.slots.flux.array,Float32[NaN,Inf])
            @test capture.failure===:none
        end
    end
end
@test !any(id->id.name in ("CUDA","AMDGPU"),keys(Base.loaded_modules))
