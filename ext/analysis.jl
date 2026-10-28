const Analysis = PipeWireAORTC.Analysis

function analysis_link_observer(state, output, input)
    return (_, info) -> begin
        matches = (info.output_node_id, info.output_port_id,
            info.input_node_id, info.input_port_id) ==
            (output[1].id, output[2].id, input[1].id, input[2].id)
        state[] = Int(matches ? info.state : PipeWireAO.LINK_STATE_ERROR)
        return nothing
    end
end

function analysis_ready_notice(config, count)
    message = "PIPEWIREAO_ANALYSIS_READY name=$(config.name) links=$count\n"
    # The owner thread runs PipeWire's native loop. Julia's pipe stdout uses
    # libuv and can defer a background-task write until that owner returns.
    # Emit this one bounded startup notice through the ordinary POSIX fd.
    GC.@preserve message begin
        written = @ccall gc_safe=true write(1::Cint, pointer(message)::Ptr{UInt8},
            ncodeunits(message)::Csize_t)::Int
        written == ncodeunits(message) || error("Analysis readiness notice failed")
    end
    return nothing
end

# Analysis owns these ordinary application links. They never enter the required
# RTC admission cohort and are destroyed with this client, including on a crash.
function analysis_endpoint(registry, endpoint, direction)
    nodes = PipeWireAO.find_globals(registry; interface="PipeWire:Interface:Node",
        properties=("node.name" => endpoint.node,))
    length(nodes) <= 1 || error("Ambiguous analysis node $(endpoint.node)")
    isempty(nodes) && return nothing
    node = only(nodes)
    ports = PipeWireAO.find_globals(registry; interface="PipeWire:Interface:Port",
        properties=("node.id" => string(node.id), "port.name" => endpoint.port,
            "port.direction" => direction))
    length(ports) <= 1 || error("Ambiguous analysis port $(endpoint.node):$(endpoint.port)")
    isempty(ports) && return nothing
    port = only(ports)
    all(item -> haskey(item.properties, "object.serial"), (node, port)) ||
        error("Analysis endpoints require PipeWire object serials")
    return (node, port)
end

function analysis_incarnation_present(registry, original)
    current = PipeWireAO.find_global(registry, original.id)
    return current !== nothing &&
        get(current.properties, "object.serial", nothing) == original.properties["object.serial"]
end

