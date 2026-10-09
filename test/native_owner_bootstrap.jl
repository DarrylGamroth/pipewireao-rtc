# Run with --threads=2,0. These are cold transport/threading tests, no SCI frames.
using Test, PipeWireAO, PipeWireAODeployment, ThreadPinning
include("native_control_private_core.jl")
const B = PipeWireAODeployment.NativeOwnerBootstrapClient
const R = PipeWireAODeployment.NativeOwnerBootstrapRuntime
const C = PipeWireAODeployment.NativeOwnerBootstrapCodec
const Client = PipeWireAODeployment.NativeControlClient
const Endpoint = PipeWireAODeployment.NativeControlEndpoint
function main_gate(microseconds::Cuint)
    @ccall gc_safe=true usleep(microseconds::Cuint)::Cint
end
remaining() = Client.monotonic()+10.0
function bootstrap_proof(remote, directory, daemon)
    chmod(dirname(remote),0o700)
    runtime = R.Runtime(remote,"test.bootstrap",Int64(42))
    a = b = nothing
    try
        @test Threads.threadid() == 1
        a = B.connect(remote,"test.bootstrap",getpid(),42;deadline=remaining())
        first = B.status(a; deadline=remaining())
        @test first.lifecycle === C.Preparing && first.header.token > 0
        queries = ThreadPinning.@spawnat 2 begin
            reply = B.status(a; deadline=remaining())
            observed_at = with_thread_loop_lock(a.client.loop) do _
                something(a.client.observation.completion).at
            end
            (reply=reply, at=observed_at, thread=Threads.threadid())
        end
        main_gate(Cuint(1_000_000))
        main_unblocked = Client.monotonic()
        observed = fetch(queries)
        @test observed.at < main_unblocked
        @test observed.thread == 2
        @test observed.reply.lifecycle === C.Preparing
        @test observed.reply.header.token > first.header.token
        @test !R.cancelled(runtime)
        @test (@allocated R.cancelled(runtime)) == 0
        premature = B.request!(a,:connect;deadline=remaining())
        @test premature.header.result == -22 && premature.lifecycle === C.Preparing
        @test runtime.connect_ticket === nothing && !R.cancelled(runtime)

        # Expired foreign ticket before take remains neutral to preparation.
        b = B.connect(remote,"test.bootstrap",getpid(),42;deadline=remaining())
        locked = lock(runtime.lock)
        expired = nothing
        try
            expired = ThreadPinning.@spawnat 2 try
                B.request!(b,:connect; deadline=Client.monotonic()+0.05)
            catch error
                error
            end
            main_gate(Cuint(200_000))
            # A staged ticket requires discovery/admission work even if its
            # publication hint has already been consumed by another duty cycle.
            with_thread_loop_lock(runtime.transport.loop) do _
                @test runtime.transport.endpoint.pending !== nothing
                Base.Threads.atomic_xchg!(runtime.transport.wake,false)
            end
            @test R._poll_ready!(runtime.transport)
        finally
            unlock(runtime.lock)
        end
        @test fetch(expired) isa Client.UnknownOutcome
        close(b); b = nothing
        @test B.status(a;deadline=remaining()).lifecycle === C.Preparing
        @test runtime.connect_ticket === nothing && !R.cancelled(runtime)

        R.prepared!(runtime)
        wait_proof(() -> with_thread_loop_lock(runtime.transport.loop) do _
            runtime.transport.endpoint.lifecycle === C.Prepared
        end, 5, "Prepared publication")
        b = B.connect(remote,"test.bootstrap",getpid(),42;deadline=remaining())
        applying = ThreadPinning.@spawnat 2 B.connect_owner!(a;deadline=remaining())
        ticket = R.take_connect!(runtime)
        @test ticket.header.controller == a.client.identity
        @test Threads.threadid() == 1
        busy = B.request!(b,:status;deadline=remaining())
        @test busy isa C.Rejection && busy.header.result < 0 && busy.lifecycle === C.Prepared
        close(b); b = nothing
        R.check_connect!(runtime,ticket)
        actual_effect_thread = Threads.threadid()
        R.connected!(runtime,ticket)
        R.await_connected!(runtime,ticket)
        @test actual_effect_thread == 1
        @test fetch(applying).lifecycle === C.Connected
        duplicate = B.request!(a,:connect;deadline=remaining())
        @test duplicate.header.result == -22 && duplicate.lifecycle === C.Connected
        @test B.status(a;deadline=remaining()).lifecycle === C.Connected
        quitting = ThreadPinning.@spawnat 2 begin
            reply = B.quit!(a;deadline=remaining())
            close(a)
            reply
        end
        wait_proof(() -> R.cancelled(runtime),5,"accepted Quit")
        @test !istaskdone(quitting)
        R.finishing!(runtime)
        cleanup_thread = Threads.threadid()
        cleanup_at = Client.monotonic()
        R.finish!(runtime)
        stopped = fetch(quitting)
        @test cleanup_thread == 1 && stopped.lifecycle === C.Stopped
        @test Client.monotonic() >= cleanup_at
        @test runtime.transport.endpoint.lifecycle === C.Stopped
        @test runtime.failure === nothing
    finally
        b === nothing || close(b)
        a === nothing || close(a)
        close(runtime)
    end
