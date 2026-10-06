"""Exact typed request and reply profile for the cold native RTC runner."""
module NativeRunnerCodec

using PipeWireAO
using ..NativeControlCodec

const SPA = PipeWireAO.SPA
const Envelope = NativeControlCodec
const Pod = PipeWireAO.Pod
const MAX_PROPERTIES = 42
const MAX_PARAMETER_BYTES = 512 * 1024 * 1024
const MAX_ROWS = (64 * 1024) ÷ 40
const OPERATIONS = (
    :quit, :groups, :status, :properties, :property_generation,
    :parameter_generation, :stop_group, :start_group, :session_stop,
    :session_start, :source_ended, :reset, :properties_set, :parameter,
)

export RunnerCommand, RunnerScalar, RunnerResult, RunnerError, Completion, Rejection,
    Lifecycle, Outcome, GroupState, operation_id, encode_request, decode_completion, decode_rejection

@enum Lifecycle::UInt32 Offline=1 Configuring=2 Ready=3 Running=4 Fault=5
@enum Outcome::UInt32 Accepted=1 Observed=2 Requested=3 Completed=4 Active=5 Submitted=6
@enum GroupState::UInt32 Stopped=1 GroupRunning=2

"""A scalar's SPA tag and exact bits. Float values use UInt32/UInt64 bits."""
struct RunnerScalar
    kind::Symbol
    value::Union{Bool,Int32,Int64,UInt32,UInt64,String}
    function RunnerScalar(kind::Symbol, value)
        valid = (kind === :bool && value isa Bool) ||
            (kind === :int && value isa Int32) ||
            (kind === :long && value isa Int64) ||
            (kind === :float && value isa UInt32) ||
            (kind === :double && value isa UInt64) ||
            (kind === :id && value isa UInt32) ||
            (kind === :string && value isa String)
        valid || throw(ArgumentError("invalid runner scalar kind/value"))
        kind === :string && _string_check(value; empty=true)
        new(kind, value)
    end
end

"""Closed runner operation with typed tuple arguments; encoding checks exact arity."""
struct RunnerCommand{O,T<:Tuple}
    args::T
end
function RunnerCommand(operation::Symbol, args...)
    operation in OPERATIONS || throw(ArgumentError("unknown runner operation"))
    return RunnerCommand{operation,typeof(args)}(args)
end

struct RunnerResult{O,T<:NamedTuple}
    outcome::Outcome
    details::T
end
struct RunnerError
    field::String
    message::String
end
struct Completion
    header::ReplyHeader
    lifecycle::Lifecycle
    result::Union{Nothing,RunnerResult}
    error::Union{Nothing,RunnerError}
end
struct Rejection
    header::ReplyHeader
    lifecycle::Lifecycle
    error::RunnerError
end

_op(::RunnerCommand{O}) where O = UInt32(findfirst(==(O), OPERATIONS)::Int)
operation_id(command::RunnerCommand) = _op(command)
_pod(x) = Pod(x)
_struct(fields::AbstractVector{Pod}) = SPA.Struct(fields)
_struct(fields::Pod...) = SPA.Struct(Pod[fields...])
_fields(value::SPA.Struct) = value.values
function _fields(pod::Pod)
    PipeWireAO.pod_type(pod) == SPA.POD_STRUCT || throw(ArgumentError("expected runner Struct"))
    return PipeWireAO.pod_value(SPA.Struct, pod).values
end
function _arity(fields, count)
    length(fields) == count || throw(ArgumentError("wrong runner field arity"))
    return fields
end
function _scalar(pod::Pod, type::UInt32, ::Type{T}) where T
    PipeWireAO.pod_type(pod) == type || throw(ArgumentError("wrong runner scalar POD type"))
    sizeof(pod) == 8 + (type == SPA.POD_BOOL ? 4 : sizeof(T)) ||
        throw(ArgumentError("wrong runner scalar POD width"))
    return PipeWireAO.pod_value(T, pod)
