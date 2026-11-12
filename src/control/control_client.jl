"""Serialized cold connection to one native RTC owner incarnation."""
module ControlClient

using PipeWireAO
import ..ControlCodec
import ..Common: remaining_ns
import Clocks

export AbstractProfile, Client, connect, request!, UnknownOutcome

public private_remote

const Envelope = ControlCodec
const SPA = PipeWireAO.SPA
const PROTOCOL = "pipewireao.rtc-control/1"
const CONTROLLER_PROFILE = "pipewireao.rtc.controller/1"
const CONTROLLER_NODE_PREFIX = "pipewireao.rtc.controller."
"""Interface for one versioned owner-control protocol.

A client profile implements `profile_name`, `capability_names`, `lifecycle_type`,
`completion_type`, `rejection_type`, `operation_id`, `encode_request`,
`decode_completion` and `decode_rejection`. Capability names are the ordered
version, instance, owner PID, lifecycle, last token and controller-list fields.
Lifecycle is an enum type. Decoded replies retain the common `ControlCodec`
header and the profile's lifecycle; codecs reject invalid widths, tags and shapes.

Server profiles additionally implement `decode_request`, `encode_completion`,
`encode_rejection` and `encode_failure`. The common endpoint owns envelope
admission and correlation; a profile must not create another request authority.
Profiles used by an owned `ControlEndpoint.Transport` also implement
`command_type`, returning the bounded command type accepted by that protocol.

Independent protocol properties use the traits `reply_endpoint` (`:lifecycle`
or `:calibration`), `maximum_budget` (seconds), and `node_identity` (an optional
immutable String pinned to a bound NodeInfo incarnation). Their defaults suit
ordinary lifecycle profiles. Extend these traits when the wire contract differs,
rather than selecting concrete profile types in the shared client or endpoint.
"""
abstract type AbstractProfile end
function profile_name end
function capability_names end
function lifecycle_type end
function completion_type end
function rejection_type end
function decode_completion end
function decode_rejection end
function operation_id end
function encode_request end
function decode_request end
"Return the bounded command type accepted by an owned endpoint transport."
function command_type end
function encode_completion end
function encode_rejection end
function encode_failure end
encode_failure(profile::AbstractProfile, header, lifecycle, command) =
    encode_failure(profile, header, lifecycle)
reply_endpoint(::AbstractProfile) = :lifecycle
reply_bound(profile::AbstractProfile) =
    Envelope._limit(Val(:reply), reply_endpoint(profile))
maximum_budget(::AbstractProfile) = 30.0
function budget_ns(profile::AbstractProfile, remaining::Float64)
    isfinite(remaining) && remaining > 0 ||
        throw(ArgumentError("invalid native request budget"))
    nanoseconds = min(remaining, maximum_budget(profile)) * 1.0e9
    # Float64(typemax(Int64)) rounds upward to 2^63. Saturate before integer
    # conversion so a valid maximum calibration budget cannot overflow.
    return nanoseconds >= Float64(typemax(Int64)) ? typemax(Int64) :
           max(Int64(1), floor(Int64, nanoseconds))
end
function budget_ns(profile::AbstractProfile, remaining::Int64)
    remaining > 0 || throw(ArgumentError("invalid native request budget"))
    limit = budget_ns(profile, maximum_budget(profile))
    return Int64(min(remaining, limit))
end
"Profile-specific immutable bound NodeInfo identity; common profiles have none."
node_identity(::AbstractProfile, properties, previous) = nothing

const INSTANCE_LOCK = ReentrantLock()
const NEXT_INSTANCE = Ref(Int64(0))
"Return monotonic seconds for existing public seconds-based tool APIs."
monotonic() = Clocks.time_nanos(Clocks.SystemNanoClock()) / 1.0e9
const NO_CHECK = () -> nothing
const SUPERVISION_INTERVAL_NS = Int64(5_000_000)

# Convert only the existing public seconds input. New callers pass Clocks'
# Int64 nanoseconds directly; every internal deadline and receipt stays signed.
_deadline_ns(deadline::Int64) = deadline
function _deadline_ns(deadline::Float64)
    nanoseconds = deadline * 1.0e9
    isfinite(nanoseconds) &&
    Float64(typemin(Int64)) <= nanoseconds < Float64(typemax(Int64)) ||
        throw(ArgumentError("native deadline must fit signed nanoseconds"))
    return floor(Int64, nanoseconds)
