module CalibrationPreparationTests
using Test, PipeWireAORTC
import Hsm
import Clocks
const P = PipeWireAORTC.CalibrationPreparation
const SECOND = Int64(1_000_000_000)

# A concrete clock probe measures reads and read failure without production adapters.
struct PreparationClock <: Clocks.AbstractNanoClock
    at::Base.RefValue{Int64}
    reads::Base.RefValue{Int}
    failed::Base.RefValue{Bool}
end
PreparationClock(at, reads = Ref(0); failed = Ref(false)) =
    PreparationClock(at, reads, failed)
function Clocks.time_nanos(clock::PreparationClock)
    clock.reads[] += 1
    clock.failed[] && error("Clock unavailable")
    return clock.at[]
end

request(;
    run = UInt64(91),
    serial = UInt64(1),
    stage = "dark",
    condition = "blocked",
    configuration_identity = "detector-configuration-sha256",
    kind = :manual,
    issued_at = 10 * SECOND,
    deadline = 20 * SECOND,
) = P.Request(;
    run, serial, stage, condition, configuration_identity, kind, issued_at, deadline
)
confirmation(r; observed_at = 11 * SECOND, witness = "operator-17") =
    P.Confirmation(r; observed_at, witness)

@testset "Cached nanosecond clocks preserve preparation expiry and regression" begin
    clock = Clocks.CachedNanoClock(11_000_000_000)
    p = P.Procedure(request(); clock)
    c = confirmation(p.request)
    @test p.clock === clock && P.complete!(p, c) === c
    Clocks.advance!(clock, 8_999_999_999)
    @test P.check_current!(p) === c
    Clocks.advance!(clock, 1)
    @test_throws ArgumentError P.check_current!(p)
    @test p.state === :expired && p.reason == "Deadline expired"
    for regressed in (10_000_000_000, -1)
        clock = Clocks.CachedNanoClock(11_000_000_000)
        p = P.Procedure(request(); clock)
        P.complete!(p, confirmation(p.request))
        Clocks.update!(clock, regressed)
        @test_throws ArgumentError P.check_current!(p)
        @test p.state === :invalidated && p.reason == "Invalid monotonic clock"
        @test p.last_at == 11 * SECOND
        Clocks.update!(clock, 12_000_000_000)
        @test_throws ArgumentError P.check_current!(p)
        @test p.state === :invalidated
    end
end

@testset "signed preparation windows retain individual nanoseconds" begin
    for origin in (typemin(Int64), -Int64(2)^60, Int64(2)^53 + 1, typemax(Int64) - 2)
        r = request(
            issued_at = origin, deadline = Base.Checked.checked_add(origin, Int64(2))
        )
        clock = Clocks.CachedNanoClock(origin)
        p = P.Procedure(r; clock)
        c = confirmation(r; observed_at = origin)
        @test p.last_at === origin && r.issued_at === origin
        @test P.complete!(p, c) === c
        Clocks.advance!(clock, Int64(1))
        @test P.check_current!(p) === c
        Clocks.advance!(clock, Int64(1))
        @test_throws ArgumentError P.check_current!(p)
        @test p.state === :expired
    end
    @test_throws ArgumentError request(issued_at = big(typemin(Int64)) - 1)
    @test_throws ArgumentError request(deadline = big(typemax(Int64)) + 1)
    @test_throws ArgumentError confirmation(
        request(); observed_at = big(typemax(Int64)) + 1
    )
    @test_throws ArgumentError request(issued_at = 10.0)
end

@testset "preparation request and evidence validation" begin
    r = request()
    @test r.run === UInt64(91)
    @test r == request()
    @test r != request(serial = 2)
    for kwargs in (
        (; run = 0),
        (; run = -1),
        (; serial = 0),
        (; serial = big(2)^64),
        (; stage = ""),
        (; stage = " "),
        (; condition = "x"^257),
        (; configuration_identity = "x\0y"),
        (; kind = :cached),
        (; issued_at = NaN),
        (; deadline = Inf),
        (; deadline = 10 * SECOND),
        (; deadline = 9 * SECOND),
    )
        @test_throws ArgumentError request(; kwargs...)
    end
    @test_throws ArgumentError request(stage = String(UInt8[0xff]))
    @test_throws ArgumentError request(stage = "é"^129)
    @test request(stage = "é"^128).stage == "é"^128
    for kwargs in (
        (; observed_at = Inf),
        (; witness = ""),
        (; witness = " "),
        (; witness = "x"^1025),
        (; witness = "operator\0other"),
    )
        @test_throws ArgumentError confirmation(r; kwargs...)
    end
    @test_throws TypeError P.Procedure(r; clock = () -> NaN)
