using Test, PipeWireAORTC
import Hsm

const CR = PipeWireAORTC.CorrectionRecovery
const RECOVERY_OWNER = Int64(801)
const RECOVERY_TOKEN = UInt64(17)

loop_observation(serial, requested, active, closed; owner=RECOVERY_OWNER,
    token=RECOVERY_TOKEN) = CR.LoopObservation(owner, token, UInt64(serial),
        UInt64(requested), UInt64(active), closed)
recovery_observation(serial; owner=RECOVERY_OWNER, token=RECOVERY_TOKEN,
    requested=11, active=11, status=:applied, inhibited=true) =
    CR.RecoveryObservation(owner, token, UInt64(serial), UInt64(requested),
        UInt64(active), status, inhibited)
reference_observation(serial; owner=RECOVERY_OWNER, token=RECOVERY_TOKEN,
    generation=11, reached=true, coherent=true, ready=true) =
    CR.ReferenceObservation(owner, token, UInt64(serial), UInt64(generation),
        reached, coherent, ready)
release_observation(serial; owner=RECOVERY_OWNER, token=RECOVERY_TOKEN,
    generation=11, released=true, closed=false, reached=true, coherent=true, ready=true) =
    CR.ReleaseObservation(owner, token, UInt64(serial), UInt64(generation),
        released, closed, reached, coherent, ready)

function qualified_recovery(; now=Ref(UInt64(100)), closed=true, timeout_ms=5)
    sm = CR.Coordinator(RECOVERY_OWNER; clock=() -> now[], timeout_ms)
    CR.qualify!(sm, loop_observation(1, 3, 3, closed; token=UInt64(0)))
    return sm, now
end
function restoring_recovery(; kwargs...)
    sm, now = qualified_recovery(; kwargs...)
    effect = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN; reason=:saturation)
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation=UInt64(4))
    CR.observe_loop!(sm, loop_observation(2, 4, 4, false))
    return sm, now
end
function holding_recovery(; kwargs...)
    sm, now = restoring_recovery(; kwargs...)
    CR.observe_recovery!(sm, recovery_observation(3))
    CR.observe_reference!(sm, reference_observation(4))
    return sm, now
end

@testset "Protective recovery hierarchy and explicit close intent" begin
    sm, now = qualified_recovery()
    @test CR.state(sm) === :Closed
    @test Hsm.ancestor(sm, :Closed) === :Operational
    effect = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN; reason=:saturation)
    @test effect === CR.StageRecovery(RECOVERY_OWNER, RECOVERY_TOKEN)
    @test CR.state(sm) === :Opening
    @test Hsm.ancestor(sm, CR.state(sm)) === :ProtectiveOpen
    @test sm.reason === :saturation
    @test sm.pending_since_ns == now[]
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation=UInt64(4))
    now[] += 1
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation=UInt64(4)) # no new effect
    @test sm.pending_since_ns == now[] - 1
    @test CR.observe_loop!(sm, loop_observation(2, 4, 4, false)) === nothing
    @test CR.state(sm) === :RestoringReference
    @test sm.pending_since_ns == now[]
    @test CR.observe_recovery!(sm, recovery_observation(3)) === nothing
    @test CR.state(sm) === :Verifying
    @test CR.observe_reference!(sm, reference_observation(4)) === nothing
    @test CR.state(sm) === :Holding
    @test sm.pending_since_ns == 0
    @test sm.failure === nothing
    # Completion emits no command and remains held, even with repeated evidence.
    @test CR.observe_reference!(sm, reference_observation(4)) === nothing
    @test CR.state(sm) === :Holding
    release = CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    @test release === CR.ReleaseRecovery(RECOVERY_OWNER, RECOVERY_TOKEN, UInt64(11))
    @test CR.state(sm) === :Releasing
    close = CR.observe_release!(sm, release_observation(5))
    @test close === CR.CloseLoop(RECOVERY_OWNER, RECOVERY_TOKEN)
    @test CR.state(sm) === :Closing
    CR.staged!(sm, close, UInt64(5))
    @test CR.observe_loop!(sm, loop_observation(6, 5, 5, true)) === nothing
    @test CR.state(sm) === :Closed
    @test Hsm.ancestor(sm, CR.state(sm)) !== :ProtectiveOpen
    @test sm.pending_since_ns == 0
    @test_throws ArgumentError CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    @test CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN + UInt64(1)) isa CR.StageRecovery
