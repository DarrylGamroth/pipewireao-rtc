using FilterGraphAlgorithms
using FilterGraphPipeWire
using JuliaFilterGraph
using PipeWireAO

length(ARGS) in (3, 4, 5) || error(
    "expected CORE_NAME GRAPH_CONFIGURATION STOP_FILE [NODE_NAME] [EXPECTED_DISCONNECT_FILE]",
)
core_name, graph_configuration, stop_file = ARGS[1:3]
node_name = length(ARGS) >= 4 ? ARGS[4] : "pipewireao-rtc-revolt-controller"
expected_disconnect = length(ARGS) == 5 ? ARGS[5] : nothing

graph = JuliaFilterGraph.prepare_graph(
    graph_configuration;
    algorithms=FilterGraphAlgorithms.algorithms(),
)
node = FilterGraphPipeWire.PipeWireNode(
    graph;
    name=node_name,
    remote=core_name,
    rate=(500, 1),
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
            Base.Libc.systemsleep(0.1)
            println("REVOLT_JULIA_GRAPH_READY state=$state")
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
catch error
    # RTC unload removes its owned parameter source. An external graph can
    # report EPIPE as that link disappears. Accept it only after the RTC has
    # completed unload; callback errors are raised before run! reports EPIPE.
    if isnothing(expected_disconnect) ||
       !(error isa PipeWireAO.PipeWireError &&
         error.operation === :pw_ndarray_filter_run &&
         error.code == -Base.Libc.EPIPE)
        rethrow()
    end
    finished[] = true
    deadline = time_ns() + 5_000_000_000
    while !isfile(expected_disconnect) && time_ns() < deadline
        Base.Libc.systemsleep(0.01)
    end
    isfile(expected_disconnect) || rethrow()
    println("REVOLT_JULIA_GRAPH_EXPECTED_DISCONNECT")
    flush(stdout)
finally
    finished[] = true
    wait(monitor)
    close(node)
end
