"""Native framing around the existing serialized calibration effects."""
module HILNativeCalibrationActions

using PipeWireAO
import ..CalibrationServer
import ..HILNativeAcquisitionLifecycle
const Server = CalibrationServer
const Bridge = HILNativeAcquisitionLifecycle
const Codec = Bridge.NativeCalibrationActionCodec
const Client = Bridge.NativeControlClient
const Endpoint = Bridge.NativeControlEndpoint
const Envelope = Bridge.NativeControlCodec
const Lifecycle = Bridge.Codec
const POLL_SECONDS = 0.005

export ActionServer, serve!, action_node, request, result

action_node(lifecycle_node::AbstractString) = String(lifecycle_node) * ".actions"
mutable struct ActionServer{B,E}
    bridge::B
    endpoint::E
    controller::Union{Nothing,Envelope.ControllerIdentity}
    terminal::Union{Nothing,Endpoint.Ticket}
    last_activity::Float64
    released::Bool
end
function ActionServer(bridge::Bridge.Bridge, lifecycle_node::AbstractString)
    bridge.profile === Lifecycle.CALIBRATION_PROFILE ||
        throw(ArgumentError("actions require a calibration lifecycle bridge"))
    bridge.action_endpoint === nothing || error("calibration action endpoint already exists")
    endpoint = Endpoint.Endpoint(Codec.PROFILE, Codec.Command, bridge.runtime.loop,
        bridge.runtime.core, action_node(lifecycle_node),
        bridge.runtime.endpoint.instance, bridge.runtime.endpoint.lifecycle;
        publisher=(filter, params) -> begin
            bridge.runtime.wake[] = true
            update_params!(filter, params)
        end)
    bridge.action_endpoint = endpoint
    return ActionServer(bridge, endpoint, nothing, nothing, Client.monotonic(), false)
end

function Base.close(server::ActionServer)
    try
        close(server.endpoint)
    finally
        server.bridge.action_endpoint === server.endpoint &&
            (server.bridge.action_endpoint = nothing)
    end
    return nothing
end

_cursor(c) = (; domain=c.domain, generation=c.generation, sequence=c.sequence, model_ns=c.model_ns)
_rule(::Codec.Immediate) = (; kind="immediate")
_rule(r::Codec.DiscardExposures) = (; kind="discard_exposures", frames=r.frames)
_rule(r::Codec.ModelTime) = (; kind="model_time", duration_ns=r.duration_ns)
_action(::Codec.Hold) = (; kind="hold")
_action(a::Codec.Adopt) = (; kind="adopt", probe=UInt64(a.probe), figure=a.figure)
_action(a::Codec.Settle) = (; kind="settle", probe=UInt64(a.probe), after=_cursor(a.after), rule=_rule(a.rule))
_action(a::Codec.Collect) = (; kind="collect", probe=UInt64(a.probe), after=_cursor(a.after), measurements=UInt64(a.measurements), frames=UInt64(a.frames))
_action(a::Codec.Capture) = (; kind="capture", probe=UInt64(a.probe), after=_cursor(a.after), frames=UInt64(a.frames))
_action(a::Codec.Restore) = (; kind="restore", figure=a.figure, rule=_rule(a.rule))
_action(::Codec.Release) = (; kind="release")
function request(command::Codec.Command, timeout_ns::UInt64)
    return (; version=UInt8(1), run=command.run, serial=command.serial,
        timeout_ns, action=_action(command.action))
end
_result_cursor(c) = Codec.AcquisitionCursor(c.domain,c.generation,c.sequence,c.model_ns)
_result(::Val{:held}, r) = Codec.Held(_result_cursor(r.cursor))
_result(::Val{:adopted}, r) = Codec.Adopted(_result_cursor(r.cursor),r.figure,r.clipped)
_result(::Val{:settled}, r) = Codec.Settled(_result_cursor(r.cursor))
_result(::Val{:responses}, r) = Codec.Responses(r.values,
    Codec.Exposure[Codec.Exposure(e.domain,e.generation,e.sequence,e.start_model_ns,e.duration_ns) for e in r.exposures],r.valid)
_result(::Val{:captured}, r) = Codec.Captured(_result_cursor(r.cursor),r.manifest,r.sha256,
    UInt32(r.frames),UInt64(r.bytes),UInt64(r.metadata_bytes))
