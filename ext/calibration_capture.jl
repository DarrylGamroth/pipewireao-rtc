"""Bounded, owned acquisition capture; the supplied PipeWire core remains caller-owned."""
module CalibrationCapture

using PipeWireAO
import PipeWireAORTC
import AdaptiveOpticsSim

export Capture, arm!, await!, snapshot

const IDLE = UInt8(0)
const ARMED = UInt8(1)
const COMPLETE = UInt8(2)
const CLOSED = UInt8(3)

"Owned per-stream provenance. Model time comes from the armed HIL exposure, never Header PTS."
struct Receipt
    identity::AcquisitionIdentity
    model_start_ns::Int64
    duration_ns::UInt64
    header::BufferHeader
    acquisition_version::UInt32
    acquisition_flags::UInt32
    wire_start::Union{Nothing,AcquisitionExposureStart}
    timebase::Union{Nothing,AcquisitionTimebase}
    ptp_reference::Union{Nothing,AcquisitionPtpReference}
end

mutable struct Slot{T,N}
    format::NdArrayFormat{N}
    schema::String
    wire::Vector{T}
    array::Array{T,N}
    permutation::Vector{Int}
    buffer::StreamBuffer
    phase::UInt8
    receipt::Union{Nothing,Receipt}
end

mutable struct Capture{Slots}
    core::CoreConnection
    slots::Slots
    streams::NamedTuple
    wakeup::Base.AsyncCondition
    wakeup_lock::ReentrantLock
    own_wakeup::Bool
    phase::UInt8
    failure::Symbol
    exception::Any
    expected::Union{Nothing,AcquisitionIdentity}
    model_start_ns::Int64
    duration_ns::UInt64
    last::Union{Nothing,AcquisitionIdentity}
    started::Bool
    waiting::Bool
end

_locked(f, capture::Capture) = with_thread_loop_lock(_ -> f(), main_loop(capture.core))
function _signal(capture)
    lock(capture.wakeup_lock) do
        isopen(capture.wakeup) && ccall(:uv_async_send, Cint, (Ptr{Cvoid},), capture.wakeup)
    end
    return nothing
end
function _close_wakeup(capture)
    lock(capture.wakeup_lock) do
        isopen(capture.wakeup) && close(capture.wakeup)
    end
    return nothing
end
function _fail!(capture, reason, exception=nothing)
    capture.failure === :none || return nothing
    capture.failure = reason
    capture.exception = exception
    _signal(capture)
    return nothing
end

function _usable(capture)
    capture.phase == CLOSED && throw(InvalidStateException("calibration capture is closed", :closed))
    capture.failure === :none || throw(InvalidStateException(
        "calibration capture failed: $(capture.failure)", :failed))
    return nothing
end

function _slot(spec, ::Type{T}, rank) where {T}
    format = spec.format
    format isa NdArrayFormat || throw(ArgumentError("capture format must be an NdArrayFormat"))
    expected = T === UInt16 ? NdArray.U16_LE : T === Bool ? NdArray.BOOL8 : NdArray.F32_LE
    format.element_type == expected && length(format.shape) == rank ||
        throw(ArgumentError("capture stream element type or rank differs from its declared role"))
    format.layout == NdArray.ROW_MAJOR || throw(ArgumentError("capture streams require explicit row-major wire layout"))
    Base.ENDIAN_BOM == 0x04030201 || throw(ArgumentError("capture requires a little-endian host"))
    payload_size(format) <= typemax(Int32) || throw(ArgumentError("capture payload exceeds SPA buffer range"))
    schema = String(spec.schema)
    isempty(schema) && throw(ArgumentError("capture stream schema must be nonempty"))
    shape = Int.(format.shape)
    array = zeros(T, shape)
    # Prepare row-major wire index -> Julia linear index once, outside callbacks.
    permutation = Int[]
    indices = LinearIndices(array)
    for reversed in CartesianIndices(reverse(shape))
        push!(permutation, indices[reverse(Tuple(reversed))...])
    end
    return Slot(format, schema, zeros(T, length(array)), array, permutation,
        StreamBuffer(), IDLE, nothing)
end

function _slots(declarations::NamedTuple)
    !isempty(declarations) && first(keys(declarations)) === :raw ||
        throw(ArgumentError("capture requires raw as its first declaration"))
    slots = map(keys(declarations), values(declarations)) do name, spec
        name === :raw && return _slot(spec, UInt16, 2)
        format = spec.format
        format isa NdArrayFormat || throw(ArgumentError("capture format must be an NdArrayFormat"))
        rank = length(format.shape)
        if format.element_type == NdArray.F32_LE && rank in (1, 2)
            return _slot(spec, Float32, rank)
        elseif format.element_type == NdArray.BOOL8 && rank == 1
            return _slot(spec, Bool, rank)
        end
        throw(ArgumentError("capture outputs require Float32 rank one/two or Bool rank one"))
    end
    return NamedTuple{keys(declarations)}(slots)
