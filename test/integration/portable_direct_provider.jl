# The provider owns the external detector and the uncontrolled sink.
using PipeWireAO

function publish_endpoints(socket, source_name, sink_name, schema)
    format = NdArrayFormat(NdArray.F32_LE, (2,); layout = NdArray.ROW_MAJOR)
    loop = ThreadLoop("portable-detector")
    context = core = source = sink = nothing
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties = Dict("remote.name" => socket))
            source = NdArraySource(core, source_name, zeros(Float32, 2), format; schema)
            sink = NdArraySink(core, sink_name, zeros(Float32, 2), format; schema)
        end
        start!(loop)
        start!(source)
        start!(sink)
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