end
_id(pod) = _scalar(pod, SPA.POD_ID, SPA.Id).value
_long(pod) = _scalar(pod, SPA.POD_LONG, Int64)
_bool(pod) = _scalar(pod, SPA.POD_BOOL, Bool)
function _string(pod)
    PipeWireAO.pod_type(pod) == SPA.POD_STRING || throw(ArgumentError("expected String POD"))
    value = PipeWireAO.pod_value(String, pod)
    _string_check(value; empty=true)
    return value
end
function _string_check(value::AbstractString; empty::Bool=false, limit::Int=64 * 1024)
    (empty || !isempty(value)) && ncodeunits(value) <= limit &&
        !occursin('\0', value) && isvalid(value) ||
        throw(ArgumentError("invalid runner string or name"))
    return String(value)
end
_name(pod) = _string_check(_string(pod))
function _rows(pod)
    rows = _fields(pod)
    length(rows) <= MAX_ROWS || throw(ArgumentError("runner catalog cannot fit reply"))
    return rows
end
function _unique_rows(parse, ::Type{T}, rows) where T
    output = Dict{String,T}()
    for row in rows
        key, value = parse(row)
        haskey(output, key) && throw(ArgumentError("duplicate runner catalog name"))
        output[key] = value
    end
    return output
end
_lifecycle(pod) = try Lifecycle(_id(pod)) catch; throw(ArgumentError("unknown lifecycle Id")) end
_outcome(pod) = try Outcome(_id(pod)) catch; throw(ArgumentError("unknown outcome Id")) end
_group(pod) = try GroupState(_id(pod)) catch; throw(ArgumentError("unknown group Id")) end
function _optional_long(pod)
    _is_none(pod) && return nothing
    return _long(pod)
end
function _optional_group(pod)
    _is_none(pod) && return nothing
    return _group(pod)
end
function _is_none(pod)
    PipeWireAO.pod_type(pod) == SPA.POD_NONE || return false
    sizeof(pod) == 8 || throw(ArgumentError("wrong None POD width"))
    return true
end
function _scalar_value(pod; finite::Bool)
    kind = PipeWireAO.pod_type(pod)
    scalar = if kind == SPA.POD_BOOL
        RunnerScalar(:bool, _bool(pod))
    elseif kind == SPA.POD_INT
        RunnerScalar(:int, _scalar(pod, SPA.POD_INT, Int32))
    elseif kind == SPA.POD_LONG
        RunnerScalar(:long, _long(pod))
    elseif kind == SPA.POD_FLOAT
        RunnerScalar(:float, reinterpret(UInt32, _scalar(pod, SPA.POD_FLOAT, Float32)))
    elseif kind == SPA.POD_DOUBLE
        RunnerScalar(:double, reinterpret(UInt64, _scalar(pod, SPA.POD_DOUBLE, Float64)))
    elseif kind == SPA.POD_ID
        RunnerScalar(:id, _id(pod))
    elseif kind == SPA.POD_STRING
        RunnerScalar(:string, _string(pod))
    else
        throw(ArgumentError("property must be a native scalar"))
    end
    if finite && scalar.kind === :float
        isfinite(reinterpret(Float32, scalar.value::UInt32)) || throw(ArgumentError("nonfinite property request"))
    elseif finite && scalar.kind === :double
        isfinite(reinterpret(Float64, scalar.value::UInt64)) || throw(ArgumentError("nonfinite property request"))
    end
    return scalar
end
function _scalar_pod(value::RunnerScalar; finite::Bool)
    k, v = value.kind, value.value
    if k === :float
        f = reinterpret(Float32, v::UInt32)
        finite && !isfinite(f) && throw(ArgumentError("nonfinite property request"))
        return _pod(f)
    elseif k === :double
        f = reinterpret(Float64, v::UInt64)
        finite && !isfinite(f) && throw(ArgumentError("nonfinite property request"))
        return _pod(f)
    elseif k === :id
        return _pod(SPA.Id(v::UInt32))
    elseif k === :string
        return _pod(_string_check(v::String; empty=true, limit=16 * 1024))
    end
    return _pod(v)
