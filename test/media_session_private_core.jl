# Optional source-cohort selector; see docs/SESSION_POLICY_MIGRATION.md.
module MediaSessionPrivateCoreTests
using PipeWireAORTC, PipeWireAO, Test
const S = PipeWireAORTC.MediaSession
const Agent = S.Agent
const Clocks = S.Clocks
include("control_private_core.jl")
@testset "Owner-thread native discovery and startup cancellation" begin
    with_control_private_core() do socket, directory, daemon
        policy = Dict{String,Any}(
            "instance" => "101",
            "controller.instance" => "102",
            "admission.controller-instance" => "103",
            "node.name" => "session-test",
            "controller.node.name" => "session-controller-test",
            "startup.timeout-ms" => 300000,
            "session.uuid" => "e10d4214-9c5f-4a61-b584-69b65b2193f6",
            "properties" => Dict{String,String}(),
            "core.owner" => Dict("pid" => getpid(daemon), "nodes" => String[]),
            "owners" => [],
            "node.pids" => Dict{String,Int}(),
            "source" => Dict(
                "role" => "missing-source",
                "control-node" => "not-published",
                "pid" => getpid(),
            ),
            "session" => Dict(
                "sources" => [],
                "graphs" => [],
                "sinks" => [],
                "links" => [
                    Dict(
                        "output" => "not-published:output",
                        "input" => "not-published-sink:input",
                    ),
                ],
            ),
        )
        config = Dict(
            "context.properties" => Dict(
                "remote.name" => socket,
                "library.use-fallback" => false,
                "support.dbus" => false,
            ),
            "context.modules" => [
                Dict("name" => "libpipewire-module-protocol-native"),
                Dict("name" => "libpipewire-module-client-node"),
            ],
            "pipewireao.session" => policy,
        )
        path = joinpath(directory, "session.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path, config)
        session = S.Session(path; clock = Clocks.CachedNanoClock(0))
        try
            for _ in 1:100
                Agent.do_work(session)
                sleep(0.001)
            end
            @test session.controller !== nothing
            @test session.client_id > 0
            @test session.machine.lifecycle == PipeWireAORTC.RunnerCodec.Configuring
            S.observe_controllers!(session)
            S.drain!(session)
            S.observe_controllers!(session)
            @test isempty(S.Ingress.take_actions!(session.ingress))
            S.stage!(session.queue, S.ShutdownRequested())
            for _ in 1:1000
                Agent.do_work(session)
                session.done && break
                sleep(0.001)
            end
            @test session.done
            @test session.exitcode == 0
            @test session.machine.lifecycle == PipeWireAORTC.RunnerCodec.Offline
        finally
            close(session)
        end
    end

end

const LINK_SCHEMA = "org.pipewireao.test.session-cleanup/1"
const LINK_FORMAT = NdArrayFormat(
    NdArray.F32_LE, (2,); layout = NdArray.ROW_MAJOR, rate = PipeWireAO.SPA.Fraction(100, 1)
)
const LINK_CONTRACT = S.PortContract(
    "F32_LE", Int32[2], LINK_SCHEMA, "ROW_MAJOR", PipeWireAO.SPA.Fraction(100, 1)
)

function cleanup_session(socket, directory, daemon)
    policy = Dict{String,Any}(
        "instance" => "101",
        "controller.instance" => "102",
        "admission.controller-instance" => "103",
        "node.name" => "cleanup-session",
        "controller.node.name" => "pipewireao.rtc.controller.cleanup-session",
        "startup.timeout-ms" => 300000,
        "session.uuid" => "cb0fecda-c6bf-45da-9339-9b814585b9f2",
        "properties" => Dict{String,String}(),
        "core.owner" => Dict("pid" => getpid(daemon), "nodes" => String[]),
        "owners" => [],
        "node.pids" => Dict{String,Int}(),
        "source" => Dict(
            "role" => "missing-source",
            "control-node" => "not-published",
            "pid" => getpid(),
        ),
        "session" => Dict(
            "sources" => [],
            "graphs" => [],
            "sinks" => [],
            "links" => [
                Dict(
                    "output" => "not-published:output",
                    "input" => "not-published-sink:input",
                ),
            ],
        ),
    )
    configuration = Dict(
        "context.properties" => Dict(
            "remote.name" => socket,
            "library.use-fallback" => false,
            "support.dbus" => false,
        ),
        "context.modules" => [
            Dict("name" => "libpipewire-module-protocol-native"),
            Dict("name" => "libpipewire-module-client-node"),
        ],
        "pipewireao.session" => policy,
    )
    path = joinpath(directory, "cleanup-session.conf")
    PipeWireAORTC.ScienceExport.write_spa_config(path, configuration)
    return S.Session(path)
end

function wait_native(f, pump)
    deadline = PipeWireAORTC.ControlClient.monotonic() + 20.0
    while true
        pump()
        f() && return nothing
        PipeWireAORTC.ControlClient.monotonic() < deadline ||
            error("native cleanup observation timed out")
        sleep(0.001)
    end
end
function port_endpoint(registry, endpoint)
    id = node_id(endpoint)
    node = something(find_global(registry, id))
    port = only(
        filter(
            global_object ->
                get(global_object.properties, "node.id", nothing) == string(id),
            find_globals(registry; interface = "PipeWire:Interface:Port"),
        ),
    )
    return S.Endpoint(
        id, port.id, parse(UInt32, node.properties["client.id"]), LINK_CONTRACT
    )
end
function link_properties(output, input, path)
    Dict(
        "link.output.node" => string(output.node),
        "link.output.port" => string(output.port),
        "link.input.node" => string(input.node),
        "link.input.port" => string(input.port),
        "link.passive" => "true",
        "object.linger" => "false",
        "object.path" => path,
    )
end
function owned_link!(session, output, input, sequence, destroyed)
    path = "pipewireao/session/101/cleanup/$sequence"
    record = S.LinkRecord(
        sequence,
        path,
        output,
        input,
        true,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        true,
        true,
        false,
        false,
        false,
        nothing,
    )
    push!(session.links, record)
    try
        record.proxy = create_object(
            session.core,
            "link-factory",
            PipeWireAO.Link;
            properties = link_properties(output, input, path),
            on_bound = (_, id) -> S.stage!(session.queue, S.LinkBound(sequence, id)),
            on_info = (_, info) -> S.stage!(session.queue, S.LinkUpdated(sequence, info)),
            on_error = (_, _, error) ->
                S.stage!(session.queue, S.LinkError(sequence, sprint(showerror, error))),
        )
        record.listener = add_listener!(
            record.proxy.proxy;
            on_destroyed = (_) -> begin
                destroyed[] += 1
                S.stage!(session.queue, S.LinkDestroyed(sequence))
            end,
        )
    finally
        record.creation_pending = false
    end
    return record
end

function check_transport_cleanup(socket, directory, daemon, emergency)
    loop = MainLoop()
    context = core = registry = peer_link = session = nothing
    sources = NdArraySource[]
    sinks = NdArraySink[]
    owned = Tuple{PipeWireAO.Link,ManagedListener}[]
    try
        context = Context(loop)
        core = CoreConnection(context; properties = Dict("remote.name" => socket))
        registry = Registry(core)
        for index in 1:3
            push!(
                sources,
                NdArraySource(
                    core,
                    "cleanup-source-$index",
                    zeros(Float32, 2),
                    LINK_FORMAT;
                    schema = LINK_SCHEMA,
                ),
            )
            push!(
                sinks,
                NdArraySink(
                    core,
                    "cleanup-sink-$index",
                    zeros(Float32, 2),
                    LINK_FORMAT;
                    schema = LINK_SCHEMA,
                ),
            )
            start!(last(sources))
            start!(last(sinks))
        end
        wait_native(
            () ->
                length(find_globals(registry; interface = "PipeWire:Interface:Port")) == 6,
            () -> PipeWireAO.iterate!(loop),
        )
        outputs = [port_endpoint(registry, source) for source in sources]
        inputs = [port_endpoint(registry, sink) for sink in sinks]
        peer_link = create_object(
            core,
            "link-factory",
            PipeWireAO.Link;
            properties = link_properties(outputs[3], inputs[3], "peer/retained-link"),
        )
        wait_native(
            () -> any(
                global_object ->
                    get(global_object.properties, "object.path", nothing) ==
                    "peer/retained-link",
                find_globals(registry; interface = "PipeWire:Interface:Link"),
            ),
            () -> PipeWireAO.iterate!(loop),
        )
        peer = only(
            filter(
                global_object ->
                    get(global_object.properties, "object.path", nothing) ==
                    "peer/retained-link",
                find_globals(registry; interface = "PipeWire:Interface:Link"),
            ),
        )
        peer_serial = peer.properties["object.serial"]
        node_serials = Dict(
            global_object.id => global_object.properties["object.serial"] for
            global_object in find_globals(registry; interface = "PipeWire:Interface:Node")
        )
        session = cleanup_session(socket, directory, daemon)
        pump = () -> begin
            Agent.do_work(session)
            PipeWireAO.iterate!(loop)
        end
        wait_native(() -> session.client_id > 0 && session.controller !== nothing, pump)
        destroyed = Ref(0)
        active = owned_link!(session, outputs[1], inputs[1], UInt64(1), destroyed)
        push!(owned, (active.proxy, active.listener))
        wait_native(() -> begin
            active.failure === nothing || error(active.failure)
            active.negotiated && !active.pending
        end, pump)
        @test active.id !== nothing && active.negotiated
        @test find_global(session.registry, peer.id) !== nothing
        @test !haskey(session.objects, peer.id)
        @test !haskey(session.objects, active.id)
        @test all(id -> !haskey(session.objects, id), keys(node_serials))
        pending = owned_link!(session, outputs[2], inputs[2], UInt64(2), destroyed)
        push!(owned, (pending.proxy, pending.listener))
        @test pending.pending && pending.id === nothing

        if emergency
            # Fence the startup coroutine exactly as the owner does, then inject
            # the failed Hold receipt that requires transport disconnection.
            S.submit!(session.machine, S.Request(S.Quit()))
            S.drain!(session)
            session.active_task === nothing || wait(session.active_task)
            S.fail!(
                session.machine,
                session.machine.effect,
                "injected ingress Hold failure";
                submitted = true,
            )
            S.fail!(
                session.machine,
                session.machine.effect,
                "injected fault ingress Hold failure";
                submitted = true,
            )
            ticket = session.machine.effect
            @test !S.budgeted(ticket.effect)
            @test !session.done
            @test S.perform!(session, S.Job(ticket, false), ticket.effect) === nothing
            disconnected_before_receipt = !isopen(session.core) && !session.done
            @test disconnected_before_receipt
            S.update!(
                session,
                S.EffectCompleted(ticket, nothing, Clocks.time_nanos(session.source_clock)),
            )
            @test session.done && session.exitcode == 1
            @test isopen(session.context)
        else
            @test close(session) === nothing
        end
        core_closed = !isopen(session.core)
        owned_released = isempty(session.links) && isempty(session.objects)
        handles_closed = all(pair -> !isopen(pair[1]) && !isopen(pair[2]), owned)
        @test core_closed
        @test owned_released
        @test handles_closed
        @test destroyed[] == 0 # Lifetime listeners detach before proxy destruction.
        if !isopen(session.core)
            wait_native(
                () ->
                    !any(
                        global_object ->
                            get(global_object.properties, "object.path", nothing) in
                            (active.path, pending.path),
                        find_globals(registry; interface = "PipeWire:Interface:Link"),
                    ),
                () -> PipeWireAO.iterate!(loop),
            )
            @test !any(
                global_object -> get(global_object.properties, "object.path", nothing) in
                (active.path, pending.path),
                find_globals(registry; interface = "PipeWire:Interface:Link"),
            )
        end
        retained = something(find_global(registry, peer.id))
        @test retained.properties["object.serial"] == peer_serial && isopen(peer_link)
        peer_nodes_retained = all(node_serials) do (id, serial)
            global_object = find_global(registry, id)
            global_object !== nothing && global_object.properties["object.serial"] == serial
        end
        @test peer_nodes_retained
        @test all(endpoint -> isopen(endpoint), sources) &&
            all(endpoint -> isopen(endpoint), sinks)
    finally
        # Also make the pre-fix failure safe: created proxies were not part of
        # the old close path and must be explicitly retired before retrying it.
        try
            for (proxy, listener) in owned
                close(listener)
                close(proxy)
            end
        finally
            try
                session === nothing || close(session)
            finally
                try
                    peer_link === nothing || close(peer_link)
                    foreach(close, sources)
                    foreach(close, sinks)
                finally
                    registry === nothing || close(registry)
                    core === nothing || close(core)
                    context === nothing || close(context)
                    close(loop)
                end
            end
        end
    end
end
@testset "Owned active and pending Links close before Core disconnect" begin
    with_control_private_core(; allow_passive = true) do socket, directory, daemon
        check_transport_cleanup(socket, directory, daemon, false)
        check_transport_cleanup(socket, directory, daemon, true)
    end
end

mutable struct ClosingProxy
    failure::Union{Nothing,Exception}
    closed::Bool
end
function Base.close(proxy::ClosingProxy)
    proxy.failure === nothing || throw(proxy.failure)
    proxy.closed = true
    return nothing
end
@testset "Transport cleanup continues after a bound-object failure" begin
    with_control_private_core() do socket, directory, daemon
        session = cleanup_session(socket, directory, daemon)
        primary = ErrorException("earlier owner failure")
        failure = ErrorException("injected bound-object close failure")
        bad = ClosingProxy(failure, false)
        good = ClosingProxy(nothing, false)
        bad_id, good_id = typemax(UInt32) - UInt32(1), typemax(UInt32) - UInt32(2)
        session.objects[bad_id] = S.Object{ClosingProxy,NodeInfo}(
            bad_id, UInt64(1001), Dict{String,String}(), bad, nothing, false
        )
        session.objects[good_id] = S.Object{ClosingProxy,NodeInfo}(
            good_id, UInt64(1002), Dict{String,String}(), good, nothing, false
        )
        try
            failures = Exception[primary]
            S._close_transport!(session, failures)
            @test failures == Exception[primary, failure]
            @test !bad.closed && good.closed
            @test haskey(session.objects, bad_id) && !haskey(session.objects, good_id)
            @test !isopen(session.core)
            @test isopen(session.context)
        finally
            bad.failure = nothing
            close(session)
        end
    end
end
end
