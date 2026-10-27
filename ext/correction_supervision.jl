const Supervision = PipeWireAORTC.CorrectionSupervision

function prepare_supervision(options, owner_instance, graph)
    conditions = get(options, :supervision, ())
    isempty(conditions) && return nothing
    options.capture_backend === nothing && options.execution == "complete-frame" ||
        throw(ArgumentError("supervision supports complete-frame CPU controller owners only"))
    formats = JuliaFilterGraph.output_formats(graph)
    names = map(condition -> condition.output, conditions)
    policies = NamedTuple{names}(map(conditions) do condition
        hasproperty(formats, condition.output) ||
            throw(ArgumentError("supervision output $(condition.output) is absent"))
        format = getproperty(formats, condition.output)
        return (; configuration=condition.configuration, tolerance=condition.tolerance,
            schema=condition.schema, shape=format.shape, layout=format.layout)
    end)
    return Supervision.Observer(formats, policies; owner_instance)
end

struct CorrectionStatus{L,S}
    loops::L
    supervision::S
end

function (status::CorrectionStatus)(properties::PipeWireAO.SPA.Props, available::Bool)
    loops = status.loops(properties, available)
    supervision = status.supervision(properties, available)
    return PipeWireAO.SPA.Props([loops.values; supervision.values])
end

correction_observation(::Nothing, ::Nothing) = (;)
correction_observation(observer, ::Nothing) = (; property_observer=observer,
    property_info=PipeWireAORTC.CorrectionLoops.property_info(observer), property_getter=observer)
function correction_observation(observer, supervision::Supervision.Observer)
    return (; property_observer=observer,
        property_info=[PipeWireAORTC.CorrectionLoops.property_info(observer);
            Supervision.property_info(supervision)],
        property_getter=CorrectionStatus(observer, supervision), frame_observer=supervision)
end
