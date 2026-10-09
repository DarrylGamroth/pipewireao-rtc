# Cold private-core authority tests; no scientific application or frames.
using Test, PipeWireAO, PipeWireAODeployment, ThreadPinning
include("native_control_private_core.jl")
const R = PipeWireAODeployment.NativeOwnerBootstrapRuntime
const B = PipeWireAODeployment.NativeOwnerBootstrapClient
const C = PipeWireAODeployment.NativeControlClient
const P = PipeWireAODeployment.NativeOwnerBootstrapCodec
const E = PipeWireAODeployment.NativeControlEndpoint
remaining() = C.monotonic() + 10.0
function connected_owner(remote, name, instance)
    runtime = R.Runtime(remote, name, instance)
    client = B.connect(remote, name, getpid(), instance; deadline=remaining())
    R.prepared!(runtime)
    request = ThreadPinning.@spawnat 2 B.connect_owner!(client; deadline=remaining())
    ticket = R.take_connect!(runtime)
    R.connected!(runtime, ticket)
    R.await_connected!(runtime, ticket)
    @test fetch(request).lifecycle === P.Connected
    @test runtime.transport.endpoint.retained_controller == client.client.identity
    @test length(runtime.transport.endpoint.controllers) == 1
    @test !isopen(runtime.transport.registry_listener)
    @test isopen(something(runtime.transport.endpoint.registry))
    runtime, client
end
function retained_authority(remote, directory, daemon)
    chmod(dirname(remote), 0o700)
    runtime, client = connected_owner(remote, "test.bootstrap.retained", Int64(52))
    try
        @test B.status(client; deadline=remaining()).lifecycle === P.Connected
        before = globals(something(runtime.transport.endpoint.registry))
        @test_throws C.UnknownOutcome B.connect(remote, "test.bootstrap.retained", getpid(), 52;
            deadline=C.monotonic() + 0.3)
        @test length(runtime.transport.endpoint.controllers) == 1
        @test runtime.transport.endpoint.retained_controller == client.client.identity
        @test !R.cancelled(runtime)
        @test map(object -> object.id, globals(something(runtime.transport.endpoint.registry))) ==
            map(object -> object.id, before)
        @test B.status(client; deadline=remaining()).lifecycle === P.Connected
        # Isolate the cold client listener while measuring owner methods, as in
        # existing SDK microbenchmarks. This is not a process-wide SCI claim.
        with_thread_loop_lock(client.client.loop) do _
            with_thread_loop_lock(runtime.transport.loop) do _
                E.poll!(runtime.transport.endpoint)
                @test (@allocated E.poll!(runtime.transport.endpoint)) == 0
            end
        end
        quitting = ThreadPinning.@spawnat 2 B.quit!(client; deadline=remaining())
        wait_proof(() -> R.cancelled(runtime), 5, "retained Quit")
        R.finish!(runtime)
        @test fetch(quitting).lifecycle === P.Stopped
        @test runtime.failure === nothing
    finally
        close(client)
        close(runtime)
    end
end
function revoked_authority(remote, directory, daemon; mode)
    chmod(dirname(remote), 0o700)
    name = "test.bootstrap.revoked.$mode"
    runtime, client = connected_owner(remote, name, Int64(53))
    try
        with_thread_loop_lock(client.client.loop) do _
            if mode === :proof
                update_properties!(something(client.client.marker),
                    Dict("pipewireao.rtc-control.instance" => string(client.client.marker_instance + 1)))
            elseif mode === :node
                close(something(client.client.marker))
            end
        end
        mode === :connection && close(client)
        wait_proof(() -> R.cancelled(runtime), 5, "retained controller revocation")
        @test !only(runtime.transport.endpoint.controllers).verified
        @test only(runtime.transport.endpoint.controllers).retired
        @test runtime.failure !== nothing
        @test_throws Exception R.finish!(runtime)
    finally
        close(client)
        close(runtime)
    end
end
function pending_quit_loss(remote, directory, daemon; remove)
    chmod(dirname(remote), 0o700)
    runtime, client = connected_owner(remote, "test.bootstrap.quit.$remove", Int64(54))
    try
        quitting = ThreadPinning.@spawnat 2 try
            B.request!(client, :quit; deadline=C.monotonic() + (remove ? 10.0 : 0.5))
        catch error
            error
        end
        wait_proof(() -> R.cancelled(runtime), 5, "retained pending Quit")
        @test !istaskdone(quitting)
        if remove
            with_thread_loop_lock(client.client.loop) do _
                close(something(client.client.marker))
            end
        end
        wait_proof(() -> runtime.failure !== nothing, 5, "retained Quit loss")
        @test runtime.failure !== nothing
        @test_throws Exception R.finish!(runtime)
        outcome = fetch(quitting)
        @test outcome isa C.UnknownOutcome || outcome.header.result < 0
    finally
        close(client)
        close(runtime)
    end
end
@testset "retained ordinary-owner bootstrap authority" begin
    with_control_private_core(retained_authority)
    for remove in (false, true)
        with_control_private_core() do remote, directory, daemon
            pending_quit_loss(remote, directory, daemon; remove)
        end
    end
    for mode in (:proof, :node, :connection)
        with_control_private_core() do remote, directory, daemon
            revoked_authority(remote, directory, daemon; mode)
        end
    end
end
