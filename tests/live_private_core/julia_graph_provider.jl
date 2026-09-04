using FilterGraphAlgorithms
using FilterGraphPipeWire
using JuliaFilterGraph
using PipeWireAO

length(ARGS) == 3 || error("expected CORE_NAME GRAPH_CONFIGURATION STOP_FILE")
core_name, graph_configuration, stop_file = ARGS

graph = JuliaFilterGraph.prepare_graph(
    graph_configuration;
    algorithms=FilterGraphAlgorithms.algorithms(),
)
node = FilterGraphPipeWire.PipeWireNode(
    graph;
    name="pipewireao-rtc-external-graph",
    remote=core_name,
    rate=(1_000, 1),
    boundary_layout=FilterGraphAlgorithms.RowMajorLayout(),
    run_control=true,
)

finished = Threads.Atomic{Bool}(false)
monitor = Threads.@spawn begin
    while !finished[] && !isfile(stop_file)
        state = FilterGraphPipeWire.node_state(node)
        if PipeWireAO.isrunning(node) &&
           (state == PipeWireAO.NDARRAY_FILTER_STATE_PAUSED ||
            state == PipeWireAO.NDARRAY_FILTER_STATE_STREAMING)
            println("JULIA_GRAPH_READY state=$state")
            flush(stdout)
            break
        end
        Base.Libc.systemsleep(0.001)
    end
    while !finished[] && !isfile(stop_file)
        Base.Libc.systemsleep(0.01)
    end
    finished[] || FilterGraphPipeWire.quit!(node)
    nothing
end

try
    FilterGraphPipeWire.run!(node)
finally
    finished[] = true
    wait(monitor)
    close(node)
end
