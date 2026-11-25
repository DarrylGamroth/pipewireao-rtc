# Managed activation verifies the public native endpoint from a separate PipeWire
# connection in the RTC process. Only the session owner advances the machine.
function admission_endpoint(session)
    admission = something(session.admission)
    client = something(admission.client)
    return with_thread_loop_lock(client.loop) do _
        ControlClient.healthy(client)
        client.global_id == node_id(session.endpoint) ||
            throw(ArgumentError("admission observed a different RTC endpoint"))
        (; session_id = something(client.observation.node_identity),
            instance = client.observation.instance, remote = admission.remote,
            client.node_name, owner_pid = client.observation.owner_pid,
            client.global_id, client.serial)
    end
end

admission_check(session, job) = () -> check_job(session, job)

function perform!(session::Session, job, ::VerifyAdmission)
    admission = something(session.admission)
    config = session.configuration
    clock = session.source_clock
    deadline = job.ticket.deadline
    client = ControlClient.connect(
        SessionProfile.Profile(), admission.remote, config["node.name"], getpid(),
        session.machine.session; deadline, clock,
        controller_instance = parse(Int64, config["admission.controller-instance"]),
        check = admission_check(session, job),
    )
    admission.client = client
    endpoint = admission_endpoint(session)
    SessionCLI.verify_admission!(admission.deployment, endpoint; deadline, clock)
    check_job(session, job)
    admission_endpoint(session) == endpoint ||
        throw(ArgumentError("RTC endpoint changed during placement verification"))
    marker = something(client.identity)
    expected = Identity(marker.global_id, marker.serial, marker.instance, getpid())
    facts = Ingress.admitted_controller(session.ingress, marker.global_id)
    facts !== nothing && facts.identity == expected ||
        throw(ArgumentError("public Status controller incarnation changed"))
    return expected
end

function check_publication(session, deadline)
    !session.done && !session.queue.overflow &&
        Hsm.current(session.machine) in (:AwaitingReadyStatus, :CheckingReadyStatus, :AwaitingReadyPublication) ||
        throw(ArgumentError("RTC admission was revoked during publication"))
    Clocks.time_nanos(session.source_clock) < deadline ||
        throw(ArgumentError("RTC admission publication expired"))
    check_core!(session)
    return nothing
end

publication_check(session, deadline) = () -> check_publication(session, deadline)

function confirm_installed_ready!(session, admission, deadline)
    try
        check = publication_check(session, deadline)
        client = something(admission.client)
        clock = session.source_clock
        completion = ControlClient.request!(
            client, SessionCodec.RunnerCommand(:status);
            deadline = min(deadline, Base.checked_add(Clocks.time_nanos(clock), Int64(10_000_000_000))),
            check,
        )
        SessionCLI.confirm_ready(completion)
        details = completion.result.details
        !details.running && details.owned_links == length(session.declared_links) ||
            throw(ArgumentError("RTC Status did not confirm held execution and declared Links"))
        endpoint = admission_endpoint(session)
        SessionCLI.publish_ready!(admission.deployment, endpoint; deadline, clock) do
            check()
            admission_endpoint(session) == endpoint ||
                throw(ArgumentError("RTC endpoint changed before Ready publication"))
        end
        admission.result = DiscoveryPublished()
    catch error
        admission.result = PublicationFailed(sprint(showerror, error))
    end
    return nothing
end

function after_completion!(session::Session, ::VerifyAdmission)
    Hsm.current(session.machine) === :AwaitingReadyStatus || return nothing
    admission = something(session.admission)
    deadline = session.machine.deadline
    # The Agent must keep dispatching PipeWire while its public Status is in flight.
    admission.confirmation = @async confirm_installed_ready!(session, admission, deadline)
    return nothing
end

# A removal or shutdown already staged in this duty cycle takes precedence over
# service notification, including events that arrived after the receipt.
function finish_publication!(session)
    admission = session.admission
    admission === nothing && return 0
    result = admission.result
    result === nothing && return 0
    session.queue.count == 0 || return 0
    admission.result = nothing
    update!(session, result)
    return 1
end

function update!(session::Session, event::PublicationFailed)
    if Hsm.current(session.machine) in (:AwaitingReadyStatus, :CheckingReadyStatus, :AwaitingReadyPublication)
        required_lost!(session.machine, event.reason)
    end
    return nothing
end