end

function next_instance()
    return lock(INSTANCE_LOCK) do
        if NEXT_INSTANCE[] == 0
            # Seed on the first actual connection, never during precompilation.
            # Identity seeds preserve the unsigned bit range of the clock tick;
            # they are protocol identities, not monotonic deadlines.
            seed = reinterpret(UInt64, Clocks.time_nanos(Clocks.SystemNanoClock()))
            NEXT_INSTANCE[] = Int64(seed % UInt64(typemax(Int64) - 2)) + 1
        end
        instance = NEXT_INSTANCE[]
        instance < typemax(Int64) || throw(ArgumentError("controller instances exhausted"))
        NEXT_INSTANCE[] += 1
        instance
    end
end

struct UnknownOutcome <: Exception
    message::String
end
Base.showerror(io::IO, error::UnknownOutcome) =
    print(io, "native control outcome unknown: ", error.message)

struct Capability{L}
    lifecycle::L
    last_token::Int64
    controllers::Vector{Envelope.ControllerIdentity}
end

struct ObservedReply{T}
    value::T
    at::Int64
    bytes::Vector{UInt8}
end

"Bounded copied callback observations, read and written under the ThreadLoop lock."
mutable struct Observation{P<:AbstractProfile,L,C,R}
    profile::P
    instance::Int64
    owner_pid::UInt32
    node_identity::Union{Nothing,String}
    identity_properties::Union{Nothing,Dict{String,String}}
    capability::Union{Nothing,Capability{L}}
    completion::Union{Nothing,ObservedReply{C}}
    rejection::Union{Nothing,ObservedReply{R}}
    completion_seen::Bool
    rejection_seen::Bool
    max_accepted::Int64
    failure::Union{Nothing,String}
    failure_at::Union{Nothing,Int64}
    last_at::Union{Nothing,Int64}
    fatal_failure::Union{Nothing,String}
    pending::Union{Nothing,Envelope.RequestHeader}
    matched_completion::Union{Nothing,ObservedReply{C}}
    matched_rejection::Union{Nothing,ObservedReply{R}}
end

function Observation(profile::P, instance::Int64, pid::UInt32) where {P<:AbstractProfile}
    return Observation{
        P,lifecycle_type(profile),completion_type(profile),rejection_type(profile)
    }(
        profile,
        instance,
        pid,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        false,
        false,
        0,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
    )
end

function fail!(
    observation::Observation,
    message;
    at::Int64 = Clocks.time_nanos(Clocks.SystemNanoClock()),
    retirement::Bool = false,
)
    if observation.last_at !== nothing && at < observation.last_at
        message = "owner observation clock regressed"
        retirement = false
    else
        observation.last_at = at
    end
    !retirement &&
        observation.fatal_failure === nothing &&
        (observation.fatal_failure = String(message))
    if observation.failure === nothing
        observation.failure = String(message)
        observation.failure_at = at
    end
    return nothing
end

function scalar(pod::Pod, type::UInt32, ::Type{T}) where {T}
    pod_type(pod) == type && sizeof(pod) == 8 + sizeof(T) ||
        throw(ArgumentError("wrong capability scalar type or width"))
    return pod_value(T, pod)
end
scalar_id(pod) = scalar(pod, SPA.POD_ID, SPA.Id).value
scalar_long(pod) = scalar(pod, SPA.POD_LONG, Int64)

