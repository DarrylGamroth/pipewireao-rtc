module NativeCalibrationActionCodecTests
using Test, PipeWireAO, PipeWireAODeployment
const Codec = PipeWireAODeployment.NativeCalibrationActionCodec
const Client = PipeWireAODeployment.NativeControlClient
const Envelope = PipeWireAODeployment.NativeControlCodec
const Lifecycle = PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod
const profile = Codec.PROFILE
const identity = Envelope.ControllerIdentity(UInt32(7), typemax(UInt64), Int64(11))
request(op) = Envelope.RequestHeader(identity, Int64(42), Int64(op), UInt32(op), typemax(Int64))
reply(op; result=Int32(0)) = Envelope.ReplyHeader(identity, Int64(42), Int64(op), UInt32(op), result)
const cursor = Codec.AcquisitionCursor(typemax(UInt64), UInt64(1)<<63, typemax(UInt64), UInt64(typemax(Int64)))
const exposure = Codec.Exposure(typemax(UInt64), UInt64(1)<<63, typemax(UInt64), UInt64(1)<<63, UInt64(typemax(Int64)))
ps(fields...) = SPA.Struct(Pod[fields...])
id(value) = Pod(SPA.Id(UInt32(value)))
long(value) = Pod(reinterpret(Int64, UInt64(value)))
const fixture_dir = normpath(joinpath(@__DIR__, "../../../tests/fixtures/native-calibration-actions"))
function fixture(name, pod)
    bytes = pod.data
    @test bytes == read(joinpath(fixture_dir, name * ".pod"))
end
function bad_request(name, op, args; run=typemax(UInt64), serial=UInt64(1)<<63)
    pod = Envelope.encode_request(request(op), ps(long(run), long(serial), Pod(args)))
    fixture("bad-request-" * name, pod)
    @test_throws ArgumentError Client.decode_request(profile, pod)
end
function bad_reply(name, op, result; lifecycle=UInt32(3))
    pod = Envelope.encode_completion(reply(op), ps(id(lifecycle), long(typemax(UInt64)), long(UInt64(1)<<63), Pod(result), Pod("")); endpoint=:calibration)
    fixture("bad-reply-" * name, pod)
    @test_throws ArgumentError Client.decode_completion(profile, pod)
