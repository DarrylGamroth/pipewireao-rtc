"""Bounded v1 SPA envelope codec for cold RTC owner controls."""
module NativeControlCodec

using PipeWireAO

const SPA = PipeWireAO.SPA
const _MAX_REQUEST = 16 * 1024
const _MAX_LIFECYCLE_REPLY = 64 * 1024
const _MAX_CALIBRATION_REPLY = 128 * 1024
const _VERSION = Int32(1)
const _INVALID_ID = typemax(UInt32)

export ControllerIdentity, RequestHeader, ReplyHeader,
    encode_request, decode_request, encode_completion, decode_completion,
    encode_rejection, decode_rejection

struct ControllerIdentity
    global_id::UInt32
    serial::UInt64
    instance::Int64
    function ControllerIdentity(global_id::UInt32, serial::UInt64, instance::Int64)
        global_id != 0 && global_id != _INVALID_ID ||
            throw(ArgumentError("controller global ID must be assigned and valid"))
        serial > 0 || throw(ArgumentError("controller serial must be positive"))
        instance > 0 || throw(ArgumentError("controller instance must be positive"))
        new(global_id, serial, instance)
    end
end

struct RequestHeader
    version::Int32
    endpoint_instance::Int64
    controller::ControllerIdentity
    token::Int64
    operation::UInt32
    budget_ns::Int64
    function RequestHeader(version::Int32, endpoint_instance::Int64,
            controller::ControllerIdentity, token::Int64,
            operation::UInt32, budget_ns::Int64)
        version == _VERSION || throw(ArgumentError("unsupported control version"))
        endpoint_instance > 0 || throw(ArgumentError("endpoint instance must be positive"))
        token > 0 || throw(ArgumentError("request token must be positive"))
        operation > 0 || throw(ArgumentError("operation must be positive"))
        budget_ns > 0 || throw(ArgumentError("request budget must be positive"))
        new(version, endpoint_instance, controller, token, operation, budget_ns)
    end
end
RequestHeader(controller::ControllerIdentity, endpoint_instance::Int64,
    token::Int64, operation::UInt32, budget_ns::Int64) =
    RequestHeader(_VERSION, endpoint_instance, controller, token, operation, budget_ns)

struct ReplyHeader
    version::Int32
    endpoint_instance::Int64
    controller::Union{Nothing,ControllerIdentity}
    token::Int64
    operation::UInt32
    result::Int32
    function ReplyHeader(version::Int32, endpoint_instance::Int64,
            controller::Union{Nothing,ControllerIdentity}, token::Int64,
            operation::UInt32, result::Int32)
        version == _VERSION || throw(ArgumentError("unsupported control version"))
        endpoint_instance > 0 || throw(ArgumentError("endpoint instance must be positive"))
        token >= 0 || throw(ArgumentError("reply token must be nonnegative"))
        if controller === nothing
            token == 0 && operation == 0 ||
                throw(ArgumentError("sentinel reply identity must be entirely zero"))
        else
            token > 0 && operation > 0 ||
                throw(ArgumentError("correlated reply identity must be complete"))
        end
        new(version, endpoint_instance, controller, token, operation, result)
    end
end
ReplyHeader(controller::ControllerIdentity, endpoint_instance::Int64,
    token::Int64, operation::UInt32, result::Int32) =
    ReplyHeader(_VERSION, endpoint_instance, controller, token, operation, result)
ReplyHeader(endpoint_instance::Int64, result::Int32) =
    ReplyHeader(_VERSION, endpoint_instance, nothing, 0, UInt32(0), result)

const _KINDS = (
    (:request, "pipewireao.rtc.control.request.header", "pipewireao.rtc.control.request.payload"),
    (:completion, "pipewireao.rtc.control.completion.header", "pipewireao.rtc.control.completion.payload"),
    (:rejection, "pipewireao.rtc.control.rejection.header", "pipewireao.rtc.control.rejection.payload"),
)
_names(kind::Symbol) = begin
    for entry in _KINDS
        entry[1] === kind && return (entry[2], entry[3])
    end
    throw(ArgumentError("unknown control record kind"))
end

_limit(::Val{:request}, endpoint) = endpoint === nothing ? _MAX_REQUEST :
    throw(ArgumentError("request records do not accept a reply endpoint"))
function _limit(::Val{:reply}, endpoint)
    endpoint === :lifecycle && return _MAX_LIFECYCLE_REPLY
    endpoint === :calibration && return _MAX_CALIBRATION_REPLY
    throw(ArgumentError("reply endpoint must be :lifecycle or :calibration"))