function capability(pod::Pod, observation::Observation)
    names = capability_names(observation.profile)
    sizeof(pod) <= reply_bound(observation.profile) ||
        throw(ArgumentError("owner capability exceeds reply bound"))
    props = SPA.Props(pod)
    length(props.values) == length(names) || throw(ArgumentError("wrong capability arity"))
    values = Dict{String,Pod}()
    for (name, value) in props.values
        name in names || throw(ArgumentError("unknown capability field"))
        haskey(values, name) && throw(ArgumentError("duplicate capability field"))
        values[name] = value
    end
    scalar(values[names[1]], SPA.POD_INT, Int32) == 1 ||
        throw(ArgumentError("unsupported capability version"))
    scalar_long(values[names[2]]) == observation.instance ||
        throw(ArgumentError("capability instance changed"))
    scalar_id(values[names[3]]) == observation.owner_pid ||
        throw(ArgumentError("capability owner PID changed"))
    state = lifecycle_type(observation.profile)(scalar_id(values[names[4]]))
    token = scalar_long(values[names[5]])
    token >= 0 || throw(ArgumentError("negative accepted token"))
    rows = pod_value(SPA.Struct, values[names[6]]).values
    length(rows) <= 32 || throw(ArgumentError("too many controller identities"))
    controllers = Envelope.ControllerIdentity[]
    for row in rows
        fields = pod_value(SPA.Struct, row).values
        length(fields) == 3 || throw(ArgumentError("wrong controller identity arity"))
        identity = Envelope.ControllerIdentity(
            scalar_id(fields[1]),
            reinterpret(UInt64, scalar_long(fields[2])),
            scalar_long(fields[3]),
        )
        any(previous -> previous.global_id == identity.global_id, controllers) &&
            throw(ArgumentError("duplicate controller global ID"))
        push!(controllers, identity)
    end
    return Capability(state, token, controllers)
end

same_request(reply::Envelope.ReplyHeader, request::Envelope.RequestHeader) =
    reply.endpoint_instance == request.endpoint_instance &&
    reply.controller == request.controller &&
    reply.token == request.token &&
    reply.operation == request.operation

function observe!(
    observation::Observation,
    pod::Pod;
    at::Int64 = Clocks.time_nanos(Clocks.SystemNanoClock()),
)
    names = capability_names(observation.profile)
    # A failure preceding a matching reply cannot be revived by later data.
    observation.fatal_failure === nothing || return nothing
    if observation.last_at !== nothing && at < observation.last_at
        fail!(observation, "owner observation clock regressed"; at)
        return nothing
    end
    observation.last_at = at
    try
        sizeof(pod) <= reply_bound(observation.profile) ||
            throw(ArgumentError("owner Props exceeds reply bound"))
        props = SPA.Props(pod)
        isempty(props.values) && throw(ArgumentError("empty owner Props"))
        name = first(props.values).first
        if name in names
            cap = capability(pod, observation)
            # A retained enum response can trail a newer subscription event.
            cap.last_token < observation.max_accepted && return nothing
            observation.capability = cap
            observation.max_accepted = cap.last_token
        elseif name == "pipewireao.rtc.control.completion.header"
            header, payload = Envelope.decode_completion(
                pod; endpoint = reply_endpoint(observation.profile)
            )
            header.endpoint_instance == observation.instance ||
                throw(ArgumentError("completion instance changed"))
            if header.controller === nothing
                header.result == 0 && isempty(payload.values) ||
                    throw(ArgumentError("invalid initial completion sentinel"))
                observation.completion_seen = true
                return nothing
            end
            value = decode_completion(observation.profile, pod)
            bytes = copy(pod.data)
            previous = observation.completion
            if previous !== nothing && header.token == previous.value.header.token
                bytes == previous.bytes ||
                    throw(ArgumentError("conflicting terminal completion"))
            end
            recorded = ObservedReply{completion_type(observation.profile)}(value, at, bytes)
            if previous === nothing || header.token >= previous.value.header.token
                observation.completion = recorded
            end
            observation.completion_seen = true
            observation.max_accepted = max(observation.max_accepted, header.token)
            pending = observation.pending
            if pending !== nothing && same_request(header, pending)
                matched = observation.matched_completion
                matched === nothing ||
                    matched.bytes == bytes ||
                    throw(ArgumentError("conflicting matching completion"))
                # Re-publication must retain the first observation time.
                matched === nothing &&
                    observation.failure === nothing &&
                    (observation.matched_completion = recorded)
            end
        elseif name == "pipewireao.rtc.control.rejection.header"
            value = decode_rejection(observation.profile, pod)
            value.header.endpoint_instance == observation.instance ||
                throw(ArgumentError("rejection instance changed"))
            bytes = copy(pod.data)
            recorded = ObservedReply(value, at, bytes)
            pending = observation.pending
            if pending !== nothing && same_request(value.header, pending)
                previous = observation.matched_rejection
                previous === nothing ||
                    previous.bytes == bytes ||
                    throw(ArgumentError("conflicting matching rejection"))
                previous === nothing &&
                    observation.failure === nothing &&
                    (observation.matched_rejection = recorded)
            end
            observation.rejection = recorded
            observation.rejection_seen = true
        else
            throw(ArgumentError("unrecognized owner Props"))
        end
    catch error
        fail!(observation, sprint(showerror, error); at)
    end
    return nothing
