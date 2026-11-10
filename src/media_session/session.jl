struct ClientBound <: AbstractEvent
    local_id::UInt32
    global_id::UInt32
end
struct ShutdownRequested <: AbstractEvent end

"""One session's control state, owned by its creating task and OS thread.

The native callbacks stage copied `AbstractEvent`s. Only the owner's Agent duty
cycle applies those observations, dispatches Hsm events and starts typed effects.
Scientific graph state remains in its separate process and data thread.
"""
mutable struct Session{C,R,F,G,S<:Clocks.AbstractNanoClock}
    configuration::Dict{String,Any}
    declared_links::Vector{DeploymentConfiguration.LinkDeclaration}
    loop::MainLoop
    context::Context{MainLoop}
    core::C
    registry::R
    registry_listener::ManagedListener
    endpoint::F
    controller_endpoint::G
    owner::Task
    source_clock::S
    clock::Clocks.CachedNanoClock
    machine::Machine{Clocks.CachedNanoClock}
    ingress::Ingress.Gate{Clocks.CachedNanoClock}
    queue::EventQueue
    objects::Dict{UInt32,Object}
    captured::Dict{UInt32,Captured}
    retired::Dict{UInt32,UInt64}
    graphs::Dict{String,UInt64}
    groups::Dict{String,Group}
    links::Vector{LinkRecord}
    owners::Vector{AbstractOwner}
    sources::Vector{AbstractSource}
    parameters::Union{Nothing,AbstractOwner}
    core_info::Union{Nothing,CoreInfo}
    client_id::UInt32
    controller::Union{Nothing,ControlCodec.ControllerIdentity}
    controller_facts::Vector{Ingress.Controller}
    token::Int64
    parameters_io::Dict{Tuple{UInt32,Cint},Parameters}
    barriers::Dict{Cint,Barrier}
    requests::Dict{UInt64,Ingress.AbstractTicket}
    next_request::UInt64
    active_job::Union{Nothing,Job}
    active_task::Union{Nothing,Task}
    effect_result::Union{Nothing,EffectCompleted,EffectFailed}
    withdrawing::Bool
    overflow_seen::Bool
    transport_error::Union{Nothing,String}
    done::Bool
    exitcode::Int
end

function update!(session::Session, event::ClientBound)
    # PipeWire's local core client proxy has ID 1. The server supplies its
    # global ID through this public Core event; no daemon layout is inspected.
    event.local_id == UInt32(1) || return nothing
    if session.client_id != 0 && session.client_id != event.global_id
        required_lost!(session.machine, "session client incarnation changed")
    end
    session.client_id = event.global_id
    return nothing
end
function update!(session::Session, event::RequestReceived)
    Ingress.receive!(session.ingress, event.pod, event.received)
    return nothing
end
function update!(session::Session, event::EffectCompleted)
    current = _matches(session.machine, event.ticket)
    complete!(session.machine, event)
    current && after_completion!(session, event.ticket.effect)
    return nothing
end
after_completion!(session, ::AbstractEffect) = nothing
function after_completion!(session, ::PublishQuit)
    session.exitcode = 0
    session.done = true
    return nothing
end
function after_completion!(session, ::Disconnect)
    @error "Session disconnected during cleanup" failure=session.machine.failure cleanup=session.machine.cleanup_failure
    session.exitcode = 1
    session.done = true
    return nothing
end
function update!(session::Session, event::EffectFailed)
    current = _matches(session.machine, event.ticket)
    fail!(session.machine, event)
    current && after_failure!(session, event.ticket.effect)
    return nothing
end
after_failure!(session, ::AbstractEffect) = nothing
after_failure!(session, effect::PublishQuit) = after_completion!(session, effect)
after_failure!(session, effect::Disconnect) = after_completion!(session, effect)
after_retirement!(session, ::AbstractEffect) = nothing
after_retirement!(session, effect::PublishQuit) = after_completion!(session, effect)
function update!(session::Session, event::FilterChanged)
    event.state == PipeWireAO.LibPipeWire.PW_FILTER_STATE_ERROR || return nothing
    required_lost!(session.machine, something(event.message, "session endpoint failed"))
    return nothing
end
function update!(session::Session, ::ShutdownRequested)
    submit!(session, Request(Quit()))
    return nothing
end

