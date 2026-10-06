module HILOwnerProtocol

using JSON3

const MAX_REQUEST_BYTES = 16 * 1024
const MAX_REPLY_BYTES = 64 * 1024
const REQUIRED_OPTIONS = (
    "profile", "graph", "rate", "exposure-ns", "remote", "prepared-event",
    "connect-request", "connect-reply", "quit-request", "output",
)

"""Parse the complete-frame simulator command line without loading a plant."""
function parse_options(arguments)
    values = Dict("backend" => "cpu", "frames" => "16", "transport" => "scientific", "correction-diagnostics" => "false", "total-exchanges" => "0", "wall-rate" => "default", "control-node" => "simulator-wfs")
    allowed = Set((REQUIRED_OPTIONS..., "backend", "frames", "transport", "controller-node", "controller-pid", "controller-instance", "correction-diagnostics", "total-exchanges", "wall-rate", "control-node", "control-request", "control-reply"))
    seen = Set{String}()
    iseven(length(arguments)) || throw(ArgumentError("each option requires one value"))
    for index in 1:2:length(arguments)
        name = arguments[index]
        startswith(name, "--") || throw(ArgumentError("expected an option, received $name"))
        key = name[3:end]
        key in allowed || throw(ArgumentError("unknown option $name"))
        key in seen && throw(ArgumentError("duplicate option $name"))
        value = arguments[index + 1]
        isempty(value) && throw(ArgumentError("$name must not be empty"))
        push!(seen, key)
        values[key] = value
    end
    for key in REQUIRED_OPTIONS
        haskey(values, key) || throw(ArgumentError("missing --$key"))
    end
    values["profile"] in ("classic", "copper") || throw(ArgumentError("--profile must be classic or copper"))
    values["backend"] in ("cpu", "cuda", "amdgpu") || throw(ArgumentError("--backend must be cpu, cuda or amdgpu"))
    values["transport"] in ("scientific", "heart") || throw(ArgumentError("--transport must be scientific or heart"))
    values["correction-diagnostics"] in ("true", "false") || throw(ArgumentError("--correction-diagnostics must be true or false"))
    correction_diagnostics = values["correction-diagnostics"] == "true"
    controller_keys = ("controller-node", "controller-pid", "controller-instance")
    present = count(key -> haskey(values, key), controller_keys)
    expected = values["transport"] == "heart" ? 3 : 0
    present == expected || throw(ArgumentError("HEART requires a native controller name, PID and incarnation; scientific transport permits none"))
    controller_node = present == 0 ? nothing : values["controller-node"]
    controller_pid = present == 0 ? nothing : UInt32(parse_positive_integer(values["controller-pid"], "--controller-pid", typemax(UInt32)))
    controller_instance = present == 0 ? nothing : Int64(parse_positive_integer(values["controller-instance"], "--controller-instance", typemax(Int64)))
    controller_node === nothing || occursin(r"^[a-zA-Z0-9_.-]{1,128}$", controller_node) ||
        throw(ArgumentError("invalid HEART controller node name"))
    present == 0 || isabspath(values["remote"]) || throw(ArgumentError("HEART requires an explicit absolute private remote"))
    rate = parse_positive_integer(values["rate"], "--rate", 500)
    frames = parse_positive_integer(values["frames"], "--frames", 256)
    total_exchanges = values["total-exchanges"] == "0" ? frames : parse_positive_integer(values["total-exchanges"], "--total-exchanges", 65536)
    total_exchanges >= frames || throw(ArgumentError("total exchanges must cover the retained prefix"))
    wall_rate = values["wall-rate"] == "default" ? rate : values["wall-rate"] == "unpaced" ? 0 : parse_positive_integer(values["wall-rate"], "--wall-rate", 500)
    wall_rate <= rate || throw(ArgumentError("wall rate must not exceed model rate"))
    sustained = total_exchanges != frames || wall_rate != rate
    sustained && values["transport"] != "scientific" && throw(ArgumentError("sustained mode requires scientific transport"))
    sustained && total_exchanges <= frames && throw(ArgumentError("sustained mode requires total exchanges greater than retained frames"))
    wall_period_ns = wall_rate == 0 ? UInt64(0) : UInt64(rounded_period(wall_rate))
    period = rounded_period(rate)
    exposure = parse_positive_integer(values["exposure-ns"], "--exposure-ns", period)
    paths = [abspath(values[key]) for key in (
        "prepared-event", "connect-request", "connect-reply", "quit-request",
        "output",
    )]
    control_keys = ("control-request", "control-reply")
    control_present = count(key -> haskey(values,key), control_keys)
    control_present in (0,2) || throw(ArgumentError("calibration controls require both file paths"))
    control_paths = control_present == 0 ? (nothing,nothing) : Tuple(abspath(values[key]) for key in control_keys)
    occursin(r"^[a-zA-Z0-9_.-]{1,128}$", values["control-node"]) || throw(ArgumentError("invalid control node name"))
    append!(paths, [path for path in control_paths if path !== nothing])
    prefix = endswith(paths[5],".json") ? paths[5][1:end-5] : paths[5]
    append!(paths,[prefix * ".frames.u16le",prefix * ".commands.f32le"])
    sustained && push!(paths,paths[5] * ".sustained.json")
    length(unique(paths)) == length(paths) || throw(ArgumentError("marker, control and output paths must differ"))
    abspath(values["graph"]) in paths && throw(ArgumentError("plant graph must differ from marker, control and output paths"))
    return (
        profile=Symbol(values["profile"]), backend=Symbol(values["backend"]),
        correction_diagnostics, total_exchanges, wall_rate, wall_period_ns, sustained,
        transport=Symbol(values["transport"]), controller_node, controller_pid, controller_instance,
        graph=abspath(values["graph"]), rate=rate, period_ns=UInt64(period),
        exposure_ns=UInt64(exposure), frames=frames, remote=values["remote"],
        prepared_event=paths[1], connect_request=paths[2], connect_reply=paths[3],
        quit_request=paths[4], control_request=control_paths[1], control_reply=control_paths[2],
        control_node=values["control-node"], output=paths[5],
    )
