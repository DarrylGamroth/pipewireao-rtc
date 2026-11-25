module CorrectionSupervisionClientTests
import Clocks
using Test, PipeWireAORTC
const CS = PipeWireAORTC.CorrectionSupervision
const CR = PipeWireAORTC.CorrectionRecovery
const Runner = PipeWireAORTC.RunnerCodec
const Envelope = PipeWireAORTC.ControlCodec
const ControlClient = PipeWireAORTC.ControlClient
include("helpers/correction_recovery_transport.jl")

# Add owner-produced supervision Props to the existing recovery model. The
# underlying transport exclusively implements recovery, closure and token flow.
mutable struct SupervisionTransport <: CR.AbstractRecoveryTransport
    recovery::ScriptedTransport
    properties::Dict{String,Runner.RunnerScalar}
    property_reads::Int
    replace_before_recovery::Bool
end
function SupervisionTransport(outputs = (:left,); action = "monitor_only", mode = :normal)
    recovery = ScriptedTransport(; mode)
    properties = Dict{String,Runner.RunnerScalar}(
        CS.OBSERVATION_PREFIX * "version" => scalar(Int32(1)),
        CS.OBSERVATION_PREFIX * "owner-instance" => scalar(recovery.owner),
        "pipewireao.frame-observer.state" => scalar("active"),
    )
    for output in outputs
        prefix = CS.OBSERVATION_PREFIX * string(output) * "."
        for (field, value) in (
            ("state", "Tripped"),
            ("action", action),
            ("sequence", "100"),
            ("observed-ns", string(Clocks.time_nanos(recovery.clock))),
            ("trip-sequence", "90"),
            ("trip-ns", "900000000"),
            ("max-gap-ns", "1000000000"),
        )
            properties[prefix*field] = scalar(value)
        end
        properties[prefix*"fresh"] = scalar(true)
    end
    return SupervisionTransport(recovery, properties, 0, false)
end
CR.transport_instance(t::SupervisionTransport) = CR.transport_instance(t.recovery)
CR.transport_initial_token(t::SupervisionTransport) = CR.transport_initial_token(t.recovery)
CR.transport_clock(t::SupervisionTransport) = CR.transport_clock(t.recovery)
CR.transport_pause!(t::SupervisionTransport, seconds::Float64) =
    CR.transport_pause!(t.recovery, seconds)
function CR.request_native!(
    t::SupervisionTransport, command::Runner.RunnerCommand; deadline::Int64, check
)
    if t.recovery.mode === :expired_trigger && t.property_reads == 1
        # Supervision was fresh when queried, but admission's readiness read
        # completes after its evidence expiry and before the caller deadline.
        Clocks.advance!(t.recovery.clock, Int64(2_000_000))
    end
    return CR.request_native!(t.recovery, command; deadline, check)
end
function CR.request_native!(
    t::SupervisionTransport,
    command::Runner.RunnerCommand{:properties};
    deadline::Int64,
    check,
)
    t.property_reads += 1
    if t.replace_before_recovery && t.property_reads == 2
        # Replacement occurs between the supervision receipt and recovery's
        # own admission read, while the selected session remains unchanged.
        t.recovery.owner += 1
    end
    reply = CR.request_native!(t.recovery, command; deadline, check)
    properties = merge(reply.result.details.properties, t.properties)
    details = (; graph = reply.result.details.graph, properties)
    return Runner.Completion(
        reply.header,
        reply.lifecycle,
        Runner.RunnerResult{:properties,typeof(details)}(reply.result.outcome, details),
        reply.error,
    )
end
set_status!(t, output, field, value) =
    (t.properties[CS.OBSERVATION_PREFIX*string(output)*"."*field] = scalar(value); t)
client(t, outputs = (:left,)) = CS.Client(t, "science", outputs)
poll!(c) = CS.poll!(c; deadline = Int64(2_000_000_000))

@testset "Monitor-only supervision never changes correction" begin
    t = SupervisionTransport()
    c = client(t)
    for _ in 1:3
        result = poll!(c)
        @test result.state === :Monitoring && result.operation === nothing
        @test only(result.observed).action == "monitor_only"
    end
    @test isempty(t.recovery.writes)
    @test t.recovery.closed && !t.recovery.inhibited
    @test c.owner_instance == t.recovery.owner
end