submit!(session::Session, request::Request) = submit!(session.machine, request)
function submit!(session::Session, request::Request{Quit})
    # Ingress can consume part of a duty cycle before it admits Quit. Start
    # the effect budget at admission and leave the client's deadline intact.
    admitted_at = Clocks.time_nanos(session.source_clock)
    return submit!(session.machine, request, admitted_at)
end

request_payload(command::RunnerCodec.RunnerCommand) = command.args
request_payload(
    command::Union{
        RunnerCodec.RunnerCommand{:start_group},RunnerCodec.RunnerCommand{:stop_group}
    },
) = only(command.args)
request_payload(::Union{SessionCodec.WarmupCommand,SessionCodec.AdmitCommand}) = nothing

function apply!(session::Session, action::Ingress.DispatchRequest)
    ticket = action.ticket
    operation = ticket.header.operation
    if operation in (WARMUP_OPERATION, ADMIT_OPERATION) &&
        ticket.controller.instance !=
       parse(UInt64, session.configuration["admission.controller-instance"])
        header = ControlCodec.ReplyHeader(
            ticket.header.controller,
            ticket.header.endpoint_instance,
            ticket.header.token,
            operation,
            Int32(-Base.Libc.ESTALE),
        )
        payload = policy_struct(
            Pod("session"),
            Pod("Resource admission launcher incarnation differs"),
            Pod(SPA.Id(UInt32(session.machine.lifecycle))),
        )
        Ingress.complete!(
            session.ingress,
            ticket,
            ControlCodec.encode_completion(header, payload; endpoint = :lifecycle),
        )
        return nothing
    end
    length(session.requests) < 2 || error("session request correlation capacity exceeded")
    session.next_request = Base.Checked.checked_add(session.next_request, UInt64(1))
    token = session.next_request
    session.requests[token] = ticket
    submit!(
        session,
        Request(
            operation;
            token,
            deadline = ticket.deadline,
            payload = request_payload(ticket.command),
            controller = ticket.controller,
        ),
    )
    return nothing
end
function apply!(session::Session, action::Ingress.PublishRecords)
    # Emergency Disconnect can retire transport before ingress retains its final
    # reply. Gate records still drain; a closed endpoint
    # cannot establish wire delivery.
    isopen(session.endpoint) || return nothing
    PipeWireAO.update_params!(
        session.endpoint, Pod[action.capability, action.completion, action.rejection]
    )
    return nothing
end
function apply!(session::Session, action::Ingress.AuthorityFailed)
    required_lost!(session.machine, action.message)
    return nothing
end

reply_outcome(::Val{:Quit}, reply) = RunnerCodec.Accepted
reply_outcome(::Val{:Observed}, reply) = RunnerCodec.Observed
reply_outcome(::Val{:Lifecycle}, reply) = RunnerCodec.Completed
reply_outcome(::Val{:Group}, reply) = RunnerCodec.Requested
function reply_outcome(::Val{:Updated}, reply)
    # Both update adapters return the wire's final active-adoption Bool. A
    # parameter submission never claims adoption; its adapter always emits false.
    return policy_bool(last(reply.details.values)) ? RunnerCodec.Active :
           RunnerCodec.Submitted
end
reply_details(::Val{:Quit}, reply) = policy_struct(Pod(true))
reply_details(::Val{:Lifecycle}, reply) =
    policy_struct(Pod(SPA.Id(UInt32(reply.lifecycle))))
reply_details(::Val, reply) = reply.details::SPA.Struct
function reply_pod(ticket::Ingress.AbstractTicket, reply::Reply)
    h = ticket.header
    result = reply.error === nothing ? Int32(0) : Int32(-Base.Libc.EIO)
    header = ControlCodec.ReplyHeader(
        h.controller, h.endpoint_instance, h.token, h.operation, result
    )
    payload = if reply.error !== nothing
        message = reply.error * (reply.unknown ? "; effect outcome unknown" : "")
        policy_struct(
            Pod("session"),
            Pod(first(message, 2048)),
            Pod(SPA.Id(UInt32(reply.lifecycle))),
        )
    elseif reply.outcome === :Warmup
        policy_struct(Pod(SPA.Id(UInt32(reply.lifecycle))), Pod(reply.details::Bool))
    else
        kind = Val(reply.outcome)
        policy_struct(
            Pod(SPA.Id(UInt32(reply.lifecycle))),
            Pod(SPA.Id(UInt32(reply_outcome(kind, reply)))),
            Pod(reply_details(kind, reply)),
        )
    end
    pod = ControlCodec.encode_completion(header, payload; endpoint = :lifecycle)
    SessionCodec.decode_completion(pod)
    return pod
