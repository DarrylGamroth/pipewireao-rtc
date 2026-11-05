using Test, PipeWireAORTC
import Hsm
import Clocks

const CR = PipeWireAORTC.CorrectionRecovery
const RECOVERY_OWNER = Int64(801)
const RECOVERY_TOKEN = UInt64(17)

loop_observation(
    serial, requested, active, closed; owner = RECOVERY_OWNER, token = RECOVERY_TOKEN
) = CR.LoopObservation(
    owner, token, UInt64(serial), UInt64(requested), UInt64(active), closed
)
recovery_observation(
    serial;
    owner = RECOVERY_OWNER,
    token = RECOVERY_TOKEN,
    requested = 11,
    active = 11,
    status = :applied,
    inhibited = true,
) = CR.RecoveryObservation(
    owner, token, UInt64(serial), UInt64(requested), UInt64(active), status, inhibited
)
reference_observation(
    serial;
    owner = RECOVERY_OWNER,
    token = RECOVERY_TOKEN,
    generation = 11,
    reached = true,
    coherent = true,
    ready = true,
) = CR.ReferenceObservation(
    owner, token, UInt64(serial), UInt64(generation), reached, coherent, ready
)
release_observation(
    serial;
    owner = RECOVERY_OWNER,
    token = RECOVERY_TOKEN,
    generation = 11,
    released = true,
    closed = false,
    reached = true,
    coherent = true,
    ready = true,
) = CR.ReleaseObservation(
    owner,
    token,
    UInt64(serial),
    UInt64(generation),
    released,
    closed,
    reached,
    coherent,
    ready,
)

function qualified_recovery(;
    now = Clocks.CachedNanoClock(100), closed = true, timeout_ms = 5
)
    sm = CR.Coordinator(RECOVERY_OWNER; clock = now, timeout_ms)
    CR.qualify!(sm, loop_observation(1, 3, 3, closed; token = UInt64(0)))
    return sm, now
end
function restoring_recovery(; kwargs...)
    sm, now = qualified_recovery(; kwargs...)
    effect = CR.request_protection!(
        sm, RECOVERY_OWNER, RECOVERY_TOKEN; reason = :saturation
    )
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation = UInt64(4))
    CR.observe_loop!(sm, loop_observation(2, 4, 4, false))
    return sm, now
end
function holding_recovery(; kwargs...)
    sm, now = restoring_recovery(; kwargs...)
    CR.observe_recovery!(sm, recovery_observation(3))
    CR.observe_reference!(sm, reference_observation(4))
    return sm, now
end

@testset "Cached nanosecond recovery clocks preserve exact expiry and errors" begin
    clock = Clocks.CachedNanoClock(100)
    sm = CR.Coordinator(RECOVERY_OWNER; clock, timeout_ms = 5)
    CR.qualify!(sm, loop_observation(1, 3, 3, true; token = UInt64(0)))
    stage = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    @test stage isa CR.StageRecovery && sm.clock === clock && sm.pending_since_ns == 100
    Clocks.advance!(clock, 4_999_999)
    CR.check_timeout!(sm)
    @test CR.state(sm) === :Opening && sm.failure === nothing
    Clocks.advance!(clock, 1)
    CR.check_timeout!(sm)
    @test CR.state(sm) === :Unverified && sm.failure === :operation_timeout
    @test sm.pending_since_ns == 0
    clock = Clocks.CachedNanoClock(100)
    sm = CR.Coordinator(RECOVERY_OWNER; clock)
    CR.qualify!(sm, loop_observation(1, 3, 3, true; token = UInt64(0)))
    Clocks.update!(clock, -1)
    CR.check_timeout!(sm)
    @test CR.state(sm) === :Unverified && sm.failure === :clock_error
    @test CR.Coordinator(RECOVERY_OWNER; clock).clock === clock
end