end
_check_size(pod::PipeWireAO.Pod, limit::Int) = sizeof(pod) <= limit ||
    throw(ArgumentError("control POD exceeds its byte limit"))

function _strict_pod(pod::PipeWireAO.Pod, limit::Int)
    _check_size(pod, limit)
    length(pod.data) >= 8 || throw(ArgumentError("incomplete SPA POD header"))
    declared = reinterpret(UInt32, @view pod.data[1:4])[1]
    Int(declared) + 8 == length(pod.data) ||
        throw(ArgumentError("SPA POD has trailing or truncated bytes"))
    return nothing
end

function _strict_pod_length(pod::PipeWireAO.Pod)
    length(pod.data) >= 8 || throw(ArgumentError("incomplete SPA POD header"))
    declared = reinterpret(UInt32, @view pod.data[1:4])[1]
    Int(declared) + 8 == length(pod.data) ||
        throw(ArgumentError("SPA POD has trailing or truncated bytes"))
    return nothing
end

function _owned_exact_pod(bytes::AbstractVector{UInt8}, limit::Int)
    length(bytes) <= limit || throw(ArgumentError("control POD exceeds its byte limit"))
    length(bytes) >= 8 || throw(ArgumentError("incomplete SPA POD header"))
    start = firstindex(bytes)
    declared = only(reinterpret(UInt32, @view bytes[start:(start + 3)]))
    Int(declared) + 8 == length(bytes) ||
        throw(ArgumentError("SPA POD has trailing or truncated bytes"))
    return PipeWireAO.Pod(bytes)
end

function _scalar(::Type{T}, pod::PipeWireAO.Pod, type::UInt32) where {T}
    PipeWireAO.pod_type(pod) == type || throw(ArgumentError("wrong SPA scalar type"))
    sizeof(pod) == 8 + sizeof(T) || throw(ArgumentError("wrong SPA scalar width"))
    return PipeWireAO.pod_value(T, pod)
end
_int(pod) = _scalar(Int32, pod, SPA.POD_INT)
_long(pod) = _scalar(Int64, pod, SPA.POD_LONG)
_id(pod) = _scalar(SPA.Id, pod, SPA.POD_ID).value
function _string(pod)
    value = PipeWireAO.pod_value(String, pod)
    isvalid(value) || throw(ArgumentError("SPA string is not valid UTF-8"))
    return value
end

function _check_payload(pod::PipeWireAO.Pod, depth::Int)
    _strict_pod_length(pod)
    type = PipeWireAO.pod_type(pod)
    if type == SPA.POD_NONE
        sizeof(pod) == 8 || throw(ArgumentError("invalid None POD"))
        PipeWireAO.pod_value(Nothing, pod)
    elseif type == SPA.POD_BOOL
        sizeof(pod) == 8 + sizeof(Int32) || throw(ArgumentError("wrong SPA Bool width"))
        PipeWireAO.pod_value(Bool, pod)
    elseif type == SPA.POD_ID
        _id(pod)
    elseif type == SPA.POD_INT
        _int(pod)
    elseif type == SPA.POD_LONG
        _long(pod)
    elseif type == SPA.POD_FLOAT
        _scalar(Float32, pod, SPA.POD_FLOAT)
    elseif type == SPA.POD_DOUBLE
        _scalar(Float64, pod, SPA.POD_DOUBLE)
    elseif type == SPA.POD_STRING
        _string(pod)
    elseif type == SPA.POD_BYTES
        PipeWireAO.pod_value(SPA.Bytes, pod)
    elseif type == SPA.POD_ARRAY
        array = PipeWireAO.pod_value(SPA.Array, pod)
        T = eltype(array.values)
        T in (Bool, SPA.Id, Int32, Int64, Float32, Float64) ||
            throw(ArgumentError("unsupported SPA array element type"))
    elseif type == SPA.POD_STRUCT
        depth <= 8 || throw(ArgumentError("payload Struct nesting exceeds eight"))
        value = PipeWireAO.pod_value(SPA.Struct, pod)
        for child in value.values
            child_depth = depth + (PipeWireAO.pod_type(child) == SPA.POD_STRUCT ? 1 : 0)
            _check_payload(child, child_depth)
        end
    else
        throw(ArgumentError("unsupported SPA payload POD type"))
    end
    return nothing
end

