"""Supervisor-owned optional detector link. It never controls source acquisition."""
module ObservationBoundary

using PipeWireAO

const INPUT_NAME = "simulator-detector-queue-input"
const OUTPUT_NAME = "simulator-detector-queue-output"
monotonic() = time_ns() / 1.0e9

mutable struct WatchedNode
    id::UInt32
    serial::String
    name::String
    node::Union{Nothing,Node}
    properties::Union{Nothing,Dict{String,String}}
end

mutable struct Boundary
    loop::ThreadLoop
    context::Union{Nothing,Context}
    core::Union{Nothing,CoreConnection}
    registry::Union{Nothing,Registry}
    link::Union{Nothing,Link}
    info::Union{Nothing,LinkInfo}
    passive::Bool
    failure::Union{Nothing,String}
    closed::Bool
    nodes::Dict{String,Tuple{UInt32,String}}
    watched::Vector{WatchedNode}
end

fail!(boundary, detail) = (boundary.failure === nothing && (boundary.failure = String(detail)); nothing)

function observe_node!(boundary, watched, update::NodeInfo)
    update.id == watched.id || return fail!(boundary,"optional detector node global ID changed")
    if update.change_mask & PipeWireAO.NODE_CHANGE_STATE != 0
        update.error === nothing || return fail!(boundary,update.error)
    end
    # Registry globals are deliberately sparse. Only bound NodeInfo properties
    # establish owner metadata; a state-only delta must not erase that evidence.
    if update.change_mask & PipeWireAO.NODE_CHANGE_PROPERTIES != 0
        properties = update.properties
        get(properties,"node.name","") == watched.name &&
            get(properties,"object.serial","") == watched.serial ||
            return fail!(boundary,"optional detector node identity changed: $(watched.name)")
        watched.properties = copy(properties)
    end
    return nothing
end

function queue_identity(input_properties, output_properties)
    (input_properties === nothing || output_properties === nothing) && return false
    queue_id = get(input_properties,"pipewireao.queue.id","")
    !isempty(queue_id) && get(output_properties,"pipewireao.queue.id","") == queue_id &&
        get(output_properties,"device.api","") == "pipewireao.queue" ||
        error("detector queue endpoints do not share an owner identity")
    return true
end

function observe_link!(boundary, update::LinkInfo)
    # Public callbacks contain deltas. Keep state and passive evidence only
    # when the corresponding public change-mask bit is present.
    if boundary.info === nothing || update.change_mask & PipeWireAO.LINK_CHANGE_STATE != 0
        boundary.info = update
    end
    if update.change_mask & PipeWireAO.LINK_CHANGE_STATE != 0
        update.error === nothing || fail!(boundary,update.error)
    end
    if update.change_mask & PipeWireAO.LINK_CHANGE_PROPERTIES != 0
        boundary.passive = get(update.properties,"link.passive",nothing) == "true"
        boundary.passive || fail!(boundary,"optional detector link is not passive")
    end
    return nothing
end

function passive_link_properties(source_node, source_port, queue_node, queue_port)
    return Dict("link.output.node"=>string(source_node), "link.output.port"=>string(source_port),
        "link.input.node"=>string(queue_node), "link.input.port"=>string(queue_port),
        "link.passive"=>"true", "object.linger"=>"false")
end

function unique_global(registry, interface, properties)
    matches = find_globals(registry; interface, properties)
    length(matches) <= 1 || error("optional detector endpoint is ambiguous")
    return isempty(matches) ? nothing : only(matches)
end

function endpoints(registry, source_name, source_id, source_serial)
    source = unique_global(registry,"PipeWire:Interface:Node",("node.name"=>source_name,))
    source === nothing && return nothing
    source.id == source_id && get(source.properties,"object.serial","") == source_serial ||
        error("admitted detector source identity changed")
    input = unique_global(registry,"PipeWire:Interface:Node",("node.name"=>INPUT_NAME,))
    output = unique_global(registry,"PipeWire:Interface:Node",("node.name"=>OUTPUT_NAME,))
    (input === nothing || output === nothing) && return nothing
    source_port = unique_global(registry,"PipeWire:Interface:Port",
        ("node.id"=>string(source.id), "port.direction"=>"out", "port.name"=>"output_1"))
    input_port = unique_global(registry,"PipeWire:Interface:Port",
        ("node.id"=>string(input.id), "port.direction"=>"in"))
    (source_port === nothing || input_port === nothing) && return nothing
    return source,source_port,input,input_port,output
end

identity(object) = (object.id,get(object.properties,"object.serial",""))

function fence_endpoints(registry, candidates, source_name, source_id, source_serial)
    current = endpoints(registry,source_name,source_id,source_serial)
    current !== nothing && map(identity,current) == map(identity,candidates) ||
        error("optional detector endpoints changed before linking")
    return current
end

function wait_for(boundary::Boundary, predicate, deadline, check)
    while monotonic() < deadline
        check()
        value = with_thread_loop_lock(boundary.loop) do _
            boundary.failure === nothing || error(boundary.failure)
            predicate()
        end
        value === nothing || value === false || return value
        sleep(min(0.005,max(0.0,deadline-monotonic())))
    end
    error("optional detector observation preparation timed out")