@testset "Recovery events own admission facts and latch the first failure" begin
    now = Clocks.CachedNanoClock(100)
    sm = CR.Coordinator(RECOVERY_OWNER; clock = now, timeout_ms = 5)
    initial = loop_observation(1, 3, 3, true; token = UInt64(0))
    Hsm.dispatch!(sm, :Qualified, initial)
    @test CR.state(sm) === :Closed
    @test (sm.serial, sm.loop_generation, sm.target_closed) == (1, 3, true)
    request = (;
        owner_instance = RECOVERY_OWNER, token = RECOVERY_TOKEN, reason = :saturation
    )
    Hsm.dispatch!(sm, :Protect, request)
    @test CR.state(sm) === :Opening
    @test (sm.token, sm.reason, sm.target_closed) == (RECOVERY_TOKEN, :saturation, false)
    deadline = sm.pending_since_ns
    Clocks.advance!(now, 1)
    Hsm.dispatch!(sm, :Protect, merge(request, (; token = RECOVERY_TOKEN + UInt64(1))))
    @test sm.token == RECOVERY_TOKEN && sm.pending_since_ns == deadline
    Hsm.dispatch!(sm, :Failed, (; reason = :endpoint_lost, uncertain = false))
    @test CR.state(sm) === :Fault
    @test sm.failure === :endpoint_lost && sm.reference_serial == 0
    @test sm.pending_since_ns == 0
    Hsm.dispatch!(sm, :Failed, (; reason = :later_failure, uncertain = true))
    Hsm.dispatch!(sm, :Protect, request)
    @test CR.state(sm) === :Fault && sm.failure === :endpoint_lost
    @test CR.failed!(sm, :wrapper_failure) === nothing
    @test sm.failure === :endpoint_lost

    sm, _ = holding_recovery()
    Hsm.dispatch!(sm, :Failed, (; reason = :uncertain_outcome, uncertain = true))
    retained = (sm.serial, sm.loop_generation, sm.target_closed, sm.reference_since_ns)
    Hsm.dispatch!(sm, :Qualified, loop_observation(50, 5, 5, false))
    Hsm.dispatch!(sm, :ReferenceObserved, reference_observation(51))
    @test CR.state(sm) === :Unverified && sm.failure === :uncertain_outcome
    @test (sm.serial, sm.loop_generation, sm.target_closed, sm.reference_since_ns) ==
        retained
end

@testset "Reference refresh events preserve release deadlines and reject stale facts" begin
    sm, now = restoring_recovery()
    CR.observe_recovery!(sm, recovery_observation(3))
    Hsm.dispatch!(sm, :ReferenceObserved, reference_observation(4))
    @test CR.state(sm) === :Holding && sm.reference_serial == 4
    Clocks.advance!(now, 1)
    Hsm.dispatch!(sm, :ReferenceObserved, reference_observation(5))
    @test sm.reference_serial == 5 && sm.reference_since_ns == Clocks.time_nanos(now)
    @test sm.pending_since_ns == 0
    request = (; owner_instance = RECOVERY_OWNER, token = RECOVERY_TOKEN, closed = true)
    Hsm.dispatch!(sm, :Release, request)
    @test CR.state(sm) === :Releasing && sm.target_closed
    deadline = sm.pending_since_ns
    Clocks.advance!(now, 1)
    Hsm.dispatch!(sm, :ReferenceObserved, reference_observation(6))
    refreshed = sm.reference_since_ns
    @test sm.reference_serial == 6 && refreshed == Clocks.time_nanos(now)
    Clocks.advance!(now, 1)
    Hsm.dispatch!(sm, :Release, request)
    Hsm.dispatch!(sm, :ReferenceObserved, reference_observation(6))
    Hsm.dispatch!(
        sm, :ReferenceObserved, reference_observation(7; owner = RECOVERY_OWNER + 1)
    )
    Hsm.dispatch!(sm, :ReferenceObserved, reference_observation(7; generation = 10))
    @test sm.serial == 6 && sm.reference_serial == 6 && sm.reference_since_ns == refreshed
    @test sm.pending_since_ns == deadline && CR.state(sm) === :Releasing
    Clocks.update!(now, deadline + sm.timeout_ns)
    CR.check_timeout!(sm)
    @test CR.state(sm) === :Unverified && sm.failure === :operation_timeout
    @test sm.pending_since_ns == 0 && sm.reference_serial == 0
end

