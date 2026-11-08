# Direct PipeWire object ownership. Names follow media-session's public object,
# lookup, link creation/removal and synchronization vocabulary. This is an
# independent Julia implementation using PipeWireAO's public proxies and info
# records; no upstream policy, daemon layouts or WirePlumber objects are used.

const ObjectInfo = Union{NodeInfo,PortInfo,ClientInfo,FactoryInfo}
mutable struct Object{P,I<:ObjectInfo}
    id::UInt32
    serial::UInt64
    global_properties::Dict{String,String}
    proxy::P
    info::Union{Nothing,I}
    removed::Bool
end

struct CoreIdentity
    pid::UInt32
    cookie::UInt32
    name::String
end
Base.:(==)(a::CoreIdentity, b::CoreIdentity) =
    a.pid == b.pid && a.cookie == b.cookie && a.name == b.name
struct Captured
    serial::UInt64
    properties::Dict{String,Union{Nothing,String}}
    info_properties::Dict{String,Union{Nothing,String}}
    inputs::Union{Nothing,UInt32}
    outputs::Union{Nothing,UInt32}
    core::Union{Nothing,CoreIdentity}
end
mutable struct Group
    nodes::Vector{String}
    members::Vector{String}
    running::Bool
end
struct PortContract
    element_type::String
    shape::Vector{Int32}
    schema::Union{Nothing,String}
    layout::Union{Nothing,String}
    rate::Union{Nothing,PolicySPA.Fraction}
end
struct Endpoint
    node::UInt32
    port::UInt32
    parent::UInt32
    contract::PortContract
end

struct ObjectUpdated{I<:ObjectInfo} <: AbstractEvent
    id::UInt32
    serial::UInt64
    info::I
end
struct ObjectBound <: AbstractEvent
    id::UInt32
    serial::UInt64
    bound_id::UInt32
end
struct ObjectError <: AbstractEvent
    id::UInt32
    serial::UInt64
    sequence::Cint
    message::String
end
ObjectError(id::UInt32, serial::UInt64, message::String) =
    ObjectError(id, serial, Cint(-1), message)
struct LinkBound <: AbstractEvent
    sequence::UInt64
    id::UInt32
end
struct LinkUpdated <: AbstractEvent
    sequence::UInt64
    info::LinkInfo
end
struct LinkDestroyed <: AbstractEvent
    sequence::UInt64
end
struct LinkError <: AbstractEvent
    sequence::UInt64
    message::String
end
mutable struct LinkRecord
    sequence::UInt64
    path::String
    output::Endpoint
    input::Endpoint
    passive::Bool
    proxy::Union{Nothing,PipeWireAO.Link}
    listener::Union{Nothing,PipeWireAO.ManagedListener}
    id::Union{Nothing,UInt32}
    serial::Union{Nothing,UInt64}
    info::Union{Nothing,LinkInfo}
    creation_pending::Bool
    pending::Bool
    negotiated::Bool
    retiring::Bool
    destroyed::Bool
    failure::Union{Nothing,String}
end

const OBJECT_IDENTITY_KEYS = (
    "object.serial",
    "node.name",
    "client.id",
    "node.id",
    "port.name",
    "port.direction",
    "application.process.id",
    "factory.id",
    "factory.name",
    "factory.type.name",
    "module.id",
    "pipewireao.rtc-control.protocol",
    "pipewireao.rtc-control.profile",
    "pipewireao.rtc-control.instance",
    "pipewireao.rtc-control.owner-pid",
    "pipewireao.source-control.protocol",
    "pipewireao.source-control.instance",
    "pipewireao.source-control.owner-pid",
)
const MAX_LINKS = DeploymentConfiguration.MAX_SESSION_LINKS

info_properties(::Nothing) = Dict{String,String}()
info_properties(info::ObjectInfo) = info.properties
info_properties(info::FactoryInfo) = merge(
    info.properties, Dict("factory.name" => info.name, "factory.type.name" => info.type)
)
info_properties(info::PortInfo) = merge(
    info.properties,
    Dict("port.direction" =>
            (info.direction == PipeWireAO.DIRECTION_INPUT ? "in" : "out")),
)
object_properties(object::Object) =
    merge(object.global_properties, info_properties(object.info))
function property(runtime, handle::UInt64, key::AbstractString)
    object = get(runtime.objects, UInt32(handle), nothing)
    object === nothing && return nothing
    return get(object_properties(object), key, nothing)
end
find_object(runtime, id::Integer) = get(runtime.objects, UInt32(id), nothing)
function registry_serial(runtime, id)
    object = PipeWireAO.find_global(runtime.registry, id)
    return object === nothing ? nothing : _serial(object.properties)
end
function _serial(properties)
    value = tryparse(UInt64, get(properties, "object.serial", ""))
    value !== nothing && value > 0 ||
        throw(ArgumentError("missing or invalid object serial"))
    return value
end
function _object_error!(runtime, message)
    required_lost!(runtime.machine, message)
    return nothing
end

# Wire tags are normalized only at registry admission. Runtime behavior uses
# concrete proxy/info types, including sparse-info merge and state validation.
_proxy_type(::Val{Symbol("PipeWire:Interface:Node")}) = (Node, NodeInfo)
_proxy_type(::Val{Symbol("PipeWire:Interface:Port")}) = (Port, PortInfo)
_proxy_type(::Val{Symbol("PipeWire:Interface:Client")}) = (Client, ClientInfo)
_proxy_type(::Val{Symbol("PipeWire:Interface:Factory")}) = (Factory, FactoryInfo)
_proxy_type(::Val) = nothing
function bind_object!(runtime, global_object::Global)
    types = _proxy_type(Val(Symbol(global_object.type)))
    types === nothing && return nothing
    return _bind_object!(runtime, global_object, types...)