end

function matching_reply(
    observation::Observation,
    deadline::Int64;
    now::Int64 = Clocks.time_nanos(Clocks.SystemNanoClock()),
)
    # Valid completion observed before retirement wins over a later removal.
    # An earlier failure blocks observe!, and a late reply never extends time.
    observation.fatal_failure === nothing ||
        throw(UnknownOutcome(observation.fatal_failure))
    for recorded in (observation.matched_completion, observation.matched_rejection)
        recorded === nothing && continue
        recorded.at <= deadline &&
            (observation.failure_at === nothing || recorded.at <= observation.failure_at) &&
            return recorded.value
    end
    observation.failure === nothing || throw(UnknownOutcome(observation.failure))
    now < deadline || throw(UnknownOutcome("absolute request deadline expired"))
    return nothing
end

"One private remote and one serialized pending request; explicitly close after use."
mutable struct Client{O<:Observation,C<:Clocks.AbstractNanoClock}
    loop::ThreadLoop
    context::Union{Nothing,Context}
    core::Union{Nothing,CoreConnection}
    registry::Union{Nothing,Registry}
    marker::Union{Nothing,Filter}
    marker_node::Union{Nothing,Node}
    node::Union{Nothing,Node}
    observation::O
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
    wakeup::Base.AsyncCondition
    wakeup_lock::ReentrantLock
    timer::Union{Nothing,TimerSource}
    registry_listener::Union{Nothing,ManagedListener}
    clock::C
    last_at::Union{Nothing,Int64}
end


# Preserve the positional construction surface while retaining a concrete
# observation/profile type; the original nonparametric constructor converted IDs.
function Client(
    loop::ThreadLoop,
    context,
    core,
    registry,
    marker,
    marker_node,
    node,
    observation::O,
    node_name::String,
    marker_name::String,
    marker_instance::Int64,
    global_id::Integer,
    serial::Integer,
    identity,
    owner_ready::Bool,
    marker_ready::Bool,
    last_token::Int64,
    closed::Bool,
    active::Bool,
    request_lock::ReentrantLock;
    clock::C = Clocks.SystemNanoClock(),
) where {O<:Observation,C<:Clocks.AbstractNanoClock}
    return Client{O,C}(
        loop,
        context,
        core,
        registry,
        marker,
        marker_node,
        node,
        observation,
        node_name,
        marker_name,
        marker_instance,
        UInt32(global_id),
        UInt64(serial),
        identity,
        owner_ready,
        marker_ready,
        last_token,
        closed,
        active,
        request_lock,
        Base.AsyncCondition(),
        ReentrantLock(),
        nothing,
        nothing,
        clock,
        nothing,
    )
end

"""
    private_remote(remote)

Resolve and validate an absolute path to a caller-owned PipeWire socket.
Require a private parent directory and an owned socket without a symlink.
"""
function private_remote(remote::AbstractString)
    isabspath(remote) ||
        throw(ArgumentError("native remote must be an absolute socket path"))
    name = basename(remote)
    name in ("", ".", "..") && throw(ArgumentError("remote must name a socket"))
    parent = realpath(dirname(remote))
    directory = lstat(parent)
    uid = ccall(:geteuid, Cuint, ())
    isdir(directory) && directory.uid == uid && directory.mode & 0o077 == 0 ||
        throw(ArgumentError("native remote parent must be owned and private"))
    path = joinpath(parent, name)
    socket = lstat(path)
    issocket(socket) && socket.uid == uid ||
        throw(ArgumentError("native remote must be an owned non-symlink socket"))
    return path
end

function _supervise(check)
    try
        check()
    catch error
        throw(UnknownOutcome("supervision check failed: $(sprint(showerror, error))"))
    end
    return nothing
end