end

@testset "Early, stale and mismatched observations cannot close" begin
    sm, now = restoring_recovery()
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    @test_throws ArgumentError CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN + UInt64(1))
    CR.observe_reference!(sm, reference_observation(100)) # before scope adoption
    @test CR.state(sm) === :RestoringReference
    CR.observe_recovery!(sm, recovery_observation(3; owner=RECOVERY_OWNER + 1))
    CR.observe_recovery!(sm, recovery_observation(3; token=RECOVERY_TOKEN - UInt64(1)))
    CR.observe_recovery!(sm, recovery_observation(1))
    CR.observe_recovery!(sm, recovery_observation(3; requested=10, active=10))
    @test CR.state(sm) === :RestoringReference
    CR.observe_recovery!(sm, recovery_observation(3))
    @test CR.state(sm) === :Verifying
    CR.observe_reference!(sm, reference_observation(3)) # same snapshot as adoption
    CR.observe_reference!(sm, reference_observation(4; generation=10))
    CR.observe_reference!(sm, reference_observation(4; ready=false))
    @test CR.state(sm) === :Verifying
    CR.observe_reference!(sm, reference_observation(5))
    @test CR.state(sm) === :Holding
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER + 1, RECOVERY_TOKEN)
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN - UInt64(1))
    now[] += UInt64(5_000_000)
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    @test CR.state(sm) === :Holding
    CR.observe_reference!(sm, reference_observation(6))
    @test CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN) isa CR.ReleaseRecovery
    @test CR.observe_release!(sm, release_observation(6)) === nothing
    @test CR.observe_release!(sm, release_observation(7; generation=10)) === nothing
    @test CR.observe_release!(sm, release_observation(7; released=false)) === nothing
    @test CR.state(sm) === :Releasing
    @test CR.observe_release!(sm, release_observation(8)) isa CR.CloseLoop
    @test CR.observe_release!(sm, release_observation(9)) === nothing
end

@testset "Release revalidates each closure prerequisite" begin
    for change in ((; closed=true), (; reached=false), (; coherent=false), (; ready=false))
        sm, _ = holding_recovery()
        CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
        @test CR.observe_release!(sm, release_observation(5; change...)) === nothing
        @test CR.state(sm) === :Unverified
        @test sm.failure === :release_prerequisites_changed
        @test CR.observe_release!(sm, release_observation(6)) === nothing
        @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    end
    sm, _ = holding_recovery()
    CR.observe_reference!(sm, reference_observation(5; coherent=false))
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
end

@testset "Timeouts latch uncertain outcomes at every pending phase" begin
    for phase in (:Opening, :RestoringReference, :Verifying, :Releasing, :Closing)
        sm, now = qualified_recovery()
        stage = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
        CR.recovery_staged!(sm, stage, UInt64(11); loop_generation=UInt64(4))
        if phase !== :Opening
            CR.observe_loop!(sm, loop_observation(2, 4, 4, false))
        end
        if phase in (:Verifying, :Releasing, :Closing)
            CR.observe_recovery!(sm, recovery_observation(3))
        end
        if phase in (:Releasing, :Closing)
            CR.observe_reference!(sm, reference_observation(4))
            CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
        end
        if phase === :Closing
            close = CR.observe_release!(sm, release_observation(5))
            CR.staged!(sm, close, UInt64(5))
        end
        @test CR.state(sm) === phase
        now[] += UInt64(5_000_000)
        # Late valid adoption is checked for timeout before accepting facts.
        @test CR.observe_loop!(sm, loop_observation(50, 5, 5, true)) === nothing
        @test CR.state(sm) === :Unverified
        @test sm.failure === :operation_timeout
        @test sm.pending_since_ns == 0
        CR.qualify!(sm, loop_observation(51, 5, 5, true; token=RECOVERY_TOKEN))
        @test CR.state(sm) === :Unverified
        @test CR.observe_recovery!(sm, recovery_observation(52)) === nothing
        @test_throws ArgumentError CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN + UInt64(1))
    end
end