end
function bind_object!(runtime, id::UInt32, interface::AbstractString)
    global_object = PipeWireAO.find_global(runtime.registry, id)
    global_object === nothing && return nothing
    global_object.type == interface || throw(ArgumentError("registry object type differs"))
    return bind_object!(runtime, global_object)
end
function _bind_object!(runtime, global_object, ::Type{P}, ::Type{I}) where {P,I}
    id, serial = global_object.id, _serial(global_object.properties)
    old = find_object(runtime, id)
    if old !== nothing
        old.serial == serial ||
            throw(ArgumentError("registry replaced an object without removal"))
        return old
    end
    queue = runtime.queue
    callbacks = (
        on_info = (_, info) -> stage!(queue, ObjectUpdated(id, serial, info)),
        on_bound = (_, bound) -> stage!(queue, ObjectBound(id, serial, bound)),
        on_removed = (_) -> stage!(queue, ObjectError(id, serial, "Bound object removed")),
        on_error = (_, sequence, error) ->
            stage!(queue, ObjectError(id, serial, sequence, sprint(showerror, error))),
    )
    proxy = _bind_object(runtime.registry, global_object, P, callbacks, queue, id)
    object = Object{typeof(proxy),I}(
        id, serial, copy(global_object.properties), proxy, nothing, false
    )
    runtime.objects[id] = object
    return object
end
_bind_object(registry, global_object, ::Type{P}, callbacks, queue, id) where {P} =
    bind(registry, global_object, P; callbacks...)

function _bind_object(
    registry, global_object, ::Type{P}, callbacks, queue, id
) where {P<:Union{Node,Port}}
    return bind(
        registry, global_object, P; callbacks..., on_param = param_callback(queue, id)
    )
end

_changed(mask, bit) = mask & bit != 0
function _merge_info(::Nothing, update::NodeInfo)
    empty = NodeInfo(
        update.id,
        update.max_input_ports,
        update.max_output_ports,
        UInt64(0),
        UInt32(0),
        UInt32(0),
        PipeWireAO.NODE_STATE_CREATING,
        nothing,
        Dict{String,String}(),
        ParamInfo[],
    )
    return _merge_info(empty, update)
end
function _merge_info(::Nothing, update::PortInfo)
    return _merge_info(
        PortInfo(
            update.id, update.direction, UInt64(0), Dict{String,String}(), ParamInfo[]
        ),
        update,
    )
end
function _merge_info(::Nothing, update::LinkInfo)
    empty = LinkInfo(
        update.id,
        update.output_node_id,
        update.output_port_id,
        update.input_node_id,
        update.input_port_id,
        UInt64(0),
        PipeWireAO.LINK_STATE_INIT,
        nothing,
        nothing,
        Dict{String,String}(),
    )
    return _merge_info(empty, update)
end
_merge_info(::Nothing, update::ClientInfo) =
    _merge_info(ClientInfo(update.id, UInt64(0), Dict{String,String}()), update)
_merge_info(::Nothing, update::FactoryInfo) = _merge_info(
    FactoryInfo(
        update.id,
        update.name,
        update.type,
        update.version,
        UInt64(0),
        Dict{String,String}(),
    ),
    update,
)
function _merge_info(current::Union{Nothing,NodeInfo}, update::NodeInfo)
    current === nothing && return update
    mask = update.change_mask
    return NodeInfo(
        current.id,
        current.max_input_ports,
        current.max_output_ports,
        current.change_mask | mask,
        _changed(mask, PipeWireAO.NODE_CHANGE_INPUT_PORTS) ? update.n_input_ports :
        current.n_input_ports,
        _changed(mask, PipeWireAO.NODE_CHANGE_OUTPUT_PORTS) ? update.n_output_ports :
        current.n_output_ports,
        _changed(mask, PipeWireAO.NODE_CHANGE_STATE) ? update.state : current.state,
        _changed(mask, PipeWireAO.NODE_CHANGE_STATE) ? update.error : current.error,
        _changed(mask, PipeWireAO.NODE_CHANGE_PROPERTIES) ? update.properties :
        current.properties,
        _changed(mask, PipeWireAO.NODE_CHANGE_PARAMS) ? update.params : current.params,
    )
end
function _merge_info(current::Union{Nothing,PortInfo}, update::PortInfo)
    current === nothing && return update
    mask = update.change_mask
    return PortInfo(
        current.id,
        update.direction,
        current.change_mask | mask,
        _changed(mask, PipeWireAO.PORT_CHANGE_PROPERTIES) ? update.properties :
        current.properties,
        _changed(mask, PipeWireAO.PORT_CHANGE_PARAMS) ? update.params : current.params,
    )
end
function _merge_info(current::Union{Nothing,LinkInfo}, update::LinkInfo)
    current === nothing && return update
    mask = update.change_mask
    return LinkInfo(
        current.id,
        current.output_node_id,
        current.output_port_id,
        current.input_node_id,
        current.input_port_id,
        current.change_mask | mask,
        _changed(mask, PipeWireAO.LINK_CHANGE_STATE) ? update.state : current.state,
        _changed(mask, PipeWireAO.LINK_CHANGE_STATE) ? update.error : current.error,
        _changed(mask, PipeWireAO.LINK_CHANGE_FORMAT) ? update.format : current.format,
        _changed(mask, PipeWireAO.LINK_CHANGE_PROPERTIES) ? update.properties :
        current.properties,
    )
