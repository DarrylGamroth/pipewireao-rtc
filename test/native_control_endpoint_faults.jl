using Test, PipeWireAO, PipeWireAODeployment
include("test_native_control_client.jl")
include("native_control_private_core.jl")
const Endpoint = PipeWireAODeployment.NativeControlEndpoint

Client.decode_request(::TestProfile, header, payload::SPA.Struct) =
    header.operation == 71 && isempty(payload.values) ? TestCommand() : throw(ArgumentError("invalid action"))
Client.encode_rejection(::TestProfile, header, lifecycle) =
    Envelope.encode_rejection(header, SPA.Struct(Pod(SPA.Id(UInt32(lifecycle)))))
Client.encode_failure(::TestProfile, header, lifecycle) =
    Envelope.encode_completion(header, SPA.Struct(Pod(SPA.Id(UInt32(lifecycle)))))

function node_info(mask, properties)
    return NodeInfo(UInt32(42), UInt32(0), UInt32(0), UInt64(mask), UInt32(0), UInt32(0),
        PipeWireAO.NODE_STATE_IDLE, nothing, Dict{String,String}(properties), ParamInfo[])
end
const CONTROLLER_PROPERTIES = Dict("node.name" => "pipewireao.rtc.controller.test",
    "object.serial" => string(typemax(UInt64)),
    "pipewireao.rtc-control.protocol" => Client.PROTOCOL,
    "pipewireao.rtc-control.profile" => Client.CONTROLLER_PROFILE,
    "pipewireao.rtc-control.instance" => "9",
    "pipewireao.rtc-control.owner-pid" => string(getpid()))

@testset "controller property-change mask fences identity" begin
    controller = Endpoint.Controller(UInt32(42), typemax(UInt64), nothing,
        CONTROLLER_PROPERTIES["node.name"], UInt32(0), nothing, false, false)
    Endpoint.controller_info!(controller, node_info(NODE_CHANGE_STATE, Dict()))
    @test !controller.verified && !controller.retired
    Endpoint.controller_info!(controller, node_info(NODE_CHANGE_PROPERTIES, CONTROLLER_PROPERTIES))
    @test controller.verified && !controller.retired
    Endpoint.controller_info!(controller, node_info(NODE_CHANGE_STATE, Dict()))
    @test controller.verified && !controller.retired
    Endpoint.controller_info!(controller, node_info(NODE_CHANGE_PROPERTIES, Dict()))
    @test !controller.verified && controller.retired
    Endpoint.controller_info!(controller, node_info(NODE_CHANGE_PROPERTIES, CONTROLLER_PROPERTIES))
    @test !controller.verified && controller.retired

    observation = Client.Observation(TestProfile(), Int64(23), UInt32(getpid()))
    client = Client.Client(ThreadLoop("test.node-metadata"), nothing, nothing, nothing,
        nothing, nothing, nothing, observation, "test.owner", "test.marker", Int64(9),
        UInt32(42), typemax(UInt64), IDENTITY, false, false, Int64(0), false, false, ReentrantLock())
    try
        properties = merge(CONTROLLER_PROPERTIES, Dict("node.name" => "test.owner",
            "pipewireao.rtc-control.profile" => Client.profile_name(TestProfile()),
            "pipewireao.rtc-control.instance" => "23"))
        Client.node_info!(client, node_info(NODE_CHANGE_PROPERTIES, properties); marker=false)
        @test client.owner_ready && observation.failure === nothing
        Client.node_info!(client, node_info(NODE_CHANGE_STATE, Dict()); marker=false)
        @test observation.failure === nothing
        Client.node_info!(client, node_info(NODE_CHANGE_PROPERTIES, Dict()); marker=false)
        @test observation.fatal_failure !== nothing
    finally
        close(client)
    end
end

mutable struct FaultPublisher
    calls::Int
    fail_at::Int
end
function (publisher::FaultPublisher)(filter, params)
    publisher.calls += 1
    publisher.calls == publisher.fail_at && error("injected publication failure")
    return update_params!(filter, params)
end

function publication_fault(socket, directory, daemon, phase)
    loop = ThreadLoop("test.owner-publication")
    context = core = endpoint = nothing
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => socket))
        end
        publisher = FaultPublisher(0, -1)
        endpoint = Endpoint.Endpoint(TestProfile(), TestCommand, loop, core,
            "test.owner.publication", Int64(23), Prepared; publisher)
        start!(loop)
        # Fault injection tests publication and slot transitions in isolation.
        # Registry lifetime itself is qualified by the separate actual-client fixture.
        push!(endpoint.controllers, Endpoint.Controller(IDENTITY.global_id, IDENTITY.serial,
            IDENTITY, "test.controller", UInt32(getpid()), nothing, true, false))
        header = Envelope.RequestHeader(IDENTITY, Int64(23), Int64(1), UInt32(71), Int64(1_000_000_000))
        request = Envelope.encode_request(header, SPA.Struct())
        with_thread_loop_lock(loop) do _
            if phase === :acceptance
                publisher.fail_at = publisher.calls + 1
                @test_throws ErrorException Endpoint.stage!(endpoint, request)
                @test endpoint.pending !== nothing
                @test endpoint.failure !== nothing
                @test_throws InvalidStateException Endpoint.take!(endpoint)
            else
                Endpoint.stage!(endpoint, request)
                if phase === :completion
                    # Preserve the proven controller while taking this unit ticket.
                    endpoint.applying = true
                    ticket = endpoint.pending
                    completion = Envelope.encode_completion(Envelope.ReplyHeader(IDENTITY,
                        Int64(23), Int64(1), UInt32(71), Int32(-5)), SPA.Struct())
                    publisher.fail_at = publisher.calls + 1
                    @test_throws ErrorException Endpoint.complete!(endpoint, ticket, completion)
                    @test endpoint.pending === ticket && endpoint.applying
                else
                    ticket = endpoint.pending
                    endpoint.controllers[1].retired = true
                    publisher.fail_at = publisher.calls + 1
                    @test_throws ErrorException Endpoint.take!(endpoint)
                    @test endpoint.pending === ticket
                end
                @test endpoint.failure !== nothing
                @test_throws InvalidStateException Endpoint.stage!(endpoint, request)
            end
        end
    finally
        endpoint === nothing || close(endpoint)
        with_thread_loop_lock(loop) do _
            for resource in (core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
    end
end

@testset "publication failure fences accepted owner work" begin
    for phase in (:acceptance, :completion, :expiry)
        with_control_private_core() do socket, directory, daemon
            publication_fault(socket, directory, daemon, phase)
        end
    end
end
