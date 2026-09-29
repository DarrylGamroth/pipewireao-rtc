using FilterGraphAlgorithms
using FilterGraphPipeWire
using JuliaFilterGraph
using PipeWireAO

import FilterGraphAlgorithms: process!

@algorithm LatestHoldPrimaryPassF32 begin
    label = "rtc-latest-hold-primary-pass-f32"

    @configuration LatestHoldPrimaryPassF32Configuration begin
        extent::Int => graph_rebuild
    end

    ports(configuration) = (
        input(
            :primary,
            Float32,
            (configuration.extent,),
            "org.pipewireao.rtc.latest-hold.primary/1";
            rate=(1, 1),
        ),
        input(
            :held,
            Float32,
            (configuration.extent,),
            "org.pipewireao.rtc.latest-hold.slow/1";
            rate=(1, 1),
        ),
        output(
            :output,
            Float32,
            (configuration.extent,),
            "org.pipewireao.rtc.latest-hold.primary/1";
            metadata_from=:primary,
            rate=(1, 1),
        ),
    )

    prepare(configuration) = configuration.extent
    process!(plan) = begin
        @inbounds @simd for index in eachindex(output, primary, held)
            output[index] = primary[index]
        end
        nothing
    end
end

length(ARGS) == 4 || error("expected CORE_NAME GRAPH_CONFIGURATION STOP_FILE RATE")
core_name, graph_configuration, stop_file, rate_text = ARGS
rate = parse(Int, rate_text)
rate > 0 || error("RATE must be positive")

graph = JuliaFilterGraph.prepare_graph(
    graph_configuration;
    algorithms=(LatestHoldPrimaryPassF32,),
)
node = FilterGraphPipeWire.PipeWireNode(
    graph;
    name="pipewireao-rtc-latest-hold-graph",
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
            println("LATEST_HOLD_JULIA_GRAPH_READY state=$state")
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
