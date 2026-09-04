using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO

length(ARGS) == 2 || error("expected CORE_NAME CONTROL_DIRECTORY")
core_name, control_directory = ARGS
phase_1_request = joinpath(control_directory, "external-hil-phase-1")
phase_2_request = joinpath(control_directory, "external-hil-phase-2")
stop_file = joinpath(control_directory, "stop-external-hil")

command = Float32[1, -1]
plant = discrete_integrator_node(
    :plant;
    extent=2,
    sample_period_s=0.001,
    input_schema="org.calculon.ao.controller-command/1",
    output_schema="org.calculon.ao.docrime-excitation/1",
    gain=1.0,
    tau_s=0.001,
)
graph = prepare_algorithm_graph(algorithm_graph(
    (plant,);
    inputs=(graph_input(:command, :plant => :input, command),),
    outputs=(graph_output(:frame, :plant => :output),),
))
boundary = prepare_graph_hil_boundary(
    graph;
    command_input=:command,
    frame_output=:frame,
)
configuration = PipeWireHILConfiguration(
    remote=core_name,
    frame_node_name="pipewireao-rtc-external-source",
    command_node_name="pipewireao-rtc-external-sink",
    frame_schema="org.calculon.ao.docrime-excitation/1",
    command_schema="org.calculon.ao.controller-command/1",
    rate=SPA.Fraction(1_000, 1),
    exposure_duration_ns=1_000_000,
)

prepared = prepare_pipewire_hil(boundary, configuration)
try
    start!(prepared)
    println("EXTERNAL_HIL_READY")
    flush(stdout)
    completed_phase_1 = false
    completed_phase_2 = false
    while !isfile(stop_file)
        if !completed_phase_1 && isfile(phase_1_request)
            for expected_sequence in UInt64(1):UInt64(3)
                sequence = exchange_frame!(prepared)
                sequence == expected_sequence || error(
                    "phase 1 expected sequence $expected_sequence, received $sequence",
                )
                all(isfinite, hil_frame_buffer(boundary)) || error(
                    "phase 1 produced a non-finite WFS frame",
                )
                all(isfinite, hil_command_buffer(boundary)) || error(
                    "phase 1 received a non-finite correction command",
                )
            end
            println("EXTERNAL_HIL_PHASE_1_DONE sequence=3")
            flush(stdout)
            completed_phase_1 = true
        elseif completed_phase_1 && !completed_phase_2 && isfile(phase_2_request)
            for expected_sequence in UInt64(4):UInt64(6)
                sequence = exchange_frame!(prepared)
                sequence == expected_sequence || error(
                    "phase 2 expected sequence $expected_sequence, received $sequence",
                )
                all(isfinite, hil_frame_buffer(boundary)) || error(
                    "phase 2 produced a non-finite WFS frame",
                )
                all(isfinite, hil_command_buffer(boundary)) || error(
                    "phase 2 received a non-finite correction command",
                )
            end
            println("EXTERNAL_HIL_PHASE_2_DONE sequence=6")
            flush(stdout)
            completed_phase_2 = true
        end
        sleep(0.01)
    end
finally
    close(prepared)
end
