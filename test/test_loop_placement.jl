using Test
using PipeWireAORTC
using PipeWireAO

const LoopPlacement = PipeWireAORTC.Placement

function calling_thread_affinity()
    tid = Int(ccall(:gettid, Cint, ()))
    cpus = LoopPlacement.cpus_from_list(LoopPlacement.proc_field(
        "/proc/self/task/$tid/status", "Cpus_allowed_list"))
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
        observed = LoopPlacement.cpus_from_list(LoopPlacement.proc_field(
            "/proc/self/task/$(report["tid"])/status", "Cpus_allowed_list"))
        @test observed == [cpu]
        @test calling_thread_affinity() == (caller_tid, caller_cpus)
        @test isrunning(loop)

        rejected = Threads.Atomic{Bool}(false)
        completed = Threads.Atomic{Bool}(false)
        self_check = EventSource(loop, (_source, _count) -> begin
            try
                LoopPlacement.pin_loop!(loop, cpu)
            catch error
                rejected[] = error isa LoopPlacement.PlacementError
            finally
                completed[] = true
            end
            nothing
        end)
        try
            signal!(self_check)
            @test Base.timedwait(() -> completed[], 5; pollint=0.001) === :ok
            @test rejected[]
        finally
            close(self_check)
        end

        @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(loop, -1)
        @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(loop, 0)
        @test_throws ArgumentError LoopPlacement.pin_loop!(loop, cpu; timeout=0)
        @test_throws ArgumentError LoopPlacement.pin_loop!(loop, cpu; timeout=Inf)
        @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(loop, typemax(Int))

        checks = Ref(0)
        cancel = () -> begin
            checks[] += 1
            checks[] == 2 && throw(InterruptException())
            nothing
        end
        @test_throws InterruptException LoopPlacement.pin_loop!(loop, cpu; check=cancel)
        @test checks[] == 2
        # Hold the native lock only to make this timeout test deterministic:
        # the event cannot dispatch before the bounded wait gives up.
        with_thread_loop_lock(loop) do _
            @test_throws LoopPlacement.PlacementError LoopPlacement.pin_loop!(loop, cpu; timeout=0.005)
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