end
function _merge_info(current::Union{Nothing,ClientInfo}, update::ClientInfo)
    current === nothing && return update
    return ClientInfo(
        current.id,
        current.change_mask | update.change_mask,
        _changed(update.change_mask, UInt64(1)) ? update.properties : current.properties,
    )
end
function _merge_info(current::Union{Nothing,FactoryInfo}, update::FactoryInfo)
    current === nothing && return update
    return FactoryInfo(
        current.id,
        update.name,
        update.type,
        update.version,
        current.change_mask | update.change_mask,
        _changed(update.change_mask, UInt64(1)) ? update.properties : current.properties,
    )
end
function update!(runtime, event::ObjectUpdated)
    object = find_object(runtime, event.id)
    object !== nothing && object.serial == event.serial || return nothing
    _update_info!(runtime, object, event.info)
    return nothing
end
function _update_info!(runtime, object::Object{P,I}, info::I) where {P,I}
    info.id == object.id ||
        return _object_error!(runtime, "Object info ID differs from registry identity")
    object.info = _merge_info(object.info, info)
    if haskey(runtime.captured, object.id)
        try
            assert_identity!(runtime, UInt64(object.id))
        catch error
            _object_error!(runtime, "Required object changed: " * sprint(showerror, error))
        end
    end
    return nothing
end
function update!(runtime, event::ObjectBound)
    object = find_object(runtime, event.id)
    object !== nothing && object.serial == event.serial || return nothing
    event.id == event.bound_id || _object_error!(runtime, "Object binding identity differs")
    return nothing
end
function update!(runtime, event::ObjectError)
    object = find_object(runtime, event.id)
    object !== nothing && object.serial == event.serial || return nothing
    event.sequence == -1 ||
        !parameter_error!(runtime, event.id, event.sequence, event.message) ||
        return nothing
    object.removed = true
    haskey(runtime.captured, event.id) && _object_error!(runtime, event.message)
    return nothing
end
function remove_object!(runtime, id::UInt32)
    object = pop!(runtime.objects, id, nothing)
    object === nothing && return nothing
    object.removed = true
    if haskey(runtime.captured, id)
        delete!(runtime.captured, id)
        _object_error!(
            runtime,
            "Required registry incarnation removed: id=$id serial=$(object.serial)",
        )
    end
    # This is owner event application, after native iterate returned. It must
    # never be called from the native registry callback itself.
    close(object.proxy)
    return nothing
end
function dispose_objects!(runtime)
    for object in values(runtime.objects)
        close(object.proxy)
    end
    empty!(runtime.objects)
    empty!(runtime.captured)
    return nothing
end

client_pid(object::Object) = nothing
function client_pid(object::Object{P,ClientInfo}) where {P}
    object.info === nothing && return nothing
    return tryparse(UInt32, get(object.info.properties, "application.process.id", ""))
end
_retirement_port_parent(object::Object) = nothing
function _retirement_port_parent(object::Object{P,PortInfo}) where {P}
    return tryparse(UInt32, get(object_properties(object), "node.id", ""))
end
_node_client(object::Object) = nothing
function _node_client(object::Object{P,NodeInfo}) where {P}
    return tryparse(UInt32, get(object_properties(object), "client.id", ""))
end

"""Retire a declared process cohort after its validated bootstrap Quit receipt.

`owner.retired` must already record successful validation of that receipt. An
acquisition Shutdown proves acquisition cleanup, not process shutdown, and does
not admit this operation. Captures remain required until this explicit handoff.
Only declared nodes with matching native ClientInfo provenance, their ports and
unshared client parents are retired. Exact `(global ID, serial)` absence targets
remain in `runtime.retired`; this method neither removes nor destroys objects.
"""
function retire_owner!(runtime, owner::Owner{OwnerBootstrapCodec.Profile})
    owner.retired || throw(ArgumentError("owner has no validated bootstrap Quit receipt"))
    assert_identity!(runtime, owner.handle)
    endpoint = something(find_object(runtime, owner.handle))
    properties = object_properties(endpoint)
    declarations = [
        declaration for declaration in get(runtime.configuration, "owners", []) if
        get(declaration, "pid", nothing) == owner.pid &&
            haskey(declaration, "bootstrap-node")
    ]
    length(declarations) == 1 ||
        throw(ArgumentError("process retirement requires one declared bootstrap owner"))
    declaration = only(declarations)
    get(properties, "node.name", nothing) == declaration["bootstrap-node"] &&
    tryparse(Int64, string(declaration["bootstrap-instance"])) == owner.instance &&
    get(properties, "pipewireao.rtc-control.protocol", nothing) == ControlClient.PROTOCOL &&
    get(properties, "pipewireao.rtc-control.profile", nothing) ==
    ControlClient.profile_name(owner.profile) &&
    tryparse(Int64, get(properties, "pipewireao.rtc-control.instance", "")) ==
    owner.instance &&
    tryparse(UInt32, get(properties, "pipewireao.rtc-control.owner-pid", "")) == owner.pid ||
        throw(ArgumentError("bootstrap receipt differs from the declared native owner"))
    names = Set{String}(
        name for
        (name, pid) in get(runtime.configuration, "node.pids", Dict{String,Int}()) if
        pid == owner.pid
    )
    push!(names, String(declaration["bootstrap-node"]))
    control_name = get(declaration, "control-node", nothing)
    control_name === nothing || push!(names, String(control_name))
    nodes, clients = Set{UInt32}(), Set{UInt32}()
    for object in values(runtime.objects)
        haskey(runtime.captured, object.id) || continue
        any(name -> _named_node(object, name), names) || continue
        assert_identity!(runtime, UInt64(object.id))
        client_id = _node_client(object)
        client_id === nothing &&
            throw(ArgumentError("retiring node has no native client provenance"))
        client = find_object(runtime, client_id)
        client !== nothing &&
        !client.removed &&
        client_pid(client) == owner.pid ||
            throw(ArgumentError("retiring node has a foreign or unproven native client"))
        push!(nodes, object.id)
        push!(clients, client_id)
    end
    UInt32(owner.handle) in nodes ||
        throw(ArgumentError("bootstrap endpoint is not a proven retirement target"))
    targets = copy(nodes)
    for object in values(runtime.objects)
        haskey(runtime.captured, object.id) || continue
        _retirement_port_parent(object) in nodes && push!(targets, object.id)
    end
    for id in clients
        shared = any(
            object ->
                haskey(runtime.captured, object.id) &&
                !(object.id in nodes) &&
                _node_client(object) == id,
            values(runtime.objects),
        )
        shared || push!(targets, id)
    end
    for id in targets
        haskey(runtime.captured, id) && assert_identity!(runtime, UInt64(id))
    end
    for id in targets
        object = something(find_object(runtime, id))
        runtime.retired[id] = object.serial
        delete!(runtime.captured, id)
    end
    return nothing