@testset "Failure, replacement and contradictory evidence do not replay" begin
    for (status, expected) in ((:failed, :Fault), (:unknown, :Unverified))
        sm, _ = restoring_recovery()
        CR.observe_recovery!(sm, recovery_observation(3; status))
        @test CR.state(sm) === expected
        failure = sm.failure
        CR.failed!(sm, :later_failure)
        @test sm.failure === failure
        @test CR.observe_recovery!(sm, recovery_observation(4)) === nothing
        @test CR.state(sm) === expected
    end
    sm, _ = holding_recovery()
    CR.owner_replaced!(sm, RECOVERY_OWNER + 1)
    @test sm.failure === :owner_replaced
    @test CR.state(sm) === :Unverified
    replacement = CR.Coordinator(RECOVERY_OWNER + 1)
    CR.qualify!(replacement, loop_observation(1, 3, 3, false; token=UInt64(0)))
    @test CR.state(replacement) === :Unverified
    CR.qualify!(replacement, loop_observation(1, 3, 3, false;
        owner=RECOVERY_OWNER + 1, token=UInt64(0)))
    @test CR.state(replacement) === :Open
    sm, _ = holding_recovery()
    CR.observe_loop!(sm, loop_observation(5, 4, 4, true))
    @test sm.failure === :unexpected_loop_change
    sm, _ = restoring_recovery()
    CR.observe_recovery!(sm, recovery_observation(3; inhibited=false))
    @test sm.failure === :missing_closure_inhibition
end

@testset "Qualification and clock inputs are bounded" begin
    @test_throws ArgumentError CR.Coordinator(Int64(0))
    for timeout_ms in (0, -1, 60_001, true, typemax(Int128))
        @test_throws ArgumentError CR.Coordinator(RECOVERY_OWNER; timeout_ms)
    end
    for clock in (() -> -1, () -> true, () -> 1.5, () -> typemax(UInt128))
        @test_throws ArgumentError CR.Coordinator(RECOVERY_OWNER; clock)
    end
    sm = CR.Coordinator(RECOVERY_OWNER)
    CR.qualify!(sm, loop_observation(1, 4, 3, true; token=UInt64(0)))
    @test sm.failure === :initial_generation_mismatch
    @test_throws ArgumentError CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
end

@testset "Cancellation and clock failure preserve uncertain outcomes" begin
    sm, _ = holding_recovery()
    CR.cancel!(sm, RECOVERY_OWNER + 1, RECOVERY_TOKEN)
    CR.cancel!(sm, RECOVERY_OWNER, RECOVERY_TOKEN + UInt64(1))
    @test CR.state(sm) === :Holding
    CR.cancel!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    @test CR.state(sm) === :Unverified
    @test sm.failure === :operation_cancelled
    @test CR.observe_reference!(sm, reference_observation(5)) === nothing
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    now = Ref(Int64(1))
    sm = CR.Coordinator(RECOVERY_OWNER; clock=() -> now[])
    CR.qualify!(sm, loop_observation(1, 3, 3, true; token=UInt64(0)))
    CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    now[] = -1
    @test CR.check_timeout!(sm) === nothing
    @test sm.failure === :clock_error
    @test CR.state(sm) === :Unverified
    @test sm.pending_since_ns == 0
end

@testset "Atomic recovery-open generation and stale release fencing" begin
    sm, _ = qualified_recovery()
    stage = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    CR.recovery_staged!(sm, stage, UInt64(11); loop_generation=UInt64(4))
    # The atomic request already inhibits, but the old closed plan may remain
    # active until its exact forced-open generation adopts at a callback.
    CR.observe_loop!(sm, loop_observation(2, 4, 3, true))
    @test CR.state(sm) === :Opening
    @test sm.failure === nothing
    CR.observe_recovery!(sm, recovery_observation(3))
    @test CR.state(sm) === :Opening
    CR.observe_loop!(sm, loop_observation(4, 4, 4, false))
    @test CR.state(sm) === :RestoringReference
    @test sm.loop_generation == 4
    @test sm.expected_loop_generation == 0
    CR.observe_recovery!(sm, recovery_observation(5))
    CR.observe_reference!(sm, reference_observation(6))
    @test CR.state(sm) === :Holding
    CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    CR.observe_reference!(sm, reference_observation(8; reached=false))
    @test sm.failure === :release_prerequisites_changed
    @test CR.observe_release!(sm, release_observation(7)) === nothing
    @test CR.state(sm) === :Unverified
    sm, _ = restoring_recovery()
    CR.observe_loop!(sm, loop_observation(3, 6, 4, false))
    @test sm.failure === :unexpected_loop_change
end
