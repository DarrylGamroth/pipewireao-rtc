# Optional private-core selector for the independent GPI2 display publisher.
using Test
using PipeWireAO
using PipeWireAORTC
using FilterGraphAlgorithms
using FilterGraphPipeWire
using FilterGraphs

include("control_private_core.jl")

const GraphExt = Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt)
const SCHEMA = FilterGraphAlgorithms.PYRAMID_MEAN_PUPIL_INTENSITY_V1
const DOMAIN = ntuple(i -> UInt8(i), 16)

function intensity_metadata(sequence, generation)
    return SampleMetadata(1000 + sequence;
        timestamp_nanoseconds = 3000 * sequence, terminal = true,
        acquisition_identity = SampleAcquisitionIdentity(DOMAIN, generation, sequence),
        exposure_duration_nanoseconds = 500,
        reference_timestamp = SampleReferenceTimestamp(100_000 + sequence),
    )
end
intensity_sample(sequence, generation = 9) =
    GraphExt.ScalarSample(Float32(sequence), intensity_metadata(sequence, generation))

function intensity_receipt(buffer)
    data = buffer_data(buffer)
    value = only(reinterpret(Float32, buffer_memory(data, sizeof(Float32))))
    return (; value, header = buffer_header(buffer), identity = acquisition_identity(buffer),
        timing = exposure_timing(buffer), reference = reference_timestamp(buffer))
end

function verify_intensity(receipt, sequence; generation = 9)
    @test receipt.value == Float32(sequence)
    @test receipt.header.sequence == 1000 + sequence
    @test receipt.header.pts == 3000 * sequence
    @test receipt.identity == AcquisitionIdentity(AcquisitionDomain(DOMAIN), generation, sequence)
    @test receipt.timing.duration_nanoseconds == 500
    @test receipt.reference.timestamp_nanoseconds == 100_000 + sequence
end

function link_intensity(core, registry, display, sink_name)
    topology = Ref{NTuple{4,UInt32}}()
    wait_proof(10, "intensity source and sink Ports") do
        entries = globals(registry)
        source = filter(item -> item.type == "PipeWire:Interface:Node" &&
            get(item.properties, "node.name", nothing) == display.node, entries)
        sink = filter(item -> item.type == "PipeWire:Interface:Node" &&
            get(item.properties, "node.name", nothing) == sink_name, entries)
        length(source) == length(sink) == 1 || return false
        output_node, input_node = only(source).id, only(sink).id
        out = find_globals(registry; interface = "PipeWire:Interface:Port",
            properties = ("node.id" => string(output_node), "port.direction" => "out"))
        inp = find_globals(registry; interface = "PipeWire:Interface:Port",
            properties = ("node.id" => string(input_node), "port.direction" => "in"))
        length(out) == length(inp) == 1 || return false
        topology[] = (output_node, input_node, only(out).id, only(inp).id)
        return true
    end
    output_node, input_node, output_port, input_port = topology[]
    return with_thread_loop_lock(main_loop(core)) do _
        create_object(core, "link-factory", PipeWireAO.Link; properties = Dict(
            "link.output.node" => string(output_node), "link.output.port" => string(output_port),
            "link.input.node" => string(input_node), "link.input.port" => string(input_port),
            "object.linger" => "false",
        ))
    end
end

function verify_display_name(registry, display, loop; queue = false)
    nodes = find_globals(registry; interface = "PipeWire:Interface:Node",
        properties = ("node.name" => display.node,))
    node, tracker = with_thread_loop_lock(loop) do _
        node = PipeWireAO.bind(registry, only(nodes), PipeWireAO.Node)
        return node, PipeWireAO.track_info!(node)
    end
    try
        wait_proof(() -> PipeWireAO.has_current_info(tracker), 10, "display Node info")
        properties = PipeWireAO.current_info(tracker).properties
        @test properties["media.name"] == display.media
        @test properties["media.class"] == "Data/Source"
        if queue
            @test properties["device.api"] == "pipewireao.queue"
            @test !isempty(properties["pipewireao.queue.id"])
        end
    finally
        with_thread_loop_lock(loop) do _
            close(tracker)
            close(node)
        end
    end
    return nothing
end

function optional_link(publisher, registry)
    source_id = with_thread_loop_lock(_ -> node_id(publisher.stream), publisher.loop)
    source_id === nothing && return nothing
    links = find_globals(registry; interface = "PipeWire:Interface:Link",
        properties = ("link.output.node" => string(source_id),))
    return isempty(links) ? nothing : only(links)
end

