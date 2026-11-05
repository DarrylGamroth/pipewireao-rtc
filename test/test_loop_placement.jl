using Test
using PipeWireAORTC
using PipeWireAO
import Clocks

const LoopPlacement = PipeWireAORTC.Placement

@testset "signed placement deadlines without affinity changes" begin
    clock = Clocks.CachedNanoClock(Int64(-100))
    previous, deadline = LoopPlacement.placement_deadline(clock, 3//1_000_000_000)
    @test (previous, deadline) === (Int64(-100), Int64(-97))
    Clocks.update!(clock, Int64(-98))
    @test LoopPlacement.placement_remaining(clock, previous, deadline) ===
          (Int64(-98), Int64(1))
    Clocks.update!(clock, deadline)
    @test LoopPlacement.placement_remaining(clock, -98, deadline) === (deadline, Int64(0))
    Clocks.update!(clock, Int64(-99))
    @test_throws LoopPlacement.PlacementError LoopPlacement.placement_remaining(
        clock,
        -98,
        deadline,
    )

    # Adjacent ticks above Float64's exact-integer range stay distinct.
    origin = Int64(2)^53 + 1
    Clocks.update!(clock, origin)
    @test LoopPlacement.placement_deadline(clock, 1//1_000_000_000) === (origin, origin + 1)
    for timeout in (0, -1, Inf, NaN)
        @test_throws ArgumentError LoopPlacement.placement_deadline(clock, timeout)
    end
    @test_throws InexactError LoopPlacement.placement_deadline(clock, typemax(Int))
    @test_throws InexactError LoopPlacement.placement_deadline(clock, floatmax(Float64))
    Clocks.update!(clock, typemax(Int64))
    @test_throws OverflowError LoopPlacement.placement_deadline(clock, 1//1_000_000_000)
    @test LoopPlacement.placement_remaining(clock, Int64(-100), Int64(-97)) ===
          (typemax(Int64), Int64(0))
    Clocks.update!(clock, typemin(Int64))
    @test_throws OverflowError LoopPlacement.placement_remaining(
        clock,
        typemin(Int64),
        typemax(Int64),
    )

    # Block event dispatch, then advance the injected clock at the first poll.
    # Both paths must close the event without ever reaching taskset or /proc mutation.
    loop = ThreadLoop("RTC-placement-clock")
    try
        start!(loop)
        for next_tick in (Int64(-97), Int64(-101))
            Clocks.update!(clock, Int64(-100))
            checks = Ref(0)
            check = () -> begin
                checks[] += 1
                checks[] == 3 && Clocks.update!(clock, next_tick)
                nothing
            end
            with_thread_loop_lock(loop) do _
                @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(
                    loop,
                    2;
                    timeout = 3//1_000_000_000,
                    clock,
                    check,
                )
            end
            @test checks[] == 3
            @test isrunning(loop)
        end
    finally
        isrunning(loop) && stop!(loop)
        close(loop)
    end
    @test !isopen(loop)
end

function calling_thread_affinity()
    tid = Int(ccall(:gettid, Cint, ()))
    cpus = LoopPlacement.cpus_from_list(
        LoopPlacement.proc_field("/proc/self/task/$tid/status", "Cpus_allowed_list"),
    )
    return tid, cpus
end

@testset "placement identifies the owned native loop by event" begin
    caller_tid, caller_cpus = calling_thread_affinity()
    cpu = first(filter(>=(2), caller_cpus))
    loop = ThreadLoop("RTC-placement")
    try
        @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(loop, cpu)
        start!(loop)
        report = LoopPlacement.pin_loop!(loop, cpu)
        @test report["pid"] == getpid()
        @test report["tid"] != caller_tid
        @test report["cpus"] == [cpu]
        observed = LoopPlacement.cpus_from_list(
            LoopPlacement.proc_field(
                "/proc/self/task/$(report["tid"])/status",
                "Cpus_allowed_list",
            ),
        )
        @test observed == [cpu]
        @test calling_thread_affinity() == (caller_tid, caller_cpus)
        @test isrunning(loop)

        rejected = Threads.Atomic{Bool}(false)
        completed = Threads.Atomic{Bool}(false)
        self_check = EventSource(
            loop,
            (_source, _count) -> begin
                try
                    LoopPlacement.pin_loop!(loop, cpu)
                catch error
                    rejected[] = error isa LoopPlacement.PlacementError
                finally
                    completed[] = true
                end
                nothing
            end,
        )
        try
            signal!(self_check)
            @test Base.timedwait(() -> completed[], 5; pollint = 0.001) === :ok
            @test rejected[]
        finally
            close(self_check)
        end

        @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(loop, -1)
        @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(loop, 0)
        @test_throws ArgumentError LoopPlacement.pin_loop!(loop, cpu; timeout = 0)
        @test_throws ArgumentError LoopPlacement.pin_loop!(loop, cpu; timeout = Inf)
        @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(
            loop,
            typemax(Int),
        )

        checks = Ref(0)
        cancel = () -> begin
            checks[] += 1
            checks[] == 2 && throw(InterruptException())
            nothing
        end
        @test_throws InterruptException LoopPlacement.pin_loop!(loop, cpu; check = cancel)
        @test checks[] == 2
        # Hold the native lock only to make this timeout test deterministic:
        # the event cannot dispatch before the bounded wait gives up.
        with_thread_loop_lock(loop) do _
            @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(
                loop,
                cpu;
                timeout = 0.005,
            )
        end
        @test LoopPlacement.pin_loop!(loop, cpu)["tid"] == report["tid"]
        @test calling_thread_affinity() == (caller_tid, caller_cpus)
    finally
        isrunning(loop) && stop!(loop)
        # Public close rejects outstanding sources, so this also verifies
        # event cleanup after success, cancellation, timeout and taskset error.
        close(loop)
    end
    @test !isopen(loop)
end
