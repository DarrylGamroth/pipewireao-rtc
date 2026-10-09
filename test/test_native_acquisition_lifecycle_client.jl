using Test, PipeWireAODeployment
const Native = PipeWireAODeployment.NativeAcquisitionLifecycleClient
const Codec = PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const Envelope = PipeWireAODeployment.NativeControlCodec
const Identity = Envelope.ControllerIdentity(UInt32(7), typemax(UInt64), Int64(11))
header(result=Int32(0); operation=UInt32(5)) =
    Envelope.ReplyHeader(Identity, Int64(42), Int64(19), operation, result)
const Snapshot = Codec.Snapshot(Codec.Classic, nothing, nothing, false, false,
    "initial", false, false, nothing)

function failure_text(f, reply)
    exception = try
        f(reply)
        nothing
    catch error
        error
    end
    @test exception isa ErrorException
    return exception === nothing ? "" : sprint(showerror, exception)
end

@testset "acquisition Connect retains typed failure details" begin
    accepted = Codec.Completion(header(), Codec.Connected, Snapshot, "")
    @test Native._require_connected(accepted) === accepted
    for reply in (Codec.Completion(header(Int32(-5)), Codec.Connected, Snapshot, "effect failed"),
            Codec.Completion(header(), Codec.Fault, Snapshot, "owner fault"),
            Codec.Completion(header(), Codec.Connected, nothing, ""),
            Codec.Rejection(header(Int32(-16)), Codec.Prepared, "busy"),
            Codec.Rejection(header(Int32(-22)), Codec.Fault, ""),
            Codec.Completion(header(Int32(-5)), Codec.Fault, nothing, "x"^8192))
        text = failure_text(Native._require_connected, reply)
        @test occursin("acquisition owner Connect did not complete", text)
        @test occursin("result=$(reply.header.result)", text)
        @test occursin("lifecycle=$(reply.lifecycle)", text)
        @test occursin("instance=42", text)
        @test occursin("token=19", text)
        @test occursin("operation=5", text)
        @test occursin("message=$(repr(reply.message))", text)
    end
    text = failure_text(Native._require_connected, Codec.Completion(header(), Codec.Connected, nothing, ""))
    @test occursin("snapshot=absent", text)
    @test occursin("message=\"\"", text)
end

@testset "fresh acquisition readiness preserves Status requirements and failure details" begin
    for phase in (Codec.Prepared, Codec.Connected)
        reply = Codec.Completion(header(;operation=UInt32(1)), phase, Snapshot, "")
        @test Native._require_status(reply) === reply
        @test Native._require_ready(reply) === reply
    end
    for reply in (Codec.Completion(header(Int32(-5);operation=UInt32(1)), Codec.Fault, nothing, "failed preparation"),
            Codec.Completion(header(;operation=UInt32(1)), Codec.Prepared, nothing, ""),
            Codec.Rejection(header(Int32(-16);operation=UInt32(1)), Codec.Preparing, "busy"))
        text = failure_text(Native._require_status, reply)
        @test occursin("acquisition lifecycle status was not successful", text)
        @test occursin("result=$(reply.header.result)", text)
        @test occursin("operation=1", text)
        @test occursin("message=$(repr(reply.message))", text)
    end
    for phase in (Codec.Preparing, Codec.Fault, Codec.Stopped)
        reply = Codec.Completion(header(;operation=UInt32(1)), phase, Snapshot, "readiness changed")
        @test Native._require_status(reply) === reply
        text = failure_text(Native._require_ready, reply)
        @test occursin("acquisition owner changed readiness during discovery", text)
        @test occursin("lifecycle=$phase", text)
        @test occursin("operation=1", text)
        @test occursin("message=\"readiness changed\"", text)
    end
end
