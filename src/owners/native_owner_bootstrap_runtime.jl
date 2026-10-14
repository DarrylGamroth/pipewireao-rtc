"""Cold native bootstrap resources and the reserved ordinary-owner monitor."""
module NativeOwnerBootstrapRuntime

using PipeWireAO
import ThreadPinning
import ..NativeControlCodec
import ..NativeControlClient
import ..NativeControlEndpoint
import ..NativeOwnerBootstrapCodec

const Envelope = NativeControlCodec
const Client = NativeControlClient
const Endpoint = NativeControlEndpoint
const Codec = NativeOwnerBootstrapCodec
const Profile = Codec.Profile
const Commands = Union{Codec.Command{:status}, Codec.Command{:connect}, Codec.Command{:quit}}
const POLL_SECONDS = 0.005

export Runtime, validate_threads, preparation_check!, prepared!, take_connect!,
    check_connect!, connecting!, connected!, await_connected!, cancelled,
    finishing!, fault!, finish!, clean_cancel, flush_terminal!

mutable struct Transport{P<:Profile,C,E,L}
    profile::P
    loop::ThreadLoop
    context::Context
    core::C
    endpoint::E
    registry_listener::L
    acknowledged_sequence::Base.RefValue{Cint}
    wake::Base.Threads.Atomic{Bool}
    closed::Bool
end

"""Publish Preparing before the existing owner prepares its science or plant."""
function Transport(profile::P, remote::AbstractString, name::AbstractString,
        instance::Int64) where {P<:Profile}
    path = Client.private_remote(remote)
    loop = ThreadLoop("rtc-bootstrap")
    context = core = endpoint = registry_listener = nothing
    endpoint_ref = Ref{Union{Nothing,Endpoint.Endpoint}}(nothing)
    acknowledged_sequence = Ref{Cint}(-1)
    wake = Base.Threads.Atomic{Bool}(false)
    connection_failure = Ref{Union{Nothing,String}}(nothing)
    try
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => path),
                on_done=(core, id, sequence) -> begin
                    id == 0 && (acknowledged_sequence[] = sequence)
                    nothing
                end,
                on_error=(core, id, sequence, error) -> begin
                    connection_failure[] = sprint(showerror, error)
                    current = endpoint_ref[]
                    current === nothing || (current.failure = connection_failure[])
                    wake[] = true
                    nothing
                end)
            endpoint = Endpoint.Endpoint(profile, Commands, loop, core,
                name, instance, Codec.Preparing;
                publisher=(filter, params) -> begin
                    wake[] = true
                    update_params!(filter, params)
                end)
            registry_listener = add_listener!(something(endpoint.registry);
                on_global_added=(registry, global_object) -> (wake[] = true; nothing),
                on_global_removed=(registry, id) -> (wake[] = true; nothing))
            endpoint_ref[] = endpoint
            connection_failure[] === nothing || (endpoint.failure = connection_failure[])
        end
        start!(loop)
        return Transport(profile, loop, context, core, endpoint, registry_listener,
            acknowledged_sequence, wake, false)
    catch primary
        failures = Exception[primary]
        try
            with_thread_loop_lock(loop) do _
                for resource in (registry_listener, endpoint, core, context)
                    resource === nothing && continue
                    try close(resource) catch cleanup; push!(failures, cleanup) end
                end
            end
        catch cleanup
            push!(failures, cleanup)
        end
        try close(loop) catch cleanup; push!(failures, cleanup) end
        length(failures) == 1 && rethrow()
        throw(CompositeException(failures))
    end
end

"""Cold ingress hint, including Core error."""
@inline has_pending(runtime::Transport) = runtime.wake[]

poll!(runtime::Transport) = Endpoint.poll!(runtime.endpoint)
take!(runtime::Transport) = Endpoint.take!(runtime.endpoint)