@testset "Cached once-fresh status cannot authorize stale or unavailable effects" begin
    for change in (:aged, :flag_false, :observer_failed, :unknown)
        t = SupervisionTransport(; action = "restore_reference")
        if change === :aged
            set_status!(t, :left, "max-gap-ns", "1")
        elseif change === :flag_false
            set_status!(t, :left, "fresh", false)
        elseif change === :observer_failed
            t.properties["pipewireao.frame-observer.state"] = scalar("failed")
        else
            set_status!(t, :left, "state", "Unknown")
            set_status!(t, :left, "action", "none")
            set_status!(t, :left, "fresh", false)
        end
        result = poll!(client(t))
        @test result.state === :Unknown && result.operation === nothing
        @test isempty(t.recovery.writes)
    end
    # An owner state declaring unknown evidence cannot be upgraded by a cached
    # true fresh flag, either alone or after an earlier protective trip.
    t = SupervisionTransport()
    set_status!(t, :left, "state", "Unknown")
    set_status!(t, :left, "action", "none")
    @test poll!(client(t)).state === :Unknown
    @test isempty(t.recovery.writes)
    t = SupervisionTransport((:left, :right); action = "restore_reference")
    set_status!(t, :right, "state", "Unknown")
    set_status!(t, :right, "action", "none")
    @test poll!(client(t, (:left, :right))).state === :Unknown
    @test isempty(t.recovery.writes)
    for (gap, expected) in (("200000", :Monitoring), ("199999", :Unknown))
        t = SupervisionTransport()
        set_status!(t, :left, "max-gap-ns", gap)
        @test poll!(client(t)).state === expected # Native status + Props cost 200000 ns.
        @test isempty(t.recovery.writes)
    end
    # One unavailable configured output gates all protective effects, even
    # when an earlier output already has a valid restore-reference trip.
    t = SupervisionTransport((:left, :right); action = "restore_reference")
    set_status!(t, :right, "fresh", false)
    @test poll!(client(t, (:left, :right))).state === :Unknown
    @test isempty(t.recovery.writes)
end

@testset "All declared publications are validated before any protective effect" begin
    cases = (
        ("state", "invalid"),
        ("action", "hold"),
        ("sequence", "-1"),
        ("sequence", "18446744073709551616"),
        ("observed-ns", "18446744073709551615"),
        ("trip-sequence", "101"),
        ("trip-ns", "1000000001"),
        ("trip-ns", "-9223372036854775809"),
        ("max-gap-ns", "0"),
        ("max-gap-ns", "nan"),
        ("sequence", Int64(100)),
        ("fresh", "true"),
    )
    for (field, value) in cases
        t = SupervisionTransport((:left, :right); action = "restore_reference")
        set_status!(t, :right, field, value)
        c = client(t, (:left, :right))
        @test_throws ArgumentError poll!(c)
        @test c.state === :Unverified
        @test isempty(t.recovery.writes)
        reads = t.property_reads
        @test_throws ControlClient.UnknownOutcome poll!(c)
        @test t.property_reads == reads # No retry, read, or effect after refusal.
    end
    for unavailable_state in ("Unknown", "Disabled")
        t = SupervisionTransport((:left, :right); action = "restore_reference")
        set_status!(t, :right, "state", unavailable_state)
        set_status!(t, :right, "action", "none")
        set_status!(t, :right, "fresh", "true")
        c = client(t, (:left, :right))
        @test_throws ArgumentError poll!(c)
        @test c.state === :Unverified && isempty(t.recovery.writes)
    end
    for field in ("sequence", "max-gap-ns", "state", "fresh")
        t = SupervisionTransport((:left, :right); action = "restore_reference")
        delete!(t.properties, CS.OBSERVATION_PREFIX * "right." * field)
        c = client(t, (:left, :right))
        @test_throws KeyError poll!(c)
        @test c.state === :Unverified && isempty(t.recovery.writes)
    end
end

@testset "UInt64 source identities remain lossless and future times are refused" begin
    t = SupervisionTransport()
    maximum = string(typemax(UInt64))
    set_status!(t, :left, "sequence", maximum)
    set_status!(t, :left, "trip-sequence", maximum)
    set_status!(t, :left, "max-gap-ns", string(typemax(Int64)))
    result = poll!(client(t))
    @test only(result.observed).sequence === typemax(UInt64)
    @test only(result.observed).trip_sequence === typemax(UInt64)
    @test result.state === :Monitoring && isempty(t.recovery.writes)
    # A signed duration whose absolute expiry cannot fit fails before effects.
    t = SupervisionTransport(; action = "restore_reference")
    set_status!(t, :left, "max-gap-ns", string(typemax(Int64)))
    c = client(t)
    @test_throws OverflowError poll!(c)
    @test c.state === :Unverified && isempty(t.recovery.writes)
    for field in ("observed-ns", "trip-ns")
        t = SupervisionTransport(; action = "restore_reference")
        set_status!(t, :left, field, maximum)
        @test_throws ArgumentError poll!(client(t))
        @test isempty(t.recovery.writes)
    end
end

