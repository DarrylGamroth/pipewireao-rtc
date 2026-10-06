"""Serialized cold supervisor connection to one native RTC runner incarnation."""
module NativeRunnerClient

using PipeWireAO
import ..NativeControlCodec
import ..NativeRunnerCodec

const Envelope = NativeControlCodec
const Codec = NativeRunnerCodec
const SPA = PipeWireAO.SPA
const PROTOCOL = "pipewireao.rtc-control/1"
const PROFILE = "pipewireao.rtc.runner/1"
const CONTROLLER_PROFILE = "pipewireao.rtc.controller/1"
const CAP_NAMES = (
    "pipewireao.rtc.runner.version", "pipewireao.rtc.runner.instance",
    "pipewireao.rtc.runner.owner-pid", "pipewireao.rtc.runner.lifecycle",
    "pipewireao.rtc.runner.last-token", "pipewireao.rtc.runner.controllers",
)
const MAX_REPLY = 64 * 1024
const INSTANCE_LOCK = ReentrantLock()
const NEXT_INSTANCE = Ref(Int64(0))
monotonic() = time_ns() / 1.0e9

function next_instance()
    return lock(INSTANCE_LOCK) do
        if NEXT_INSTANCE[] == 0
            # Seed on the first actual connection, never during precompilation.
            NEXT_INSTANCE[] = Int64(time_ns() % UInt64(typemax(Int64) - 2)) + 1
        end
        instance = NEXT_INSTANCE[]
        instance < typemax(Int64) || throw(ArgumentError("controller instances exhausted"))
        NEXT_INSTANCE[] += 1
        instance
    end
end

export Client, connect, request!, UnknownOutcome

struct UnknownOutcome <: Exception
    message::String
end
Base.showerror(io::IO, error::UnknownOutcome) = print(io, "native runner outcome unknown: ", error.message)

struct Capability
    lifecycle::Codec.Lifecycle
    last_token::Int64
    controllers::Vector{Envelope.ControllerIdentity}
end

struct ObservedReply{T}
    value::T
    at::Float64
    bytes::Vector{UInt8}
end

"Bounded copied callback observations, read and written under the ThreadLoop lock."
mutable struct Observation
    instance::Int64
    owner_pid::UInt32
    capability::Union{Nothing,Capability}
    completion::Union{Nothing,ObservedReply{Codec.Completion}}
    rejection::Union{Nothing,ObservedReply{Codec.Rejection}}
    completion_seen::Bool
    rejection_seen::Bool
    max_accepted::Int64
    failure::Union{Nothing,String}
    failure_at::Float64
    fatal_failure::Union{Nothing,String}
    pending::Union{Nothing,Envelope.RequestHeader}
    matched_completion::Union{Nothing,ObservedReply{Codec.Completion}}
    matched_rejection::Union{Nothing,ObservedReply{Codec.Rejection}}
end

Observation(instance::Int64, pid::UInt32) = Observation(instance, pid, nothing,
    nothing, nothing, false, false, 0, nothing, Inf, nothing, nothing, nothing, nothing)

function fail!(observation::Observation, message;
        at::Float64=monotonic(), retirement::Bool=false)
    !retirement && observation.fatal_failure === nothing &&
        (observation.fatal_failure = String(message))
    if observation.failure === nothing
        observation.failure = String(message)
        observation.failure_at = at
    end
    return nothing
end

function scalar(pod::Pod, type::UInt32, ::Type{T}) where T
    pod_type(pod) == type && sizeof(pod) == 8 + sizeof(T) ||
        throw(ArgumentError("wrong capability scalar type or width"))
    return pod_value(T, pod)
end
scalar_id(pod) = scalar(pod, SPA.POD_ID, SPA.Id).value
scalar_long(pod) = scalar(pod, SPA.POD_LONG, Int64)

