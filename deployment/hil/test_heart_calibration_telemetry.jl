using Test
include("heart_calibration_telemetry.jl")
using .HeartCalibrationTelemetry

function put!(bytes, offset, value::T) where {T<:Integer}
    copyto!(bytes, offset + 1, reinterpret(UInt8, [htol(value)]), 1, sizeof(T))
end
put!(bytes, offset, value::Float32) = put!(bytes, offset, reinterpret(UInt32, value))
put!(bytes, offset, value::Float64) = put!(bytes, offset, reinterpret(UInt64, value))

function fixture(tag, datatype, rows, cols, element_bytes, payload;
    bucket=UInt64(0), sync=UInt32(1), state=Int16(2), revision=Int16(2),
)
    data_bytes = cld(rows * cols * element_bytes, 64) * 64
    bytes = zeros(UInt8, 1024 + 64 + data_bytes)
    copyto!(bytes, 1, codeunits(tag), 1, ncodeunits(tag))
    put!(bytes, 32, Float64(element_bytes))
    put!(bytes, 40, Int32(datatype))
    put!(bytes, 44, UInt32(16))
    put!(bytes, 48, UInt32(rows))
    put!(bytes, 52, UInt32(cols))
    put!(bytes, 56, UInt32(data_bytes))
    put!(bytes, 144, UInt64(1))
    put!(bytes, 1024, Int64(1_000_001))
    put!(bytes, 1024 + 16, bucket)
    put!(bytes, 1024 + 32, state)
    put!(bytes, 1024 + 34, revision)
    put!(bytes, 1024 + 36, Int16(4))
    put!(bytes, 1024 + 38, Int16(4))
    put!(bytes, 1024 + 44, sync)
    copyto!(bytes, 1089, payload, 1, length(payload))
    return bytes
end

function decode(bytes; tag, datatype, shape)
    mktemp() do path, io
        write(io, bytes)
        close(io)
        reader = TelemetryReader(path; tag, datatype, shape, maximum_bytes=UInt64(1_000_000))
        try
            frame = next_frame!(reader)
            @test next_frame!(reader) === nothing
            return frame
        finally
            close(reader)
        end
    end
end

@testset "bounded HEART telemetry publication" begin
    bytes = fixture("cbHoPixelsRaw0", 7, 2, 2, 2, reinterpret(UInt8, UInt16[1, 2, 3, 4]))
    frame = decode(bytes; tag="cbHoPixelsRaw0", datatype=7, shape=(2, 2))
    @test raw_pixels(frame) == UInt16[1, 2, 3, 4]
    @test (frame.bucket, frame.sync) == (0, 1)
    @test_throws ArgumentError decode(bytes; tag="cbHoGrad0", datatype=7, shape=(2, 2))
    wrong_revision = copy(bytes)
    put!(wrong_revision, 1024 + 34, Int16(3))
    @test_throws ArgumentError decode(wrong_revision; tag="cbHoPixelsRaw0", datatype=7, shape=(2, 2))
    wrong_size = copy(bytes)
    put!(wrong_size, 56, UInt32(16))
    @test_throws ArgumentError decode(wrong_size; tag="cbHoPixelsRaw0", datatype=7, shape=(2, 2))
    mktemp() do path, io
        write(io, bytes[1:end - 1])
        flush(io)
        reader = TelemetryReader(path; tag="cbHoPixelsRaw0", datatype=7, shape=(2, 2), maximum_bytes=UInt64(8192))
        @test next_frame!(reader) === nothing
        write(io, bytes[end:end])
        flush(io)
        @test raw_pixels(next_frame!(reader)) == UInt16[1, 2, 3, 4]
        @test_throws ArgumentError await_frame!(reader; timeout_ns=UInt64(1_000_000))
        close(reader)
        @test_throws ArgumentError next_frame!(reader)
    end
    mktemp() do path, io
        write(io, bytes)
        write(io, bytes[1025:end])
        flush(io)
        reader = TelemetryReader(path; tag="cbHoPixelsRaw0", datatype=7, shape=(2, 2), maximum_bytes=UInt64(8192))
        @test next_frame!(reader) isa TelemetryFrame
        seek(io, 144)
        write(io, htol(UInt64(2)))
        flush(io)
        @test_throws ArgumentError next_frame!(reader) # duplicated bucket
        close(reader)
    end
    mktemp() do path, io
        write(io, bytes)
        flush(io)
        reader = TelemetryReader(path; tag="cbHoPixelsRaw0", datatype=7, shape=(2, 2), maximum_bytes=UInt64(length(bytes)))
        write(io, UInt8(0))
        flush(io)
        @test_throws ArgumentError next_frame!(reader)
        close(reader)
    end
