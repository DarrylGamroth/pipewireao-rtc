using PipeWireAO

length(ARGS) == 4 || error("expected CORE_NAME NODE_NAME HOLD_FILE RATE")
core_name, node_name, hold_file, rate_text = ARGS
rate = parse(Int, rate_text)
rate > 0 || error("RATE must be positive")

mutable struct ObservationProcess
    buffer::StreamBuffer
    held::Bool
end

function (process::ObservationProcess)(stream::Stream)
    process.held && return nothing
    dequeue_buffer!(process.buffer, stream) || return nothing
    payload = buffer_data(process.buffer)
    length(bytes(payload)) == 8 || error("observer expected one two-element F32 frame")
    values = collect(reinterpret(Float32, bytes(payload)))
    header = buffer_header(process.buffer)
    println("OBSERVER_BUFFER sequence=$(header.sequence) values=$(join(values, ','))")
    flush(stdout)
    if isfile(hold_file)
        process.held = true
    else
        queue_buffer!(process.buffer, stream)
    end
    return nothing
end

context = Context()
try
    core = CoreConnection(context; properties=Dict("remote.name" => core_name))
    try
        process = ObservationProcess(StreamBuffer(), false)
        stream = Stream(
            core,
            "RTC bounded observation client";
            properties=Dict(
                "node.name" => node_name,
                "media.type" => "Application",
                "media.category" => "Capture",
                "media.role" => "Analysis",
            ),
            on_process=process,
        )
        try
            format = ndarray_format(
                NdArrayFormat(
                    NdArray.F32_LE,
                    (2,);
                    layout=NdArray.ROW_MAJOR,
                    rate=SPA.Fraction(rate, 1),
                );
                schema="org.calculon.ao.docrime-excitation/1",
            )
            connect!(
                stream,
                :input;
                flags=STREAM_MAP_BUFFERS | STREAM_NO_CONVERT,
                params=[
                    format,
                    buffers_param(
                        buffers=3,
                        data_types=Int32(1 << SPA.DATA_MEM_FD),
                    ),
                    header_metadata_param(),
                ],
            )
            println("OBSERVER_READY")
            flush(stdout)
            run!(stream)
        finally
            close(stream)
        end
    finally
        close(core)
    end
finally
    close(context)
end