function capability(pod::Pod, observation::Observation)
    sizeof(pod) <= MAX_REPLY || throw(ArgumentError("runner capability exceeds reply bound"))
    props = SPA.Props(pod)
    length(props.values) == length(CAP_NAMES) || throw(ArgumentError("wrong capability arity"))
    values = Dict{String,Pod}()
    for (name, value) in props.values
        name in CAP_NAMES || throw(ArgumentError("unknown capability field"))
        haskey(values, name) && throw(ArgumentError("duplicate capability field"))
        values[name] = value
    end
    scalar(values[CAP_NAMES[1]], SPA.POD_INT, Int32) == 1 || throw(ArgumentError("unsupported capability version"))
    scalar_long(values[CAP_NAMES[2]]) == observation.instance || throw(ArgumentError("capability instance changed"))
    scalar_id(values[CAP_NAMES[3]]) == observation.owner_pid || throw(ArgumentError("capability owner PID changed"))
    state = Codec.Lifecycle(scalar_id(values[CAP_NAMES[4]]))
    token = scalar_long(values[CAP_NAMES[5]])
    token >= 0 || throw(ArgumentError("negative accepted token"))
    rows = pod_value(SPA.Struct, values[CAP_NAMES[6]]).values
    length(rows) <= 32 || throw(ArgumentError("too many controller identities"))
    controllers = Envelope.ControllerIdentity[]
    for row in rows
        fields = pod_value(SPA.Struct, row).values
        length(fields) == 3 || throw(ArgumentError("wrong controller identity arity"))
        identity = Envelope.ControllerIdentity(scalar_id(fields[1]),
            reinterpret(UInt64, scalar_long(fields[2])), scalar_long(fields[3]))
        any(previous -> previous.global_id == identity.global_id, controllers) &&
            throw(ArgumentError("duplicate controller global ID"))
        push!(controllers, identity)
    end
    return Capability(state, token, controllers)
end

same_request(reply::Envelope.ReplyHeader, request::Envelope.RequestHeader) =
    reply.endpoint_instance == request.endpoint_instance &&
    reply.controller == request.controller && reply.token == request.token &&
    reply.operation == request.operation

function observe!(observation::Observation, pod::Pod; at::Union{Nothing,Float64}=nothing)
    # A failure preceding a matching reply cannot be revived by later data.
    observation.fatal_failure === nothing || return nothing
    try
        sizeof(pod) <= MAX_REPLY || throw(ArgumentError("runner Props exceeds reply bound"))
        props = SPA.Props(pod)
        isempty(props.values) && throw(ArgumentError("empty runner Props"))
        name = first(props.values).first
        if name in CAP_NAMES
            cap = capability(pod, observation)
            # A retained enum response can trail a newer subscription event.
            cap.last_token < observation.max_accepted && return nothing
            observation.capability = cap
            observation.max_accepted = cap.last_token
        elseif name == "pipewireao.rtc.control.completion.header"
            header, payload = Envelope.decode_completion(pod; endpoint=:lifecycle)
            header.endpoint_instance == observation.instance || throw(ArgumentError("completion instance changed"))
            if header.controller === nothing
                header.result == 0 && isempty(payload.values) || throw(ArgumentError("invalid initial completion sentinel"))
                observation.completion_seen = true
                return nothing
            end
            value = Codec.decode_completion(pod)
            bytes = copy(pod.data)
            previous = observation.completion
            if previous !== nothing && header.token == previous.value.header.token
                bytes == previous.bytes || throw(ArgumentError("conflicting terminal completion"))
            end
            recorded = ObservedReply(value, at === nothing ? monotonic() : at, bytes)
            if previous === nothing || header.token >= previous.value.header.token
                observation.completion = recorded
            end
            observation.completion_seen = true
            observation.max_accepted = max(observation.max_accepted, header.token)
            pending = observation.pending
            if pending !== nothing && same_request(header, pending)
                matched = observation.matched_completion
                matched === nothing || matched.bytes == bytes ||
                    throw(ArgumentError("conflicting matching completion"))
                # Re-publication must retain the first observation time.
                matched === nothing && observation.failure === nothing &&
                    (observation.matched_completion = recorded)
            end
        elseif name == "pipewireao.rtc.control.rejection.header"
            value = Codec.decode_rejection(pod)
            value.header.endpoint_instance == observation.instance || throw(ArgumentError("rejection instance changed"))
            bytes = copy(pod.data)
            recorded = ObservedReply(value, at === nothing ? monotonic() : at, bytes)
            pending = observation.pending
            if pending !== nothing && same_request(value.header, pending)
                previous = observation.matched_rejection
                previous === nothing || previous.bytes == bytes ||
                    throw(ArgumentError("conflicting matching rejection"))
                previous === nothing && observation.failure === nothing &&
                    (observation.matched_rejection = recorded)
            end
            observation.rejection = recorded
            observation.rejection_seen = true
        else
            throw(ArgumentError("unrecognized runner Props"))
        end
    catch error
        fail!(observation, sprint(showerror, error); at=at === nothing ? monotonic() : at)
    end
    return nothing
