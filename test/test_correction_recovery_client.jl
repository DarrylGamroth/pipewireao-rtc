module CorrectionRecoveryClientTests
using Test, PipeWireAORTC
const CR = PipeWireAORTC.CorrectionRecovery
const Runner = PipeWireAORTC.RunnerCodec
const Envelope = PipeWireAORTC.ControlCodec

include("helpers/correction_recovery_transport.jl")
include("helpers/correction_recovery_readbacks.jl")

@testset "Native recovery driver keeps recovery and resume explicit" begin
    t = ScriptedTransport()
    operation = CR.protective_open!(t, "science"; deadline = 2.0, reason = :saturation)
    @test CR.state(operation.coordinator) === :Holding
    @test operation.coordinator.reason === :saturation
    @test operation.coordinator.recovery_generation == 3
    @test operation.coordinator.loop_generation == 4
    @test operation.request_token == 8
    @test isempty(writes(t, "correction:closed"))
    @test length(writes(t, "pipewireao-recovery:request-token")) == 1
    @test isempty(writes(t, "pipewireao-recovery:release-token"))
    @test CR.resume!(operation; deadline = 2.0) === operation
    @test CR.state(operation.coordinator) === :Closed
    @test length(writes(t, "pipewireao-recovery:release-token")) == 1
    @test only(writes(t, "pipewireao-recovery:release-token")).second.value == 3
    @test length(writes(t, "correction:closed")) == 1
    @test last(writes(t, "correction:closed")).second.value === true
    @test_throws ArgumentError CR.resume!(operation; deadline = 2.0)
    @test length(writes(t, "correction:closed")) == 1
end

@testset "Missing or expired source evidence never closes or retries" begin
    for mode in (:stall, :expired_reference)
        t = ScriptedTransport(; mode)
        failure = failure_of(() -> CR.protective_open!(t, "science"; deadline = 2.0))
        @test CR.state(failure.operation.coordinator) === :Unverified
        @test failure.operation.coordinator.failure === :operation_timeout
        @test length(writes(t, "pipewireao-recovery:request-token")) == 1
        @test isempty(writes(t, "pipewireao-recovery:release-token"))
        @test isempty(writes(t, "correction:closed"))
        @test_throws ArgumentError CR.resume!(failure.operation; deadline = 2.0)
        @test isempty(writes(t, "correction:closed"))
    end
end

@testset "Native owner and outcome failures latch without replay" begin
    for mode in (:wrong_owner, :wrong_session, :unknown, :cached_reply)
        t = ScriptedTransport(; mode)
        failure = failure_of(() -> CR.protective_open!(t, "science"; deadline = 2.0))
        @test CR.state(failure.operation.coordinator) === :Unverified
        @test length(writes(t, "pipewireao-recovery:request-token")) == 1
        @test isempty(writes(t, "correction:closed"))
        @test isempty(writes(t, "pipewireao-recovery:release-token"))
    end
end

@testset "Release refusal, lost readiness and stale source prevent close" begin
    for mode in (
        :release_refused,
        :stopped_before_close,
        :frozen_source,
        :frozen_after_release,
        :wrong_release_token,
    )
        t = ScriptedTransport()
        operation = CR.protective_open!(t, "science"; deadline = 2.0)
        t.mode = mode
        failure = failure_of(() -> CR.resume!(operation; deadline = 2.0))
        @test failure.operation === operation
        @test CR.state(operation.coordinator) === :Unverified
        @test isempty(writes(t, "correction:closed"))
        @test length(writes(t, "pipewireao-recovery:release-token")) <= 1
        @test_throws ArgumentError CR.resume!(operation; deadline = 2.0)
        @test isempty(writes(t, "correction:closed"))
    end
end

@testset "Pending recovery is refused before effects" begin
    t = ScriptedTransport()
    t.recovery_state = :pending
    t.virtual_requested += 1
    @test_throws ArgumentError CR.protective_open!(t, "science"; deadline = 2.0)
    @test isempty(t.writes)
end

@testset "Cancellation after submission does not replay recovery" begin
    t = ScriptedTransport()
    check =
        () ->
            isempty(writes(t, "pipewireao-recovery:request-token")) ? nothing :
            throw(InterruptException())
    failure = failure_of(() -> CR.protective_open!(t, "science"; deadline = 2.0, check))
    @test failure.operation.coordinator.failure === :operation_cancelled
    @test CR.state(failure.operation.coordinator) === :Unverified
    @test length(writes(t, "pipewireao-recovery:request-token")) == 1
    @test isempty(writes(t, "correction:closed"))
end

@testset "Slow successful readiness cannot issue an expired phase effect" begin
    opening = ScriptedTransport(; mode = :slow_open_status)
    failure = failure_of(() -> CR.protective_open!(opening, "science"; deadline = 2.0))
    @test CR.state(failure.operation.coordinator) === :Unverified
    @test isempty(opening.writes)
    @test opening.now_ns < 2_000_000_000

    closing = ScriptedTransport()
    operation = CR.protective_open!(closing, "science"; deadline = 2.0)
    closing.mode = :slow_close_status
    failure = failure_of(() -> CR.resume!(operation; deadline = 2.0))
    @test failure.operation === operation
    @test CR.state(operation.coordinator) === :Unverified
    @test length(writes(closing, "pipewireao-recovery:release-token")) == 1
    @test isempty(writes(closing, "correction:closed"))
    @test closing.now_ns < 2_000_000_000