end
function _parameter_shape(shape)
    shape isa AbstractVector{UInt32} || throw(ArgumentError("parameter shape must be UInt32 dimensions"))
    0 < length(shape) <= 4096 || throw(ArgumentError("invalid parameter rank"))
    bytes = 4
    for axis in shape
        axis > 0 || throw(ArgumentError("zero parameter dimension"))
        bytes <= MAX_PARAMETER_BYTES ÷ Int(axis) || throw(ArgumentError("parameter extent exceeds 512 MiB"))
        bytes *= Int(axis)
    end
    return shape
end

# Inspect borrowed command fields before creating any variable-size PODs. The
# empty common envelope already includes the eight-byte payload Struct header;
# every additional child is padded to eight bytes by SPA.
function _checked_add(total::Int, amount::Int, limit::Int)
    0 <= amount <= limit - total || throw(ArgumentError("runner request exceeds 16 KiB"))
    return total + amount
end
_pod_size(body::Int) = (body + 15) & -8
function _string_size(value; empty::Bool=false)
    value isa AbstractString || throw(ArgumentError("runner field must be a String"))
    (empty || !isempty(value)) && ncodeunits(value) <= 16 * 1024 &&
        !occursin('\0', value) && isvalid(value) ||
        throw(ArgumentError("invalid runner string or name"))
    return _pod_size(ncodeunits(value) + 1)
end
function _scalar_size(value)
    value isa RunnerScalar || throw(ArgumentError("property must be RunnerScalar"))
    if value.kind === :string
        return _string_size(value.value; empty=true)
    elseif value.kind === :float
        isfinite(reinterpret(Float32, value.value::UInt32)) ||
            throw(ArgumentError("nonfinite property request"))
    elseif value.kind === :double
        isfinite(reinterpret(Float64, value.value::UInt64)) ||
            throw(ArgumentError("nonfinite property request"))
    end
    return 16
end
function _preflight_request(command::RunnerCommand{O}, base::Int) where O
    args = command.args
    total = base
    if O in (:quit, :groups, :status, :session_stop, :session_start, :source_ended, :reset)
        _arity(args, 0)
    elseif O in (:properties, :stop_group, :start_group)
        _arity(args, 1)
        total = _checked_add(total, _string_size(args[1]), 16 * 1024)
    elseif O in (:property_generation, :parameter_generation)
        _arity(args, 2)
        for value in args
            total = _checked_add(total, _string_size(value), 16 * 1024)
        end
    elseif O === :properties_set
        _arity(args, 2)
        graph, properties = args
        total = _checked_add(total, _string_size(graph), 16 * 1024)
        properties isa AbstractDict{String,RunnerScalar} ||
            throw(ArgumentError("properties must be a typed String=>RunnerScalar dictionary"))
        1 <= length(properties) <= MAX_PROPERTIES || throw(ArgumentError("invalid property count"))
        rows = 0
        for (name, value) in properties
            row = _pod_size(_checked_add(_string_size(name), _scalar_size(value), 16 * 1024))
            rows = _checked_add(rows, row, 16 * 1024)
        end
        total = _checked_add(total, _pod_size(rows), 16 * 1024)
    elseif O === :parameter
        _arity(args, 6)
        graph, parameter, element_type, shape, schema, path = args
        element_type == "F32_LE" || throw(ArgumentError("unsupported parameter element type"))
        _parameter_shape(shape)
        length(shape) <= (16 * 1024) ÷ 4 || throw(ArgumentError("parameter rank exceeds request"))
        array_bytes = _pod_size(8 + 4 * length(shape))
        total = _checked_add(total, array_bytes, 16 * 1024)
        for (value, empty) in ((graph, false), (parameter, false),
                (element_type, true), (schema, true), (path, false))
            total = _checked_add(total, _string_size(value; empty), 16 * 1024)
        end
    else
        throw(ArgumentError("unknown runner operation"))
    end
    return total
