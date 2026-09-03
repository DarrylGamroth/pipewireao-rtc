using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO

length(ARGS) == 2 || error("expected CORE_NAME STOP_FILE")
core_name, stop_file = ARGS

command = zeros(Float32, 2)
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
    while !isfile(stop_file)
        sleep(0.01)
    end
finally
    close(prepared)
end
