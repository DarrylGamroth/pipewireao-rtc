# Run with --threads=2,0. These are cold transport/threading tests, no SCI frames.
using Test, PipeWireAO, PipeWireAORTC, ThreadPinning
import Clocks
include("control_private_core.jl")
include("bootstrap_monitor_gate.jl")
const B = PipeWireAORTC.OwnerBootstrapClient
const R = PipeWireAORTC.OwnerBootstrapRuntime
const C = PipeWireAORTC.OwnerBootstrapCodec
const Client = PipeWireAORTC.ControlClient
const Endpoint = PipeWireAORTC.ControlEndpoint
function main_gate(microseconds::Cuint)
    @ccall gc_safe = true usleep(microseconds::Cuint)::Cint
end
remaining() = Client.monotonic() + 10.0
function bootstrap_proof(remote, directory, daemon)
    chmod(dirname(remote), 0o700)
    runtime = R.Runtime(remote, "test.bootstrap", Int64(42))
    a = b = nothing
    try
        @test Threads.threadid() == 1
        a = B.connect(remote, "test.bootstrap", getpid(), 42; deadline = remaining())
        first = B.status(a; deadline = remaining())
        @test first.lifecycle === C.Preparing && first.header.token > 0
        queries = ThreadPinning.@spawnat 2 begin
            reply = B.status(a; deadline = remaining())
            observed_at = with_thread_loop_lock(a.client.loop) do _
                something(a.client.observation.completion).at
            end
            (reply = reply, at = observed_at, thread = Threads.threadid())
        end
        main_gate(Cuint(1_000_000))
        main_unblocked = Clocks.time_nanos(Clocks.SystemNanoClock())
        observed = fetch(queries)
        @test observed.at < main_unblocked
        @test observed.thread == 2
        @test observed.reply.lifecycle === C.Preparing
        @test observed.reply.header.token > first.header.token
        @test !R.cancelled(runtime)
        @test (@allocated R.cancelled(runtime)) == 0
        wrong_owner = ThreadPinning.@spawnat 2 try
            R.prepared!(runtime)
        catch error
            error
        end
        @test fetch(wrong_owner) isa ArgumentError
        @test !R._status(runtime).prepared
        premature = B.request!(a, :connect; deadline = remaining())
        @test premature.header.result == -22 && premature.lifecycle === C.Preparing
        @test runtime.connect_ticket === nothing && !R.cancelled(runtime)

        # Expired foreign ticket before take remains neutral to preparation.
        b = B.connect(remote, "test.bootstrap", getpid(), 42; deadline = remaining())
        gate = pause_bootstrap_monitor(runtime)
        expired = nothing
        try
            expired = ThreadPinning.@spawnat 2 try
                B.request!(b, :connect; deadline = Client.monotonic() + 0.05)
            catch error
                error
            end
            main_gate(Cuint(200_000))
            # A staged ticket requires discovery/admission work even if its
            # publication hint has already been consumed by another duty cycle.
            with_thread_loop_lock(runtime.transport.loop) do _
                @test runtime.transport.endpoint.pending !== nothing
                Base.Threads.atomic_xchg!(runtime.transport.wake, false)
            end
            @test R._poll_ready!(runtime.transport)
        finally
            resume_bootstrap_monitor(gate)
        end
        @test fetch(expired) isa Client.UnknownOutcome
        close(b)
        b = nothing
        @test B.status(a; deadline = remaining()).lifecycle === C.Preparing
        @test runtime.connect_ticket === nothing && !R.cancelled(runtime)

        R.prepared!(runtime)
        wait_proof(
            () -> with_thread_loop_lock(runtime.transport.loop) do _
                runtime.transport.endpoint.lifecycle === C.Prepared
            end,
            5,
            "Prepared publication",
        )
        b = B.connect(remote, "test.bootstrap", getpid(), 42; deadline = remaining())
        applying = ThreadPinning.@spawnat 2 B.connect_owner!(a; deadline = remaining())
        ticket = R.take_connect!(runtime)
        @test ticket.header.controller == a.client.identity
        @test Threads.threadid() == 1
        busy = B.request!(b, :status; deadline = remaining())
        @test busy isa C.Rejection &&
            busy.header.result < 0 &&
            busy.lifecycle === C.Prepared
        close(b)
        b = nothing
        R.check_connect!(runtime, ticket)
        actual_effect_thread = Threads.threadid()
        R.connected!(runtime, ticket)
        R.await_connected!(runtime, ticket)
        @test actual_effect_thread == 1
        @test fetch(applying).lifecycle === C.Connected
        duplicate = B.request!(a, :connect; deadline = remaining())
        @test duplicate.header.result == -22 && duplicate.lifecycle === C.Connected
        @test B.status(a; deadline = remaining()).lifecycle === C.Connected
        quitting = ThreadPinning.@spawnat 2 begin
            reply = B.quit!(a; deadline = remaining())
            close(a)
            reply
        end
        wait_proof(() -> R.cancelled(runtime), 5, "accepted Quit")
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
    chmod(dirname(remote), 0o700)
    runtime = R.Runtime(remote, "test.bootstrap.fault", Int64(43))
    client = nothing
    try
        client = B.connect(
            remote, "test.bootstrap.fault", getpid(), 43; deadline = remaining()
        )
        R.fault!(runtime, ErrorException("preparation failed"))
        wait_proof(
            () -> with_thread_loop_lock(runtime.transport.loop) do _
                runtime.transport.endpoint.lifecycle === C.Fault
            end,
            5,
            "Fault publication",
        )
        fault = B.status(client; deadline = remaining())
        @test fault.lifecycle === C.Fault && occursin("preparation failed", fault.message)
        @test B.request!(client, :connect; deadline = remaining()).header.result == -22
        finishing = ThreadPinning.@spawnat 2 B.request!(
            client, :quit; deadline = remaining()
        )
        wait_proof(() -> R.cancelled(runtime), 5, "fault Quit")
        R.finish!(runtime)
        reply = fetch(finishing)
        @test reply.header.result < 0 && reply.lifecycle === C.Fault
        @test runtime.failure === nothing
    finally
        client === nothing || close(client)
        close(runtime)
    end