"Check quiet transport health without registry traversal; consume only the old wake."
function _poll_ready!(runtime::Transport)
    wake = Base.Threads.atomic_xchg!(runtime.wake, false)
    pending = with_thread_loop_lock(runtime.loop) do _
        Endpoint.operational(runtime.endpoint)
        retained = runtime.endpoint.retained_controller
        retained === nothing || Endpoint.controller_present(runtime.endpoint, retained) ||
            error("retained native bootstrap controller was revoked")
        runtime.endpoint.pending !== nothing
    end
    if wake || pending
        poll!(runtime)
        return true
    end
    return false
end
function lifecycle!(runtime::Transport, lifecycle::Codec.Lifecycle)
    Endpoint.state!(runtime.endpoint, lifecycle)
    return nothing
end

"""Publish the result of an accepted ticket after the sole owner has applied it."""
function complete!(runtime::Transport, ticket::Endpoint.Ticket,
        lifecycle::Codec.Lifecycle; result::Int32=Int32(0), message::AbstractString="",
        terminal::Bool=false)
    header = Envelope.ReplyHeader(ticket.header.controller, runtime.endpoint.instance,
        ticket.header.token, ticket.header.operation, result)
    completion = Client.encode_completion(runtime.profile, header, lifecycle, message)
    Endpoint.complete!(runtime.endpoint, ticket, completion; terminal)
    return nothing
end

"""Synchronize a terminal publication before removing the public endpoint."""
function flush_terminal!(runtime::Transport, deadline::Float64; check=()->nothing)
    Client.deadline_check(deadline, check)
    sequence = with_thread_loop_lock(runtime.loop) do _
        Endpoint.operational(runtime.endpoint)
        Client.deadline_check(deadline, check)
        sync!(runtime.core)
    end
    while true
        Client.deadline_check(deadline, check)
        observed = with_thread_loop_lock(runtime.loop) do _
            Endpoint.operational(runtime.endpoint)
            runtime.acknowledged_sequence[] == sequence
        end
        Client.deadline_check(deadline, check)
        observed && return nothing
        sleep(min(POLL_SECONDS, max(0.0, deadline - Client.monotonic())))
    end
end

function Base.close(runtime::Transport)
    runtime.closed && return nothing
    runtime.closed = true
    failures = Exception[]
    try
        with_thread_loop_lock(runtime.loop) do _
            for resource in (runtime.registry_listener, runtime.endpoint,
                    runtime.core, runtime.context)
                try close(resource) catch error; push!(failures, error) end
            end
        end
    catch error
        push!(failures, error)
    end
    try close(runtime.loop) catch error; push!(failures, error) end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end


abstract type ConnectionHooks end
struct Hooks{R,Q} <: ConnectionHooks
    ready::R
    quit::Q
end

"""Cold facts/handshakes; science stays on the constructing default thread 1."""
mutable struct Runtime{T}
    transport::T
    lock::ReentrantLock
    prepare_done::Bool
    connect_ticket::Union{Nothing,Endpoint.Ticket}
    connect_taken::Bool
    connect_done::Bool
    hooks::Union{Nothing,ConnectionHooks}
    main_finished::Bool
    main_error::Union{Nothing,Exception}
    failure::Union{Nothing,Exception}
    cancel::Base.Threads.Atomic{Bool}
    monitor_ready::Base.Threads.Atomic{Bool}
    # ThreadPinning returns a StableTask. This cold handle never enters science.
    monitor::Any
end
function validate_threads()
    VERSION >= v"1.12" || throw(ArgumentError("native bootstrap requires Julia >= 1.12"))
    Base.Threads.threadid() == 1 || throw(ArgumentError("native owner must construct on Julia thread 1"))
    ids = ThreadPinning.threadids(; threadpool=:default)
    length(ids) >= 2 && ids == collect(1:length(ids)) ||
        throw(ArgumentError("native owner requires --threads=N,0 with N >= 2; thread 2 is the cold monitor"))
    return nothing
