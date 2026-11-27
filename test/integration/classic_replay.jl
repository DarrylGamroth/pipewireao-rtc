"Transport-independent Classic controller oracle shared by opt-in integrations."
module ClassicReplay
using Test, PipeWireAORTC, FilterGraphPipeWire, FilterGraphs

const FEEDBACK_IN = Symbol("constraint-feedback")
const FEEDBACK_OUT = Symbol("controller-constraint-feedback")
const SCALE = Float32(1e-6)

function prepare_controller(application)
    deployment = PipeWireAORTC.Common.read_json(joinpath(application, "deployment.conf"))
    owner = only(owner for owner in deployment["owners"] if "--fits-bindings" in owner["argv"])
    function asset(option)
        path = owner["argv"][only(findall(==(option), owner["argv"])) + 1]
        return PipeWireAORTC.DeploymentConfiguration.relative_asset(
            application, String(chopprefix(path, "@PACKAGE@/")),
        )
    end
    options = FilterGraphPipeWire.parse_arguments([
        "--graph",
        asset("--graph"),
        "--check",
        "--execution",
        "complete-frame",
    ])
    entries = PipeWireAORTC.GraphOwner.bindings(asset("--fits-bindings"))
    graph = FilterGraphPipeWire.prepare_service_graph(
        options.graph;
        initial_parameters = formats ->
            PipeWireAORTC.GraphOwner.prepare_bindings(entries, formats),
    )
    try
        # This private replay compares the correction on captured and oracle frames.
        FilterGraphs.replace_properties!(graph, "closed-loop-correction:closed" => true)
    catch
        FilterGraphPipeWire.close_execution(graph)
        rethrow()
    end
    return graph
end

function load_frame!(raw, frames, index)
    for row in axes(raw, 1), column in axes(raw, 2)
        raw[row, column] = frames[(row-1)*size(raw, 2)+column, index]
    end
end

function replay(application, frames, adopted)
    graph = prepare_controller(application)
    try
        raw = zeros(UInt16, 352, 352)
        feedback = zeros(Float32, getproperty(graph.input_formats, FEEDBACK_IN).shape)
        inputs = NamedTuple{(:raw, FEEDBACK_IN)}((raw, feedback))
        outputs = map(
            format -> zeros(format.element_type, format.shape), graph.output_formats
        )
        load_frame!(raw, frames, 1)
        FilterGraphs.process!(outputs, graph, inputs)
        FilterGraphs.reset!(graph)
        fill!(feedback, 0)
        predicted = similar(adopted)
        for index in axes(frames, 2)
            load_frame!(raw, frames, index)
            result = FilterGraphs.process!(outputs, graph, inputs)
            @test all(values(result))
            @test all(isfinite, outputs.demanded)
            for actuator in axes(predicted, 1)
                predicted[actuator, index] = outputs.demanded[actuator] * SCALE
            end
            copyto!(feedback, getproperty(outputs, FEEDBACK_OUT))
        end
        @test predicted == adopted
        return predicted
    finally
        FilterGraphPipeWire.close_execution(graph)
    end
end
end
