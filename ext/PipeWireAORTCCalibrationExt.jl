module PipeWireAORTCCalibrationExt

import PipeWireAORTC
import FilterGraphIsland
import FilterGraphPipeWire
import JuliaFilterGraph
import AdaptiveOpticsSim
import AdaptiveOpticsSimPipeWireHIL
import AdaptiveOpticsCalibration

const Calibration = PipeWireAORTC.InstrumentCalibration
const GraphOwner = PipeWireAORTC.GraphOwner
const HIL = AdaptiveOpticsSim.AlgorithmGraphs

shack_hartmann_configuration(config) = nothing
shack_hartmann_configuration(config::HIL.ShackHartmannRateNodeConfig) = config
function Calibration.shack_hartmann_configuration(system)
    return only(filter(!isnothing,
        map(node -> shack_hartmann_configuration(node.config), system.definition.nodes)))
end

function Calibration.controller_graph(application; overrides=Dict())
    options = FilterGraphIsland.parse_arguments([
        "--graph", joinpath(application, "rtc", "graph.conf"), "--check", "--execution", "complete-frame"])
    entries = GraphOwner.bindings(joinpath(application, "rtc", "parameters.conf"))
    return FilterGraphIsland.prepare_service_graph(options; initial_parameters=formats ->
        [port => get(overrides, port, data) for (port, data) in
            GraphOwner.prepare_bindings(entries, formats)])
end

function Calibration.controller_storage(graph; raw_input=:raw, feedback_input=Symbol("constraint-feedback"))
    raw_name, feedback_name = Symbol(raw_input), Symbol(feedback_input)
    raw_format = getproperty(graph.input_formats, raw_name)
    raw = zeros(raw_format.element_type, raw_format.shape)
    feedback_format = getproperty(graph.input_formats, feedback_name)
    feedback = zeros(feedback_format.element_type, feedback_format.shape)
    inputs = NamedTuple{(raw_name, feedback_name)}((raw, feedback))
    outputs = map(format -> zeros(format.element_type, format.shape), graph.output_formats)
    return (; raw, feedback, inputs, outputs)
end

function Calibration.measure!(storage, graph, frame)
    storage.raw .= round.(eltype(storage.raw), frame)
    JuliaFilterGraph.reset!(graph)
    fill!(storage.feedback, 0)
    all(values(JuliaFilterGraph.process!(storage.outputs, graph, storage.inputs))) ||
        throw(ArgumentError("calibration estimator rejected a frame"))
    return storage.outputs
end

function Calibration.calibration_frame!(system, physical)
    boundary = system.boundary
    sequence = HIL.hil_boundary_status(boundary).frame_sequence
    if sequence == 0
        all(iszero, physical) || throw(ArgumentError("first calibration frame must be flat"))
    else
        copyto!(HIL.hil_command_buffer(boundary), physical)
        HIL.adopt_hil_command!(boundary, sequence)
    end
    HIL.step_hil_frame!(boundary)
    return HIL.hil_frame_buffer(boundary)
end

include("modal_calibration.jl")
include("modal_hidden_modes.jl")
include("modal_validation.jl")

end