end
function _request_fields(::RunnerCommand{O}, args) where O
    if O in (:quit, :groups, :status, :session_stop, :session_start, :source_ended, :reset)
        _arity(args, 0)
        return _struct()
    elseif O in (:properties, :stop_group, :start_group)
        _arity(args, 1)
        return _struct(_pod(_string_check(args[1]; limit=16 * 1024)))
    elseif O in (:property_generation, :parameter_generation)
        _arity(args, 2)
        return _struct(_pod(_string_check(args[1]; limit=16 * 1024)),
            _pod(_string_check(args[2]; limit=16 * 1024)))
    elseif O === :properties_set
        _arity(args, 2)
        graph, properties = args
        _string_check(graph; limit=16 * 1024)
        properties isa AbstractDict{String,RunnerScalar} ||
            throw(ArgumentError("properties must be a typed String=>RunnerScalar dictionary"))
        1 <= length(properties) <= MAX_PROPERTIES || throw(ArgumentError("invalid property count"))
        rows = Pod[]
        for name in sort!(collect(keys(properties)))
            push!(rows, _pod(_struct(_pod(_string_check(name; limit=16 * 1024)),
                _scalar_pod(properties[name]; finite=true))))
        end
        return _struct(_pod(String(graph)), _pod(_struct(rows)))
    elseif O === :parameter
        _arity(args, 6)
        graph, parameter, element_type, shape, schema, path = args
        _string_check(graph; limit=16 * 1024); _string_check(parameter; limit=16 * 1024)
        _string_check(path; limit=16 * 1024)
        _string_check(element_type; empty=true, limit=16 * 1024)
        _string_check(schema; empty=true, limit=16 * 1024)
        element_type == "F32_LE" || throw(ArgumentError("unsupported parameter element type"))
        _parameter_shape(shape)
        return _struct(_pod(String(graph)), _pod(String(parameter)), _pod(String(element_type)),
            _pod(SPA.Array(SPA.Id.(shape))), _pod(String(schema)), _pod(String(path)))
    end
    throw(ArgumentError("unknown runner operation"))
end

"""Encode one exact runner command under the common 16 KiB request envelope."""
function encode_request(header::RequestHeader, command::RunnerCommand)
    header.operation == _op(command) || throw(ArgumentError("header/command operation mismatch"))
    base = sizeof(Envelope.encode_request(header, _struct()))
    _preflight_request(command, base)
    return Envelope.encode_request(header, _request_fields(command, command.args))
end

function _generation_pair(row)
    fields = _arity(_fields(row), 2)
    return (_long(fields[1]), _long(fields[2]))
end
function _result(operation::UInt32, outcome::Outcome, details::NamedTuple)
    symbol = OPERATIONS[Int(operation)]
    return RunnerResult{symbol,typeof(details)}(outcome, details)
