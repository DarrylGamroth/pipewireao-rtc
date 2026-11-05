# Optional CPU/private-core transport selector; no instrument optics or devices.
using Test,
    PipeWireAO, PipeWireAORTC, FilterGraphIsland, FilterGraphPipeWire, JuliaFilterGraph
using AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsCalibration
include("control_private_core.jl")
const Transport = Base.get_extension(PipeWireAORTC, :PipeWireAORTCCalibrationExt)
isdefined(Transport, :start_calibration_graph) ||
    Base.include(Transport, joinpath(@__DIR__, "..", "ext", "calibration_transport.jl"))

function transport_link(core, registry, output, output_port, input, input_port)
    return with_thread_loop_lock(main_loop(core)) do _
        create_object(
            core,
            "link-factory",
            PipeWireAO.Link;
            properties = Dict(
                "link.output.node" => string(output),
                "link.output.port" => string(output_port),
                "link.input.node" => string(input),
                "link.input.port" => string(input_port),
                "object.linger" => "false",
            ),
        )
    end
end

function transport_test(socket, directory, daemon)
    wake = Base.AsyncCondition()
    notify_owner() = (ccall(:uv_async_send, Cint, (Ptr{Cvoid},), wake); nothing)
    function await(predicate)
        deadline = time_ns() / 1e9 + 10
        timer = Timer(_ -> notify_owner(), 10)
        try
            while !predicate()
                time_ns() / 1e9 < deadline || error("calibration transport test deadline")
                wait(wake)
            end
        finally
            close(timer)
        end
    end
    loop = ThreadLoop("test.calibration-probe")
    context =
        core =
            registry =
                listener =
                    graph =
                        worker =
                            cancelled = probe = demand_sink = trigger_listener = nothing
    source_cycles = Threads.Atomic{UInt64}(0)
    links = PipeWireAO.Link[]
    demanded = zeros(Float32, 2)
    demand_sequence = Threads.Atomic{UInt64}(0)
    demand_reference = Ref{Union{Nothing,ReferenceTimestamp}}(nothing)
    buffer = StreamBuffer()
    try
        path = joinpath(directory, "graph.conf")
        write(
            path,
            """
{ filter.graph = {
    nodes = [{ name = pdm label = pdm-command-f32 type = ndarray
        config = { actuator_count = 2 command_limits = [-0.5 0.5]
            slew_limit = null initial_current = null quantization_origin = null
            quantization_step = null dither_seed = null } }]
    inputs = ["pdm:requested"]
    outputs = ["pdm:demanded" "pdm:constraint-feedback"]
} }
""",
        )
        graph = FilterGraphIsland.prepare_service_graph(
            FilterGraphIsland.parse_arguments([
                "--graph", path, "--check", "--execution", "complete-frame"
            ]),
        )
        projection = Transport.GraphProjection(
            graph;
            document = PipeWireAORTC.DeploymentConfiguration.decode(
                path, ENV["PIPEWIREAO_PREFIX"]
            ),
            bindings = PipeWireAORTC.GraphOwner.FITSBinding[],
            parameters = Dict{Symbol,Array}(),
            source_graph_sha256 = PipeWireAORTC.InstrumentCalibration.digest(path),
            parameter_sources = Dict{Symbol,PipeWireAORTC.Artifacts.FITSArtifact}(),
            parameter_sha256 = Dict{Symbol,String}(),
        )
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties = Dict("remote.name" => socket))
            registry = Registry(core)
            listener = add_listener!(
                registry;
                on_global_added = (registry, global_object) -> notify_owner(),
                on_global_removed = (registry, id) -> notify_owner(),
            )
        end
        start!(loop)
        cancelled = Transport.start_calibration_graph(
            projection,
            socket,
            "test.cancelled-calibration-pdm",
            500//1;
            notify = notify_owner,
        )
        Transport.quit_calibration_graph!(cancelled)
        await(() -> istaskdone(cancelled.task))
        @test Transport.finish_calibration_graph!(cancelled).error === nothing &&
            cancelled.stop_sent &&
            !Transport.calibration_graph_status(cancelled).ready
        workers = Transport.CalibrationGraphWorker[]
        Transport.start_command_graphs!(
            workers,
            projection,
            socket,
            "test.calibration-pdm",
            500//1;
            notify = notify_owner,
            reference_clock = METADATA_CLOCK_REALTIME,
        )
        worker = only(workers)
        await(
            () ->
                Transport.calibration_graph_status(worker).ready || istaskdone(worker.task),
        )
        @test Transport.calibration_graph_status(worker).error === nothing
        # Registry state has registry wakeups; a client's later bound node ID
        # has no equivalent notification on this owner's condition.
        endpoint = Ref{Any}(nothing)
        await() do
            endpoint[] = Transport.calibration_endpoint(
                registry, "test.calibration-pdm", "in", :requested
            )
            endpoint[] !== nothing
        end
        @test endpoint[].node.properties["node.name"] == "test.calibration-pdm"
        @test endpoint[].port.properties["port.name"] == "requested"
        @test Transport.calibration_incarnation_present(registry, endpoint[])
        @test Transport.calibration_endpoint(
            registry, "test.absent-calibration-pdm", "in", :requested
        ) === nothing
        @test Transport.calibration_endpoint(
            registry, "test.calibration-pdm", "in", :absent
        ) === nothing
        @test_throws ErrorException Transport.calibration_endpoint(
            registry, "test.calibration-pdm", "out", nothing
        )
        original = endpoint[].node
        properties = merge(original.properties, Dict("object.serial" => "replaced"))
        replaced = PipeWireAO.Global(
            original.id, original.permissions, original.type, original.version, properties
        )
        @test !Transport.calibration_incarnation_present(
            registry, (; node = replaced, port = endpoint[].port)
        )
        @test_throws ErrorException Transport.calibration_link(
            core,
            registry,
            (; node = replaced, port = endpoint[].port),
            endpoint[];
            on_info = (_, _) -> nothing,
        )
        probe = Transport.prepare_command_probe(
            core,
            projection,
            500//1;
            notify = notify_owner,
            prefix = "unused-scalar-prefix",
            reference_clock = METADATA_CLOCK_REALTIME,
        )
        with_thread_loop_lock(loop) do _
            @test stream_properties(probe.source)["node.name"] == "calibration-requested"
            @test stream_properties(probe.feedback)["node.name"] ==
                "calibration-constraint-feedback"
            trigger_listener = add_listener!(
                probe.source;
                on_trigger_done = stream -> begin
                    Threads.atomic_add!(source_cycles, UInt64(1))
                    notify_owner()
                end,
            )
            demand_sink = Stream(
                core,
                "test.calibration-demand";
                properties = Dict(
                    "node.name" => "test.calibration-demand", "node.reliable" => "true"
                ),
                on_process = stream -> begin
                    dequeue_buffer!(buffer, stream) || return nothing
                    try
                        copyto!(
                            demanded,
                            reinterpret(
                                Float32,
                                buffer_memory(buffer_data(buffer), sizeof(demanded)),
                            ),
                        )
                        demand_reference[] = reference_timestamp(buffer)
                        demand_sequence[] = something(buffer_header(buffer)).sequence
                    finally
                        queue_buffer!(buffer, stream)
                    end
                    notify_owner()
                end,
            )
            format = NdArrayFormat(
                NdArray.F32_LE,
                (2,);
                rate = SPA.Fraction(500, 1),
                layout = NdArray.ROW_MAJOR,
            )
            connect!(
                demand_sink,
                :input;
                flags = STREAM_MAP_BUFFERS | STREAM_INACTIVE | STREAM_DONT_RECONNECT,
                params = (
                    ndarray_format(format; schema = "pipewireao/dm-command-opd-um-f32/1"),
                    Pod(buffers_param(size = 8, buffers = 2)),
                    Pod(header_metadata_param()),
                    Pod(metadata_param(MetadataRequirement(SPA.META_REFERENCE_TIMESTAMP))),
                ),
            )
        end
        roundtrip(registry)
        function port(node, direction, name = nothing)
            matches = find_globals(
                registry;
                interface = "PipeWire:Interface:Port",
                properties = ("node.id" => string(node), "port.direction" => direction),
            )
            name === nothing || (
                matches = filter(
                    p -> get(p.properties, "port.name", nothing) == name, matches
                )
            )
            return only(matches).id
        end
        owner_id = endpoint[].node.id
        for (output, outport, input, inport) in (
            (
                node_id(probe.source),
                port(node_id(probe.source), "out"),
                owner_id,
                port(owner_id, "in", "requested"),
            ),
            (
                owner_id,
                port(owner_id, "out", "constraint-feedback"),
                node_id(probe.feedback),
                port(node_id(probe.feedback), "in"),
            ),
            (
                owner_id,
                port(owner_id, "out", "demanded"),
                node_id(demand_sink),
                port(node_id(demand_sink), "in"),
            ),
        )
            push!(links, transport_link(core, registry, output, outport, input, inport))
        end
        roundtrip(core)
        with_thread_loop_lock(loop) do _
            set_active!(probe.feedback, true)
            set_active!(demand_sink, true)
            set_active!(probe.source, true)
        end
        @test_throws ArgumentError Transport.stage!(probe, UInt64(0), Float32[0, 0])
        @test_throws DimensionMismatch Transport.stage!(probe, UInt64(1), Float32[0])
        @test_throws ArgumentError Transport.stage!(probe, UInt64(1), Float32[Inf, 0])
        for (sequence, figure, expected, feedback) in (
            (UInt64(1), Float32[0.25, -0.75], Float32[0.25, -0.5], Float32[0, -0.25]),
            (UInt64(2), Float32[0, 0], Float32[0, 0], Float32[0, 0]),
        )
            prior_cycles = source_cycles[]
            Transport.stage!(probe, sequence, figure)
            await(
                () -> begin
                    snapshot = Transport.calibration_probe_snapshot(probe)
                    snapshot.error === nothing || throw(snapshot.error)
                    source_cycles[] > prior_cycles && snapshot.published == sequence
                end
            )
            try
                await(
                    () -> begin
                        snapshot = Transport.calibration_probe_snapshot(probe)
                        snapshot.error === nothing || throw(snapshot.error)
                        snapshot.received == sequence && demand_sequence[] == sequence
                    end
                )
            catch
                @show Transport.calibration_probe_snapshot(probe) Transport.calibration_graph_status(
                    worker
                ).ready demand_sequence[]
                istaskdone(worker.task) &&
                    (@show Transport.calibration_graph_status(worker).error)
                with_thread_loop_lock(loop) do _
                    @show stream_state(probe.source) stream_state(probe.feedback) stream_state(
                        demand_sink
                    )
                end
                rethrow()
            end
            snapshot = Transport.calibration_probe_snapshot(probe)
            @test snapshot.published == snapshot.received == sequence
            @test snapshot.values == feedback
            @test demanded == expected
            @test something(demand_reference[]).clock == METADATA_CLOCK_REALTIME
            @test something(demand_reference[]).timestamp_nanoseconds > 2^53
            snapshot.values[1] = 99
            @test Transport.calibration_probe_snapshot(probe).values == feedback
            @test_throws ArgumentError Transport.stage!(probe, sequence, figure)
        end
        Transport.quit_calibration_graph!(worker)
        await(() -> istaskdone(worker.task))
        status = Transport.finish_calibration_graph!(worker)
        @test status.done && status.error === nothing && !status.ready
        with_thread_loop_lock(loop) do _
            close(trigger_listener)
            trigger_listener = nothing
        end
        close(probe)
        @test_throws InvalidStateException Transport.stage!(probe, UInt64(3), Float32[0, 0])
    finally
        worker === nothing || Transport.quit_calibration_graph!(worker)
        worker === nothing || await(() -> istaskdone(worker.task))
        cancelled === nothing || Transport.quit_calibration_graph!(cancelled)
        cancelled === nothing || await(() -> istaskdone(cancelled.task))
        with_thread_loop_lock(loop) do _
            trigger_listener === nothing || close(trigger_listener)
        end
        probe === nothing || close(probe)
        with_thread_loop_lock(loop) do _
            foreach(close, reverse(links))
            for resource in (demand_sink, listener, registry, core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
        graph === nothing || FilterGraphIsland.close_execution(graph)
        close(wake)
    end
end

@testset "calibration graph worker and command transport" begin
    Threads.nthreads() >= 2 || error("run calibration transport selector with --threads=2")
    with_control_private_core(transport_test)
    @test !any(id.name in ("CUDA", "AMDGPU") for id in keys(Base.loaded_modules))
end