function deadline_check(deadline::Int64, check, current::Int64)
    _supervise(check)
    current < deadline || throw(UnknownOutcome("absolute deadline expired"))
    return nothing
end

# Existing one-shot/server callers still expose seconds. Their input conversion
# is confined here until their owned loops migrate to signed sampled values.
function deadline_check(deadline::Union{Int64,Float64}, check)
    deadline = _deadline_ns(deadline)
    _supervise(check)
    return deadline_check(deadline, NO_CHECK, Clocks.time_nanos(Clocks.SystemNanoClock()))
end

function deadline_check(client::Client, deadline::Int64, check, current::Int64)
    if client.last_at !== nothing && current < client.last_at
        throw(UnknownOutcome("native client clock regressed"))
    end
    client.last_at = current
    return deadline_check(deadline, check, current)
end

"Validate fresh time after supervision/encoding and immediately before native I/O."
function deadline_check(client::Client, deadline::Int64, check)
    _supervise(check)
    return deadline_check(client, deadline, NO_CHECK, Clocks.time_nanos(client.clock))
end

function serial(properties, name)
    get(properties, "node.name", nothing) == name ||
        throw(UnknownOutcome("node name changed"))
    value = tryparse(UInt64, get(properties, "object.serial", ""))
    value !== nothing && value > 0 || throw(UnknownOutcome("invalid node object.serial"))
    return value
end

function candidate(client::Client, name)
    matches = find_globals(
        something(client.registry);
        interface = "PipeWire:Interface:Node",
        properties = ("node.name" => name,),
    )
    length(matches) <= 1 || throw(UnknownOutcome("node name is ambiguous"))
    return isempty(matches) ? nothing : only(matches)
end

function healthy(client::Client)
    client.closed && throw(UnknownOutcome("client is closed"))
    client.observation.failure === nothing ||
        throw(UnknownOutcome(client.observation.failure))
    isrunning(client.loop) || throw(UnknownOutcome("client loop stopped"))
    if client.global_id != 0
        owner = candidate(client, client.node_name)
        owner !== nothing &&
        owner.id == client.global_id &&
        serial(owner.properties, client.node_name) == client.serial ||
            throw(UnknownOutcome("owner incarnation disappeared or changed"))
    end
    if client.owner_ready
        node_identity(
            client.observation.profile,
            something(client.observation.identity_properties),
            client.observation.node_identity,
        ) == client.observation.node_identity ||
            throw(UnknownOutcome("bound owner identity changed"))
    end
    if client.identity !== nothing
        marker = candidate(client, client.marker_name)
        marker !== nothing &&
        marker.id == client.identity.global_id &&
        serial(marker.properties, client.marker_name) == client.identity.serial ||
            throw(UnknownOutcome("controller incarnation disappeared or changed"))
    end
    return nothing
end

function wake!(client::Client)
    # AsyncCondition's documented foreign-thread notification mechanism. Native
    # callbacks never schedule Julia tasks or execute a calibration consumer.
    lock(client.wakeup_lock) do
        isopen(client.wakeup) && ccall(:uv_async_send, Cint, (Ptr{Cvoid},), client.wakeup)
    end
    return nothing
end

function fail!(client::Client, message; kwargs...)
    fail!(client.observation, message; at = Clocks.time_nanos(client.clock), kwargs...)
    wake!(client)
    return nothing
end

function poll(f, client::Client, deadline::Int64, check; verify_health = true)
    # Registry, reply and timer callbacks wake the same waiting task.
    timer = client.timer
    if timer === nothing
        timer = TimerSource(client.loop, (_, _) -> wake!(client))
        client.timer = timer
    end
    try
        while true
            current = Clocks.time_nanos(client.clock)
            verify_health && deadline_check(client, deadline, check, current)
            remaining = remaining_ns(deadline, current)
            if remaining > 0
                delay = check === NO_CHECK ? remaining : min(remaining, SUPERVISION_INTERVAL_NS)
                update_timer!(timer; delay = delay / 1.0e9)
            end
            value = with_thread_loop_lock(client.loop) do _
                verify_health && healthy(client)
                f(current)
            end
            if value !== nothing && value !== false
                verify_health && deadline_check(client, deadline, check, current)
                return value
            end
            deadline_check(client, deadline, check, current)
            wait(client.wakeup)
        end
    finally
        update_timer!(timer; delay = nothing)
    end