end
function accepted_loss_proof(remote, directory, daemon; remove = false, persistent = false)
    name = remove ? "test.bootstrap.remove" : "test.bootstrap.expire"
    instance = remove ? 45 : 44
    chmod(dirname(remote), 0o700)
    runtime = R.Runtime(remote, name, Int64(instance); persistent)
    client = observer = nothing
    quit_threads = Int[]
    try
        client = B.connect(remote, name, getpid(), instance; deadline = remaining())
        observer = B.connect(remote, name, getpid(), instance; deadline = remaining())
        R.prepared!(runtime)
        wait_proof(
            () -> B.status(client; deadline = remaining()).lifecycle === C.Prepared,
            5,
            "loss Prepared",
        )
        applying = ThreadPinning.@spawnat 2 try
            B.request!(
                client, :connect; deadline = Client.monotonic() + (remove ? 10 : 0.5)
            )
        catch error
            error
        end
        ticket = R.take_connect!(runtime)
        # Methods loaded after the monitor began exercise the cold world-age seam.
        hooks = Module(gensym(:LateBootstrapHooks))
        Core.eval(hooks, :(ready() = false))
        R.connecting!(
            runtime,
            ticket;
            ready = () -> hooks.ready(),
            quit = () -> push!(quit_threads, Threads.threadid()),
        )
        if persistent
            candidate = try
                B.connect(remote, name, getpid(), instance; deadline = Client.monotonic() + 0.3)
            catch error
                error
            end
            @test candidate isa Client.UnknownOutcome
            candidate isa B.Connection && close(candidate)
        end
        if remove
            with_thread_loop_lock(client.client.loop) do _
                close(something(client.client.marker))
            end
        end
        wait_proof(() -> R.cancelled(runtime), 5, "accepted loss cancellation")
        @test runtime.failure !== nothing
        @test (runtime.failure isa R.RetiredSession) == persistent
        @test with_thread_loop_lock(runtime.transport.loop) do _
            runtime.transport.endpoint.lifecycle === C.Fault
        end
        # Wait for the known negative accepted-effect result to free the one slot;
        # a request before that boundary correctly receives busy instead.
        wait_proof(
            () -> with_thread_loop_lock(runtime.transport.loop) do _
                runtime.transport.endpoint.pending === nothing
            end,
            5,
            "failed effect retired",
        )
        # Main cleanup has not finished, so a fresh Fault query remains serviced.
        persistent || @test B.status(observer; deadline = remaining()).lifecycle === C.Fault
        R.finishing!(runtime)
        @test !isempty(quit_threads) && all(==(2), quit_threads)
        @test_throws Exception R.finish!(runtime)
        outcome = fetch(applying)
        @test outcome isa Client.UnknownOutcome || outcome.header.result < 0
        @test Threads.threadid() == 1
    catch error
        @error "accepted bootstrap loss proof failed before cleanup" exception = (
            error, catch_backtrace()
        )
        rethrow()
    finally
        client === nothing || close(client)
        observer === nothing || close(observer)
        close(runtime)
    end
