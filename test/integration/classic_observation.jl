# Opt-in client of the installed Classic capacity-one observation queues.
# Including this file does not connect to or change a running application.
using PipeWireAO

const CLASSIC_OBSERVATION_STREAMS = (
    (name="detector", node="simulator-detector-queue-output", media="detector-image",
        type=UInt16, wire=NdArray.U16_LE, shape=(352,352),
        schema="org.calculon.ao.raw-detector-pixels/1", rate=SPA.Fraction(500,1)),
    (name="slopes", node="rtc-slopes-queue-output", media="shwfs-slopes",
        type=Float32, wire=NdArray.F32_LE, shape=(188,2),
        schema="org.calculon.ao.shack-hartmann-slopes/1", rate=nothing),
    (name="flux", node="rtc-flux-queue-output", media="shwfs-flux",
        type=Float32, wire=NdArray.F32_LE, shape=(188,),
        schema="org.calculon.ao.shack-hartmann-flux/1", rate=nothing),
    # BOOL8 has byte storage, but is a distinct negotiated wire type from U8.
    (name="validity", node="rtc-validity-queue-output", media="shwfs-validity",
        type=UInt8, wire=NdArray.BOOL8, shape=(188,),
        schema="org.calculon.ao.shack-hartmann-validity/1", rate=nothing),
    (name="demanded", node="rtc-command-queue-output", media="dm-command",
        type=Float32, wire=NdArray.F32_LE, shape=(277,),
        schema="org.calculon.ao.demanded-pdm-command/1", rate=nothing),
    (name="applied", node="rtc-applied-queue-output", media="dm-applied",
        type=Float32, wire=NdArray.F32_LE, shape=(277,),
        schema="org.calculon.ao.applied-pdm-command/1", rate=nothing),
    (name="offset", node="rtc-offset-queue-output", media="dm-offset",
        type=Float32, wire=NdArray.F32_LE, shape=(277,),
        schema="org.calculon.ao.pdm-engineering-offset/1", rate=nothing),
    (name="focal", node="simulator-focal-image-queue-output", media="focal-image",
        type=Float32, wire=NdArray.F32_LE, shape=(480,480),
        schema="org.calculon.ao.focal-photon-rate.f32/1", rate=nothing),
)

mutable struct ClassicObservationCapture{T,N}
    buffer::StreamBuffer
    values::Vector{T}
    format::NdArrayFormat{N}
    schema::String
    negotiated::Union{Nothing,NdArrayFormat{N}}
    header::Union{Nothing,BufferHeader}
    identity::Union{Nothing,AcquisitionIdentity}
    first_identity::Union{Nothing,AcquisitionIdentity}
    first_sequence::Union{Nothing,UInt64}
    count::Int
    distinct_sequences::Int
    finite::Bool
    canonical_boolean::Bool
    identities::Vector{Union{Nothing,AcquisitionIdentity}}
    error::Any
end

function ClassicObservationCapture(spec)
    format=NdArrayFormat(spec.wire, spec.shape; layout=NdArray.ROW_MAJOR, rate=spec.rate)
    return ClassicObservationCapture(StreamBuffer(), zeros(spec.type, prod(spec.shape)),
        format, spec.schema, nothing, nothing, nothing, nothing, nothing, 0, 0, true, true,
        Union{Nothing,AcquisitionIdentity}[nothing for _ in 1:256], nothing)
end

# SPA's public ChoiceNone wire representation embeds one child POD after its
# kind/flags. PipeWireAO 0.6.18's fixed ndarray parser accepts direct values;
# unwrap fixed choices with owned public POD values before calling that parser.
function _classic_fixed_value(value::Pod)
    choice_type=pod_type(Pod(SPA.Choice(SPA.CHOICE_NONE, [SPA.Id(0)])))
    pod_type(value)==choice_type || return value
    length(value.data)>=24 || error("truncated negotiated SPA choice")
    kind=only(reinterpret(UInt32, value.data[9:12]))
    kind==UInt32(SPA.CHOICE_NONE) || error("negotiated format contains an unfixed SPA choice")
    child=Pod(value.data[17:end])
    sizeof(child)+16==sizeof(value) || error("negotiated SPA choice has multiple values")
    return child
end

