struct ScalarSample
    value::Float32
    metadata::FilterGraphAlgorithms.SampleMetadata
end

# One slot belongs to the frame callback and one belongs to the display loop.
# Atomic exchange hands each endpoint the middle slot. The high bit marks an
# unread sample, which the writer can overwrite without waiting for the reader.
mutable struct LatestScalar
    const samples::Vector{Union{ScalarSample,Nothing}}
    writer::UInt8
    @atomic middle::UInt8
    reader::UInt8
    LatestScalar() = new(fill(nothing, 3), 0x01, 0x02, 0x03)
end

@inline function replace_latest!(latest::LatestScalar, sample)
    slot = latest.writer
    @inbounds latest.samples[slot] = sample
    latest.writer = (@atomicswap latest.middle = slot | 0x80) & 0x7f
    return nothing
end

@inline function advance_latest!(latest::LatestScalar)
    middle = @atomic latest.middle
    iszero(middle & 0x80) && return false
    latest.reader = (@atomicswap latest.middle = latest.reader) & 0x7f
    return true
end

@inline latest_sample(latest::LatestScalar) = @inbounds latest.samples[latest.reader]

@inline function (latest::LatestScalar)(::Val{:frame}, array, record)
    record.present || return nothing
    sample = record.value
    value = @inbounds array[1]
    if sample.has_acquisition_identity && !sample.corrupted && isfinite(value)
        replace_latest!(latest, ScalarSample(value, sample))
    end
    return nothing
end

(latest::LatestScalar)(::Val{:reset}) = replace_latest!(latest, nothing)