end
function Runtime(remote::AbstractString, name::AbstractString, instance::Int64)
    validate_threads()
    transport = Transport(Codec.PROFILE, remote, name, instance)
    runtime = Runtime(transport, ReentrantLock(), false, nothing, false, false,
        nothing, false, nothing, nothing, Base.Threads.Atomic{Bool}(false),
        Base.Threads.Atomic{Bool}(false), nothing)
    try
        runtime.monitor = ThreadPinning.@spawnat 2 serve!(runtime)
        deadline = Client.monotonic() + 5.0
        while !runtime.monitor_ready[]
            Client.deadline_check(deadline, () -> nothing)
            sleep(POLL_SECONDS)
        end
        return runtime
    catch primary
        runtime.cancel[] = true
        lock(runtime.lock) do
            runtime.main_finished = true
        end
        if runtime.monitor !== nothing
            timedwait(() -> istaskdone(runtime.monitor), 2.0; pollint=POLL_SECONDS) == :ok ||
                throw(CompositeException([primary, ErrorException("bootstrap monitor did not terminate; resources retained for finite process cleanup")]))
            wait(runtime.monitor)
        end
        try close(transport) catch cleanup; throw(CompositeException([primary, cleanup])) end
        rethrow()
    end
end
cancelled(runtime::Runtime) = runtime.cancel[]
clean_cancel(runtime::Runtime) = cancelled(runtime) && lock(runtime.lock) do
    runtime.failure === nothing
end
function preparation_check!(runtime::Runtime)
    failure = lock(runtime.lock) do
        runtime.failure
    end
    failure === nothing || throw(failure)
    cancelled(runtime) && throw(InterruptException())
    return nothing
end
function prepared!(runtime::Runtime)
    preparation_check!(runtime)
    lock(runtime.lock) do
        runtime.prepare_done = true
    end
    return nothing
end
function take_connect!(runtime::Runtime)
    while true
        preparation_check!(runtime)
        ticket = lock(runtime.lock) do
            if runtime.connect_ticket !== nothing && !runtime.connect_taken
                runtime.connect_taken = true
                return runtime.connect_ticket
            end
            nothing
        end
        ticket === nothing || return ticket
        sleep(POLL_SECONDS)
    end
end
function check_connect!(runtime::Runtime, ticket::Endpoint.Ticket)
    preparation_check!(runtime)
    Endpoint.check_ticket(runtime.transport.endpoint, ticket)
    return nothing
end
function connecting!(runtime::Runtime, ticket::Endpoint.Ticket; ready, quit)
    check_connect!(runtime, ticket)
    lock(runtime.lock) do
        cancelled(runtime) && throw(InterruptException())
        runtime.hooks = Hooks(ready, quit)
    end
    return nothing
end
function connected!(runtime::Runtime, ticket::Endpoint.Ticket)
    check_connect!(runtime, ticket)
    lock(runtime.lock) do
        runtime.connect_done = true
    end
    return nothing
end
function await_connected!(runtime::Runtime, ticket::Endpoint.Ticket)
    while true
        preparation_check!(runtime)
        done = with_thread_loop_lock(runtime.transport.loop) do _
            endpoint = runtime.transport.endpoint
            endpoint.lifecycle === Codec.Connected && endpoint.pending !== ticket && return true
            Endpoint.check_ticket(endpoint, ticket)
            false
        end
        done && return nothing
        sleep(POLL_SECONDS)
    end
end
"""Exclude monitor reads/quit before main closes its scientific node."""
function finishing!(runtime::Runtime)
    lock(runtime.lock) do
        runtime.hooks = nothing
    end
    return nothing
end
function fault!(runtime::Runtime, error::Exception)
    lock(runtime.lock) do
        runtime.main_error === nothing && (runtime.main_error = error)
    end
    return nothing
end
function finish!(runtime::Runtime)
    finishing!(runtime)
    lock(runtime.lock) do
        runtime.main_finished = true
    end
    wait(runtime.monitor)
    failure = lock(runtime.lock) do
        runtime.failure
    end
    failure === nothing || throw(failure)
    return nothing
end
function _message(error::Exception)
    text = sprint(showerror, error)
    io = IOBuffer()
    bytes = 0
    for char in text
        width = ncodeunits(string(char))
        bytes + width <= 8192 || break
        print(io, char == '\0' ? '?' : char)
        bytes += width
    end
    return String(Base.take!(io))