end

function node_info!(client::Client, info::NodeInfo; marker::Bool)
    try
        identity = client.identity
        id = marker ? something(identity).global_id : client.global_id
        info.id == id || throw(UnknownOutcome("bound node global ID changed"))
        info.error === nothing || throw(UnknownOutcome("bound node reported an error"))
        info.n_input_ports == 0 && info.n_output_ports == 0 ||
            throw(UnknownOutcome("control node acquired ports"))
        (info.change_mask & NODE_CHANGE_PROPERTIES) == 0 && return nothing
        name = marker ? client.marker_name : client.node_name
        expected_serial = marker ? something(identity).serial : client.serial
        serial(info.properties, name) == expected_serial ||
            throw(UnknownOutcome("bound node serial changed"))
        pid = marker ? UInt32(getpid()) : client.observation.owner_pid
        instance = marker ? client.marker_instance : client.observation.instance
        profile = marker ? CONTROLLER_PROFILE : profile_name(client.observation.profile)
        for (key, expected) in (
            "pipewireao.rtc-control.protocol" => PROTOCOL,
            "pipewireao.rtc-control.profile" => profile,
            "pipewireao.rtc-control.instance" => string(instance),
            "pipewireao.rtc-control.owner-pid" => string(pid),
        )
            get(info.properties, key, nothing) == expected ||
                throw(UnknownOutcome("control metadata changed: $key"))
        end
        if marker
            client.marker_ready = true
        else
            client.observation.node_identity = node_identity(
                client.observation.profile,
                info.properties,
                client.observation.node_identity,
            )
            client.observation.identity_properties = info.properties
            client.owner_ready = true
        end
    catch error
        fail!(
            client.observation,
            sprint(showerror, error);
            at = Clocks.time_nanos(client.clock),
        )
    finally
        wake!(client)
    end
    return nothing
end

_check_controller_instance(::Nothing) = nothing
_check_controller_instance(::Bool) =
    throw(ArgumentError("controller instance must be positive Int64"))
_check_controller_instance(value::Integer) =
    0 < value <= typemax(Int64) ||
    throw(ArgumentError("controller instance must be positive Int64"))