end

function drain!(session::Session)
    cancellation = take_cancelled!(session.machine)
    job = session.active_job
    if cancellation !== nothing &&
        job !== nothing &&
        cancellation.serial == job.ticket.serial
        job.cancelled = true
    end
    cancellation === nothing || after_retirement!(session, cancellation.effect)
    session.ingress.lifecycle == session.machine.lifecycle ||
        Ingress.state!(session.ingress, session.machine.lifecycle)
    for reply in take_replies!(session.machine)
        ticket = pop!(session.requests, reply.token, nothing)
        ticket === nothing && continue
        Ingress.complete!(
            session.ingress,
            ticket,
            reply_pod(ticket, reply);
            unknown = reply.unknown,
            terminal = reply.outcome === :Quit,
        )
    end
    # Processing an action can dispatch an immediate reply.
    # Drain each bounded outbox before applying the next native observation.
    for _ in 1:Ingress.MAX_ACTIONS
        actions = Ingress.take_actions!(session.ingress)
        isempty(actions) && return nothing
        foreach(action -> apply!(session, action), actions)
    end
    error("session ingress action cycle exceeds bound")
end

function start_effect!(session::Session)
    task = session.active_task
    task !== nothing && !istaskdone(task) && return nothing
    ticket = session.machine.effect
    ticket === nothing && return nothing
    session.active_job !== nothing &&
        session.active_job.ticket.serial == ticket.serial &&
        return nothing
    # Retained terminal replies must leave ingress before the final native fence.
    ready_for_effect(session, ticket.effect) || return nothing
    job = Job(ticket, false)
    session.active_job = job
    session.active_task = @async begin
        try
            result = perform!(session, job, ticket.effect)
            session.effect_result = EffectCompleted(
                ticket, result, Clocks.time_nanos(session.source_clock)
            )
        catch error
            if error isa InterruptException
                stage!(session.queue, ShutdownRequested())
            else
                session.effect_result = EffectFailed(ticket, sprint(showerror, error), false)
            end
        end
    end
    return nothing
end
ready_for_effect(session, ::AbstractEffect) = true
ready_for_effect(session, ::PublishQuit) =
    session.ingress.pending === nothing && session.ingress.retired === nothing

function Agent.do_work(session::Session)
    current_task() === session.owner || error("session task ownership changed")
    Clocks.update!(session.clock, Clocks.time_nanos(session.source_clock))
    work = session.done ? 0 : PipeWireAO.iterate!(session.loop; max_dispatches = 1)
    if session.queue.overflow && !session.overflow_seen
        session.overflow_seen = true
        required_lost!(session.machine, "session observation queue overflow")
    end
    for _ in eachindex(session.queue.records)
        event = next_event!(session.queue)
        event === nothing && break
        update!(session, event)
        observe_controllers!(session)
        drain!(session)
        work += 1
    end
    # The owner coroutine has one result slot, separate from native ingress.
    # Observation overflow must not drop the emergency teardown acknowledgement.
    result = session.effect_result
    session.effect_result = nothing
    if result !== nothing
        update!(session, result)
        drain!(session)
        work += 1
    end
    tick!(session.machine)
    Ingress.tick!(session.ingress)
    observe!(
        session.machine,
        Observation(
            groups_details(session),
            status_details(
                session; running = _status_running(session.machine.lifecycle_origin)
            ),
        ),
    )
    drain!(session)
    start_effect!(session)
    return work
end

controller_fact(session, object::Object) = nothing
controller_fact(session, object::Object{P,NodeInfo}) where {P} =
    controller_fact(session, object, object.info)
