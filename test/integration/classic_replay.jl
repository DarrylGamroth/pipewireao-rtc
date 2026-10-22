"Transport-independent Classic controller oracle shared by opt-in integrations."
module ClassicReplay
using Test, PipeWireAORTC, FilterGraphIsland, JuliaFilterGraph

const FEEDBACK_IN = Symbol("constraint-feedback")
const FEEDBACK_OUT = Symbol("controller-constraint-feedback")
const SCALE = Float32(1e-6)

function prepare_controller(application)
    options = FilterGraphIsland.parse_arguments([
        "--graph", joinpath(application, "graph.conf"), "--check",
        "--execution", "complete-frame"])
    entries = PipeWireAORTC.GraphOwner.bindings(joinpath(application, "parameters.conf"))
    return FilterGraphIsland.prepare_service_graph(options;
        initial_parameters=formats -> PipeWireAORTC.GraphOwner.prepare_bindings(entries, formats))
end

function load_frame!(raw, frames, index)
    for row in axes(raw,1), column in axes(raw,2)
        raw[row,column] = frames[(row-1)*size(raw,2)+column,index]
    end
end

function replay(application, frames, adopted)
    graph = prepare_controller(application)
    try
        raw = zeros(UInt16,352,352)
        feedback = zeros(Float32,getproperty(graph.input_formats,FEEDBACK_IN).shape)
        inputs = NamedTuple{(:raw,FEEDBACK_IN)}((raw,feedback))
        outputs = map(format -> zeros(format.element_type,format.shape),graph.output_formats)
        load_frame!(raw,frames,1)
        JuliaFilterGraph.process!(outputs,graph,inputs)
        JuliaFilterGraph.reset!(graph)
        fill!(feedback,0)
        predicted = similar(adopted)
        for index in axes(frames,2)
            load_frame!(raw,frames,index)
            result = JuliaFilterGraph.process!(outputs,graph,inputs)
            @test all(values(result))
            @test all(isfinite,outputs.demanded)
            for actuator in axes(predicted,1)
                predicted[actuator,index] = outputs.demanded[actuator]*SCALE
            end
            copyto!(feedback,getproperty(outputs,FEEDBACK_OUT))
        end
        @test predicted == adopted
        return predicted
    finally
        FilterGraphIsland.close_execution(graph)
    end
end
end
