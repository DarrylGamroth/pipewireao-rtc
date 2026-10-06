module NativeHeartCodecTests

using Test
using PipeWireAO
using PipeWireAODeployment

if !isdefined(PipeWireAODeployment, :NativeHeartCodec)
    Base.include(PipeWireAODeployment,
        joinpath(dirname(@__DIR__), "src", "native_heart_codec.jl"))
end

const Heart = PipeWireAODeployment.NativeHeartCodec
const Client = PipeWireAODeployment.NativeControlClient
const Envelope = PipeWireAODeployment.NativeControlCodec
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod
const identity = Envelope.ControllerIdentity(UInt32(7), UInt64(9), Int64(11))
request_header(op; token=Int64(op)) = Envelope.RequestHeader(identity, Int64(42), token, UInt32(op), Int64(1_000_000))
reply_header(op; result::Int32=Int32(0)) = Envelope.ReplyHeader(identity, Int64(42), Int64(op), UInt32(op), result)
ps(xs...) = SPA.Struct(Pod[xs...])
id(x) = Pod(SPA.Id(UInt32(x)))

@testset "native HEART typed profile" begin
    @test Client.profile_name(Heart.HEART_PROFILE) == "pipewireao.rtc.heart/1"
    @test Client.maximum_budget(Heart.HEART_PROFILE) == 30.0
    @test Client.capability_names(Heart.HEART_PROFILE) == (
        "pipewireao.rtc.heart.version", "pipewireao.rtc.heart.instance",
        "pipewireao.rtc.heart.owner-pid", "pipewireao.rtc.heart.lifecycle",
        "pipewireao.rtc.heart.last-token", "pipewireao.rtc.heart.controllers")

    @testset "exact HEART operation requests" begin
        for (op, command) in ((1, Heart.HeartCommand{:status}()), (2, Heart.HeartCommand{:reset}()),
                (3, Heart.HeartCommand{:connect}()), (4, Heart.HeartCommand{:shutdown}()))
            bytes = Client.encode_request(Heart.HEART_PROFILE, request_header(op), command)
            header, payload = Envelope.decode_request(bytes)
            @test header.operation == op
            @test isempty(payload.values)
            @test Client.decode_request(Heart.HEART_PROFILE, bytes)[2] == command
        end
        @test_throws ArgumentError Heart.HeartCommand(:launch)
        @test_throws ArgumentError Client.encode_request(Heart.HEART_PROFILE,
            request_header(1), Heart.HeartCommand{:reset}())
        @test_throws ArgumentError Client.decode_request(Heart.HEART_PROFILE,
            request_header(5), SPA.Struct())
        @test_throws ArgumentError Client.decode_request(Heart.HEART_PROFILE,
            request_header(1), ps(Pod(Int32(1))))
        @test_throws ArgumentError Client.operation_id(Heart.HEART_PROFILE, Heart.HeartCommand{:launch}())
    end

    @testset "typed snapshot and completion" begin
        snapshot = Heart.HeartSnapshot(Int64(4), typemax(UInt32), nothing, true,
            Heart.Streaming, true, true, "/tmp/heart-report.json", repeat("a", 64))
        bytes = Client.encode_completion(Heart.HEART_PROFILE, reply_header(1),
            Heart.Ready, snapshot, "healthy")
        reply = Client.decode_completion(Heart.HEART_PROFILE, bytes)
        @test reply.lifecycle === Heart.Ready
        @test reply.snapshot == snapshot
        @test reply.message == "healthy"

        preparing = Heart.HeartSnapshot(Int64(0), nothing, nothing, false,
            Heart.Deferred, false, false, "", "")
        @test Client.decode_completion(Heart.HEART_PROFILE,
            Client.encode_completion(Heart.HEART_PROFILE, reply_header(1),
                Heart.Preparing, preparing, "starting")).snapshot == preparing
        stopped = Heart.HeartSnapshot(Int64(3), UInt32(45), Int32(1), false,
            Heart.Deferred, true, true, "/report", "c"^64)
        @test Client.decode_completion(Heart.HEART_PROFILE,
            Client.encode_completion(Heart.HEART_PROFILE, reply_header(2),
                Heart.Stopped, stopped, "exited")).snapshot == stopped
        @test_throws ArgumentError Heart.HeartSnapshot(Int64(-1), nothing, nothing,
            false, Heart.Streaming, false, false, "", "")
        @test_throws ArgumentError Heart.HeartSnapshot(Int64(0), UInt32(0), nothing,
            false, Heart.Streaming, false, false, "", "")
        @test_throws ArgumentError Heart.HeartSnapshot(Int64(0), nothing, nothing,
            false, Heart.Streaming, false, false, "x"^4097, "")
        @test_throws ArgumentError Heart.HeartSnapshot(Int64(0), nothing, nothing,
            false, Heart.Streaming, false, false, "", "A"^64)
        @test_throws ArgumentError Client.encode_completion(Heart.HEART_PROFILE,
            reply_header(1), Heart.Ready, preparing, "bad ready")
        @test_throws ArgumentError Client.encode_completion(Heart.HEART_PROFILE,
            reply_header(1), Heart.Preparing, preparing, "x"^8193)
    end

    @testset "strict POD type, width, arity and lifecycle checks" begin
        valid_snapshot = Heart.HeartSnapshot(Int64(1), UInt32(42), nothing, true,
            Heart.Streaming, true, true, "/report", "b"^64)
        payload(fields...) = ps(fields...)
        @test_throws ArgumentError Client.decode_completion(Heart.HEART_PROFILE,
            Envelope.encode_completion(reply_header(1), payload(id(2)); endpoint=:lifecycle))
        wrong_float = ps(Pod(reinterpret(Float32, Int32(1))), Pod(SPA.Struct()), Pod(""))
        @test_throws ArgumentError Client.decode_completion(Heart.HEART_PROFILE,
            Envelope.encode_completion(reply_header(1), wrong_float; endpoint=:lifecycle))
        snapshot_fields = Heart._fields(Heart._snapshot_pod(valid_snapshot))
        snapshot_fields[1] = Pod(Float32(1))
        wrong_generation = ps(id(2), Pod(ps(snapshot_fields...)), Pod(""))
        @test_throws ArgumentError Client.decode_completion(Heart.HEART_PROFILE,
            Envelope.encode_completion(reply_header(1), wrong_generation; endpoint=:lifecycle))
        unknown_lifecycle = ps(id(99), Pod(Heart._snapshot_pod(valid_snapshot)), Pod(""))
        @test_throws ArgumentError Client.decode_completion(Heart.HEART_PROFILE,
            Envelope.encode_completion(reply_header(1), unknown_lifecycle; endpoint=:lifecycle))
        wrong_snapshot_arity = ps(id(2), Pod(ps(Pod(Int64(0)))), Pod(""))
        @test_throws ArgumentError Client.decode_completion(Heart.HEART_PROFILE,
            Envelope.encode_completion(reply_header(1), wrong_snapshot_arity; endpoint=:lifecycle))
        bad_pid_fields = copy(snapshot_fields)
        bad_pid_fields[2] = Pod(Int32(42))
        wrong_pid_type = ps(id(2), Pod(ps(bad_pid_fields...)), Pod(""))
        @test_throws ArgumentError Client.decode_completion(Heart.HEART_PROFILE,
            Envelope.encode_completion(reply_header(1), wrong_pid_type; endpoint=:lifecycle))
    end

    @testset "rejection and failure completion" begin
        rejected = Client.decode_rejection(Heart.HEART_PROFILE,
            Client.encode_rejection(Heart.HEART_PROFILE, reply_header(1; result=Int32(-22)), Heart.Ready))
        @test rejected.lifecycle === Heart.Ready
        @test rejected.message == "request rejected"
        unknown_request = Envelope.RequestHeader(identity, Int64(42), Int64(8),
            UInt32(999), Int64(1_000_000))
        @test sizeof(Envelope.encode_request(unknown_request, SPA.Struct())) <= 16 * 1024
        @test_throws ArgumentError Client.decode_request(Heart.HEART_PROFILE,
            Envelope.encode_request(unknown_request, SPA.Struct()))
        unknown_header = Envelope.ReplyHeader(identity, Int64(42), Int64(8),
            UInt32(999), Int32(-22))
        unknown_bytes = Client.encode_rejection(Heart.HEART_PROFILE, unknown_header, Heart.Ready)
        @test sizeof(unknown_bytes) <= Envelope._limit(Val(:reply), :lifecycle)
        unknown = Client.decode_rejection(Heart.HEART_PROFILE, unknown_bytes)
        @test unknown.header.operation == 999
        @test unknown.lifecycle === Heart.Ready

        sentinel_header = Envelope.ReplyHeader(Int64(42), Int32(-22))
        sentinel = Client.encode_rejection(Heart.HEART_PROFILE, sentinel_header, Heart.Preparing)
        initial = Client.decode_rejection(Heart.HEART_PROFILE, sentinel)
        @test initial.header.controller === nothing
        @test initial.header.operation == 0
        observation = Client.Observation(Heart.HEART_PROFILE, Int64(42), UInt32(123))
        Client.observe!(observation, sentinel)
        @test observation.failure === nothing
        @test observation.fatal_failure === nothing
        @test observation.rejection.value.header.controller === nothing
        failed = Client.decode_completion(Heart.HEART_PROFILE,
            Client.encode_failure(Heart.HEART_PROFILE, reply_header(1; result=Int32(-22)), Heart.Ready))
        @test failed.lifecycle === Heart.Ready
        @test failed.snapshot === nothing
        @test failed.message == "request expired or controller removed"
        @test_throws ArgumentError Client.encode_completion(Heart.HEART_PROFILE,
            reply_header(1), Heart.Ready, nothing, "")
        @test_throws ArgumentError Client.decode_completion(Heart.HEART_PROFILE,
            Envelope.encode_completion(reply_header(1),
                ps(id(2), Pod(nothing), Pod("")); endpoint=:lifecycle))
    end
end

end # module NativeHeartCodecTests