end
function _stop!(runtime::Runtime)
    runtime.cancel[] = true
    lock(runtime.lock) do
        runtime.hooks === nothing || Base.invokelatest(runtime.hooks.quit)
    end
    return nothing
end
function _ready(runtime::Runtime)
    lock(runtime.lock) do
        runtime.connect_done || (runtime.hooks !== nothing && Base.invokelatest(runtime.hooks.ready))
    end
end
struct Facts
    prepared::Bool
    finished::Bool
    error::Union{Nothing,Exception}
end
function _facts(runtime::Runtime)
    lock(runtime.lock) do
        Facts(runtime.prepare_done, runtime.main_finished, runtime.main_error)
    end
end
function _apply!(runtime::Runtime, ticket, ::Codec.Command{:status}, lifecycle)
    error = _facts(runtime).error
    try
        complete!(runtime.transport, ticket, lifecycle; message=error === nothing ? "" : _message(error))
    catch failure
        endpoint = runtime.transport.endpoint
        neutral = with_thread_loop_lock(runtime.transport.loop) do _
            Endpoint.operational(endpoint)
            Client.monotonic() >= ticket.deadline || !Endpoint.controller_present(endpoint, ticket.header.controller)
        end
        neutral || rethrow()
        complete!(runtime.transport, ticket, lifecycle; result=Int32(-110), message="Status expired or controller removed")
    end
    return nothing
end
function _apply!(runtime::Runtime, ticket, ::Codec.Command{:connect}, lifecycle)
    if lifecycle !== Codec.Prepared
        complete!(runtime.transport, ticket, lifecycle; result=Int32(-22), message="Connect requires Prepared")
        return nothing
    end
    lock(runtime.lock) do
        runtime.connect_ticket = ticket
    end
    return ticket
end
function _apply!(runtime::Runtime, ticket, ::Codec.Command{:quit}, lifecycle)
    _stop!(runtime)
    return ticket
end
function _advance!(runtime, ticket, ::Codec.Command{:connect}, facts, lifecycle)
    if facts.error !== nothing || facts.finished
        message = facts.error === nothing ? "owner stopped before Connect registered" : _message(facts.error)
        complete!(runtime.transport, ticket, lifecycle; result=Int32(-5), message)
        return nothing, lifecycle, false
    elseif _ready(runtime)
        # The supervisor retains this exact connection through reset and Quit.
        # Remove global discovery before publishing Connected; main cannot enter
        # science until the accepted ticket has completed below. Bound controller
        # proxies still report removal/error and exact NodeInfo proof changes.
        with_thread_loop_lock(runtime.transport.loop) do _
            Endpoint.check_ticket(runtime.transport.endpoint, ticket)
            close(runtime.transport.registry_listener)
            Endpoint.retain_controller!(runtime.transport.endpoint, ticket)
        end
        lifecycle = Codec.Connected
        lifecycle!(runtime.transport, lifecycle)
        complete!(runtime.transport, ticket, lifecycle)
        return nothing, lifecycle, false
    end
    return ticket, lifecycle, false
end
function _advance!(runtime, ticket, ::Codec.Command{:quit}, facts, lifecycle)
    if facts.finished
        result = facts.error === nothing ? Int32(0) : Int32(-5)
        lifecycle = result == 0 ? Codec.Stopped : Codec.Fault
        lifecycle!(runtime.transport, lifecycle)
        result == 0 && Endpoint.retain_controller!(runtime.transport.endpoint, ticket)
        complete!(runtime.transport, ticket, lifecycle; result,
            message=facts.error === nothing ? "" : _message(facts.error), terminal=result == 0)
        flush_terminal!(runtime.transport, ticket.deadline)
        if result == 0
            # main_finished proves scientific cleanup; retain only the cold
            # control transport until the reader releases this exact controller.
            Endpoint.wait_terminal_release!(runtime.transport.endpoint, ticket)
        end
        return nothing, lifecycle, true
    end
    # Repeat public quit until main excludes hooks before close: quit may
    # otherwise race main entering its native blocking run loop.
    _stop!(runtime)
    return ticket, lifecycle, false