end

function matching_reply(observation::Observation, deadline::Float64)
    # Valid completion observed before retirement wins over a later removal.
    # An earlier failure blocks observe!, and a late reply never extends time.
    observation.fatal_failure === nothing || throw(UnknownOutcome(observation.fatal_failure))
    for recorded in (observation.matched_completion, observation.matched_rejection)
        recorded === nothing && continue
        recorded.at <= deadline && recorded.at <= observation.failure_at && return recorded.value
    end
    observation.failure === nothing || throw(UnknownOutcome(observation.failure))
    monotonic() < deadline || throw(UnknownOutcome("absolute request deadline expired"))
    return nothing
end

"One private remote and one serialized pending request; explicitly close after use."
mutable struct Client
    loop::ThreadLoop
    context::Union{Nothing,Context}
    core::Union{Nothing,CoreConnection}
    registry::Union{Nothing,Registry}
    marker::Union{Nothing,Filter}
    marker_node::Union{Nothing,Node}
    node::Union{Nothing,Node}
    observation::Observation
    node_name::String
    marker_name::String
    marker_instance::Int64
    global_id::UInt32
    serial::UInt64
    identity::Union{Nothing,Envelope.ControllerIdentity}
    owner_ready::Bool
    marker_ready::Bool
    last_token::Int64
    closed::Bool
    active::Bool
    request_lock::ReentrantLock
end

function private_remote(remote::AbstractString)
    isabspath(remote) || throw(ArgumentError("native remote must be an absolute socket path"))
    name = basename(remote)
    name in ("", ".", "..") && throw(ArgumentError("remote must name a socket"))
    parent = realpath(dirname(remote))
    directory = lstat(parent)
    uid = ccall(:geteuid, Cuint, ())
    isdir(directory) && directory.uid == uid && directory.mode & 0o077 == 0 ||
        throw(ArgumentError("native remote parent must be owned and private"))
    path = joinpath(parent, name)
    socket = lstat(path)
    issocket(socket) && socket.uid == uid || throw(ArgumentError("native remote must be an owned non-symlink socket"))
    return path
end

function deadline_check(deadline::Float64, check)
    isfinite(deadline) || throw(ArgumentError("native runner deadline must be finite"))
    try
        check()
    catch error
        throw(UnknownOutcome("supervision check failed: $(sprint(showerror, error))"))
    end
    monotonic() < deadline || throw(UnknownOutcome("absolute deadline expired"))
    return nothing
end

function serial(properties, name)
    get(properties, "node.name", nothing) == name || throw(UnknownOutcome("node name changed"))
    value = tryparse(UInt64, get(properties, "object.serial", ""))
    value !== nothing && value > 0 || throw(UnknownOutcome("invalid node object.serial"))
    return value
end