end

struct BootstrapFenceClock <: Clocks.AbstractNanoClock
    at::Threads.Atomic{Int64}
    target::Threads.Atomic{Int64}
    reads::Threads.Atomic{Int}
end
BootstrapFenceClock() = BootstrapFenceClock(Threads.Atomic{Int64}(0), Threads.Atomic{Int64}(0), Threads.Atomic{Int}(0))

function Clocks.time_nanos(clock::BootstrapFenceClock)
    target = clock.target[]
    if Threads.threadid() == 2 && target != 0 && Threads.atomic_add!(clock.reads, -1) == 0
        clock.at[] = target
        clock.target[] = 0
    end
    return max(clock.at[], Clocks.time_nanos(Clocks.SystemNanoClock()))
end

function expire_bootstrap_after!(clock, ticket, reads)
    clock.reads[] = reads
    clock.target[] = ticket.deadline
    return nothing
end

function persistent_late_fence_proof(remote, directory, daemon; operation)
    chmod(dirname(remote), 0o700)
    name = "test.bootstrap.late.$operation"
    clock = BootstrapFenceClock()
    runtime = R.Runtime(remote, name, Int64(47); persistent = true, clock)
    client = nothing
    release = Channel{Nothing}(1)
    try
        client = B.connect(remote, name, getpid(), 47; deadline = remaining())
        R.prepared!(runtime)
        wait_proof(() -> B.status(client; deadline = remaining()).lifecycle === C.Prepared, 5, "late fence Prepared")
        applying = @async try
            B.request!(client, :connect; deadline = Client.monotonic() + 3)
        catch error
            error
        end
        ticket = R.take_connect!(runtime)
        if operation === :connect
            R.connecting!(runtime, ticket; ready = () -> begin
                # Validate Connect once after readiness. Expire on Completed's
                # internal recheck after the monitor has published Connected.
                expire_bootstrap_after!(clock, ticket, 1)
                true
            end, quit = () -> nothing)
            wait_proof(() -> R.cancelled(runtime), 5, "late Connect retirement")
            outcome = fetch(applying)
            @test outcome isa Client.UnknownOutcome || outcome.header.result < 0
        else
            entered = Channel{Nothing}(1)
            woke = Threads.Atomic{Bool}(false)
            R.connecting!(runtime, ticket; ready = () -> true, quit = () -> begin
                if !Threads.atomic_xchg!(woke, true)
                    put!(entered, nothing)
                    take!(release)
                end
            end)
            @test fetch(applying).header.result == 0
            quitting = @async try
                B.request!(client, :quit; deadline = Client.monotonic() + 3)
            catch error
                error
            end
            wait_proof(() -> isready(entered), 5, "late Quit accepted")
            take!(entered)
            pending = with_thread_loop_lock(runtime.transport.loop) do _
                something(runtime.transport.endpoint.pending)
            end
            # Queue finished facts before the next duty cycle. Let the current
            # pending check, next cycle's clock, pending, retain and completion
            # checks pass. Expire at the terminal native synchronization.
            R._enqueue!(runtime.mailbox, R.HooksExcluded(Channel{R.OwnerReply}(1)); cleanup = true)
            R._enqueue!(runtime.mailbox, R.OwnerFinished(Channel{R.OwnerReply}(1)); cleanup = true)
            expire_bootstrap_after!(clock, pending, 5)
            put!(release, nothing)
            wait_proof(() -> R._status(runtime).done, 5, "late Quit retirement")
            @test runtime.transport.endpoint.terminal
            @test fetch(quitting) isa Union{Client.UnknownOutcome,C.Completion}
        end
        @test runtime.failure isa R.RetiredSession
        @test clock.at[] > 0
        @test_throws R.RetiredSession R.finish!(runtime)
    finally
        isready(release) || put!(release, nothing)
        client === nothing || close(client)
        close(runtime)
    end
