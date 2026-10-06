using Test, PipeWireAO, PipeWireAODeployment

include("test_native_control_client.jl")
include("native_control_private_core.jl")
const OwnerEndpoint = PipeWireAODeployment.NativeControlEndpoint
const DECODE_DELAY = Ref(0.0)

function Client.decode_request(::TestProfile, header, payload::SPA.Struct)
    header.operation == 71 && isempty(payload.values) || throw(ArgumentError("invalid test action"))
    DECODE_DELAY[] > 0 && sleep(DECODE_DELAY[])
    return TestCommand()
end
Client.encode_rejection(::TestProfile, header, lifecycle) =
    Envelope.encode_rejection(header, SPA.Struct(Pod(SPA.Id(UInt32(lifecycle)))))
Client.encode_failure(::TestProfile, header, lifecycle) =
    Envelope.encode_completion(header, SPA.Struct(Pod(SPA.Id(UInt32(lifecycle)))))

function run_endpoint_proof(socket, directory, daemon)
    chmod(dirname(socket), 0o700)
    loop = ThreadLoop("test.native-owner")
    context = core = endpoint = nothing
    clients = Client.Client[]
    run_effects = Ref(true)
    quit = Ref(false)
    effects = Ref(0)
    owner_task = nothing
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => socket))
        end
        endpoint = OwnerEndpoint.Endpoint(TestProfile(), TestCommand, loop, core,
            "test.native.owner", Int64(23), Prepared)
        start!(loop)
        owner_task = @async begin
            while !quit[]
                OwnerEndpoint.poll!(endpoint)
                ticket = run_effects[] ? OwnerEndpoint.take!(endpoint) : nothing
                if ticket !== nothing
                    OwnerEndpoint.check_ticket(endpoint, ticket)
                    effects[] += 1
                    header = Envelope.ReplyHeader(ticket.header.controller, endpoint.instance,
                        ticket.header.token, ticket.header.operation, Int32(0))
                    OwnerEndpoint.complete!(endpoint, ticket,
                        Envelope.encode_completion(header, SPA.Struct(Pod(Int32(effects[])))))
                end
                sleep(0.002)
            end
        end
        check_owner() = begin
            istaskfailed(owner_task) && fetch(owner_task)
            Base.process_exited(daemon) && error("private core exited")
            nothing
        end
        connect_client() = Client.connect(TestProfile(), socket, "test.native.owner", getpid(), 23;
            deadline=Client.monotonic() + 10, check=check_owner)
        first_client = connect_client()
        push!(clients, first_client)
        second_client = connect_client()
        push!(clients, second_client)
        @test first_client.identity != second_client.identity
        @test first_client.core !== second_client.core
        @test first_client.identity in first_client.observation.capability.controllers
        @test second_client.identity in second_client.observation.capability.controllers
        @test length(endpoint.controllers) == 2
        @test effects[] == 0

        ask(client; seconds=10.0) = Client.request!(client, TestCommand();
            deadline=Client.monotonic() + seconds, check=check_owner)
        reply = ask(first_client)
        @test reply.header.result == 0
        @test pod_value(Int32, only(reply.payload.values)) == 1
        @test effects[] == 1
        @test endpoint.pending === nothing
        previous_terminal = endpoint.terminal_request

        # Wrong owner profile is rejected by metadata before any request.
        @test_throws Client.UnknownOutcome Client.connect(CalibrationProfile(), socket,
            "test.native.owner", getpid(), 23; deadline=Client.monotonic() + 10, check=check_owner)
        @test effects[] == 1

        # The owner can still publish observations while effects are held.
        run_effects[] = false
        pending = @async ask(first_client)
        wait_proof(() -> endpoint.pending !== nothing, 5, "staged owner action"; check=check_owner)
        accepted = endpoint.pending
        previous_rejection = copy(endpoint.rejection.data)
        with_thread_loop_lock(loop) do _
            OwnerEndpoint.stage!(endpoint, Envelope.encode_request(previous_terminal.header, SPA.Struct()))
        end
        rejection_header, _ = Envelope.decode_rejection(endpoint.rejection)
        @test rejection_header.result == -116
        @test endpoint.pending === accepted
        wait_proof(() -> with_thread_loop_lock(second_client.loop) do _
            second_client.observation.max_accepted >= accepted.header.token
        end, 5, "accepted capability visible to other controller"; check=check_owner)
        busy = ask(second_client)
        @test busy.header.result == -16
        @test endpoint.pending === accepted
        @test effects[] == 1
        run_effects[] = true
        wait_proof(() -> istaskdone(pending), 5, "single accepted owner effect"; check=check_owner)
        @test fetch(pending).header.result == 0
        @test effects[] == 2

        # Queue expiry must retire work without executing it. A client timeout
        # does not extend the owner's ticket and never triggers a retry.
        run_effects[] = false
        expired = @async try
            ask(first_client; seconds=0.3)
        catch error
            error
        end
        wait_proof(() -> endpoint.pending !== nothing, 5, "queued expiry admission"; check=check_owner)
        wait_proof(() -> istaskdone(expired), 5, "finite client expiry"; check=check_owner)
        @test fetch(expired) isa Client.UnknownOutcome
        @test effects[] == 2
        run_effects[] = true
        wait_proof(() -> endpoint.pending === nothing, 5, "retired expired ticket"; check=check_owner)
        header, _ = Envelope.decode_completion(endpoint.completion)
        @test header.result == -110
        @test effects[] == 2
        @test_throws Client.UnknownOutcome ask(first_client)

        # An actual controller removal invalidates its accepted queued action.
        close(first_client)
        replacement = connect_client()
        push!(clients, replacement)
        run_effects[] = false
        ticket_task = @async try
            ask(replacement)
        catch error
            error
        end
        wait_proof(() -> endpoint.pending !== nothing, 5, "removal admission"; check=check_owner)
        removed_identity = replacement.identity
        with_thread_loop_lock(replacement.loop) do _
            close(replacement.marker)
        end
        wait_proof(() -> !OwnerEndpoint.controller_present(endpoint, removed_identity),
            5, "owner observed registry removal"; check=check_owner)
        run_effects[] = true
        wait_proof(() -> endpoint.pending === nothing, 5, "removed caller ticket retirement"; check=check_owner)
        wait_proof(() -> istaskdone(ticket_task), 5, "removed caller outcome"; check=check_owner)
        @test fetch(ticket_task) isa Client.UnknownOutcome
        @test effects[] == 2

        reply = ask(second_client)
        @test reply.header.result == 0
        @test effects[] == 3

        # Budget consumption begins at receipt, including owner-side decoding.
        run_effects[] = false
        DECODE_DELAY[] = 0.05
        with_thread_loop_lock(loop) do _
            header = Envelope.RequestHeader(second_client.identity, endpoint.instance,
                endpoint.last_token + 1, UInt32(71), Int64(10_000_000))
            OwnerEndpoint.stage!(endpoint, Envelope.encode_request(header, SPA.Struct()))
            taken = OwnerEndpoint.take!(endpoint)
            @test taken === nothing
            if taken !== nothing
                failed = Envelope.ReplyHeader(taken.header.controller, endpoint.instance,
                    taken.header.token, taken.header.operation, Int32(-110))
                OwnerEndpoint.complete!(endpoint, taken, Client.encode_failure(TestProfile(), failed, Prepared))
            end
        end
        DECODE_DELAY[] = 0.0
        @test effects[] == 3
        @test endpoint.failure === nothing

        # Retained registry proof cannot authorize effects after its loop stops.
        stopped_request = @async try
            ask(second_client)
        catch error
            error
        end
        wait_proof(() -> endpoint.pending !== nothing, 5, "stopped-loop admission"; check=check_owner)
        stopped_ticket = endpoint.pending
        stop!(loop)
        try
            @test_throws InvalidStateException OwnerEndpoint.poll!(endpoint)
            @test_throws InvalidStateException OwnerEndpoint.take!(endpoint)
            @test endpoint.pending === stopped_ticket
            @test effects[] == 3
        finally
            start!(loop)
        end
        with_thread_loop_lock(second_client.loop) do _
            close(second_client.marker)
        end
        run_effects[] = true
        wait_proof(() -> istaskdone(stopped_request), 5, "stopped caller cleanup"; check=check_owner)
        println("NATIVE_OWNER_ENDPOINT two_actual_controllers=true no_ports=true effects=$((effects[]))")
    finally
        quit[] = true
        if owner_task !== nothing
            wait_proof(() -> istaskdone(owner_task), 5, "owner dispatcher shutdown")
            fetch(owner_task)
        end
        foreach(close, reverse(clients))
        endpoint === nothing || close(endpoint)
        with_thread_loop_lock(loop) do _
            for resource in (core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
    end
end

@testset "cold native owner staging and registry lifetime" begin
    with_control_private_core(run_endpoint_proof)
end
