# Optional CPU integration: no desktop core, instrument session or GPU is used.
include("test_correction_observer.jl")
include("native_control_private_core.jl")

@testset "Idle correction deadline publishes from a native timer" begin
    with_control_private_core() do remote, _, _
        now = Threads.Atomic{UInt64}(0)
        timed_out = Threads.Atomic{Bool}(false)
        wakes = Threads.Atomic{Int}(0)
        observer = Loops.Observer(["correction:closed"], Int64(24);
            timeout_ms=10, clock=() -> now[])
        getter = (props, available) -> begin
            status = observer(props, available)
            timed_out[] = status_value(status, "correction:closed.state") == "Unknown" &&
                occursin("timeout", status_value(status, "correction:closed.fault"))
            status
        end
        node = FilterGraphPipeWire.PipeWireNode(correction_graph(); remote,
            connect=false, run_control=true, property_observer=observer,
            property_info=Loops.property_info(observer), property_getter=getter)
        loop = ThreadLoop("correction-deadline-private-core")
        watchdog = nothing
        try
            Loops.attach_timers!(observer, loop, () -> begin
                Threads.atomic_add!(wakes, 1)
                # Logical time advances only when the real native timer fires.
                # This distinguishes the wake from incidental startup readback.
                now[] = UInt64(10_000_000)
                PipeWireAO.notify_properties!(node.filter)
                nothing
            end)
            start!(loop)
            FilterGraphPipeWire.connect!(node)
            node.filter.callbacks.on_properties(node.filter,
                PipeWireAO.SPA.Props("correction:closed" => false))
            @test Loops.state(only(observer.loops)) === :Opening
            started = time_ns()
            watchdog = TimerSource(loop, (_, _) -> begin
                if timed_out[] || time_ns() - started > UInt64(5_000_000_000)
                    FilterGraphPipeWire.quit!(node)
                end
                nothing
            end; delay=0.005, interval=0.005)
            # Blocks the constructing Julia thread in the native owner loop.
            # No Julia Timer, client polling, frames or later property writes.
            FilterGraphPipeWire.run!(node)
            @test timed_out[]
            @test wakes[] > 0
            sm = only(observer.loops)
            @test Loops.state(sm) === :Unknown
            @test sm.failure === :adoption_timeout
            @test sm.pending_since_ns == 0
            @test sm.requested_generation == 1
            @test sm.active_generation == 0
            @test sm.applied_closed === true
        finally
            watchdog === nothing || close(watchdog)
            close(observer)
            close(node)
            close(loop)
        end
    end
end
