# Cold private-core terminal lifetime tests; run with --threads=2,0.
using Test, PipeWireAO, PipeWireAODeployment, ThreadPinning
include("native_control_private_core.jl")
const R = PipeWireAODeployment.NativeOwnerBootstrapRuntime
const B = PipeWireAODeployment.NativeOwnerBootstrapClient
const C = PipeWireAODeployment.NativeOwnerBootstrapCodec
const Client = PipeWireAODeployment.NativeControlClient
const Envelope = PipeWireAODeployment.NativeControlCodec
const Endpoint = PipeWireAODeployment.NativeControlEndpoint
deadline() = Client.monotonic() + 10.0

function client_fence(client)
    done = Ref{Cint}(-1)
    listener = with_thread_loop_lock(client.loop) do _
        add_listener!(something(client.core);
            on_done=(core, id, seq) -> (id == 0 && (done[] = seq); nothing))
    end
    try
        seq = with_thread_loop_lock(client.loop) do _
            sync!(something(client.core))
        end
        wait_proof(() -> with_thread_loop_lock(client.loop) do _
            done[] == seq
        end, 5, "cold client publication fence")
    finally
        with_thread_loop_lock(client.loop) do _
            close(listener)
        end
    end
end

function terminal_owner(remote, directory, daemon; mode)
    chmod(dirname(remote), 0o700)
    runtime = R.Runtime(remote, "test.terminal.$mode", Int64(81))
    connection = driver = nothing
    try
        connection = B.connect(remote, "test.terminal.$mode", getpid(), 81; deadline=deadline())
        client = connection.client
        R.prepared!(runtime)
        connecting = ThreadPinning.@spawnat 2 B.connect_owner!(connection; deadline=deadline())
        ticket = R.take_connect!(runtime)
        R.connected!(runtime, ticket)
        R.await_connected!(runtime, ticket)
        @test fetch(connecting).lifecycle === C.Connected

        # Match Lua's enum-only owner reader: no subscription can observe the
        # terminal publication before this test explicitly asks for Props.
        with_thread_loop_lock(client.loop) do _
            subscribe_params!(something(client.node), ())
        end
        client_fence(client)
        budget = mode === :expiry ? 1.0 : 5.0
        sent_at = Client.monotonic()
        request = with_thread_loop_lock(client.loop) do _
            token = max(client.last_token, client.observation.max_accepted) + 1
            header = Envelope.RequestHeader(something(client.identity), Int64(81), token,
                UInt32(3), Int64(round(budget * 1e9)))
            set_param!(something(client.node), PipeWireAO.SPA.PARAM_PROPS,
                Client.encode_request(C.PROFILE, header, C.Command(:quit)))
            header
        end
        wait_proof(() -> R.cancelled(runtime), 5, "accepted terminal Quit")
        # This models the ordinary owner finally: science closes first; main
        # marks finished; only then the monitor publishes the successful reply.
        science_closed = true
        driver = @async begin
            R.finish!(runtime)
            close(runtime)
        end
        wait_proof(() -> runtime.transport.closed ||
            with_thread_loop_lock(runtime.transport.loop) do _
                terminal = runtime.transport.endpoint.terminal_request
                terminal !== nothing && terminal.header.token == request.token
            end, 5, "terminal published after scientific cleanup")
        @test science_closed
        sleep(0.1) # Deliberately defer peer observation beyond many Lua polls.
        @test !runtime.transport.closed
        @test !istaskdone(driver)

        if mode === :expiry
            fetch(driver)
            @test runtime.failure === nothing
            @test Client.monotonic() >= sent_at + budget
            @test runtime.transport.closed
        elseif mode === :proof
            with_thread_loop_lock(client.loop) do _
                update_properties!(something(client.marker),
                    Dict("pipewireao.rtc-control.instance" => string(client.marker_instance + 1)))
            end
            wait_proof(() -> istaskdone(driver), 5, "terminal proof mutation rejected")
            @test istaskfailed(driver)
            @test runtime.failure !== nothing
            controller = only(runtime.transport.endpoint.controllers)
            @test controller.retired && !controller.removed
        else
            saved_terminal = runtime.transport.endpoint.terminal_request
            for (offset, operation) in ((1, :status), (2, :quit))
                denied = Envelope.RequestHeader(request.controller, Int64(81), request.token + offset,
                    Client.operation_id(C.PROFILE, C.Command(operation)), Int64(1_000_000_000))
                with_thread_loop_lock(client.loop) do _
                    set_param!(something(client.node), PipeWireAO.SPA.PARAM_PROPS,
                        Client.encode_request(C.PROFILE, denied, C.Command(operation)))
                end
                client_fence(client)
                with_thread_loop_lock(client.loop) do _
                    enum_params!(something(client.node), PipeWireAO.SPA.PARAM_PROPS; count=UInt32(8))
                end
                wait_proof(() -> with_thread_loop_lock(client.loop) do _
                    observed = client.observation.rejection
                    observed !== nothing && observed.value.header.token == denied.token
                end, 5, "new terminal work rejected")
                @test client.observation.rejection.value.header.result == -108
                @test runtime.transport.endpoint.pending === nothing
                @test runtime.transport.endpoint.terminal_request.header.token == request.token
                @test !istaskdone(driver)
            end
            with_thread_loop_lock(client.loop) do _
                set_param!(something(client.node), PipeWireAO.SPA.PARAM_PROPS,
                    Client.encode_request(C.PROFILE, request, C.Command(:quit)))
            end
            client_fence(client)
            with_thread_loop_lock(runtime.transport.loop) do _
                endpoint = runtime.transport.endpoint
                @test Endpoint.admission(endpoint, request, saved_terminal.payload) == 1
                @test endpoint.pending === nothing
                @test endpoint.terminal_request === saved_terminal
                @test endpoint.terminal_request.deadline == saved_terminal.deadline
                rejected, _ = Envelope.decode_rejection(endpoint.rejection)
                @test rejected.token == request.token + 2
            end
            with_thread_loop_lock(client.loop) do _
                enum_params!(something(client.node), PipeWireAO.SPA.PARAM_PROPS; count=UInt32(8))
            end
            wait_proof(() -> with_thread_loop_lock(client.loop) do _
                observed = client.observation.completion
                observed !== nothing && observed.value.header.token == request.token
            end, 5, "delayed exact terminal enumeration")
            reply = client.observation.completion.value
            @test reply.lifecycle === C.Stopped && reply.header.result == 0
            @test reply.header.controller == request.controller
            @test !istaskdone(driver)
            close(connection)
            wait_proof(() -> istaskdone(driver), 5, "exact terminal controller release")
            fetch(driver)
            @test runtime.failure === nothing
            @test runtime.transport.closed
            @test only(runtime.transport.endpoint.controllers).removed
        end
    finally
        connection === nothing || close(connection)
        if driver !== nothing
            wait_proof(() -> istaskdone(driver), 10, "bounded terminal driver cleanup")
        else
            try R.finish!(runtime) catch end
        end
        close(runtime)
    end
end

@testset "native terminal endpoint retained for delayed peer" begin
    modes = isempty(ARGS) ? (:release, :expiry, :proof) : (Symbol(only(ARGS)),)
    for mode in modes
        with_control_private_core((args...) -> terminal_owner(args...; mode))
    end
end