controller_fact(session, object, ::Nothing) = nothing
function controller_fact(session, object, info::NodeInfo)
    properties = object_properties(object)
    get(properties, "pipewireao.rtc-control.profile", nothing) ==
    ControlClient.CONTROLLER_PROFILE || return nothing
    object.removed && return nothing
    instance = tryparse(UInt64, get(properties, "pipewireao.rtc-control.instance", ""))
    pid = tryparse(UInt32, get(properties, "pipewireao.rtc-control.owner-pid", ""))
    name = get(properties, "node.name", "")
    isempty(name) && return nothing
    instance === nothing && return nothing
    pid === nothing && return nothing
    # The advertised PID is checked against the server-owned ClientInfo record.
    id = _node_client(object)
    id === nothing && return nothing
    client = find_object(session, id)
    client !== nothing && !client.removed && client_pid(client) == pid || return nothing
    registry_serial(session, id) == client.serial || return nothing
    registry_serial(session, object.id) == object.serial || return nothing
    mask =
        PipeWireAO.NODE_CHANGE_INPUT_PORTS | PipeWireAO.NODE_CHANGE_OUTPUT_PORTS |
        PipeWireAO.NODE_CHANGE_PROPERTIES
    identity = Identity(object.id, object.serial, instance, pid)
    return Ingress.Controller(
        identity,
        name;
        input_ports = info.n_input_ports,
        output_ports = info.n_output_ports,
        protocol = get(properties, "pipewireao.rtc-control.protocol", ""),
        full_info = info.change_mask & mask == mask,
    )
end
function observe_controllers!(session::Session)
    observations = Ingress.Controller[]
    for object in values(session.objects)
        fact = controller_fact(session, object)
        fact === nothing || push!(observations, fact)
    end
    # Sorting makes native callback order irrelevant to capability serialization.
    sort!(observations; by = fact -> fact.identity.global_id)
    if observations != session.controller_facts
        Ingress.controllers!(session.ingress, observations)
        session.controller_facts = observations
    end
    if session.controller === nothing
        name = session.configuration["controller.node.name"]
        instance = parse(UInt64, session.configuration["controller.instance"])
        for fact in observations
            if fact.name == name &&
                fact.identity.instance == instance &&
                fact.identity.pid == getpid() &&
                fact.full_info &&
                fact.input_ports == 0 &&
                fact.output_ports == 0
                identity = fact.identity
                session.controller = ControlCodec.ControllerIdentity(
                    identity.global_id, identity.serial, Int64(instance)
                )
                break
            end
        end
    end
    return nothing
end
function update!(session::Session, event::ControllerAdded)
    object = PipeWireAO.find_global(session.registry, event.id)
    object === nothing && return nothing
    _serial(object.properties) == event.serial || return nothing
    id = tryparse(UInt32, get(object.properties, "client.id", ""))
    id === nothing && return nothing
    client = PipeWireAO.find_global(session.registry, id)
    client === nothing && return nothing
    client.type == "PipeWire:Interface:Client" || return nothing
    bind_object!(session, client)
    bind_object!(session, object)
    return nothing
end
function update!(session::Session, event::GlobalRemoved)
    object = find_object(session, event.id)
    if object !== nothing
        Ingress.controller_removed!(session.ingress, event.id, object.serial)
        Hsm.dispatch!(
            session.machine, :AdmissionControllerRemoved, (; id = event.id, object.serial)
        )
    end
    remove_object!(session, event.id)
    return nothing
end

function perform!(session::Session, job, ::RemoveControls)
    identity = session.controller
    if identity !== nothing
        object = find_object(session, identity.global_id)
        object !== nothing && object.serial == identity.serial ||
            throw(ArgumentError("session controller changed before retirement"))
        retire_object!(session, identity.global_id)
    end
    close(session.controller_endpoint)
    synchronize!(session, job)
    await_condition!(session, job) do
        all(session.retired) do (id, serial)
            registry_serial(session, id) != serial
        end
    end
    return nothing
end
function perform!(session::Session, job, ::PublishQuit)
    synchronize!(session, job)
    return nothing
end
function perform!(session::Session, job, ::Disconnect)
    # Transport retirement bypasses the expired scientific budget. Completion
    # is returned only after the actual Core connection has been closed.
    failures = Exception[]
    _close_transport!(session, failures)
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

const SESSION_IDLE_SECONDS = 0.001
Agent.on_start(session::Session) = nothing
Agent.on_error(::Session, error) = throw(error)
Agent.on_close(::Session) = nothing
"Run the serialized session policy on its creating task until shutdown."
function serve!(session::Session)
    current_task() === session.owner || error("session belongs to another task")
    invoker = Agent.AgentInvoker(session)
    terminate = SignalSource(
        session.loop, Base.SIGTERM, (_, _) -> stage!(session.queue, ShutdownRequested())
    )
    try
        Agent.start(invoker)
        while !session.done
            try
                Base.disable_sigint(() -> Agent.invoke_unchecked(invoker))
                sleep(SESSION_IDLE_SECONDS)
            catch error
                error isa InterruptException || rethrow()
                stage!(session.queue, ShutdownRequested())
            end
        end
    finally
        close(invoker)
        close(terminate)
    end
    return session.exitcode