function _classic_fixed_format(parameter::Pod)
    object=pod_value(SPA.Parameter, parameter).object
    properties=[SPA.Property(p.key, _classic_fixed_value(p.value); flags=p.flags)
        for p in object.properties]
    return SPA.Parameter(SPA.Object(object.type, object.id, properties))
end

struct ClassicObservationFormat{C}
    capture::C
end

function (callback::ClassicObservationFormat)(stream, id, parameter)
    id==SPA.PARAM_FORMAT && parameter!==nothing || return nothing
    capture=callback.capture
    try
        fixed=_classic_fixed_format(parameter)
        actual=NdArrayFormat(fixed)
        expected=capture.format
        actual.element_type==expected.element_type && actual.shape==expected.shape &&
            actual.layout==expected.layout && ndarray_schema(fixed)==capture.schema ||
            error("Classic observation negotiated a different ndarray contract")
        expected.rate===nothing || actual.rate==expected.rate ||
            error("Classic detector observation negotiated a different rate")
        capture.negotiated=actual
        update_params!(stream, _classic_buffer_parameters(capture))
    catch err
        capture.error=err
    end
    return nothing
end

function _classic_buffer_parameters(capture::ClassicObservationCapture{T}) where {T}
    # The queue's playback pool has the capture pool's exact buffer count:
    # capacity one requires three pool buffers (retained capacity plus two).
    # Match the GUI observer's bounded range rather than requiring two buffers.
    count=SPA.Choice(SPA.CHOICE_RANGE, Int32[3,2,64])
    memory_types=Int32((1<<Int(SPA.DATA_MEM_PTR)) | (1<<Int(SPA.DATA_MEM_FD)) |
        (1<<Int(SPA.DATA_DMA_BUF)))
    return (Pod(buffers_param(buffers=count, blocks=1, size=payload_size(capture.format),
            stride=Int(last(capture.format.shape))*sizeof(T),
            data_types=SPA.Choice(SPA.CHOICE_FLAGS, Int32[memory_types]))),
        Pod(header_metadata_param()), Pod(acquisition_metadata_param(;version=2)))
end

function (capture::ClassicObservationCapture{T})(stream) where {T}
    capture.error===nothing || return nothing
    dequeue_buffer!(capture.buffer, stream) || return nothing
    try
        capture.negotiated===nothing && error("sample arrived before format negotiation")
        header=something(buffer_header(capture.buffer))
        header.flags & (SPA.META_HEADER_FLAG_CORRUPTED | SPA.META_HEADER_FLAG_GAP)==0 ||
            error("Classic observation received an invalid Header")
        metadata=buffer_acquisition(capture.buffer)
        identity=metadata===nothing ? nothing : acquisition_identity(metadata)
        identity===nothing || identity.sequence==header.sequence ||
            error("Classic observation Header and acquisition sequence differ")
        data=buffer_data(capture.buffer)
        chunk=chunk_info(data)
        packed_stride=Int(last(capture.format.shape))*sizeof(T)
        chunk.offset==0 && chunk.size==payload_size(capture.format) &&
            chunk.stride in (0, sizeof(T), packed_stride) && chunk.flags==0 ||
            error("Classic observation payload is not the declared packed ndarray")
        # Own all retained data before returning the borrowed buffer. Readers
        # hold the same native loop lock used to dispatch this callback.
        copyto!(capture.values, reinterpret(T, bytes(data)))
        capture.finite &= all(isfinite, capture.values)
        if capture.format.element_type==NdArray.BOOL8
            capture.canonical_boolean &= all(value -> value<=1, capture.values)
        end
        previous=capture.header
        if previous!==nothing
            _classic_same_acquisition(capture.identity, identity)
        end
        if previous===nothing || previous.sequence!=header.sequence
            previous===nothing || header.sequence>previous.sequence ||
                error("Classic observation sequence regressed")
            capture.distinct_sequences+=1
            capture.identities[mod1(capture.distinct_sequences, length(capture.identities))]=identity
        end
        if capture.first_sequence===nothing
            capture.first_sequence=header.sequence
            capture.first_identity=identity
        end
        capture.header=header
        capture.identity=identity
        capture.count+=1
    catch err
        capture.error=err
    finally
        queue_buffer!(capture.buffer, stream)
    end
    return nothing