function update!(session::Session, ::DiscoveryPublished)
    Hsm.current(session.machine) === :AwaitingReadyPublication || return nothing
    admission = something(session.admission)
    try
        check_publication(session, session.machine.deadline)
        admission_endpoint(session)
        Hsm.dispatch!(session.machine, :ReadyPublished)
        drain!(session)
    catch error
        required_lost!(session.machine, sprint(showerror, error))
    end
    return nothing
end

# Retire the proof client and flush outstanding PipeWire observations before
# accepting the held graph and advertising Ready.
function perform!(session::Session, job, ::ConfirmReady)
    admission = something(session.admission)
    endpoint = admission_endpoint(session)
    close(something(admission.client))
    admission.client = nothing
    clock = session.source_clock
    deadline = job.ticket.deadline
    while true
        SessionCLI.check_ready_units!(admission.deployment; deadline, clock)
        synchronize!(session, job)
        registry_serial(session, node_id(session.endpoint)) == endpoint.serial ||
            throw(ArgumentError("RTC endpoint changed before Ready notification"))
        verify_held_links!(session)
        SessionCLI.units_changed(admission.deployment; deadline, clock) || return nothing
    end
end

function after_completion!(session::Session, ::ConfirmReady)
    Hsm.current(session.machine) === :Ready || return nothing
    try
        SessionCLI.units_changed(session.admission.deployment;
            deadline = session.machine.deadline, clock = session.source_clock) &&
            throw(ArgumentError("systemd service changed after the final held Link check"))
        drain!(session)
        Hsm.current(session.machine) === :Ready || return nothing
        SessionCLI.notify_ready!()
        session.admission.notified = true
        manager = session.admission.deployment.manager
        manager === nothing || close(manager)
    catch error
        required_lost!(session.machine, sprint(showerror, error))
    end
    return nothing
end

# Infer the native resource types from their actual constructors. Package
# compilation must never acquire a core connection or a proof client.
function precompile_admission(::Type{T}) where {T<:Session}
    clock = fieldtype(T, :source_clock)
    profile = SessionProfile.Profile()
    observation = ControlClient.Observation{
        typeof(profile), ControlClient.lifecycle_type(profile),
        ControlClient.completion_type(profile), ControlClient.rejection_type(profile),
    }
    client = ControlClient.Client{observation,clock}
    check = Core.Compiler.return_type(admission_check, Tuple{T,Job})
    status_check = Core.Compiler.return_type(publication_check, Tuple{T,Int64})
    status = typeof(SessionCodec.RunnerCommand(:status))
    precompile(
        Core.kwcall,
        (
            NamedTuple{(:deadline, :clock, :controller_instance, :check),
                Tuple{Int64,clock,Int64,check}},
            typeof(ControlClient.connect), typeof(profile), String, String, Int32, UInt64,
        ),
    )
    precompile(
        Core.kwcall,
        (
            NamedTuple{(:deadline, :check),Tuple{Int64,status_check}},
            typeof(ControlClient.request!), client, status,
        ),
    )
    precompile(admission_endpoint, (T,))
    precompile(close, (client,))
    connection = (Context{ThreadLoop}, String, client)
    precompile(ControlClient.client_core, connection)
    core = Core.Compiler.return_type(ControlClient.client_core, Tuple{connection...})
    isconcretetype(core) || return nothing
    precompile(Registry, (core,))
    precompile(close, (core,))
    registry = Core.Compiler.return_type(Registry, Tuple{core})
    isconcretetype(registry) || return nothing
    precompile(close, (registry,))
    listener = (registry, client)
    precompile(ControlClient.listen_registry!, listener)
    listener_type = Core.Compiler.return_type(ControlClient.listen_registry!, Tuple{listener...})
    isconcretetype(listener_type) && precompile(close, (listener_type,))
    for (bind_node, arguments) in (
        (ControlClient.bind_marker, (registry, Global, client)),
        (ControlClient.bind_owner, (registry, Global, client, observation)),
    )
        precompile(bind_node, arguments)
        node = Core.Compiler.return_type(bind_node, Tuple{arguments...})
        isconcretetype(node) || continue
        precompile(close, (node,))
        if bind_node === ControlClient.bind_owner
            precompile(subscribe_params!, (node, Tuple{UInt32}))
            precompile(
                Core.kwcall,
                (NamedTuple{(:count,),Tuple{UInt32}}, typeof(enum_params!), node, UInt32),
            )
        end
    end
    return nothing
end
