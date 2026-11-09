using Test, PipeWireAO, PipeWireAORTC
import Clocks

const Client = PipeWireAORTC.ControlClient
const Envelope = PipeWireAORTC.ControlCodec
const SessionProfile = PipeWireAORTC.SessionProfile
const SPA = PipeWireAO.SPA

@enum TestState::UInt32 Preparing = 17 Prepared = 18
struct TestProfile <: Client.AbstractProfile end
struct CalibrationProfile <: Client.AbstractProfile end
struct TestReply
    header::Envelope.ReplyHeader
    payload::SPA.Struct
end


struct TestCommand end

Client.profile_name(::TestProfile) = "org.test.owner/1"
Client.profile_name(::CalibrationProfile) = "org.test.calibration/1"
Client.capability_names(::Union{TestProfile,CalibrationProfile}) = (
    "org.test.owner.version",
    "org.test.owner.instance",
    "org.test.owner.owner-pid",
    "org.test.owner.lifecycle",
    "org.test.owner.last-token",
    "org.test.owner.controllers",
)
Client.lifecycle_type(::Union{TestProfile,CalibrationProfile}) = TestState
Client.completion_type(::Union{TestProfile,CalibrationProfile}) = TestReply
Client.rejection_type(::Union{TestProfile,CalibrationProfile}) = TestReply
Client.reply_endpoint(::CalibrationProfile) = :calibration
function Client.decode_completion(profile::Union{TestProfile,CalibrationProfile}, pod)
    header, payload = Envelope.decode_completion(
        pod; endpoint = Client.reply_endpoint(profile)
    )
    return TestReply(header, payload)
end
function Client.decode_rejection(profile::Union{TestProfile,CalibrationProfile}, pod)
    header, payload = Envelope.decode_rejection(
        pod; endpoint = Client.reply_endpoint(profile)
    )
    return TestReply(header, payload)
end
Client.operation_id(::TestProfile, ::TestCommand) = UInt32(71)
Client.encode_request(::TestProfile, header, ::TestCommand) =
    Envelope.encode_request(header, SPA.Struct())

const IDENTITY = Envelope.ControllerIdentity(UInt32(42), typemax(UInt64), Int64(9))
function test_capability(profile; state = UInt32(Prepared))
    names = Client.capability_names(profile)
    rows = SPA.Struct(
        Pod(
            SPA.Struct(
                Pod(SPA.Id(IDENTITY.global_id)),
                Pod(reinterpret(Int64, IDENTITY.serial)),
                Pod(IDENTITY.instance),
            ),
        ),
    )
    return Pod(
        props_param(
            SPA.Props(
                names[1] => Int32(1),
                names[2] => Int64(23),
                names[3] => SPA.Id(getpid()),
                names[4] => SPA.Id(state),
                names[5] => Int64(0),
                names[6] => rows,
            ),
        ),
    )
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

    session = Client.Observation(SessionProfile.Profile(), Int64(23), UInt32(getpid()))
    Client.observe!(session, test_capability(profile))
    @test session.fatal_failure !== nothing
    @test session.capability === nothing
    invalid = Client.Observation(profile, Int64(23), UInt32(getpid()))
    Client.observe!(invalid, test_capability(profile; state = UInt32(3)))
    @test invalid.fatal_failure !== nothing
    @test invalid.capability === nothing

    request = Envelope.RequestHeader(IDENTITY, Int64(23), Int64(1), UInt32(71), Int64(1000))
    observation.pending = request
    reply = Envelope.ReplyHeader(IDENTITY, Int64(23), Int64(1), UInt32(71), Int32(0))
    now = Clocks.time_nanos(Clocks.SystemNanoClock())
    Client.observe!(
        observation, Envelope.encode_completion(reply, SPA.Struct(Pod(Int32(7)))); at = now
    )
    @test Client.matching_reply(observation, now + 1) isa TestReply
    @test pod_value(Int32, observation.matched_completion.value.payload.values[1]) == 7
    @test Client.operation_id(profile, TestCommand()) == 71
    @test_throws MethodError Client.operation_id(
        profile, PipeWireAORTC.RunnerCodec.RunnerCommand(:status)
    )
    @test_throws MethodError Client.operation_id(SessionProfile.Profile(), TestCommand())
