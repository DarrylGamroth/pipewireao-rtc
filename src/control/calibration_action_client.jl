"""One correlated native calibration run; dictionaries are saved evidence adapters."""
module CalibrationActionClient
import Clocks

import ..ControlClient
import ..CalibrationActionCodec
import ..AcquisitionLifecycleCodec

export Binding, Connection, connect, request!, complete!, action, document

const Client = ControlClient
const Codec = CalibrationActionCodec
const Lifecycle = AcquisitionLifecycleCodec

struct Binding
    remote::String
    node::String
    owner_pid::UInt32
    instance::Int64
    function Binding(
        remote::AbstractString, node::AbstractString, pid::Integer, instance::Integer
    )
        0 < pid <= typemax(UInt32) || throw(ArgumentError("invalid calibration owner PID"))
        0 < instance <= typemax(Int64) ||
            throw(ArgumentError("invalid calibration owner incarnation"))
        0 < ncodeunits(node) <= 128 && isvalid(node) && !occursin('\0', node) ||
            throw(ArgumentError("invalid calibration action node"))
        new(String(remote), String(node), UInt32(pid), Int64(instance))
    end
end
mutable struct Connection{C}
    client::C
    binding::Binding
    run::UInt64
    serial::UInt64
    timeout_ns::Int64
    command_count::Int
    records::Vector{Dict{String,Any}}
    can_restore::Bool
end
"""
    connect(binding, run, timeout_ns; command_count, kwargs...)

Connect to the exact calibration owner and wait for its Connected state. Use the supplied
run ID, command count and nanosecond timeout for subsequent requests.
"""
function connect(
    binding::Binding,
    run::Integer,
    timeout_ns::Integer;
    command_count::Int,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
    deadline::Union{Int64,Float64} = Base.Checked.checked_add(
        Clocks.time_nanos(clock), Int64(timeout_ns)
    ),
    check = Client.NO_CHECK,
)
    deadline = Client._deadline_ns(deadline)
    0 < run <= typemax(UInt64) && 0 < timeout_ns <= typemax(Int64) ||
        throw(ArgumentError("invalid calibration run or timeout"))
    1 <= command_count <= 4096 || throw(ArgumentError("invalid command contract"))
    client = Client.connect(
        Codec.PROFILE,
        binding.remote,
        binding.node,
        binding.owner_pid,
        binding.instance;
        deadline,
        check,
        clock,
    )
    try
        Client.poll(client, deadline, check) do _
            capability = client.observation.capability
            capability === nothing && return false
            capability.lifecycle in (Lifecycle.Preparing, Lifecycle.Prepared) &&
                return false
            capability.lifecycle === Lifecycle.Connected ||
                error("calibration action owner is unavailable")
            return true
        end
        return Connection(
            client,
            binding,
            UInt64(run),
            UInt64(0),
            Int64(timeout_ns),
            command_count,
            Dict{String,Any}[],
            false,
        )
    catch primary
        try
            close(client)
        catch cleanup
            throw(CompositeException([primary, cleanup]))
        end
        rethrow()
    end
end

_get(value, key) =
    haskey(value, key) ? value[key] : throw(ArgumentError("missing calibration field $key"))
_fields(value, names) = throw(ArgumentError("unexpected calibration fields"))
function _fields(value::AbstractDict, names)
    Set(keys(value)) == Set(names) || throw(ArgumentError("unexpected calibration fields"))
    return value
end
_integer(value, minimum, maximum) = throw(ArgumentError("calibration integer out of range"))
_integer(value::Bool, minimum, maximum) =
    throw(ArgumentError("calibration integer out of range"))
function _integer(value::Integer, minimum, maximum)
    minimum <= value <= maximum || throw(ArgumentError("calibration integer out of range"))
    return UInt64(value)
end
_figure(values, args_overhead::Int) = throw(ArgumentError("invalid calibration figure"))
function _figure(values::AbstractVector, args_overhead::Int)
    !isempty(values) && length(values) <= 4096 ||
        throw(ArgumentError("invalid calibration figure"))
    extent = Codec._add(
        Codec._envelope_base(:request),
        Codec._add(32, Codec._add(args_overhead, Codec._array_size(length(values), 4))),
    )
    extent <= Codec.Envelope._MAX_REQUEST ||
        throw(ArgumentError("calibration figure exceeds request capacity"))
    return map(_figure_value, values)
end
_figure_value(value) = throw(ArgumentError("invalid calibration figure value"))
_figure_value(value::Bool) = throw(ArgumentError("invalid calibration figure value"))
function _figure_value(value::Real)
    isfinite(value) || throw(ArgumentError("invalid calibration figure value"))
    converted = Float32(value)
    isfinite(converted) || throw(ArgumentError("calibration figure exceeds Float32"))
    return converted
end

