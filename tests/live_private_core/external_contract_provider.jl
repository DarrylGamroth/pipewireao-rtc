using PipeWireAO

length(ARGS) == 2 || error("expected CORE_NAME CONTROL_DIRECTORY")
core_name, control_directory = ARGS
stop_file = joinpath(control_directory, "stop-external-hil")
close_source_request = joinpath(control_directory, "close-external-hil-source")
close_sink_request = joinpath(control_directory, "close-external-hil-sink")
mutate_source_request = joinpath(control_directory, "mutate-external-hil-source")
mutate_sink_request = joinpath(control_directory, "mutate-external-hil-sink")

rate = SPA.Fraction(1_000, 1)
function stream_parameters(shape, schema)
    format = NdArrayFormat(
        NdArray.F32_LE,
        shape;
        layout=NdArray.ROW_MAJOR,
        rate,
    )
    return Pod[
        ndarray_format(format; schema),
        Pod(buffers_param(size=payload_size(format), buffers=2)),
        Pod(header_metadata_param()),
        Pod(acquisition_metadata_param()),
    ]
end

function stream_properties(name; driver=false)
    properties = Dict(
        "node.name" => name,
        "media.type" => "Application",
        "media.category" => "Filter",
        "media.role" => "DSP",
        "node.description" => name,
    )
    if driver
        properties["node.want-driver"] = "true"
        properties["priority.driver"] = "30000"
    end
    return properties
end

loop = ThreadLoop("pipewireao-rtc external contract fixture")
context = Context(loop)
core = CoreConnection(context; properties=Dict("remote.name" => core_name))
source = Stream(
    core,
    "pipewireao-rtc-external-source";
    properties=stream_properties("pipewireao-rtc-external-source"; driver=true),
)
sink = Stream(
    core,
    "pipewireao-rtc-external-sink";
    properties=stream_properties("pipewireao-rtc-external-sink"),
)

try
    flags = STREAM_MAP_BUFFERS | STREAM_INACTIVE | STREAM_DONT_RECONNECT
    connect!(
        source,
        :output;
        flags=flags | STREAM_DRIVER,
        params=stream_parameters((2,), "org.calculon.ao.docrime-excitation/1"),
    )
    connect!(
        sink,
        :input;
        flags,
        params=stream_parameters((2,), "org.calculon.ao.controller-command/1"),
    )
    start!(loop)
    with_thread_loop_lock(loop) do _
        set_active!(sink, true)
        set_active!(source, true)
    end
    while with_thread_loop_lock(loop) do _
        node_id(source) == typemax(UInt32) || node_id(sink) == typemax(UInt32)
    end
        sleep(0.001)
    end
    println("EXTERNAL_HIL_READY")
    flush(stdout)

    fault_applied = false
    while !isfile(stop_file)
        if !fault_applied && isfile(close_source_request)
            with_thread_loop_lock(loop) do _
                close(source)
            end
            println("EXTERNAL_HIL_SOURCE_CLOSED")
            flush(stdout)
            fault_applied = true
        elseif !fault_applied && isfile(close_sink_request)
            with_thread_loop_lock(loop) do _
                close(sink)
            end
            println("EXTERNAL_HIL_SINK_CLOSED")
            flush(stdout)
            fault_applied = true
        elseif !fault_applied &&
               (isfile(mutate_source_request) || isfile(mutate_sink_request))
            stream = isfile(mutate_source_request) ? source : sink
            with_thread_loop_lock(loop) do _
                update_params!(
                    stream,
                    [ndarray_format(
                        NdArrayFormat(
                            NdArray.F32_LE,
                            (3,);
                            layout=NdArray.ROW_MAJOR,
                            rate,
                        );
                        schema="org.pipewireao.rtc.incompatible/1",
                    )],
                )
            end
            println(
                isfile(mutate_source_request) ?
                "EXTERNAL_HIL_SOURCE_MUTATED" : "EXTERNAL_HIL_SINK_MUTATED",
            )
            flush(stdout)
            fault_applied = true
        end
        sleep(0.01)
    end
finally
    try
        with_thread_loop_lock(loop) do _
            close(source)
            close(sink)
            close(core)
            close(context)
        end
    finally
        stop!(loop)
        close(loop)
    end
end
