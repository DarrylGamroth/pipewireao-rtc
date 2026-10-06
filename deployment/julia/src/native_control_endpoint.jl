"""Bounded cold owner ingress; the sole owner applies staged effects outside callbacks."""
module NativeControlEndpoint

using PipeWireAO
import ..NativeControlCodec
import ..NativeControlClient

const Envelope = NativeControlCodec
const Client = NativeControlClient
const SPA = PipeWireAO.SPA
const MAX_CONTROLLERS = 32
monotonic() = time_ns() / 1.0e9

"One actual registry incarnation, verified using full NodeInfo."
mutable struct Controller
    global_id::UInt32
    serial::UInt64
    identity::Union{Nothing,Envelope.ControllerIdentity}
    name::String
    pid::UInt32
    node::Union{Nothing,Node}
    verified::Bool
    retired::Bool
end

struct Ticket{C}
    header::Envelope.RequestHeader
    command::C
    payload::Vector{UInt8}
    deadline::Float64
end

mutable struct Endpoint{P<:Client.Profile,C,L,F}
    profile::P
    loop::ThreadLoop
    registry::Union{Nothing,Registry}
    filter::Union{Nothing,Filter}
    instance::Int64
    lifecycle::L
    publisher::F
    controllers::Vector{Controller}
    pending::Union{Nothing,Ticket{C}}
    applying::Bool
    last_token::Int64
    terminal_request::Union{Nothing,Ticket{C}}
    completion::Pod
    rejection::Pod
    failure::Union{Nothing,String}
    closed::Bool
end

function metadata(identity::Envelope.ControllerIdentity, pid::UInt32)
    return (
        "pipewireao.rtc-control.protocol" => Client.PROTOCOL,
        "pipewireao.rtc-control.profile" => Client.CONTROLLER_PROFILE,
        "pipewireao.rtc-control.instance" => string(identity.instance),
        "pipewireao.rtc-control.owner-pid" => string(pid))
end

function controller_info!(controller::Controller, info::NodeInfo)
    controller.retired && return nothing
    valid = info.id == controller.global_id && info.error === nothing &&
        info.n_input_ports == 0 && info.n_output_ports == 0
    if (info.change_mask & NODE_CHANGE_PROPERTIES) != 0
        serial = tryparse(UInt64, get(info.properties, "object.serial", ""))
        instance = tryparse(Int64, get(info.properties, "pipewireao.rtc-control.instance", ""))
        pid = tryparse(UInt32, get(info.properties, "pipewireao.rtc-control.owner-pid", ""))
        valid &= get(info.properties, "node.name", nothing) == controller.name &&
            serial == controller.serial && instance !== nothing && instance > 0 &&
            pid !== nothing && pid > 0
        if valid
            identity = Envelope.ControllerIdentity(controller.global_id, controller.serial, instance)
            valid &= all(get(info.properties, key, nothing) == value for (key, value) in metadata(identity, pid))
            if controller.identity !== nothing
                valid &= identity == controller.identity && pid == controller.pid
            end
            if valid
                controller.identity = identity
                controller.pid = pid
                controller.verified = true
            end
        end
    end
    valid || (controller.retired = true; controller.verified = false)
    return nothing
end

function capability(endpoint::Endpoint)
    names = Client.capability_names(endpoint.profile)
    rows = SPA.Struct(Pod[Pod(SPA.Struct(Pod(SPA.Id(controller.global_id)),
        Pod(reinterpret(Int64, controller.serial)), Pod(something(controller.identity).instance)))
        for controller in endpoint.controllers if controller.verified && !controller.retired])
    return Pod(props_param(SPA.Props(names[1] => Int32(1), names[2] => endpoint.instance,
        names[3] => SPA.Id(getpid()), names[4] => SPA.Id(UInt32(endpoint.lifecycle)),
        names[5] => endpoint.last_token, names[6] => rows)))
end

function healthy(endpoint::Endpoint)
    endpoint.closed && throw(InvalidStateException("native endpoint closed", :closed))
    endpoint.failure === nothing ||
        throw(InvalidStateException("native endpoint failed: $(endpoint.failure)", :failed))
    return nothing
end

function operational(endpoint::Endpoint)
    healthy(endpoint)
    isrunning(endpoint.loop) || throw(InvalidStateException("native owner loop stopped", :stopped))
    try
        state = filter_state(something(endpoint.filter))
        state == PipeWireAO.LibPipeWire.PW_FILTER_STATE_UNCONNECTED &&
            throw(InvalidStateException("native owner filter disconnected", :disconnected))
    catch error
        endpoint.failure = sprint(showerror, error)
        rethrow()
    end
    return nothing
end

function publish!(endpoint::Endpoint)
    endpoint.closed && return nothing
    healthy(endpoint)
    try
        endpoint.publisher(something(endpoint.filter),
            [capability(endpoint), endpoint.completion, endpoint.rejection])
    catch error
        endpoint.failure = sprint(showerror, error)
        rethrow()
    end
    return nothing
end

