module CalibrationPreparationTests
using Test, PipeWireAORTC
const P = PipeWireAORTC.CalibrationPreparation

request(; run=UInt64(91), serial=UInt64(1), stage="dark", condition="blocked",
    configuration_identity="detector-configuration-sha256", kind=:manual,
    issued_at=10.0, deadline=20.0) = P.Request(;
        run, serial, stage, condition, configuration_identity, kind, issued_at, deadline)
confirmation(r; observed_at=11.0, witness="operator-17") = P.Confirmation(r; observed_at, witness)

@testset "preparation request and evidence validation" begin
    r = request()
    @test r.run === UInt64(91)
    @test r == request()
    @test r != request(serial=2)
    for kwargs in ((; run=0), (; run=-1), (; serial=0), (; serial=big(2)^64),
            (; stage=""), (; stage=" " ), (; condition="x"^257),
            (; configuration_identity="x\0y"), (; kind=:cached),
            (; issued_at=NaN), (; deadline=Inf), (; deadline=10.0), (; deadline=9.0))
        @test_throws ArgumentError request(; kwargs...)
    end
    @test_throws ArgumentError request(stage=String(UInt8[0xff]))
    @test_throws ArgumentError request(stage="é"^129)
    @test request(stage="é"^128).stage == "é"^128
    for kwargs in ((; observed_at=Inf), (; witness=""), (; witness=" "),
            (; witness="x"^1025), (; witness="operator\0other"))
        @test_throws ArgumentError confirmation(r; kwargs...)
    end
    @test_throws ArgumentError P.Procedure(r; clock=()->NaN)
end

@testset "manual, simulated and service evidence admission" begin
    for (kind, witness) in ((:manual,"operator-17"), (:simulated,"graph-epoch-41"),
            (:service,"mechanism-service-epoch-8"))
        now = Ref(11.0)
        r = request(; kind)
        p = P.Procedure(r; clock=()->now[])
        @test p.state == :pending
        @test p.confirmation === nothing
        @test_throws ArgumentError P.check_current!(p)
        c = confirmation(r; witness)
        @test P.complete!(p,c) === c
        @test p.state == :ready
        @test p.reason === nothing
        @test P.check_current!(p) === c
        now[] = prevfloat(20.0)
        @test P.check_current!(p) === c
        now[] = 20.0
        @test_throws ArgumentError P.check_current!(p)
        @test p.state == :expired
        @test p.confirmation === c
        @test_throws ArgumentError P.complete!(p,c)
        @test p.state == :expired
    end
end

@testset "exact request correlation fences stale and foreign evidence" begin
    for wrong in (request(run=92), request(serial=2), request(stage="reference"),
            request(condition="illuminated"), request(configuration_identity="new-detector-epoch"),
            request(kind=:service), request(issued_at=9.0), request(deadline=21.0))
        p = P.Procedure(request(); clock=()->11.0)
        @test_throws ArgumentError P.complete!(p,confirmation(wrong))
        @test p.state == :invalidated
        @test p.confirmation === nothing
        @test_throws ArgumentError P.complete!(p,confirmation(p.request))
        @test_throws ArgumentError P.check_current!(p)
    end
    # Exact incarnations are adapter-validated witnesses, not guessed from run IDs.
    p = P.Procedure(request(kind=:service); clock=()->11.0)
    P.complete!(p,confirmation(p.request; witness="service-epoch-4"))
    P.invalidate!(p,"Service restarted as epoch 5")
    @test_throws ArgumentError P.complete!(p,confirmation(p.request; witness="service-epoch-5"))
    @test_throws ArgumentError P.check_current!(p)
    @test p.confirmation.witness == "service-epoch-4"
end

@testset "observation boundaries and delayed delivery" begin
    for (at, observed_at, state) in ((11.0,9.0,:invalidated),
            (11.0,12.0,:invalidated), (20.0,11.0,:expired),
            (21.0,20.0,:expired), (9.0,9.0,:invalidated))
        p = P.Procedure(request(); clock=()->at)
        @test_throws ArgumentError P.complete!(p,confirmation(p.request; observed_at))
        @test p.state == state
        @test_throws ArgumentError P.check_current!(p)
    end
    p = P.Procedure(request(); clock=()->10.0)
    c = confirmation(p.request; observed_at=10.0)
    @test P.complete!(p,c) === c
    @test P.check_current!(p) === c
end

@testset "cancellation, invalidation and duplicate completion cannot revive" begin
    for ready in (false,true), event in (:cancel,:invalidate,:duplicate)
        event == :duplicate && !ready && continue
        p = P.Procedure(request(); clock=()->11.0)
        c = confirmation(p.request)
        ready && P.complete!(p,c)
        if event == :cancel
            P.cancel!(p)
            @test p.state == :cancelled
        elseif event == :invalidate
            P.invalidate!(p,"Optical condition lost")
            @test p.state == :invalidated
        else
            @test_throws ArgumentError P.complete!(p,c)
            @test p.state == :invalidated
        end
        state, reason = p.state, p.reason
        @test_throws ArgumentError P.check_current!(p)
        @test_throws ArgumentError P.complete!(p,c)
        P.cancel!(p)
        P.invalidate!(p,"Another event")
        P.expire!(p)
        @test (p.state,p.reason) == (state,reason)
        @test p.confirmation === (ready ? c : nothing)
    end
    now = Ref(11.0)
    p = P.Procedure(request(); clock=()->now[])
    P.expire!(p)
    @test p.state == :pending
    now[] = 20.0
    P.expire!(p)
    @test p.state == :expired
    @test_throws ArgumentError P.complete!(p,confirmation(p.request))
    p = P.Procedure(request(); clock=()->11.0)
    @test_throws ArgumentError P.invalidate!(p,"x"^1025)
    @test p.state == :pending
end

@testset "monotonic clock failure and single-task ownership" begin
    for bad in (NaN,Inf,10.0)
        now = Ref(11.0)
        p = P.Procedure(request(); clock=()->now[])
        P.complete!(p,confirmation(p.request))
        now[] = bad
        @test_throws ArgumentError P.check_current!(p)
        @test p.state == :invalidated
    end
    failed = Ref(false)
    p = P.Procedure(request(); clock=()->failed[] ? error("Clock unavailable") : 11.0)
    P.complete!(p,confirmation(p.request))
    failed[] = true
    @test_throws ArgumentError P.check_current!(p)
    @test p.state == :invalidated
    failed[] = false
    @test_throws ArgumentError P.check_current!(p)
    p = P.Procedure(request(); clock=()->11.0)
    c = confirmation(p.request)
    for event in (() -> P.complete!(p,c), () -> P.check_current!(p),
            () -> P.cancel!(p), () -> P.expire!(p), () -> P.invalidate!(p,"Lost"))
        error = fetch(@async try event(); nothing catch error; error end)
        @test error isa ArgumentError
        @test p.state == :pending
    end
    @test P.complete!(p,c) === c
end

end
