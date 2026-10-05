module NativeSourceClient

using PipeWireAO
import ..HILSourceControl
const Control = HILSourceControl

monotonic() = time_ns() / 1.0e9
const STOPPED = UInt32(1)
const RUNNING = UInt32(2)
const InitialSnapshot = Control.snapshot_values(Int64(1), Control.INITIAL,
    Int64(0), Int32(0), Int64(1), Int64(0), false, false, Int64(1), Int64(0))

"Copied observations, accessed only under the owning PipeWire loop lock."
mutable struct Observation{S,R}
    instance::Int64
    run_destination::Base.RefValue{RunControlStatus}
    reset_destination::Base.RefValue{ResetControlStatus}
    snapshot_destination::Base.RefValue{Control.SnapshotValues}
    rejection_destination::Base.RefValue{Control.SnapshotValues}
    snapshot_codec::S
    rejection_codec::R
    run::Union{Nothing,RunControlStatus}
    reset::Union{Nothing,ResetControlStatus}
    snapshot::Union{Nothing,Control.SnapshotValues}
    rejection::Union{Nothing,Control.SnapshotValues}
    failure::Union{Nothing,String}
    pending_kind::Int32
    pending_token::Int64
    last_token::Int64
end

function Observation(instance::Int64)
    snapshot = PropsBuffer(Control.SNAPSHOT_NAMES, InitialSnapshot)
    rejection = PropsBuffer(Control.REJECTION_NAMES, InitialSnapshot)
    return Observation(instance, Ref{RunControlStatus}(), Ref{ResetControlStatus}(),
        Ref(InitialSnapshot), Ref(InitialSnapshot), snapshot, rejection,
        nothing, nothing, nothing, nothing, nothing, Control.INITIAL, 0, 0)
end

function fail!(observation::Observation, message)
    observation.failure === nothing && (observation.failure = String(message))
    return nothing
end

function valid_snapshot(values::Control.SnapshotValues, instance::Int64; rejection=false)
    version, owner, kind, token, result, generation, sequence, running,
        completed, report_generation, report_sequence = values
    version == Control.VERSION && owner == instance && instance > 0 || return false
    generation >= 1 && sequence >= 0 && report_generation >= 1 && report_sequence >= 0 || return false
    report_generation <= generation || return false
    report_generation == generation && report_sequence > sequence && return false
    completed && running && return false
    if kind == Control.INITIAL
        return token == 0 && result == 0
    elseif rejection && kind == Control.INVALID
        return token == 0 && result < 0
    end
    kind in (Control.RUN, Control.RESET, Control.QUERY) && token > 0 || return false
    return rejection ? result < 0 : result <= 0
end

report_ready(values::Control.SnapshotValues) = values[6] == values[10] && values[7] == values[11]

function observe!(observation::Observation, pod::Pod)
    observation.failure === nothing || return nothing
    if parse_run_control_status!(observation.run_destination, pod) == 0
        status = observation.run_destination[]
        if status.version != Control.VERSION || status.completed_token < 0 || status.result > 0 ||
           !(status.actual_state in (STOPPED, RUNNING))
            return fail!(observation, "invalid native run-control status")
        end
        previous = observation.run
        previous !== nothing && status.completed_token < previous.completed_token && return nothing
        if previous !== nothing && status.completed_token == previous.completed_token &&
           (status.result != previous.result || status.actual_state != previous.actual_state)
            return fail!(observation, "conflicting native run-control status")
        end
        observation.run = status
    elseif parse_reset_control_status!(observation.reset_destination, pod) == 0
        status = observation.reset_destination[]
        if status.version != Control.VERSION || status.completed_token < 0 || status.result > 0
            return fail!(observation, "invalid native reset-control status")
        end
        previous = observation.reset
        previous !== nothing && status.completed_token < previous.completed_token && return nothing
        if previous !== nothing && status.completed_token == previous.completed_token && status.result != previous.result
            return fail!(observation, "conflicting native reset-control status")
        end
        observation.reset = status
    elseif parse_props!(observation.snapshot_destination, observation.snapshot_codec, pod) == 0
        values = observation.snapshot_destination[]
        valid_snapshot(values, observation.instance) || return fail!(observation, "invalid source snapshot semantics")
        previous = observation.snapshot
        previous !== nothing && values[4] < previous[4] && return nothing
        if previous !== nothing && values[4] == previous[4] && values != previous
            return fail!(observation, "conflicting source snapshot")
        end
        observation.snapshot = values
    elseif parse_props!(observation.rejection_destination, observation.rejection_codec, pod) == 0
        values = observation.rejection_destination[]
        valid_snapshot(values, observation.instance; rejection=true) ||
            return fail!(observation, "invalid source rejection semantics")
        previous = observation.rejection
        previous !== nothing && values[4] < previous[4] && return nothing
        observation.rejection = values
    else
        fail!(observation, "unrecognized or malformed source Props")
    end
    return nothing
