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

function perform!(session::Session, job, ::VerifyAdmission)
    admission = something(session.admission)
    config = session.configuration
    clock = session.source_clock
    deadline = job.ticket.deadline
    client = ControlClient.connect(
        SessionProfile.Profile(), admission.remote, config["node.name"], getpid(),
        session.machine.session; deadline, clock,
        controller_instance = parse(Int64, config["admission.controller-instance"]),
        check = () -> check_job(session, job),
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

function confirm_installed_ready!(session, admission, deadline)
    try
        check = () -> check_publication(session, deadline)
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

# The owner has queued the new public capability. Retire the proof client
# and wait for the PipeWire core to process that capability before notifying systemd.
function perform!(session::Session, job, ::ConfirmReady)
    admission = something(session.admission)
    endpoint = admission_endpoint(session)
    close(something(admission.client))
    admission.client = nothing
    synchronize!(session, job)
    registry_serial(session, node_id(session.endpoint)) == endpoint.serial ||
        throw(ArgumentError("RTC endpoint changed before Ready notification"))
    return nothing
end

function after_completion!(session::Session, ::ConfirmReady)
    Hsm.current(session.machine) === :Ready || return nothing
    try
        SessionCLI.notify_ready!()
        session.admission.notified = true
    catch error
        required_lost!(session.machine, sprint(showerror, error))
    end
    return nothing
end