end
@testset "Native terminal failures retain their reported field and cause" begin
    transport = ScriptedTransport(; mode = :native_error)
    failure = failure_of(() -> CR.protective_open!(transport, "science"; deadline = 2.0))
    @test occursin("properties: owner rejected update", sprint(showerror, failure))
    @test CR.state(failure.operation.coordinator) === :Unverified
    @test length(transport.writes) == 1
    @test length(writes(transport, "pipewireao-recovery:request-token")) == 1
end

@testset "First protective mutation inhibits a competing close before adoption" begin
    t = ScriptedTransport(; mode = :competing_close)
    operation = try
        CR.protective_open!(t, "science"; deadline = 2.0)
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
    t = ScriptedTransport(; mode = :immediate_application)
    operation = CR.protective_open!(t, "science"; deadline = 2.0)
    @test CR.state(operation.coordinator) === :Holding
    @test operation.coordinator.loop_generation == 4
    @test operation.coordinator.recovery_generation == 3
    @test only(t.writes).first == "pipewireao-recovery:request-token"
    @test t.inhibited && !t.closed
end

@testset "Native singular facts implement the loop observation interface" begin
    snapshot = native_readback(owner_properties(ScriptedTransport()))
    @test snapshot isa CR.AbstractLoopObservation
    @test CR.controller_scope(snapshot) isa CR.SingleController
    @test snapshot.readbacks isa CR.ControllerReadback{Nothing}
    @test CR.controller_names(snapshot) == snapshot.controller == "correction"
    @test CR.owner_instance(snapshot) == snapshot.owner_instance == 501
    @test CR.observation_serial(snapshot) == snapshot.serial == 1
    @test CR.operation_token(snapshot) == UInt64(snapshot.request_token) == 7
    @test CR.requested_generation(snapshot) == snapshot.loop_requested == 3
    @test CR.active_generation(snapshot) == snapshot.loop_active == 3
    @test snapshot.requested_generation == snapshot.active_generation == 8
    @test CR.closed(snapshot) === snapshot.closed === true
    @test snapshot.loop_state === :Closed
    @test snapshot.controller_readiness === nothing
    @test CR.generations_match(snapshot) &&
        CR.all_closed(snapshot) &&
        !CR.all_open(snapshot)
    @test CR.adoption_matches(snapshot)
    coordinator = CR.Coordinator(CR.controller_scope(snapshot), snapshot.owner_instance)
    CR.qualify!(coordinator, snapshot)
    @test CR.state(coordinator) === :Unverified # persisted token7 is never relabeled0
    CR.qualify!(
        coordinator,
        CR.LoopObservation(
            snapshot.owner_instance,
            UInt64(0),
            snapshot.serial,
            CR.requested_generation(snapshot),
            CR.active_generation(snapshot),
            CR.closed(snapshot),
        ),
    )
    @test CR.state(coordinator) === :Closed
    @test CR.same_scope(coordinator, snapshot)
    @test_throws ArgumentError replace_readbacks(
        snapshot, CR.SingleController(), (snapshot.readbacks,)
    )
    @test_throws ArgumentError replace_readbacks(
        snapshot, CR.CoupledControllers{1}(), (snapshot.readbacks,)
    )
end

@testset "Version1 names and native validation precedence remain unchanged" begin
    p = "pipewireao-recovery:"
    properties = owner_properties(ScriptedTransport())
    legacy_name = "legacy/controller with spaces:closed"
    properties[p*"controller"] = scalar(legacy_name)
    for suffix in (":closed", ":requested-generation", ":active-generation")
        properties[legacy_name*suffix] = pop!(properties, "correction" * suffix)
    end
    for suffix in ("fault", "state", "requested")
        properties["pipewireao.correction-control."*legacy_name*":closed."*suffix] = pop!(
            properties, "pipewireao.correction-control.correction:closed." * suffix
        )
    end
    @test native_readback(properties).controller == legacy_name

    properties = owner_properties(ScriptedTransport())
    properties[p*"controller"] = scalar("")
    delete!(properties, "pipewireao.correction-control.correction:closed.fault")
    failure = readback_error(() -> native_readback(properties))
    @test failure isa ArgumentError
    @test occursin("controller is absent", sprint(showerror, failure))

    properties = owner_properties(ScriptedTransport())
    properties["pipewireao.correction-control.correction:closed.fault"] = scalar(
        "owner adoption fault"
    )
    properties["correction:closed"] = scalar(Int64(0))
    failure = readback_error(() -> native_readback(properties))
    @test failure isa PipeWireAORTC.ControlClient.UnknownOutcome
    @test occursin("observer has a fault", sprint(showerror, failure))

    properties = owner_properties(ScriptedTransport())
    control = "pipewireao.correction-control.correction:closed."
    properties[control*"requested"] = scalar(Int64(0))
    properties["correction:closed"] = scalar(Int64(0))
    failure = readback_error(() -> native_readback(properties))
    @test failure isa ArgumentError
    @test occursin(control * "requested", sprint(showerror, failure))

    properties = owner_properties(ScriptedTransport())
    properties["correction:requested-generation"] = scalar(Int64(-1))
    @test_throws ArgumentError native_readback(properties)
    properties = owner_properties(ScriptedTransport())
    properties[p*"version"] = scalar(Int64(1))
    @test_throws ArgumentError native_readback(properties)
end

end