end

function initial_ready(observation::Observation)
    run, reset, snapshot = observation.run, observation.reset, observation.snapshot
    (run === nothing || reset === nothing || snapshot === nothing) && return false
    run.completed_token == 0 && run.result == 0 && run.actual_state == STOPPED ||
        error("source run status is not initially stopped")
    reset.completed_token == 0 && reset.result == 0 || error("source reset status is not initial")
    snapshot[3] == Control.INITIAL && snapshot[4] == 0 && snapshot[5] == 0 &&
        snapshot[7] == 0 && !snapshot[8] && !snapshot[9] && report_ready(snapshot) ||
        error("source snapshot is not initially paused and report-ready")
    return true
end

"One private-remote connection owned by a serialized supervisor caller."
mutable struct Client{O,Q}
    loop::ThreadLoop
    context::Union{Nothing,Context}
    core::Union{Nothing,CoreConnection}
    registry::Union{Nothing,Registry}
    node::Union{Nothing,Node}
    observation::O
    query::Q
    node_name::String
    expected_pid::Int64
    global_id::UInt32
    serial::String
    metadata_ready::Bool
    closed::Bool
end

function registry_identity(properties, node_name::String)
    get(properties, "node.name", nothing) == node_name || error("source node name changed")
    serial = get(properties, "object.serial", "")
    serial_value = tryparse(UInt64, serial)
    serial_value !== nothing && serial_value > 0 || error("source object.serial must be positive")
    return serial
end

function validate_metadata(properties, node_name::String, expected_pid::Int64)
    serial = registry_identity(properties, node_name)
    for (key, expected) in (
        "pipewireao.run-control" => "true", "pipewireao.reset-control" => "true",
        "pipewireao.source-query.version" => "1", "pipewireao.source-snapshot.version" => "1",
        "pipewireao.source-rejection.version" => "1",
        "pipewireao.source-control.owner-pid" => string(expected_pid),
    )
        get(properties, key, nothing) == expected || error("source metadata mismatch: $key")
    end
    instance = tryparse(Int64, get(properties, "pipewireao.source-control.instance", ""))
    instance !== nothing && instance > 0 || error("source instance must be positive")
    return instance, serial
end

function healthy(client::Client)
    client.closed && error("native source client is closed; source outcome unknown")
    client.observation.failure === nothing || error("source outcome unknown: $(client.observation.failure)")
    isrunning(client.loop) || error("source loop stopped; source outcome unknown")
    if client.node !== nothing
        matches = find_globals(something(client.registry); interface="PipeWire:Interface:Node",
            properties=("node.name" => client.node_name,))
        length(matches) == 1 || error("source disappeared or node name became ambiguous; source outcome unknown")
        global_object = only(matches)
        serial = registry_identity(global_object.properties, client.node_name)
        global_object.id == client.global_id && serial == client.serial ||
            error("source identity changed; source outcome unknown")
    end
    return nothing
end

function check_deadline(deadline::Float64, check)
    isfinite(deadline) || throw(ArgumentError("source deadline must be finite"))
    check()
    monotonic() < deadline || error("native source deadline expired; source outcome unknown")
    return nothing
end

function wait_for(client::Client, predicate, deadline::Float64, check)
    while true
        check_deadline(deadline, check)
        value = with_thread_loop_lock(client.loop) do _
            healthy(client)
            predicate()
        end
        check_deadline(deadline, check)
        value === nothing || value === false || return value
        sleep(min(0.005, max(0.0, deadline - monotonic())))
    end
end