function refresh_controllers!(endpoint::Endpoint)
    healthy(endpoint)
    registry = something(endpoint.registry)
    globals = find_globals(registry; interface="PipeWire:Interface:Node")
    changed = false
    for controller in endpoint.controllers
        matches = filter(global_object -> global_object.id == controller.global_id &&
            get(global_object.properties, "object.serial", nothing) == string(controller.serial), globals)
        if isempty(matches) && !controller.retired
            controller.retired = true
            controller.verified = false
            changed = true
        end
    end
    for controller in endpoint.controllers
        if controller.retired && controller.node !== nothing
            close(controller.node)
            controller.node = nothing
        end
    end
    # A changed proof on a still-live registry incarnation is permanently
    # revoked. Retain its bounded tombstone until that incarnation disappears.
    filter!(controller -> !controller.retired || any(global_object ->
        global_object.id == controller.global_id &&
        get(global_object.properties, "object.serial", nothing) == string(controller.serial), globals),
        endpoint.controllers)
    for global_object in globals
        length(endpoint.controllers) < MAX_CONTROLLERS || break
        any(controller -> controller.global_id == global_object.id, endpoint.controllers) && continue
        name = get(global_object.properties, "node.name", "")
        startswith(name, "pipewireao.rtc.controller.") || continue
        serial = tryparse(UInt64, get(global_object.properties, "object.serial", ""))
        if isempty(name) || ncodeunits(name) > 128 || serial === nothing || serial == 0 ||
                global_object.id in (UInt32(0), typemax(UInt32))
            continue
        end
        # Registry announcements are sparse. Bind a bounded set of candidate
        # names, then admit only the exact full NodeInfo proof, never the name.
        controller = Controller(global_object.id, serial, nothing, name, UInt32(0),
            nothing, false, false)
        controller.node = bind(registry, global_object, Node;
            on_info=(node, info) -> begin
                controller_info!(controller, info)
                publish!(endpoint)
                nothing
            end,
            on_removed=node -> begin
                controller.retired = true
                controller.verified = false
                publish!(endpoint)
                nothing
            end,
            on_error=(node, sequence, error) -> begin
                controller.retired = true
                controller.verified = false
                publish!(endpoint)
                nothing
            end)
        push!(endpoint.controllers, controller)
        changed = true
    end
    changed && publish!(endpoint)
    return nothing
end

controller_present(endpoint::Endpoint, identity::Envelope.ControllerIdentity) =
    any(controller -> controller.identity == identity && controller.verified && !controller.retired,
        endpoint.controllers)

function rejection!(endpoint::Endpoint, header::Union{Nothing,Envelope.RequestHeader}, result::Int32)
    reply = header === nothing ? Envelope.ReplyHeader(endpoint.instance, result) :
        Envelope.ReplyHeader(header.controller, endpoint.instance, header.token, header.operation, result)
    endpoint.rejection = Client.encode_rejection(endpoint.profile, reply, endpoint.lifecycle)
    publish!(endpoint)
    return nothing
end

function admission(endpoint::Endpoint, header::Envelope.RequestHeader, bytes)
    header.endpoint_instance == endpoint.instance || return Int32(-116)
    controller_present(endpoint, header.controller) || return Int32(-116)
    header.token < endpoint.last_token && return Int32(-116)
    for previous in (endpoint.pending, endpoint.terminal_request)
        previous === nothing && continue
        if header.token == previous.header.token
            return header.controller == previous.header.controller &&
                header.operation == previous.header.operation && bytes == previous.payload ?
                Int32(1) : Int32(-114)
        end
    end
    header.token > endpoint.last_token || return Int32(-116)
    endpoint.pending === nothing || return Int32(-16)
    return Int32(0)
end

function stage!(endpoint::Endpoint{P,C}, pod::Pod) where {P,C}
    operational(endpoint)
    received = monotonic()
    header = nothing
    # Only request decoding is classified as invalid input. Publication failure
    # is fatal and must never turn an accepted, executable ticket into rejection.
    decoded = try
        header, payload = Envelope.decode_request(pod)
        command = Client.decode_request(endpoint.profile, header, payload)
        (command, copy(Pod(payload).data))
    catch error
        return rejection!(endpoint, header, Int32(-22))
    end
    command, bytes = decoded
    result = admission(endpoint, header, bytes)
    result < 0 && return rejection!(endpoint, header, result)
    if result == 1
        publish!(endpoint)
        return nothing
    end
    budget = min(header.budget_ns / 1.0e9, Client.maximum_budget(endpoint.profile))
    endpoint.pending = Ticket{C}(header, command, bytes, received + budget)
    endpoint.last_token = header.token
    endpoint.applying = false
    publish!(endpoint)
    return nothing
end