@testset "Reference events route invalid evidence and ignore inactive phases" begin
    sm, now = holding_recovery()
    CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    freshness = sm.reference_since_ns
    Clocks.advance!(now, 1)
    Hsm.dispatch!(sm, :ReferenceObserved, reference_observation(5; ready = false))
    @test CR.state(sm) === :Unverified && sm.failure === :release_prerequisites_changed
    @test sm.serial == 5 && sm.reference_serial == 0
    @test sm.reference_since_ns == freshness && sm.pending_since_ns == 0
    Hsm.dispatch!(sm, :Failed, (; reason = :later_failure, uncertain = false))
    @test CR.state(sm) === :Unverified && sm.failure === :release_prerequisites_changed

    sm, _ = restoring_recovery()
    before = (sm.serial, sm.reference_serial, sm.reference_since_ns, sm.pending_since_ns)
    Hsm.dispatch!(sm, :ReferenceObserved, reference_observation(50))
    @test CR.state(sm) === :RestoringReference && sm.failure === nothing
    @test (sm.serial, sm.reference_serial, sm.reference_since_ns, sm.pending_since_ns) ==
        before
    CR.observe_recovery!(sm, recovery_observation(3))
    deadline = sm.pending_since_ns
    Hsm.dispatch!(sm, :ReferenceObserved, reference_observation(4; coherent = false))
    @test CR.state(sm) === :Verifying && sm.failure === nothing
    @test sm.serial == 4 && sm.reference_serial == 0 && sm.pending_since_ns == deadline
end

@testset "Protective recovery hierarchy and explicit close intent" begin
    sm, now = qualified_recovery()
    @test CR.state(sm) === :Closed
    @test Hsm.ancestor(sm, :Closed) === :Operational
    effect = CR.request_protection!(
        sm, RECOVERY_OWNER, RECOVERY_TOKEN; reason = :saturation
    )
    @test effect === CR.StageRecovery(RECOVERY_OWNER, RECOVERY_TOKEN)
    @test CR.state(sm) === :Opening
    @test Hsm.ancestor(sm, CR.state(sm)) === :ProtectiveOpen
    @test sm.reason === :saturation
    @test sm.pending_since_ns == Clocks.time_nanos(now)
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation = UInt64(4))
    Clocks.advance!(now, 1)
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation = UInt64(4)) # no new effect
    @test sm.pending_since_ns == Clocks.time_nanos(now) - 1
    @test CR.observe_loop!(sm, loop_observation(2, 4, 4, false)) === nothing
    @test CR.state(sm) === :RestoringReference
    @test sm.pending_since_ns == Clocks.time_nanos(now)
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
    @test CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN + UInt64(1)) isa
        CR.StageRecovery
end

@testset "Early, stale and mismatched observations cannot close" begin
    sm, now = restoring_recovery()
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    @test_throws ArgumentError CR.request_protection!(
        sm, RECOVERY_OWNER, RECOVERY_TOKEN + UInt64(1)
    )
    CR.observe_reference!(sm, reference_observation(100)) # before scope adoption
    @test CR.state(sm) === :RestoringReference
    CR.observe_recovery!(sm, recovery_observation(3; owner = RECOVERY_OWNER + 1))
    CR.observe_recovery!(sm, recovery_observation(3; token = RECOVERY_TOKEN - UInt64(1)))
    CR.observe_recovery!(sm, recovery_observation(1))
    CR.observe_recovery!(sm, recovery_observation(3; requested = 10, active = 10))
    @test CR.state(sm) === :RestoringReference
    CR.observe_recovery!(sm, recovery_observation(3))
    @test CR.state(sm) === :Verifying
    CR.observe_reference!(sm, reference_observation(3)) # same snapshot as adoption
    CR.observe_reference!(sm, reference_observation(4; generation = 10))
    CR.observe_reference!(sm, reference_observation(4; ready = false))
    @test CR.state(sm) === :Verifying
    CR.observe_reference!(sm, reference_observation(5))
    @test CR.state(sm) === :Holding
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER + 1, RECOVERY_TOKEN)
    @test_throws ArgumentError CR.request_close!(
        sm, RECOVERY_OWNER, RECOVERY_TOKEN - UInt64(1)
    )
    Clocks.advance!(now, Int64(5_000_000))
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    @test CR.state(sm) === :Holding
    CR.observe_reference!(sm, reference_observation(6))
    @test CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN) isa CR.ReleaseRecovery
    @test CR.observe_release!(sm, release_observation(6)) === nothing
    @test CR.observe_release!(sm, release_observation(7; generation = 10)) === nothing
    @test CR.observe_release!(sm, release_observation(7; released = false)) === nothing
    @test CR.state(sm) === :Releasing
    @test CR.observe_release!(sm, release_observation(8)) isa CR.CloseLoop
    @test CR.observe_release!(sm, release_observation(9)) === nothing
end

