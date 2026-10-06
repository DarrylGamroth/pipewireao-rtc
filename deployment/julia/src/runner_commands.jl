"""Translate legacy runner argv and native typed results at the Julia boundary."""
module RunnerCommands

using ..NativeControlCodec
using ..NativeRunnerCodec

export parse, render

const MAX_ARGUMENTS = 128
const MAX_PARAMETER_BYTES = 512 * 1024 * 1024

function _string(value)
    value isa String || throw(ArgumentError("runner command fields must be Strings"))
    occursin('\0', value) && throw(ArgumentError("runner command fields must not contain NUL"))
    isvalid(value) || throw(ArgumentError("runner command fields must be valid UTF-8"))
    ncodeunits(value) <= 16 * 1024 || throw(ArgumentError("runner field exceeds request limit"))
    return value
end

function _scalar(value_type::String, value::String)
    value_type == "bool" && return value == "true" ? RunnerScalar(:bool, true) :
        value == "false" ? RunnerScalar(:bool, false) : throw(ArgumentError("invalid bool $(repr(value))"))
    value_type == "int" && return RunnerScalar(:int, Base.parse(Int32, value))
    value_type == "long" && return RunnerScalar(:long, Base.parse(Int64, value))
    if value_type == "float"
        number = Base.parse(Float32, value)
        isfinite(number) || throw(ArgumentError("nonfinite float property"))
        return RunnerScalar(:float, reinterpret(UInt32, number))
    elseif value_type == "double"
        number = Base.parse(Float64, value)
        isfinite(number) || throw(ArgumentError("nonfinite double property"))
        return RunnerScalar(:double, reinterpret(UInt64, number))
    elseif value_type == "id"
        return RunnerScalar(:id, Base.parse(UInt32, value))
    elseif value_type == "string"
        return RunnerScalar(:string, value)
    end
    throw(ArgumentError("expected bool, int, long, float, double, id, or string; got $(repr(value_type))"))
end

function _dimensions(value::String)
    dimensions = UInt32[]
    for part in split(value, 'x'; keepempty=true)
        dimension = Base.parse(UInt32, part)
        dimension > 0 || throw(ArgumentError("parameter dimensions must be nonzero"))
        push!(dimensions, dimension)
    end
    isempty(dimensions) && throw(ArgumentError("parameter dimensions must not be empty"))
    bytes = UInt64(4)
    for dimension in dimensions
        bytes <= UInt64(MAX_PARAMETER_BYTES) ÷ dimension ||
            throw(ArgumentError("declared parameter exceeds 536870912 bytes"))
        bytes *= dimension
    end
    return dimensions
end

function _command(fields::Vector{String})
    n = length(fields)
    n == 1 && fields[1] in ("quit", "exit") && return RunnerCommand(:quit)
    n == 1 && fields[1] == "groups" && return RunnerCommand(:groups)
    n == 1 && fields[1] == "status" && return RunnerCommand(:status)
    n == 2 && fields[1] == "properties" && return RunnerCommand(:properties, fields[2])
    n == 3 && fields[1] == "property-generation" &&
        return RunnerCommand(:property_generation, fields[2], fields[3])
    n == 3 && fields[1] == "parameter-generation" &&
        return RunnerCommand(:parameter_generation, fields[2], fields[3])
    n == 2 && fields[1] == "stop" && return RunnerCommand(:stop_group, fields[2])
    n == 2 && fields[1] == "start" && return RunnerCommand(:start_group, fields[2])
    n == 1 && fields[1] == "session-stop" && return RunnerCommand(:session_stop)
    n == 1 && fields[1] == "session-start" && return RunnerCommand(:session_start)
    n == 1 && fields[1] == "source-ended" && return RunnerCommand(:source_ended)
    n == 1 && fields[1] == "reset" && return RunnerCommand(:reset)
    if n == 5 && fields[1] == "property"
        return RunnerCommand(:properties_set, fields[2],
            Dict(fields[3] => _scalar(fields[4], fields[5])))
    end
    if n >= 5 && fields[1] == "properties-set" && (n - 2) % 3 == 0
        values = Dict{String,RunnerScalar}()
        for i in 3:3:n
            name = fields[i]
            haskey(values, name) && throw(ArgumentError("duplicate property $(repr(name))"))
            values[name] = _scalar(fields[i + 1], fields[i + 2])
        end
        return RunnerCommand(:properties_set, fields[2], values)
    end
    if n == 7 && fields[1] == "parameter"
        return RunnerCommand(:parameter, fields[2], fields[3], fields[4],
            _dimensions(fields[5]), fields[6], fields[7])
    end
    throw(ArgumentError("unknown or malformed runner command"))
end