end

function endpoint_properties(profile, instance, name)
    properties = Dict{String,String}(
        "node.name" => name,
        "node.cache-params" => "false",
        "media.class" => "Control",
        "pipewireao.rtc-control.protocol" => ControlClient.PROTOCOL,
        "pipewireao.rtc-control.profile" => profile,
        "pipewireao.rtc-control.instance" => string(instance),
        "pipewireao.rtc-control.owner-pid" => string(getpid()),
    )
    return properties
end

const MAX_DISPATCH_PREPARATION_EFFECTS = 32

"""Prepare cold control dispatch before the public endpoint accepts requests.

An unpublished machine with a private cached clock exercises cleanup events.
RTC requests and backend methods compile without executing, so no native
mutation or readiness observation is produced.
"""
function prepare_dispatch!(session::Session)
    Base.precompile(update!, (typeof(session), EffectCompleted{Nothing}))
    Base.precompile(update!, (typeof(session), EffectCompleted{SPA.Struct}))
    Base.precompile(update!, (typeof(session), EffectFailed))
    controls = (
        (Status, Tuple{}, QueryStatus),
        (Properties, Tuple{String}, QueryProperties{Tuple{String}}),
        (PropertyGeneration, Tuple{String,String}, QueryPropertyGeneration{Tuple{String,String}}),
        (ParameterGeneration, Tuple{String,String}, QueryParameterGeneration{Tuple{String,String}}),
        (
            SetProperties,
            Tuple{String,Dict{String,RunnerCodec.RunnerScalar}},
            UpdateProperties{Tuple{String,Dict{String,RunnerCodec.RunnerScalar}}},
        ),
        (
            SetParameter,
            ParameterSource.Arguments,
            SubmitParameter{ParameterSource.Arguments},
        ),
    )
    for (command, payload, effect) in controls
        Base.precompile(submit!, (typeof(session.machine), Request{command,payload}))
        for origin in (ReadyOrigin, RunningOrigin)
            job = Job{EffectTicket{effect,origin}}
            Base.precompile(perform!, (typeof(session), job, effect))
        end
    end
    parameter_owner = Owner{
        ParameterSource.Profile,
        ControlClient.Observation{
            ParameterSource.Profile,ParameterSource.Lifecycle,
            ParameterSource.Completion,ParameterSource.Rejection
        }
    }
    parameter_command = RunnerCodec.RunnerCommand{:parameter,ParameterSource.Arguments}
    parameter_effect = SubmitParameter{ParameterSource.Arguments}
    for origin in (ReadyOrigin, RunningOrigin)
        job = Job{EffectTicket{parameter_effect,origin}}
        Base.precompile(request_owner!, (typeof(session), job, parameter_owner, parameter_command))
    end
    bootstrap = OwnerBootstrapCodec.PROFILE
    bootstrap_owner = Owner{
        typeof(bootstrap),
        ControlClient.Observation{
            typeof(bootstrap),ControlClient.lifecycle_type(bootstrap),
            ControlClient.completion_type(bootstrap),ControlClient.rejection_type(bootstrap)
        }
    }
    for origin in (ConfiguringOrigin, ReadyOrigin, RunningOrigin)
        job = Job{EffectTicket{ShutdownOwners,origin}}
        Base.precompile(_shutdown_bootstrap!, (typeof(session), job, bootstrap_owner))
    end
    for payload in ((), nothing)
        machine = Machine(1; clock = Clocks.CachedNanoClock(0))
        submit!(machine, Request(Quit(); payload))
        take_cancelled!(machine)
        for _ in 1:MAX_DISPATCH_PREPARATION_EFFECTS
            ticket = machine.effect
            ticket === nothing && break
            # The simulated Quit discovers the effect sequence while Configuring.
            # Real Ready and Running requests use distinct backend job types.
            effect = typeof(ticket.effect)
            for origin in (ConfiguringOrigin, ReadyOrigin, RunningOrigin)
                job = Job{EffectTicket{effect,origin}}
                Base.precompile(perform!, (typeof(session), job, effect))
            end
            submitted!(machine, ticket)
            complete!(machine, ticket)
            take_replies!(machine)
        end
        machine.effect === nothing ||
            error("cleanup dispatch preparation exceeded its bound")
    end
    return nothing
