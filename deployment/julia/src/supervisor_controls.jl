# Included inside Deployment: the existing owner serializes every public request.
const Supervisor = NativeSupervisorCodec
const RunnerProtocol = NativeRunnerCodec

struct CoordinationRejected <: Exception
    field::String
    message::String
end
Base.showerror(io::IO, error::CoordinationRejected) = print(io,error.message)
reject_control(field,message) = throw(CoordinationRejected(field,message))

function control(path::AbstractString, argv::AbstractVector; timeout=30,
        request_id=nothing, allow_rejection=false, check=nothing, deadline=nothing)
    require(isfinite(timeout) && timeout>0,"control timeout must be finite and positive")
    command = try RunnerCommands.parse(argv) catch failure
        failure isa ArgumentError&&allow_rejection || rethrow()
        return control_error(request_id,"control.command",sprint(showerror,failure))
    end
    deadline = deadline===nothing ? monotonic()+timeout : deadline
    require(isfinite(deadline)&&deadline>monotonic(),"control deadline must be finite and future")
    check_fn = check === nothing ? (() -> nothing) : check
    client = NativeSupervisorClient.connect_locator(path;deadline,check=check_fn)
    try
        uuid=NativeSupervisorClient.live_uuid(client)
        # The saved locator never supplies admission. Every call verifies fresh
        # native Status on this exact client before its optional mutation.
        observed = NativeSupervisorClient.request!(client,RunnerProtocol.RunnerCommand(:status);deadline,check=check_fn)
        reply = RunnerProtocol.operation_id(command)==3 ? observed :
            NativeSupervisorClient.request!(client,command;deadline,check=check_fn)
        rendered = NativeSupervisorClient.render(reply;request_id,owner_pid=client.observation.owner_pid)
        rendered["deployment_uuid"] = uuid
        !rendered["ok"]&&!allow_rejection && fail("control rejected: $(rendered["error"])")
        return rendered
    finally
        close(client)
    end
end

function control_binding(client::NativeControlClient.Client)
    return with_thread_loop_lock(client.loop) do _
        NativeControlClient.healthy(client)
        Supervisor.Binding(client.node_name,NativeControlClient.profile_name(client.observation.profile),
            client.observation.owner_pid,client.global_id,client.serial,client.observation.instance)
    end
end
function control_binding(client::NativeSourceClient.Client)
    return with_thread_loop_lock(client.loop) do _
        NativeSourceClient.healthy(client)
        Supervisor.Binding(client.node_name,"pipewireao.source-control/1",UInt32(client.expected_pid),
            client.global_id,parse(UInt64,client.serial),client.observation.instance)
    end
end

function runner_request(deployment::DeploymentRunner, command::RunnerProtocol.RunnerCommand;
        deadline::Float64, check=()->check_processes(deployment))
    deployment.runner_client===nothing && fail("native runner client was not prepared")
    NativeControlClient.deadline_check(deadline,check)
    return NativeRunnerClient.request!(deployment.runner_client,command;deadline,check)
end
function source_observation(deployment::DeploymentRunner;deadline::Float64,check)
    deployment.source_owner===nothing && return nothing
    deployment.source_failed && fail("source coordination already failed; source outcome unknown")
    if native_acquisition(deployment.source_owner)
        connection = deployment.source_client
        completion = NativeAcquisitionLifecycleClient.status(connection;deadline,check)
        completion.lifecycle===NativeAcquisitionLifecycleCodec.Connected || fail("source is not Connected")
        return Supervisor.SourceObservation(control_binding(connection.client),completion.header.token,
            completion.lifecycle,something(completion.snapshot))
    end
    native_source(deployment.source_owner) || fail("public native supervisor requires native source controls")
    reply = source_control(deployment,"status";deadline,check)
    client = deployment.source_client
    snapshot = with_thread_loop_lock(client.loop) do _
        NativeSourceClient.healthy(client)
        values = something(client.observation.snapshot)
        values[4]==reply["id"] && values[3]==3 && values[5]==0 || fail("source query identity changed")
        Supervisor.SimulatorSnapshot(values...)
    end
    return Supervisor.SourceObservation(control_binding(client),snapshot.token,nothing,snapshot)
end
function heart_observation(deployment::DeploymentRunner;deadline::Float64,check)
    client=deployment.heart_client
    client===nothing && return nothing
    completion=NativeControlClient.request!(client,NativeHeartCodec.HeartCommand(:status);deadline,check)
    completion.header.result==0&&completion.lifecycle===NativeHeartCodec.Ready&&completion.snapshot!==nothing ||
        fail("HEART wrapper health was not Ready")
    return Supervisor.HeartObservation(control_binding(client),completion.header.token,
        completion.lifecycle,completion.snapshot)