function candidate(client::Client, name)
    matches = find_globals(something(client.registry); interface="PipeWire:Interface:Node",
        properties=("node.name" => name,))
    length(matches) <= 1 || throw(UnknownOutcome("node name is ambiguous"))
    return isempty(matches) ? nothing : only(matches)
end

function healthy(client::Client)
    client.closed && throw(UnknownOutcome("client is closed"))
    client.observation.failure === nothing || throw(UnknownOutcome(client.observation.failure))
    isrunning(client.loop) || throw(UnknownOutcome("client loop stopped"))
    if client.global_id != 0
        owner = candidate(client, client.node_name)
        owner !== nothing && owner.id == client.global_id &&
            serial(owner.properties, client.node_name) == client.serial ||
            throw(UnknownOutcome("runner incarnation disappeared or changed"))
    end
    if client.identity !== nothing
        marker = candidate(client, client.marker_name)
        marker !== nothing && marker.id == client.identity.global_id &&
            serial(marker.properties, client.marker_name) == client.identity.serial ||
            throw(UnknownOutcome("controller incarnation disappeared or changed"))
    end
    return nothing
end

function poll(predicate, client::Client, deadline::Float64, check)
    while true
        deadline_check(deadline, check)
        value = with_thread_loop_lock(client.loop) do _
            healthy(client)
            predicate()
        end
        deadline_check(deadline, check)
        value === nothing || value === false || return value
        sleep(min(0.005, max(0.0, deadline - monotonic())))
    end
end

function node_info!(client::Client, info::NodeInfo; marker::Bool)
    try
        identity = client.identity
        id = marker ? something(identity).global_id : client.global_id
        info.id == id || throw(UnknownOutcome("bound node global ID changed"))
        info.error === nothing || throw(UnknownOutcome("bound node reported an error"))
        info.n_input_ports == 0 && info.n_output_ports == 0 || throw(UnknownOutcome("control node acquired ports"))
        isempty(info.properties) && return nothing
        name = marker ? client.marker_name : client.node_name
        expected_serial = marker ? something(identity).serial : client.serial
        serial(info.properties, name) == expected_serial || throw(UnknownOutcome("bound node serial changed"))
        pid = marker ? UInt32(getpid()) : client.observation.owner_pid
        instance = marker ? client.marker_instance : client.observation.instance
        profile = marker ? CONTROLLER_PROFILE : PROFILE
        for (key, expected) in (
            "pipewireao.rtc-control.protocol" => PROTOCOL,
            "pipewireao.rtc-control.profile" => profile,
            "pipewireao.rtc-control.instance" => string(instance),
            "pipewireao.rtc-control.owner-pid" => string(pid),
        )
            get(info.properties, key, nothing) == expected || throw(UnknownOutcome("control metadata changed: $key"))
        end
        marker ? (client.marker_ready = true) : (client.owner_ready = true)
    catch error
        fail!(client.observation, sprint(showerror, error))
    end
    return nothing
end

