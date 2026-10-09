using Test, PipeWireAO, PipeWireAODeployment
include("native_control_private_core.jl")
const R = PipeWireAODeployment.NativeOwnerBootstrapRuntime
const B = PipeWireAODeployment.NativeOwnerBootstrapClient
const C = PipeWireAODeployment.NativeControlClient
const P = PipeWireAODeployment.NativeOwnerBootstrapCodec
import ThreadPinning
function idle_window()
    before = Base.gc_num()
    @ccall gc_safe=true usleep(Cuint(500_000)::Cuint)::Cint
    after = Base.gc_num()
    Base.GC_Diff(after,before)
end
function measured(remote, directory, daemon)
    chmod(dirname(remote),0o700)
    # Warm the measurement without owner monitor activity.
    idle_window()
    baseline = idle_window()
    @test baseline.allocd == 0
    println("BASELINE bytes=",baseline.allocd," pool=",baseline.poolalloc)
    runtime = R.Runtime(remote,"review.bootstrap",Int64(91))
    client = B.connect(remote,"review.bootstrap",getpid(),91;deadline=C.monotonic()+20)
    try
        R.prepared!(runtime)
        request = ThreadPinning.@spawnat 2 B.connect_owner!(client;deadline=C.monotonic()+20)
        ticket = R.take_connect!(runtime)
        R.connected!(runtime,ticket)
        R.await_connected!(runtime,ticket)
        fetch(request)
        idle_window()
        first = idle_window()
        second = idle_window()
        println("CONNECTED first bytes=",first.allocd," pool=",first.poolalloc)
        println("CONNECTED second bytes=",second.allocd," pool=",second.poolalloc)
        # Exclude monitor duty cycles to attribute the registry work directly.
        lock(runtime.lock) do
            for _ in 1:5
                PipeWireAODeployment.NativeControlEndpoint.poll!(runtime.transport.endpoint)
            end
            poll_bytes = @allocated PipeWireAODeployment.NativeControlEndpoint.poll!(runtime.transport.endpoint)
            # Poll/take cannot erase a wake produced after the consumed hint.
            runtime.transport.wake[] = true
            R.poll!(runtime.transport)
            @test runtime.transport.wake[]
            @test R.take!(runtime.transport) === nothing
            @test runtime.transport.wake[]
            @test R._poll_ready!(runtime.transport)
            for _ in 1:5
                R._poll_ready!(runtime.transport)
                R._facts(runtime)
            end
            @test (@allocated R._poll_ready!(runtime.transport)) == 0
            @test (@allocated R._facts(runtime)) == 0
            with_thread_loop_lock(runtime.transport.loop) do _
                endpoint = runtime.transport.endpoint
                saved_failure = endpoint.failure
                endpoint.failure = "injected quiet health failure"
                Base.Threads.atomic_xchg!(runtime.transport.wake,false)
                try
                    @test_throws InvalidStateException R._poll_ready!(runtime.transport)
                finally
                    endpoint.failure = saved_failure
                end
            end
            cancel_bytes = @allocated R.cancelled(runtime)
            R.preparation_check!(runtime)
            check_bytes = @allocated R.preparation_check!(runtime)
            println("DIRECT poll_bytes=",poll_bytes," cancel_bytes=",cancel_bytes," owner_check_bytes=",check_bytes)
        end
        @test runtime.transport.endpoint.lifecycle === P.Connected
        @test first.allocd == 0
        @test second.allocd == 0

    finally
        R.finish!(runtime)
        close(client)
        close(runtime)
    end
end
@testset "quiet native bootstrap inclusive allocations" begin
    with_control_private_core(measured)
end