@testset "Release revalidates each closure prerequisite" begin
    for change in
        ((; closed = true), (; reached = false), (; coherent = false), (; ready = false))
        sm, _ = holding_recovery()
        CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
        @test CR.observe_release!(sm, release_observation(5; change...)) === nothing
        @test CR.state(sm) === :Unverified
        @test sm.failure === :release_prerequisites_changed
        @test CR.observe_release!(sm, release_observation(6)) === nothing
        @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    end
    sm, _ = holding_recovery()
    CR.observe_reference!(sm, reference_observation(5; coherent = false))
    @test_throws ArgumentError CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
end

@testset "Timeouts latch uncertain outcomes at every pending phase" begin
    for phase in (:Opening, :RestoringReference, :Verifying, :Releasing, :Closing)
        sm, now = qualified_recovery()
        stage = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
        CR.recovery_staged!(sm, stage, UInt64(11); loop_generation = UInt64(4))
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
        Clocks.advance!(now, Int64(5_000_000))
        # Late valid adoption is checked for timeout before accepting facts.
        @test CR.observe_loop!(sm, loop_observation(50, 5, 5, true)) === nothing
        @test CR.state(sm) === :Unverified
        @test sm.failure === :operation_timeout
        @test sm.pending_since_ns == 0
        CR.qualify!(sm, loop_observation(51, 5, 5, true; token = RECOVERY_TOKEN))
        @test CR.state(sm) === :Unverified
        @test CR.observe_recovery!(sm, recovery_observation(52)) === nothing
        @test_throws ArgumentError CR.request_protection!(
            sm, RECOVERY_OWNER, RECOVERY_TOKEN + UInt64(1)
        )
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
    CR.qualify!(replacement, loop_observation(1, 3, 3, false; token = UInt64(0)))
    @test CR.state(replacement) === :Unverified
    CR.qualify!(
        replacement,
        loop_observation(1, 3, 3, false; owner = RECOVERY_OWNER + 1, token = UInt64(0)),
    )
    @test CR.state(replacement) === :Open
    sm, _ = holding_recovery()
    CR.observe_loop!(sm, loop_observation(5, 4, 4, true))
    @test sm.failure === :unexpected_loop_change
    sm, _ = restoring_recovery()
    CR.observe_recovery!(sm, recovery_observation(3; inhibited = false))
    @test sm.failure === :missing_closure_inhibition
end

@testset "Qualification and clock inputs are bounded" begin
    @test_throws ArgumentError CR.Coordinator(Int64(0))
    for timeout_ms in (0, -1, 60_001, true, typemax(Int128))
        @test_throws ArgumentError CR.Coordinator(RECOVERY_OWNER; timeout_ms)
    end
    for clock in (() -> -1, () -> true, () -> 1.5, () -> typemax(UInt128))
        @test_throws TypeError CR.Coordinator(RECOVERY_OWNER; clock)
    end
    sm = CR.Coordinator(RECOVERY_OWNER)
    CR.qualify!(sm, loop_observation(1, 4, 3, true; token = UInt64(0)))
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
    now = Clocks.CachedNanoClock(1)
    sm = CR.Coordinator(RECOVERY_OWNER; clock = now)
    CR.qualify!(sm, loop_observation(1, 3, 3, true; token = UInt64(0)))
    CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    Clocks.update!(now, -1)
    @test CR.check_timeout!(sm) === nothing
    @test sm.failure === :clock_error
    @test CR.state(sm) === :Unverified
    @test sm.pending_since_ns == 0
end

@testset "Atomic recovery-open generation and stale release fencing" begin
    sm, _ = qualified_recovery()
    stage = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    CR.recovery_staged!(sm, stage, UInt64(11); loop_generation = UInt64(4))
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
    CR.observe_reference!(sm, reference_observation(8; reached = false))
    @test sm.failure === :release_prerequisites_changed
    @test CR.observe_release!(sm, release_observation(7)) === nothing
    @test CR.state(sm) === :Unverified
    sm, _ = restoring_recovery()
    CR.observe_loop!(sm, loop_observation(3, 6, 4, false))
    @test sm.failure === :unexpected_loop_change
end

function coupled_recovery()
    now = Clocks.CachedNanoClock(100)
    sm = CR.Coordinator(RECOVERY_OWNER; clock = now, timeout_ms = 5, controllers = 2)
    observation(serial, requested, active, closed; token = RECOVERY_TOKEN) =
        CR.LoopObservation(
            RECOVERY_OWNER,
            token,
            UInt64(serial),
            map(UInt64, requested),
            map(UInt64, active),
            closed,
        )
    CR.qualify!(sm, observation(1, (3, 9), (3, 9), (true, false); token = UInt64(0)))
    return sm, now, observation