end
retire_owner!(runtime, owner::Owner) =
    throw(ArgumentError("process retirement requires a bootstrap Quit receipt"))

"""Replace a failed local bind after a correlated read-only request has ended.

PipeWireAO retains proxy errors. The owner may refresh that local proxy after
its parameter barrier, preserving the captured server incarnation. This does
not replace, destroy or adopt a server global. Pending parameter transactions
must be fenced by the caller before invoking this method.
"""
function refresh_object!(runtime, id::UInt32)
    object = find_object(runtime, id)
    object === nothing && throw(ArgumentError("cannot refresh an absent object"))
    global_object = PipeWireAO.find_global(runtime.registry, id)
    global_object !== nothing && _serial(global_object.properties) == object.serial ||
        throw(ArgumentError("cannot refresh a changed registry incarnation"))
    close(object.proxy)
    delete!(runtime.objects, id)
    replacement = bind_object!(runtime, global_object)
    replacement.info = object.info
    haskey(runtime.captured, id) && assert_identity!(runtime, UInt64(id))
    return replacement
end

_port_counts(::Nothing) = (nothing, nothing)
_port_counts(info::ObjectInfo) = (nothing, nothing)
_port_counts(info::NodeInfo) = (info.n_input_ports, info.n_output_ports)
_healthy(::Nothing) = true
_healthy(info::ObjectInfo) = true
_healthy(info::NodeInfo) = info.state != PipeWireAO.NODE_STATE_ERROR
function _core_identity(runtime)
    info = runtime.core_info
    info === nothing && throw(ArgumentError("remote CoreInfo is unavailable"))
    pid = tryparse(UInt32, get(info.properties, "application.process.id", ""))
    pid !== nothing && pid > 0 ||
        throw(ArgumentError("remote core process identity is unavailable"))
    return CoreIdentity(pid, info.cookie, info.name)
end
function capture!(runtime, handle::UInt64; core = nothing)
    object = find_object(runtime, handle)
    object !== nothing && !object.removed ||
        throw(ArgumentError("required object is absent"))
    haskey(runtime.captured, object.id) && return assert_identity!(runtime, handle)
    properties = object_properties(object)
    frozen = Dict{String,Union{Nothing,String}}(
        key => get(properties, key, nothing) for key in OBJECT_IDENTITY_KEYS
    )
    info = info_properties(object.info)
    info_frozen = Dict{String,Union{Nothing,String}}(
        key => get(info, key, nothing) for key in OBJECT_IDENTITY_KEYS
    )
    inputs, outputs = _port_counts(object.info)
    runtime.captured[object.id] = Captured(
        object.serial, frozen, info_frozen, inputs, outputs, core
    )
    return assert_identity!(runtime, handle)
end
function assert_identity!(runtime, handle::UInt64)
    id = UInt32(handle)
    captured = get(runtime.captured, id, nothing)
    captured === nothing && throw(ArgumentError("object is not captured"))
    object = find_object(runtime, id)
    object !== nothing && !object.removed && object.serial == captured.serial ||
        throw(ArgumentError("object incarnation changed"))
    properties, info = object_properties(object), info_properties(object.info)
    _serial(properties) == captured.serial &&
    registry_serial(runtime, id) == captured.serial ||
        throw(ArgumentError("object serial changed"))
    for (key, value) in captured.properties
        get(properties, key, nothing) == value ||
            throw(ArgumentError("object identity property changed: $key"))
    end
    for (key, value) in captured.info_properties
        get(info, key, nothing) == value ||
            throw(ArgumentError("bound info identity property disappeared: $key"))
    end
    _port_counts(object.info) == (captured.inputs, captured.outputs) ||
        throw(ArgumentError("required node port inventory changed"))
    _healthy(object.info) || throw(ArgumentError("required node entered error state"))
    captured.core === nothing ||
        captured.core == _core_identity(runtime) ||
        throw(ArgumentError("remote core incarnation changed"))
    return nothing
end