function _header_values(header::RequestHeader)
    c = header.controller
    return PipeWireAO.Pod[
        PipeWireAO.Pod(header.version), PipeWireAO.Pod(header.endpoint_instance),
        PipeWireAO.Pod(SPA.Id(c.global_id)), PipeWireAO.Pod(reinterpret(Int64, c.serial)),
        PipeWireAO.Pod(c.instance), PipeWireAO.Pod(header.token),
        PipeWireAO.Pod(SPA.Id(header.operation)), PipeWireAO.Pod(header.budget_ns),
    ]
end
function _header_values(header::ReplyHeader)
    c = header.controller
    global_id = c === nothing ? UInt32(0) : c.global_id
    serial = c === nothing ? UInt64(0) : c.serial
    instance = c === nothing ? Int64(0) : c.instance
    operation = c === nothing ? UInt32(0) : header.operation
    return PipeWireAO.Pod[
        PipeWireAO.Pod(header.version), PipeWireAO.Pod(header.endpoint_instance),
        PipeWireAO.Pod(SPA.Id(global_id)), PipeWireAO.Pod(reinterpret(Int64, serial)),
        PipeWireAO.Pod(instance), PipeWireAO.Pod(header.token),
        PipeWireAO.Pod(SPA.Id(operation)), PipeWireAO.Pod(header.result),
    ]
end

_padded_size(size::Int) = (size + 7) & -8

function _bounded_add(total::Int, amount::Int, limit::Int)
    amount >= 0 && total <= limit || throw(ArgumentError("control POD exceeds its byte limit"))
    amount <= limit - total || throw(ArgumentError("control POD exceeds its byte limit"))
    padded = _padded_size(amount)
    padded <= limit - total || throw(ArgumentError("control POD exceeds its byte limit"))
    return total + padded
end

function _pod_struct_size(values::AbstractVector{PipeWireAO.Pod}, limit::Int)
    total = 8
    total <= limit || throw(ArgumentError("control POD exceeds its byte limit"))
    for value in values
        total = _bounded_add(total, sizeof(value), limit)
    end
    return total
end
_pod_struct_size(value::SPA.Struct, limit::Int) = _pod_struct_size(value.values, limit)

function _validate_payload(value::SPA.Struct)
    for child in value.values
        child_depth = PipeWireAO.pod_type(child) == SPA.POD_STRUCT ? 2 : 1
        _check_payload(child, child_depth)
    end
    return nothing
end

function _envelope_size(kind::Symbol, header_values::Vector{PipeWireAO.Pod}, payload::SPA.Struct, limit::Int)
    hname, pname = _names(kind)
    headersize = _pod_struct_size(header_values, limit)
    payloadsize = _pod_struct_size(payload, limit)
    stringpodsize(name) = 8 + ncodeunits(name) + 1
    body = 8
    for size in (stringpodsize(hname), headersize, stringpodsize(pname), payloadsize)
        body = _bounded_add(body, size, limit)
    end
    total = _bounded_add(24, body, limit)
    return total
end

function _envelope(kind::Symbol, header_values::Vector{PipeWireAO.Pod}, payload::SPA.Struct, limit::Int)
    _envelope_size(kind, header_values, payload, limit) <= limit ||
        throw(ArgumentError("control POD exceeds its byte limit"))
    _validate_payload(payload)
    hname, pname = _names(kind)
    value = SPA.Struct(PipeWireAO.Pod[
        PipeWireAO.Pod(hname), PipeWireAO.Pod(SPA.Struct(header_values)),
        PipeWireAO.Pod(pname), PipeWireAO.Pod(payload),
    ])
    pod = PipeWireAO.Pod(SPA.Parameter(
        SPA.OBJECT_PROPS, SPA.PARAM_PROPS, SPA.Property(SPA.PROP_PARAMS, value),
    ))
    _strict_pod(pod, limit)
    return pod
end

"Encode one bounded request envelope."
function encode_request(header::RequestHeader, payload::SPA.Struct)
    return _envelope(:request, _header_values(header), payload, _MAX_REQUEST)
end

function _encode_reply(kind::Symbol, header::ReplyHeader, payload::SPA.Struct, endpoint::Symbol)
    if kind === :completion
        header.result <= 0 || throw(ArgumentError("completion result must be zero or negative"))
        header.controller === nothing && header.result != 0 &&
            throw(ArgumentError("initial completion sentinel must have result zero"))
    else
        header.result < 0 || throw(ArgumentError("rejection result must be negative"))
    end
    return _envelope(kind, _header_values(header), payload, _limit(Val(:reply), endpoint))