end

@testset "Coupled recovery fences exact generations and independent reclosure" begin
    sm, now, observation = coupled_recovery()
    @test CR.state(sm) === :PartiallyClosed
    effect = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation = (UInt64(4), UInt64(10)))
    CR.observe_loop!(sm, observation(2, (4, 10), (4, 9), (false, false)))
    @test CR.state(sm) === :Opening
    @test sm.loop_generation == (3, 9)
    CR.observe_loop!(sm, observation(3, (4, 10), (4, 10), (false, false)))
    @test CR.state(sm) === :RestoringReference
    @test sm.loop_generation == (4, 10)
    CR.observe_recovery!(sm, recovery_observation(4))
    CR.observe_reference!(sm, reference_observation(5))
    @test CR.state(sm) === :Holding
    @test_throws ArgumentError CR.request_close!(
        sm, RECOVERY_OWNER, RECOVERY_TOKEN; closed = (false, false)
    )
    release = CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN; closed = (false, true))
    @test release isa CR.ReleaseRecovery
    close = CR.observe_release!(sm, release_observation(6; closed = (false, false)))
    @test close isa CR.CloseLoop
    CR.staged!(sm, close, (UInt64(4), UInt64(11)))
    CR.observe_loop!(sm, observation(7, (4, 11), (4, 10), (false, false)))
    @test CR.state(sm) === :Closing
    CR.observe_loop!(sm, observation(8, (4, 11), (4, 11), (false, true)))
    @test CR.state(sm) === :PartiallyClosed
    @test sm.loop_generation == (4, 11)
    @test_throws ArgumentError CR.request_close!(
        sm, RECOVERY_OWNER, RECOVERY_TOKEN; closed = (true, true)
    )
    @test_throws ArgumentError CR.request_close!(
        sm, RECOVERY_OWNER, RECOVERY_TOKEN; closed = (true, false), released = true
    )
    CR.observe_reference!(sm, reference_observation(9; ready = false))
    @test_throws ArgumentError CR.request_close!(
        sm, RECOVERY_OWNER, RECOVERY_TOKEN; closed = (true, true), released = true
    )
    CR.observe_reference!(sm, reference_observation(10))
    remaining = CR.request_close!(
        sm, RECOVERY_OWNER, RECOVERY_TOKEN; closed = (true, true), released = true
    )
    @test remaining isa CR.CloseLoop # no second release or recovery effect
    CR.staged!(sm, remaining, (UInt64(5), UInt64(11)))
    CR.observe_loop!(sm, observation(11, (5, 11), (5, 11), (true, true)))
    @test CR.state(sm) === :Closed
    @test sm.failure === nothing
end

@testset "Coupled adoption cannot hide a stale or conflicting component" begin
    for (requested, active) in (((4, 10), (5, 9)), ((3, 11), (3, 11)), ((5, 10), (4, 10)))
        sm, _, observation = coupled_recovery()
        effect = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
        CR.recovery_staged!(
            sm, effect, UInt64(11); loop_generation = (UInt64(4), UInt64(10))
        )
        CR.observe_loop!(sm, observation(2, requested, active, (false, false)))
        @test sm.failure === :conflicting_loop_generation
        @test CR.state(sm) === :Unverified
    end
    sm, _, _ = coupled_recovery()
    effect = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation = (UInt64(3), UInt64(10)))
    @test sm.failure === :invalid_loop_generation # every controller must be forced open
    sm, _, _ = coupled_recovery()
    effect = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation = UInt64(10))
    @test sm.failure === :loop_scope_mismatch
    for count in (0, 17, true)
        @test_throws ArgumentError CR.Coordinator(RECOVERY_OWNER; controllers = count)
    end
end