"""
    connect(remote, node_name, expected_pid; deadline::Float64, check=()->nothing)

Connect to exactly one source on the specified private remote. Validate its
advertised owner, versions, instance, and initial paused, report-ready state.
`deadline` is an absolute `time_ns() / 1e9` deadline shared by every discovery
and observation stage. `check` can reject loss of a supervised process.
Construction submits no run request. Close the returned client explicitly.
"""
function connect(remote::AbstractString, node_name::AbstractString, expected_pid::Integer;
                 deadline::Float64, check=()->nothing)
    expected_pid > 0 || throw(ArgumentError("expected source owner PID must be positive"))
    isempty(remote) && throw(ArgumentError("a private source remote is required"))
    isempty(node_name) && throw(ArgumentError("a source node name is required"))
    try
        check_deadline(deadline, check)
    catch failure
        throw(ErrorException("native source connection failed during preparation: $(sprint(showerror, failure))"))
    end
    observation = Observation(Int64(1))
    query = PropsBuffer(Control.QUERY_NAMES, Control.query_values(Int64(0), Int64(1)))
    client = Client(ThreadLoop("deployment.source-client"), nothing, nothing, nothing,
        nothing, observation, query, String(node_name), Int64(expected_pid), typemax(UInt32), "", false, false)
    stage = "discovery"
    try
        with_thread_loop_lock(client.loop) do _
            client.context = Context(client.loop)
            client.core = CoreConnection(something(client.context); properties=Dict("remote.name" => String(remote)),
                on_error=(core, id, sequence, failure) -> fail!(observation, sprint(showerror, failure)))
            client.registry = Registry(something(client.core))
        end
        start!(client.loop)
        candidate = wait_for(client, deadline, check) do
            matches = find_globals(something(client.registry); interface="PipeWire:Interface:Node",
                properties=("node.name" => client.node_name,))
            length(matches) > 1 && error("source node name is ambiguous")
            isempty(matches) ? nothing : only(matches)
        end
        stage = "metadata"
        with_thread_loop_lock(client.loop) do _
            check_deadline(deadline, check)
            serial = registry_identity(candidate.properties, client.node_name)
            client.global_id = candidate.id
            client.serial = serial
            client.node = bind(something(client.registry), candidate, Node;
                on_param=(node, sequence, id, index, next, pod) ->
                    (id == SPA.PARAM_PROPS && pod !== nothing && observe!(observation, pod); nothing),
                on_removed=proxy -> fail!(observation, "source proxy was removed"),
                on_error=(proxy, sequence, failure) -> fail!(observation, sprint(showerror, failure)),
                on_info=(node, info) -> begin
                    try
                        info.id == client.global_id || error("source node global ID changed")
                        info.error === nothing || error("source node failed: $(info.error)")
                        if !isempty(info.properties)
                            instance, serial = validate_metadata(info.properties, client.node_name, client.expected_pid)
                            serial == client.serial || error("source node serial changed")
                            client.metadata_ready && instance != observation.instance && error("source instance changed")
                            observation.instance = instance
                            client.metadata_ready = true
                        end
                    catch failure
                        fail!(observation, sprint(showerror, failure))
                    end
                end)
        end
        wait_for(client, () -> client.metadata_ready, deadline, check)
        stage = "initial parameters"
        with_thread_loop_lock(client.loop) do _
            check_deadline(deadline, check)
            healthy(client)
            subscribe_params!(something(client.node), (SPA.PARAM_PROPS,))
            enum_params!(something(client.node), SPA.PARAM_PROPS; count=UInt32(4))
        end
        wait_for(client, () -> initial_ready(observation), deadline, check)
        return client
    catch failure
        detail = with_thread_loop_lock(client.loop) do _
            "run=$(observation.run !== nothing), reset=$(observation.reset !== nothing), snapshot=$(observation.snapshot !== nothing)"
        end
        contextual_failure = ErrorException("native source connection failed during $stage ($detail): $(sprint(showerror, failure))")
        try
            close(client)
        catch cleanup_failure
            throw(CompositeException([contextual_failure, cleanup_failure]))
        end
        throw(contextual_failure)
    end
end

# Support Julia's do-block argument order for the discovery predicate.
wait_for(predicate, client::Client, deadline::Float64, check) = wait_for(client, predicate, deadline, check)

function reply(operation::String, token::Int64, values::Control.SnapshotValues)
    return Dict{String,Any}(
        "version" => 1, "id" => token, "operation" => operation,
        "state" => values[8] ? "running" : "paused", "sequence" => values[7],
        "completed" => values[9], "ok" => values[5] == 0,
        "error" => values[5] == 0 ? nothing : "native source rejected request ($(values[5]))",
        "generation" => values[6], "instance" => values[2],
        "report-ready" => report_ready(values), "report-generation" => values[10],
        "report-sequence" => values[11],
    )
end

function matching_reply(observation::Observation, operation::String, token::Int64, previous::Control.SnapshotValues)
    kind = operation == "status" ? Control.QUERY : operation == "reset" ? Control.RESET : Control.RUN
    snapshot = observation.snapshot
    if snapshot !== nothing && snapshot[4] == token
        snapshot[3] == kind || error("source completion kind does not match request; outcome unknown")
        if kind == Control.RUN
            status = observation.run
            status === nothing && return nothing
            status.completed_token == token || return nothing
            status.result == snapshot[5] && (status.actual_state == RUNNING) == snapshot[8] ||
                error("native run ACK and source snapshot disagree; outcome unknown")
            snapshot[5] == 0 && snapshot[8] != (operation == "resume") &&
                error("source run outcome does not match requested state; outcome unknown")
        elseif kind == Control.RESET
            status = observation.reset
            status === nothing && return nothing
            status.completed_token == token || return nothing
            status.result == snapshot[5] || error("native reset ACK and source snapshot disagree; outcome unknown")
            if snapshot[5] == 0
                snapshot[6] == previous[6] + 1 && snapshot[7] == 0 && !snapshot[8] && !snapshot[9] ||
                    error("source reset did not produce a new paused generation; outcome unknown")
            end
        end
        snapshot[6] >= previous[6] || error("source generation moved backwards; outcome unknown")
        snapshot[6] == previous[6] && snapshot[7] < previous[7] &&
            error("source sequence moved backwards without a reset; outcome unknown")
        if snapshot[5] == 0 && (operation == "reset" || snapshot[9])
            report_ready(snapshot) || error("source completion preceded report publication; outcome unknown")
        end
        return reply(operation, token, snapshot)
    elseif snapshot !== nothing && snapshot[4] > token
        error("source advanced past the requested completion; outcome unknown")
    end
    rejection = observation.rejection
    if rejection !== nothing && rejection[3] == kind && rejection[4] == token && rejection[5] < 0
        return reply(operation, token, rejection)
    end
    return nothing