function prepare_latest_output(options, graph)
    output = get(options, :local_output, nothing)
    output === nothing && return nothing, nothing
    options.capture_backend === nothing && options.execution == "complete-frame" &&
        graph isa FilterGraphs.PreparedGraph || throw(
            ArgumentError("a local output requires an ordinary complete-frame CPU Graph"),
        )
    formats = FilterGraphs.output_formats(graph)
    haskey(formats, output.port) || throw(ArgumentError("unknown Graph output $(output.port)"))
    source_format = getproperty(formats, output.port)
    schema = source_format.schema
    source_format.element_type === Float32 && source_format.shape == (1,) &&
        schema isa String && !isempty(schema) || throw(
            ArgumentError("a local display output requires a schema and F32_LE[1]"),
        )
    output.node === nothing && return output.port => nothing, nothing
    output.node != options.name || throw(ArgumentError("display and Graph Nodes must have distinct names"))
    output.sink === nothing || output.sink.node ∉ (output.node, options.name) || throw(
        ArgumentError("the display sink must be a separate Node"),
    )
    layout = options.boundary_layout isa FilterGraphAlgorithms.RowMajorLayout ?
        PipeWireAO.NdArray.ROW_MAJOR : PipeWireAO.NdArray.COLUMN_MAJOR
    options.rate !== nothing || source_format.rate == (1, 1) || throw(
        ArgumentError("a display output with a non-unit rate requires a Graph base rate"),
    )
    projected_rate = options.rate === nothing ? nothing :
        options.rate * (Int(first(source_format.rate)) // Int(last(source_format.rate)))
    rate = projected_rate === nothing ? nothing :
        PipeWireAO.SPA.Fraction(numerator(projected_rate), denominator(projected_rate))
    format = PipeWireAO.NdArrayFormat(PipeWireAO.NdArray.F32_LE, (1,); layout, rate)
    latest = LatestScalar()
    return output.port => latest, (; latest, output.node, output.media, output.sink, format, schema)
end

# The stream state and its single loan are serialized on its own PipeWire loop.
mutable struct ScalarStream{F,P}
    const latest::LatestScalar
    const format::F
    const schema::String
    const params::P
    const buffer::PipeWireAO.StreamBuffer
    streaming::Bool
    pending::Bool
    route_ready::Bool
end

function ScalarStream(latest, format, schema)
    params = (
        PipeWireAO.Pod(PipeWireAO.buffers_param(;
            buffers = PipeWireAO.SPA.Choice(PipeWireAO.SPA.CHOICE_RANGE, Int32[2, 2, 64]),
            blocks = 1, size = sizeof(Float32),
            metadata_types = Int32(1 << PipeWireAO.SPA.META_HEADER),
        )),
        PipeWireAO.Pod(PipeWireAO.header_metadata_param()),
        map(r -> PipeWireAO.Pod(PipeWireAO.metadata_param(r)),
            PipeWireAORTC.Common.TELEMETRY_METADATA)...,
    )
    return ScalarStream(latest, format, schema, params, PipeWireAO.StreamBuffer(), false, false, true)
end

function write_scalar!(buffer, sample)
    metadata = sample.metadata
    identity = metadata.acquisition_identity
    header_flags = metadata.terminal ? PipeWireAO.SPA.META_HEADER_FLAG_MARKER : UInt32(0)
    metadata.discontinuity && (header_flags |= PipeWireAO.SPA.META_HEADER_FLAG_DISCONT)
    pts = metadata.has_timestamp ? metadata.timestamp_nanoseconds : typemin(Int64)
    header = PipeWireAO.BufferHeader(header_flags, metadata.offset, pts, 0, metadata.sequence)
    records = PipeWireAO.initialize_metadata!(buffer)
    PipeWireAO.set_buffer_header!(buffer, header)
    PipeWireAO.set_acquisition_identity!(records, PipeWireAO.AcquisitionIdentity(
        PipeWireAO.AcquisitionDomain(identity.domain), identity.generation, identity.sequence,
    ))
    duration = metadata.has_exposure_duration ? metadata.exposure_duration_nanoseconds : nothing
    has_timing = PipeWireAO.metadata_record(records, PipeWireAO.SPA.META_EXPOSURE_TIMING) !== nothing
    if has_timing && metadata.has_exposure_start
        start = metadata.exposure_start
        PipeWireAO.set_exposure_timing!(records, PipeWireAO.ExposureTiming(start.nanoseconds;
            clock = PipeWireAO.MetadataClock(UInt32(start.clock)), duration_nanoseconds = duration,
        ))
    elseif has_timing && duration !== nothing
        PipeWireAO.set_exposure_timing!(records, PipeWireAO.ExposureTiming(; duration_nanoseconds = duration))
    end
    if metadata.has_reference_timestamp &&
       PipeWireAO.metadata_record(records, PipeWireAO.SPA.META_REFERENCE_TIMESTAMP) !== nothing
        stamp = metadata.reference_timestamp
        PipeWireAO.set_reference_timestamp!(records, PipeWireAO.ReferenceTimestamp(stamp.timestamp_nanoseconds;
            clock = PipeWireAO.MetadataClock(UInt32(stamp.clock)),
            duration_nanoseconds = stamp.has_duration ? stamp.duration_nanoseconds : nothing,
        ))
    end
    data = PipeWireAO.buffer_data(buffer)
    reinterpret(Float32, PipeWireAO.buffer_memory(data, sizeof(Float32)))[1] = sample.value
    PipeWireAO.set_chunk!(data; size = sizeof(Float32), stride = sizeof(Float32))
    PipeWireAO.set_buffer_size!(buffer, 1)
    return nothing
end

function publish_scalar!(state::ScalarStream, stream)
    advance_latest!(state.latest) && (state.pending = true)
    state.streaming && state.pending && state.route_ready || return nothing
    sample = latest_sample(state.latest)
    sample === nothing && return nothing
    PipeWireAO.dequeue_buffer!(state.buffer, stream) || return nothing
    queued = false
    try
        records = PipeWireAO.metadata_records(state.buffer)
        if PipeWireAO.metadata_record(records, UInt32(PipeWireAO.SPA.META_HEADER)) === nothing ||
           PipeWireAO.metadata_record(records, PipeWireAO.SPA.META_ACQUISITION_IDENTITY) === nothing
            state.pending = false
            return nothing
        end
        write_scalar!(state.buffer, sample)
        PipeWireAO.queue_buffer!(state.buffer, stream)
        queued = true
        state.pending = false
    finally
        queued || PipeWireAO.return_buffer!(state.buffer, stream)
    end
    return nothing
end

mutable struct ScalarOutputLink
    proxy::Union{Nothing,PipeWireAO.Link}
    endpoints::Union{Nothing,NTuple{4,PipeWireAO.Global}}
    removed::Bool
    const state::Base.RefValue{Int}
    ScalarOutputLink() = new(nothing, nothing, false, Ref(Int(PipeWireAO.LINK_STATE_INIT)))
end

function reconcile_scalar_link!(connection::ScalarOutputLink, core, registry, stream, endpoint, publisher)
    endpoints = connection.endpoints
    stale = endpoints !== nothing &&
        !all(item -> analysis_incarnation_present(registry, item), endpoints)
    if stale || connection.removed || connection.state[] == Int(PipeWireAO.LINK_STATE_ERROR)
        publisher.route_ready = false
        connection.proxy === nothing || close(connection.proxy)
        connection.proxy = nothing
        connection.endpoints = nothing
        connection.removed = false
        connection.state[] = Int(PipeWireAO.LINK_STATE_INIT)
    end
    if connection.proxy !== nothing
        publisher.route_ready = connection.state[] >= Int(PipeWireAO.LINK_STATE_PAUSED)
        return nothing
    end
    source_id = PipeWireAO.node_id(stream)
    source_id === nothing && return nothing
    source = PipeWireAO.find_global(registry, source_id)
    source === nothing && return nothing
    ports = PipeWireAO.find_globals(registry; interface = "PipeWire:Interface:Port",
        properties = ("node.id" => string(source_id), "port.direction" => "out"))
    length(ports) == 1 || return nothing
    output = (source, only(ports))
    all(item -> haskey(item.properties, "object.serial"), output) || return nothing
    input = analysis_endpoint(registry, endpoint, "in")
    input === nothing && return nothing
    endpoints = (output..., input...)
    all(item -> analysis_incarnation_present(registry, item), endpoints) || return nothing
    removed(_) = (connection.removed = true; publisher.route_ready = false; nothing)
    connection.proxy = PipeWireAO.create_object(core, "link-factory", PipeWireAO.Link;
        properties = Dict(
            "link.output.node" => string(source_id), "link.output.port" => string(output[2].id),
            "link.input.node" => string(input[1].id), "link.input.port" => string(input[2].id),
            "object.linger" => "false",
        ),
        on_info = analysis_link_observer(connection.state, output, input),
        on_removed = removed,
        on_error = (proxy, _, _) -> removed(proxy),
    )
    connection.endpoints = endpoints
    return nothing
end

function scalar_link_timer(loop, connection, core, registry, stream, endpoint, publisher)
    function tick(_, _)
        try
            reconcile_scalar_link!(connection, core, registry, stream, endpoint, publisher)
        catch
            publisher.route_ready = false
            # The target is optional. Retry discovery on the next timer tick.
        end
        return nothing
    end
    return PipeWireAO.TimerSource(loop, tick; delay = 0.2, interval = 0.2)
end

struct ScalarPublisher{L,C,R,S,T,G,Q,U}
    loop::L
    context::C
    core::R
    stream::S
    timer::T
    registry::G
    connection::Q
    link_timer::U
end

function open_scalar_publisher(display, remote)
    Base.ENDIAN_BOM == 0x04030201 || error("the scalar publisher requires little-endian storage")
    state = ScalarStream(display.latest, display.format, display.schema)
    state.route_ready = display.sink === nothing
    loop = PipeWireAO.ThreadLoop("rtc-display")
    context = core = stream = timer = registry = connection = link_timer = nothing
    try
        PipeWireAO.with_thread_loop_lock(loop) do _
            context = PipeWireAO.Context(loop)
            core = PipeWireAO.CoreConnection(context; properties = Dict("remote.name" => remote))
            stream = PipeWireAO.Stream(core, display.node;
                properties = Dict(
                    "node.name" => display.node,
                    "media.name" => display.media,
                    "media.type" => "Application",
                    "media.class" => "Data/Source",
                    "node.want-driver" => "true",
                    "priority.driver" => "100",
                ),
                on_state_changed = (_, old, current, message) -> begin
                    state.streaming = current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING
                    state.streaming && (state.pending = true)
                    nothing
                end,
                on_param_changed = (stream, id, param) -> begin
                    id == PipeWireAO.SPA.PARAM_FORMAT && param !== nothing || return nothing
                    PipeWireAO.update_params!(stream, state.params)
                    nothing
                end,
                on_process = stream -> publish_scalar!(state, stream),
            )
            flags = PipeWireAO.STREAM_MAP_BUFFERS | PipeWireAO.STREAM_NO_CONVERT |
                PipeWireAO.STREAM_DRIVER | PipeWireAO.STREAM_ASYNC
            params = (PipeWireAO.ndarray_format(state.format; schema = state.schema), state.params...)
            PipeWireAO.connect!(stream, :output; flags, params)
            timer = scalar_timer(loop, stream, state)
            if display.sink !== nothing
                registry = PipeWireAO.Registry(core)
                connection = ScalarOutputLink()
                link_timer = scalar_link_timer(loop, connection, core, registry, stream, display.sink, state)
            end
        end
        PipeWireAO.start!(loop)
        return ScalarPublisher(loop, context, core, stream, timer, registry, connection, link_timer)
    catch
        close_scalar_publisher(loop, timer, stream, core, context, registry, connection, link_timer)
        rethrow()
    end
end

function scalar_timer(loop, stream, state)
    # A chart needs the latest available sample, so bound graph triggers to 200 Hz.
    function tick(_, _)
        advance_latest!(state.latest) && (state.pending = true)
        if state.streaming && state.pending && state.route_ready && latest_sample(state.latest) !== nothing &&
           PipeWireAO.is_driving(stream)
            try
                PipeWireAO.trigger_process!(stream)
            catch error
                error isa PipeWireAO.PipeWireError && error.code in (-Base.Libc.EIO, -Base.Libc.EAGAIN) || rethrow()
            end
        end
        return nothing
    end
    return PipeWireAO.TimerSource(loop, tick; delay = 0.005, interval = 0.005)
end

function close_scalar_publisher(loop, timer, stream, core, context, registry, connection, link_timer)
    errors = Any[]
    try
        PipeWireAO.isrunning(loop) && PipeWireAO.stop!(loop)
    catch error
        push!(errors, error)
    end
    try
        PipeWireAO.with_thread_loop_lock(loop) do _
            link = connection === nothing ? nothing : connection.proxy
            for resource in (link_timer, timer, link, stream, registry, core, context)
                resource === nothing && continue
                try
                    close(resource)
                catch error
                    push!(errors, error)
                end
            end
        end
    catch error
        push!(errors, error)
    end
    try
        close(loop)
    catch error
        push!(errors, error)
    end
    isempty(errors) || throw(CompositeException(errors))
    return nothing
end

Base.close(publisher::ScalarPublisher) = close_scalar_publisher(
    publisher.loop, publisher.timer, publisher.stream, publisher.core, publisher.context,
    publisher.registry, publisher.connection, publisher.link_timer,
)