@testset "Loop events preserve pending adoption and forced-open monitoring" begin
    sm, now = qualified_recovery()
    before = (sm.serial, sm.loop_generation, sm.target_closed, sm.pending_since_ns)
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(2, 4, 4, false; token = UInt64(0)))
    @test CR.state(sm) === :Closed
    @test (sm.serial, sm.loop_generation, sm.target_closed, sm.pending_since_ns) == before
    stage = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    CR.recovery_staged!(sm, stage, UInt64(11); loop_generation = UInt64(4))
    deadline = sm.pending_since_ns
    Clocks.advance!(now, 1)
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(2, 4, 3, true))
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(3, 3, 3, true))
    Hsm.dispatch!(sm, :RecoveryObserved, recovery_observation(4))
    @test CR.state(sm) === :Opening && sm.serial == 1 && sm.loop_generation == 3
    @test sm.pending_since_ns == deadline && sm.failure === nothing
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(5, 4, 4, false))
    @test CR.state(sm) === :RestoringReference && sm.serial == 5
    @test sm.loop_generation == 4 && sm.expected_loop_generation == 0
    deadline = sm.pending_since_ns
    Clocks.advance!(now, 1)
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(6, 4, 3, true))
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(5, 4, 4, false))
    @test sm.serial == 5 && sm.pending_since_ns == deadline
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(7, 4, 4, false))
    @test sm.serial == 7 && sm.pending_since_ns == deadline
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(8, 4, 4, true))
    @test CR.state(sm) === :Unverified && sm.failure === :unexpected_loop_change
    @test sm.serial == 7 && sm.pending_since_ns == 0

    sm, _ = holding_recovery()
    CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    close = CR.observe_release!(sm, release_observation(5))
    CR.staged!(sm, close, UInt64(5))
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(6, 5, 4, false))
    @test CR.state(sm) === :Closing && sm.serial == 5
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(7, 5, 5, true))
    @test CR.state(sm) === :Closed && sm.serial == 7 && sm.loop_generation == 5

    sm, _, _ = coupled_recovery()
    effect = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    CR.recovery_staged!(sm, effect, UInt64(11); loop_generation = (UInt64(4), UInt64(10)))
    Hsm.dispatch!(sm, :LoopObserved, loop_observation(2, 4, 4, false))
    @test CR.state(sm) === :Unverified && sm.failure === :loop_scope_mismatch
    @test sm.serial == 1 && sm.loop_generation == (3, 9)

    sm, _, _ = coupled_recovery()
    CR.observe_loop!(sm, loop_observation(2, 4, 4, false; token = UInt64(0)))
    @test sm.failure === :loop_scope_mismatch # Shape validation precedes phase filtering.
end

@testset "Recovery observations are handled only while restoring the reference" begin
    sm, _ = restoring_recovery()
    deadline = sm.pending_since_ns
    Hsm.dispatch!(
        sm, :RecoveryObserved, recovery_observation(3; requested = 10, active = 10)
    )
    @test CR.state(sm) === :RestoringReference && sm.serial == 2
    @test sm.pending_since_ns == deadline && sm.failure === nothing
    Hsm.dispatch!(sm, :RecoveryObserved, recovery_observation(4))
    @test CR.state(sm) === :Verifying && sm.serial == 4
    Hsm.dispatch!(sm, :RecoveryObserved, recovery_observation(5; status = :failed))
    @test CR.state(sm) === :Verifying && sm.serial == 4 && sm.failure === nothing
    for (status, expected) in ((:failed, :Fault), (:unknown, :Unverified))
        sm, _ = restoring_recovery()
        Hsm.dispatch!(sm, :RecoveryObserved, recovery_observation(3; status))
        @test CR.state(sm) === expected
        @test sm.failure === (status === :failed ? :recovery_failed : :recovery_unknown)
        @test sm.serial == 2
    end
end