end

"""
    request!(client, operation::String, token::Int64; deadline::Float64, check=()->nothing)

Submit one `resume`, `pause`, `reset`, or authoritative `status` request and
return its correlated source reply. Tokens must strictly increase. Submission
and observation share the caller's absolute monotonic deadline. A timeout,
transport failure, or incoherent completion has an unknown outcome and disables
further requests on this client; mutations are never retried. Use one serialized
supervisor caller and close the client before releasing its owner processes.
"""
function request!(client::Client, operation::String, token::Int64; deadline::Float64, check=()->nothing)
    operation in ("resume", "pause", "reset", "status") || throw(ArgumentError("unsupported source operation"))
    token > 0 || throw(ArgumentError("source request token must be positive"))
    check_deadline(deadline, check)
    previous = with_thread_loop_lock(client.loop) do _
        healthy(client)
        observation = client.observation
        observation.pending_kind == Control.INITIAL || error("a source request is already pending")
        token > observation.last_token || throw(ArgumentError("source tokens must strictly increase"))
        snapshot = something(observation.snapshot)
        token > snapshot[4] || throw(ArgumentError("source request token is not fresh"))
        kind = operation == "status" ? Control.QUERY : operation == "reset" ? Control.RESET : Control.RUN
        request = operation == "status" ? props!(client.query, Control.query_values(token, observation.instance)) :
            operation == "reset" ? reset_control_request(token) :
            run_control_request(token, operation == "resume" ? :running : :stopped)
        check_deadline(deadline, check)
        observation.pending_kind = kind
        observation.pending_token = token
        observation.last_token = token
        try
            set_param!(something(client.node), SPA.PARAM_PROPS, request)
        catch failure
            fail!(observation, sprint(showerror, failure))
            rethrow()
        end
        snapshot
    end
    try
        return wait_for(client, () -> matching_reply(client.observation, operation, token, previous), deadline, check)
    catch failure
        with_thread_loop_lock(client.loop) do _
            fail!(client.observation, sprint(showerror, failure))
        end
        rethrow()
    finally
        with_thread_loop_lock(client.loop) do _
            client.observation.pending_kind = Control.INITIAL
            client.observation.pending_token = 0
        end
    end
end

"""
    prepare_requests!(client; deadline::Float64, check=()->nothing) -> Client

Compile the concrete request keyword signature during cold preparation, while
the source remains in its initial paused, report-ready state. This sends no
control request and leaves request tokens and source state unchanged. Use a
finite absolute preparation deadline and the same `check` callable used for
subsequent requests. Each live request still needs its own finite deadline.
"""
function prepare_requests!(client::Client; deadline::Float64, check::F=()->nothing) where {F}
    check_deadline(deadline, check)
    with_thread_loop_lock(client.loop) do _
        healthy(client)
        initial_ready(client.observation) || error("source initial parameters are incomplete")
        client.observation.last_token == 0 || error("source requests have already begun")
    end
    keywords = NamedTuple{(:deadline, :check),Tuple{Float64,F}}
    Base.precompile(Core.kwcall, (keywords, typeof(request!), typeof(client), String, Int64)) ||
        error("cannot compile the prepared native source request signature")
    check_deadline(deadline, check)
    with_thread_loop_lock(client.loop) do _
        healthy(client)
        initial_ready(client.observation) || error("source initial state changed during preparation")
    end
    check_deadline(deadline, check)
    return client
end

function Base.close(client::Client)
    client.closed && return nothing
    client.closed = true
    failures = Any[]
    with_thread_loop_lock(client.loop) do _
        for resource in (client.node, client.registry, client.core, client.context)
            resource === nothing && continue
            try
                close(resource)
            catch failure
                push!(failures, failure)
            end
        end
    end
    try
        close(client.loop)
    catch failure
        push!(failures, failure)
    end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

end