"""
    connect(remote, node_name, expected_pid, expected_instance; deadline, check=()->nothing)

Discover one exact private-core runner and export one unique inactive no-port
controller on this connection. Return only after its actual registry incarnation
is verified and appears in the bounded retained capability. No operation is sent.
All discovery/subscription/admission steps share one absolute monotonic deadline.
"""
function connect(remote::AbstractString, node_name::AbstractString,
        expected_pid::Integer, expected_instance::Integer;
        deadline::Float64, check=()->nothing)
    0 < expected_pid <= typemax(UInt32) || throw(ArgumentError("expected owner PID must fit positive Id"))
    0 < expected_instance <= typemax(Int64) || throw(ArgumentError("expected instance must be positive Int64"))
    0 < ncodeunits(node_name) <= 128 && !occursin('\0', node_name) && isvalid(node_name) ||
        throw(ArgumentError("runner node name must be bounded nonempty UTF-8"))
    deadline_check(deadline, check)
    path = private_remote(remote)
    deadline_check(deadline, check)
    instance = next_instance()
    marker_name = "pipewireao.rtc.controller.julia.$(getpid()).$instance"
    observation = Observation(Int64(expected_instance), UInt32(expected_pid))
    client = Client(ThreadLoop("deployment.native-runner"), nothing, nothing, nothing,
        nothing, nothing, nothing, observation, String(node_name), marker_name, instance,
        0, 0, nothing, false, false, 0, false, false, ReentrantLock())
    stage = "connection and controller export"
    try
        with_thread_loop_lock(client.loop) do _
            deadline_check(deadline, check)
            client.context = Context(client.loop)
            client.core = CoreConnection(something(client.context);
                properties=Dict("remote.name" => path),
                on_error=(core, id, sequence, error) ->
                    fail!(observation, sprint(showerror, error); retirement=true))
            client.registry = Registry(something(client.core))
            client.marker = Filter(something(client.core), marker_name; properties=Dict(
                "node.name" => marker_name, "media.class" => "Control",
                "pipewireao.rtc-control.protocol" => PROTOCOL,
                "pipewireao.rtc-control.profile" => CONTROLLER_PROFILE,
                "pipewireao.rtc-control.instance" => string(instance),
                "pipewireao.rtc-control.owner-pid" => string(getpid())))
            connect!(something(client.marker); flags=FILTER_ASYNC | FILTER_INACTIVE)
        end
        start!(client.loop)
        stage = "controller identity"
        marker = poll(client, deadline, check) do; candidate(client, marker_name); end
        with_thread_loop_lock(client.loop) do _
            deadline_check(deadline, check)
            client.identity = Envelope.ControllerIdentity(marker.id, serial(marker.properties, marker_name), instance)
            client.marker_node = bind(something(client.registry), marker, Node;
                on_info=(proxy, info) -> node_info!(client, info; marker=true),
                on_removed=proxy -> fail!(observation, "controller proxy was removed"; retirement=true),
                on_error=(proxy, sequence, error) ->
                    fail!(observation, sprint(showerror, error); retirement=true))
        end
        poll(() -> client.marker_ready, client, deadline, check)
        stage = "runner identity"
        owner = poll(client, deadline, check) do; candidate(client, client.node_name); end
        with_thread_loop_lock(client.loop) do _
            deadline_check(deadline, check)
            owner.id != 0 && owner.id != typemax(UInt32) ||
                throw(UnknownOutcome("runner global ID is not assigned"))
            client.global_id = owner.id
            client.serial = serial(owner.properties, client.node_name)
            client.node = bind(something(client.registry), owner, Node;
                on_info=(proxy, info) -> node_info!(client, info; marker=false),
                on_removed=proxy -> fail!(observation, "runner proxy was removed"; retirement=true),
                on_error=(proxy, sequence, error) ->
                    fail!(observation, sprint(showerror, error); retirement=true),
                on_param=(proxy, sequence, id, index, next, pod) -> begin
                    id == SPA.PARAM_PROPS && pod !== nothing && observe!(observation, pod)
                    nothing
                end)
        end
        poll(() -> client.owner_ready, client, deadline, check)
        stage = "retained parameters and controller admission"
        with_thread_loop_lock(client.loop) do _
            deadline_check(deadline, check)
            healthy(client)
            subscribe_params!(something(client.node), (SPA.PARAM_PROPS,))
            enum_params!(something(client.node), SPA.PARAM_PROPS; count=UInt32(8))
        end
        poll(client, deadline, check) do
            cap = observation.capability
            cap !== nothing && observation.completion_seen && observation.rejection_seen &&
                something(client.identity) in cap.controllers
        end
        return client
    catch error
        contextual = UnknownOutcome("connection failed during $stage: $(sprint(showerror, error))")
        try
            close(client)
        catch cleanup_error
            throw(CompositeException([contextual, cleanup_error]))
        end
        throw(contextual)
    end
end