end

@testset "native WFS representation is explicit" begin
    records = zeros(UInt8, 188 * 16)
    for index in 1:188
        offset = 16(index - 1)
        put!(records, offset, Int32(1))
        put!(records, offset + 4, Float32(index))
        put!(records, offset + 8, Float32(-index))
        put!(records, offset + 12, Float32(100 + index))
    end
    frame = decode(fixture("cbHoGrad0", 13, 188, 1, 16, records);
        tag="cbHoGrad0", datatype=13, shape=(188, 1))
    response = classic_response(frame; order=collect(188:-1:1), scale=(2.0, -3.0), active=fill(true, 188))
    @test response.slopes[1:4] == Float32[376, 564, 374, 561]
    @test first(response.flux) == 288
    @test response.valid
    put!(records, 0, Int32(0))
    invalid = decode(fixture("cbHoGrad0", 13, 188, 1, 16, records);
        tag="cbHoGrad0", datatype=13, shape=(188, 1))
    @test !classic_response(invalid; order=collect(1:188), scale=(1.0, 1.0), active=fill(true, 188)).valid
    active = fill(true, 188)
    active[1] = false
    @test classic_response(invalid; order=collect(1:188), scale=(1.0, 1.0), active).valid
    @test_throws ArgumentError classic_response(frame; order=fill(1, 188), scale=(1.0, 1.0), active)
    @test_throws ArgumentError classic_response(frame; order=collect(1:188), scale=(0.0, 1.0), active)
    native_pixels = Float32.(1:3600) ./ 2000
    copper = decode(fixture("cbHoGrad0", 8, 3600, 1, 4, reinterpret(UInt8, native_pixels));
        tag="cbHoGrad0", datatype=8, shape=(3600, 1))
    @test copper_response(copper).pixels == native_pixels
    @test copper_response(copper).valid
    @test_throws ArgumentError classic_response(copper; order=collect(1:188), scale=(1.0, 1.0), active)
end

@testset "native DM physical units and clipping" begin
    requested = fill(0.02f0, 277)
    actual = copy(requested)
    actual[4] = 0.01f0
    frame = decode(fixture("cbDmCmd0", 20, 277, 1, 4, reinterpret(UInt8, actual); sync=UInt32(0));
        tag="cbDmCmd0", datatype=20, shape=(277, 1))
    receipt = Float32.(Float64.(actual) .* 1e-6)
    evidence = confirm_probe(frame, requested, receipt)
    @test evidence.clipped
    @test evidence.figure == actual
    @test evidence.native_sync == 0 # never invent a positive native probe ID
    @test !confirm_probe(frame, actual, receipt).clipped
    @test_throws ArgumentError confirm_probe(frame, requested, fill(0.02f0, 277))
end

