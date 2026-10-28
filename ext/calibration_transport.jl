import PipeWireAO as PW
import FilterGraphAlgorithms

struct CalibrationGraphWorker
    task::Task
    node::Base.RefValue{Any}
    error::Base.RefValue{Any}
    ready::Threads.Atomic{Bool}
    stop_requested::Threads.Atomic{Bool}
end

"Run the prepared graph on one sticky owner task; the caller retains its graph."
function start_calibration_graph(descriptor, remote, name, rate; notify)
    node = Ref{Any}(nothing)
    failure = Ref{Any}(nothing)
    ready = Threads.Atomic{Bool}(false)
    stop_requested = Threads.Atomic{Bool}(false)
    task = Threads.@spawn begin
        current_task().sticky = true
        owned = nothing
        try
            stop_requested[] && return nothing
            owned = FilterGraphPipeWire.PipeWireNode(descriptor.graph;
                remote, name, rate, connect=false,
                # Every requested calibration sample must reach the graph.
                # Latest-input admission can discard it under output starvation.
                fifo_inputs=true,
                boundary_layout=FilterGraphAlgorithms.RowMajorLayout())
            stop_requested[] && return nothing
            FilterGraphPipeWire.prepare!(owned; execution=:complete_frame,
                required_outputs=Tuple(keys(JuliaFilterGraph.output_formats(descriptor.graph))))
            stop_requested[] && return nothing
            FilterGraphPipeWire.connect!(owned)
            stop_requested[] && return nothing
            node[] = owned
            ready[] = true
            notify()
            stop_requested[] && return nothing
            FilterGraphPipeWire.run!(owned)
        catch error
            failure[] = error
        finally
            try
                owned === nothing || close(owned)
            catch error
                failure[] = failure[] === nothing ? error : CompositeException([failure[], error])
            end
            ready[] = false
            notify()
        end
    end
    # Task completion, rather than its finally block, publishes the error Ref
    # and wakes deadline-bound teardown after istaskdone becomes observable.
    @async begin
        try
            wait(task)
        finally
            notify()
        end
    end
    return CalibrationGraphWorker(task, node, failure, ready, stop_requested)
end

"Request cross-thread shutdown; await worker.task before closing descriptor.graph."
function quit_calibration_graph!(worker::CalibrationGraphWorker)
    worker.stop_requested[] = true
    worker.ready[] || return nothing
    # The public cross-thread quit queues a native loop invocation, including
    # the short interval between publication and entry to run!. Cold preparation
    # instead observes the retained request before connecting/running.
    try
        FilterGraphPipeWire.quit!(worker.node[])
    catch error
        already_closed = error isa InvalidStateException && error.state === :closed
        worker.ready[] && !already_closed && rethrow()
    end
    return nothing
end

mutable struct CalibrationProbe{L,F}
    loop::L
    source::Union{Nothing,PW.Stream}
    feedback::Union{Nothing,PW.Stream}
    figure::Vector{Float32}
    values::Vector{Float32}
    sequence::UInt64
    published::UInt64
    received::UInt64
    drain_pending::Bool
    error::Any
    closed::Bool
    source_buffer::PW.StreamBuffer
    feedback_buffer::PW.StreamBuffer
    notify::F
end

function calibration_probe_failure!(probe, error)
    probe.error === nothing && (probe.error = error)
    probe.notify()
    return nothing
end

function publish_calibration_probe!(probe, stream)
    probe.error === nothing && !probe.closed || return nothing
    probe.sequence > probe.published || return nothing
    try
        PW.dequeue_buffer!(probe.source_buffer, stream) || return nothing
        queued = false
        try
            data = PW.buffer_data(probe.source_buffer)
            extent = sizeof(probe.figure)
            copyto!(reinterpret(Float32, PW.buffer_memory(data, extent)), probe.figure)
            PW.set_chunk!(data; size=extent, stride=sizeof(Float32))
            PW.set_buffer_header!(probe.source_buffer,
                PW.BufferHeader(0, 0, 0, 0, probe.sequence))
            PW.queue_buffer!(probe.source_buffer, stream)
            queued = true
            probe.published = probe.sequence
            probe.drain_pending = true
            probe.notify()
        finally
            queued || PW.return_buffer!(probe.source_buffer, stream)
        end
    catch error
        calibration_probe_failure!(probe, error)
    end
    return nothing