_named_node(object::Object, name) = false
_named_node(object::Object{P,NodeInfo}, name) where {P} =
    get(object_properties(object), "node.name", nothing) == name
_spa_factory(object::Object) = false
function _spa_factory(object::Object{P,FactoryInfo}) where {P}
    properties = object_properties(object)
    return !haskey(properties, "client.id") &&
           get(properties, "factory.name", nothing) == "spa-node-factory" &&
           get(properties, "factory.type.name", nothing) == "PipeWire:Interface:Node"
end
function _core_factory(runtime, object, name, pid)
    declaration = get(runtime.configuration, "core.owner", nothing)
    declaration === nothing && return nothing
    name in declaration["nodes"] || return nothing
    core = _core_identity(runtime)
    pid == declaration["pid"] == core.pid ||
        throw(ArgumentError("declared core process differs"))
    id = tryparse(UInt32, get(object_properties(object), "factory.id", ""))
    id === nothing && return nothing
    factory = bind_object!(runtime, id, "PipeWire:Interface:Factory")
    factory === nothing && return nothing
    _spa_factory(factory) ||
        throw(ArgumentError("declared core node has an unsupported factory"))
    return factory
end
function named_node!(runtime, name)
    matches = find_globals(
        runtime.registry;
        interface = "PipeWire:Interface:Node",
        properties = ("node.name" => name,),
    )
    length(matches) <= 1 || throw(ArgumentError("ambiguous declared node: $name"))
    return isempty(matches) ? nothing : bind_object!(runtime, only(matches))
end
function find_object(runtime, name::AbstractString, pid::Integer)
    object = named_node!(runtime, name)
    object === nothing && return nothing
    object.removed && throw(ArgumentError("declared node binding failed: $name"))
    object.info === nothing && return nothing
    properties = object_properties(object)
    client_id = get(properties, "client.id", nothing)
    if client_id !== nothing
        id = tryparse(UInt32, client_id)
        id !== nothing || throw(ArgumentError("invalid node client identity"))
        client = bind_object!(runtime, id, "PipeWire:Interface:Client")
        client === nothing && return nothing
        client.info === nothing && return nothing
        client_pid(client) == pid ||
            throw(ArgumentError("declared node has an unexpected process owner: $name"))
    else
        _core_factory(runtime, object, name, pid) === nothing && return nothing
    end
    return object
end
function node!(runtime, job, name::AbstractString, pid::Integer)
    return await_condition!(runtime, job) do
        object = find_object(runtime, name, pid)
        object === nothing ? nothing : UInt64(object.id)
    end
end

function PortContract(value::AbstractDict)
    shape = Int32[Int32(dimension) for dimension in value["shape"]]
    1 <= length(shape) <= 32 && all(>(0), shape) ||
        throw(ArgumentError("invalid declared shape"))
    raw_rate = get(value, "rate", nothing)
    rate = nothing
    if raw_rate !== nothing
        parts = split(String(raw_rate), '/')
        length(parts) == 2 || throw(ArgumentError("invalid declared rate"))
        num, denom = tryparse.(UInt32, parts)
        num !== nothing && denom !== nothing && num > 0 && denom > 0 ||
            throw(ArgumentError("invalid declared rate"))
        rate = PolicySPA.Fraction(num, denom)
    end
    return PortContract(
        String(value["element-type"]),
        shape,
        get(value, "schema", nothing),
        get(value, "layout", nothing),
        rate,
    )
end
function _endpoint_address(address)
    parts = split(String(address), ':'; limit = 2)
    length(parts) == 2 && all(!isempty, parts) ||
        throw(ArgumentError("invalid declared endpoint"))
    return parts
end
function declared_port!(runtime, node, name, direction, address)
    direction_name = direction == PipeWireAO.DIRECTION_OUTPUT ? "out" : "in"
    matches = find_globals(
        runtime.registry;
        interface = "PipeWire:Interface:Port",
        properties = (
            "node.id" => string(node), "port.name" => name, "port.direction" => direction_name
        ),
    )
    length(matches) <= 1 || throw(ArgumentError("ambiguous declared port: $address"))
    isempty(matches) && return nothing
    port = bind_object!(runtime, only(matches))
    port.info === nothing && return nothing
    properties = object_properties(port)
    port.info.direction == direction &&
    get(properties, "node.id", nothing) == string(node) &&
    get(properties, "port.name", nothing) == name ||
        throw(ArgumentError("bound Port differs from its registry declaration: $address"))
    return port
end
function _endpoint!(runtime, job, address, direction)
    name, port_name = _endpoint_address(address)
    pid = runtime.configuration["node.pids"][name]
    node = UInt32(node!(runtime, job, name, pid))
    port = await_condition!(runtime, job) do
        declared_port!(runtime, node, port_name, direction, address)
    end
    declaration = nothing
    for role in ("sources", "graphs", "sinks"),
        value in get(runtime.configuration["session"], role, [])

        get(value, "node.name", nothing) == name || continue
        for candidate in get(value, "ports", [])
            candidate["name"] == port_name &&
            candidate["direction"] ==
            (direction == PipeWireAO.DIRECTION_OUTPUT ? "output" : "input") || continue
            declaration === nothing || throw(ArgumentError("duplicate port contract"))
            declaration = candidate
        end
    end
    declaration === nothing && throw(ArgumentError("port contract missing: $address"))
    object = something(find_object(runtime, node))
    properties = object_properties(object)
    client_id = get(properties, "client.id", nothing)
    parent, core =
        client_id === nothing ?
        (something(_core_factory(runtime, object, name, pid)).id, _core_identity(runtime)) :
        (parse(UInt32, client_id), nothing)
    for id in (node, port.id, parent)
        capture!(runtime, UInt64(id); core)
    end
    return Endpoint(node, port.id, parent, PortContract(declaration))