end
_fault_reply!(runtime, ticket, command::Codec.Command{:status}, lifecycle) =
    _apply!(runtime, ticket, command, lifecycle)
_fault_reply!(runtime, ticket, command::Union{Codec.Command{:connect},Codec.Command{:quit}}, lifecycle) =
    complete!(runtime.transport, ticket, lifecycle; result=Int32(-5), message="owner cleanup after failure")

function _idle!()
    # Julia Timer progress can depend on the construction thread's libuv loop.
    # This ordinary cold syscall stays responsive while main is in native code.
    @ccall gc_safe=true usleep(Cuint(5000)::Cuint)::Cint
    yield()
    return nothing
end
function serve!(runtime::Runtime)
    runtime.monitor_ready[] = true
    transport = runtime.transport
    active = nothing
    lifecycle = Codec.Preparing
    try
        while true
            ingress = _poll_ready!(transport)
            facts = _facts(runtime)
            if facts.error !== nothing && lifecycle !== Codec.Fault
                lifecycle = Codec.Fault
                lifecycle!(transport, lifecycle)
            elseif facts.prepared && lifecycle === Codec.Preparing && !cancelled(runtime)
                lifecycle = Codec.Prepared
                lifecycle!(transport, lifecycle)
            end
            if active === nothing && ingress
                ticket = take!(transport)
                ticket === nothing || (active = _apply!(runtime, ticket, ticket.command, lifecycle))
            end
            if active !== nothing
                Endpoint.check_ticket(transport.endpoint, active)
                active, lifecycle, done = _advance!(runtime, active, active.command, facts, lifecycle)
                done && return nothing
            end
            if facts.finished && active === nothing
                lifecycle = facts.error === nothing ? Codec.Stopped : Codec.Fault
                lifecycle!(transport, lifecycle)
                flush_terminal!(transport, Client.monotonic() + 5.0)
                return nothing
            end
            _idle!()
        end
    catch error
        lock(runtime.lock) do
            runtime.failure === nothing && (runtime.failure = error)
        end
        # Preserve actual completed cleanup even when terminal transport fails.
        facts = _facts(runtime)
        failed_lifecycle = facts.finished && facts.error === nothing ? Codec.Stopped : Codec.Fault
        try
            lifecycle!(transport, failed_lifecycle)
        catch publication
            lock(runtime.lock) do
                runtime.failure = CompositeException([error, publication])
            end
        end
        try
            _stop!(runtime)
            # Release an uncertain accepted effect only with a known negative
            # result. Never acknowledge an expired effect as successful.
            if active !== nothing
                pending = with_thread_loop_lock(transport.loop) do _
                    transport.endpoint.pending === active && transport.endpoint.applying
                end
                pending && complete!(transport, active, failed_lifecycle;
                    result=Int32(-5), message=_message(error))
            end
            # Cooperative native quit can race main entering run!. Keep the
            # cold public quit hook available until main excludes it for close.
            cleanup_deadline = Client.monotonic() + 5.0
            while !_facts(runtime).finished && Client.monotonic() < cleanup_deadline
                _stop!(runtime)
                Endpoint.poll!(transport.endpoint)
                ticket = take!(transport)
                if ticket !== nothing
                    _fault_reply!(runtime, ticket, ticket.command, failed_lifecycle)
                end
                _idle!()
            end
            flush_terminal!(transport, cleanup_deadline)
        catch cleanup
            lock(runtime.lock) do
                runtime.failure = CompositeException([something(runtime.failure), cleanup])
            end
        end
        return nothing
    end
end
function Base.close(runtime::Runtime)
    cancelled(runtime) || _stop!(runtime)
    lock(runtime.lock) do
        runtime.main_finished = true
    end
    runtime.monitor === nothing || wait(runtime.monitor)
    close(runtime.transport)
    return nothing
end
end # module NativeOwnerBootstrapRuntime