function analysis_connections(node, config, remote, finished)
    deadline = time_ns() + UInt64(120_000_000_000)
    # Wait for this filter's loop to register it before a monitor can request
    # Quit. No monitor failure may race ahead of the owner's native Run call.
    while !finished[] && !(PipeWireAO.isrunning(node) &&
            FilterGraphPipeWire.node_id(node) !== nothing)
        time_ns() < deadline || error("Analysis node publication timed out")
        FilterGraphIsland.deployment_sleep(0.01)
    end
    finished[] && return nothing
    loop = PipeWireAO.ThreadLoop("rtc.analysis.connections")
    context = nothing
    core = nothing
    registry = nothing
    links = PipeWireAO.Link[]
    states = Threads.Atomic{Int}[]
    try
        context, core, registry = PipeWireAO.with_thread_loop_lock(loop) do _
            context = PipeWireAO.Context(loop)
            core = PipeWireAO.CoreConnection(context; properties=Dict("remote.name" => remote))
            return context, core, PipeWireAO.Registry(core)
        end
        PipeWireAO.start!(loop)
        endpoints = map(_ -> nothing, config.links)
        # Discovery is asynchronous: a dead server cannot strand this task in
        # a synchronous core roundtrip. Startup and teardown remain bounded.
        while !finished[]
            candidates = map(config.links) do link
                (analysis_endpoint(registry, link.output, "out"),
                    analysis_endpoint(registry, link.input, "in"))
            end
            if all(pair -> all(!isnothing, pair), candidates)
                endpoints = candidates
                break
            end
            time_ns() < deadline || error("Analysis endpoint discovery timed out")
            FilterGraphIsland.deployment_sleep(0.02)
        end
        finished[] && return nothing
        for pair in endpoints, endpoint in pair
            global_node, global_port = endpoint
            if global_node.properties["node.name"] == config.name
                global_node.id == FilterGraphPipeWire.node_id(node) ||
                    error("Analysis name belongs to a different node")
            end
            analysis_incarnation_present(registry, global_node) &&
                analysis_incarnation_present(registry, global_port) ||
                error("Analysis endpoint changed during discovery")
        end
        for (output, input) in endpoints
            link_state = Threads.Atomic{Int}(Int(PipeWireAO.LINK_STATE_INIT))
            link = PipeWireAO.with_thread_loop_lock(loop) do _
                all(original -> analysis_incarnation_present(registry, original),
                    (output..., input...)) || error("Analysis endpoint changed before linking")
                PipeWireAO.create_object(core, "link-factory", PipeWireAO.Link;
                    on_info=analysis_link_observer(link_state, output, input),
                    properties=Dict("link.output.node" => string(output[1].id),
                        "link.output.port" => string(output[2].id),
                        "link.input.node" => string(input[1].id),
                        "link.input.port" => string(input[2].id),
                        "object.linger" => "false"))
            end
            push!(links, link)
            push!(states, link_state)
        end
        published(link) = begin
            id = PipeWireAO.bound_id(link)
            id !== nothing && PipeWireAO.find_global(registry, id) !== nothing
        end
        while !finished[] && (!all(published, links) ||
                !all(state -> state[] >= Int(PipeWireAO.LINK_STATE_PAUSED), states))
            any(state -> state[] == Int(PipeWireAO.LINK_STATE_ERROR), states) &&
                error("Analysis link negotiation failed")
            time_ns() < deadline || error("Analysis link publication timed out")
            FilterGraphIsland.deployment_sleep(0.02)
        end
        finished[] && return nothing
        all(original -> analysis_incarnation_present(registry, original),
            (original for pair in endpoints for endpoint in pair for original in endpoint)) ||
            error("Analysis endpoint changed during link negotiation")
        analysis_ready_notice(config, length(links))
        while !finished[]
            any(state -> state[] == Int(PipeWireAO.LINK_STATE_ERROR), states) &&
                error("Analysis link failed")
            for pair in endpoints, endpoint in pair, original in endpoint
                analysis_incarnation_present(registry, original) ||
                    error("Analysis endpoint incarnation disappeared")
            end
            for link in links
                id = PipeWireAO.bound_id(link)
                id !== nothing && PipeWireAO.find_global(registry, id) !== nothing ||
                    error("Analysis link disappeared")
            end
            node_state = FilterGraphPipeWire.node_state(node)
            node_state == PipeWireAO.NDARRAY_FILTER_STATE_ERROR &&
                error("Analysis graph failed: $(FilterGraphPipeWire.last_error(node))")
            FilterGraphIsland.deployment_sleep(0.05)
        end
    finally
        FilterGraphPipeWire.quit!(node)
        PipeWireAO.with_thread_loop_lock(loop) do _
            foreach(close, links)
            isnothing(registry) || close(registry)
            isnothing(core) || close(core)
            isnothing(context) || close(context)
        end
        close(loop)
    end
    return nothing
end

function analysis_input_owner(graph)
    input_count = length(JuliaFilterGraph.input_formats(graph))
    input_count == 1 && return graph
    return JuliaFilterGraph.prepare_synchronized_inputs(graph; match=:acquisition)
end

function run_analysis_graph(config, remote, graph, boundary_layout)
    input_owner = analysis_input_owner(graph)
    capture = Analysis.prepare_capture(config.capture, JuliaFilterGraph.output_formats(graph))
    graph_sha256 = capture === nothing ? "" : PipeWireAORTC.DeploymentConfiguration.digest(config.graph)
    node = FilterGraphPipeWire.PipeWireNode(input_owner; name=config.name, remote,
        rate=config.rate, boundary_layout, connect=false, channel_units=config.channel_units,
        frame_observer=capture)
    finished = Threads.Atomic{Bool}(false)
    monitor = nothing
    acquisition = nothing
    try
        FilterGraphPipeWire.connect!(node)
        monitor = FilterGraphIsland.spawn_monitor() do
            try
                analysis_connections(node, config, remote, finished)
            finally
                FilterGraphPipeWire.quit!(node)
            end
        end
        if capture !== nothing
            acquisition = FilterGraphIsland.spawn_monitor() do
                Analysis.capture_artifacts(config, capture, finished;
                    pause=FilterGraphIsland.deployment_sleep, graph_sha256)
            end
        end
        FilterGraphPipeWire.run!(node)
    finally
        finished[] = true
        try
            isnothing(monitor) || fetch(monitor)
        finally
            try
                isnothing(acquisition) || fetch(acquisition)
            finally
                close(node)
            end
        end
    end
    return nothing
end

function Analysis.run_graph(config::Analysis.Config, remote::AbstractString)
    options = FilterGraphIsland.parse_arguments(["--graph", config.graph,
        "--name", config.name, "--remote", remote,
        "--rate", "$(numerator(config.rate))/$(denominator(config.rate))",
        "--boundary-layout", "row-major"])
    declarations = FilterGraphIsland.algorithm_declarations(options)
    graph = FilterGraphIsland.prepare_service_graph(options; declarations)
    try
        Base.invokelatest(run_analysis_graph, config, remote, graph, options.boundary_layout)
    finally
        FilterGraphIsland.close_execution(graph)
    end
    return nothing
end