end

# A source process queues its buffer for the following native graph cycle.
# Flush that single publication after trigger_done; do not republish or spin
# until feedback, and do not use a clock tick as adoption evidence.
function drain_calibration_probe!(probe, stream)
    (probe.closed || probe.error !== nothing || !probe.drain_pending) && return nothing
    try
        probe.drain_pending = false
        PW.trigger_process!(stream)
    catch error
        calibration_probe_failure!(probe, error)
    end
    return nothing
end

function receive_calibration_feedback!(probe, stream)
    probe.error === nothing && !probe.closed || return nothing
    try
        PW.dequeue_buffer!(probe.feedback_buffer, stream) || return nothing
        try
            header = PW.buffer_header(probe.feedback_buffer)
            header === nothing && throw(ArgumentError("calibration feedback has no Header"))
            header.flags == 0 && header.offset == 0 ||
                throw(ArgumentError("calibration feedback has invalid Header flags/offset"))
            probe.sequence > 0 && probe.published == probe.sequence && probe.received != probe.sequence &&
                header.sequence == probe.sequence ||
                throw(ArgumentError("calibration feedback is duplicate, unarmed or unrelated"))
            data = PW.buffer_data(probe.feedback_buffer)
            chunk = PW.chunk_info(data)
            chunk.offset == 0 && chunk.size == sizeof(probe.values) &&
                chunk.stride in (0, sizeof(Float32), sizeof(probe.values)) && chunk.flags == 0 ||
                throw(ArgumentError("calibration feedback has an invalid packed extent"))
            values = reinterpret(Float32, PW.buffer_memory(data, sizeof(probe.values)))
            all(isfinite, values) || throw(ArgumentError("calibration feedback is nonfinite"))
            copyto!(probe.values, values)
            probe.received = header.sequence
        finally
            PW.queue_buffer!(probe.feedback_buffer, stream)
        end
        probe.notify()
    catch error
        calibration_probe_failure!(probe, error)
    end
    return nothing
end

function calibration_probe_format(format, rate)
    format.element_type in (Float32, PW.NdArray.F32_LE) && length(format.shape) == 1 ||
        throw(ArgumentError("calibration probe/feedback must be a Float32 vector"))
    fraction = rate isa PW.SPA.Fraction ? rate :
        rate isa Rational ? PW.SPA.Fraction(numerator(rate), denominator(rate)) :
        PW.SPA.Fraction(rate...)
    fraction.num > 0 && fraction.denom > 0 || throw(ArgumentError("calibration rate must be positive"))
    return PW.NdArrayFormat(PW.NdArray.F32_LE, format.shape;
        rate=fraction, layout=PW.NdArray.ROW_MAJOR)
end

function calibration_probe_parameters(format, schema)
    return (PW.ndarray_format(format; schema),
        PW.Pod(PW.buffers_param(size=PW.payload_size(format), buffers=2)),
        PW.Pod(PW.header_metadata_param()))
end

function calibration_probe_state!(probe, old, current, message)
    probe.closed && return nothing
    if current == PW.LibPipeWire.PW_STREAM_STATE_ERROR ||
            (current == PW.LibPipeWire.PW_STREAM_STATE_UNCONNECTED && old != current)
        calibration_probe_failure!(probe, ErrorException("calibration probe stream disconnected: $message"))
    else
        probe.notify()
    end
    return nothing
end