end

# Negotiated SPA formats can wrap a fixed property in SPA_CHOICE_None. Rebuild
# that public POD value before using the public NdArrayFormat parser. This path
# runs on configuration callbacks, never on the payload-copy path.
function _fixed(pod::Pod)
    pod_type(pod) == PipeWireAO.LibPipeWire.SPA_TYPE_Choice || return pod
    native = PipeWireAO.LibPipeWire
    length(pod.data) >= sizeof(native.spa_pod_choice) || throw(ArgumentError("truncated fixed format choice"))
    choice = GC.@preserve pod unsafe_load(Ptr{native.spa_pod_choice}(pointer(pod.data)))
    choice.body.type == UInt32(SPA.CHOICE_NONE) || throw(ArgumentError("negotiated format is not fixed"))
    offset = sizeof(native.spa_pod_choice)
    Int(choice.body.child.size) == length(pod.data) - offset || throw(ArgumentError("invalid fixed format choice length"))
    header = reinterpret(UInt8, UInt32[choice.body.child.size, choice.body.child.type])
    return Pod(vcat(header, pod.data[offset+1:end]))
end

function _format(parameter)
    object = pod_value(SPA.Parameter, parameter).object
    properties = [SPA.Property(property.key,
        property.key in (SPA.FORMAT_MEDIA_TYPE, SPA.FORMAT_MEDIA_SUBTYPE,
            SPA.FORMAT_NDARRAY_ELEMENT_TYPE, SPA.FORMAT_NDARRAY_LAYOUT,
            SPA.FORMAT_NDARRAY_SHAPE, SPA.FORMAT_NDARRAY_RATE) ? _fixed(property.value) : property.value;
        flags=property.flags) for property in object.properties]
    return SPA.Parameter(SPA.Object(object.type, object.id, properties))
end

function _buffer_parameters(slot)
    return (Pod(buffers_param(buffers=2, blocks=1, size=payload_size(slot.format))),
        Pod(header_metadata_param()), Pod(acquisition_metadata_param()))
end

function _param!(capture, slot, stream, id, parameter)
    id == SPA.PARAM_FORMAT && parameter !== nothing || return nothing
    try
        fixed = _format(parameter)
        actual, expected = NdArrayFormat(fixed), slot.format
        actual.element_type == expected.element_type && actual.shape == expected.shape &&
            actual.layout == expected.layout && actual.rate == expected.rate &&
            ndarray_schema(fixed) == slot.schema || throw(ArgumentError("negotiated capture format differs"))
        update_params!(stream, _buffer_parameters(slot))
    catch error
        _fail!(capture, :format, error)
    end
    return nothing
end

function _read!(capture, slot::Slot{T}, buffer) where {T}
    slot.phase == ARMED || return _fail!(capture, :duplicate)
    header = buffer_header(buffer)
    header === nothing && return _fail!(capture, :missing_header)
    header.sequence == something(capture.expected).sequence || return _fail!(capture, :sequence)
    # DISCONT can legitimately mark a generation boundary. Exact acquisition
    # identity still establishes freshness; CORRUPTED/GAP never complete a slot.
    invalid = SPA.META_HEADER_FLAG_CORRUPTED | SPA.META_HEADER_FLAG_GAP
    header.flags & invalid == 0 || return _fail!(capture, :header_flags)
    metadata = buffer_acquisition(buffer)
    metadata === nothing && return _fail!(capture, :missing_acquisition)
    acquisition_valid(metadata) || return _fail!(capture, :acquisition)
    identity = acquisition_identity(metadata)
    identity === capture.expected || identity == capture.expected || return _fail!(capture, :identity)
    duration = acquisition_exposure_duration(metadata)
    duration === capture.duration_ns || return _fail!(capture, :duration)
    start = acquisition_exposure_start(metadata)
    timebase = acquisition_timebase(metadata)
    reference = acquisition_ptp_reference(metadata)
    # Optional wire clock provenance is copied without treating its clock as
    # model time. The validated HIL timestamp is the model-time authority.
    data = buffer_data(buffer)
    chunk = chunk_info(data)
    extent = payload_size(slot.format)
    packed_stride = Int(last(slot.format.shape)) * sizeof(T)
    chunk.offset == 0 && chunk.size == extent && chunk.flags == 0 &&
        chunk.stride in (0, sizeof(T), packed_stride) || return _fail!(capture, :payload)
    memory = buffer_memory(data, extent)
    if T === Bool
        all(x -> x <= 1, memory) || return _fail!(capture, :boolean_encoding)
    end
    copyto!(slot.wire, reinterpret(T, memory))
    for index in eachindex(slot.wire)
        slot.array[slot.permutation[index]] = slot.wire[index]
    end
    slot.receipt = Receipt(something(identity), capture.model_start_ns, capture.duration_ns,
        header, UInt32(acquisition_version(metadata)), acquisition_flags(metadata), start, timebase, reference)
    slot.phase = COMPLETE
    all(other -> other.phase == COMPLETE, values(capture.slots)) && (capture.phase = COMPLETE)
    _signal(capture)
    return nothing
