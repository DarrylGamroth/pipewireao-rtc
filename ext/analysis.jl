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

function analysis_discard_outputs(config, output_names)
    config.capture === nothing && return ()
    linked = Set(link.output.port for link in config.links if link.output.node == config.name)
    return Tuple(String(name) for name in output_names if !(String(name) in linked))
end

function analysis_source_loop(nodes)
    names = Set(String(get(node.properties, "node.loop.name", "")) for node in nodes)
    delete!(names, "")
    length(names) <= 1 || error("Analysis capture sources declare conflicting node.loop.name values")
    return isempty(names) ? nothing : only(names)
end

function analysis_connections(node, config, remote, finished; output_names=())
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
    sinks = Dict{String,PipeWireAO.Node}()
    source_nodes = PipeWireAO.Node[]
    states = Threads.Atomic{Int}[]
    failure = Ref{Union{Nothing,PipeWireAO.PipeWireError}}(nothing)
    failed = Threads.Atomic{Bool}(false)
    # The connection loop is the single writer; publish its owned error before
    # the control task reads it. Missing native factories must not look like
    # absent endpoints and spend the whole discovery deadline waiting.
    native_error = error -> begin
        if !failed[]
            failure[] = error
            failed[] = true
        end
        nothing
    end
    check_native_error() = failed[] ? throw(something(failure[])) : nothing
    try
        context, core, registry = PipeWireAO.with_thread_loop_lock(loop) do _
            context = PipeWireAO.Context(loop)
            core = PipeWireAO.CoreConnection(context; properties=Dict("remote.name" => remote),
                on_error=config.capture === nothing ? nothing :
                    ((_, _, _, error) -> native_error(error)))
            return context, core, PipeWireAO.Registry(core)
        end
        PipeWireAO.start!(loop)
        specifications = copy(config.links)
        discard_outputs = analysis_discard_outputs(config, output_names)
        sources = ()
        source_loop = nothing
        if !isempty(discard_outputs)
            source_specs = Tuple(link.output for link in config.links if link.input.node == config.name)
            while !finished[]
                check_native_error()
                candidates = map(endpoint -> analysis_endpoint(registry, endpoint, "out"), source_specs)
                if all(!isnothing, candidates)
                    sources = candidates
                    break
                end
                time_ns() < deadline || error("Analysis source discovery timed out")
                FilterGraphIsland.deployment_sleep(0.02)
            end
            finished[] && return nothing
            source_info = Dict{UInt32,PipeWireAO.NodeInfo}()
            PipeWireAO.with_thread_loop_lock(loop) do _
                for (original, _) in sources
                    # Full properties arrive on Node info, not registry globals.
                    # Capture the first copied snapshot under this loop's lock.
                    id = original.id
                    push!(source_nodes, bind(registry, original, PipeWireAO.Node;
                        on_error=(_, _, error) -> native_error(error),
                        on_info=(_, info) -> begin
                            if !haskey(source_info, id) &&
                                    (info.change_mask & PipeWireAO.NODE_CHANGE_PROPERTIES) != 0
                                source_info[id] = info
                            end
                            nothing
                        end))
                end
            end
            while !finished[]
                check_native_error()
                discovered = PipeWireAO.with_thread_loop_lock(loop) do _
                    all(endpoint -> haskey(source_info, endpoint[1].id), sources) || return false
                    for (original, _) in sources
                        info = source_info[original.id]
                        info.id == original.id &&
                            get(info.properties, "object.serial", nothing) == original.properties["object.serial"] ||
                            error("Analysis source info belongs to a different node")
                        info.error === nothing || error("Analysis source failed: $(info.error)")
                    end
                    source_loop = analysis_source_loop(values(source_info))
                    true
                end
                discovered && break
                time_ns() < deadline || error("Analysis source info discovery timed out")
                FilterGraphIsland.deployment_sleep(0.02)
            end
            finished[] && return nothing
        end
        for (index, port) in enumerate(discard_outputs)
            # Every native ndarray output needs a consumer-provided buffer pool.
            # Finite capture observes the complete Graph locally; these ordinary
            # sinks only keep its otherwise unconnected outputs progressing.
            # Keep their payload work on the source's declared observation loop.
            # Sources without that property retain the native default.
            name = "$(config.name).discard.$(FilterGraphPipeWire.node_id(node)).$index"
            properties = Dict("factory.name"=>"api.pipewireao.discard",
                "node.name"=>name, "node.virtual"=>"true",
                "node.want-driver"=>"true", "object.linger"=>"false")
            source_loop === nothing || (properties["node.loop.name"] = source_loop)
            sinks[name] = PipeWireAO.with_thread_loop_lock(loop) do _
                PipeWireAO.create_object(core, "spa-node-factory", PipeWireAO.Node;
                    on_error=(_, _, error) -> native_error(error),
                    properties)
            end
            push!(specifications, Analysis.LinkSpec(Analysis.Endpoint(config.name, port),
                Analysis.Endpoint(name, "in")))
        end
        endpoints = map(_ -> nothing, specifications)
        # Discovery is asynchronous: a dead server cannot strand this task in
        # a synchronous core roundtrip. Startup and teardown remain bounded.
        while !finished[]
            check_native_error()
            candidates = map(specifications) do link
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
        all(original -> analysis_incarnation_present(registry, original),
            (original for endpoint in sources for original in endpoint)) ||
            error("Analysis source changed after loop discovery")
        for pair in endpoints, endpoint in pair
            global_node, global_port = endpoint
            if global_node.properties["node.name"] == config.name
                global_node.id == FilterGraphPipeWire.node_id(node) ||
                    error("Analysis name belongs to a different node")
            end
            sink = get(sinks, global_node.properties["node.name"], nothing)
            sink === nothing || global_node.id == PipeWireAO.bound_id(sink) ||
                error("Analysis discard name belongs to a different node")
            analysis_incarnation_present(registry, global_node) &&
                analysis_incarnation_present(registry, global_port) ||
                error("Analysis endpoint changed during discovery")
        end
        for (output, input) in endpoints
            link_state = Threads.Atomic{Int}(Int(PipeWireAO.LINK_STATE_INIT))
            link = PipeWireAO.with_thread_loop_lock(loop) do _
                all(original -> analysis_incarnation_present(registry, original),
                    (original for endpoint in sources for original in endpoint)) ||
                    error("Analysis source changed before linking")
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
            check_native_error()
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
            check_native_error()
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
        try
            PipeWireAO.with_thread_loop_lock(loop) do _
                try
                    foreach(close, links)
                finally
                    try
                        foreach(close, values(sinks))
                    finally
                        try
                            foreach(close, source_nodes)
                        finally
                            isnothing(registry) || close(registry)
                            isnothing(core) || close(core)
                            isnothing(context) || close(context)
                        end
                    end
                end
            end
        finally
            close(loop)
        end
    end
    return nothing