"""
    request!(client, command::RunnerCommand; deadline, check=()->nothing)

Send exactly once with a new token above all observed accepted tokens and return
a matching typed Completion or Rejection. One absolute deadline covers encoding,
submission and observation. A reply observed before retirement remains resolved;
retirement disables future requests. Failure before reply observation is unknown,
disables this client, and is never retried or rebound. Serialize close with use.
"""
function request!(client::Client, command::Codec.RunnerCommand;
        deadline::Float64, check=()->nothing)
    client.closed && throw(UnknownOutcome("client is closed"))
    trylock(client.request_lock) || throw(ArgumentError("a native runner request is already pending"))
    if client.active
        unlock(client.request_lock)
        throw(ArgumentError("a native runner operation is already active"))
    end
    client.active = true
    submitted = false
    installed = false
    header = nothing
    try
        deadline_check(deadline, check)
        client.closed && throw(UnknownOutcome("client is closed"))
        token = with_thread_loop_lock(client.loop) do _
            healthy(client)
            token = max(client.last_token, client.observation.max_accepted)
            token < typemax(Int64) || throw(ArgumentError("request tokens exhausted"))
            token + 1
        end
        operation = Codec.operation_id(command)
        # Encode/validate locally before occupying a pending owner operation.
        validation_header = Envelope.RequestHeader(something(client.identity),
            client.observation.instance, token, operation, Int64(1))
        Codec.encode_request(validation_header, command)
        # Cold validation/compilation must not inflate the transmitted budget.
        deadline_check(deadline, check)
        remaining = deadline - monotonic()
        budget = max(Int64(1), floor(Int64, min(remaining, 30.0) * 1.0e9))
        header = Envelope.RequestHeader(something(client.identity), client.observation.instance,
            token, operation, budget)
        pod = Codec.encode_request(header, command)
        deadline_check(deadline, check)
        with_thread_loop_lock(client.loop) do _
            healthy(client)
            deadline_check(deadline, check)
            observation = client.observation
            observation.pending === nothing || throw(ArgumentError("a native request is already pending"))
            observation.pending = header
            installed = true
            observation.matched_completion = nothing
            observation.matched_rejection = nothing
            client.last_token = token
            submitted = true
            set_param!(something(client.node), SPA.PARAM_PROPS, pod)
        end
        while true
            reply = with_thread_loop_lock(client.loop) do _
                reply = matching_reply(client.observation, deadline)
                reply !== nothing && return reply
                healthy(client)
                nothing
            end
            reply === nothing || return reply
            deadline_check(deadline, check)
            sleep(min(0.005, max(0.0, deadline - monotonic())))
        end
    catch error
        if submitted || error isa UnknownOutcome
            with_thread_loop_lock(client.loop) do _
                fail!(client.observation, sprint(showerror, error))
            end
            throw(error isa UnknownOutcome ? error : UnknownOutcome(sprint(showerror, error)))
        end
        rethrow()
    finally
        try
            if installed && !client.closed
                with_thread_loop_lock(client.loop) do _
                    if client.observation.pending == header
                        client.observation.pending = nothing
                        client.observation.matched_completion = nothing
                        client.observation.matched_rejection = nothing
                    end
                end
            end
        finally
            client.active = false
            unlock(client.request_lock)
        end
    end
end

function Base.close(client::Client)
    client.closed && return nothing
    trylock(client.request_lock) || throw(ArgumentError("serialize close after the pending native request"))
    if client.active
        unlock(client.request_lock)
        throw(ArgumentError("serialize close after the active native operation"))
    end
    client.active = true
    failures = Any[]
    try
        client.closed = true
        with_thread_loop_lock(client.loop) do _
            for resource in (client.node, client.marker_node, client.marker,
                    client.registry, client.core, client.context)
                resource === nothing && continue
                try
                    close(resource)
                catch error
                    push!(failures, error)
                end
            end
        end
        try
            close(client.loop)
        catch error
            push!(failures, error)
        end
    finally
        client.active = false
        unlock(client.request_lock)
    end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

end # module NativeRunnerClient
