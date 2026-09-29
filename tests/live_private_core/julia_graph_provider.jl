using FilterGraphAlgorithms
using FilterGraphPipeWire
using JuliaFilterGraph
using PipeWireAO

length(ARGS) == 4 || error("expected CORE_NAME GRAPH_CONFIGURATION STOP_FILE RATE")
core_name, graph_configuration, stop_file, rate_text = ARGS
rate = parse(Int, rate_text)
rate > 0 || error("RATE must be positive")

graph = JuliaFilterGraph.prepare_graph(
    graph_configuration;
    algorithms=FilterGraphAlgorithms.algorithms(),
)
node = FilterGraphPipeWire.PipeWireNode(
    graph;
    name="pipewireao-rtc-external-graph",
    remote=core_name,
    rate=(rate, 1),
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
catch error
    # The runner has already unloaded and removed its source link before this
    # marker is written. Preserve callback failures and every other run error.
    if !(error isa PipeWireAO.PipeWireError &&
         error.operation === :pw_ndarray_filter_run &&
         error.code == -Base.Libc.EPIPE)
        rethrow()
    end
    finished[] = true
    deadline = time_ns() + 5_000_000_000
    expected_disconnect = stop_file * ".rtc-unloaded"
    while !isfile(expected_disconnect) && time_ns() < deadline
        Base.Libc.systemsleep(0.01)
    end
    isfile(expected_disconnect) || rethrow()
    println("JULIA_GRAPH_EXPECTED_DISCONNECT")
    flush(stdout)
finally
    finished[] = true
    wait(monitor)
    close(node)
end