@testset "Staging, cancellation and deadline events follow the active phase" begin
    sm, now = qualified_recovery()
    Hsm.dispatch!(sm, :DeadlineChecked, Clocks.time_nanos(now))
    Hsm.dispatch!(sm, :Cancelled, (; owner_instance = RECOVERY_OWNER, token = UInt64(0)))
    @test CR.state(sm) === :Closed && sm.failure === nothing
    stage = CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    deadline = sm.pending_since_ns
    staged = (; effect = stage, generation = UInt64(11), loop_generation = UInt64(4))
    Hsm.dispatch!(sm, :RecoveryStaged, staged)
    Clocks.advance!(now, 1)
    Hsm.dispatch!(sm, :RecoveryStaged, staged)
    @test sm.recovery_generation == 11 && sm.expected_loop_generation == 4
    @test sm.pending_since_ns == deadline
    Hsm.dispatch!(
        sm,
        :LoopStaged,
        (; effect = CR.CloseLoop(RECOVERY_OWNER, RECOVERY_TOKEN), generation = UInt64(5)),
    )
    @test sm.expected_loop_generation == 4 && sm.failure === nothing
    Hsm.dispatch!(sm, :DeadlineChecked, deadline + sm.timeout_ns - Int64(1))
    @test CR.state(sm) === :Opening && sm.pending_since_ns == deadline
    Hsm.dispatch!(sm, :DeadlineChecked, deadline + sm.timeout_ns)
    @test CR.state(sm) === :Unverified && sm.failure === :operation_timeout
    @test sm.pending_since_ns == 0
    Hsm.dispatch!(sm, :RecoveryStaged, merge(staged, (; generation = UInt64(12))))
    Hsm.dispatch!(
        sm, :Cancelled, (; owner_instance = RECOVERY_OWNER, token = RECOVERY_TOKEN)
    )
    @test sm.recovery_generation == 11 && sm.failure === :operation_timeout

    sm, _ = holding_recovery()
    Hsm.dispatch!(
        sm, :Cancelled, (; owner_instance = RECOVERY_OWNER + 1, token = RECOVERY_TOKEN)
    )
    @test CR.state(sm) === :Holding && sm.failure === nothing
    Hsm.dispatch!(
        sm, :Cancelled, (; owner_instance = RECOVERY_OWNER, token = RECOVERY_TOKEN)
    )
    @test CR.state(sm) === :Unverified && sm.failure === :operation_cancelled
end

@testset "Qualification and release dispatch preserve refusal and clock semantics" begin
    now = Clocks.CachedNanoClock(100)
    sm = CR.Coordinator(RECOVERY_OWNER; clock = now)
    CR.qualify!(sm, loop_observation(1, 3, 3, true; token = UInt64(0)))
    Clocks.update!(now, -1)
    CR.qualify!(sm, loop_observation(2, 4, 4, false; token = UInt64(0)))
    @test CR.state(sm) === :Closed && sm.failure === nothing
    @test sm.serial == 1

    sm, _ = holding_recovery()
    release = CR.request_close!(sm, RECOVERY_OWNER, RECOVERY_TOKEN; released = true)
    @test release isa CR.ReleaseRecovery && CR.state(sm) === :Releasing
    Hsm.dispatch!(sm, :ReleaseObserved, release_observation(5; released = false))
    @test sm.serial == 4 && CR.state(sm) === :Releasing
    Hsm.dispatch!(sm, :ReleaseObserved, release_observation(5; closed = true))
    @test sm.serial == 5 && sm.failure === :release_prerequisites_changed
    @test CR.state(sm) === :Unverified && sm.pending_since_ns == 0
    @test CR.observe_release!(sm, release_observation(6)) === nothing
end

@testset "Signed recovery origins and checked clock spans" begin
    for origin in (Int64(-10_000_000), Int64(0), Int64(2)^53 + 1)
        clock = Clocks.CachedNanoClock(origin)
        sm, _ = qualified_recovery(; now = clock, timeout_ms = 1)
        CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
        @test sm.pending_since_ns === origin
        Clocks.advance!(clock, 999_999)
        CR.check_timeout!(sm)
        @test CR.state(sm) === :Opening
        Clocks.advance!(clock, 1)
        CR.check_timeout!(sm)
        @test sm.failure === :operation_timeout
    end
    sm, clock = qualified_recovery(; now = Clocks.CachedNanoClock(-10))
    Clocks.update!(clock, -11)
    CR.check_timeout!(sm)
    @test sm.failure === :clock_error && CR.state(sm) === :Unverified
    sm, _ = qualified_recovery(; now = Clocks.CachedNanoClock(typemax(Int64) - 1))
    @test_throws ArgumentError CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    @test sm.failure === :clock_error && CR.state(sm) === :Unverified
    sm, clock = qualified_recovery(; now = Clocks.CachedNanoClock(typemin(Int64)))
    CR.request_protection!(sm, RECOVERY_OWNER, RECOVERY_TOKEN)
    Clocks.update!(clock, 0)
    CR.check_timeout!(sm)
    @test sm.failure === :clock_error
end

@testset "Qualification rejects a regressing signed clock" begin
    clock = Clocks.CachedNanoClock(-10)
    sm = CR.Coordinator(RECOVERY_OWNER; clock)
    Clocks.update!(clock, -11)
    CR.qualify!(sm, loop_observation(1, 3, 3, true; token = UInt64(0)))
    @test sm.failure === :clock_error && CR.state(sm) === :Unverified
end