end
function _decode_details(operation::UInt32, fields, state::Lifecycle)
    1 <= operation <= length(OPERATIONS) || throw(ArgumentError("unknown runner operation"))
    if operation == 1
        _arity(fields, 1); _bool(fields[1]) === true || throw(ArgumentError("quit must be true"))
        return _result(operation, Accepted, (shutdown=true,))
    elseif operation == 2
        _arity(fields, 1)
        groups = _unique_rows(GroupState, _rows(fields[1])) do row
            r = _arity(_fields(row), 2); (_name(r[1]), _group(r[2]))
        end
        return _result(operation, Observed, (groups=groups,))
    elseif operation == 3
        _arity(fields, 5)
        sinks = _unique_rows(UInt64, _rows(fields[5])) do row
            r = _arity(_fields(row), 2); (_name(r[1]), reinterpret(UInt64, _long(r[2])))
        end
        return _result(operation, Observed, (running=_bool(fields[1]),
            owned_nodes=reinterpret(UInt64, _long(fields[2])),
            owned_links=reinterpret(UInt64, _long(fields[3])),
            discarded_buffers=reinterpret(UInt64, _long(fields[4])), discarded_by_sink=sinks))
    elseif operation == 4
        _arity(fields, 2)
        properties = _unique_rows(RunnerScalar, _rows(fields[2])) do row
            r = _arity(_fields(row), 2); (_name(r[1]), _scalar_value(r[2]; finite=false))
        end
        return _result(operation, Observed, (graph=_name(fields[1]), properties=properties))
    elseif operation == 5
        _arity(fields, 4)
        return _result(operation, Observed, (graph=_name(fields[1]), node=_name(fields[2]),
            requested=_long(fields[3]), active=_optional_long(fields[4])))
    elseif operation == 6
        _arity(fields, 4)
        return _result(operation, Observed, (graph=_name(fields[1]), node=_name(fields[2]),
            requested=_long(fields[3]), active=_long(fields[4])))
    elseif operation in (7, 8)
        _arity(fields, 3)
        requested = _group(fields[2])
        requested == (operation == 7 ? Stopped : GroupRunning) ||
            throw(ArgumentError("requested group state mismatches operation"))
        return _result(operation, Requested, (group=_name(fields[1]),
            requested=requested, observed=_optional_group(fields[3])))
    elseif operation in (9, 10, 11, 12)
        _arity(fields, 1)
        expected = operation == 10 ? Running : Ready
        _lifecycle(fields[1]) == expected == state ||
            throw(ArgumentError("completed lifecycle mismatches operation/header"))
        return _result(operation, Completed, (state=state,))
    elseif operation == 13
        _arity(fields, 3)
        rows = _rows(fields[2]); names = Set{String}()
        generations = NamedTuple[]
        for row in rows
            r = _arity(_fields(row), 3)
            name = _name(r[1]); name in names && throw(ArgumentError("duplicate generation node"))
            push!(names, name)
            requested = _optional_long(r[2]); active = _optional_long(r[3])
            requested === nothing && active !== nothing && throw(ArgumentError("partial absent generation"))
            push!(generations, (node=name, requested=requested, active=active))
        end
        adopted = _bool(fields[3])
        if adopted
            state == Running && !isempty(generations) &&
                all(g -> g.requested !== nothing && g.active == g.requested, generations) ||
                throw(ArgumentError("active adoption lacks Running observations"))
        end
        return _result(operation, adopted ? Active : Submitted,
            (graph=_name(fields[1]), generations=generations, active_adoption_observed=adopted))
    elseif operation == 14
        _arity(fields, 4)
        generation = _is_none(fields[3]) ? nothing : _generation_pair(fields[3])
        _bool(fields[4]) === false || throw(ArgumentError("parameter adoption flag must be false"))
        return _result(operation, Submitted, (graph=_name(fields[1]),
            parameter=_name(fields[2]), generation=generation, active_adoption_observed=false))
    end
    throw(ArgumentError("unknown runner operation"))
end
function _error(fields)
    _arity(fields, 3)
    return RunnerError(_string(fields[1]), _string(fields[2])), _lifecycle(fields[3])
end

"""Decode an exact typed successful or failed runner completion."""
function decode_completion(input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_completion(input; endpoint=:lifecycle)
    header.controller === nothing && throw(ArgumentError("initial sentinel is not a fresh completion"))
    1 <= header.operation <= length(OPERATIONS) || throw(ArgumentError("unknown runner operation"))
    fields = _fields(payload)
    if header.result < 0
        error, state = _error(fields)
        return Completion(header, state, nothing, error)
    end
    _arity(fields, 3)
    state = _lifecycle(fields[1]); outcome = _outcome(fields[2])
    result = _decode_details(header.operation, _fields(fields[3]), state)
    result.outcome == outcome || throw(ArgumentError("runner outcome mismatches operation/details"))
    return Completion(header, state, result, nothing)
end

"""Decode an independent admission rejection, including the zero sentinel."""
function decode_rejection(input::Union{Pod,AbstractVector{UInt8}})
    header, payload = Envelope.decode_rejection(input; endpoint=:lifecycle)
    error, state = _error(_fields(payload))
    return Rejection(header, state, error)
end

end # module NativeRunnerCodec