function _cursor(value)
    _fields(value, ("domain", "generation", "sequence", "model_ns"))
    return Codec.AcquisitionCursor(
        _integer(value["domain"], 1, typemax(UInt64)),
        _integer(value["generation"], 1, typemax(UInt64)),
        _integer(value["sequence"], 0, typemax(UInt64)),
        _integer(value["model_ns"], 0, typemax(Int64)),
    )
end
function _rule(value)
    kind = _get(value, "kind")
    if kind == "immediate"
        _fields(value, ("kind",))
        return Codec.Immediate()
    elseif kind == "discard_exposures"
        _fields(value, ("kind", "frames"))
        return Codec.DiscardExposures(UInt32(_integer(value["frames"], 1, 4096)))
    elseif kind == "model_time"
        _fields(value, ("kind", "duration_ns"))
        return Codec.ModelTime(_integer(value["duration_ns"], 1, typemax(Int64)))
    end
    throw(ArgumentError("unknown calibration settling rule"))
end
"""
    action(value)

Convert a calibration action mapping to the corresponding typed command. Pass a typed
command through unchanged.
"""
function action(value::AbstractDict)
    kind = _get(value, "kind")
    if kind == "hold"
        _fields(value, ("kind",))
        return Codec.Hold()
    elseif kind == "adopt"
        _fields(value, ("kind", "probe", "figure"))
        return Codec.Adopt(
            UInt32(_integer(value["probe"], 0, 16383)), _figure(value["figure"], 24)
        )
    elseif kind == "settle"
        _fields(value, ("kind", "probe", "after", "rule"))
        return Codec.Settle(
            UInt32(_integer(value["probe"], 0, 16383)),
            _cursor(value["after"]),
            _rule(value["rule"]),
        )
    elseif kind == "collect"
        _fields(value, ("kind", "probe", "after", "measurements", "frames"))
        return Codec.Collect(
            UInt32(_integer(value["probe"], 0, 16383)),
            _cursor(value["after"]),
            UInt32(_integer(value["measurements"], 0, 131072)),
            UInt32(_integer(value["frames"], 1, 4096)),
        )
    elseif kind == "restore"
        _fields(value, ("kind", "figure", "rule"))
        rule = _rule(value["rule"])
        return Codec.Restore(
            _figure(value["figure"], Codec._add(8, Codec._rule_size(rule))), rule
        )
    elseif kind == "release"
        _fields(value, ("kind",))
        return Codec.Release()
    end
    throw(ArgumentError("unknown calibration action"))
end
action(value::Codec.AbstractAction) = value
_cursor_document(c) = Dict(
    "domain" => c.domain,
    "generation" => c.generation,
    "sequence" => c.sequence,
    "model_ns" => c.model_ns,
)
_kind(::Codec.Held) = "held"
_kind(::Codec.Adopted) = "adopted"
_kind(::Codec.Settled) = "settled"
_kind(::Codec.Responses) = "responses"
_kind(::Codec.Restored) = "restored"
_kind(::Codec.Released) = "released"
_kind(::Codec.Failed) = "failed"
"""
    document(result)

Convert a typed calibration result into a mapping suitable for JSON reports.
"""
document(r::Codec.Held) = Dict("kind" => "held", "cursor" => _cursor_document(r.cursor))
document(r::Codec.Adopted) = Dict(
    "kind" => "adopted",
    "cursor" => _cursor_document(r.cursor),
    "figure" => r.figure,
    "clipped" => r.clipped,
)
document(r::Codec.Settled) =
    Dict("kind" => "settled", "cursor" => _cursor_document(r.cursor))
document(r::Codec.Responses) = Dict(
    "kind" => "responses",
    "values" => r.values,
    "exposures" => [
        Dict(
            "domain" => e.domain,
            "generation" => e.generation,
            "sequence" => e.sequence,
            "start_model_ns" => e.start_model_ns,
            "duration_ns" => e.duration_ns,
        ) for e in r.exposures
    ],
    "valid" => r.valid,
)
document(r::Codec.Restored) =
    Dict("kind" => "restored", "figure" => r.figure, "clipped" => r.clipped)
document(::Codec.Released) = Dict("kind" => "released")
_reason(reason::Codec.FailureReason) =
    ("cancelled", "endpoint", "invalid_evidence", "probe_clipped")[Int(reason)]
document(r::Codec.Failed) = Dict("kind" => "failed", "reason" => _reason(r.reason))
_validate_figure(::Codec.AbstractResult, count) = nothing
_validate_figure(r::Union{Codec.Adopted,Codec.Restored}, count) =
    length(r.figure) == count ||
    throw(Client.UnknownOutcome("calibration command contract changed"))

_require_completion(::Codec.Completion) = nothing
_require_completion(reply::Codec.Rejection) = throw(
    ArgumentError(
        "native calibration request rejected ($(reply.header.result)): $(reply.message)"
    ),
)
_sent_action(value::AbstractDict, command_action) = value
_sent_action(value, command_action) = _action_document(command_action)
_close_unknown!(connection, primary) = nothing
function _close_unknown!(connection, primary::Client.UnknownOutcome)
    try
        close(connection)
    catch cleanup
        throw(CompositeException([primary, cleanup]))
    end
    return nothing
