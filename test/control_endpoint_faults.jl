using Test, PipeWireAO, PipeWireAORTC
import Hsm
import Clocks
include("test_control_client.jl")
include("control_private_core.jl")
const Endpoint = PipeWireAORTC.ControlEndpoint

const DECODE_CLOCK = Ref{Union{Nothing,Clocks.CachedNanoClock}}(nothing)
function Client.decode_request(::TestProfile, header, payload::SPA.Struct)
    header.operation == 71 && isempty(payload.values) ||
        throw(ArgumentError("invalid action"))
    DECODE_CLOCK[] === nothing || Clocks.advance!(DECODE_CLOCK[], 1)
    return TestCommand()
end
Client.encode_rejection(::TestProfile, header, lifecycle) =
    Envelope.encode_rejection(header, SPA.Struct(Pod(SPA.Id(UInt32(lifecycle)))))
Client.encode_failure(::TestProfile, header, lifecycle) =
    Envelope.encode_completion(header, SPA.Struct(Pod(SPA.Id(UInt32(lifecycle)))))

function node_info(mask, properties)
    return NodeInfo(
        UInt32(42),
        UInt32(0),
        UInt32(0),
        UInt64(mask),
        UInt32(0),
        UInt32(0),
        PipeWireAO.NODE_STATE_IDLE,
        nothing,
        Dict{String,String}(properties),
        ParamInfo[],
    )
end
const CONTROLLER_PROPERTIES = Dict(
    "node.name" => "pipewireao.rtc.controller.test",
    "object.serial" => string(typemax(UInt64)),
    "pipewireao.rtc-control.protocol" => Client.PROTOCOL,
    "pipewireao.rtc-control.profile" => Client.CONTROLLER_PROFILE,
    "pipewireao.rtc-control.instance" => "9",
    "pipewireao.rtc-control.owner-pid" => string(getpid()),
)

@testset "controller property-change mask fences identity" begin
    controller = Endpoint.Controller(
        UInt32(42),
        typemax(UInt64),
        nothing,
        CONTROLLER_PROPERTIES["node.name"],
        UInt32(0),
        nothing,
        false,
        false,
        false,
    )
    Endpoint.controller_info!(controller, node_info(NODE_CHANGE_STATE, Dict()))
    @test !controller.verified && !controller.retired
    Endpoint.controller_info!(
        controller, node_info(NODE_CHANGE_PROPERTIES, CONTROLLER_PROPERTIES)
    )
    @test controller.verified && !controller.retired
    Endpoint.controller_info!(controller, node_info(NODE_CHANGE_STATE, Dict()))
    @test controller.verified && !controller.retired
    Endpoint.controller_info!(controller, node_info(NODE_CHANGE_PROPERTIES, Dict()))
    @test !controller.verified && controller.retired
    Endpoint.controller_info!(
        controller, node_info(NODE_CHANGE_PROPERTIES, CONTROLLER_PROPERTIES)
    )
    @test !controller.verified && controller.retired

    observation = Client.Observation(TestProfile(), Int64(23), UInt32(getpid()))
    client = Client.Client(
        ThreadLoop("test.node-metadata"),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        observation,
        "test.owner",
        "test.marker",
        Int64(9),
        UInt32(42),
        typemax(UInt64),
        IDENTITY,
        false,
        false,
        Int64(0),
        false,
        false,
        ReentrantLock(),
    )
    try
        properties = merge(
            CONTROLLER_PROPERTIES,
            Dict(
                "node.name" => "test.owner",
                "pipewireao.rtc-control.profile" => Client.profile_name(TestProfile()),
                "pipewireao.rtc-control.instance" => "23",
            ),
        )
        Client.node_info!(
            client, node_info(NODE_CHANGE_PROPERTIES, properties); marker = false
        )
        @test client.owner_ready && observation.failure === nothing
        Client.node_info!(client, node_info(NODE_CHANGE_STATE, Dict()); marker = false)
        @test observation.failure === nothing
        Client.node_info!(client, node_info(NODE_CHANGE_PROPERTIES, Dict()); marker = false)
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
            core = CoreConnection(context; properties = Dict("remote.name" => socket))
        end
        publisher = FaultPublisher(0, -1)
        endpoint = Endpoint.Endpoint(
            TestProfile(),
            TestCommand,
            loop,
            core,
            "test.owner.publication",
            Int64(23),
            Prepared;
            publisher,
        )
        @test typeof(endpoint.clock) === Clocks.SystemNanoClock
        @test endpoint.last_at === nothing
        start!(loop)
        # Fault injection tests publication and slot transitions in isolation.
        # Registry lifetime itself is qualified by the separate actual-client fixture.
        push!(
            endpoint.controllers,
            Endpoint.Controller(
                IDENTITY.global_id,
                IDENTITY.serial,
                IDENTITY,
                "test.controller",
                UInt32(getpid()),
                nothing,
                true,
                false,
                false,
            ),
        )
        header = Envelope.RequestHeader(
            IDENTITY, Int64(23), Int64(1), UInt32(71), Int64(1_000_000_000)
        )
        request = Envelope.encode_request(header, SPA.Struct())
        with_thread_loop_lock(loop) do _
            if phase === :acceptance
                publisher.fail_at = publisher.calls + 1
                @test_throws ErrorException Endpoint.stage!(endpoint, request)
                @test endpoint.pending !== nothing
                @test Hsm.current(endpoint) === :Staged && !endpoint.applying
                @test endpoint.failure !== nothing
                @test_throws InvalidStateException Endpoint.take!(endpoint)
            else
                Endpoint.stage!(endpoint, request)
                if phase in (:completion, :terminal_completion)
                    # Preserve the proven controller while taking this unit ticket.
                    ticket = endpoint.pending
                    taken = Ref{Union{Nothing,typeof(ticket)}}(nothing)
                    Hsm.dispatch!(endpoint, :Taken, taken)
                    @test taken[] === ticket && Hsm.current(endpoint) === :Applying
                    terminal = phase === :terminal_completion
                    # This slot test retains its synthetic proof instead of
                    # asking registry discovery to replace it with a real node.
                    terminal && (endpoint.retained_controller = IDENTITY)
                    completion = Envelope.encode_completion(
                        Envelope.ReplyHeader(
                            IDENTITY,
                            Int64(23),
                            Int64(1),
                            UInt32(71),
                            terminal ? Int32(0) : Int32(-5),
                        ),
                        SPA.Struct(),
                    )
                    publisher.fail_at = publisher.calls + 1
                    @test_throws ErrorException Endpoint.complete!(
                        endpoint, ticket, completion; terminal
                    )
                    @test endpoint.pending === ticket && endpoint.applying
                    @test endpoint.terminal == terminal
                    @test Hsm.current(endpoint) ===
                        (terminal ? :TerminalApplying : :Applying)
                else
                    ticket = endpoint.pending
                    endpoint.controllers[1].retired = true
                    publisher.fail_at = publisher.calls + 1
                    @test_throws ErrorException Endpoint.take!(endpoint)
                    @test endpoint.pending === ticket
                    @test Hsm.current(endpoint) === :Staged
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
    for phase in (:acceptance, :completion, :terminal_completion, :expiry)
        with_control_private_core() do socket, directory, daemon
            publication_fault(socket, directory, daemon, phase)
        end
    end
