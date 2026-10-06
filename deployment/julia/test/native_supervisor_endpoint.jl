using Test, JSON3, PipeWireAO, PipeWireAODeployment
include("test_native_supervisor_coordination.jl")
include("native_control_private_core.jl")
const Client=PipeWireAODeployment.NativeControlClient
const Public=PipeWireAODeployment.NativeSupervisorClient
const Runtime=PipeWireAODeployment.NativeSupervisorRuntime
const Endpoint=PipeWireAODeployment.NativeControlEndpoint
const SPA=PipeWireAO.SPA

function supervisor_endpoint_proof(remote,directory,daemon)
    chmod(dirname(remote),0o700)
    runtime=Runtime.Runtime(C.PROFILE,remote,"test.public.supervisor",Int64(42))
    deployment,backend,plant=supervisor_fixture()
    deployment.broker=runtime
    clients=Client.Client[]
    running=Ref(true);dispatch=Ref(true);oversized=Ref(false)
    deadlines=Float64[]
    function query_snapshot(deployment;deadline,check)
        check();push!(deadlines,deadline)
        snapshot=supervisor_fixture_snapshot(backend.state;sink=oversized[] ? repeat("s",64_500) : "sink")
        s=snapshot.source.snapshot
        source=C.SourceObservation(snapshot.source.binding,s.token,nothing,C.SimulatorSnapshot(s.version,s.instance,s.kind,s.token,s.result,
            plant.generation,s.sequence,plant.running,s.completed,plant.generation,s.report_sequence))
        return C.Snapshot(snapshot.processes,snapshot.runner,source,snapshot.heart)
    end
    service()=D.serve_control(deployment;snapshot_query=query_snapshot)
    owner=@async while running[]
        dispatch[]&&service()
        sleep(0.002)
    end
    locked(f)=with_thread_loop_lock(runtime.loop) do _;f(runtime.endpoint);end
    wait_endpoint(f,label)=wait_proof(()->locked(f),10,label)
    function raw(client,command;token=locked(e->e.last_token+1),budget=Int64(10_000_000_000),header=nothing,payload=nothing)
        h=header===nothing ? E.RequestHeader(something(client.identity),Int64(42),Int64(token),R.operation_id(command),budget) : header
        pod=payload===nothing ? Client.encode_request(C.PROFILE,h,command) : E.encode_request(h,payload)
        with_thread_loop_lock(client.loop) do _
            set_param!(something(client.node),SPA.PARAM_PROPS,pod)
        end
        return h,pod
    end
    reject_matches(h,code)=locked(e->begin
        rejected=C.decode_rejection(e.rejection)
        rejected.header.token==h.token&&rejected.header.controller==h.controller&&rejected.header.result==code
    end)
    try
        for i in 1:2
            push!(clients,Public.connect(remote,"test.public.supervisor",getpid(),42;deadline=Client.monotonic()+30))
        end
        @test Public.live_uuid(clients[1])==runtime.uuid
        @test Public.live_uuid(clients[2])==runtime.uuid
        matched=Public.connect(remote,"test.public.supervisor",getpid(),42;deadline=Client.monotonic()+30,expected_uuid=runtime.uuid)
        close(matched)
        @test_throws Client.UnknownOutcome Public.connect(remote,"test.public.supervisor",getpid(),42;deadline=Client.monotonic()+5,expected_uuid="00000000-0000-0000-0000-000000000001")
        locator_path=joinpath(directory,"supervisor-hints.json")
        PipeWireAODeployment.Common.write_json(locator_path,Dict("version"=>1,
            "profile"=>"pipewireao.rtc.deployment-supervisor/1","remote"=>remote,
            "node"=>"test.public.supervisor","owner_pid"=>getpid(),"instance"=>42))
        copied_locator=Public.read_locator(locator_path)
        # An atomically replaced file cannot redirect this already copied binding.
        PipeWireAODeployment.Common.write_json(locator_path,Dict("version"=>1,
            "profile"=>"pipewireao.rtc.deployment-supervisor/1","remote"=>remote,
            "node"=>"foreign.supervisor","owner_pid"=>getpid()+1,"instance"=>43);atomic=true)
        retained=Public.connect(copied_locator;deadline=Client.monotonic()+30)
        try
            @test Public.live_uuid(retained)==runtime.uuid
            status=Public.request!(retained,R.RunnerCommand(:status);deadline=Client.monotonic()+10)
            @test status.header.result==0
            @test retained.observation.owner_pid==getpid()
            @test retained.observation.instance==42
        finally
            close(retained)
        end
        @test clients[1].identity!=clients[2].identity
        @test clients[1].global_id==clients[2].global_id
        @test Client.profile_name(clients[1].observation.profile)=="pipewireao.rtc.deployment-supervisor/1"
        @test isempty(find_globals(something(clients[1].registry);interface="PipeWire:Interface:Port",properties=("node.id"=>string(clients[1].global_id),)))
        prepared=Public.request!(clients[1],R.RunnerCommand(:status);deadline=Client.monotonic()+30)
        @test prepared.lifecycle===C.Preparing&&!prepared.admitted&&isempty(prepared.snapshot.processes)
        @test prepared.snapshot.runner===nothing&&prepared.snapshot.source===nothing
        denied=Public.request!(clients[2],R.RunnerCommand(:session_stop);deadline=Client.monotonic()+30)
        @test denied.header.result<0&&denied.lifecycle===C.Preparing
        @test isempty(backend.calls)&&isempty(plant.calls)&&isempty(deadlines)
        Runtime.lifecycle!(runtime,C.Admitted)
        for (command,state) in ((R.RunnerCommand(:session_stop),R.Ready),(R.RunnerCommand(:reset),R.Ready),(R.RunnerCommand(:session_start),R.Running))
            before=length(deadlines)
            done=Public.request!(clients[1],command;deadline=Client.monotonic()+30)
            @test done.header.result==0&&done.result.lifecycle===state
            @test length(deadlines)==before+2&&deadlines[end]===deadlines[end-1]
            @test backend.calls[end][2]===deadlines[end]
            @test plant.calls[end][2]===deadlines[end]
        end
        current=Public.request!(clients[2],R.RunnerCommand(:status);deadline=Client.monotonic()+30)
        @test current.snapshot.source.snapshot.generation==2&&current.snapshot.source.snapshot.running
        @test Public.render(current)["session_id"]=="native-runner-instance:10"
        # Selected control reads only a locator, then binds/query-verifies actual metadata.
        locator=joinpath(directory,"control.json")
        D.atomic_record(locator,Dict("version"=>1,"profile"=>Client.profile_name(C.PROFILE),"remote"=>remote,
            "node"=>"test.public.supervisor","owner_pid"=>getpid(),"instance"=>42))
        via_locator=D.control(locator,["status"];timeout=30)
        if haskey(ENV,"SUPERVISOR_CLI_BINARY")
            # Actual Rust library client and selected CLI against this same owner.
            cli=ENV["SUPERVISOR_CLI_BINARY"]
            rust=JSON3.read(read(`$cli control --locator $locator -- status`,String),Dict{String,Any})
            @test rust["ok"]&&rust["admitted"]&&rust["state"]=="Running"
            @test rust["deployment_uuid"]==runtime.uuid
            @test rust["source"]["generation"]==2
            for command in ("session-stop","reset","session-start")
                rust=JSON3.read(read(`$cli control --locator $locator -- $command`,String),Dict{String,Any})
                @test rust["ok"]&&rust["admitted"]
            end
            @test backend.state===R.Running&&plant.running
            wrong_path=joinpath(directory,"wrong-control.json")
            for (key,value) in (("owner_pid",getpid()+1),("instance",43),("profile","pipewireao.rtc.runner/1"))
                hints=PipeWireAODeployment.Common.read_json(locator;maximum=4096);hints[key]=value
                D.atomic_record(wrong_path,hints)
                previous=(length(backend.calls),length(plant.calls))
                child=run(pipeline(ignorestatus(`$cli control --locator $wrong_path -- session-stop`);stdout=devnull,stderr=devnull))
                @test !success(child)
                @test (length(backend.calls),length(plant.calls))==previous
            end

        end
        @test via_locator["ok"]&&via_locator["admitted"]&&via_locator["state"]=="Running"
        # An explicit source rejection preserves the known applied inner result.
        Public.request!(clients[2],R.RunnerCommand(:session_stop);deadline=Client.monotonic()+30)
        plant.reject_resume=true
        partial=Public.request!(clients[2],R.RunnerCommand(:session_start);deadline=Client.monotonic()+30)
        @test partial.header.result<0&&partial.lifecycle===C.Admitted&&partial.snapshot===nothing
        @test partial.result.lifecycle===R.Running&&partial.result.result.outcome===R.Completed
        @test backend.calls[end][2]===plant.calls[end][2]===deadlines[end]
        shown=Public.render(partial)
        @test !shown["ok"]&&shown["state"]=="Running"&&shown["result"]["outcome"]=="completed"&&shown["error"]["field"]=="source.state"
        fresh=Public.request!(clients[2],R.RunnerCommand(:status);deadline=Client.monotonic()+30)
        @test fresh.snapshot.runner.status.lifecycle===R.Running&&!fresh.snapshot.source.snapshot.running
        if haskey(ENV,"SUPERVISOR_CLI_BINARY")
            Public.request!(clients[2],R.RunnerCommand(:session_stop);deadline=Client.monotonic()+30)
            cli=ENV["SUPERVISOR_CLI_BINARY"]
            rust=JSON3.read(read(pipeline(ignorestatus(`$cli control --locator $locator -- session-start`);stderr=devnull),String),Dict{String,Any})
            @test !rust["ok"]&&rust["state"]=="Running"&&rust["result"]["outcome"]=="completed"&&rust["error"]["field"]=="source.state"
            rust=JSON3.read(read(`$cli control --locator $locator -- status`,String),Dict{String,Any})
            @test rust["state"]=="Running"&&rust["source"]["state"]=="paused"
        end
        plant.reject_resume=false
        Public.request!(clients[2],R.RunnerCommand(:session_stop);deadline=Client.monotonic()+30)
        Public.request!(clients[2],R.RunnerCommand(:session_start);deadline=Client.monotonic()+30)
        # A replay preserves its retained result and has no source/runner effects.
        Public.request!(clients[1],R.RunnerCommand(:status);deadline=Client.monotonic()+30)
        terminal=locked(e->e.terminal_request)
        previous_calls=(length(backend.calls),length(plant.calls))
        _,pod=raw(clients[1],terminal.command;header=terminal.header)
        sleep(0.02)
        @test locked(e->e.terminal_request===terminal&&e.pending===nothing)
        @test (length(backend.calls),length(plant.calls))==previous_calls
        conflict=E.RequestHeader(terminal.header.controller,Int64(42),terminal.header.token,UInt32(10),Int64(1_000_000_000))
        raw(clients[1],R.RunnerCommand(:session_start);header=conflict)
        wait_proof(()->reject_matches(conflict,Int32(-114)),10,"conflicting replay")
        @test locked(e->e.last_token==terminal.header.token)
        # Malformed native payload keeps accepted state and never executes effects.
        malformed=E.RequestHeader(something(clients[1].identity),Int64(42),terminal.header.token+1,UInt32(9),Int64(1_000_000_000))
        raw(clients[1],R.RunnerCommand(:session_stop);header=malformed,payload=SPA.Struct(Pod(Int64(1))))
        wait_proof(()->reject_matches(malformed,Int32(-22)),10,"malformed request")
        @test locked(e->e.last_token==terminal.header.token)
        # Busy uses another actual caller and does not advance the accepted token.
        dispatch[]=false
        pending,_=raw(clients[1],R.RunnerCommand(:session_stop))
        wait_endpoint(e->e.pending!==nothing,"pending request")
        busy,_=raw(clients[2],R.RunnerCommand(:session_start);token=pending.token+1)
        wait_proof(()->reject_matches(busy,Int32(-16)),10,"other caller busy")
        @test locked(e->e.last_token==pending.token)
        service()
        wait_endpoint(e->e.pending===nothing,"normal queued dispatch")
        dispatch[]=true
        # Earlier token is stale after a newer terminal operation.
        stale=terminal.header
        raw(clients[1],terminal.command;header=stale)
        wait_proof(()->reject_matches(stale,Int32(-116)),10,"stale request")
        # Combined reply overflow is rejected before source pause/runner mutation.
        oversized[]=true
        previous_calls=(length(backend.calls),length(plant.calls))
        capacity=Public.request!(clients[2],R.RunnerCommand(:session_stop);deadline=Client.monotonic()+30)
        @test capacity.header.result<0&&capacity.error.field=="control.capacity"
        @test (length(backend.calls),length(plant.calls))==previous_calls
        oversized[]=false
        # Accepted queue expiry retains terminal failure without effects.
        dispatch[]=false
        previous_calls=(length(backend.calls),length(plant.calls))
        expired,_=raw(clients[1],R.RunnerCommand(:session_start);budget=Int64(1_000_000))
        wait_endpoint(e->e.pending!==nothing,"expiry admission")
        sleep(0.01);service()
        failed=locked(e->C.decode_completion(e.completion))
        @test failed.header.token==expired.token&&failed.header.result==-110
        @test (length(backend.calls),length(plant.calls))==previous_calls
        # Removing an actual marker fences queued work before dispatch.
        removed,_=raw(clients[1],R.RunnerCommand(:session_start))
        wait_endpoint(e->e.pending!==nothing,"removed caller admission")
        with_thread_loop_lock(clients[1].loop) do _;close(clients[1].marker);end
        wait_proof(()->begin Runtime.poll!(runtime);locked(e->!Endpoint.controller_present(e,removed.controller)) end,10,"actual caller removal")
        service()
        failed=locked(e->C.decode_completion(e.completion))
        @test failed.header.token==removed.token&&failed.header.result==-110
        @test (length(backend.calls),length(plant.calls))==previous_calls
        @test_throws Client.UnknownOutcome Public.request!(clients[1],R.RunnerCommand(:status);deadline=Client.monotonic()+5)
        dispatch[]=true
        # Successful terminal quit flushes before endpoint/owner cleanup.
        quit=Public.request!(clients[2],R.RunnerCommand(:quit);deadline=Client.monotonic()+30)
        @test quit.header.result==0&&quit.result.result.outcome===R.Accepted
        wait_proof(()->deployment.stopping,10,"quit terminal flush")
        @test deployment.native_shutdown
        @test Public.render(quit)["snapshot_order"]=="before_quit_effect"
        running[]=false;wait(owner)
        close(runtime)
        @test_throws Client.UnknownOutcome Public.request!(clients[2],R.RunnerCommand(:status);deadline=Client.monotonic()+5)
    finally
        running[]=false
        istaskdone(owner)||wait(owner)
        foreach(close,reverse(clients))
        close(runtime)
    end
end
@testset "actual public supervisor native callers and staged coordinator" begin
    with_control_private_core(supervisor_endpoint_proof)
end