end

# Fixed Choice.None defaults may legally retain trailing alternatives. Read
# only the public SPA wire header and the complete selected primitive; never
# recursively decode unused format fields or reinterpret their payloads.
function _fixed_value(value::PolicyPod, tag::UInt32, width::Union{Nothing,Int})
    PipeWireAO.pod_type(value) == PolicySPA.POD_CHOICE || return value
    data = value.data
    length(data) >= 24 || throw(ArgumentError("truncated fixed format choice"))
    kind, child_size, child_type = reinterpret(UInt32, data[9:24])[[1, 3, 4]]
    kind == UInt32(PolicySPA.CHOICE_NONE) && child_type == tag && child_size > 0 ||
        throw(ArgumentError("negotiated format retains an unfixed or incompatible choice"))
    width === nothing ||
        child_size == width ||
        throw(ArgumentError("invalid selected format width"))
    length(data) >= 24 + child_size ||
        throw(ArgumentError("incomplete fixed format default"))
    header = collect(reinterpret(UInt8, UInt32[child_size, child_type]))
    return PolicyPod(vcat(header, data[25:(24+Int(child_size))]))
end
function validate_format(pod::PolicyPod, contract::PortContract)
    16 <= length(pod.data) <= 65536 || throw(ArgumentError("invalid Format size"))
    object = PipeWireAO.pod_value(PolicySPA.Object, pod)
    object.type == UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format) &&
    object.id in (PolicySPA.PARAM_FORMAT, PolicySPA.PARAM_ENUM_FORMAT) ||
        throw(ArgumentError("expected native Format"))
    length(object.properties) <= 32 || throw(ArgumentError("too many Format fields"))
    ids = Set{UInt32}()
    selected = PolicySPA.Property[]
    for property in object.properties
        property.key in ids && throw(ArgumentError("duplicate Format field"))
        push!(ids, property.key)
        key, value = property.key, property.value
        if key in (
            PolicySPA.FORMAT_MEDIA_TYPE,
            PolicySPA.FORMAT_MEDIA_SUBTYPE,
            PolicySPA.FORMAT_NDARRAY_ELEMENT_TYPE,
            PolicySPA.FORMAT_NDARRAY_LAYOUT,
        )
            value = _fixed_value(value, PolicySPA.POD_ID, 4)
            policy_id(value)
        elseif key == PolicySPA.FORMAT_NDARRAY_RATE
            value = _fixed_value(value, PolicySPA.POD_FRACTION, 8)
            length(value.data) == 16 ||
                throw(ArgumentError("invalid format Fraction width"))
        elseif key == PolicySPA.FORMAT_NDARRAY_SHAPE
            value = _fixed_value(value, PolicySPA.POD_ARRAY, nothing)
            shape = PipeWireAO.pod_value(PolicySPA.Array{Int32}, value).values
            length(shape) == length(contract.shape) && shape == contract.shape ||
                throw(ArgumentError("negotiated ndarray shape differs"))
        elseif key == PolicySPA.FORMAT_NDARRAY_SCHEMA
            value = _fixed_value(value, PolicySPA.POD_STRING, nothing)
            policy_text(value; limit = 4096)
        else
            continue
        end
        push!(selected, PolicySPA.Property(key, value; flags = property.flags))
    end
    fixed = PolicySPA.Parameter(PolicySPA.Object(object.type, object.id, selected))
    format = NdArrayFormat(fixed)
    string(format.element_type) == contract.element_type &&
    collect(format.shape) == contract.shape &&
    PipeWireAO.ndarray_schema(fixed) == contract.schema ||
        throw(ArgumentError("negotiated ndarray element type/schema differs"))
    contract.layout === nothing ||
        string(format.layout) == contract.layout ||
        throw(ArgumentError("negotiated ndarray layout differs"))
    if contract.rate !== nothing
        rate = format.rate
        rate !== nothing &&
        UInt64(rate.num) * contract.rate.denom == UInt64(contract.rate.num) * rate.denom ||
            throw(ArgumentError("negotiated ndarray rate differs"))
    end
    return nothing
end

function _link(runtime, sequence::UInt64)
    index = findfirst(record -> record.sequence == sequence, runtime.links)
    return index === nothing ? nothing : runtime.links[index]
end
function _link_failure!(runtime, record, message)
    record.failure === nothing && (record.failure = String(message))
    record.retiring || _object_error!(runtime, something(record.failure))
    return nothing
end
function update!(runtime, event::LinkBound)
    record = _link(runtime, event.sequence)
    record === nothing && return nothing
    record.id === nothing ||
        record.id == event.id ||
        return _link_failure!(runtime, record, "Created Link binding ID changed")
    record.info === nothing ||
        record.info.id == event.id ||
        return _link_failure!(
            runtime, record, "Created Link binding differs from observed LinkInfo ID"
        )
    record.id = event.id
    record.pending = false
    record.serial === nothing && (record.serial = registry_serial(runtime, event.id))
    return nothing