end

function endpoint_clock_proof(socket, directory, daemon, origin, mode)
    loop = ThreadLoop("test.owner.signed-clock")
    context = core = endpoint = nothing
    clock = Clocks.CachedNanoClock(origin)
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties = Dict("remote.name" => socket))
        end
        endpoint = Endpoint.Endpoint(
            TestProfile(),
            TestCommand,
            loop,
            core,
            "test.owner.clock",
            Int64(23),
            Prepared;
            clock,
        )
        @test endpoint.clock === clock && endpoint.last_at === nothing
        start!(loop)
        with_thread_loop_lock(loop) do _
            push!(
                endpoint.controllers,
                Endpoint.Controller(
                    IDENTITY.global_id,
                    IDENTITY.serial,
                    IDENTITY,
                    "test.controller",
                    UInt32(getpid()),
                    nothing,
                    true,
                    false,
                    false,
                ),
            )
            # Keep this synthetic proof while exercising the real filter/lock.
            endpoint.retained_controller = IDENTITY
            header = Envelope.RequestHeader(
                IDENTITY, Int64(23), Int64(1), UInt32(71), Int64(1)
            )
            mode === :decode && (DECODE_CLOCK[] = clock)
            try
                Endpoint.stage!(endpoint, Envelope.encode_request(header, SPA.Struct()))
            finally
                DECODE_CLOCK[] = nothing
            end
            if mode === :overflow
                @test endpoint.pending === nothing && endpoint.last_token == 0
                @test Hsm.current(endpoint) === :Idle && endpoint.failure === nothing
                rejected, _ = Envelope.decode_rejection(endpoint.rejection)
                @test rejected.result == -22
            else
                ticket = endpoint.pending
                @test ticket.deadline == origin + 1
                if mode === :regression
                    Clocks.update!(clock, origin - 1)
                    @test_throws Client.UnknownOutcome Endpoint.take!(endpoint)
                    @test endpoint.pending === ticket && Hsm.current(endpoint) === :Staged
                    @test endpoint.failure == "native owner clock regressed"
                elseif mode === :submission
                    @test Endpoint.take!(endpoint) === ticket
                    Clocks.advance!(clock, 1)
                    @test_throws ErrorException Endpoint.check_ticket(endpoint, ticket)
                    @test endpoint.pending === ticket && endpoint.applying
                else
                    mode === :decode || Clocks.advance!(clock, 1)
                    @test Endpoint.take!(endpoint) === nothing
                    @test endpoint.pending === nothing && !endpoint.applying
                    @test endpoint.terminal_request === ticket
                    reply, _ = Envelope.decode_completion(endpoint.completion)
                    @test reply.result == -110
                end
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

@testset "native owner receipts and fresh admission use signed nanoseconds" begin
    with_control_private_core() do socket, directory, daemon
        for origin in (typemin(Int64), -Int64(2)^60, Int64(2)^53 + 1, typemax(Int64) - 1)
            endpoint_clock_proof(socket, directory, daemon, origin, :expiry)
        end
        endpoint_clock_proof(socket, directory, daemon, typemax(Int64), :overflow)
        endpoint_clock_proof(socket, directory, daemon, Int64(-10), :regression)
        endpoint_clock_proof(socket, directory, daemon, Int64(2)^53 + 1, :decode)
        endpoint_clock_proof(socket, directory, daemon, Int64(-10), :submission)
    end
end