end
wait_for(predicate, boundary::Boundary, deadline, check) = wait_for(boundary,predicate,deadline,check)

"""Prepare one passive link while the admitted source is held; no retries or run requests."""
function connect(remote, source_name, source_id::UInt32, source_serial; deadline::Float64, check=()->nothing)
    isfinite(deadline) && monotonic() < deadline || throw(ArgumentError("finite future observation deadline required"))
    boundary = Boundary(ThreadLoop("deployment.observation"),nothing,nothing,nothing,nothing,nothing,false,nothing,false,
        Dict{String,Tuple{UInt32,String}}(),WatchedNode[])
    try
        with_thread_loop_lock(boundary.loop) do _
            boundary.context = Context(boundary.loop)
            boundary.core = CoreConnection(something(boundary.context);properties=Dict("remote.name"=>String(remote)),
                on_error=(core,id,sequence,failure)->fail!(boundary,sprint(showerror,failure)))
            boundary.registry = Registry(something(boundary.core))
        end
        start!(boundary.loop)
        candidates = wait_for(boundary,deadline,check) do
            endpoints(something(boundary.registry),source_name,source_id,source_serial)
        end
        with_thread_loop_lock(boundary.loop) do _
            current = fence_endpoints(something(boundary.registry),candidates,source_name,source_id,source_serial)
            source,source_port,input,input_port,output = current
            for object in (source,input,output)
                name = object.properties["node.name"]
                serial = get(object.properties,"object.serial","")
                isempty(serial) && error("optional detector endpoint has no incarnation: $name")
                boundary.nodes[name] = (object.id,serial)
                watched = WatchedNode(object.id,serial,name,nothing,nothing)
                push!(boundary.watched,watched)
                watched.node = bind(something(boundary.registry),object,Node;
                    on_info=(node,update)->observe_node!(boundary,watched,update),
                    on_removed=node->fail!(boundary,"optional detector endpoint removed: $name"),
                    on_error=(node,sequence,failure)->fail!(boundary,sprint(showerror,failure)))
            end
        end
        wait_for(boundary,deadline,check) do
            fence_endpoints(something(boundary.registry),candidates,source_name,source_id,source_serial)
            all(watched->watched.properties !== nothing,boundary.watched) || return false
            queue_identity(boundary.watched[2].properties,boundary.watched[3].properties)
        end
        with_thread_loop_lock(boundary.loop) do _
            source,source_port,input,input_port,output =
                fence_endpoints(something(boundary.registry),candidates,source_name,source_id,source_serial)
            boundary.failure === nothing || error(boundary.failure)
            queue_identity(boundary.watched[2].properties,boundary.watched[3].properties) ||
                error("optional detector owner metadata unavailable")
            boundary.link = create_object(something(boundary.core),"link-factory",Link;
                properties=passive_link_properties(source.id,source_port.id,input.id,input_port.id),
                on_info=(link,info)->observe_link!(boundary,info),
                on_removed=link->fail!(boundary,"optional detector link removed"),
                on_error=(link,sequence,failure)->fail!(boundary,sprint(showerror,failure)))
        end
        wait_for(boundary,deadline,check) do
            fence_endpoints(something(boundary.registry),candidates,source_name,source_id,source_serial)
            queue_identity(boundary.watched[2].properties,boundary.watched[3].properties)
            info = boundary.info
            info === nothing && return false
            boundary.passive || return false
            source,source_port,input,input_port,output = candidates
            (info.output_node_id,info.output_port_id,info.input_node_id,info.input_port_id) ==
                (source.id,source_port.id,input.id,input_port.id) || error("optional detector link endpoints differ")
            return info.state in (PipeWireAO.LINK_STATE_PAUSED,PipeWireAO.LINK_STATE_ACTIVE)
        end
        return boundary
    catch failure
        try close(boundary) catch cleanup throw(CompositeException([failure,cleanup])) end
        rethrow()
    end
end

failure(boundary::Boundary) = with_thread_loop_lock(boundary.loop) do _
    if boundary.failure === nothing && !boundary.closed
        try
            queue_identity(boundary.watched[2].properties,boundary.watched[3].properties)
        catch failure
            fail!(boundary,sprint(showerror,failure))
        end
        for (name,(id,serial)) in boundary.nodes
            matches = find_globals(something(boundary.registry);interface="PipeWire:Interface:Node",
                properties=("node.name"=>name,))
            if length(matches) != 1 || only(matches).id != id || get(only(matches).properties,"object.serial","") != serial
                fail!(boundary,"optional detector endpoint disappeared or changed: $name")
                break
            end
        end
    end
    boundary.failure
end

function Base.close(boundary::Boundary)
    boundary.closed && return nothing
    boundary.closed = true
    failures = Any[]
    with_thread_loop_lock(boundary.loop) do _
        # A non-lingering core-created link is removed by closing its owned proxy.
        resources = Any[boundary.link]
        append!(resources,(watched.node for watched in boundary.watched))
        append!(resources,(boundary.registry,boundary.core,boundary.context))
        for resource in resources
            resource === nothing && continue
            try close(resource) catch failure push!(failures,failure) end
        end
    end
    try close(boundary.loop) catch failure push!(failures,failure) end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

end