function prepared_intensity(socket, directory)
    path = joinpath(directory, "pyramid.conf")
    PipeWireAORTC.ScienceExport.write_spa_config(path, Dict(
        "filter.graph" => Dict(
            "nodes" => [Dict(
                "type" => "ndarray", "name" => "pyramid", "label" => "pyramid-pupil-image-f32",
                "config" => Dict(
                    "image_size" => [4, 4], "pupil_size" => [2, 2],
                    "pupil_origins" => [[0, 0], [2, 0], [0, 2], [2, 2]],
                    "pupil_mask" => fill(true, 4),
                ),
            )],
            "inputs" => [Dict("name" => "image", "endpoint" => "pyramid:image")],
            "outputs" => [
                Dict("name" => "pixels", "endpoint" => "pyramid:reconstruction-pixels"),
                Dict("name" => "intensity", "endpoint" => "pyramid:mean-pupil-intensity"),
            ],
        ),
    ))
    owner = PipeWireAORTC.GraphOwner
    _, graph_args, _, properties, timeout, recovery, supervision, offsets, qualification,
        local_output = owner.arguments([
            "--remote", socket, "--bootstrap-node", "test.pyramid-bootstrap",
            "--bootstrap-instance", "19", "--graph", path, "--name", "test.pyramid",
            "--rate", "2000", "--boundary-layout", "row-major", "--session-run-control",
            "--latest-output", "intensity", "test.intensity-publisher", "mean-pupil-intensity",
            "--latest-output-sink", "test.intensity-input", "playback_1",
        ])
    options = owner.graph_options(
        FilterGraphPipeWire, graph_args, properties, timeout, recovery, supervision,
        offsets, qualification, local_output,
    )
    graph = FilterGraphPipeWire.prepare_service_graph(options.graph)
    try
        (; node, display) = GraphExt.graph_node(options, graph, Int64(19))
        try
            callback = node.owner.local_output.callback
            @test callback === display.latest
            @test display.node == "test.intensity-publisher"
            @test display.media == "mean-pupil-intensity"
            @test display.sink == (; node = "test.intensity-input", port = "playback_1")
            @test display.schema == SCHEMA
            @test display.format == NdArrayFormat(NdArray.F32_LE, (1,);
                layout = NdArray.ROW_MAJOR, rate = SPA.Fraction(2000, 1))

            inputs = (; image = zeros(Float32, 4, 4))
            outputs = (; pixels = zeros(Float32, 4, 4), intensity = zeros(Float32, 1))
            function emit(sequence, generation)
                fill!(inputs.image, Float32(sequence))
                inputs.image[1, 1] -= 0.5f0
                inputs.image[4, 4] += 0.5f0
                available = FilterGraphs.process!(
                    outputs, graph, inputs, (; image = intensity_metadata(sequence, generation)),
                )
                @test available.intensity
                metadata = FilterGraphs.output_metadata(graph).intensity
                callback(Val(:frame), outputs.intensity,
                    FilterGraphAlgorithms.AdmittedSampleMetadata(available.intensity, metadata))
                return nothing
            end
            return (; graph, node, display, emit)
        catch
            close(node)
            rethrow()
        end
    catch
        FilterGraphPipeWire.close_execution(graph)
        rethrow()
    end
end