end

function analysis_input_owner(graph)
    input_count = length(JuliaFilterGraph.input_formats(graph))
    input_count == 1 && return graph
    return JuliaFilterGraph.prepare_synchronized_inputs(graph; match=:acquisition)
end

function run_analysis_graph(config, remote, graph, boundary_layout, graph_sha256)
    input_owner = analysis_input_owner(graph)
    capture = Analysis.prepare_capture(config.capture, JuliaFilterGraph.output_formats(graph))
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
                analysis_connections(node, config, remote, finished;
                    output_names=keys(JuliaFilterGraph.output_formats(graph)))
            finally
                FilterGraphPipeWire.quit!(node)
            end
        end
        if capture !== nothing
            acquisition = FilterGraphIsland.spawn_monitor() do
                while capture.ready[] == 0 && !finished[] && !node.owner.frame_observer.failed[]
                    FilterGraphIsland.deployment_sleep(0.01)
                end
                FilterGraphPipeWire.quit!(node)
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
                try
                    close(node)
                finally
                    if capture !== nothing
                        # Native processing and owned output consumers are gone
                        # before filesystem, Git or SQLite work reaches this task.
                        if capture.ready[] == 0 && node.owner.frame_observer.failed[]
                            Analysis.fail_capture!(capture, :observer_failed)
                        end
                        Analysis.capture_artifacts(config, capture, finished; graph_sha256)
                    end
                end
            end
        end
    end
    return nothing
end

function Analysis.prepare_graph(config::Analysis.Config, remote::AbstractString)
    graph_sha256=PipeWireAORTC.DeploymentConfiguration.digest(config.graph)
    provenance=config.capture===nothing ? nothing : config.capture.provenance
    provenance===nothing || provenance.graph_sha256==graph_sha256 ||
        throw(ArgumentError("analysis graph differs from acquisition provenance"))
    bindings_sha256=config.fits_bindings===nothing ? nothing : PipeWireAORTC.DeploymentConfiguration.digest(config.fits_bindings)
    provenance===nothing || provenance.fits_bindings_sha256==bindings_sha256 ||
        throw(ArgumentError("analysis FITS bindings differ from acquisition provenance"))
    options = FilterGraphIsland.parse_arguments(["--graph", config.graph,
        "--name", config.name, "--remote", remote,
        "--rate", "$(numerator(config.rate))/$(denominator(config.rate))",
        "--boundary-layout", "row-major"])
    declarations = FilterGraphIsland.algorithm_declarations(options)
    entries = config.fits_bindings === nothing ? PipeWireAORTC.GraphOwner.FITSBinding[] :
        PipeWireAORTC.GraphOwner.bindings(config.fits_bindings)
    graph = FilterGraphIsland.prepare_service_graph(options; declarations,
        initial_parameters=formats -> begin
            artifacts=PipeWireAORTC.GraphOwner.prepare_artifacts(entries,formats)
            if provenance !== nothing
                hashes=Dict(String(port)=>artifact.provenance["original_sha256"] for (port,artifact) in artifacts)
                hashes==provenance.parameter_sha256 ||
                    throw(ArgumentError("analysis FITS snapshots differ from acquisition provenance"))
            end
            [port=>artifact.data for (port,artifact) in artifacts]
        end)
    try
        PipeWireAORTC.DeploymentConfiguration.digest(config.graph)==graph_sha256 ||
            throw(ArgumentError("analysis graph changed during preparation"))
        if config.fits_bindings !== nothing
            PipeWireAORTC.DeploymentConfiguration.digest(config.fits_bindings)==bindings_sha256 ||
                throw(ArgumentError("analysis FITS bindings changed during preparation"))
        end
    catch
        FilterGraphIsland.close_execution(graph)
        rethrow()
    end
    return (; graph, options, graph_sha256)
end

function Analysis.run_graph(config::Analysis.Config, remote::AbstractString)
    prepared = Analysis.prepare_graph(config, remote)
    graph, options = prepared.graph, prepared.options
    try
        Base.invokelatest(run_analysis_graph, config, remote, graph, options.boundary_layout,prepared.graph_sha256)
    finally
        FilterGraphIsland.close_execution(graph)
    end
    return nothing
end