end

function persistent_attachment_proof(remote, directory, daemon)
    chmod(dirname(remote), 0o700)
    binding = (; remote, bootstrap_node = "test.bootstrap.persistent", bootstrap_instance = 46,
        persistent = true)
    previous_serial = nothing
    for lost_controller in (true, false)
        R.with_owner(binding) do admitted
            runtime = admitted.bootstrap_runtime
            client = B.connect(
                remote, binding.bootstrap_node, getpid(), binding.bootstrap_instance;
                deadline = remaining(),
            )
            foreign = nothing
            try
                @test client.client.serial != previous_serial
                previous_serial = client.client.serial
                @test B.request!(client, :quit; deadline = remaining()).header.result == -Base.Libc.EPERM
                @test !R.cancelled(runtime)
                foreign = B.connect(
                    remote, binding.bootstrap_node, getpid(), binding.bootstrap_instance;
                    deadline = remaining(),
                )

                R.prepared!(runtime)
                applying = @async B.connect_owner!(client; deadline = remaining())
                ticket = R.take_connect!(runtime)
                woke = Threads.Atomic{Bool}(false)
                R.connecting!(runtime, ticket; ready = () -> true, quit = () -> (woke[] = true))
                @test fetch(applying).lifecycle === C.Connected
                @test B.status(client; deadline = remaining()).lifecycle === C.Connected
                foreign_outcome = try
                    B.request!(foreign, :quit; deadline = Client.monotonic() + 0.5)
                catch error
                    error
                end
                @test foreign_outcome isa Client.UnknownOutcome || foreign_outcome.header.result < 0
                @test !R.cancelled(runtime)

                if lost_controller
                    close(client)
                    wait_proof(() -> woke[], 5, "persistent controller loss")
                    @test runtime.failure isa R.RetiredSession
                else
                    quitting = @async try
                        B.quit!(client; deadline = remaining())
                    finally
                        close(client)
                    end
                    wait_proof(() -> woke[], 5, "persistent attached Quit")
                    R.finish!(runtime)
                    @test fetch(quitting).lifecycle === C.Stopped
                end
            finally
                foreign === nothing || close(foreign)
                close(client)
            end
        end
    end
end

@testset "native ordinary bootstrap actual core" begin
    with_control_private_core(bootstrap_proof)
    with_control_private_core(fault_status_proof)
    with_control_private_core((args...) -> accepted_loss_proof(args...))
    with_control_private_core((args...) -> accepted_loss_proof(args...; remove = true))
    with_control_private_core((args...) -> accepted_loss_proof(args...; remove = true, persistent = true))
    with_control_private_core((args...) -> persistent_late_fence_proof(args...; operation = :connect))
    with_control_private_core((args...) -> persistent_late_fence_proof(args...; operation = :quit))
    with_control_private_core(persistent_attachment_proof)
end