end
encode_completion(header::ReplyHeader, payload::SPA.Struct; endpoint::Symbol=:lifecycle) =
    _encode_reply(:completion, header, payload, endpoint)
encode_rejection(header::ReplyHeader, payload::SPA.Struct; endpoint::Symbol=:lifecycle) =
    _encode_reply(:rejection, header, payload, endpoint)

function _decode(kind::Symbol, pod::PipeWireAO.Pod, limit::Int)
    _strict_pod(pod, limit)
    obj = PipeWireAO.pod_value(SPA.Object, pod)
    obj.type == SPA.OBJECT_PROPS && obj.id == SPA.PARAM_PROPS ||
        throw(ArgumentError("expected SPA Props parameter object"))
    length(obj.properties) == 1 || throw(ArgumentError("expected exactly one Props property"))
    prop = only(obj.properties)
    prop.key == SPA.PROP_PARAMS && prop.flags == 0 ||
        throw(ArgumentError("expected one flags-zero params property"))
    outer = PipeWireAO.pod_value(SPA.Struct, prop.value)
    length(outer.values) == 4 || throw(ArgumentError("wrong envelope arity"))
    hname, pname = _names(kind)
    _string(outer.values[1]) == hname || throw(ArgumentError("wrong header name or order"))
    header = PipeWireAO.pod_value(SPA.Struct, outer.values[2])
    _string(outer.values[3]) == pname || throw(ArgumentError("wrong payload name or order"))
    payload = PipeWireAO.pod_value(SPA.Struct, outer.values[4])
    _check_payload(outer.values[4], 1)
    length(header.values) == 8 || throw(ArgumentError("wrong control header arity"))
    return header.values, payload
end

function _decode_identity(values)
    gid = _id(values[3])
    serial = reinterpret(UInt64, _long(values[4]))
    instance = _long(values[5])
    token = _long(values[6])
    operation = _id(values[7])
    if iszero(gid) && iszero(serial) && iszero(instance) && iszero(token) && iszero(operation)
        return nothing, token, operation
    end
    controller = ControllerIdentity(gid, serial, instance)
    token > 0 && operation > 0 || throw(ArgumentError("partial zero reply identity"))
    return controller, token, operation
end

function decode_request(pod::PipeWireAO.Pod)
    values, payload = _decode(:request, pod, _MAX_REQUEST)
    version = _int(values[1]); endpoint = _long(values[2]); gid = _id(values[3])
    serial = reinterpret(UInt64, _long(values[4])); instance = _long(values[5])
    token = _long(values[6]); operation = _id(values[7]); budget = _long(values[8])
    header = RequestHeader(version, endpoint,
        ControllerIdentity(gid, serial, instance), token, operation, budget)
    return header, payload
end

function _decode_reply(kind::Symbol, pod::PipeWireAO.Pod, endpoint::Symbol)
    values, payload = _decode(kind, pod, _limit(Val(:reply), endpoint))
    version = _int(values[1]); instance = _long(values[2]); result = _int(values[8])
    controller, token, operation = _decode_identity(values)
    header = ReplyHeader(version, instance, controller, token, operation, result)
    if kind === :completion
        result <= 0 || throw(ArgumentError("completion result must be zero or negative"))
        controller === nothing && result != 0 &&
            throw(ArgumentError("initial completion sentinel must have result zero"))
    else
        result < 0 || throw(ArgumentError("rejection result must be negative"))
    end
    return header, payload
end
decode_completion(pod::PipeWireAO.Pod; endpoint::Symbol=:lifecycle) = _decode_reply(:completion, pod, endpoint)
decode_rejection(pod::PipeWireAO.Pod; endpoint::Symbol=:lifecycle) = _decode_reply(:rejection, pod, endpoint)
decode_request(bytes::AbstractVector{UInt8}) = decode_request(_owned_exact_pod(bytes, _MAX_REQUEST))
decode_completion(bytes::AbstractVector{UInt8}; endpoint::Symbol=:lifecycle) =
    decode_completion(_owned_exact_pod(bytes, _limit(Val(:reply), endpoint)); endpoint)
decode_rejection(bytes::AbstractVector{UInt8}; endpoint::Symbol=:lifecycle) =
    decode_rejection(_owned_exact_pod(bytes, _limit(Val(:reply), endpoint)); endpoint)

end # module NativeControlCodec