end

function _process!(capture, slot, stream)
    acquired = false
    try
        acquired = dequeue_buffer!(slot.buffer, stream)
        acquired || return nothing
        # Transport startup may produce warmup buffers before HIL arms a genuine
        # exposure. Return them without accepting data or advancing provenance.
        capture.phase in (ARMED, COMPLETE) && capture.failure === :none && _read!(capture, slot, slot.buffer)
    catch error
        _fail!(capture, :callback, error)
    finally
        if acquired
            try
                queue_buffer!(slot.buffer, stream)
            catch error
                _fail!(capture, :return_buffer, error)
            end
        end
    end
    return nothing
end

"""
    Capture(core, declarations; wakeup=nothing)

Prepare inactive raw and explicitly declared output streams on a caller-owned ThreadLoop
core. Each declaration has `name`, exact row-major `format`, and `schema`.
The first declaration is `raw` with UInt16 rank two. Other declarations have
Float32 rank one/two or Bool rank one; their names retain the graph output names.
The collector owns its streams and one fixed payload slot per stream. It owns
only an internally created wakeup; a supplied AsyncCondition remains caller-owned.
Callbacks only validate/copy one borrowed payload, return it and uv_async_send.
One control task owns arm/await/snapshot. Callbacks run on the core ThreadLoop;
control methods acquire that same loop lock. Payload and receipt stores therefore
happen before the owner observes completion. Close fences stream callbacks before
releasing an owned wakeup; a live waiter first unwinds its one-shot Timer. No scientific validity, clipping, unit conversion or file policy is applied.
"""
function Capture(core::CoreConnection, declarations::NamedTuple; wakeup=nothing, wakeup_lock=ReentrantLock())
    main_loop(core) isa ThreadLoop || throw(ArgumentError("capture requires a caller-dispatched ThreadLoop core"))
    slots = _slots(declarations)
    condition = wakeup === nothing ? Base.AsyncCondition() : wakeup
    condition isa Base.AsyncCondition && isopen(condition) || throw(ArgumentError("capture wakeup must be an open AsyncCondition"))
    capture = Capture(core,slots,NamedTuple(),condition,wakeup_lock,wakeup===nothing,IDLE,:none,nothing,nothing,Int64(0),UInt64(0),nothing,false,false)
    created = Stream[]
    try
        _locked(capture) do
            for name in keys(slots)
                slot, spec = getproperty(slots,name), getproperty(declarations,name)
                stream = Stream(core,spec.name;
                    properties=Dict("node.name"=>String(spec.name),"media.type"=>"Application",
                        "media.category"=>"Filter","node.reliable"=>"true"),
                    on_process=stream -> _process!(capture,slot,stream),
                    on_param_changed=(stream,id,parameter) -> _param!(capture,slot,stream,id,parameter),
                    on_state_changed=(stream,old,current,message) -> begin
                        if current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_ERROR ||
                            (current == PipeWireAO.LibPipeWire.PW_STREAM_STATE_UNCONNECTED && old != current)
                            _fail!(capture,:disconnected)
                        end
                        _signal(capture)
                        nothing
                    end)
                push!(created,stream)
                connect!(stream,:input; flags=STREAM_MAP_BUFFERS|STREAM_INACTIVE|STREAM_DONT_RECONNECT|STREAM_NO_CONVERT,
                    params=(ndarray_format(slot.format;schema=slot.schema),_buffer_parameters(slot)...))
                # Keep capture on the main ThreadLoop while participating in
                # graph-synchronous delivery. Set this before creating links.
                update_properties!(stream,Dict("node.async"=>"false"))
                properties = stream_properties(stream)
                get(properties,"node.async",nothing) == "false" ||
                    error("calibration capture requires node.async=false")
                get(properties,"node.loop.class",nothing) == "main" ||
                    error("calibration capture requires node.loop.class=main")
            end
            capture.streams = NamedTuple{keys(slots)}(Tuple(created))
        end
    catch primary
        errors = Exception[primary]
        _locked(capture) do
            for stream in reverse(created)
                try close(stream) catch error; push!(errors,error) end
            end
        end
        capture.own_wakeup && _close_wakeup(capture)
        length(errors) == 1 && rethrow()
        throw(CompositeException(errors))
    end
    return capture