function check_intensity_publisher(socket, directory; queue = false)
    display = (; node = "test.intensity-output", media = "mean-pupil-intensity")
    prepared = queue ? prepared_intensity(socket, directory) : nothing
    source = if prepared === nothing
        format = NdArrayFormat(NdArray.F32_LE, (1,);
            layout = NdArray.ROW_MAJOR, rate = SPA.Fraction(2000, 1))
        merge(display, (; latest = GraphExt.LatestScalar(), format, schema = SCHEMA, sink = nothing))
    else
        prepared.display
    end
    emit(sequence, generation = 9) = prepared === nothing ?
        GraphExt.replace_latest!(source.latest, intensity_sample(sequence, generation)) :
        prepared.emit(sequence, generation)
    publisher = nothing
    sink_name = "test.intensity-reader"
    sink_loop = ThreadLoop(sink_name)
    context = core = registry = sink = link = nothing
    receipts = NamedTuple[]
    held = StreamBuffer[]
    hold = Ref(false)
    try
        publisher = GraphExt.open_scalar_publisher(source, socket)
        with_thread_loop_lock(sink_loop) do _
            context = Context(sink_loop)
            core = CoreConnection(context; properties = Dict("remote.name" => socket))
            registry = Registry(core)
            params = GraphExt.ScalarStream(source.latest, source.format, source.schema).params
            sink = Stream(core, sink_name;
                properties = Dict("node.name" => sink_name, "media.type" => "Application"),
                on_param_changed = (stream, id, param) -> begin
                    id == SPA.PARAM_FORMAT && param !== nothing || return nothing
                    update_params!(stream, params)
                end,
                on_process = stream -> begin
                    buffer = dequeue_buffer(stream)
                    buffer === nothing && return nothing
                    push!(receipts, intensity_receipt(buffer))
                    if hold[]
                        push!(held, buffer)
                    else
                        queue_buffer!(buffer, stream)
                    end
                end,
            )
            connect!(sink, :input; flags = STREAM_MAP_BUFFERS | STREAM_NO_CONVERT,
                params = (ndarray_format(source.format; schema = source.schema), params...),
            )
        end
        start!(sink_loop)
        if queue
            wait_proof(() -> optional_link(publisher, registry) !== nothing, 10, "optional queue Link")
        end
        for sequence in 1:10
            emit(sequence)
        end
        link = link_intensity(core, registry, display, sink_name)
        verify_display_name(registry, display, sink_loop; queue)
        wait_proof(10, "latest sample after linking") do
            with_thread_loop_lock(_ -> !isempty(receipts), sink_loop)
        end
        with_thread_loop_lock(sink_loop) do _
            verify_intensity(only(receipts), 10)
            hold[] = !queue
        end
        if queue
            original = optional_link(publisher, registry)
            @test original !== nothing
            with_thread_loop_lock(_ -> destroy_global!(registry, original.id), sink_loop)
            wait_proof(10, "replacement optional display Link") do
                replacement = optional_link(publisher, registry)
                return replacement !== nothing && replacement.properties["object.serial"] !=
                    original.properties["object.serial"]
            end
            emit(501)
            wait_proof(10, "receipt through the replacement display Link") do
                with_thread_loop_lock(_ -> last(receipts).value == 501f0, sink_loop)
            end
            with_thread_loop_lock(_ -> verify_intensity(last(receipts), 501), sink_loop)
            return nothing
        end
        for sequence in 11:12
            emit(sequence)
            wait_proof(10, "retained intensity buffer $sequence") do
                with_thread_loop_lock(_ -> length(held) == sequence - 10, sink_loop)
            end
        end
        for sequence in 13:500
            emit(sequence)
        end
        with_thread_loop_lock(sink_loop) do _
            @test length(receipts) == 3
            hold[] = false
            foreach(buffer -> queue_buffer!(buffer, sink), held)
            empty!(held)
        end
        wait_proof(10, "latest sample after releasing buffers") do
            with_thread_loop_lock(_ -> length(receipts) > 3, sink_loop)
        end
        with_thread_loop_lock(sink_loop) do _
            verify_intensity(receipts[4], 500)
            close(link)
            link = nothing
        end
        wait_proof(10, "intensity stream paused after unlinking") do
            with_thread_loop_lock(publisher.loop) do _
                stream_state(publisher.stream) == PipeWireAO.LibPipeWire.PW_STREAM_STATE_PAUSED
            end
        end
        source.latest(Val(:reset))
        for sequence in 1:5
            emit(sequence, 10)
        end
        link = link_intensity(core, registry, display, sink_name)
        wait_proof(10, "latest sample after reconnecting") do
            with_thread_loop_lock(_ -> length(receipts) > 4, sink_loop)
        end
        with_thread_loop_lock(sink_loop) do _
            verify_intensity(receipts[5], 5; generation = 10)
        end
    finally
        stop!(sink_loop)
        with_thread_loop_lock(sink_loop) do _
            foreach(buffer -> queue_buffer!(buffer, sink), held)
            foreach(resource -> resource === nothing || close(resource),
                (link, sink, registry, core, context))
        end
        close(sink_loop)
        publisher === nothing || close(publisher)
        if prepared !== nothing
            close(prepared.node)
            FilterGraphPipeWire.close_execution(prepared.graph)
        end
    end
    return nothing
end

@testset "Latest mean pupil intensity on a private core" begin
    with_control_private_core((socket, directory, _) -> check_intensity_publisher(socket, directory))
end

@testset "A prepared pyramid output keeps the GUI queue through optional Link replacement" begin
    metadata = join(("{ type = $(r.type) size = $(r.size) required = false }"
        for r in PipeWireAORTC.Common.TELEMETRY_METADATA), ' ')
    queue = """
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-queue args = {
        node.name = test.intensity-queue
        queue.max-buffers = 1
        queue.storage = copy
        queue.overflow = drop-oldest
        queue.media = application/ndarray
        metadata = [ $metadata ]
        capture.props = { node.name = test.intensity-input node.loop.name = telemetry-loop
            node.group = pipewireao-telemetry }
        playback.props = { node.name = test.intensity-output node.loop.name = telemetry-loop
            media.class = Data/Source media.name = mean-pupil-intensity
            node.group = pipewireao-telemetry device.api = pipewireao.queue }
    } }
    """
    driver = """
    { factory = spa-node-factory args = {
        node.loop.name = telemetry-loop
        node.name = test.telemetry-driver
        factory.name = support.node.driver
        node.sync-group = sync.pipewireao-telemetry
        priority.driver = 100
        node.group = pipewireao-telemetry
    } }
    """
    with_control_private_core(;
        telemetry_loop = true, modules = queue, objects = driver
    ) do socket, directory, _
        check_intensity_publisher(socket, directory; queue = true)
    end
end
