# Optional selector: julia --startup-file=no --project=. test/hsm_allocations.jl
# Nominal control HSM paths only: no native timer, core, transport or science.
# Constructors and 128 warmup cycles precede the measured region. Immutable
# observation/effect construction and the real correction clock are included.
# Preparation includes a counted, concrete nanosecond clock read on each ready check.
using PipeWireAORTC, Test
import Clocks
const CL = PipeWireAORTC.CorrectionLoops
const CR = PipeWireAORTC.CorrectionRecovery
const CP = PipeWireAORTC.CalibrationPreparation

mutable struct PreparationReadClock <: Clocks.AbstractNanoClock
    at::Int64
    reads::Int
end
function Clocks.time_nanos(clock::PreparationReadClock)
    clock.reads += 1
    return clock.at
end

function loop_cycle!(sm)
    generation = sm.requested_generation + 1
    closed = !sm.applied_closed
    CL.requested!(sm, sm.instance, generation, sm.active_generation, closed)
    CL.observed!(sm, sm.instance, generation, generation, closed)
    return nothing
end

function recovery_cycle!(sm)
    owner = sm.owner_instance
    token = sm.token + UInt64(1)
    serial = sm.serial
    generation = sm.loop_generation + UInt64(1)
    stage = CR.request_protection!(sm, owner, token)
    CR.recovery_staged!(sm, stage, token; loop_generation = generation)
    CR.observe_loop!(
        sm,
        CR.LoopObservation(owner, token, serial + UInt64(1), generation, generation, false),
    )
    CR.observe_recovery!(
        sm,
        CR.RecoveryObservation(
            owner, token, serial + UInt64(2), token, token, :applied, true
        ),
    )
    CR.observe_reference!(
        sm,
        CR.ReferenceObservation(owner, token, serial + UInt64(3), token, true, true, true),
    )
    CR.request_close!(sm, owner, token)
    close = CR.observe_release!(
        sm,
        CR.ReleaseObservation(
            owner, token, serial + UInt64(4), token, true, false, true, true, true
        ),
    )::CR.CloseLoop
    generation += UInt64(1)
    CR.staged!(sm, close, generation)
    CR.observe_loop!(
        sm,
        CR.LoopObservation(owner, token, serial + UInt64(5), generation, generation, true),
    )
    return nothing
end

function coupled_recovery_cycle!(sm)
    owner = sm.owner_instance
    token = sm.token + UInt64(1)
    serial = sm.serial
    generation = map(value -> value + UInt64(1), sm.loop_generation)
    stage = CR.request_protection!(sm, owner, token)
    CR.recovery_staged!(sm, stage, token; loop_generation = generation)
    CR.observe_loop!(
        sm,
        CR.LoopObservation(
            owner, token, serial + UInt64(1), generation, generation, (false, false)
        ),
    )
    CR.observe_recovery!(
        sm,
        CR.RecoveryObservation(
            owner, token, serial + UInt64(2), token, token, :applied, true
        ),
    )
    CR.observe_reference!(
        sm,
        CR.ReferenceObservation(owner, token, serial + UInt64(3), token, true, true, true),
    )
    CR.request_close!(sm, owner, token)
    close = CR.observe_release!(
        sm,
        CR.ReleaseObservation(
            owner,
            token,
            serial + UInt64(4),
            token,
            true,
            (false, false),
            true,
            true,
            true,
        ),
    )::CR.CloseLoop
    generation = map(value -> value + UInt64(1), generation)
    CR.staged!(sm, close, generation)
    CR.observe_loop!(
        sm,
        CR.LoopObservation(
            owner, token, serial + UInt64(5), generation, generation, (true, true)
        ),
    )
    return nothing
end

function measure()
    loop = CL.Loop("correction:closed", Int64(1))
    CL.observed!(loop, Int64(1), Int64(0), Int64(0), false)
    recovery = CR.Coordinator(Int64(1))
    CR.qualify!(
        recovery,
        CR.LoopObservation(Int64(1), UInt64(0), UInt64(1), UInt64(1), UInt64(1), true),
    )
    coupled = CR.Coordinator(Int64(1); controllers = 2)
    CR.qualify!(
        coupled,
        CR.LoopObservation(
            Int64(1),
            UInt64(0),
            UInt64(1),
            (UInt64(1), UInt64(1)),
            (UInt64(1), UInt64(1)),
            (true, true),
        ),
    )
    clock = PreparationReadClock(Int64(11_000_000_000), 0)
    request = CP.Request(;
        run = 1,
        serial = 1,
        stage = "dark",
        condition = "blocked",
        configuration_identity = "detector-epoch",
        kind = :manual,
        issued_at = Int64(10_000_000_000),
        deadline = Int64(20_000_000_000),
    )
    preparation = CP.Procedure(request; clock)
    confirmation = CP.Confirmation(
        request; observed_at = Int64(11_000_000_000), witness = "operator"
    )
    CP.complete!(preparation, confirmation)
    for _ in 1:128
        loop_cycle!(loop)
        recovery_cycle!(recovery)
        coupled_recovery_cycle!(coupled)
        CP.check_current!(preparation)
    end
    loop_bytes = @allocated for _ in 1:1000
        loop_cycle!(loop)
    end
    recovery_bytes = @allocated for _ in 1:1000
        recovery_cycle!(recovery)
    end
    coupled_bytes = @allocated for _ in 1:1000
        coupled_recovery_cycle!(coupled)
    end
    preparation_bytes = @allocated for _ in 1:1000
        CP.check_current!(preparation)
    end
    @test loop.failure === nothing
    @test recovery.failure === nothing
    @test loop.requested_generation == 1128
    @test loop.active_generation == 1128
    @test recovery.token == 1128
    @test recovery.serial == 1 + 5 * 1128
    @test recovery.loop_generation == 1 + 2 * 1128
    @test CR.state(recovery) === :Closed
    @test loop_bytes == 0
    @test recovery_bytes == 0
    @test coupled_bytes == 0
    @test CR.state(coupled) === :Closed && coupled.failure === nothing
    @test coupled.serial == 1 + 5 * 1128 && coupled.token == 1128
    @test coupled.loop_generation == (UInt64(2257), UInt64(2257))
    @test preparation_bytes == 0
    @test clock.reads == 1130
    @test preparation.state === :ready && preparation.confirmation === confirmation
    println("Julia ", VERSION, "; default threads=", Threads.nthreads(:default))
    println("1,000 loop cycles, bytes=", loop_bytes)
    println("1,000 recovery cycles, bytes=", recovery_bytes)
    println("1,000 coupled recovery cycles, bytes=", coupled_bytes)
    println("1,000 ready preparation checks, bytes=", preparation_bytes)
end

@testset "Warmed HSM allocation budgets" begin
    measure()
end