end

@testset "native reply envelope limits follow owner profile" begin
    # Envelope size advances by eight-byte padding. Find the largest admissible
    # byte payload and test its exact size and the next padding unit.
    profile = CalibrationProfile()
    header = Envelope.ReplyHeader(IDENTITY, Int64(23), Int64(1), UInt32(71), Int32(0))
    empty_payload = SPA.Struct(Pod(SPA.Bytes(UInt8[])))
    overhead = sizeof(
        Envelope.encode_completion(header, empty_payload; endpoint = :calibration)
    )
    limit = Client.reply_bound(profile)
    count = limit - overhead
    payload = SPA.Struct(Pod(SPA.Bytes(fill(UInt8(1), count))))
    pod = Envelope.encode_completion(header, payload; endpoint = :calibration)
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
    @test_throws ArgumentError Envelope.encode_completion(
        header,
        SPA.Struct(Pod(SPA.Bytes(fill(UInt8(1), count + 1))));
        endpoint = :calibration,
    )

    sentinel = Envelope.encode_completion(
        Envelope.ReplyHeader(Int64(23), Int32(0)), SPA.Struct(); endpoint = :calibration
    )
    initial = Client.Observation(profile, Int64(23), UInt32(getpid()))
    Client.observe!(initial, sentinel)
    @test initial.completion_seen && initial.failure === nothing
    @test initial.completion === nothing
end

@testset "signed native receipt time and exact deadline ordering" begin
    function pending_observation()
        observation = Client.Observation(TestProfile(), Int64(23), UInt32(getpid()))
        observation.pending = Envelope.RequestHeader(
            IDENTITY, Int64(23), Int64(1), UInt32(71), Int64(1000)
        )
        return observation
    end
    header = Envelope.ReplyHeader(IDENTITY, Int64(23), Int64(1), UInt32(71), Int32(0))
    pod = Envelope.encode_completion(header, SPA.Struct(Pod(Int32(7))))
    for at in (Int64(-10), Int64(0), Int64(2)^53 + 1)
        observation = pending_observation()
        Client.observe!(observation, pod; at)
        @test observation.matched_completion.at === at
        @test Client.matching_reply(observation, at; now = at + 1).header == header
        Client.observe!(observation, pod; at = at + 2)
        @test observation.matched_completion.at === at
        Client.fail!(observation, "retired"; at = at + 3, retirement = true)
        @test Client.matching_reply(observation, at; now = at + 4).header == header
    end
    observation = pending_observation()
    Client.observe!(observation, pod; at = Int64(2)^53 + 1)
    @test_throws Client.UnknownOutcome Client.matching_reply(
        observation, Int64(2)^53; now = Int64(2)^53 + 2
    )
    observation = pending_observation()
    Client.observe!(observation, test_capability(TestProfile()); at = Int64(-2))
    Client.observe!(observation, pod; at = Int64(-3))
    @test observation.fatal_failure !== nothing
    @test observation.matched_completion === nothing
    @test_throws Client.UnknownOutcome Client.matching_reply(
        observation, Int64(10); now = Int64(0)
    )
end

mutable struct CountingNanoClock <: Clocks.AbstractNanoClock
    value::Int64
    reads::Int
end
Clocks.time_nanos(clock::CountingNanoClock) = (clock.reads += 1; clock.value)

function clock_client(clock)
    return Client.Client(
        ThreadLoop("clock-contract"),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        Client.Observation(TestProfile(), Int64(23), UInt32(getpid())),
        "owner",
        "marker",
        Int64(17),
        0,
        0,
        nothing,
        false,
        false,
        Int64(0),
        false,
        false,
        ReentrantLock();
        clock,
    )
end

