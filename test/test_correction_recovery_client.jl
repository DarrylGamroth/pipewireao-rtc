module CorrectionRecoveryClientTests
using Test, PipeWireAORTC
const CR = PipeWireAORTC.CorrectionRecovery
const Runner = PipeWireAORTC.NativeRunnerCodec
const Envelope = PipeWireAORTC.NativeControlCodec

include("helpers/correction_recovery_transport.jl")

@testset "Native recovery driver keeps recovery and resume explicit" begin
    t = ScriptedTransport()
    operation = CR.protective_open!(t, "science"; deadline=2.0, reason=:saturation)
    @test CR.state(operation.coordinator) === :Holding
    @test operation.coordinator.reason === :saturation
    @test operation.coordinator.recovery_generation == 3
    @test operation.coordinator.loop_generation == 4
    @test operation.request_token == 8
    @test isempty(writes(t, "correction:closed"))
    @test length(writes(t, "pipewireao-recovery:request-token")) == 1
    @test isempty(writes(t, "pipewireao-recovery:release-token"))
    @test CR.resume!(operation; deadline=2.0) === operation
    @test CR.state(operation.coordinator) === :Closed
    @test length(writes(t, "pipewireao-recovery:release-token")) == 1
    @test only(writes(t, "pipewireao-recovery:release-token")).second.value == 3
    @test length(writes(t, "correction:closed")) == 1
    @test last(writes(t, "correction:closed")).second.value === true
    @test_throws ArgumentError CR.resume!(operation; deadline=2.0)
    @test length(writes(t, "correction:closed")) == 1
end

@testset "Missing or expired source evidence never closes or retries" begin
    for mode in (:stall, :expired_reference)
        t = ScriptedTransport(; mode)
        failure = failure_of(() -> CR.protective_open!(t, "science"; deadline=2.0))
        @test CR.state(failure.operation.coordinator) === :Unverified
        @test failure.operation.coordinator.failure === :operation_timeout
        @test length(writes(t, "pipewireao-recovery:request-token")) == 1
        @test isempty(writes(t, "pipewireao-recovery:release-token"))
        @test isempty(writes(t, "correction:closed"))
        @test_throws ArgumentError CR.resume!(failure.operation; deadline=2.0)
        @test isempty(writes(t, "correction:closed"))
    end
end

@testset "Native owner and outcome failures latch without replay" begin
    for mode in (:wrong_owner, :wrong_session, :unknown, :cached_reply)
        t = ScriptedTransport(; mode)
        failure = failure_of(() -> CR.protective_open!(t, "science"; deadline=2.0))
        @test CR.state(failure.operation.coordinator) === :Unverified
        @test length(writes(t, "pipewireao-recovery:request-token")) == 1
        @test isempty(writes(t, "correction:closed"))
        @test isempty(writes(t, "pipewireao-recovery:release-token"))
    end
end

@testset "Release refusal, lost readiness and stale source prevent close" begin
    for mode in (:release_refused, :stopped_before_close, :frozen_source,
            :frozen_after_release, :wrong_release_token)
        t = ScriptedTransport()
        operation = CR.protective_open!(t, "science"; deadline=2.0)
        t.mode = mode
        failure = failure_of(() -> CR.resume!(operation; deadline=2.0))
        @test failure.operation === operation
        @test CR.state(operation.coordinator) === :Unverified
        @test isempty(writes(t, "correction:closed"))
        @test length(writes(t, "pipewireao-recovery:release-token")) <= 1
        @test_throws ArgumentError CR.resume!(operation; deadline=2.0)
        @test isempty(writes(t, "correction:closed"))
    end
end

@testset "Pending recovery is refused before effects" begin
    t = ScriptedTransport()
    t.recovery_state = :pending
    t.virtual_requested += 1
    @test_throws ArgumentError CR.protective_open!(t, "science"; deadline=2.0)
    @test isempty(t.writes)
end

@testset "Cancellation after submission does not replay recovery" begin
    t = ScriptedTransport()
    check = () -> isempty(writes(t, "pipewireao-recovery:request-token")) ? nothing : throw(InterruptException())
    failure = failure_of(() -> CR.protective_open!(t, "science"; deadline=2.0, check))
    @test failure.operation.coordinator.failure === :operation_cancelled
    @test CR.state(failure.operation.coordinator) === :Unverified
    @test length(writes(t, "pipewireao-recovery:request-token")) == 1
    @test isempty(writes(t, "correction:closed"))
end

@testset "Slow successful readiness cannot issue an expired phase effect" begin
    opening = ScriptedTransport(; mode=:slow_open_status)
    failure = failure_of(() -> CR.protective_open!(opening, "science"; deadline=2.0))
    @test CR.state(failure.operation.coordinator) === :Unverified
    @test isempty(opening.writes)
    @test opening.now_ns < 2_000_000_000

    closing = ScriptedTransport()
    operation = CR.protective_open!(closing, "science"; deadline=2.0)
    closing.mode = :slow_close_status
    failure = failure_of(() -> CR.resume!(operation; deadline=2.0))
    @test failure.operation === operation
    @test CR.state(operation.coordinator) === :Unverified
    @test length(writes(closing, "pipewireao-recovery:release-token")) == 1
    @test isempty(writes(closing, "correction:closed"))
    @test closing.now_ns < 2_000_000_000
end
@testset "Native terminal failures retain their reported field and cause" begin
    transport = ScriptedTransport(; mode=:native_error)
    failure = failure_of(() -> CR.protective_open!(transport, "science"; deadline=2.0))
    @test occursin("properties: owner rejected update", sprint(showerror, failure))
    @test CR.state(failure.operation.coordinator) === :Unverified
    @test length(transport.writes) == 1
    @test length(writes(transport, "pipewireao-recovery:request-token")) == 1
end

@testset "First protective mutation inhibits a competing close before adoption" begin
    t = ScriptedTransport(; mode=:competing_close)
    operation = try
        CR.protective_open!(t, "science"; deadline=2.0)
    catch error
        error
    end
    @test first(first(t.writes)) == "pipewireao-recovery:request-token"
    @test t.competing_close_attempts == 1
    @test t.competing_close_accepted == 0
    @test !t.resurrected_correction
    @test operation isa CR.Operation
    @test t.inhibited
    @test !t.closed
    @test iszero(t.retained_correction)
    @test isempty(writes(t, "correction:closed"))
end

@testset "First recovery readback may already show atomic application" begin
    t = ScriptedTransport(; mode=:immediate_application)
    operation = CR.protective_open!(t, "science"; deadline=2.0)
    @test CR.state(operation.coordinator) === :Holding
    @test operation.coordinator.loop_generation == 4
    @test operation.coordinator.recovery_generation == 3
    @test only(t.writes).first == "pipewireao-recovery:request-token"
    @test t.inhibited && !t.closed
end

end