"Create an inactive no-port endpoint on the owner's existing Core/ThreadLoop."
function Endpoint(profile::P, ::Type{C}, loop::ThreadLoop, core::CoreConnection,
        name::AbstractString, instance::Int64, lifecycle::L;
        publisher=update_params!, properties_extra=Dict{String,String}()) where {P<:Client.Profile,C,L}
    instance > 0 || throw(ArgumentError("native owner instance must be positive"))
    0 < ncodeunits(name) <= 128 && isvalid(name) && !occursin('\0', name) ||
        throw(ArgumentError("native owner name must be bounded nonempty UTF-8"))
    L === Client.lifecycle_type(profile) || throw(ArgumentError("wrong native owner lifecycle type"))
    initial = Envelope.encode_completion(Envelope.ReplyHeader(instance, Int32(0)), SPA.Struct();
        endpoint=Client.reply_endpoint(profile))
    rejected = Client.encode_rejection(profile, Envelope.ReplyHeader(instance, Int32(-22)), lifecycle)
    endpoint = Endpoint{P,C,L,typeof(publisher)}(profile, loop, nothing, nothing, instance, lifecycle, publisher, Controller[],
        nothing, false, 0, nothing, initial, rejected, nothing, false)
    try
        with_thread_loop_lock(loop) do _
            endpoint.registry = Registry(core)
            properties = Dict(
                "node.name" => String(name), "media.class" => "Control",
                "pipewireao.rtc-control.protocol" => Client.PROTOCOL,
                "pipewireao.rtc-control.profile" => Client.profile_name(profile),
                "pipewireao.rtc-control.instance" => string(instance),
                "pipewireao.rtc-control.owner-pid" => string(getpid()))
            any(key -> haskey(properties,key),keys(properties_extra)) &&
                throw(ArgumentError("extra native properties cannot replace common identity"))
            merge!(properties,properties_extra)
            endpoint.filter = Filter(core, String(name); properties,
                on_param_changed=(filter, port, id, pod) -> begin
                    if port === nothing && id == SPA.PARAM_PROPS && pod !== nothing
                        stage!(endpoint, pod)
                    end
                    nothing
                end)
            publish!(endpoint)
            connect!(something(endpoint.filter); flags=FILTER_ASYNC | FILTER_INACTIVE,
                params=[capability(endpoint), endpoint.completion, endpoint.rejection])
        end
        return endpoint
    catch primary
        try
            close(endpoint)
        catch cleanup
            throw(CompositeException([primary, cleanup]))
        end
        rethrow()
    end
end

function poll!(endpoint::Endpoint)
    with_thread_loop_lock(endpoint.loop) do _
        operational(endpoint)
        refresh_controllers!(endpoint)
    end
    return nothing
end

"Take the sole staged ticket for execution outside the PipeWire loop lock."
function take!(endpoint::Endpoint)
    return with_thread_loop_lock(endpoint.loop) do _
        operational(endpoint)
        refresh_controllers!(endpoint)
        ticket = endpoint.pending
        ticket === nothing && return nothing
        endpoint.applying && return nothing
        if monotonic() >= ticket.deadline || !controller_present(endpoint, ticket.header.controller)
            header = Envelope.ReplyHeader(ticket.header.controller, endpoint.instance,
                ticket.header.token, ticket.header.operation, Int32(-110))
            endpoint.completion = Client.encode_failure(endpoint.profile, header, endpoint.lifecycle, ticket.command)
            publish!(endpoint)
            endpoint.terminal_request = ticket
            endpoint.pending = nothing
            return nothing
        end
        endpoint.applying = true
        ticket
    end
end

function check_ticket(endpoint::Endpoint, ticket::Ticket)
    with_thread_loop_lock(endpoint.loop) do _
        operational(endpoint)
        endpoint.pending === ticket && endpoint.applying || error("native owner ticket is not applying")
        refresh_controllers!(endpoint)
        controller_present(endpoint, ticket.header.controller) || error("native controller disappeared")
        monotonic() < ticket.deadline || error("native owner request deadline expired")
    end
    return nothing
end

function complete!(endpoint::Endpoint, ticket::Ticket, completion::Pod)
    with_thread_loop_lock(endpoint.loop) do _
        operational(endpoint)
        endpoint.pending === ticket && endpoint.applying || error("native owner ticket is not applying")
        header, _ = Envelope.decode_completion(completion; endpoint=Client.reply_endpoint(endpoint.profile))
        Client.same_request(header, ticket.header) || throw(ArgumentError("completion does not match staged ticket"))
        if header.result == 0
            check_ticket(endpoint, ticket)
        end
        endpoint.completion = completion
        publish!(endpoint)
        endpoint.terminal_request = ticket
        endpoint.pending = nothing
        endpoint.applying = false
    end
    return nothing
end

function state!(endpoint::Endpoint{P,C,L}, lifecycle::L) where {P,C,L}
    with_thread_loop_lock(endpoint.loop) do _
        operational(endpoint)
        endpoint.lifecycle = lifecycle
        publish!(endpoint)
    end
    return nothing
end

function Base.close(endpoint::Endpoint)
    endpoint.closed && return nothing
    failures = Exception[]
    with_thread_loop_lock(endpoint.loop) do _
        endpoint.closed = true
        for controller in endpoint.controllers
            controller.node === nothing && continue
            try
                close(controller.node)
            catch error
                push!(failures, error)
            end
        end
        for resource in (endpoint.filter, endpoint.registry)
            resource === nothing && continue
            try
                close(resource)
            catch error
                push!(failures, error)
            end
        end
    end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

end # module NativeControlEndpoint
