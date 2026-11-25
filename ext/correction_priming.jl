const CorrectionLoops = PipeWireAORTC.CorrectionLoops

struct CorrectionPriming{Port,Camera,Validity,Pyramid,Controller,Sensor}
    controller::Controller
    sensor::Sensor
    property::String
    ready::Threads.Atomic{Bool}
end

function prepare_priming(options, graph)
    selected = get(options, :prime_on_output, nothing)
    selected === nothing && return nothing
    options.session_run_control && options.capture_backend === nothing &&
        options.execution == "complete-frame" &&
        graph isa Union{FilterGraphs.PreparedGraph,FilterGraphs.PreparedComposition} ||
        throw(ArgumentError("correction priming requires a session-controlled complete-frame CPU graph"))
    rules = selected isa Symbol ? (only(options.correction_properties) => selected,) : selected
    return map(rules) do (property, output)
        prepare_priming(graph, options, property, output)
    end
end

prepare_priming(graph, options, property, output::Symbol) =
    prepare_priming(graph, options, property, (output, nothing))

function prepare_priming(graph, options, property, ports::Tuple)
    output, validity = ports
    formats = FilterGraphs.output_formats(graph)
    output_format = priming_format(options, formats, output)
    output_format.element_type <: AbstractFloat ||
        throw(ArgumentError("correction priming requires a floating-point graph output"))
    validity_format = validity === nothing ? nothing : priming_format(options, formats, validity)
    if validity_format !== nothing && validity_format.element_type !== Bool
        throw(ArgumentError("correction priming validity requires a Boolean graph output"))
    end
    checked = graph isa FilterGraphs.PreparedComposition ? graph.graph : graph
    name = Symbol(first(split(property, ':'; limit = 2)))
    index = findfirst(node -> node.name === name, checked.nodes)
    index === nothing && throw(ArgumentError("correction priming controller '$name' is absent"))
    controller = checked.nodes[index].prepared
    get(FilterGraphAlgorithms.property_values(controller.plan), :closed, nothing) === false ||
        throw(ArgumentError("correction priming requires an initially open correction loop"))
    camera = priming_camera(graph, output, index)
    if validity !== nothing && priming_camera(graph, validity, index) !== camera
        throw(ArgumentError("correction priming validity must come from the selected camera"))
    end
    sensor = if validity_format !== nothing &&
            validity_format.schema == FilterGraphAlgorithms.SHACK_HARTMANN_VALIDITY_V1
        route = checked.output_routes[findfirst(==(validity), keys(checked.output_formats))]
        shack_hartmann_sensor(checked, route, validity_format)
    else
        nothing
    end
    pyramid = output_format.schema == FilterGraphAlgorithms.PYRAMID_RECONSTRUCTION_PIXELS_V1
    return CorrectionPriming{output,camera,validity,pyramid,typeof(controller),typeof(sensor)}(
        controller, sensor, CorrectionLoops.STATUS_PREFIX * property * ".primed", Threads.Atomic{Bool}(false),
    )
end

function shack_hartmann_sensor(graph, route, format)
    throw(ArgumentError("Shack–Hartmann priming validity must come from the sensing algorithm"))
end
function shack_hartmann_sensor(graph, ::FilterGraphs.NodeOutput{Node}, format) where {Node}
    sensor = graph.nodes[Node].prepared
    plan = sensor.plan
    plan isa FilterGraphAlgorithms.ShackHartmannImagePlan && size(plan.active) == format.shape &&
        any(plan.active) || throw(ArgumentError("Shack–Hartmann priming requires an active lenslet mask"))
    return sensor
end

function priming_format(options, formats, output)
    local_output = get(options, :local_output, nothing)
    feedback = get(options, :feedback, nothing)
    ((local_output !== nothing && local_output.port === output) ||
     (feedback !== nothing && last(feedback) === output)) &&
        throw(ArgumentError("the correction priming output must be published by the graph owner"))
    format = get(formats, output, nothing)
    format === nothing && throw(ArgumentError("correction priming output '$output' is absent"))
    return format
end

function priming_camera(graph::FilterGraphs.PreparedGraph, output, index)
    output_index = findfirst(==(output), keys(FilterGraphs.output_formats(graph)))
    source = FilterGraphs.output_metadata_source_inputs(graph)[output_index]
    source != 0 || throw(ArgumentError("correction priming requires an acquisition-sourced graph output"))
    return keys(FilterGraphs.input_formats(graph))[source]