end

function PipeWireAO.start!(capture::Capture)
    _locked(capture) do
        _usable(capture)
        foreach(stream -> set_active!(stream,true),values(capture.streams))
        capture.started = true
    end
    return capture
end

"Arm one genuine HIL exposure before its publication; previous data must already be consumed."
function arm!(capture::Capture, exposure)
    identity = exposure.identity
    identity isa AcquisitionIdentity && identity.sequence > 0 || throw(ArgumentError("capture requires a full positive acquisition identity"))
    start = AdaptiveOpticsSim.AlgorithmGraphs.model_nanoseconds(exposure.timestamp)
    duration = exposure.exposure_duration_nanoseconds
    start >= 0 && duration isa UInt64 && duration > 0 && duration <= UInt64(typemax(Int64)-start) ||
        throw(ArgumentError("capture exposure model start/end must fit nonnegative Int64 nanoseconds"))
    _locked(capture) do
        _usable(capture)
        capture.started || throw(InvalidStateException("capture streams are inactive",:inactive))
        capture.phase == IDLE || throw(InvalidStateException("prior capture is still armed",:armed))
        prior = capture.last
        if prior !== nothing
            same_domain = prior.domain == identity.domain
            same_domain && (identity.generation > prior.generation ||
                (identity.generation == prior.generation && prior.sequence < typemax(UInt64) && identity.sequence == prior.sequence+1)) ||
                throw(ArgumentError("capture identity must advance within its acquisition domain"))
        end
        capture.expected, capture.model_start_ns, capture.duration_ns = identity,start,duration
        for slot in values(capture.slots)
            slot.phase,slot.receipt = ARMED,nothing
        end
        capture.phase = ARMED
    end
    return capture
end

function _snapshot(capture)
    capture.phase == COMPLETE || throw(InvalidStateException("capture is incomplete",:pending))
    return (;arrays=map(slot -> slot.array,capture.slots),
        metadata=map(slot -> something(slot.receipt),capture.slots))
end

"Read owned arrays/provenance after completion; arrays remain valid only until the next arm!."
function snapshot(capture::Capture)
    return _locked(capture) do
        _usable(capture)
        all(slot -> slot.phase == COMPLETE,values(capture.slots)) ||
            throw(InvalidStateException("capture is incomplete",:pending))
        (;arrays=map(slot -> slot.array,capture.slots),metadata=map(slot -> something(slot.receipt),capture.slots))
    end
end

"Wait on the owner task until completion/deadline; `check` must throw on owner loss."
function await!(capture::Capture; deadline::Real, check=()->nothing)
    isfinite(deadline) || throw(ArgumentError("capture deadline must be finite"))
    now = PipeWireAORTC.NativeControlClient.monotonic
    _locked(capture) do
        _usable(capture)
        capture.waiting && throw(InvalidStateException("capture already has a waiter",:waiting))
        capture.waiting = true
    end
    timer = nothing
    try
        timer = Timer(_ -> _signal(capture),max(0.0,Float64(deadline)-now()))
        while true
            check()
            result = _locked(capture) do
                _usable(capture)
                if now() >= deadline
                    _fail!(capture,:deadline)
                    throw(InvalidStateException("calibration capture deadline expired",:deadline))
                end
                if capture.phase == COMPLETE
                    result = _snapshot(capture)
                    capture.last = capture.expected
                    capture.phase = IDLE
                    return result
                end
                capture.phase == ARMED || throw(InvalidStateException("capture is not armed",:unarmed))
                nothing
            end
            result === nothing || return result
            wait(capture.wakeup)
        end
    finally
        timer === nothing || close(timer)
        close_wakeup = _locked(capture) do
            capture.waiting = false
            capture.phase == CLOSED && capture.own_wakeup
        end
        close_wakeup && _close_wakeup(capture)
    end
end

function Base.close(capture::Capture)
    errors = Exception[]
    _locked(capture) do
        capture.phase == CLOSED && return nothing
        capture.phase = CLOSED
        for stream in reverse(values(capture.streams))
            try close(stream) catch error; push!(errors,error) end
        end
        _signal(capture)
    end
    # A live waiter owns its Timer and closes an owned wakeup after unwinding.
    close_wakeup = _locked(() -> capture.own_wakeup && !capture.waiting,capture)
    close_wakeup && _close_wakeup(capture)
    isempty(errors) || throw(CompositeException(errors))
    return nothing
end

end