end

function _complete!(
    connection::Connection,
    value;
    deadline::Union{Int64,Float64} = Base.Checked.checked_add(
        Clocks.time_nanos(connection.client.clock), connection.timeout_ns
    ),
    check = Client.NO_CHECK,
    record::Bool = true,
)
    connection.can_restore = false
    command_action = action(value)
    serial = Base.Checked.checked_add(connection.serial, UInt64(1))
    command = Codec.Command(connection.run, serial, command_action)
    # Keep the complete local validation before identity consumption/submission.
    Codec._preflight(command)
    connection.serial = serial
    reply = Client.request!(connection.client, command; deadline, check)
    _require_completion(reply)
    reply.run == connection.run && reply.serial == serial ||
        throw(Client.UnknownOutcome("calibration run/serial completion mismatch"))
    reply.header.result == 0 && reply.result !== nothing || throw(
        Client.UnknownOutcome("calibration transport completion failed: $(reply.message)"),
    )
    result = reply.result
    _validate_figure(result, connection.command_count)
    _valid_result(command_action, result) ||
        throw(Client.UnknownOutcome("unexpected calibration completion result"))
    record && _record!(connection, value, command_action, reply)
    connection.can_restore = _restore_allowed(result)
    return result
end
_valid_result(a::Codec.AbstractAction, r::Codec.AbstractResult) =
    Codec._operation(a) == Codec._tag(r)
_valid_result(::Codec.AbstractAction, ::Codec.Failed) = true
function _record!(connection, value, command_action, reply)
    result = reply.result
    result_document = document(result)
    sent_action = _sent_action(value, command_action)
    sent = Dict(
        "version" => 1,
        "run" => connection.run,
        "serial" => reply.serial,
        "timeout_ns" => connection.timeout_ns,
        "action" => sent_action,
    )
    # Saved evidence must outlive mutations to caller-owned requests and results.
    push!(
        connection.records,
        deepcopy(
            Dict(
                "request" => sent,
                "reply" => Dict(
                    "version" => 1,
                    "run" => reply.run,
                    "serial" => reply.serial,
                    "result" => result_document,
                ),
            ),
        ),
    )
    return nothing
end
_restore_allowed(::Codec.AbstractResult) = true
_restore_allowed(r::Codec.Restored) = !r.clipped
_restore_allowed(r::Codec.Failed) = r.reason === Codec.InvalidEvidence
# Typed callers retain ordinary structured evidence without serializing it live.
_action_document(::Codec.Hold) = Dict("kind" => "hold")
_action_document(::Codec.Release) = Dict("kind" => "release")
_action_document(a::Codec.Adopt) =
    Dict("kind" => "adopt", "probe" => a.probe, "figure" => a.figure)
_action_document(a::Codec.Collect) = Dict(
    "kind" => "collect",
    "probe" => a.probe,
    "after" => _cursor_document(a.after),
    "measurements" => a.measurements,
    "frames" => a.frames,
)
_rule_document(::Codec.Immediate) = Dict("kind" => "immediate")
_rule_document(r::Codec.DiscardExposures) =
    Dict("kind" => "discard_exposures", "frames" => r.frames)
_rule_document(r::Codec.ModelTime) =
    Dict("kind" => "model_time", "duration_ns" => r.duration_ns)
_action_document(a::Codec.Settle) = Dict(
    "kind" => "settle",
    "probe" => a.probe,
    "after" => _cursor_document(a.after),
    "rule" => _rule_document(a.rule),
)
_action_document(a::Codec.Restore) =
    Dict("kind" => "restore", "figure" => a.figure, "rule" => _rule_document(a.rule))
"""
    complete!(connection, value; kwargs...)

Return the correlated typed terminal result, including an action-level Failed.
"""
function complete!(connection::Connection, value; kwargs...)
    try
        return _complete!(connection, value; kwargs...)
    catch primary
        _close_unknown!(connection, primary)
        rethrow()
    end
end
_successful(result::Codec.AbstractResult) = result
_successful(result::Codec.Failed) =
    throw(ArgumentError("calibration action failed: $(document(result))"))
"""
    request!(connection, value, expected; kwargs...)

Send a calibration action and return its successful result as a mapping. Close the
connection if the completion kind differs from `expected`.
"""
function request!(connection::Connection, value, expected::AbstractString; kwargs...)
    result = _successful(complete!(connection, value; kwargs...))
    if _kind(result) != expected
        connection.can_restore = false
        close(connection)
        throw(Client.UnknownOutcome("unexpected calibration completion result"))
    end
    return document(result)
end
Base.close(connection::Connection) = close(connection.client)

end # module CalibrationActionClient
