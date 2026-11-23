const CorrectionLoops = PipeWireAORTC.CorrectionLoops

struct CorrectionPriming{Port,Controller}
    controller::Controller
    property::String
    ready::Threads.Atomic{Bool}
end

function prepare_priming(options, graph)
    output = get(options, :prime_on_output, nothing)
    output === nothing && return nothing
    options.session_run_control && options.capture_backend === nothing &&
        options.execution == "complete-frame" && graph isa FilterGraphs.PreparedGraph ||
        throw(ArgumentError("correction priming requires a session-controlled complete-frame CPU graph"))
    local_output = get(options, :local_output, nothing)
    local_output !== nothing && local_output.port === output &&
        throw(ArgumentError("the correction priming output must be published by the graph owner"))
    format = get(FilterGraphs.output_formats(graph), output, nothing)
    format !== nothing && format.element_type <: AbstractFloat ||
        throw(ArgumentError("correction priming requires a floating-point graph output"))
    property = only(options.correction_properties)
    name = Symbol(first(split(property, ':')))
    controller = only(node.prepared for node in graph.nodes if node.name === name)
    get(FilterGraphAlgorithms.property_values(controller.plan), :closed, nothing) === false ||
        throw(ArgumentError("correction priming requires an initially open correction loop"))
    return CorrectionPriming{output,typeof(controller)}(
        controller, CorrectionLoops.STATUS_PREFIX * property * ".primed", Threads.Atomic{Bool}(false),
    )
end

function (observer::CorrectionPriming{Port})(::Val{:frame}, outputs, metadata) where {Port}
    receipt = getproperty(metadata, Port)
    identity = receipt.present && !receipt.value.corrupted ?
        FilterGraphAlgorithms.sample_acquisition_identity(receipt.value) : nothing
    duration = receipt.present ?
        FilterGraphAlgorithms.sample_exposure_duration_nanoseconds(receipt.value) : nothing
    # The graph's data thread adopts Plans before processing and owns this read.
    open = !FilterGraphAlgorithms.property_values(observer.controller.plan).closed
    observer.ready[] = open && identity !== nothing && identity.sequence > 0 &&
        duration !== nothing && duration > 0 && all(isfinite, getproperty(outputs, Port))
    return nothing
end

function (observer::CorrectionPriming)(::Union{Val{:invalidated},Val{:reset}})
    observer.ready[] = false
    return nothing
end

function correction_observation(loops, priming::CorrectionPriming)
    info = PipeWireAO.SPA.PropInfo(
        priming.property, PipeWireAO.Pod(false);
        display_name = "Primed by live data", group = "Correction control",
        params = true, flags = PipeWireAO.SPA.PROPERTY_READONLY,
    )
    function status(props, available)
        result = loops(props, available)
        push!(result.values, priming.property => PipeWireAO.Pod(available && priming.ready[]))
        return result
    end
    return (;
        property_observer = loops,
        property_info = [CorrectionLoops.property_info(loops); info],
        property_getter = status,
        frame_observer = priming,
    )
end