end
function supervisor_snapshot(deployment::DeploymentRunner;deadline::Float64,check)
    NativeControlClient.deadline_check(deadline,check)
    completion=runner_request(deployment,RunnerProtocol.RunnerCommand(:status);deadline,check)
    completion.header.result==0&&completion.result!==nothing || fail("native runner Status failed")
    runner=Supervisor.RunnerObservation(control_binding(deployment.runner_client),completion.header.token,
        "native-runner-instance:$(completion.header.endpoint_instance)",
        Supervisor.RunnerRecord(completion.lifecycle,completion.result))
    source=source_observation(deployment;deadline,check)
    heart=heart_observation(deployment;deadline,check)
    NativeControlClient.deadline_check(deadline,check)
    processes=Supervisor.OwnedProcess[Supervisor.OwnedProcess(role,UInt32(deployment.owned_pids[process]))
        for (role,process) in deployment.processes if process_running(process)]
    return Supervisor.validate_snapshot(Supervisor.Admitted,true,Supervisor.Snapshot(processes,runner,source,heart))
end

"Reserve optional acquisition fields and bounded HEART path growth before effects."
function future_snapshot_bound(snapshot::Supervisor.Snapshot)
    bound=Supervisor._snapshot_size(snapshot)
    source=snapshot.source
    if source!==nothing && source.snapshot isa NativeAcquisitionLifecycleCodec.Snapshot
        s=source.snapshot
        # Each cursor is exactly 72 bytes when present, versus eight for None.
        s.cursor===nothing && (bound=Supervisor._add(bound,64))
        s.report_cursor===nothing && (bound=Supervisor._add(bound,64))
        source.binding.profile=="pipewireao.rtc.correction-lifecycle/1" && s.window===nothing &&
            (bound=Supervisor._add(bound,8))
        profile=source.binding.profile=="pipewireao.rtc.calibration-lifecycle/1" ?
            NativeAcquisitionLifecycleCodec.CALIBRATION_PROFILE : NativeAcquisitionLifecycleCodec.CORRECTION_PROFILE
        phase_bytes=maximum(ncodeunits,NativeAcquisitionLifecycleCodec._phases(profile))
        bound=Supervisor._add(bound,RunnerProtocol._pod_size(phase_bytes+1)-Supervisor._string_size(s.phase))
    end
    if snapshot.heart!==nothing
        s=snapshot.heart.snapshot
        bound=Supervisor._add(bound,RunnerProtocol._pod_size(4097)-Supervisor._string_size(s.report_path;empty=true))
        bound=Supervisor._add(bound,RunnerProtocol._pod_size(65)-Supervisor._string_size(s.report_sha256;empty=true))
        s.child_pid===nothing && (bound=Supervisor._add(bound,8))
        s.child_returncode===nothing && (bound=Supervisor._add(bound,8))
    end
    # These commands never change the loaded configuration or realized sink
    # catalog. Runner counters, phases and source generations have fixed widths.
    return bound
end
source_running(source::Supervisor.SourceObservation)=source.snapshot.running
source_completed(source::Supervisor.SourceObservation)=source.snapshot.completed

"Apply an admitted typed operation through this same existing coordinator."
function coordinate(deployment::DeploymentRunner,command::RunnerProtocol.RunnerCommand,
        before::Supervisor.Snapshot;deadline::Float64,check)
    op=RunnerProtocol.operation_id(command)
    stopping=op in (1,7,9,11)
    starting=op in (8,10)
    resetting=op==12
    source=before.source
    if resetting&&source!==nothing&&source.binding.profile=="pipewireao.rtc.calibration-lifecycle/1"
        reject_control("source.reset","calibration reset requires a fresh instance")
    end
    if source===nothing || !(stopping||starting||resetting)
        return runner_request(deployment,command;deadline,check)
    end
    if resetting&&before.runner.status.lifecycle!==RunnerProtocol.Ready
        return runner_request(deployment,command;deadline,check)
    end
    starting&&source_completed(source) && reject_control("source.state","finite source completed; reset before start")
    was_running=source_running(source)
    stopping&&source_control(deployment,"pause";deadline,check)
    completion=runner_request(deployment,command;deadline,check)
    if completion.header.result==0
        if starting&&completion.lifecycle===RunnerProtocol.Running
            resumed=source_control(deployment,"resume";deadline,check,allow_rejection=true)
            resumed["ok"] || reject_control("source.state",something(resumed["error"],"source rejected resume"))
        elseif resetting
            source_control(deployment,"reset";deadline,check)
        end
    elseif stopping&&was_running&&!source_completed(source)
        source_control(deployment,"resume";deadline,check)
    end
    return completion
end