end
@testset "native calibration action codec" begin
    @test Client.profile_name(profile) == "pipewireao.rtc.calibration-actions/1"
    @test Client.reply_endpoint(profile) == :calibration
    @test Client.lifecycle_type(profile) === Lifecycle.ColdLifecycle
    for value in (UInt64(1), UInt64(typemax(Int64)), UInt64(1)<<63, typemax(UInt64))
        command = Codec.Command(value, value, Codec.Hold())
        decoded = Client.decode_request(profile, Client.encode_request(profile, request(1), command))[2]
        @test decoded.run == value && decoded.serial == value
    end
    @test_throws ArgumentError Client.encode_completion(profile, reply(1), reinterpret(Lifecycle.ColdLifecycle, UInt32(99)), UInt64(1), UInt64(1), Codec.Held(cursor), "")
    @test_throws ArgumentError Client.encode_completion(profile, reply(1), Lifecycle.Fault, UInt64(1), UInt64(1), Codec.Failed(reinterpret(Codec.FailureReason, UInt32(99))), "")
    actions = ("hold"=>Codec.Hold(), "adopt"=>Codec.Adopt(UInt32(16383), Float32[0.0, -0.0, 1.25]),
        "settle-immediate"=>Codec.Settle(UInt32(0), cursor, Codec.Immediate()),
        "settle-discard"=>Codec.Settle(UInt32(1), cursor, Codec.DiscardExposures(UInt32(4096))),
        "settle-model"=>Codec.Settle(UInt32(2), cursor, Codec.ModelTime(UInt64(typemax(Int64)))),
        "collect"=>Codec.Collect(UInt32(16383), cursor, UInt32(131072), UInt32(4096)),
        "capture"=>Codec.Capture(UInt32(16383), cursor, UInt32(4096)),
        "restore"=>Codec.Restore(Float32[1.0, -1.0], Codec.Immediate()), "release"=>Codec.Release())
    for (name, action) in actions
        command = Codec.Command(typemax(UInt64), UInt64(1)<<63, action)
        op = Client.operation_id(profile, command)
        pod = Client.encode_request(profile, request(op), command)
        fixture("request-" * name, pod)
        header, decoded = Client.decode_request(profile, pod)
        @test header.operation == op
        @test decoded.run == command.run && decoded.serial == command.serial
        @test Client.encode_request(profile, header, decoded).data == pod.data
        @test Codec._preflight(command) == sizeof(pod)
    end
    results = ("held"=>Codec.Held(cursor), "adopted"=>Codec.Adopted(cursor, Float32[0.0,-0.0,1.25], false),
        "settled"=>Codec.Settled(cursor), "responses"=>Codec.Responses(Float32[1.0,-1.0], [exposure], false),
        "captured"=>Codec.Captured(cursor, "run-1/manifest.json", "a"^64, UInt32(4096), typemax(UInt64), UInt64(1)<<63),
        "restored"=>Codec.Restored(Float32[1.0,-1.0], true), "released"=>Codec.Released())
    for (op, (name, result)) in enumerate(results)
        pod = Client.encode_completion(profile, reply(op), Lifecycle.Connected, typemax(UInt64), UInt64(1)<<63, result, "ok")
        fixture("reply-" * name, pod)
        decoded = Client.decode_completion(profile, pod)
        @test decoded.run == typemax(UInt64) && decoded.serial == UInt64(1)<<63
        @test Client.encode_completion(profile, decoded.header, decoded.lifecycle, decoded.run, decoded.serial, decoded.result, decoded.message).data == pod.data
        @test Codec._completion_size(Codec._result_size(result), 2) == sizeof(pod)
    end
    for reason in (Codec.Cancelled, Codec.Endpoint, Codec.InvalidEvidence, Codec.ProbeClipped)
        pod = Client.encode_completion(profile, reply(4), Lifecycle.Fault, typemax(UInt64), UInt64(1)<<63, Codec.Failed(reason), "")
        fixture("reply-failed-" * string(UInt32(reason)), pod)
        @test Client.decode_completion(profile, pod).result.reason === reason
    end
    negative = Client.encode_completion(profile, reply(4; result=Int32(-22)), Lifecycle.Fault, typemax(UInt64), UInt64(1)<<63, nothing, "expired")
    fixture("reply-negative", negative)
    @test Client.decode_completion(profile, negative).result === nothing
    rejection = Client.encode_rejection(profile, reply(4; result=Int32(-22)), Lifecycle.Prepared, "rejected")
    fixture("rejection", rejection)
    @test Client.decode_rejection(profile, rejection).message == "rejected"

    bad_request("hold-arity", 1, ps(id(1)))
    bad_request("unknown-operation", 8, ps())
    bad_request("zero-run", 1, ps(); run=UInt64(0))
    bad_request("adopt-child", 2, ps(id(1), Pod(SPA.Array(Int32[1]))))
    bad_request("adopt-nonfinite", 2, ps(id(1), Pod(SPA.Array(Float32[NaN]))))
    bad_request("adopt-probe", 2, ps(id(16384), Pod(SPA.Array(Float32[1]))))
    bad_request("cursor-model", 5, ps(id(1), Pod(Lifecycle._cursor_pod(Codec.AcquisitionCursor(1,1,0,typemax(UInt64)))), id(1)))
    bad_request("rule-unknown", 3, ps(id(1), Pod(Lifecycle._cursor_pod(cursor)), Pod(ps(id(4)))))
    bad_request("rule-arity", 3, ps(id(1), Pod(Lifecycle._cursor_pod(cursor)), Pod(ps(id(1), id(1)))))
    bad_request("rule-duration", 3, ps(id(1), Pod(Lifecycle._cursor_pod(cursor)), Pod(ps(id(3),long(typemax(UInt64))))))
    bad_reply("wrong-result", 1, ps(id(7)))
    bad_reply("unknown-result", 1, ps(id(9)))
    bad_reply("wrong-arity", 1, ps(id(1)))
    bad_reply("lifecycle", 1, ps(id(1), Pod(Lifecycle._cursor_pod(cursor))); lifecycle=UInt32(99))
    bad_reply("failure-reason", 1, ps(id(8),id(5)))
    bad_reply("float-child", 4, ps(id(4),Pod(SPA.Array(Int32[1])),Pod(SPA.Array(Int64[1,1,1,1,1])),Pod(true)))
    bad_reply("nonfinite", 4, ps(id(4),Pod(SPA.Array(Float32[Inf])),Pod(SPA.Array(Int64[1,1,1,1,1])),Pod(true)))
    bad_reply("exposure-arity", 4, ps(id(4),Pod(SPA.Array(Float32[1])),Pod(SPA.Array(Int64[1,1,1,1])),Pod(true)))
    bad_reply("exposure-overflow", 4, ps(id(4),Pod(SPA.Array(Float32[1])),Pod(SPA.Array(Int64[1,1,1,-1,1])),Pod(true)))
    bad_reply("exposure-duration", 4, ps(id(4),Pod(SPA.Array(Float32[1])),Pod(SPA.Array(Int64[1,1,1,0,0])),Pod(true)))
    bad_reply("exposure-child", 4, ps(id(4),Pod(SPA.Array(Float32[1])),Pod(SPA.Array(Float32[1,1,1,1,1])),Pod(true)))
    for manifest in ("/absolute", "../escape", "a/../escape", "a//b", "a\\b", "")
        result = Codec.Captured(cursor, manifest, "a"^64, UInt32(1), UInt64(1), UInt64(1))
        @test_throws ArgumentError Client.encode_completion(profile, reply(5), Lifecycle.Connected, UInt64(1), UInt64(1), result, "")
    end
    @test_throws ArgumentError Client.encode_completion(profile, reply(5), Lifecycle.Connected, UInt64(1), UInt64(1), Codec.Captured(cursor,"manifest", "A"^64, UInt32(1), UInt64(1), UInt64(1)), "")
    @test_throws ArgumentError Client.encode_completion(profile, reply(1), Lifecycle.Connected, UInt64(1), UInt64(1), nothing, "")
    @test_throws ArgumentError Client.encode_completion(profile, reply(1), Lifecycle.Connected, UInt64(1), UInt64(1), Codec.Held(cursor), "x"^8193)
    @test_throws ArgumentError Client.encode_request(profile, request(1), Codec.Command(UInt64(1),UInt64(1),Codec.Release()))
    @test_throws ArgumentError Client.encode_request(profile, request(2), Codec.Command(UInt64(1),UInt64(1),Codec.Adopt(UInt32(0),zeros(Float32,4096))))
    max_figure = findlast(n -> Codec._envelope_base(:request) + 32 + 24 + Codec._array_size(n,4) <= 16384, 1:4096)
    full_command = Codec.Command(UInt64(1),UInt64(1),Codec.Adopt(UInt32(0),zeros(Float32,max_figure)))
    @test sizeof(Client.encode_request(profile, request(2), full_command)) == 16384
    @test length(Client.decode_request(profile, Client.encode_request(profile, request(2), full_command))[2].action.figure) == max_figure
    @test_throws ArgumentError Client.encode_request(profile, request(2), Codec.Command(UInt64(1),UInt64(1),Codec.Adopt(UInt32(0),zeros(Float32,max_figure+1))))
    @test_throws ArgumentError Client.decode_request(profile, zeros(UInt8,16385))
    @test_throws ArgumentError Client.decode_completion(profile, zeros(UInt8,131073))
    @test_throws ArgumentError Codec.preflight_collect_reply(131072,4096)
    @test_throws ArgumentError Codec.preflight_collect_reply(1,4096)
    for (m,n) in ((1,1),(376,409),(3600,100),(32000,1))
        result = Codec.Responses(zeros(Float32,m),fill(exposure,n),true)
        pod = Client.encode_completion(profile,reply(4),Lifecycle.Connected,UInt64(1),UInt64(1),result,"")
        @test sizeof(pod) == Codec.preflight_collect_reply(m,n)
    end
    max_m = findlast(m -> Codec.collect_reply_size(m,1) <= 131072, 1:131072)
    @test Codec.preflight_collect_reply(max_m,1) == 131072
    @test_throws ArgumentError Codec.preflight_collect_reply(max_m+1,1)
    @test_throws ArgumentError Client.encode_completion(profile, reply(4), Lifecycle.Connected, UInt64(1), UInt64(1), Codec.Responses(zeros(Float32,max_m+1),[exposure],true), "")
end
end
