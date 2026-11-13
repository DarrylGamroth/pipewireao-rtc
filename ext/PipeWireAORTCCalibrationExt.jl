module PipeWireAORTCCalibrationExt

import PipeWireAORTC
import PipeWireAORTC.InstrumentCalibration: calibration_endpoint, calibration_port
import FilterGraphPipeWire
import FilterGraphs
import AdaptiveOpticsSim
import AdaptiveOpticsSimPipeWireHIL
import Clocks
import FilterGraphAlgorithms as FGA
import LinearAlgebra as LA
import PipeWireAO as PW

include("calibration_worker.jl")
using .CalibrationWorkers:
    CalibrationGraphWorker,
    start_calibration_graph,
    quit_calibration_graph!,
    calibration_graph_status,
    finish_calibration_graph!,
    calibration_graph_released

const IC = PipeWireAORTC.InstrumentConfiguration
const Calibration = PipeWireAORTC.InstrumentCalibration
const GraphOwner = PipeWireAORTC.GraphOwner
const HIL = AdaptiveOpticsSim.AlgorithmGraphs

function Calibration.controller_graph(application; overrides = Dict())
    entries = GraphOwner.bindings(joinpath(application, "rtc", "parameters.conf"))
    return FilterGraphPipeWire.prepare_service_graph(
        joinpath(application, "rtc", "graph.conf");
        initial_parameters = formats -> [
            port => get(overrides, port, data) for
            (port, data) in GraphOwner.prepare_bindings(entries, formats)
        ],
    )
end

function Calibration.calibration_frame!(system, physical)
    boundary = system.boundary
    sequence = HIL.hil_boundary_status(boundary).frame_sequence
    if sequence == 0
        all(iszero, physical) ||
            throw(ArgumentError("first calibration frame must be flat"))
    else
        copyto!(HIL.hil_command_buffer(boundary), physical)
        HIL.adopt_hil_command!(boundary, sequence)
    end
    HIL.step_hil_frame!(boundary)
    return HIL.hil_frame_buffer(boundary)
end

include("calibration_graphs.jl")
function Calibration.calibration_frame!(system, commands::NamedTuple)
    boundary = system.boundary
    sequence = HIL.hil_boundary_status(boundary).frame_sequence
    if sequence == 0
        all(c -> all(iszero, c), commands) ||
            throw(ArgumentError("initial calibration frame must be flat"))
    else
        for name in keys(commands)
            copyto!(
                getproperty(HIL.hil_command_buffer(boundary), name),
                getproperty(commands, name),
            )
        end
        HIL.adopt_hil_command!(boundary, sequence)
    end
    HIL.step_hil_frame!(boundary)
    return HIL.hil_frame_buffer(boundary)
end

include("modal_completion.jl")
include("pupil_feedback.jl")
include("calibration_transport.jl")
include("calibration_capture.jl")
include("calibration_owner.jl")
include("calibration_settings.jl")

end