end
function _validate_link!(runtime, record::LinkRecord, info::LinkInfo)
    record.id === nothing ||
        record.id == info.id ||
        throw(ArgumentError("LinkInfo ID differs from bound Link identity"))
    (info.output_node_id, info.output_port_id, info.input_node_id, info.input_port_id) ==
    (record.output.node, record.output.port, record.input.node, record.input.port) ||
        throw(ArgumentError("Link endpoints differ from exact declaration"))
    if info.state in (PipeWireAO.LINK_STATE_ERROR, PipeWireAO.LINK_STATE_UNLINKED)
        throw(ArgumentError("Link failed: $(info.error)"))
    end
    if !(info.state in (PipeWireAO.LINK_STATE_PAUSED, PipeWireAO.LINK_STATE_ACTIVE))
        record.negotiated && throw(ArgumentError("admitted Link left negotiated state"))
        return nothing
    end
    info.format === nothing && throw(ArgumentError("negotiated Link has no Format"))
    properties = info.properties
    get(properties, "client.id", nothing) == string(runtime.client_id) ||
        throw(ArgumentError("Link client provenance differs"))
    get(properties, "object.path", nothing) == record.path &&
    get(properties, "object.linger", "false") != "true" ||
        throw(ArgumentError("Link lifetime properties differ"))
    (get(properties, "link.passive", "false") == "true") == record.passive ||
        throw(ArgumentError("Link passive boundary differs"))
    validate_format(info.format, record.output.contract)
    validate_format(info.format, record.input.contract)
    record.negotiated = true
    return nothing
end
function update!(runtime, event::LinkUpdated)
    record = _link(runtime, event.sequence)
    record === nothing && return nothing
    record.retiring && return nothing
    record.id === nothing ||
        record.id == event.info.id ||
        return _link_failure!(
            runtime, record, "Link event ID differs from bound Link identity"
        )
    record.info === nothing ||
        record.info.id == event.info.id ||
        return _link_failure!(runtime, record, "Link event ID changed before binding")
    (
        event.info.output_node_id,
        event.info.output_port_id,
        event.info.input_node_id,
        event.info.input_port_id,
    ) == (record.output.node, record.output.port, record.input.node, record.input.port) ||
        return _link_failure!(
            runtime, record, "Link event endpoints differ from exact declaration"
        )
    record.info = _merge_info(record.info, event.info)
    try
        _validate_link!(runtime, record, something(record.info))
    catch error
        _link_failure!(runtime, record, sprint(showerror, error))
    end
    return nothing
end
function update!(runtime, event::LinkDestroyed)
    record = _link(runtime, event.sequence)
    record === nothing && return nothing
    record.destroyed, record.pending = true, false
    record.retiring || _link_failure!(runtime, record, "Required Link proxy destroyed")
    return nothing
end
function update!(runtime, event::LinkError)
    record = _link(runtime, event.sequence)
    record === nothing && return nothing
    record.pending = false
    _link_failure!(runtime, record, event.message)
    return nothing
end

function _link_order(rows)
    successors = Dict{UInt32,Set{UInt32}}()
    for (output, input, passive) in rows
        push!(get!(successors, output.node, Set{UInt32}()), input.node)
    end
    depths, visiting = Dict{UInt32,Int}(), Set{UInt32}()
    function rank(node)
        haskey(depths, node) && return depths[node]
        node in visiting && throw(ArgumentError("session links contain a scheduling cycle"))
        push!(visiting, node)
        depth = 0
        for successor in get(successors, node, Set{UInt32}())
            depth = max(depth, rank(successor) + 1)
        end
        delete!(visiting, node)
        return depths[node] = depth
    end
    for (output, input, passive) in rows
        rank(output.node)
    end
    return sortperm(eachindex(rows); by = index -> (rank(rows[index][2].node), index))
end
function create_links!(runtime, job)
    isempty(runtime.links) && !runtime.withdrawing ||
        throw(ArgumentError("old Link cohort remains"))
    declarations = runtime.configuration["session"]["links"]
    1 <= length(declarations) <= MAX_LINKS ||
        throw(ArgumentError("invalid declared Link count"))
    rows = Tuple{Endpoint,Endpoint,Bool}[]
    for declaration in declarations
        output = _endpoint!(
            runtime, job, declaration["output"], PipeWireAO.DIRECTION_OUTPUT
        )
        input = _endpoint!(runtime, job, declaration["input"], PipeWireAO.DIRECTION_INPUT)
        push!(rows, (output, input, get(declaration, "passive", false)))
    end
    prefix = "pipewireao/session/$(job.ticket.session)/$(job.ticket.epoch)/"
    for index in _link_order(rows)
        output, input, passive = rows[index]
        for endpoint in (output, input),
            id in (endpoint.node, endpoint.port, endpoint.parent)

            assert_identity!(runtime, UInt64(id))
        end
        sequence = Base.Checked.checked_add(
            Base.Checked.checked_mul(job.ticket.serial, UInt64(65)), UInt64(index)
        )
        record = LinkRecord(
            sequence,
            prefix * string(index),
            output,
            input,
            passive,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            true,
            true,
            false,
            false,
            false,
            nothing,
        )
        push!(runtime.links, record)
        properties = Dict(
            "link.output.node" => string(output.node),
            "link.output.port" => string(output.port),
            "link.input.node" => string(input.node),
            "link.input.port" => string(input.port),
            "link.passive" => string(passive),
            "object.linger" => "false",
            "object.path" => record.path,
        )
        queue = runtime.queue
        try
            proxy = create_object(
                runtime.core,
                "link-factory",
                PipeWireAO.Link;
                properties,
                on_bound = (_, id) -> stage!(queue, LinkBound(sequence, id)),
                on_info = (_, info) -> stage!(queue, LinkUpdated(sequence, info)),
                on_removed = (_) ->
                    stage!(queue, LinkError(sequence, "Required Link removed")),
                on_error = (_, seq, error) ->
                    stage!(queue, LinkError(sequence, sprint(showerror, error))),
            )
            record.proxy = proxy
            record.listener = add_listener!(
                proxy.proxy; on_destroyed = (_) -> stage!(queue, LinkDestroyed(sequence))
            )
        finally
            # create_object is synchronous; binding/negotiation remains pending.
            # Even construction failure retains the record/path for the fence.
            record.creation_pending = false
        end
        await_condition!(runtime, job) do
            record.failure === nothing || throw(ArgumentError(record.failure))
            if record.id !== nothing
                serial = registry_serial(runtime, record.id)
                if serial !== nothing
                    record.serial === nothing && (record.serial = serial)
                    serial == record.serial ||
                        throw(ArgumentError("created Link registry incarnation changed"))
                    record.negotiated && !record.pending && return true
                end
            end
            return nothing
        end
    end
    return nothing