end
function fault_status_proof(remote, directory, daemon)
    chmod(dirname(remote),0o700)
    runtime = R.Runtime(remote,"test.bootstrap.fault",Int64(43))
    client = nothing
    try
        client = B.connect(remote,"test.bootstrap.fault",getpid(),43;deadline=remaining())
        R.fault!(runtime,ErrorException("preparation failed"))
        wait_proof(() -> with_thread_loop_lock(runtime.transport.loop) do _
            runtime.transport.endpoint.lifecycle === C.Fault
        end,5,"Fault publication")
        fault = B.status(client;deadline=remaining())
        @test fault.lifecycle === C.Fault && occursin("preparation failed",fault.message)
        @test B.request!(client,:connect;deadline=remaining()).header.result == -22
        finishing = ThreadPinning.@spawnat 2 B.request!(client,:quit;deadline=remaining())
        wait_proof(() -> R.cancelled(runtime),5,"fault Quit")
        R.finish!(runtime)
        reply = fetch(finishing)
        @test reply.header.result < 0 && reply.lifecycle === C.Fault
        @test runtime.failure === nothing
    finally
        client === nothing || close(client)
        close(runtime)
    end
end
function accepted_loss_proof(remote, directory, daemon; remove=false)
    name = remove ? "test.bootstrap.remove" : "test.bootstrap.expire"
    instance = remove ? 45 : 44
    chmod(dirname(remote),0o700)
    runtime = R.Runtime(remote,name,Int64(instance))
    client = observer = nothing
    quit_threads = Int[]
    try
        client = B.connect(remote,name,getpid(),instance;deadline=remaining())
        observer = B.connect(remote,name,getpid(),instance;deadline=remaining())
        R.prepared!(runtime)
        wait_proof(() -> B.status(client;deadline=remaining()).lifecycle === C.Prepared,5,"loss Prepared")
        applying = ThreadPinning.@spawnat 2 try
            B.request!(client,:connect;deadline=Client.monotonic()+(remove ? 10 : 0.5))
        catch error
            error
        end
        ticket = R.take_connect!(runtime)
        # Methods loaded after the monitor began exercise the cold world-age seam.
        hooks = Module(gensym(:LateBootstrapHooks))
        Core.eval(hooks, :(ready() = false))
        R.connecting!(runtime,ticket; ready=() -> hooks.ready(), quit=() -> push!(quit_threads,Threads.threadid()))
        if remove
            with_thread_loop_lock(client.client.loop) do _
                close(something(client.client.marker))
            end
        end
        wait_proof(() -> R.cancelled(runtime),5,"accepted loss cancellation")
        @test runtime.failure !== nothing
        @test with_thread_loop_lock(runtime.transport.loop) do _
            runtime.transport.endpoint.lifecycle === C.Fault
        end
        # Wait for the known negative accepted-effect result to free the one slot;
        # a request before that boundary correctly receives busy instead.
        wait_proof(() -> with_thread_loop_lock(runtime.transport.loop) do _
            runtime.transport.endpoint.pending === nothing
        end,5,"failed effect retired")
        # Main cleanup has not finished, so a fresh Fault query remains serviced.
        @test B.status(observer;deadline=remaining()).lifecycle === C.Fault
        R.finishing!(runtime)
        @test !isempty(quit_threads) && all(==(2),quit_threads)
        @test_throws Exception R.finish!(runtime)
        outcome = fetch(applying)
        @test outcome isa Client.UnknownOutcome || outcome.header.result < 0
        @test Threads.threadid() == 1
    finally
        client === nothing || close(client)
        observer === nothing || close(observer)
        close(runtime)
    end
end
@testset "native ordinary bootstrap actual core" begin
    with_control_private_core(bootstrap_proof)
    with_control_private_core(fault_status_proof)
    with_control_private_core((args...) -> accepted_loss_proof(args...))
    with_control_private_core((args...) -> accepted_loss_proof(args...;remove=true))
end
