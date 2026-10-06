using Test, PipeWireAO, PipeWireAODeployment

const Client = PipeWireAODeployment.NativeControlClient
const Envelope = PipeWireAODeployment.NativeControlCodec
const Runner = PipeWireAODeployment.NativeRunnerClient
const SPA = PipeWireAO.SPA

@enum TestState::UInt32 Preparing=17 Prepared=18
struct TestProfile <: Client.Profile end
struct CalibrationProfile <: Client.Profile end
struct TestReply
    header::Envelope.ReplyHeader
    payload::SPA.Struct
end
struct TestCommand end

Client.profile_name(::TestProfile) = "org.test.owner/1"
Client.profile_name(::CalibrationProfile) = "org.test.calibration/1"
Client.capability_names(::Union{TestProfile,CalibrationProfile}) = (
    "org.test.owner.version", "org.test.owner.instance", "org.test.owner.owner-pid",
    "org.test.owner.lifecycle", "org.test.owner.last-token", "org.test.owner.controllers")
Client.lifecycle_type(::Union{TestProfile,CalibrationProfile}) = TestState
Client.completion_type(::Union{TestProfile,CalibrationProfile}) = TestReply
Client.rejection_type(::Union{TestProfile,CalibrationProfile}) = TestReply
Client.reply_endpoint(::CalibrationProfile) = :calibration
function Client.decode_completion(profile::Union{TestProfile,CalibrationProfile}, pod)
    header, payload = Envelope.decode_completion(pod; endpoint=Client.reply_endpoint(profile))
    return TestReply(header, payload)
end
function Client.decode_rejection(profile::Union{TestProfile,CalibrationProfile}, pod)
    header, payload = Envelope.decode_rejection(pod; endpoint=Client.reply_endpoint(profile))
    return TestReply(header, payload)
end
Client.operation_id(::TestProfile, ::TestCommand) = UInt32(71)
Client.encode_request(::TestProfile, header, ::TestCommand) = Envelope.encode_request(header, SPA.Struct())

const IDENTITY = Envelope.ControllerIdentity(UInt32(42), typemax(UInt64), Int64(9))
function test_capability(profile; state=UInt32(Prepared))
    names = Client.capability_names(profile)
    rows = SPA.Struct(Pod(SPA.Struct(Pod(SPA.Id(IDENTITY.global_id)),
        Pod(reinterpret(Int64, IDENTITY.serial)), Pod(IDENTITY.instance))))
    return Pod(props_param(SPA.Props(names[1] => Int32(1), names[2] => Int64(23),
        names[3] => SPA.Id(getpid()), names[4] => SPA.Id(state),
        names[5] => Int64(0), names[6] => rows)))
end

@testset "native owner profile dispatch" begin
    profile = TestProfile()
    observation = Client.Observation(profile, Int64(23), UInt32(getpid()))
    Client.observe!(observation, test_capability(profile))
    @test observation.failure === nothing
    @test observation.capability.lifecycle == Prepared
    @test observation.capability.controllers == [IDENTITY]
    @test fieldtype(typeof(observation), :profile) === TestProfile
    @test observation isa Client.Observation{TestProfile,TestState,TestReply,TestReply}

    runner = Runner.Observation(Int64(23), UInt32(getpid()))
    Client.observe!(runner, test_capability(profile))
    @test runner.fatal_failure !== nothing
    @test runner.capability === nothing
    invalid = Client.Observation(profile, Int64(23), UInt32(getpid()))
    Client.observe!(invalid, test_capability(profile; state=UInt32(3)))
    @test invalid.fatal_failure !== nothing
    @test invalid.capability === nothing

    request = Envelope.RequestHeader(IDENTITY, Int64(23), Int64(1), UInt32(71), Int64(1000))
    observation.pending = request
    reply = Envelope.ReplyHeader(IDENTITY, Int64(23), Int64(1), UInt32(71), Int32(0))
    now = Client.monotonic()
    Client.observe!(observation, Envelope.encode_completion(reply, SPA.Struct(Pod(Int32(7)))); at=now)
    @test Client.matching_reply(observation, now + 1) isa TestReply
    @test pod_value(Int32, observation.matched_completion.value.payload.values[1]) == 7
    @test Client.operation_id(profile, TestCommand()) == 71
    @test_throws MethodError Client.operation_id(profile,
        PipeWireAODeployment.NativeRunnerCodec.RunnerCommand(:status))
    @test_throws MethodError Client.operation_id(Runner.RunnerProfile(), TestCommand())
end

@testset "native reply envelope limits follow owner profile" begin
    # Envelope size advances by eight-byte padding. Find the largest admissible
    # byte payload and test its exact size and the next padding unit.
    profile = CalibrationProfile()
    header = Envelope.ReplyHeader(IDENTITY, Int64(23), Int64(1), UInt32(71), Int32(0))
    empty_payload = SPA.Struct(Pod(SPA.Bytes(UInt8[])))
    overhead = sizeof(Envelope.encode_completion(header, empty_payload; endpoint=:calibration))
    limit = Client.reply_bound(profile)
    count = limit - overhead
    payload = SPA.Struct(Pod(SPA.Bytes(fill(UInt8(1), count))))
    pod = Envelope.encode_completion(header, payload; endpoint=:calibration)
    @test sizeof(pod) == limit
    accepted = Client.Observation(profile, Int64(23), UInt32(getpid()))
    Client.observe!(accepted, pod)
    @test accepted.failure === nothing
    @test accepted.completion.value.header == header
    @test Client.reply_bound(TestProfile()) == 64 * 1024
    lifecycle = Client.Observation(TestProfile(), Int64(23), UInt32(getpid()))
    Client.observe!(lifecycle, pod)
    @test lifecycle.fatal_failure !== nothing
    @test lifecycle.completion === nothing
    @test_throws ArgumentError Envelope.encode_completion(header,
        SPA.Struct(Pod(SPA.Bytes(fill(UInt8(1), count + 1)))); endpoint=:calibration)

    sentinel = Envelope.encode_completion(Envelope.ReplyHeader(Int64(23), Int32(0)),
        SPA.Struct(); endpoint=:calibration)
    initial = Client.Observation(profile, Int64(23), UInt32(getpid()))
    Client.observe!(initial, sentinel)
    @test initial.completion_seen && initial.failure === nothing
    @test initial.completion === nothing
end