end

_classic_now()=Float64(time_ns())/1e9

function _classic_wait(predicate, loop, deadline, description, core_error; interval=0.02)
    while true
        done=with_thread_loop_lock(loop) do _
            core_error[]===nothing || throw(core_error[])
            predicate()
        end
        done && return nothing
        if _classic_now()>=deadline
            detail=description isa Function ? description() : description
            error("timed out waiting for $detail")
        end
        sleep(interval) # Outside the native loop lock; the producer remains independent.
    end
end

function _classic_common_wfs_identity(captures, specs=CLASSIC_OBSERVATION_STREAMS)
    wfs=findall(spec -> spec.name in ("detector","slopes","flux","validity"), specs)
    length(wfs)==4 || return nothing
    groups=map(wfs) do index
        capture=captures[index]
        Set(identity for identity in capture.identities if identity!==nothing)
    end
    common=reduce(intersect, groups)
    isempty(common) && return nothing
    return last(sort!(collect(common); by=identity -> identity.sequence))
end

function _classic_same_acquisition(previous, current)
    if previous===nothing || current===nothing
        previous===current || error("Classic observation acquisition metadata presence changed")
    else
        previous.domain==current.domain && previous.generation==current.generation ||
            error("Classic observation acquisition domain or generation changed")
    end
    return nothing
end

function _classic_observation_timing(timeout, drive_interval, minimum_duration)
    all(value -> isfinite(value) && value>0, (timeout, drive_interval)) ||
        throw(ArgumentError("timeout and drive_interval must be positive and finite"))
    isfinite(minimum_duration) && 0<=minimum_duration<timeout ||
        throw(ArgumentError("minimum_duration must be finite, nonnegative and shorter than timeout"))
    drive_interval<timeout || throw(ArgumentError("drive_interval must be shorter than timeout"))
    return nothing
end

function _classic_identity_record(identity)
    identity===nothing && return nothing
    return Dict("domain"=>bytes2hex(collect(identity.domain.bytes)),
        "generation"=>identity.generation, "sequence"=>identity.sequence)
end

function _classic_capture_record(spec, capture, endpoint)
    actual=something(capture.negotiated)
    header=something(capture.header)
    return Dict("node"=>spec.node, "media"=>spec.media,
        "output_node_id"=>endpoint.node, "output_node_serial"=>endpoint.node_serial,
        "output_port_id"=>endpoint.output, "output_port_serial"=>endpoint.output_serial,
        "observer_node_id"=>endpoint.sink, "observer_node_serial"=>endpoint.sink_serial,
        "observer_port_id"=>endpoint.input, "observer_port_serial"=>endpoint.input_serial,
        "shape"=>collect(actual.shape), "element_type"=>string(actual.element_type),
        "storage_type"=>string(eltype(capture.values)), "layout"=>string(actual.layout),
        "schema"=>capture.schema,
        "rate"=>actual.rate===nothing ? nothing : [actual.rate.num, actual.rate.denom],
        "first_sequence"=>capture.first_sequence, "last_sequence"=>header.sequence,
        "count"=>capture.count, "distinct_sequences"=>capture.distinct_sequences,
        "finite"=>capture.finite, "canonical_boolean"=>capture.canonical_boolean,
        "last_header"=>Dict("sequence"=>header.sequence, "pts"=>header.pts,
            "flags"=>header.flags, "offset"=>header.offset, "dts_offset"=>header.dts_offset),
        "first_identity"=>_classic_identity_record(capture.first_identity),
        "last_identity"=>_classic_identity_record(capture.identity))
end