end

_destroy_created!(core, ::Nothing) = nothing
_destroy_created!(core, proxy::PipeWireAO.Link) = destroy_object!(core, proxy)
_close_listener!(::Nothing) = nothing
_close_listener!(listener::PipeWireAO.ManagedListener) = close(listener)
registry_links(runtime) = find_globals(runtime.registry; interface = "PipeWire:Interface:Link")
function _correlated_link(object::Global, records)
    path = get(object.properties, "object.path", nothing)
    serial = _serial(object.properties)
    return any(
        record -> (record.id == object.id && record.serial == serial) || record.path == path,
        records,
    )
end
function remove_links!(runtime, job)
    runtime.withdrawing = true
    for record in runtime.links
        record.retiring = true
    end
    for record in runtime.links
        _destroy_created!(runtime.core, record.proxy)
    end
    await_condition!(runtime, job) do
        any(record -> record.creation_pending, runtime.links) && return nothing
        # A proxy that was never returned has no future binding callback. Its
        # exact requested path must still pass the server/registry barrier.
        all(
            record -> record.proxy === nothing || (record.destroyed && !record.pending),
            runtime.links,
        ) ? true : nothing
    end
    synchronize!(runtime, job)
    any(object -> _correlated_link(object, runtime.links), registry_links(runtime)) &&
        throw(ArgumentError("correlated Link remains after destruction and Core sync"))
    for record in runtime.links
        _close_listener!(record.listener)
    end
    empty!(runtime.links)
    runtime.withdrawing = false
    return nothing
end

function _session_controlled(declaration, role)
    ownership = get(declaration, "ownership", "runner")
    ownership in ("runner", "external") || throw(ArgumentError("invalid node ownership"))
    grant = get(declaration, "run-control", nothing)
    if ownership != "external"
        grant === nothing || throw(ArgumentError("runner-owned node has an external grant"))
        return true
    end
    if role == "graphs"
        grant in ("session", "application") ||
            throw(ArgumentError("external graph needs explicit run-control grant"))
        return grant == "session"
    end
    grant === nothing ||
        grant == "application" ||
        throw(ArgumentError("external source or sink remains application-controlled"))
    return false
end
function discover_graphs!(runtime, job)
    spec = runtime.configuration["session"]
    declared, required, membership = Dict{String,Bool}(),
    Set{String}(),
    Dict{String,String}()
    has_graph = false
    for role in ("sources", "graphs", "sinks"), declaration in get(spec, role, [])
        name = String(declaration["node.name"])
        haskey(declared, name) && throw(ArgumentError("duplicate declared node"))
        controlled = _session_controlled(declaration, role)
        declared[name] = controlled
        if role == "graphs" && controlled
            has_graph = true
            push!(required, name)
            if get(declaration, "factory", nothing) != "api.ndarray.latest-hold"
                runtime.graphs[name] = node!(
                    runtime, job, name, runtime.configuration["node.pids"][name]
                )
            end
        elseif role == "sinks" && get(declaration, "ownership", "runner") != "external"
            push!(required, name)
        end
    end
    groups = get(spec, "execution-groups", [])
    has_graph == !isempty(groups) ||
        throw(ArgumentError("execution groups and controlled graphs differ"))
    for declaration in groups
        name = String(declaration["name"])
        !isempty(name) && !occursin('\0', name) && !haskey(runtime.groups, name) ||
            throw(ArgumentError("invalid or duplicate execution group"))
        members = String.(declaration["nodes"])
        isempty(members) && throw(ArgumentError("execution group has no members"))
        for member in members
            get(declared, member, false) && !haskey(membership, member) || throw(
                ArgumentError("unknown, duplicate or application-controlled group member"),
            )
            membership[member] = name
        end
        nodes = filter(member -> haskey(runtime.graphs, member), members)
        isempty(nodes) && throw(ArgumentError("group has no controlled processing graph"))
        runtime.groups[name] = Group(nodes, members, false)
    end
    has_graph &&
        !all(name -> haskey(membership, name), required) &&
        throw(ArgumentError("eligible graph or sink has no execution group"))
    for link in spec["links"]
        output, input = first(_endpoint_address(link["output"])),
        first(_endpoint_address(link["input"]))
        from, to = get(membership, output, nothing), get(membership, input, nothing)
        from === nothing ||
            to === nothing ||
            from == to ||
            throw(ArgumentError("Link crosses execution groups"))
        passive = get(link, "passive", false)
        passive == (from === nothing && to !== nothing) ||
            throw(ArgumentError("invalid execution-group passive boundary"))
    end
    return nothing
end