@testset "one decision sample and fresh native submission guards" begin
    clock = CountingNanoClock(-20, 0)
    client = clock_client(clock)
    try
        samples = Int64[]
        result = Client.poll(
            client, Int64(100), Client.NO_CHECK; verify_health = false
        ) do now
            push!(samples, now)
            clock.value += 1
            :finished
        end
        @test result === :finished
        @test samples == [-20]
        @test clock.reads == 1 # One sample arms the timer and drives the decision.

        clock.reads = 0
        clock.value = 10
        @test_throws Client.UnknownOutcome Client.deadline_check(
            client, Int64(11), () -> (clock.value = 11)
        )
        @test clock.reads == 1 # The hook runs before the fresh native guard sample.
        clock.value = 9
        @test_throws Client.UnknownOutcome Client.deadline_check(
            client, Int64(100), Client.NO_CHECK
        )
    finally
        close(client)
    end

    clock = CountingNanoClock(0, 0)
    client = clock_client(clock)
    try
        samples = Int64[]
        @test_throws Client.UnknownOutcome Client.poll(
            client, Int64(10), Client.NO_CHECK; verify_health = false
        ) do now
            push!(samples, now)
            clock.value = 20
            Client.wake!(client)
            nothing
        end
        @test samples == [0, 20]
        @test clock.reads == 2
    finally
        close(client)
    end

    @test Client.budget_ns(TestProfile(), Int64(1)) === Int64(1)
    @test Client.remaining_ns(typemax(Int64), typemin(Int64)) === typemax(Int64)
    @test Client.remaining_ns(typemin(Int64), typemax(Int64)) === Int64(0)
    @test Client.budget_ns(TestProfile(), typemax(Int64)) == 30_000_000_000
    @test Client._deadline_ns(Int64(2)^53 + 1) === Int64(2)^53 + 1
    @test_throws ArgumentError Client._deadline_ns(Inf)
    @test_throws ArgumentError Client._deadline_ns(Float64(typemax(Int64)) / 1e9)
end

@testset "native timer wakes an idle control client" begin
    clock = Clocks.SystemNanoClock()
    client = clock_client(clock)
    try
        start!(client.loop)
        value = Ref{Union{Nothing,Symbol}}(:ready)
        samples = Int64[]
        f = now -> (push!(samples, now); value[])
        @test Client.poll(f, client, Clocks.time_nanos(clock) + 5_000_000_000, Client.NO_CHECK) === :ready
        timer = client.timer
        @test timer isa TimerSource

        value[] = nothing
        empty!(samples)
        deadline = Clocks.time_nanos(clock) + 50_000_000
        @test_throws Client.UnknownOutcome Client.poll(f, client, deadline, Client.NO_CHECK)
        @test first(samples) < deadline
        @test client.timer === timer

        checks = Ref(0)
        supervise = () -> begin
            checks[] += 1
            checks[] >= 3 && (value[] = :supervised)
            return nothing
        end
        @test Client.poll(f, client, Clocks.time_nanos(clock) + 5_000_000_000, supervise) === :supervised
        @test client.timer === timer
    finally
        close(client)
    end
end

struct DeadlineProbe{C}
    clock::C
    deadlines::Vector{Int64}
end
struct ProbeStopped <: Exception end
function Client.request!(probe::DeadlineProbe, command; deadline, check)
    push!(probe.deadlines, deadline)
    throw(ProbeStopped())
end

@testset "controller instances retain positive nonreused identities" begin
    first_instance = Client.next_instance()
    next_instance = Client.next_instance()
    @test 0 < first_instance < next_instance <= typemax(Int64)
    @test next_instance == first_instance + 1
end

@testset "calibration default deadline uses its bound clock" begin
    actions = PipeWireAORTC.CalibrationActionClient
    codec = PipeWireAORTC.CalibrationActionCodec
    binding = actions.Binding("/unused", "clock-test", getpid(), 23)
    for origin in (Int64(-10), Int64(2)^53 + 1, typemax(Int64) - 50)
        probe = DeadlineProbe(Clocks.CachedNanoClock(origin), Int64[])
        connection = actions.Connection(
            probe, binding, UInt64(1), UInt64(0), Int64(100), 1, Dict{String,Any}[], false
        )
        if origin > typemax(Int64) - 100
            @test_throws OverflowError actions.complete!(connection, codec.Hold())
            @test isempty(probe.deadlines)
            @test connection.serial == 0
        else
            @test_throws ProbeStopped actions.complete!(connection, codec.Hold())
            @test probe.deadlines == [origin + 100]
        end
    end
end