"""
    observe_classic(remote; timeout=30.0, selected_streams=nothing,
        drive_interval=0.02, minimum_duration=0.0)

Observe a Running Classic application through its eight existing capacity-one
copy/drop-oldest queue outputs. Return a plain record after every stream has
delivered at least two increasing sequences with finite payloads and the four
WFS products have delivered a common acquisition identity. Exact owned links,
streams, registry, core, context, and loop are closed on success or failure.

This opt-in check proves sample delivery and sequence/identity consistency. It
does not establish scientific accuracy, cadence, latency, or hardware behavior.
The caller starts/stops the application and saves the returned record, e.g.
`record = observe_classic(remote; timeout=45)`.
For a narrow diagnostic, select queue products by name with
`selected_streams=("detector",)`. The common WFS identity check applies when
all four WFS products are selected. The default observes and checks all eight.
Opt-in integration clients may wrap each process callback with `process_capture`
to retain bounded prefixes, extend collection with `finished(captures)`, and
release their own session with `on_ready` after format negotiation. Collection
is compiled while held before `on_ready`, which runs outside the loop lock.
`finished` runs under that lock; process callbacks run on its native thread.
Neither may block. These hooks do not change the display queues' loss policy.
Additional diagnostic declarations may be supplied as `stream_specs`. Their
`valid_payload(capture)` predicate must validate the declared special values;
the default retains the existing all-finite payload requirement. Masked OPD
validation checks its NaNs against the actual pupil during scientific replay.
`drive_interval` spaces observer driver requests; its sleep is outside the native
loop lock. `minimum_duration` keeps this attachment observing for at least that
many seconds after all streams first deliver samples. These are client settings,
not source controls.
"""
function observe_classic(remote::AbstractString; timeout::Real=30.0, selected_streams=nothing,
        drive_interval::Real=0.02, minimum_duration::Real=0.0,
        process_capture=identity, on_ready=nothing, finished=captures -> true,
        stream_specs=CLASSIC_OBSERVATION_STREAMS, valid_payload=capture -> capture.finite)
    _classic_observation_timing(timeout, drive_interval, minimum_duration)
    Base.ENDIAN_BOM==0x04030201 || error("Classic observation requires a little-endian host")
    names=selected_streams===nothing ? map(s -> s.name,stream_specs) :
        Tuple(String.(selected_streams))
    isempty(names) && throw(ArgumentError("select at least one Classic stream"))
    length(unique(names))==length(names) || throw(ArgumentError("duplicate Classic stream selection"))
    all(name -> any(s -> s.name==name,stream_specs),names) ||
        throw(ArgumentError("unknown Classic stream selection"))
    specs=filter(spec -> spec.name in names,stream_specs)
    require_wfs_identity=all(name -> name in names,("detector","slopes","flux","validity"))
    deadline=_classic_now()+timeout
    loop=ThreadLoop("classic-integration-observer")
    context=core=registry=nothing
    streams=Any[]
    links=Any[]
    link_trackers=Any[]
    probes=Any[]
    trackers=Any[nothing for _ in specs]
    captures=map(ClassicObservationCapture, specs)
    core_error=Ref{Any}(nothing)
    sync_done=Ref{Cint}(-1)
    endpoints=Any[]
    core_objects=Dict{UInt32,String}()
    try
        with_thread_loop_lock(loop) do _
            context=Context(loop)
            core=CoreConnection(context; properties=Dict("remote.name"=>String(remote)),
                on_error=(_, id, sequence, err) -> begin
                    endpoint=get(core_objects,id,join(values(core_objects), "; "))
                    core_error[]=ErrorException("Classic observer core object=$id sequence=$sequence " *
                        "endpoint=[$endpoint]: " * sprint(showerror,err))
                    nothing
                end,
                on_done=(_, id, sequence) -> (sync_done[]=sequence; nothing))
            registry=Registry(core)
            for (index, capture) in enumerate(captures)
                name="classic-integration-observer-$(getpid())-$index"
                process=process_capture(capture)
                stream=Stream(core, name; properties=Dict("node.name"=>name,
                    "node.want-driver"=>"true", "priority.driver"=>"100",
                    "node.loop.name"=>"observer-loop"),
                    on_process=process, on_param_changed=ClassicObservationFormat(capture))
                push!(streams, stream)
                precompile(process, (typeof(stream),))
                precompile(stream.callbacks.on_param_changed, (typeof(stream), UInt32, Pod))
                connect!(stream, :input;
                    flags=STREAM_MAP_BUFFERS | STREAM_INACTIVE | STREAM_DONT_RECONNECT |
                        STREAM_NO_CONVERT | STREAM_DRIVER,
                    params=(ndarray_format(capture.format; schema=capture.schema),
                        _classic_buffer_parameters(capture)...))
            end
        end
        start!(loop)
        # An asynchronous public sync avoids an unbounded roundtrip wait.
        sequence=with_thread_loop_lock(_ -> sync!(core), loop)
        _classic_wait(loop, deadline, "observer registry synchronization", core_error) do
            sync_done[]==sequence
        end
        _classic_wait(loop, deadline, "exact Classic observation endpoints", core_error) do
            empty!(endpoints)
            for (index, (spec, stream)) in enumerate(zip(specs, streams))
                stream_state(stream)
                nodes=find_globals(registry; interface="PipeWire:Interface:Node",
                    properties=("node.name"=>spec.node,))
                isempty(nodes) && return false
                node=only(nodes)
                # Global discovery exports a limited property subset. Inspect
                # the standard NodeInfo snapshot before accepting the boundary.
                if trackers[index]===nothing
                    probe=bind(registry, node, Node)
                    push!(probes,probe)
                    trackers[index]=track_info!(probe)
                end
                has_current_info(trackers[index]) || return false
                properties=current_info(trackers[index]).properties
                get(properties,"media.name",nothing)==spec.media ||
                    error("$(spec.node) has a different media name")
                for (key,value) in ("device.api"=>"pipewireao.queue", "queue.storage"=>"copy",
                    "queue.overflow"=>"drop-oldest", "queue.max-buffers"=>"1")
                    get(properties,key,nothing)==value || error("$(spec.node) lacks $key=$value")
                end
                outputs=find_globals(registry; interface="PipeWire:Interface:Port",
                    properties=("node.id"=>string(node.id), "port.direction"=>"out"))
                inputs=find_globals(registry; interface="PipeWire:Interface:Port",
                    properties=("node.id"=>string(node_id(stream)), "port.direction"=>"in"))
                observer_nodes=filter(object -> object.id==node_id(stream),
                    find_globals(registry; interface="PipeWire:Interface:Node"))
                (isempty(outputs) || isempty(inputs) || isempty(observer_nodes)) && return false
                output, input, sink=only(outputs), only(inputs), only(observer_nodes)
                serial(object)=parse(UInt64, object.properties["object.serial"])
                push!(endpoints, (node=node.id, node_serial=serial(node),
                    output=output.id, output_serial=serial(output),
                    sink=sink.id, sink_serial=serial(sink), input=input.id, input_serial=serial(input)))
            end
            return true
        end
        with_thread_loop_lock(loop) do _
            for (spec, stream, endpoint) in zip(specs, streams, endpoints)
                link=create_object(core, "link-factory", Link; properties=Dict(
                    "link.output.node"=>string(endpoint.node),
                    "link.output.port"=>string(endpoint.output),
                    "link.input.node"=>string(node_id(stream)),
                    "link.input.port"=>string(endpoint.input), "object.linger"=>"false"))
                push!(links,link)
                push!(link_trackers,track_info!(link))
                core_objects[proxy_id(link)]="$(spec.node) global=$(endpoint.node):$(endpoint.output) " *
                    "-> observer global=$(endpoint.sink):$(endpoint.input)"
                set_active!(stream, true)
            end
        end
        progress=() -> with_thread_loop_lock(loop) do _
            counts=join(("$(spec.name)=$(capture.distinct_sequences) sequences" for
                (spec,capture) in zip(specs,captures)), ", ")
            "Classic samples and matching WFS acquisition identity ($counts)"
        end
        observation_started=_classic_now()
        all_streams_sampled=nothing
        matching_wfs_identity=nothing
        collection_ready = () -> begin
            for (stream,capture) in zip(streams,captures)
                stream_state(stream)
                capture.error===nothing || throw(capture.error)
                valid_payload(capture) || error("Classic observation received an invalid payload")
                capture.canonical_boolean || error("Classic validity payload contains a value above one")
            end
            # Completion must be checked before submitting another asynchronous
            # driver request. A successful observation needs no extra cycle.
            if all_streams_sampled===nothing && all(c -> c.header!==nothing,captures)
                all_streams_sampled=_classic_now()
            end
            current_identity=_classic_common_wfs_identity(captures,specs)
            current_identity===nothing || (matching_wfs_identity=current_identity)
            if all(c -> c.distinct_sequences>=2, captures) &&
                (!require_wfs_identity || matching_wfs_identity!==nothing) &&
                all_streams_sampled!==nothing && _classic_now()-all_streams_sampled>=minimum_duration &&
                finished(captures)
                return true
            end
            for (stream,tracker) in zip(streams,link_trackers)
                has_current_info(tracker) || continue
                link=current_info(tracker)
                link.state==PipeWireAO.LINK_STATE_ERROR && error("Classic observation link failed: $(link.error)")
                if link.state==PipeWireAO.LINK_STATE_ACTIVE &&
                    stream_state(stream)==PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING && is_driving(stream)
                    trigger_process!(stream)
                end
            end
            return false
        end
        if on_ready!==nothing
            _classic_wait(loop,deadline,"held observer format negotiation",core_error) do
                all(capture -> capture.negotiated!==nothing,captures) &&
                    all(tracker -> has_current_info(tracker) &&
                        current_info(tracker).state in
                            (PipeWireAO.LINK_STATE_PAUSED,PipeWireAO.LINK_STATE_ACTIVE),link_trackers)
            end
            with_thread_loop_lock(loop) do _
                collection_ready()
                finished(captures)
            end
            on_ready()
        end
        _classic_wait(collection_ready,loop,deadline,progress,core_error;interval=Float64(drive_interval))
        return with_thread_loop_lock(loop) do _
            for capture in captures
                capture.error===nothing || throw(capture.error)
                valid_payload(capture) && capture.canonical_boolean || error("invalid final Classic payload")
            end
            Dict("remote"=>String(remote), "boundary"=>"capacity-one copy/drop-oldest queues",
                "drive_interval_s"=>Float64(drive_interval), "minimum_duration_s"=>Float64(minimum_duration),
                "observation_started_s"=>observation_started, "all_streams_sampled_s"=>all_streams_sampled,
                "observation_ended_s"=>_classic_now(),
                "streams"=>Dict(spec.name=>_classic_capture_record(spec,capture,endpoint)
                    for (spec,capture,endpoint) in zip(specs,captures,endpoints)),
                "matching_wfs_identity"=>_classic_identity_record(matching_wfs_identity))
        end
    finally
        cleanup_errors=Any[]
        # Match the GUI's public retirement protocol: remove owned links and
        # await Done, disconnect streams and await Done, then release callbacks.
        # Keep streams and capture storage rooted through both acknowledgements.
        retirement_deadline=_classic_now()+5.0
        if core!==nothing && isrunning(loop)
            with_thread_loop_lock(loop) do _
                for resource in (reverse(link_trackers)..., reverse(links)...)
                    try
                        close(resource)
                    catch err
                        push!(cleanup_errors,err)
                    end
                end
            end
            try
                sequence=with_thread_loop_lock(_ -> sync!(core),loop)
                _classic_wait(loop,retirement_deadline,"Classic observer link removal",core_error) do
                    sync_done[]==sequence
                end
            catch err
                push!(cleanup_errors,err)
            end
            with_thread_loop_lock(loop) do _
                for stream in streams
                    try
                        disconnect!(stream)
                    catch err
                        push!(cleanup_errors,err)
                    end
                end
            end
            try
                sequence=with_thread_loop_lock(_ -> sync!(core),loop)
                _classic_wait(loop,retirement_deadline,"Classic observer stream disconnection",core_error) do
                    sync_done[]==sequence
                end
            catch err
                push!(cleanup_errors,err)
            end
        end
        # Join the owned callback thread before freeing its remaining objects.
        # Failed retirement fences remain errors after cleanup is attempted.
        try
            stop!(loop)
        catch err
            push!(cleanup_errors,err)
        end
        # Attempt every close even when another resource reports a cleanup error.
        with_thread_loop_lock(loop) do _
            for resource in (reverse(link_trackers)..., reverse(links)..., reverse(streams)...,
                reverse(trackers)..., reverse(probes)..., registry, core, context)
                resource===nothing && continue
                try
                    close(resource)
                catch err
                    push!(cleanup_errors,err)
                end
            end
        end
        try
            close(loop)
        catch err
            push!(cleanup_errors,err)
        end
        isempty(cleanup_errors) || throw(CompositeException(cleanup_errors))
    end
end