end

function parse_positive_integer(value, label, maximum)
    occursin(r"^[0-9]+$", value) || throw(ArgumentError("$label must be an integer"))
    parsed = tryparse(Int, value)
    parsed !== nothing && 1 <= parsed <= maximum || throw(ArgumentError("$label must be in 1:$maximum"))
    return parsed
end

"""Round 10⁹/rate to whole nanoseconds without floating point overflow."""
rounded_period(rate::Integer) = div(1_000_000_000 + div(rate, 2), rate)

"""Choose a future wall period after a completed unit; never catch up in bursts."""
function next_deadline(deadline::UInt64, period::UInt64, now::UInt64)
    candidate = Base.checked_add(deadline, period)
    missed = now >= candidate ? div(now - candidate, period) + UInt64(1) : UInt64(0)
    future = Base.checked_add(candidate, Base.checked_mul(missed, period))
    return future, missed
end

"""State owned by the serialized simulator loop, outside PipeWire callbacks."""
mutable struct OwnerState
    running::Bool
    completed::Bool
    sequence::UInt64
    last_request_id::Int64
    deadline_ns::UInt64
end
OwnerState() = OwnerState(false, false, 0, 0, 0)

function response(state, id, operation; error=nothing)
    return (
        version=1, id=id, operation=operation,
        state=state.running ? "running" : "paused", sequence=state.sequence,
        completed=state.completed, ok=error === nothing, error=error,
    )
end

"""Apply one bounded request after any preceding frame/command unit completes."""
function control!(state::OwnerState, payload::AbstractString, now::UInt64,
                  period::UInt64, reset_owner!)
    id = 0
    operation = "invalid"
    request = try
        ncodeunits(payload) <= MAX_REQUEST_BYTES || throw(ArgumentError("request exceeds 16 KiB"))
        parsed = JSON3.read(payload)
        parsed isa JSON3.Object || throw(ArgumentError("request must be an object"))
        parsed
    catch
        return response(state, id, operation; error="invalid JSON request")
    end
    raw_id = get(request, "id", nothing)
    raw_operation = get(request, "operation", nothing)
    raw_id isa Integer && !(raw_id isa Bool) && 1 <= raw_id <= typemax(Int64) && (id = Int64(raw_id))
    raw_operation isa String && ncodeunits(raw_operation) <= 32 && (operation = raw_operation)
    if length(request) != 3 || Set(String.(keys(request))) != Set(("version", "id", "operation")) ||
       get(request, "version", nothing) !== 1 || id == 0 ||
       !(operation in ("resume", "pause", "reset", "status"))
        return response(state, id, operation; error="expected version 1, positive integer id and resume, pause, reset or status")
    end
    # JSON3's untyped parser represents integral floating point numbers as Int.
    # A typed second parse enforces integer JSON tokens rather than accepting
    # identities such as 7.0 or 7e0 and avoids implicit bool-to-integer coercion.
    try
        JSON3.read(payload, NamedTuple{(:version, :id, :operation),Tuple{Int64,Int64,String}})
    catch
        return response(state, id, operation; error="version and id must be integer JSON tokens")
    end
    id > state.last_request_id || return response(state, id, operation; error="stale request id")
    state.last_request_id = id
    if operation == "resume"
        state.completed && return response(state, id, operation; error="finite run completed; reset before resume")
        if !state.running
            state.deadline_ns = Base.checked_add(now, period)
            state.running = true
        end
    elseif operation == "pause"
        state.running = false
        state.deadline_ns = 0
    elseif operation == "reset"
        state.running && return response(state, id, operation; error="reset requires paused state")
        reset_owner!()
        state.sequence = 0
        state.completed = false
        state.deadline_ns = 0
    end
    return response(state, id, operation)
end

"""Publish a bounded JSON reply by rename in the destination directory."""
function write_json_atomic(path::AbstractString, value; maximum=MAX_REPLY_BYTES)
    payload = JSON3.write(value)
    ncodeunits(payload) <= maximum || throw(ArgumentError("JSON response exceeds configured bound"))
    mkpath(dirname(path))
    temporary, io = mktemp(dirname(path))
    try
        write(io, payload, '\n')
        close(io)
        mv(temporary, path; force=true)
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    return nothing
end

"""Reject marker paths from a prior instance before plant preparation."""
function require_fresh_instance(options)
    prefix = endswith(options.output,".json") ? options.output[1:end-5] : options.output
    paths = [options.prepared_event, options.connect_request, options.connect_reply,
        options.quit_request, options.control_request, options.control_reply, options.output,
        prefix * ".frames.u16le",prefix * ".commands.f32le"]
    get(options,:sustained,false) && push!(paths,options.output * ".sustained.json")
    for path in filter(!isnothing,paths)
        (ispath(path) || islink(path)) && throw(ArgumentError("instance path already exists: $path"))
    end
    return nothing
end

end # module HILOwnerProtocol