end

@testset "manual, simulated and service evidence admission" begin
    for (kind, witness) in (
        (:manual, "operator-17"),
        (:simulated, "graph-epoch-41"),
        (:service, "mechanism-service-epoch-8"),
    )
        now = Clocks.CachedNanoClock(11 * SECOND)
        r = request(; kind)
        p = P.Procedure(r; clock = now)
        @test p.state == :pending
        @test p.confirmation === nothing
        @test_throws ArgumentError P.check_current!(p)
        c = confirmation(r; witness)
        @test P.complete!(p, c) === c
        @test p.state == :ready
        @test p.reason === nothing
        @test P.check_current!(p) === c
        Clocks.update!(now, 20 * SECOND - 1)
        @test P.check_current!(p) === c
        Clocks.update!(now, 20 * SECOND)
        @test_throws ArgumentError P.check_current!(p)
        @test p.state == :expired
        @test p.confirmation === c
        @test_throws ArgumentError P.complete!(p, c)
        @test p.state == :expired
    end
end

@testset "exact request correlation fences stale and foreign evidence" begin
    for wrong in (
        request(run = 92),
        request(serial = 2),
        request(stage = "reference"),
        request(condition = "illuminated"),
        request(configuration_identity = "new-detector-epoch"),
        request(kind = :service),
        request(issued_at = 9 * SECOND),
        request(deadline = 21 * SECOND),
    )
        p = P.Procedure(request(); clock = Clocks.CachedNanoClock(11 * SECOND))
        @test_throws ArgumentError P.complete!(p, confirmation(wrong))
        @test p.state == :invalidated
        @test p.confirmation === nothing
        @test_throws ArgumentError P.complete!(p, confirmation(p.request))
        @test_throws ArgumentError P.check_current!(p)
    end
    # Exact incarnations are adapter-validated witnesses, not guessed from run IDs.
    p = P.Procedure(request(kind = :service); clock = Clocks.CachedNanoClock(11 * SECOND))
    P.complete!(p, confirmation(p.request; witness = "service-epoch-4"))
    P.invalidate!(p, "Service restarted as epoch 5")
    @test_throws ArgumentError P.complete!(
        p, confirmation(p.request; witness = "service-epoch-5")
    )
    @test_throws ArgumentError P.check_current!(p)
    @test p.confirmation.witness == "service-epoch-4"
end

@testset "observation boundaries and delayed delivery" begin
    for (at, observed_at, state) in (
        (11 * SECOND, 9 * SECOND, :invalidated),
        (11 * SECOND, 12 * SECOND, :invalidated),
        (20 * SECOND, 11 * SECOND, :expired),
        (21 * SECOND, 20 * SECOND, :expired),
        (9 * SECOND, 9 * SECOND, :invalidated),
    )
        p = P.Procedure(request(); clock = Clocks.CachedNanoClock(at))
        @test_throws ArgumentError P.complete!(p, confirmation(p.request; observed_at))
        @test p.state == state
        @test_throws ArgumentError P.check_current!(p)
    end
    p = P.Procedure(request(); clock = Clocks.CachedNanoClock(10 * SECOND))
    c = confirmation(p.request; observed_at = 10 * SECOND)
    @test P.complete!(p, c) === c
    @test P.check_current!(p) === c
end

@testset "cancellation, invalidation and duplicate completion cannot revive" begin
    for ready in (false, true), event in (:cancel, :invalidate, :duplicate)
        event == :duplicate && !ready && continue
        p = P.Procedure(request(); clock = Clocks.CachedNanoClock(11 * SECOND))
        c = confirmation(p.request)
        ready && P.complete!(p, c)
        if event == :cancel
            P.cancel!(p)
            @test p.state == :cancelled
        elseif event == :invalidate
            P.invalidate!(p, "Optical condition lost")
            @test p.state == :invalidated
        else
            @test_throws ArgumentError P.complete!(p, c)
            @test p.state == :invalidated
        end
        state, reason = p.state, p.reason
        @test_throws ArgumentError P.check_current!(p)
        @test_throws ArgumentError P.complete!(p, c)
        P.cancel!(p)
        P.invalidate!(p, "Another event")
        P.expire!(p)
        @test (p.state, p.reason) == (state, reason)
        @test p.confirmation === (ready ? c : nothing)
    end
    now = Clocks.CachedNanoClock(11 * SECOND)
    p = P.Procedure(request(); clock = now)
    P.expire!(p)
    @test p.state == :pending
    Clocks.update!(now, 20 * SECOND)
    P.expire!(p)
    @test p.state == :expired
    @test_throws ArgumentError P.complete!(p, confirmation(p.request))
    p = P.Procedure(request(); clock = Clocks.CachedNanoClock(11 * SECOND))
    @test_throws ArgumentError P.invalidate!(p, "x"^1025)
    @test p.state == :pending
