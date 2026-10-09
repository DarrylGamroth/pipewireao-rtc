using Test, PipeWireAO, PipeWireAODeployment

include("native_control_private_core.jl")
const Actions = PipeWireAODeployment.NativeCalibrationActionCodec
const Client = PipeWireAODeployment.NativeControlClient
const Endpoint = PipeWireAODeployment.NativeControlEndpoint
const Lifecycle = PipeWireAODeployment.NativeAcquisitionLifecycleCodec

function action_retirement_proof(socket, directory, daemon)
    chmod(dirname(socket), 0o700)
    loop = ThreadLoop("test.calibration-action-retirement")
    context = core = endpoint = nothing
    clients = Client.Client[]
    pending_request = nothing
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => socket))
        end
        endpoint = Endpoint.Endpoint(Actions.PROFILE, Actions.Command, loop, core,
            "test.calibration.actions", Int64(23), Lifecycle.Connected)
        start!(loop)
        check_owner() = begin
            Endpoint.poll!(endpoint)
            Base.process_exited(daemon) && error("private core exited")
            nothing
        end
        for (index, cause) in enumerate((:deadline, :controller_removal))
            client = Client.connect(Actions.PROFILE, socket, "test.calibration.actions",
                getpid(), 23; deadline=Client.monotonic() + 10, check=check_owner)
            push!(clients, client)
            command = Actions.Command(typemax(UInt64), (UInt64(1) << 63) + UInt64(index),
                Actions.Hold())
            budget = cause === :deadline ? 0.5 : 10.0
            pending_request = @async try
                Client.request!(client, command; deadline=Client.monotonic() + budget,
                    check=check_owner)
            catch error
                error
            end
            wait_proof(() -> endpoint.pending !== nothing, 5, "action admission"; check=check_owner)
            accepted = endpoint.pending
            if cause === :deadline
                wait_proof(() -> istaskdone(pending_request), 5, "client timeout"; check=check_owner)
                wait_proof(() -> Client.monotonic() >= accepted.deadline, 5,
                    "accepted owner budget expired"; check=check_owner)
            else
                with_thread_loop_lock(client.loop) do _
                    close(client.marker)
                end
                wait_proof(() -> !Endpoint.controller_present(endpoint, client.identity), 5,
                    "controller retirement"; check=check_owner)
            end
            @test Endpoint.take!(endpoint) === nothing
            @test endpoint.pending === nothing && !endpoint.applying
            @test endpoint.terminal_request === accepted
            completion = Client.decode_completion(Actions.PROFILE, endpoint.completion)
            @test completion.run == command.run && completion.serial == command.serial
            @test completion.header.result == -110 && completion.result === nothing
            @test Client.same_request(completion.header, accepted.header)
            @test endpoint.failure === nothing
            wait_proof(() -> istaskdone(pending_request), 5, "caller retirement"; check=check_owner)
            @test fetch(pending_request) isa Client.UnknownOutcome
            pending_request = nothing
            close(client)
        end
    finally
        foreach(close, reverse(clients))
        pending_request === nothing || wait_proof(() -> istaskdone(pending_request), 5,
            "outstanding caller cleanup")
        endpoint === nothing || close(endpoint)
        with_thread_loop_lock(loop) do _
            for resource in (core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
    end
end

@testset "accepted calibration action retirement preserves run identity" begin
    with_control_private_core(action_retirement_proof)
end