end

"""Open a session from its generated standard SPA-JSON configuration.

No service, device or graph process is started here. The caller owns `close`.
The creating task must stay on its creating OS thread.
"""
function Session(
    path::AbstractString; clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock()
)
    file = realpath(path)
    override = get(ENV, "PIPEWIREAO_CONFIG_NAME", file)
    override == file || throw(
        ArgumentError(
            "PipeWire context configuration override differs from session configuration"
        ),
    )
    prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
    config = DeploymentConfiguration.decode(file, prefix)
    Set(keys(config)) ==
    Set(("context.properties", "context.modules", "pipewireao.session")) ||
        throw(ArgumentError("session configuration has unsupported sections"))
    configuration = Dict{String,Any}(config["pipewireao.session"])
    if haskey(configuration, "journal.path") ||
        haskey(get(configuration, "properties", Dict()), "pipewireao.rtc.session.journal")
        throw(
            ArgumentError(
                "session journaling is retired; regenerate the session configuration"
            ),
        )
    end
    spec = configuration["session"]
    declared_links = DeploymentConfiguration.validate_session_links(spec)
    isempty(declared_links) && throw(ArgumentError("session requires a declared connection"))
    DeploymentConfiguration.validate_execution_groups(spec, declared_links)
    modules = [entry["name"] for entry in config["context.modules"]]
    modules == ["libpipewire-module-protocol-native", "libpipewire-module-client-node"] ||
        throw(ArgumentError("session configuration has unsupported context modules"))
    isdefined(PipeWireAO, :iterate!) ||
        throw(ArgumentError("MediaSession requires PipeWireAO's owner-thread iterate! API"))
    queue = EventQueue()
    objects = Dict{UInt32,Object}()
    loop = MainLoop()
    context = nothing
    core = nothing
    registry = nothing
    listener = nothing
    endpoint = nothing
    controller = nothing
    try
        context = Context(loop; properties = Dict("config.name" => file))
        core = CoreConnection(
            context;
            properties = Dict("remote.name" => config["context.properties"]["remote.name"]),
            on_info = (_, info) -> stage!(queue, CoreUpdated(info)),
            on_done = (_, id, sequence) -> stage!(queue, CoreDone(id, sequence)),
            on_error = (_, id, sequence, error) ->
                stage!(queue, CoreError(id, sequence, sprint(showerror, error))),
            on_bound_id = (_, local_id, global_id) ->
                stage!(queue, ClientBound(local_id, global_id)),
        )
        registry = Registry(core)
        controller_name = configuration["controller.node.name"]
        listener = add_listener!(
            registry;
            on_global_added = (_, object) -> begin
                if object.type == "PipeWire:Interface:Node"
                    name = get(object.properties, "node.name", "")
                    if name == controller_name || startswith(name, ControlClient.CONTROLLER_NODE_PREFIX)
                        stage!(queue, ControllerAdded(object.id, _serial(object.properties)))
                    end
                end
                nothing
            end,
            on_global_removed = (_, id) -> begin
                haskey(objects, id) && stage!(queue, GlobalRemoved(id))
                nothing
            end,
        )
        instance = parse(Int64, configuration["instance"])
        controller_instance = parse(Int64, configuration["controller.instance"])
        controller_properties = endpoint_properties(
            ControlClient.CONTROLLER_PROFILE,
            controller_instance,
            configuration["controller.node.name"],
        )
        controller = Filter(core, "RTC controller"; properties = controller_properties)
        properties = merge(
            Dict{String,String}(configuration["properties"]),
            endpoint_properties(SessionCodec.PROFILE, instance, configuration["node.name"]),
        )
        endpoint = Filter(
            core,
            "RTC session";
            properties,
            max_param_bytes = ControlCodec._limit(Val(:request), nothing),
            on_state_changed = (_, previous, state, message) ->
                stage!(queue, FilterChanged(state, message)),
            on_param_changed = (_, port, id, pod) ->
                id == SPA.PARAM_PROPS &&
                stage!(queue, RequestReceived(pod, Clocks.time_nanos(clock))),
            on_param_rejected = (_, port, id, size) ->
                id == SPA.PARAM_PROPS &&
                stage!(queue, RequestReceived(nothing, Clocks.time_nanos(clock))),
        )
        cached = Clocks.CachedNanoClock(Clocks.time_nanos(clock))
        machine = Machine(
            instance;
            clock = cached,
            startup_timeout_ns = Base.Checked.checked_mul(
                Int64(configuration["startup.timeout-ms"]), Int64(1_000_000)
            ),
        )
        ingress = Ingress.Gate(instance; clock = cached)
        session = Session(
            configuration,
            declared_links,
            loop,
            context,
            core,
            registry,
            listener,
            endpoint,
            controller,
            current_task(),
            clock,
            cached,
            machine,
            ingress,
            queue,
            objects,
            Dict{UInt32,Captured}(),
            Dict{UInt32,UInt64}(),
            Dict{String,UInt64}(),
            Dict{String,Group}(),
            LinkRecord[],
            AbstractOwner[],
            AbstractSource[],
            nothing,
            nothing,
            UInt32(0),
            nothing,
            Ingress.Controller[],
            Int64(0),
            Dict{Tuple{UInt32,Cint},Parameters}(),
            Dict{Cint,Barrier}(),
            Dict{UInt64,Ingress.AbstractTicket}(),
            UInt64(0),
            nothing,
            nothing,
            nothing,
            false,
            false,
            nothing,
            false,
            1,
        )
        prepare_dispatch!(session)
        # The real startup budget begins after offline code preparation. No
        # public Filter has connected yet, so no caller's receipt is deferred.
        Clocks.update!(cached, Clocks.time_nanos(clock))
        machine = Machine(
            instance; clock = cached, startup_timeout_ns = machine.startup_timeout_ns
        )
        session.machine = machine
        observe!(
            machine,
            Observation(groups_details(session), status_details(session; running = false)),
        )
        flags = PipeWireAO.FILTER_INACTIVE | PipeWireAO.FILTER_ASYNC
        PipeWireAO.connect!(controller; flags)
        PipeWireAO.connect!(endpoint; flags)
        drain!(session)
        return session
    catch primary
        failures = Exception[primary]
        for resource in (endpoint, controller, listener, registry, core, context, loop)
            resource === nothing && continue
            try
                close(resource)
            catch cleanup
                push!(failures, cleanup)
            end
        end
        length(failures) == 1 && rethrow()
        throw(CompositeException(failures))
    end