@testset "One restore trip enters atomic recovery Holding and never auto-closes" begin
    t = SupervisionTransport(; action = "restore_reference", mode = :competing_close)
    c = client(t)
    result = poll!(c)
    @test result.state === :Holding && c.state === :Holding
    @test result.operation isa CR.Operation
    @test CR.state(result.operation.coordinator) === :Holding
    @test result.operation.coordinator.reason === :saturation
    @test only(t.recovery.writes).first == "pipewireao-recovery:request-token"
    @test isempty(writes(t.recovery, "correction:closed"))
    @test isempty(writes(t.recovery, "pipewireao-recovery:release-token"))
    @test t.recovery.inhibited && !t.recovery.closed
    @test t.recovery.competing_close_attempts == 1
    @test t.recovery.competing_close_accepted == 0
    @test !t.recovery.resurrected_correction
    for _ in 1:3
        again = poll!(c)
        @test again.state === :Holding && again.operation === nothing
    end
    @test length(t.recovery.writes) == 1
    set_status!(t, :left, "sequence", "-1")
    @test_throws ArgumentError poll!(c)
    @test c.state === :Unverified && length(t.recovery.writes) == 1
    @test CR.state(result.operation.coordinator) === :Holding # Caller retains operation.
end

@testset "Trigger expiry bounds preflight but not accepted reference adoption" begin
    t = SupervisionTransport(; action = "restore_reference", mode = :expired_trigger)
    set_status!(t, :left, "max-gap-ns", "1000000")
    c = client(t)
    @test_throws ControlClient.UnknownOutcome poll!(c)
    @test c.state === :Unverified
    @test Clocks.time_nanos(t.recovery.clock) < 2_000_000_000
    @test isempty(t.recovery.writes)
    reads = (t.property_reads, t.recovery.token)
    @test_throws ControlClient.UnknownOutcome poll!(c)
    @test (t.property_reads, t.recovery.token) == reads

    # Normal preflight submits while evidence is fresh, and reference arrival
    # is then allowed to complete after the short trigger expires.
    t = SupervisionTransport(; action = "restore_reference")
    set_status!(t, :left, "max-gap-ns", "1000000")
    result = poll!(client(t))
    @test result.state === :Holding
    @test Clocks.time_nanos(t.recovery.clock) > 1_001_000_000
    @test only(t.recovery.writes).first == "pipewireao-recovery:request-token"
end

@testset "Owner fences reject replacement before the first native effect" begin
    t = SupervisionTransport(; action = "restore_reference")
    t.replace_before_recovery = true
    c = client(t)
    @test_throws ControlClient.UnknownOutcome poll!(c)
    @test c.state === :Unverified
    @test t.property_reads == 2 && isempty(t.recovery.writes)
    # Test the recovery admission fence independently of supervision parsing.
    base = ScriptedTransport()
    @test_throws ControlClient.UnknownOutcome CR.protective_open!(
        base, "science"; deadline = Int64(2_000_000_000), expected_owner = base.owner + 1
    )
    @test isempty(base.writes)

    t = SupervisionTransport()
    c = client(t)
    poll!(c)
    t.recovery.owner += 1
    t.properties[CS.OBSERVATION_PREFIX*"owner-instance"] = scalar(t.recovery.owner)
    @test_throws ControlClient.UnknownOutcome poll!(c)
    @test c.state === :Unverified && isempty(t.recovery.writes)
end

@testset "Uncertain recovery effects never retry or release automatically" begin
    for mode in (:native_error, :unknown, :wrong_owner, :cached_reply)
        t = SupervisionTransport(; action = "restore_reference", mode)
        c = client(t)
        @test_throws CR.RecoveryError poll!(c)
        @test c.state === :Unverified
        @test length(writes(t.recovery, "pipewireao-recovery:request-token")) == 1
        @test isempty(writes(t.recovery, "correction:closed"))
        @test isempty(writes(t.recovery, "pipewireao-recovery:release-token"))
        before = (t.property_reads, length(t.recovery.writes), t.recovery.token)
        @test_throws ControlClient.UnknownOutcome poll!(c)
        @test before == (t.property_reads, length(t.recovery.writes), t.recovery.token)
    end
end
@testset "Signed supervision publication has exact freshness and no zero sentinel" begin
    for origin in (Int64(-1_000_000_000), Int64(0), Int64(2)^53 + 1)
        for (gap, expected) in ((200_000, :Monitoring), (199_999, :Unknown))
            transport = SupervisionTransport()
            Clocks.update!(transport.recovery.clock, origin)
            set_status!(transport, :left, "observed-ns", string(origin))
            set_status!(transport, :left, "trip-ns", string(origin))
            set_status!(transport, :left, "max-gap-ns", string(gap))
            result = CS.poll!(client(transport); deadline = origin + 1_000_000_000)
            @test result.state === expected
            @test only(result.observed).observed_ns === origin
            @test isempty(transport.recovery.writes)
        end
    end
    transport = SupervisionTransport()
    set_status!(transport, :left, "trip-ns", "0")
    @test poll!(client(transport)).state === :Monitoring
    transport = SupervisionTransport(; action = "restore_reference")
    Clocks.update!(transport.recovery.clock, -1_000_000_000)
    transport.recovery.source_ns = -1_000_000_000
    set_status!(transport, :left, "observed-ns", "-1000000000")
    set_status!(transport, :left, "trip-ns", "-1000000000")
    result = CS.poll!(client(transport); deadline = Int64(0))
    @test result.state === :Holding
    @test CR.state(result.operation.coordinator) === :Holding
end


end