_result(::Val{:restored}, r) = Codec.Restored(r.figure,r.clipped)
_result(::Val{:released}, r) = Codec.Released()
function _result(::Val{:failed}, r)
    reasons = ("cancelled"=>Codec.Cancelled,"endpoint"=>Codec.Endpoint,
        "invalid_evidence"=>Codec.InvalidEvidence,"probe_clipped"=>Codec.ProbeClipped)
    for (name, reason) in reasons
        r.reason == name && return Codec.Failed(reason)
    end
    throw(Server.EndpointFailure())
end
result(value) = _result(Val(Symbol(value.kind)),value)
function native_collect_reply_preflight(action)
    try Codec.preflight_collect_reply(action.measurements,action.frames; message_bytes=0)
    catch error
        error isa ArgumentError || rethrow()
        throw(Server.InvalidRequest())
    end
    return nothing
end

function _operational(server::ActionServer)
    try Endpoint.poll!(server.endpoint)
    catch error; throw(Bridge.TransportFailure(error)) end
    return nothing
end
function _present(server::ActionServer)
    server.controller === nothing && return true
    return with_thread_loop_lock(server.bridge.runtime.loop) do _
        Endpoint.controller_present(server.endpoint, server.controller)
    end
end
function _fault_transport!(server, owner, exception)
    # A published Release is a resolved terminal fact; cleanup must retain it.
    if owner.phase !== :released && !owner.faulted
        Server.fault!(owner)
    end
    throw(_fault_observation(server,owner,exception))
end
function _fault_observation(server,owner,primary)
    owner.faulted || return primary
    try Bridge.lifecycle!(server.bridge,Lifecycle.Fault)
    catch publication
        return CompositeException([primary,publication])
    end
    return primary
end
function _header(server,ticket,result::Int32=Int32(0))
    h = ticket.header
    return Envelope.ReplyHeader(h.controller,server.endpoint.instance,h.token,h.operation,result)
end
function _complete!(server, ticket, value)
    pod = Client.encode_completion(Codec.PROFILE,_header(server,ticket),
        server.endpoint.lifecycle,ticket.command.run,ticket.command.serial,result(value),"")
    Endpoint.complete!(server.endpoint,ticket,pod)
    server.terminal = ticket
    return nothing
end
_initial(::Union{Codec.Hold,Codec.Restore}) = true
_initial(::Codec.Action) = false
_recovery(::Union{Codec.Restore,Codec.Release}) = true
_recovery(::Codec.Action) = false
_contract(::Codec.Action,owner) = true
_contract(a::Union{Codec.Adopt,Codec.Restore},owner) = length(a.figure)==owner.command_count
function _contract(a::Codec.Collect,owner)
    a.measurements==owner.measurement_count || return false
    try native_collect_reply_preflight(a)
    catch error
        error isa Server.InvalidRequest || rethrow()
        return false
    end
    return true
end

"""Apply one staged action outside the shared ThreadLoop lock.

Lifecycle mutation is deferred during an accepted scientific effect; checks
service only safe=false lifecycle commands, controller presence and deadlines.
"""
function apply!(server::ActionServer,owner,ticket; service_control=()->nothing,
        admission_enabled=()->true,io_timeout_ns::UInt64=owner.maximum_timeout_ns)
    command = ticket.command
    if server.controller !== nothing && ticket.header.controller != server.controller
        Endpoint.complete!(server.endpoint,ticket,Client.encode_completion(Codec.PROFILE,
            _header(server,ticket),server.endpoint.lifecycle,command.run,command.serial,
            Codec.Failed(Codec.InvalidEvidence),""))
        server.terminal = ticket
        return nothing
    end
    if server.controller === nothing && !_initial(command.action)
        _complete!(server,ticket,(;kind="failed",reason="invalid_evidence"))
        return nothing
    end
    if !_contract(command.action,owner) || ticket.header.budget_ns > owner.maximum_timeout_ns ||
            (owner.run!=0 && command.run!=owner.run) || command.serial<=owner.serial
        _complete!(server,ticket,(;kind="failed",reason="invalid_evidence"))
        return nothing
    end
    server.controller === nothing && (server.controller=ticket.header.controller)
    server.last_activity = ticket.deadline - ticket.header.budget_ns/1e9
    check_connection = () -> begin
        service_control()
        try
            Endpoint.check_ticket(server.endpoint,ticket)
            Client.monotonic()-server.last_activity < io_timeout_ns/1e9 ||
                error("calibration controller inactivity expired during effect")
        catch error; throw(Server.OwnerServiceAbort(Bridge.TransportFailure(error))) end
        nothing
    end
    check_connection()
    remaining = ticket.deadline - Client.monotonic()
    remaining > 0 || throw(Server.OwnerServiceAbort(Bridge.TransportFailure(ErrorException("calibration action deadline expired"))))
    timeout_ns = min(UInt64(ticket.header.budget_ns), UInt64(max(1,floor(Int64,remaining*1e9))))
    started = time_ns()
    reply = if !admission_enabled() && !_recovery(command.action)
        (; result=(; kind="failed",reason="cancelled"))
    else
        Server.execute!(owner,request(command,timeout_ns); started,check_connection,
            reply_preflight=native_collect_reply_preflight)
    end
    server.released = owner.phase === :released
    owner.faulted && Bridge.lifecycle!(server.bridge,Lifecycle.Fault)
    try _complete!(server,ticket,reply.result)
    catch error
        owner.phase === :released || owner.faulted || Server.fault!(owner)
        throw(Server.OwnerServiceAbort(Bridge.TransportFailure(error)))
    end
    if owner.phase === :released
        server.released = true
        try Bridge.flush_terminal!(server.bridge,ticket.deadline)
        catch error; throw(Server.OwnerServiceAbort(Bridge.TransportFailure(error))) end
    end
    return reply