end

function _close_resource!(failures::Vector{Exception}, resource)
    try
        close(resource)
        return true
    catch cleanup
        push!(failures, cleanup)
        return false
    end
end
_close_resource!(failures::Vector{Exception}, ::Nothing) = true

"Close native transport on the serialized owner thread, retaining every failure."
function _close_transport!(session::Session, failures::Vector{Exception})
    # No callbacks may retain a live hook into a proxy while it is freed. Each
    # public close also deactivates its own callbacks before native destruction.
    _close_resource!(failures, session.registry_listener)
    for record in session.links
        record.retiring = true
        if _close_resource!(failures, record.listener)
            record.listener = nothing
        end
        if _close_resource!(failures, record.proxy)
            record.proxy = nothing
        end
    end
    filter!(
        record -> record.listener !== nothing || record.proxy !== nothing, session.links
    )
    for (id, object) in session.objects
        if _close_resource!(failures, object.proxy)
            delete!(session.objects, id)
            delete!(session.captured, id)
        end
    end
    for resource in
        (session.endpoint, session.controller_endpoint, session.registry, session.core)
        _close_resource!(failures, resource)
    end
    return nothing
end

function Base.close(session::Session)
    current_task() === session.owner || error("session belongs to another task")
    session.active_job === nothing || (session.active_job.cancelled = true)
    session.done = true
    failures = Exception[]
    if session.active_task !== nothing
        try
            wait(session.active_task)
        catch cleanup
            push!(failures, cleanup)
        end
    end
    _close_transport!(session, failures)
    for resource in (session.context, session.loop)
        _close_resource!(failures, resource)
    end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

"Run the headless RTC entrypoint with `-c CONFIG`; systemd owns process lifetime."
function main(arguments = ARGS)
    length(arguments) == 2 && first(arguments) == "-c" ||
        throw(ArgumentError("usage: pipewireao-rtc -c CONFIG"))
    session = Session(last(arguments))
    result = try
        serve!(session)
    catch primary
        try
            close(session)
        catch cleanup
            throw(CompositeException(Exception[primary, cleanup]))
        end
        rethrow()
    end
    close(session)
    return result
end