"Parse the existing runner argv command surface without opening parameter paths."
function parse(argv::AbstractVector)
    length(argv) <= MAX_ARGUMENTS || throw(ArgumentError("at most $MAX_ARGUMENTS command fields are allowed"))
    fields = String[_string(field) for field in argv]
    sum(ncodeunits, fields; init=0) <= 16 * 1024 ||
        throw(ArgumentError("runner command exceeds request limit"))
    command = _command(fields)
    # Exercise the codec's exact type, shape and 16 KiB request preflight. This
    # creates only a bounded cold POD; it does not inspect or open an artifact.
    controller = ControllerIdentity(UInt32(1), UInt64(1), Int64(1))
    header = RequestHeader(controller, Int64(1), Int64(1),
        NativeRunnerCodec.operation_id(command), Int64(1))
    NativeRunnerCodec.encode_request(header, command)
    return command
end

_state(state::Lifecycle) = (Offline="Offline", Configuring="Configuring",
    Ready="Ready", Running="Running", Fault="Fault")[Symbol(string(state))]
_group(state::GroupState) = state == NativeRunnerCodec.Stopped ? "stopped" : "running"
_outcome(outcome::Outcome) = lowercase(string(outcome))

function _scalar_json(value::RunnerScalar)
    kind, raw = value.kind, value.value
    kind === :float && return Dict("type" => "float", "bits" => raw)
    kind === :double && return Dict("type" => "double", "bits" => raw)
    return Dict("type" => String(kind), "value" => raw)
end

function _legacy(result::RunnerResult{O}, lifecycle::Lifecycle) where O
    d = result.details
    outcome = _outcome(result.outcome)
    if O === :quit
        return Dict("outcome"=>outcome, "message"=>"shutdown requested", "shutdown"=>true)
    elseif O === :groups
        return Dict("outcome"=>outcome, "groups"=>Dict(k=>_group(v) for (k,v) in d.groups))
    elseif O === :status
        return Dict("outcome"=>outcome, "lifecycle_state"=>_state(lifecycle),
            "running"=>d.running, "owned_nodes"=>d.owned_nodes, "owned_links"=>d.owned_links,
            "discarded_buffers"=>d.discarded_buffers, "discarded_by_sink"=>d.discarded_by_sink)
    elseif O === :properties
        return Dict("outcome"=>outcome, "graph"=>d.graph,
            "properties"=>Dict(k=>_scalar_json(v) for (k,v) in d.properties))
    elseif O in (:property_generation, :parameter_generation)
        return Dict("outcome"=>outcome, "graph"=>d.graph, "node"=>d.node,
            "requested"=>d.requested, "active"=>d.active)
    elseif O in (:stop_group, :start_group)
        return Dict("outcome"=>outcome, "group"=>d.group, "requested"=>_group(d.requested),
            "observed"=>(d.observed === nothing ? nothing : _group(d.observed)))
    elseif O in (:session_stop, :session_start)
        return Dict("outcome"=>outcome, "session_state"=>uppercase(_state(d.state)))
    elseif O in (:source_ended, :reset)
        return Dict("outcome"=>outcome, "session_state"=>_state(d.state))
    elseif O === :properties_set
        return Dict("outcome"=>outcome, "graph"=>d.graph,
            "active_adoption_observed"=>d.active_adoption_observed,
            "property_generations"=>[Dict("node"=>g.node, "requested"=>g.requested,
                "active"=>g.active) for g in d.generations])
    elseif O === :parameter
        generation = d.generation === nothing ? nothing : Dict(
            "requested"=>d.generation[1], "active"=>d.generation[2])
        return Dict("outcome"=>outcome, "graph"=>d.graph, "parameter"=>d.parameter,
            "active_adoption_observed"=>false, "parameter_generations"=>generation)
    end
    error("unhandled native runner result $O")
end

function _response_identity(header, request_id)
    id = request_id === nothing ? string(header.token) : String(request_id)
    # This compatibility field now identifies the native endpoint incarnation;
    # it is not the old per-process JSON socket session UUID.
    return id, "native-runner-instance:$(header.endpoint_instance)"
end

function _render_error(header, lifecycle, failure; request_id)
    id, session_id = _response_identity(header, request_id)
    state = _state(lifecycle)
    return Dict("version"=>1, "id"=>id, "session_id"=>session_id,
        "state"=>state, "result"=>nothing, "ok"=>false,
        "error"=>Dict("field"=>failure.field, "message"=>failure.message))
end

function render(reply::Completion; request_id=nothing)
    if reply.error !== nothing
        return _render_error(reply.header, reply.lifecycle, reply.error; request_id)
    end
    header = reply.header
    reply.result !== nothing || throw(ArgumentError("successful completion has no result"))
    id, session_id = _response_identity(header, request_id)
    return Dict("version"=>1, "id"=>id, "session_id"=>session_id,
        "state"=>_state(reply.lifecycle), "result"=>_legacy(reply.result, reply.lifecycle),
        "ok"=>true, "error"=>nothing)
end

function render(reply::Rejection; request_id=nothing)
    failure = reply.error
    return _render_error(reply.header, reply.lifecycle, failure; request_id)
end

end # module RunnerCommands