end

"""Serve one actual controller/run, with finite admission and inactivity waits."""
function serve!(server::ActionServer,owner::Server.Owner;
        accept_timeout_ns::UInt64=UInt64(30_000_000_000),
        io_timeout_ns::UInt64=owner.maximum_timeout_ns,
        should_stop=()->false,service_control=()->nothing,
        service_boundary=service_control,admission_enabled=()->true)
    0 < accept_timeout_ns <= typemax(Int64) && 0 < io_timeout_ns <= typemax(Int64) ||
        throw(ArgumentError("invalid native calibration inactivity bound"))
    admitted_at = nothing
    primary = nothing
    try
        while owner.phase !== :released
            service_boundary()
            should_stop() && throw(Server.EndpointFailure())
            _operational(server)
            enabled = admission_enabled()
            enabled && admitted_at === nothing && (admitted_at=Client.monotonic())
            if server.controller !== nothing
                _present(server) || throw(Bridge.TransportFailure(ErrorException("calibration controller disappeared")))
                Client.monotonic()-server.last_activity < io_timeout_ns/1e9 ||
                    throw(Bridge.TransportFailure(ErrorException("calibration controller inactivity expired")))
            elseif admitted_at !== nothing
                Client.monotonic()-admitted_at < accept_timeout_ns/1e9 ||
                    throw(Bridge.TransportFailure(ErrorException("calibration admission expired")))
            end
            ticket = Endpoint.take!(server.endpoint)
            # Generic ingress may resolve a ticket before effects on expiry or
            # controller removal. Treat its outcome as terminal, never replay it.
            terminal = with_thread_loop_lock(server.bridge.runtime.loop) do _
                server.endpoint.terminal_request
            end
            if terminal !== nothing && terminal !== server.terminal
                server.terminal = terminal
                server.controller === nothing && (server.controller=terminal.header.controller)
                throw(Bridge.TransportFailure(ErrorException("calibration request expired before effect")))
            end
            if ticket !== nothing
                apply!(server,owner,ticket; service_control,admission_enabled,io_timeout_ns)
                server.terminal = server.endpoint.terminal_request
            end
            sleep(POLL_SECONDS)
        end
        return owner
    catch exception
        primary = exception
        if exception isa Server.OwnerServiceAbort
            if exception.cause !== nothing && owner.phase !== :released && !owner.faulted
                Server.fault!(owner)
            end
            if exception.cause !== nothing
                primary = Server.OwnerServiceAbort(_fault_observation(server,owner,exception.cause))
                throw(primary)
            end
            rethrow()
        end
        _fault_transport!(server,owner,exception)
    finally
        server.released = owner.phase === :released
        # Revoke action ingress after the terminal flush or before SCI cleanup.
        # The existing lifecycle endpoint/core remain available for Shutdown.
        try close(server)
        catch cleanup
            primary === nothing && rethrow()
            throw(CompositeException([primary,cleanup]))
        end
    end
end

end # module HILNativeCalibrationActions
