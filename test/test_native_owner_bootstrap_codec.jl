module NativeOwnerBootstrapCodecTests
using Test, PipeWireAO, PipeWireAODeployment
const C = PipeWireAODeployment.NativeOwnerBootstrapCodec
const Client = PipeWireAODeployment.NativeControlClient
const E = PipeWireAODeployment.NativeControlCodec
const B = PipeWireAODeployment.NativeOwnerBootstrapClient
const SPA = PipeWireAO.SPA
identity = E.ControllerIdentity(UInt32(7), typemax(UInt64), Int64(9))
request(op) = E.RequestHeader(identity, typemax(Int64), Int64(op), UInt32(op), Int64(1_000_000))
reply(op; result=Int32(0)) = E.ReplyHeader(identity, typemax(Int64), Int64(op), UInt32(op), result)
ps(fields...) = SPA.Struct(Pod[fields...])
id(value) = Pod(SPA.Id(UInt32(value)))
@testset "ordinary native bootstrap codec" begin
    @test Client.profile_name(C.PROFILE) == "pipewireao.rtc.owner-bootstrap/1"
    @test Client.lifecycle_type(C.PROFILE) == C.Lifecycle
    @test Client.reply_bound(C.PROFILE) == 64*1024
    for (op, name, phase) in ((1, :status, C.Preparing), (2, :connect, C.Connected), (3, :quit, C.Stopped))
        command = C.Command(name)
        encoded = Client.encode_request(C.PROFILE, request(op), command)
        header, decoded = Client.decode_request(C.PROFILE, encoded)
        @test header.controller.serial == typemax(UInt64)
        @test header.endpoint_instance == typemax(Int64)
        @test decoded == command
        @test isempty(E.decode_request(encoded)[2].values)
        @test sizeof(encoded) < 16*1024
        for result in (Int32(0), Int32(-110))
            completion = Client.encode_completion(C.PROFILE, reply(op; result), phase, "ok")
            value = Client.decode_completion(C.PROFILE, completion)
            @test value.lifecycle == phase && value.message == "ok" && value.header.result == result
            @test length(E.decode_completion(completion)[2].values) == 2
        end
        value = Client.decode_rejection(C.PROFILE, Client.encode_rejection(C.PROFILE, reply(op; result=Int32(-16)), C.Prepared))
        @test value.lifecycle === C.Prepared && value.header.result == -16
        @test Client.decode_completion(C.PROFILE, Client.encode_failure(C.PROFILE, reply(op; result=Int32(-110)), C.Fault)).lifecycle === C.Fault
        @test_throws ArgumentError Client.decode_request(C.PROFILE, request(op), ps(Pod(false)))
    end
    for phase in (C.Preparing,C.Prepared,C.Connected,C.Fault,C.Stopped)
        @test Client.decode_completion(C.PROFILE, Client.encode_completion(C.PROFILE, reply(1), phase, "")).lifecycle === phase
    end
    @test_throws ArgumentError C.Command(:pause)
    @test_throws ArgumentError Client.operation_id(C.PROFILE, C.Command{:unknown}())
    @test_throws ArgumentError Client.decode_request(C.PROFILE, request(4), ps())
    @test_throws ArgumentError Client.encode_request(C.PROFILE, request(1), C.Command(:connect))
    @test_throws ArgumentError Client.encode_completion(C.PROFILE, reply(4), C.Prepared, "")
    @test_throws ArgumentError Client.encode_completion(C.PROFILE, reply(2), C.Prepared, "")
    @test_throws ArgumentError Client.encode_completion(C.PROFILE, reply(3), C.Connected, "")
    @test_throws ArgumentError Client.encode_completion(C.PROFILE, reply(1), C.Preparing, "x"^8193)
    @test_throws ArgumentError Client.encode_completion(C.PROFILE, reply(1), C.Preparing, "bad\0text")
    @test Client.decode_completion(C.PROFILE, Client.encode_completion(C.PROFILE, reply(1), C.Preparing, "λ"^4096)).message == "λ"^4096
    for payload in (ps(), ps(id(1)), ps(id(1),Pod(""),Pod(false)), ps(id(99),Pod("")), ps(Pod(Int32(1)),Pod("")), ps(id(1),Pod(false)))
        @test_throws ArgumentError Client.decode_completion(C.PROFILE, E.encode_completion(reply(1), payload))
    end
    @test_throws ArgumentError B.Binding("/unexamined/core", "owner", true, 1)
    @test_throws ArgumentError B.Binding("/unexamined/core", "owner", 1, true)
    @test_throws Exception B.connect("/unexamined/core", "owner", 1, 1; deadline=Client.monotonic()-1)
    @test_throws ArgumentError B.Binding("relative", "owner", 1, 1)
    @test_throws ArgumentError B.Binding("/tmp/core", "", 1, 1)
    @test_throws ArgumentError B.Binding("/tmp/core", "owner", 0, 1)
    @test_throws ArgumentError B.Binding("/tmp/core", "owner", 1, 0)
end
end
