module NativeAcquisitionLifecycleCodecTests

using Test
using PipeWireAO
using PipeWireAODeployment

const Codec = PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const Client = PipeWireAODeployment.NativeControlClient
const Envelope = PipeWireAODeployment.NativeControlCodec
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod
const identity = Envelope.ControllerIdentity(UInt32(7), typemax(UInt64), Int64(11))
request(op) = Envelope.RequestHeader(identity, Int64(42), Int64(op), UInt32(op), Int64(1_000_000))
reply(op; result=Int32(0)) = Envelope.ReplyHeader(identity, Int64(42), Int64(op), UInt32(op), result)
ps(fields...) = SPA.Struct(Pod[fields...])
id(value) = Pod(SPA.Id(UInt32(value)))

@testset "native acquisition lifecycle profiles" begin
    @test "held" in Codec._phases(Codec.CALIBRATION_PROFILE)
    @test !("held" in Codec._phases(Codec.CORRECTION_PROFILE))
    @test "correcting" in Codec._phases(Codec.CORRECTION_PROFILE)
    @test !("correcting" in Codec._phases(Codec.CALIBRATION_PROFILE))
    for (profile, prefix, phase, window) in ((Codec.CALIBRATION_PROFILE,
            "pipewireao.rtc.calibration-lifecycle", "held", nothing),
            (Codec.CORRECTION_PROFILE, "pipewireao.rtc.correction-lifecycle", "correcting", UInt64(2)))
        @test Client.profile_name(profile) == prefix * "/1"
        @test Client.capability_names(profile) == Tuple(prefix * "." * suffix for suffix in
            ("version", "instance", "owner-pid", "lifecycle", "last-token", "controllers"))
        @test Client.reply_endpoint(profile) == :lifecycle
        @test Client.lifecycle_type(profile) == Codec.ColdLifecycle

        cursor = Codec.AcquisitionCursor(typemax(UInt64), UInt64(1) << 63,
            typemax(UInt64), UInt64(1) << 63)
        report_cursor = Codec.AcquisitionCursor(UInt64(1) << 63, typemax(UInt64),
            UInt64(1) << 63, typemax(UInt64))
        snapshot = Codec.Snapshot(Codec.Copper, cursor, report_cursor,
            false, true, phase, true, false, window)
        for (op, name) in enumerate((:status, :pause, :resume, :reset, :connect, :shutdown))
            command = Codec.LifecycleCommand(name)
            bytes = Client.encode_request(profile, request(op), command)
            @test sizeof(bytes) <= 16 * 1024
            @test isempty(Envelope.decode_request(bytes)[2].values)
            @test Client.decode_request(profile, bytes)[2] == command
            completion = Client.encode_completion(profile, reply(op), Codec.Connected, snapshot, "ok")
            @test sizeof(completion) <= 64 * 1024
            decoded = Client.decode_completion(profile, completion)
            @test decoded.header.operation == UInt32(op)
            @test decoded.snapshot.cursor == cursor
            @test decoded.snapshot.report_cursor == report_cursor
            @test decoded.snapshot.window == window
            @test decoded.snapshot.phase == phase
        end
        preparing = Codec.Snapshot(Codec.Classic, nothing, nothing, false, false, "initial",
            false, false, nothing)
        @test Client.decode_completion(profile,
            Client.encode_completion(profile, reply(1), Codec.Preparing, preparing, "")).snapshot == preparing
        @test Client.decode_completion(profile,
            Client.encode_completion(profile, reply(1), Codec.Prepared, preparing, "")).snapshot == preparing
        failed = Client.decode_completion(profile,
            Client.encode_failure(profile, reply(1; result=Int32(-22)), Codec.Fault))
        @test failed.snapshot === nothing
        @test failed.message == "request expired or controller removed"
        rejected = Client.decode_rejection(profile,
            Client.encode_rejection(profile, reply(1; result=Int32(-22)), Codec.Fault))
        @test rejected.lifecycle == Codec.Fault
        @test rejected.message == "request rejected"
        @test_throws ArgumentError Client.encode_completion(profile, reply(1), Codec.Fault, nothing, "")
        @test_throws ArgumentError Client.decode_completion(profile,
            Envelope.encode_completion(reply(1), ps(id(4), Pod(nothing), Pod("")); endpoint=:lifecycle))
        @test_throws ArgumentError Client.encode_request(profile, request(1), Codec.LifecycleCommand(:pause))
        @test_throws ArgumentError Client.decode_request(profile, request(1), ps(id(1)))
        @test_throws ArgumentError Client.decode_request(profile, request(7), ps())
        @test_throws ArgumentError Client.operation_id(profile, Codec.LifecycleCommand{:unknown}())
    end

    @test_throws ArgumentError Codec.LifecycleCommand(:unknown)
    @test_throws ArgumentError Codec.Snapshot(Codec.Classic, nothing, nothing, true, true,
        "initial", false, false, nothing)
    @test_throws ArgumentError Codec.Snapshot(Codec.Classic, nothing, nothing, false, false,
        "x"^65, false, false, nothing)
    @test_throws ArgumentError Codec.Snapshot(Codec.Classic, nothing, nothing, false, false,
        "héld", false, false, nothing)
    @test_throws ArgumentError Client.encode_completion(Codec.CALIBRATION_PROFILE,
        reply(1), Codec.Connected, Codec.Snapshot(Codec.Classic, nothing, nothing, false, false,
            "held", true, false, nothing), "")
    @test_throws ArgumentError Client.encode_completion(Codec.CALIBRATION_PROFILE,
        reply(1), Codec.Connected, Codec.Snapshot(Codec.Classic,
            Codec.AcquisitionCursor(0, 0, 0, 0), nothing, false, false, "held", true, false, nothing), "")
    @test_throws ArgumentError Client.encode_completion(Codec.CALIBRATION_PROFILE,
        reply(1), Codec.Connected, Codec.Snapshot(Codec.Classic,
            Codec.AcquisitionCursor(1, 1, 0, 0), nothing, false, false, "held", true, false, UInt64(1)), "")
    @test_throws ArgumentError Client.encode_completion(Codec.CORRECTION_PROFILE,
        reply(1), Codec.Connected, Codec.Snapshot(Codec.Classic,
            Codec.AcquisitionCursor(1, 1, 0, 0), nothing, false, false, "initial", true, false, UInt64(0)), "")
    @test_throws ArgumentError Client.encode_completion(Codec.CORRECTION_PROFILE,
        reply(1), Codec.Connected, Codec.Snapshot(Codec.Classic,
            Codec.AcquisitionCursor(1, 1, 0, 0), nothing, false, false, "held", true, false, UInt64(1)), "")

    valid = Codec.Snapshot(Codec.Classic, Codec.AcquisitionCursor(1, 1, 0, 0), nothing,
        false, false, "held", true, false, nothing)
    @test Codec._validate_window(Codec.CALIBRATION_PROFILE, Codec.Connected, valid) === nothing
    correction_initial = Codec.Snapshot(Codec.Classic, nothing, nothing,
        false, false, "initial", false, false, nothing)
    @test Codec._validate_window(Codec.CORRECTION_PROFILE, Codec.Prepared, correction_initial) === nothing
    @test_throws ArgumentError Codec._validate_window(Codec.CORRECTION_PROFILE,
        Codec.Connected, correction_initial)
    @test Client.decode_completion(Codec.CALIBRATION_PROFILE,
        Client.encode_completion(Codec.CALIBRATION_PROFILE, reply(1),
            Codec.Connected, valid, "")).snapshot.report_cursor === nothing
    fields = Codec._fields(Codec._snapshot_pod(valid))
    badcases = (ps(id(3)), ps(id(99), Pod(Codec._snapshot_pod(valid)), Pod("")),
        ps(id(3), Pod(ps(fields[1:7]...)), Pod("")))
    for body in badcases
        @test_throws ArgumentError Client.decode_completion(Codec.CALIBRATION_PROFILE,
            Envelope.encode_completion(reply(1), body; endpoint=:lifecycle))
    end
    @test_throws ArgumentError Client.decode_completion(Codec.CORRECTION_PROFILE,
        Envelope.encode_completion(reply(1),
            ps(id(3), Pod(Codec._snapshot_pod(valid)), Pod("")); endpoint=:lifecycle))
    @test_throws ArgumentError Client.decode_completion(Codec.CALIBRATION_PROFILE,
        Envelope.encode_completion(Envelope.ReplyHeader(identity, Int64(42), Int64(1),
            UInt32(99), Int32(0)), ps(id(3), Pod(Codec._snapshot_pod(valid)), Pod(""));
            endpoint=:lifecycle))
    for (index, replacement) in ((1, Pod(Int32(1))), (1, id(99)),
            (4, Pod(Int32(0))),
            (6, Pod("x"^65)), (9, Pod(Int64(1))))
        altered = copy(fields)
        altered[index] = replacement
        @test_throws ArgumentError Client.decode_completion(Codec.CALIBRATION_PROFILE,
            Envelope.encode_completion(reply(1),
                ps(id(3), Pod(ps(altered...)), Pod("")); endpoint=:lifecycle))
    end
    cursor_fields = Codec._fields(Codec._cursor_pod(valid.cursor))
    for (index, replacement) in ((1, Pod(Int32(1))), (4, Pod(SPA.Id(UInt32(1)))))
        altered_cursor = copy(cursor_fields)
        altered_cursor[index] = replacement
        altered = copy(fields)
        altered[2] = Pod(ps(altered_cursor...))
        @test_throws ArgumentError Client.decode_completion(Codec.CALIBRATION_PROFILE,
            Envelope.encode_completion(reply(1),
                ps(id(3), Pod(ps(altered...)), Pod("")); endpoint=:lifecycle))
    end
    altered = copy(fields)
    altered[2] = Pod(ps(cursor_fields[1:3]...))
    @test_throws ArgumentError Client.decode_completion(Codec.CALIBRATION_PROFILE,
        Envelope.encode_completion(reply(1), ps(id(3), Pod(ps(altered...)), Pod("")); endpoint=:lifecycle))
    altered = copy(fields)
    altered[3] = Pod(ps(Pod(Int32(1)), cursor_fields[2:4]...))
    @test_throws ArgumentError Client.decode_completion(Codec.CALIBRATION_PROFILE,
        Envelope.encode_completion(reply(1), ps(id(3), Pod(ps(altered...)), Pod("")); endpoint=:lifecycle))
    @test_throws ArgumentError Client.encode_completion(Codec.CALIBRATION_PROFILE,
        reply(1), Codec.Connected, valid, "x"^8193)
    @test_throws ArgumentError Client.decode_request(Codec.CALIBRATION_PROFILE,
        fill(UInt8(0), 16 * 1024 + 1))
    @test_throws ArgumentError Client.decode_completion(Codec.CALIBRATION_PROFILE,
        fill(UInt8(0), 64 * 1024 + 1))
end

end # module NativeAcquisitionLifecycleCodecTests