end
function priming_camera(graph::FilterGraphs.PreparedComposition, output, index)
    output_index = findfirst(==(output), keys(FilterGraphs.output_formats(graph)))
    source = FilterGraphs.output_metadata_source_inputs(graph)[output_index]
    branch = findfirst(candidate -> candidate.controller_index == index, graph.branches)
    source != 0 && branch !== nothing ||
        throw(ArgumentError("correction priming output must belong to its controller's camera branch"))
    camera = keys(FilterGraphs.input_formats(graph))[source]
    graph.branches[branch].camera === camera ||
        throw(ArgumentError("correction priming output must belong to its controller's camera branch"))
    return camera
end

function (observer::CorrectionPriming{Port,Camera,Validity,Pyramid})(::Val{:frame}, outputs,
                                                                    metadata) where {Port,Camera,Validity,Pyramid}
    receipt = getproperty(metadata, Port)
    identity = receipt.present && !receipt.value.corrupted ?
        FilterGraphAlgorithms.sample_acquisition_identity(receipt.value) : nothing
    duration = receipt.present ?
        FilterGraphAlgorithms.sample_exposure_duration_nanoseconds(receipt.value) : nothing
    # The graph's data thread adopts Plans before processing and owns this read.
    open = !FilterGraphAlgorithms.property_values(observer.controller.plan).closed
    observer.ready[] = open && identity !== nothing && identity.sequence > 0 &&
        duration !== nothing && duration > 0 && priming_measurement(getproperty(outputs, Port), Val(Pyramid)) &&
        priming_validity(observer.sensor, outputs, metadata, identity, Val(Validity))
    return nothing
end

priming_measurement(values, ::Val{false}) = all(isfinite, values)
function priming_measurement(values, ::Val{true})
    # Pyramid reconstruction pixels use the previous exposure's gain. A
    # positive sum needs both that positive gain and positive current pupil flux.
    total = 0.0
    for value in values
        isfinite(value) || return false
        total += Float64(value)
    end
    return total > 0
end

priming_validity(sensor, outputs, metadata, identity, ::Val{nothing}) = true
function priming_validity(sensor, outputs, metadata, identity, ::Val{Validity}) where {Validity}
    receipt = getproperty(metadata, Validity)
    return receipt.present && !receipt.value.corrupted &&
        FilterGraphAlgorithms.sample_acquisition_identity(receipt.value) === identity &&
        validity_accepted(sensor, getproperty(outputs, Validity))
end

validity_accepted(::Nothing, values) = all(values)
validity_accepted(sensor, values) = active_subaperture_valid(sensor.plan.active, values)

function active_subaperture_valid(active, validity)
    # The reconstructor already accepts invalid slopes as zeros. Require one
    # measured lenslet from the current calibrated active set.
    for index in eachindex(active, validity)
        active[index] && validity[index] && return true
    end
    return false
end

function (observer::CorrectionPriming{Port,Camera,Validity})(phase::Val{:frame}, outputs, metadata,
                                                             arrivals, availability) where {Port,Camera,Validity}
    getproperty(arrivals, Camera) || return nothing
    if getproperty(availability, Port) &&
        (Validity === nothing || getproperty(availability, Validity))
        observer(phase, outputs, metadata)
    else
        observer.ready[] = false
    end
    return nothing
end

function (observer::CorrectionPriming)(::Union{Val{:invalidated},Val{:reset}})
    observer.ready[] = false
    return nothing
end

correction_observation(loops, supervision, ::Nothing) = correction_observation(loops, supervision)
function correction_observation(loops, supervision,
                                priming::Tuple{CorrectionPriming,Vararg{CorrectionPriming}})
    observation = correction_observation(loops, supervision)
    info = map(priming) do observer
        PipeWireAO.SPA.PropInfo(
            observer.property, PipeWireAO.Pod(false);
            display_name = "Primed by live data", group = "Correction control",
            params = true, flags = PipeWireAO.SPA.PROPERTY_READONLY,
        )
    end
    function status(props, available)
        result = observation.property_getter(props, available)
        for observer in priming
            push!(result.values, observer.property => PipeWireAO.Pod(available && observer.ready[]))
        end
        return result
    end
    function observe(phase, args...)
        supervision === nothing || supervision(phase, args...)
        foreach(observer -> observer(phase, args...), priming)
        return nothing
    end
    return (;
        property_observer = loops,
        property_info = [observation.property_info; collect(info)],
        property_getter = status,
        frame_observer = observe,
    )
end