function public_check(deployment,runtime,ticket;ignore_rtc=false)
    NativeControlEndpoint.check_ticket(runtime.endpoint,ticket)
    check_processes(deployment;ignore_roles=ignore_rtc ? ("rtc",) : ())
    deployment.stopping && !ignore_rtc && throw(InterruptException())
    return nothing
end
function bounded_control_error(error::RunnerProtocol.RunnerError)
    field=ncodeunits(error.field)<=8192 ? error.field : "native.runner.error"
    message=ncodeunits(error.message)<=8192 ? error.message : "runner error diagnostics exceed public wire bound; inspect supervisor stderr"
    (field!=error.field||message!=error.message) && println(stderr,"native runner rejected: ",error.field,": ",error.message)
    return RunnerProtocol.RunnerError(field,message)
end
function serve_control(deployment::DeploymentRunner; snapshot_query=supervisor_snapshot, coordinator=coordinate)
    runtime=deployment.broker
    runtime isa NativeSupervisorRuntime.Runtime || return nothing
    runtime.dispatching && return nothing
    NativeSupervisorRuntime.poll!(runtime)
    ticket=NativeSupervisorRuntime.take!(runtime)
    ticket===nothing && return nothing
    runtime.dispatching=true
    fatal=nothing
    effects_started=false
    try
        phase=runtime.endpoint.lifecycle
        try
            Supervisor.validate_admission(phase,ticket.command)
        catch failure
            failure isa ArgumentError || rethrow()
            error=RunnerProtocol.RunnerError("control.phase",sprint(showerror,failure))
            NativeSupervisorRuntime.complete!(runtime,ticket,phase,nothing;result=Int32(-16),error)
            return nothing
        end
        check_fn=()->public_check(deployment,runtime,ticket)
        if phase!==Supervisor.Admitted
            snapshot=Supervisor.Snapshot(Supervisor.OwnedProcess[],nothing,nothing,nothing)
            NativeSupervisorRuntime.complete!(runtime,ticket,phase,snapshot)
            return nothing
        end
        before=snapshot_query(deployment;deadline=ticket.deadline,check=check_fn)
        op=RunnerProtocol.operation_id(ticket.command)
        if op==3
            NativeSupervisorRuntime.complete!(runtime,ticket,phase,before)
            return nothing
        end
        mutating=!(op in (2,4,5,6))
        mutating&&Supervisor.preflight_mutation_reply(ticket.command,before;snapshot_bound=future_snapshot_bound(before))
        # Read-only catalog queries may reject their actual combined reply size.
        # Every effect-bearing command reserves the complete future reply first.
        effects_started=mutating
        coordination_check=op==1 ? (() -> public_check(deployment,runtime,ticket;ignore_rtc=true)) : check_fn
        completion=coordinator(deployment,ticket.command,before;deadline=ticket.deadline,check=coordination_check)
        if completion.header.result<0
            NativeSupervisorRuntime.complete!(runtime,ticket,phase,nothing;result=completion.header.result,error=bounded_control_error(something(completion.error)))
            return nothing
        end
        snapshot=op==1 ? before : snapshot_query(deployment;deadline=ticket.deadline,check=check_fn)
        result=Supervisor.RunnerRecord(completion.lifecycle,something(completion.result))
        NativeSupervisorRuntime.complete!(runtime,ticket,phase,snapshot;runner_result=result)
        if op==1
            NativeSupervisorRuntime.flush_terminal!(runtime,ticket.deadline;
                check=()->check_processes(deployment;ignore_roles=("rtc",)))
            deployment.native_shutdown=true
            deployment.stopping=true
            NativeSupervisorRuntime.lifecycle!(runtime,Supervisor.Stopping)
        end
    catch failure
        known=failure isa CoordinationRejected || failure isa ArgumentError && !effects_started
        phase=known ? runtime.endpoint.lifecycle : Supervisor.Failed
        field=failure isa CoordinationRejected ? failure.field : known ? "control.capacity" : "control.outcome"
        message=sprint(showerror,failure)
        ncodeunits(message)<=8192 || (message="control failed with oversized diagnostics; inspect supervisor stderr")
        error=RunnerProtocol.RunnerError(field,message)
        try
            NativeSupervisorRuntime.complete!(runtime,ticket,phase,nothing;result=Int32(-5),error)
        catch publication
            known=false
            failure=CompositeException([failure,publication])
        end
        if !known
            fatal=failure
            merge!(deployment.record,Dict("phase"=>"failed","admitted"=>false,"error"=>sprint(showerror,failure)))
            NativeSupervisorRuntime.lifecycle!(runtime,Supervisor.Failed)
        end
    finally
        runtime.dispatching=false
    end
    fatal===nothing || throw(fatal)
    return nothing
end
