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
        format, spec.schema, nothing, nothing, nothing, nothing, 0, 0, true, true,
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

function _classic_buffer_parameters(capture)
    return (Pod(buffers_param(buffers=2, blocks=1, size=payload_size(capture.format))),
        Pod(header_metadata_param()), Pod(acquisition_metadata_param()))
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
        if previous===nothing || previous.sequence!=header.sequence
            previous===nothing || header.sequence>previous.sequence ||
                error("Classic observation sequence regressed")
            capture.distinct_sequences+=1
            capture.identities[mod1(capture.distinct_sequences, length(capture.identities))]=identity
        end
        capture.first_sequence===nothing && (capture.first_sequence=header.sequence)
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

function _classic_wait(predicate, loop, deadline, description, core_error)
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
        sleep(0.02)
    end
end

function _classic_common_wfs_identity(captures)
    groups=map(captures[1:4]) do capture
        Set(identity for identity in capture.identities if identity!==nothing)
    end
    common=reduce(intersect, groups)
    isempty(common) && return nothing
    return last(sort!(collect(common); by=identity -> identity.sequence))
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
        "output_node_id"=>endpoint.node, "output_port_id"=>endpoint.output,
        "observer_node_id"=>endpoint.sink, "observer_port_id"=>endpoint.input,
        "shape"=>collect(actual.shape), "element_type"=>string(actual.element_type),
        "storage_type"=>string(eltype(capture.values)), "layout"=>string(actual.layout),
        "schema"=>capture.schema,
        "rate"=>actual.rate===nothing ? nothing : [actual.rate.num, actual.rate.denom],
        "first_sequence"=>capture.first_sequence, "last_sequence"=>header.sequence,
        "count"=>capture.count, "distinct_sequences"=>capture.distinct_sequences,
        "finite"=>capture.finite, "canonical_boolean"=>capture.canonical_boolean,
        "last_header"=>Dict("sequence"=>header.sequence, "pts"=>header.pts,
            "flags"=>header.flags, "offset"=>header.offset, "dts_offset"=>header.dts_offset),
        "last_identity"=>_classic_identity_record(capture.identity))
end

"""
    observe_classic(remote; timeout=30.0)

Observe a Running Classic application through its eight existing capacity-one
copy/drop-oldest queue outputs. Return a plain record after every stream has
delivered at least two increasing sequences with finite payloads and the four
WFS products have delivered a common acquisition identity. Exact owned links,
streams, registry, core, context, and loop are closed on success or failure.

This opt-in check proves sample delivery and sequence/identity consistency. It
does not establish scientific accuracy, cadence, latency, or hardware behavior.
The caller starts/stops the application and saves the returned record, e.g.
`record = observe_classic(remote; timeout=45)`.
"""
function observe_classic(remote::AbstractString; timeout::Real=30.0)
    isfinite(timeout) && timeout>0 || throw(ArgumentError("timeout must be positive and finite"))
    Base.ENDIAN_BOM==0x04030201 || error("Classic observation requires a little-endian host")
    deadline=_classic_now()+timeout
    loop=ThreadLoop("classic-integration-observer")
    context=core=registry=nothing
    streams=Any[]
    links=Any[]
    probes=Any[]
    trackers=Any[nothing for _ in CLASSIC_OBSERVATION_STREAMS]
    captures=map(ClassicObservationCapture, CLASSIC_OBSERVATION_STREAMS)
    core_error=Ref{Any}(nothing)
    sync_done=Ref{Cint}(-1)
    endpoints=Any[]
    try
        with_thread_loop_lock(loop) do _
            context=Context(loop)
            core=CoreConnection(context; properties=Dict("remote.name"=>String(remote)),
                on_error=(_, id, sequence, err) -> (core_error[]=err; nothing),
                on_done=(_, id, sequence) -> (sync_done[]=sequence; nothing))
            registry=Registry(core)
            for (index, capture) in enumerate(captures)
                name="classic-integration-observer-$(getpid())-$index"
                stream=Stream(core, name; properties=Dict("node.name"=>name,
                    "node.want-driver"=>"true", "priority.driver"=>"100",
                    "node.loop.name"=>"observer-loop"),
                    on_process=capture, on_param_changed=ClassicObservationFormat(capture))
                push!(streams, stream)
                precompile(capture, (typeof(stream),))
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
            for (index, (spec, stream)) in enumerate(zip(CLASSIC_OBSERVATION_STREAMS, streams))
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
                (isempty(outputs) || isempty(inputs)) && return false
                push!(endpoints, (node=node.id, output=only(outputs).id,
                    sink=node_id(stream), input=only(inputs).id))
            end
            return true
        end
        with_thread_loop_lock(loop) do _
            for (stream, endpoint) in zip(streams, endpoints)
                push!(links, create_object(core, "link-factory", Link; properties=Dict(
                    "link.output.node"=>string(endpoint.node),
                    "link.output.port"=>string(endpoint.output),
                    "link.input.node"=>string(node_id(stream)),
                    "link.input.port"=>string(endpoint.input), "object.linger"=>"false")))
                set_active!(stream, true)
            end
        end
        progress=() -> with_thread_loop_lock(loop) do _
            counts=join(("$(spec.name)=$(capture.distinct_sequences) sequences" for
                (spec,capture) in zip(CLASSIC_OBSERVATION_STREAMS,captures)), ", ")
            "Classic samples and matching WFS acquisition identity ($counts)"
        end
        _classic_wait(loop, deadline, progress, core_error) do
            for (stream,capture) in zip(streams,captures)
                stream_state(stream)
                capture.error===nothing || throw(capture.error)
                capture.finite || error("Classic observation received a nonfinite payload")
                capture.canonical_boolean || error("Classic validity payload contains a value above one")
                is_driving(stream) && trigger_process!(stream)
            end
            all(c -> c.distinct_sequences>=2, captures) &&
                _classic_common_wfs_identity(captures)!==nothing
        end
        return with_thread_loop_lock(loop) do _
            for capture in captures
                capture.error===nothing || throw(capture.error)
                capture.finite && capture.canonical_boolean || error("invalid final Classic payload")
            end
            Dict("remote"=>String(remote), "boundary"=>"capacity-one copy/drop-oldest queues",
                "streams"=>Dict(spec.name=>_classic_capture_record(spec,capture,endpoint)
                    for (spec,capture,endpoint) in zip(CLASSIC_OBSERVATION_STREAMS,captures,endpoints)),
                "matching_wfs_identity"=>_classic_identity_record(_classic_common_wfs_identity(captures)))
        end
    finally
        # Attempt every close even when another resource reports a cleanup error.
        cleanup_errors=Any[]
        with_thread_loop_lock(loop) do _
            for resource in (reverse(links)..., reverse(streams)...,
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
            stop!(loop)
            close(loop)
        catch err
            push!(cleanup_errors,err)
        end
        isempty(cleanup_errors) || throw(CompositeException(cleanup_errors))
    end
end
