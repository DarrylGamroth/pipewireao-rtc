# The provider owns the external detector and the uncontrolled sink.
using PipeWireAO

function capture_source(core, name, format, schema, pending)
    values = Float32[1, 2]
    bytes = payload_size(format)
    buffer = StreamBuffer()
    # The queue reserves capacity plus two buffers.
    buffers = (Pod(buffers_param(; buffers = 3, size = bytes)), Pod(header_metadata_param()))
    source = Stream(core, name;
        properties = Dict("node.name" => name, "node.want-driver" => "true"),
        on_param_changed = (stream, id, param) -> begin
            id == SPA.PARAM_FORMAT && param !== nothing && update_params!(stream, buffers)
            return nothing
        end,
        on_process = stream -> begin
            pending[] && dequeue_buffer!(buffer, stream) || return nothing
            data = buffer_data(buffer)
            copyto!(reinterpret(Float32, buffer_memory(data, bytes)), values)
            set_chunk!(data; offset = 0, size = bytes, stride = sizeof(Float32))
            set_buffer_size!(buffer, length(values))
            set_buffer_header!(buffer, BufferHeader(0, 0, Int64(time_ns()), 0, 1))
            queue_buffer!(buffer, stream)
            pending[] = false
            return nothing
        end,
    )
    connect!(source, :output; flags = STREAM_MAP_BUFFERS | STREAM_DRIVER | STREAM_NO_CONVERT,
        params = (ndarray_format(format; schema), buffers...))
    return source
end

function publish_endpoints(socket, source_name, sink_name, schema, publish_request = nothing)
    format = NdArrayFormat(NdArray.F32_LE, (2,); layout = NdArray.ROW_MAJOR)
    loop = ThreadLoop("portable-detector")
    context = core = source = sink = nothing
    pending = Threads.Atomic{Bool}(false)
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties = Dict("remote.name" => socket))
            source = if publish_request === nothing
                NdArraySource(core, source_name, zeros(Float32, 2), format; schema)
            else
                capture_source(core, source_name, format, schema, pending)
            end
            sink = NdArraySink(core, sink_name, zeros(Float32, 2), format; schema)
        end
        start!(loop)
        start!(sink)
        if publish_request === nothing
            start!(source)
        else
            timedwait(() -> isfile(publish_request), 300) == :ok ||
                error("no publication request from the Quit fixture")
            with_thread_loop_lock(loop) do _
                pending[] = true
                trigger_process!(source)
            end
            timedwait(() -> !pending[], 5) == :ok || error("capture source did not publish")
        end
        wait(Base.Event())
    finally
        with_thread_loop_lock(loop) do _
            for resource in (sink, source, core, context)
                resource === nothing || close(resource)
            end
        end
        close(loop)
    end
end

publish_endpoints(ARGS...)