end

@testset "monotonic clock failure and single-task ownership" begin
    for bad in (typemin(Int64), 10 * SECOND)
        now = Clocks.CachedNanoClock(11 * SECOND)
        p = P.Procedure(request(); clock = now)
        P.complete!(p, confirmation(p.request))
        Clocks.update!(now, bad)
        @test_throws ArgumentError P.check_current!(p)
        @test p.state == :invalidated
    end
    failed = Ref(false)
    p = P.Procedure(request(); clock = PreparationClock(Ref(11 * SECOND); failed))
    P.complete!(p, confirmation(p.request))
    failed[] = true
    @test_throws ArgumentError P.check_current!(p)
    @test p.state == :invalidated
    failed[] = false
    @test_throws ArgumentError P.check_current!(p)
    p = P.Procedure(request(); clock = Clocks.CachedNanoClock(11 * SECOND))
    c = confirmation(p.request)
    for event in (
        () -> P.complete!(p, c),
        () -> P.check_current!(p),
        () -> P.cancel!(p),
        () -> P.expire!(p),
        () -> P.invalidate!(p, "Lost"),
    )
        error = fetch(@async try
            event()
            nothing
        catch error
            error
        end)
        @test error isa ArgumentError
        @test p.state == :pending
    end
    @test P.complete!(p, c) === c
end

@testset "preparation hierarchy owns direct completion and terminal rejection" begin
    now, reads = Ref(11 * SECOND), Ref(0)
    p = P.Procedure(request(); clock = PreparationClock(now, reads))
    @test reads[] == 1
    @test Hsm.current(p) === :Pending && Hsm.ancestor(p, :Pending) === :Active
    @test p.state === :pending && :state in propertynames(p)
    @test :state ∉ fieldnames(typeof(p))
    @test propertynames(p) ==
        (:request, :clock, :owner, :state, :confirmation, :reason, :last_at)
    c = confirmation(p.request)
    Hsm.dispatch!(p, :Complete, c)
    @test p.state === :ready && Hsm.current(p) === :Ready
    @test p.confirmation === c && reads[] == 2
    @test Hsm.ancestor(p, :Ready) === :Active
    @test_throws ArgumentError Hsm.dispatch!(p, :Complete, c)
    @test p.state === :invalidated && p.reason == "Preparation is not pending"
    @test Hsm.ancestor(p, :Invalidated) === :Terminal
    @test p.confirmation === c && reads[] == 2
    now[] = typemin(Int64)
    for event in (:Cancel, :Expire)
        Hsm.dispatch!(p, event)
        @test p.state === :invalidated && reads[] == 2
    end
    @test_throws ArgumentError Hsm.dispatch!(p, :Invalidate, "x"^1025)
    @test_throws ArgumentError P.invalidate!(p, "")
    @test_throws ArgumentError Hsm.dispatch!(p, :Complete, c)
    @test_throws ArgumentError P.check_current!(p)
    @test p.reason == "Preparation is not pending" && reads[] == 2
end

@testset "preparation events preserve deadline sampling and owning task" begin
    now, reads = Ref(20 * SECOND), Ref(0)
    p = P.Procedure(request(); clock = PreparationClock(now, reads))
    @test p.state === :expired && p.reason == "Deadline expired" && reads[] == 1
    @test Hsm.ancestor(p, :Expired) === :Terminal
    @test_throws ArgumentError P.check_current!(p)
    @test reads[] == 1
    now[] = 11 * SECOND
    p = P.Procedure(request(); clock = PreparationClock(now, reads))
    sampled = reads[]
    error = fetch(@async try
        Hsm.dispatch!(p, :Cancel)
        nothing
    catch error
        error
    end)
    @test error isa ArgumentError && p.state === :pending && reads[] == sampled
    Hsm.dispatch!(p, :Expire)
    @test p.state === :pending && reads[] == sampled + 1
    now[] = 20 * SECOND
    Hsm.dispatch!(p, :Expire)
    @test p.state === :expired && p.last_at == 20 * SECOND && reads[] == sampled + 2
    @test_throws ArgumentError Hsm.dispatch!(p, :Complete, confirmation(p.request))
    @test p.state === :expired && p.confirmation === nothing && reads[] == sampled + 2
end

end