"Prepare inactive requested-command/constraint-feedback Streams on the held-HIL core."
function prepare_calibration_probe(core, format, schema, feedback_format, feedback_schema, rate; notify)
    requested = calibration_probe_format(format, rate)
    feedback = calibration_probe_format(feedback_format, rate)
    requested.shape == feedback.shape || throw(DimensionMismatch("probe and feedback extents differ"))
    loop = PW.main_loop(core)
    probe = CalibrationProbe(loop, nothing, nothing, zeros(Float32, requested.shape...),
        zeros(Float32, feedback.shape...), UInt64(0), UInt64(0), UInt64(0), false, nothing, false,
        PW.StreamBuffer(), PW.StreamBuffer(), notify)
    try
        PW.with_thread_loop_lock(loop) do _
            probe.source = PW.Stream(core, "calibration-requested";
                properties=Dict("node.name"=>"calibration-requested", "node.want-driver"=>"true",
                    "priority.driver"=>"100", "node.reliable"=>"true"),
                on_state_changed=(stream, old, current, message) -> calibration_probe_state!(probe, old, current, message),
                on_process=stream -> publish_calibration_probe!(probe, stream),
                on_trigger_done=stream -> drain_calibration_probe!(probe, stream))
            probe.feedback = PW.Stream(core, "calibration-constraint-feedback";
                properties=Dict("node.name"=>"calibration-constraint-feedback", "node.reliable"=>"true"),
                on_state_changed=(stream, old, current, message) -> calibration_probe_state!(probe, old, current, message),
                on_process=stream -> receive_calibration_feedback!(probe, stream))
            flags = PW.STREAM_MAP_BUFFERS | PW.STREAM_INACTIVE | PW.STREAM_DONT_RECONNECT | PW.STREAM_NO_CONVERT
            PW.connect!(probe.source, :output; flags=flags | PW.STREAM_DRIVER,
                params=calibration_probe_parameters(requested, schema))
            PW.connect!(probe.feedback, :input; flags,
                params=calibration_probe_parameters(feedback, feedback_schema))
        end
        return probe
    catch
        close(probe)
        rethrow()
    end
end

"Stage one immutable command slot; feedback must finish before the slot is reused."
function stage!(probe::CalibrationProbe, sequence::UInt64, figure::AbstractVector)
    PW.with_thread_loop_lock(probe.loop) do _
        probe.closed && throw(InvalidStateException("calibration probe is closed", :closed))
        probe.error === nothing || throw(probe.error)
        sequence > probe.sequence || throw(ArgumentError("probe sequence must strictly advance"))
        probe.received == probe.sequence || throw(InvalidStateException("probe feedback is pending", :busy))
        length(figure) == length(probe.figure) || throw(DimensionMismatch("probe figure extent differs"))
        # Validate the complete command before changing the owned slot/token.
        all(value -> value isa Real && !(value isa Bool) && isfinite(value) &&
            isfinite(Float32(value)), figure) || throw(ArgumentError("probe figure must be finite Float32 values"))
        copyto!(probe.figure, figure)
        probe.sequence = sequence
        try
            PW.trigger_process!(something(probe.source))
        catch error
            calibration_probe_failure!(probe, error)
            rethrow()
        end
    end
    return nothing
end

"Read owned feedback under the same loop lock as callbacks; errors are sticky."
function calibration_probe_snapshot(probe::CalibrationProbe)
    return PW.with_thread_loop_lock(probe.loop) do _
        (; sequence=probe.sequence, published=probe.published, received=probe.received,
            values=copy(probe.values), error=probe.error, closed=probe.closed)
    end
end

function Base.close(probe::CalibrationProbe)
    PW.with_thread_loop_lock(probe.loop) do _
        probe.closed && return nothing
        probe.closed = true
        try
            probe.feedback === nothing || close(probe.feedback)
        finally
            probe.source === nothing || close(probe.source)
        end
    end
    probe.notify()
    return nothing
end