@testset "one admitted exposure with independent native identity" begin
    first_raw = decode(fixture("cbHoPixelsRaw0", 7, 2, 2, 2, reinterpret(UInt8, UInt16[3, 4, 5, 6]));
        tag="cbHoPixelsRaw0", datatype=7, shape=(2, 2))
    first_measured = decode(fixture("cbHoGrad0", 8, 3600, 1, 4, reinterpret(UInt8, fill(1.0f0, 3600)));
        tag="cbHoGrad0", datatype=8, shape=(3600, 1))
    first_exposure = (; domain=UInt64(1), generation=UInt64(1), sequence=UInt64(1),
        start_model_ns=UInt64(0), duration_ns=UInt64(1_000_000))
    fresh = FrameAssociation()
    arm_exposure!(fresh, first_exposure, UInt16[3, 4, 5, 6])
    @test associate!(fresh, first_raw, first_measured).native_sync == 1
    raw_bytes = fixture("cbHoPixelsRaw0", 7, 2, 2, 2, reinterpret(UInt8, UInt16[3, 4, 5, 6]);
        bucket=UInt64(8), sync=UInt32(14))
    raw = decode(raw_bytes; tag="cbHoPixelsRaw0", datatype=7, shape=(2, 2))
    measured = decode(fixture("cbHoGrad0", 8, 3600, 1, 4, reinterpret(UInt8, fill(1.0f0, 3600));
        bucket=UInt64(22), sync=UInt32(14)); tag="cbHoGrad0", datatype=8, shape=(3600, 1))
    exposure = (; domain=UInt64(1), generation=UInt64(2), sequence=UInt64(1),
        start_model_ns=UInt64(0), duration_ns=UInt64(1_000_000))
    association = FrameAssociation(raw_bucket=UInt64(7), measurement_bucket=UInt64(21), native_sync=UInt32(13))
    arm_exposure!(association, exposure, UInt16[3, 4, 5, 6])
    @test_throws ArgumentError arm_exposure!(association, exposure, UInt16[3, 4, 5, 6])
    result = associate!(association, raw, measured)
    @test result.exposure == exposure
    @test result.native_sync == 14
    @test association.pending === nothing
    @test_throws ArgumentError arm_exposure!(association, exposure, UInt16[3, 4, 5, 6])
    next_exposure = merge(exposure, (; sequence=UInt64(2), start_model_ns=UInt64(1_000_000)))
    @test_throws ArgumentError arm_exposure!(association,
        merge(next_exposure, (; generation=UInt64(3))), UInt16[3, 4, 5, 6])
    @test_throws ArgumentError arm_exposure!(association,
        merge(next_exposure, (; start_model_ns=UInt64(0))), UInt16[3, 4, 5, 6])
    @test_throws ArgumentError arm_exposure!(association,
        merge(next_exposure, (; domain=UInt64(2))), UInt16[3, 4, 5, 6])
    @test_throws ArgumentError arm_exposure!(association,
        merge(next_exposure, (; duration_ns=UInt64(0))), UInt16[3, 4, 5, 6])
    bad = FrameAssociation(raw_bucket=UInt64(7), measurement_bucket=UInt64(21), native_sync=UInt32(13))
    arm_exposure!(bad, exposure, UInt16[9, 4, 5, 6])
    @test_throws ArgumentError associate!(bad, raw, measured)
    @test bad.faulted && bad.pending !== nothing
    @test_throws ArgumentError arm_exposure!(bad, exposure, UInt16[3, 4, 5, 6])
    wrong_sync = FrameAssociation(raw_bucket=UInt64(7), measurement_bucket=UInt64(21), native_sync=UInt32(12))
    arm_exposure!(wrong_sync, exposure, UInt16[3, 4, 5, 6])
    @test_throws ArgumentError associate!(wrong_sync, raw, measured)
end

@testset "retained native controller hold has exact WFS and DM counts" begin
    mktempdir() do directory
        function stream(tag, datatype, rows, bytes_per_element; dm=false)
            payload = zeros(UInt8, rows * bytes_per_element)
            first = fixture(tag, datatype, rows, 1, bytes_per_element, payload)
            # The WFS raw/calibrated contract is the native full detector shape.
            if rows == 4096
                put!(first, 48, UInt32(64)); put!(first, 52, UInt32(64))
            end
            second = copy(first[1025:end])
            put!(second, 16, UInt64(1))
            put!(first, 144, UInt64(2))
            put!(first, 1024 + 44, dm ? UInt32(0) : UInt32(1))
            put!(second, 44, dm ? UInt32(0) : UInt32(2))
            if tag == "cbHoPixelsCalib0"
                put!(first, 1024, Int64(0)); put!(second, 0, Int64(0))
            end
            path = joinpath(directory, "DATE_" * tag * "_RUN_TIME.tel")
            write(path, [first; second])
            return path
        end
        raw = stream("cbHoPixelsRaw0", 7, 4096, 2)
        cal = stream("cbHoPixelsCalib0", 8, 4096, 4)
        grad = stream("cbHoGrad0", 8, 3600, 4)
        dm = stream("cbDmCmd0", 20, 277, 4; dm=true)
        maximum = UInt64(100_000)
        @test HeartCalibrationTelemetry.verify_copper_counts(directory; frames=2, commands=2, maximum_bytes=maximum) ==
            Dict("cbHoPixelsRaw0"=>2, "cbHoPixelsCalib0"=>2, "cbHoGrad0"=>2, "cbDmCmd0"=>2)
        @test_throws ArgumentError HeartCalibrationTelemetry.verify_copper_counts(directory; frames=1, commands=2, maximum_bytes=maximum)
        original = read(grad)
        bad = copy(original); put!(bad, 1024 + 64 + 14400 + 44, UInt32(1)); write(grad, bad)
        @test_throws ArgumentError HeartCalibrationTelemetry.verify_copper_counts(directory; frames=2, commands=2, maximum_bytes=maximum)
        write(grad, original)
        bad = copy(original); put!(bad, 1024, Int64(0)); write(grad, bad)
        @test_throws ArgumentError HeartCalibrationTelemetry.verify_copper_counts(directory; frames=2, commands=2, maximum_bytes=maximum)
        write(grad, original)
        open(dm, "a") do io; write(io, UInt8(0)); end
        @test_throws ArgumentError HeartCalibrationTelemetry.verify_copper_counts(directory; frames=2, commands=2, maximum_bytes=maximum)
    end
end