"""
    connect(profile, remote, node_name, expected_pid, expected_instance; deadline, check=()->nothing)

Discover one exact private-core owner and export one unique inactive no-port
controller on this connection. Return only after its actual registry incarnation
is verified and appears in the bounded retained capability. No operation is sent.
All discovery/subscription/admission steps share one absolute monotonic deadline.
Pass an `Int64` deadline in nanoseconds from `clock::Clocks.AbstractNanoClock`.
The `Float64` seconds signature is retained as an entry compatibility boundary;
injected clocks and deadlines must belong to the same monotonic domain.
"""
function connect(
    profile::AbstractProfile,
    remote::AbstractString,
    node_name::AbstractString,
    expected_pid::Integer,
    expected_instance::Integer;
    deadline::Union{Int64,Float64},
    check = NO_CHECK,
    controller_instance::Union{Nothing,Integer} = nothing,
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    deadline = _deadline_ns(deadline)
    0 < expected_pid <= typemax(UInt32) ||
        throw(ArgumentError("expected owner PID must fit positive Id"))
    0 < expected_instance <= typemax(Int64) ||
        throw(ArgumentError("expected instance must be positive Int64"))
    0 < ncodeunits(node_name) <= 128 && !occursin('\0', node_name) && isvalid(node_name) ||
        throw(ArgumentError("owner node name must be bounded nonempty UTF-8"))
    _supervise(check)
    started = Clocks.time_nanos(clock)
    deadline_check(deadline, NO_CHECK, started)
    path = private_remote(remote)
    _supervise(check)
    current = Clocks.time_nanos(clock)
    current >= started || throw(UnknownOutcome("native client clock regressed"))
    deadline_check(deadline, NO_CHECK, current)
    _check_controller_instance(controller_instance)
    instance =
        controller_instance === nothing ? next_instance() : Int64(controller_instance)
    marker_name = "$(CONTROLLER_NODE_PREFIX)julia.$(getpid()).$instance"
    observation = Observation(profile, Int64(expected_instance), UInt32(expected_pid))
    client = Client(
        ThreadLoop("deployment.native-control"),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        observation,
        String(node_name),
        marker_name,
        instance,
        0,
        0,
        nothing,
        false,
        false,
        0,
        false,
        false,
        ReentrantLock();
        clock,
    )
    client.last_at = current
    stage = "connection and controller export"
    try
        with_thread_loop_lock(client.loop) do _
            deadline_check(client, deadline, check)
            client.context = Context(client.loop)
            client.core = CoreConnection(
                something(client.context);
                properties = Dict("remote.name" => path),
                on_error = (core, id, sequence, error) ->
                    fail!(client, sprint(showerror, error); retirement = true),
            )
            client.registry = Registry(something(client.core))
            client.registry_listener = add_listener!(
                client.registry;
                on_global_added = (_, _) -> wake!(client),
                on_global_removed = (_, _) -> wake!(client),
            )
            client.marker = Filter(
                something(client.core),
                marker_name;
                properties = Dict(
                    "node.name" => marker_name,
                    "media.class" => "Control",
                    "pipewireao.rtc-control.protocol" => PROTOCOL,
                    "pipewireao.rtc-control.profile" => CONTROLLER_PROFILE,
                    "pipewireao.rtc-control.instance" => string(instance),
                    "pipewireao.rtc-control.owner-pid" => string(getpid()),
                ),
            )
            connect!(something(client.marker); flags = FILTER_ASYNC | FILTER_INACTIVE)
        end
        start!(client.loop)
        stage = "controller identity"
        marker = poll(client, deadline, check) do _
            candidate(client, marker_name)
        end
        with_thread_loop_lock(client.loop) do _
            deadline_check(client, deadline, check)
            client.identity = Envelope.ControllerIdentity(
                marker.id, serial(marker.properties, marker_name), instance
            )
            client.marker_node = bind(
                something(client.registry),
                marker,
                Node;
                on_info = (proxy, info) -> node_info!(client, info; marker = true),
                on_removed = proxy ->
                    fail!(client, "controller proxy was removed"; retirement = true),
                on_error = (proxy, sequence, error) ->
                    fail!(client, sprint(showerror, error); retirement = true),
            )
        end
        poll(_ -> client.marker_ready, client, deadline, check)
        stage = "owner identity"
        owner = poll(client, deadline, check) do _
            candidate(client, client.node_name)
        end
        with_thread_loop_lock(client.loop) do _
            deadline_check(client, deadline, check)
            owner.id != 0 && owner.id != typemax(UInt32) ||
                throw(UnknownOutcome("owner global ID is not assigned"))
            client.global_id = owner.id
            client.serial = serial(owner.properties, client.node_name)
            client.node = bind(
                something(client.registry),
                owner,
                Node;
                on_info = (proxy, info) -> node_info!(client, info; marker = false),
                on_removed = proxy ->
                    fail!(client, "owner proxy was removed"; retirement = true),
                on_error = (proxy, sequence, error) ->
                    fail!(client, sprint(showerror, error); retirement = true),
                on_param = (proxy, sequence, id, index, next, pod) -> begin
                    id == SPA.PARAM_PROPS &&
                        pod !== nothing &&
                        observe!(observation, pod; at = Clocks.time_nanos(client.clock))
                    wake!(client)
                    nothing
                end,
            )
        end
        poll(_ -> client.owner_ready, client, deadline, check)
        stage = "retained parameters and controller admission"
        with_thread_loop_lock(client.loop) do _
            deadline_check(client, deadline, check)
            healthy(client)
            subscribe_params!(something(client.node), (SPA.PARAM_PROPS,))
            enum_params!(something(client.node), SPA.PARAM_PROPS; count = UInt32(8))
        end
        poll(client, deadline, check) do _
            cap = observation.capability
            cap !== nothing &&
                observation.completion_seen &&
                observation.rejection_seen &&
                something(client.identity) in cap.controllers
        end
        return client
    catch error
        contextual = UnknownOutcome(
            "connection failed during $stage: $(sprint(showerror, error))"
        )
        try
            close(client)
        catch cleanup_error
            throw(CompositeException([contextual, cleanup_error]))
        end
        throw(contextual)
    end
end

_unknown_outcome(error) = UnknownOutcome(sprint(showerror, error))
_unknown_outcome(error::UnknownOutcome) = error
function _fail_request!(client, error)
    with_thread_loop_lock(client.loop) do _
        fail!(
            client.observation,
            sprint(showerror, error);
            at = Clocks.time_nanos(client.clock),
        )
    end
    throw(_unknown_outcome(error))
end
_request_failure!(client, error, submitted) =
    submitted ? _fail_request!(client, error) : nothing
_request_failure!(client, error::UnknownOutcome, submitted) = _fail_request!(client, error)


"""
    request!(client, command; deadline, check=()->nothing)

Send exactly once with a new token above all observed accepted tokens and return
a matching typed Completion or Rejection. One absolute deadline covers encoding,
submission and observation. A reply observed before retirement remains resolved;
retirement disables future requests. Failure before reply observation is unknown,
disables this client, and is never retried or rebound. Serialize close with use.
Pass an `Int64` nanosecond deadline from the client's clock. `Float64` seconds
are converted once on entry for compatibility. Polling retains one decision
sample per iteration; native submission independently checks the fresh clock.
"""
function request!(client::Client, command; deadline::Union{Int64,Float64}, check = NO_CHECK)
    deadline = _deadline_ns(deadline)
    client.closed && throw(UnknownOutcome("client is closed"))
    trylock(client.request_lock) ||
        throw(ArgumentError("a native owner request is already pending"))
    if client.active
        unlock(client.request_lock)
        throw(ArgumentError("a native owner operation is already active"))
    end
    client.active = true
    submitted = false
    installed = false
    header = nothing
    try
        deadline_check(client, deadline, check)
        client.closed && throw(UnknownOutcome("client is closed"))
        operation = operation_id(client.observation.profile, command)
        # Encode/validate locally before occupying a pending owner operation.
        validation_header = Envelope.RequestHeader(
            something(client.identity),
            client.observation.instance,
            Int64(1),
            operation,
            Int64(1),
        )
        encode_request(client.observation.profile, validation_header, command)
        # Cold encoding may span another caller's completion. Choose the real
        # token afterwards; validation neither reserves nor submits a request.
        token = with_thread_loop_lock(client.loop) do _
            healthy(client)
            token = max(client.last_token, client.observation.max_accepted)
            token < typemax(Int64) || throw(ArgumentError("request tokens exhausted"))
            token + 1
        end
        # Cold validation/compilation must not inflate the transmitted budget.
        deadline_check(client, deadline, check)
        remaining = remaining_ns(deadline, something(client.last_at))
        budget = budget_ns(client.observation.profile, remaining)
        header = Envelope.RequestHeader(
            something(client.identity),
            client.observation.instance,
            token,
            operation,
            budget,
        )
        pod = encode_request(client.observation.profile, header, command)
        deadline_check(client, deadline, check)
        with_thread_loop_lock(client.loop) do _
            healthy(client)
            deadline_check(client, deadline, check)
            observation = client.observation
            observation.pending === nothing ||
                throw(ArgumentError("a native request is already pending"))
            observation.pending = header
            installed = true
            observation.matched_completion = nothing
            observation.matched_rejection = nothing
            client.last_token = token
            submitted = true
            set_param!(something(client.node), SPA.PARAM_PROPS, pod)
        end
        return poll(client, deadline, check; verify_health = false) do current
            reply = matching_reply(client.observation, deadline; now = current)
            reply !== nothing && return reply
            healthy(client)
            nothing
        end
    catch error
        _request_failure!(client, error, submitted)
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
    trylock(client.request_lock) ||
        throw(ArgumentError("serialize close after the pending native request"))
    if client.active
        unlock(client.request_lock)
        throw(ArgumentError("serialize close after the active native operation"))
    end
    client.active = true
    failures = Any[]
    try
        client.closed = true
        with_thread_loop_lock(client.loop) do _
            for resource in (
                client.timer,
                client.node,
                client.marker_node,
                client.marker,
                client.registry_listener,
                client.registry,
                client.core,
                client.context,
            )
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
        lock(client.wakeup_lock) do
            close(client.wakeup)
        end
    finally
        client.active = false
        unlock(client.request_lock)
    end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

end # module ControlClient
