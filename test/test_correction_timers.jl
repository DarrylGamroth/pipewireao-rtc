using Test, PipeWireAORTC, PipeWireAO

const CL = PipeWireAORTC.CorrectionLoops

@testset "Native correction timers wake without changing Hsm from another thread" begin
    loop = ThreadLoop("correction-control-timers")
    wakes = Threads.Atomic{Int}(0)
    callback_thread = Threads.Atomic{Int}(0)
    observer = CL.Observer(["correction:closed"], Int64(22); timeout_ms=50)
    sm = only(observer.loops)
    CL.observed!(sm, sm.instance, 0, 0, false)
    CL.attach_timers!(observer, loop, () -> begin
        callback_thread[] = Threads.threadid()
        Threads.atomic_add!(wakes, 1)
        nothing
    end)
    timer = sm.timer
    try
        @test isopen(timer)
        @test_throws ArgumentError CL.attach_timers!(observer, loop, () -> nothing)
        start!(loop)
        CL.requested!(sm, sm.instance, 1, 0, true)
        @test timedwait(() -> wakes[] > 0, 5; pollint=0.005) === :ok
        @test callback_thread[] != Threads.threadid()
        @test CL.state(sm) === :Closing
        @test sm.failure === nothing
        # Only the serialized control observation can dispatch the fault.
        CL.expire!(sm, time_ns(), observer.timeout_ns)
        @test CL.state(sm) === :Unknown
        @test sm.failure === :adoption_timeout
        @test sm.pending_since_ns == 0
    finally
        close(observer)
        close(loop)
    end
    @test !isopen(timer)
    @test close(observer) === nothing
end

@testset "Applied adoption cancels the native timer" begin
    loop = ThreadLoop("correction-control-cancel")
    wakes = Threads.Atomic{Int}(0)
    observer = CL.Observer(["correction:closed"], Int64(23); timeout_ms=250)
    sm = only(observer.loops)
    CL.observed!(sm, sm.instance, 0, 0, true)
    CL.attach_timers!(observer, loop, () -> Threads.atomic_add!(wakes, 1))
    timer = sm.timer
    try
        start!(loop)
        CL.requested!(sm, sm.instance, 1, 0, false)
        CL.observed!(sm, sm.instance, 1, 1, false)
        @test CL.state(sm) === :Open
        @test sm.pending_since_ns == 0
        count = wakes[]
        sleep(0.35)
        @test wakes[] == count
        CL.requested!(sm, sm.instance, 2, 1, false)
        sleep(0.35)
        @test wakes[] == count
        CL.observed!(sm, sm.instance, 2, 2, false)
        CL.requested!(sm, sm.instance, 3, 2, true)
        @test CL.state(sm) === :Closing
        CL.unknown!(sm, :observer_error)
        @test CL.state(sm) === :Unknown
        @test sm.pending_since_ns == 0
        sleep(0.35)
        @test wakes[] == count
    finally
        close(observer)
        close(loop)
    end
    @test !isopen(timer)
end

@testset "Early native wakes preserve the original adoption deadline" begin
    now = Ref(UInt64(0))
    loop = ThreadLoop("correction-control-rearm")
    wakes = Threads.Atomic{Int}(0)
    observer = CL.Observer(["correction:closed"], Int64(25);
        timeout_ms=50, clock=() -> now[])
    sm = only(observer.loops)
    CL.observed!(sm, sm.instance, 0, 0, false)
    CL.attach_timers!(observer, loop, () -> Threads.atomic_add!(wakes, 1))
    try
        start!(loop)
        CL.requested!(sm, sm.instance, 1, 0, true)
        update_timer!(sm.timer; delay=0.001)
        @test timedwait(() -> wakes[] > 0, 5; pollint=0.005) === :ok
        now[] = UInt64(10_000_000)
        CL.expire!(sm, now[], observer.timeout_ns)
        @test CL.state(sm) === :Closing
        @test sm.pending_since_ns == 0
        count = wakes[]
        @test timedwait(() -> wakes[] > count, 5; pollint=0.005) === :ok
        now[] = UInt64(50_000_000)
        CL.expire!(sm, now[], observer.timeout_ns)
        @test sm.failure === :adoption_timeout
        @test CL.state(sm) === :Unknown
    finally
        close(observer)
        close(loop)
    end
end

@testset "Closing a pending observer cancels and releases its native timer" begin
    loop = ThreadLoop("correction-control-close")
    wakes = Threads.Atomic{Int}(0)
    observer = CL.Observer(["correction:closed"], Int64(26); timeout_ms=250)
    sm = only(observer.loops)
    CL.observed!(sm, sm.instance, 0, 0, true)
    CL.attach_timers!(observer, loop, () -> Threads.atomic_add!(wakes, 1))
    timer = sm.timer
    try
        start!(loop)
        CL.requested!(sm, sm.instance, 1, 0, false)
        close(observer)
        @test !isopen(timer)
        @test sm.timer === nothing
        @test sm.pending_since_ns == 0
        count = wakes[]
        sleep(0.35)
        @test wakes[] == count
    finally
        close(observer)
        close(loop)
    end
end
