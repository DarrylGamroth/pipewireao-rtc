if haskey(ENV,"PIPEWIREAO_TEST_SDK")
    pushfirst!(LOAD_PATH,ENV["PIPEWIREAO_TEST_SDK"])
end
using Test, PipeWireAO, SHA
pushfirst!(LOAD_PATH,normpath(joinpath(@__DIR__,"../julia")))
using PipeWireAODeployment

# Reuse the existing synthetic acquisition and its protocol regressions.
include("test_calibration_server.jl")
include("native_acquisition_lifecycle.jl")
include("native_calibration_actions.jl")
include("../julia/test/native_control_private_core.jl")
const Lifecycle = HILNativeAcquisitionLifecycle
const Actions = HILNativeCalibrationActions
const Native = PipeWireAODeployment.NativeCalibrationActionClient
const Generic = PipeWireAODeployment.NativeControlClient
const Codec = PipeWireAODeployment.NativeCalibrationActionCodec

function native_fixture(f,socket,daemon;samples=[Float32[3,4]],accept_ns=UInt64(20_000_000_000),io_ns=UInt64(5_000_000_000),build_fixture=nothing,service_control=owner->nothing)
    chmod(dirname(socket),0o700)
    instance=Int64(time_ns()%UInt64(typemax(Int64)-1))+1
    node="test.native.calibration.$instance"
    bridge=Lifecycle.Bridge((;profile=:classic,remote=socket,control_node=node,control_instance=instance),Lifecycle.Codec.CALIBRATION_PROFILE)
    actions=Actions.ActionServer(bridge,node)
    fixture=build_fixture===nothing ? server_fixture(;samples) : build_fixture()
    fixture.owner.maximum_timeout_ns=UInt64(10_000_000_000)
    enabled=Ref(true)
    failure=Ref{Any}(nothing)
    task=nothing
    check()=begin
        Base.process_exited(daemon) && error("private core exited")
        failure[]===nothing || throw(failure[])
        nothing
    end
    try
        @test actions.endpoint.loop === bridge.runtime.loop
        @test actions.endpoint.lifecycle === Lifecycle.Codec.Preparing
        Lifecycle.lifecycle!(bridge,Lifecycle.Codec.Prepared)
        @test actions.endpoint.lifecycle === Lifecycle.Codec.Prepared
        Lifecycle.lifecycle!(bridge,Lifecycle.Codec.Connected)
        task=@async try
            Actions.serve!(actions,fixture.owner;accept_timeout_ns=accept_ns,io_timeout_ns=io_ns,
                admission_enabled=()->enabled[],service_control=()->service_control(fixture.owner))
        catch error
            failure[]=error
        end
        binding=Native.Binding(socket,Actions.action_node(node),getpid(),instance)
        f((;bridge,actions,fixture,enabled,failure,task,binding,check))
    finally
        if task!==nothing && !istaskdone(task)
            close(bridge)
            timedwait(()->istaskdone(task),5;pollint=0.005)==:ok || error("native action owner did not exit")
        end
        close(bridge)
        task===nothing || wait(task)
    end
end
native_connect(test;run=typemax(UInt64),command_count=2) = Native.connect(test.binding,run,2_000_000_000;
    command_count,deadline=Generic.monotonic()+15,check=test.check)
native_request(client,action,expected) = Native.request!(client,action,expected;deadline=Generic.monotonic()+5)
function stage_native(test,client,action;budget_ns=Int64(5_000_000_000))
    token=with_thread_loop_lock(test.bridge.runtime.loop) do _
        test.actions.endpoint.last_token+1
    end
    header=PipeWireAODeployment.NativeControlCodec.RequestHeader(client.client.identity,
        test.binding.instance,token,Codec.Client.operation_id(Codec.PROFILE,Codec.Command(client.run,UInt64(1),action)),budget_ns)
    pod=Codec.Client.encode_request(Codec.PROFILE,header,Codec.Command(client.run,UInt64(1),action))
    with_thread_loop_lock(client.client.loop) do _
        set_param!(something(client.client.node),PipeWireAO.SPA.PARAM_PROPS,pod)
    end
    wait_proof(()->test.actions.endpoint.pending!==nothing,5,"native ticket staged")
    return test.actions.endpoint.pending
end
function published_fault(test)
    lifecycle=PipeWireAODeployment.NativeAcquisitionLifecycleCodec
    observer=Generic.connect(lifecycle.CALIBRATION_PROFILE,test.binding.remote,
        chop(test.binding.node;tail=8),test.binding.owner_pid,test.binding.instance;
        deadline=Generic.monotonic()+5,
        check=()->Lifecycle.Runtime.poll!(test.bridge.runtime))
    try
        Generic.poll(observer,Generic.monotonic()+5,()->nothing) do
            capability=observer.observation.capability
            capability!==nothing && capability.lifecycle===lifecycle.Fault
        end
        return true
    finally
        close(observer)
    end
end

@testset "native actions on the sole lifecycle core, exact owner and UInt64 run" begin
    with_control_private_core() do socket,directory,daemon
        native_fixture(socket,daemon) do test
            bad=Native.Binding(socket,test.binding.node,getpid(),test.binding.instance+1)
            @test_throws Generic.UnknownOutcome Native.connect(bad,1,1_000_000_000;command_count=2,deadline=Generic.monotonic()+0.3)
            bad_pid=Native.Binding(socket,test.binding.node,getpid()+1,test.binding.instance)
            @test_throws Generic.UnknownOutcome Native.connect(bad_pid,1,1_000_000_000;command_count=2,deadline=Generic.monotonic()+0.3)
            client=native_connect(test)
            try
                client.serial=UInt64(1)<<63
                held=native_request(client,Codec.Hold(),"held")
                @test test.fixture.owner.run==typemax(UInt64)
                @test test.fixture.owner.serial==(UInt64(1)<<63)+1
                @test Tuple(getfield(test.actions.controller,name) for name in (:global_id,:serial,:instance))==Tuple(getfield(client.client.identity,name) for name in (:global_id,:serial,:instance))
                @test held["cursor"]["sequence"]==0
                adopted=native_request(client,Dict("kind"=>"adopt","probe"=>0,"figure"=>[1,2]),"adopted")
                settled=native_request(client,Dict("kind"=>"settle","probe"=>0,"after"=>adopted["cursor"],"rule"=>Dict("kind"=>"immediate")),"settled")
                responses=native_request(client,Dict("kind"=>"collect","probe"=>0,"after"=>settled["cursor"],"measurements"=>2,"frames"=>3),"responses")
                @test responses["values"]==Float32[3,4]
                @test length(responses["exposures"])==3 && responses["valid"]
                @test test.fixture.session.sequence==3
                restored=native_request(client,Codec.Restore(Float32[0,0],Codec.Immediate()),"restored")
                @test !restored["clipped"] && test.fixture.owner.restored
                @test native_request(client,Codec.Release(),"released")["kind"]=="released"
                close(client) # Terminal disconnect cannot fabricate another hold.
                timedwait(()->istaskdone(test.task),5;pollint=0.005)==:ok || error("Release service did not finish")
                @test test.failure[]===nothing
                @test test.actions.released && test.fixture.owner.phase===:released
                @test test.actions.endpoint.closed && test.bridge.action_endpoint===nothing
                @test !test.bridge.runtime.endpoint.closed
                @test !test.fixture.owner.held && !test.fixture.session.held && !test.fixture.owner.faulted
                @test !ispath(joinpath(directory,"calibration.sock"))
            finally
                close(client)
            end
        end
    end
end

@testset "native action preflight rejects before exposure and admits native capacity" begin
    with_control_private_core() do socket,directory,daemon
        native_fixture(socket,daemon;samples=[fill(3f0,30000)]) do test
            client=native_connect(test)
            try
                native_request(client,Codec.Hold(),"held")
                adopted=native_request(client,Codec.Adopt(UInt32(0),Float32[1,2]),"adopted")
                after=Native._cursor(adopted["cursor"])
                native_request(client,Codec.Settle(UInt32(0),after,Codec.Immediate()),"settled")
                @test_throws ArgumentError native_request(client,Codec.Collect(UInt32(0),after,UInt32(30000),UInt32(1000)),"responses")
                @test client.can_restore
                @test isempty(test.fixture.session.exposure_budgets)
                @test test.fixture.owner.phase===:settled && !test.fixture.owner.faulted
                values=native_request(client,Codec.Collect(UInt32(0),after,UInt32(30000),UInt32(1)),"responses")
                @test length(values["values"])==30000 && all(==(3f0),values["values"])
                @test length(test.fixture.session.exposure_budgets)==1
                @test 512+16*30000+180>Server.MAX_REPLY_BYTES # Fail-before JSON capacity.
                native_request(client,Codec.Restore(Float32[0,0],Codec.Immediate()),"restored")
                native_request(client,Codec.Release(),"released")
            finally
                close(client)
            end
        end
    end
end

@testset "native action controller fencing and admission cancellation preserve effects" begin
    with_control_private_core() do socket,directory,daemon
        native_fixture(socket,daemon) do test
            client=native_connect(test)
            second=native_connect(test;run=UInt64(2))
            try
                native_request(client,Codec.Hold(),"held")
                serial=test.fixture.owner.serial
                @test_throws ArgumentError native_request(second,Codec.Restore(Float32[2,2],Codec.Immediate()),"restored")
                @test isempty(test.fixture.session.adopted) && test.fixture.owner.serial==serial
                @test Tuple(getfield(test.actions.controller,name) for name in (:global_id,:serial,:instance))==Tuple(getfield(client.client.identity,name) for name in (:global_id,:serial,:instance)) && test.fixture.owner.held
                client.run=UInt64(1)
                @test_throws ArgumentError native_request(client,Codec.Adopt(UInt32(0),Float32[1,2]),"adopted")
                @test client.can_restore && test.fixture.owner.run==typemax(UInt64)
                @test test.fixture.owner.serial==serial && isempty(test.fixture.session.adopted)
                client.run=typemax(UInt64)
                client.serial=serial-UInt64(1)
                @test_throws ArgumentError native_request(client,Codec.Adopt(UInt32(0),Float32[1,2]),"adopted")
                @test client.can_restore && test.fixture.owner.serial==serial
                test.enabled[]=false
                @test_throws ArgumentError native_request(client,Codec.Adopt(UInt32(0),Float32[1,2]),"adopted")
                @test !client.can_restore && isempty(test.fixture.session.adopted)
                @test test.fixture.owner.serial==serial && test.fixture.owner.phase===:held
                # Paused acquisition still admits restoration and release.
                native_request(client,Codec.Restore(Float32[0,0],Codec.Immediate()),"restored")
                native_request(client,Codec.Release(),"released")
                @test test.fixture.owner.phase===:released && test.fixture.owner.restored
            finally
                close(second);close(client)
            end
        end
    end
end

@testset "native controller loss before restoration retains hold" begin
    with_control_private_core() do socket,directory,daemon
        native_fixture(socket,daemon) do test
            client=native_connect(test)
            native_request(client,Codec.Hold(),"held")
            close(client)
            timedwait(()->istaskdone(test.task),5;pollint=0.005)==:ok || error("removed controller did not fault owner")
            @test test.failure[] isa Lifecycle.TransportFailure
            @test test.fixture.owner.faulted && test.fixture.owner.held && test.fixture.session.held
            @test !test.fixture.owner.restored
            @test test.bridge.runtime.endpoint.lifecycle===Lifecycle.Codec.Fault
            @test published_fault(test)
        end
    end
end

@testset "foreign ticket retirement preserves bound controller and SCI facts" begin
    for scenario in (:expired_before_take,:removed_before_take,:expired_while_applying)
        with_control_private_core() do socket,directory,daemon
            blocked=Ref(false);entered=Ref(false)
            gate=owner->begin
                if blocked[]
                    entered[]=true
                    while blocked[];sleep(0.002);end
                end
                nothing
            end
            native_fixture(socket,daemon;io_ns=UInt64(20_000_000_000),service_control=gate) do test
                first=native_connect(test);second=native_connect(test;run=UInt64(2))
                try
                    native_request(first,Codec.Hold(),"held")
                    accepted=(test.fixture.owner.run,test.fixture.owner.serial,test.actions.controller,test.actions.last_activity)
                    blocked[]=true
                    wait_proof(()->entered[],5,"owner boundary gate")
                    budget=scenario===:removed_before_take ? Int64(5_000_000_000) : Int64(500_000_000)
                    ticket=stage_native(test,second,Codec.Restore(Float32[2,2],Codec.Immediate());budget_ns=budget)
                    if scenario===:removed_before_take
                        with_thread_loop_lock(second.client.loop) do _
                            close(something(second.client.marker))
                        end
                        wait_proof(()->with_thread_loop_lock(test.bridge.runtime.loop) do _
                            !Actions.Endpoint.controller_present(test.actions.endpoint,ticket.header.controller)
                        end,5,"foreign controller removal")
                    else
                        if scenario===:expired_while_applying
                            @test Actions.Endpoint.take!(test.actions.endpoint)===ticket
                        end
                        wait_proof(()->Generic.monotonic()>=ticket.deadline,5,"foreign request expiry")
                        if scenario===:expired_while_applying
                            @test Actions.apply!(test.actions,test.fixture.owner,ticket)===nothing
                        end
                    end
                    blocked[]=false
                    wait_proof(()->test.actions.terminal===ticket || test.failure[]!==nothing,5,"foreign terminal resolution")
                    @test test.failure[]===nothing && !test.fixture.owner.faulted
                    @test test.fixture.owner.phase===:held && test.fixture.owner.held && test.fixture.session.held
                    @test (test.fixture.owner.run,test.fixture.owner.serial,test.actions.controller,test.actions.last_activity)==accepted
                    @test isempty(test.fixture.session.adopted)
                    native_request(first,Codec.Restore(Float32[0,0],Codec.Immediate()),"restored")
                    native_request(first,Codec.Release(),"released")
                finally
                    blocked[]=false;close(second);close(first)
                end
            end
        end
    end
end

@testset "expired initial invalid ticket cannot bind action authority" begin
    with_control_private_core() do socket,directory,daemon
        blocked=Ref(false);entered=Ref(false)
        gate=owner->begin
            if blocked[]
                entered[]=true
                while blocked[];sleep(0.002);end
            end
            nothing
        end
        native_fixture(socket,daemon;service_control=gate) do test
            first=native_connect(test);second=native_connect(test;run=UInt64(2))
            try
                blocked[]=true
                wait_proof(()->entered[],5,"initial owner gate")
                ticket=stage_native(test,second,Codec.Adopt(UInt32(0),Float32[1,2]);budget_ns=Int64(500_000_000))
                wait_proof(()->Generic.monotonic()>=ticket.deadline,5,"initial ticket expiry")
                blocked[]=false
                wait_proof(()->test.actions.terminal===ticket || test.failure[]!==nothing,5,"initial terminal resolution")
                @test test.failure[]===nothing && test.actions.controller===nothing
                @test test.fixture.owner.run==0 && test.fixture.owner.serial==0 && !test.fixture.owner.faulted
                @test !test.fixture.owner.held && isempty(test.fixture.session.adopted)
                native_request(first,Codec.Hold(),"held")
                native_request(first,Codec.Restore(Float32[0,0],Codec.Immediate()),"restored")
                native_request(first,Codec.Release(),"released")
            finally
                blocked[]=false;close(second);close(first)
            end
        end
    end
end

@testset "instrument extents reject before controller and SCI identity binding" begin
    with_control_private_core() do socket,directory,daemon
        native_fixture(socket,daemon) do test
            client=native_connect(test)
            try
                @test_throws ArgumentError native_request(client,Codec.Restore(Float32[0],Codec.Immediate()),"restored")
                @test test.actions.controller===nothing && test.fixture.owner.run==0 && test.fixture.owner.serial==0
                @test !test.fixture.owner.held && !test.fixture.owner.faulted && isempty(test.fixture.session.adopted)
                native_request(client,Codec.Hold(),"held")
                serial=test.fixture.owner.serial
                activity=test.actions.last_activity
                @test_throws ArgumentError native_request(client,Codec.Adopt(UInt32(0),Float32[1]),"adopted")
                @test test.fixture.owner.serial==serial && test.actions.last_activity==activity
                @test test.fixture.owner.phase===:held && isempty(test.fixture.session.adopted)
                adopted=native_request(client,Codec.Adopt(UInt32(0),Float32[1,2]),"adopted")
                after=Native._cursor(adopted["cursor"])
                native_request(client,Codec.Settle(UInt32(0),after,Codec.Immediate()),"settled")
                serial=test.fixture.owner.serial
                @test_throws ArgumentError native_request(client,Codec.Collect(UInt32(0),after,UInt32(1),UInt32(1)),"responses")
                @test test.fixture.owner.serial==serial && isempty(test.fixture.session.exposure_budgets)
                @test test.fixture.owner.phase===:settled && !test.fixture.owner.faulted
                native_request(client,Codec.Restore(Float32[0,0],Codec.Immediate()),"restored")
                native_request(client,Codec.Release(),"released")
            finally
                close(client)
            end
        end
    end
end

@testset "finite inactivity starts at receipt and includes scientific effect time" begin
    with_control_private_core() do socket,directory,daemon
        native_fixture(socket,daemon;io_ns=UInt64(1_000_000_000)) do test
            client=native_connect(test)
            try
                native_request(client,Codec.Hold(),"held")
                adopted=native_request(client,Codec.Adopt(UInt32(0),Float32[1,2]),"adopted")
                after=Native._cursor(adopted["cursor"])
                native_request(client,Codec.Settle(UInt32(0),after,Codec.Immediate()),"settled")
                test.fixture.session.delay=1.2
                @test_throws Generic.UnknownOutcome native_request(client,Codec.Collect(UInt32(0),after,UInt32(2),UInt32(1)),"responses")
                @test istaskdone(test.task) && test.failure[] isa Server.OwnerServiceAbort
                @test test.fixture.owner.faulted && test.fixture.owner.held && test.fixture.session.held
                @test test.actions.endpoint.closed
                @test test.bridge.runtime.endpoint.lifecycle===Lifecycle.Codec.Fault
                @test published_fault(test)
            finally
                close(client)
            end
        end
    end
end

@testset "native capture commits the unchanged immutable manifest" begin
    with_control_private_core() do socket,directory,daemon
        factory = () -> begin
            inner=server_fixture(;samples=[zeros(Float32,376)]).session
            session=CaptureTestSession(inner,zeros(UInt16,352*352),fill(10f0,188),fill(true,188),0,false,0.0)
            store=Server.CaptureStore(joinpath(directory,"capture");maximum_bytes=2Server.CLASSIC_CAPTURE_BYTES)
            owner=Server.Owner(session;normal_controller_absent=true,command_count=2,measurement_count=376,
                maximum_timeout_ns=UInt64(10_000_000_000),capture=store)
            (;session,owner,store)
        end
        native_fixture(socket,daemon;build_fixture=factory) do test
            client=native_connect(test)
            try
                native_request(client,Codec.Hold(),"held")
                adopted=native_request(client,Codec.Adopt(UInt32(0),Float32[1,2]),"adopted")
                after=Native._cursor(adopted["cursor"])
                native_request(client,Codec.Settle(UInt32(0),after,Codec.Immediate()),"settled")
                captured=native_request(client,Codec.Capture(UInt32(0),after,UInt32(1)),"captured")
                manifest=joinpath(test.fixture.store.directory,captured["manifest"])
                @test isfile(manifest)
                @test captured["sha256"]==bytes2hex(open(sha256,manifest))
                saved=PipeWireAODeployment.Common.read_json(manifest)
                @test saved["run"]==typemax(UInt64) && saved["serial"]==4
                @test saved["frames"]==1 && saved["bytes"]==Server.CLASSIC_CAPTURE_BYTES
                @test captured["metadata_bytes"]==filesize(manifest)
                @test test.fixture.store.reserved_bytes==Server.CLASSIC_CAPTURE_BYTES
                native_request(client,Codec.Restore(Float32[0,0],Codec.Immediate()),"restored")
                native_request(client,Codec.Release(),"released")
            finally
                close(client)
            end
        end
    end
end

@testset "transport abort after the Release effect retains the released SCI fact" begin
    with_control_private_core() do socket,directory,daemon
        abort_after_release = owner -> owner.phase === :released &&
            throw(Server.OwnerServiceAbort(Lifecycle.TransportFailure(ErrorException("synthetic post-Release transport loss"))))
        native_fixture(socket,daemon;service_control=abort_after_release) do test
            client=native_connect(test)
            try
                native_request(client,Codec.Hold(),"held")
                native_request(client,Codec.Restore(Float32[0,0],Codec.Immediate()),"restored")
                @test_throws Generic.UnknownOutcome native_request(client,Codec.Release(),"released")
                @test istaskdone(test.task) && test.failure[] isa Server.OwnerServiceAbort
                @test test.fixture.owner.phase===:released && test.actions.released
                @test !test.fixture.owner.held && !test.fixture.session.held && !test.fixture.owner.faulted
                @test test.actions.endpoint.closed && !test.bridge.runtime.endpoint.closed
                @test test.bridge.runtime.endpoint.lifecycle===Lifecycle.Codec.Connected
            finally
                close(client)
            end
        end
    end
end

@testset "malformed native requests reject without disturbing healthy calibration" begin
    with_control_private_core() do socket,directory,daemon
        native_fixture(socket,daemon) do test
            client=native_connect(test)
            try
                header=PipeWireAODeployment.NativeControlCodec.RequestHeader(client.client.identity,
                    test.binding.instance,Int64(100),UInt32(1),Int64(1_000_000_000))
                pod=PipeWireAODeployment.NativeControlCodec.encode_request(header,
                    PipeWireAO.SPA.Struct(PipeWireAO.Pod[PipeWireAO.Pod(Int64(1)),PipeWireAO.Pod(Int64(1)),
                        PipeWireAO.Pod(PipeWireAO.SPA.Struct(PipeWireAO.Pod(Int32(7))))]))
                with_thread_loop_lock(client.client.loop) do _
                    set_param!(something(client.client.node),PipeWireAO.SPA.PARAM_PROPS,pod)
                end
                timedwait(()->client.client.observation.rejection!==nothing &&
                    client.client.observation.rejection.value.header.token==100,5;pollint=0.005)==:ok || error("malformed rejection not observed")
                @test test.fixture.owner.run==0 && test.fixture.owner.serial==0
                @test !test.fixture.owner.held && !test.fixture.owner.faulted
                native_request(client,Codec.Hold(),"held")
                native_request(client,Codec.Restore(Float32[0,0],Codec.Immediate()),"restored")
                native_request(client,Codec.Release(),"released")
                @test test.fixture.owner.phase===:released
            finally
                close(client)
            end
        end
    end
end

if haskey(ENV,"PIPEWIREAO_RTC_CALIBRATE_TEST_BINARY")
    @testset "Rust coordinator uses the exact native Julia action owner" begin
        binary=ENV["PIPEWIREAO_RTC_CALIBRATE_TEST_BINARY"]
        @test isfile(binary)
        with_control_private_core() do socket,directory,daemon
            native_fixture(socket,daemon;io_ns=UInt64(20_000_000_000)) do test
                plan=Dict("version"=>1,"run"=>typemax(UInt64),"reference"=>Float32[0,0],
                    "probes"=>[Float32[1,2]],"measurements"=>2,"frames_per_probe"=>3,
                    "settling"=>Dict("kind"=>"immediate"),
                    "timeouts_ns"=>Dict(name=>UInt64(5_000_000_000) for name in
                        ("ownership","adoption","settling","collection","restoration")))
                path=joinpath(directory,"plan.json")
                PipeWireAODeployment.Common.write_json(path,plan)
                output=joinpath(directory,"result.json");errors=joinpath(directory,"rust.stderr")
                binding=test.binding
                for (pid,instance) in ((binding.owner_pid+UInt32(1),binding.instance),
                                       (binding.owner_pid,binding.instance+1))
                    rejected=`$binary --remote $(binding.remote) --node $(binding.node) --owner-pid $pid --owner-instance $instance --plan $path`
                    child=run(pipeline(ignorestatus(rejected);stdout=output,stderr=errors);wait=false)
                    try
                        wait_proof(()->process_exited(child),10,"Rust exact owner binding rejection")
                        @test !success(child)
                        @test test.fixture.owner.run==0 && test.fixture.owner.serial==0
                        @test !test.fixture.owner.held && !test.fixture.owner.faulted
                    finally
                        stop_proof_child!(child,"Rust rejected calibration client")
                    end
                end
                command=`$binary --remote $(binding.remote) --node $(binding.node) --owner-pid $(binding.owner_pid) --owner-instance $(binding.instance) --plan $path`
                child=run(pipeline(command;stdout=output,stderr=errors);wait=false)
                try
                    wait_proof(()->process_exited(child),20,"Rust native calibration completion")
                    @test success(child)
                    success(child) || error(read(errors,String))
                    result=PipeWireAODeployment.Common.read_json(output)
                    @test result["run"]==typemax(UInt64) && result["phase"]=="complete"
                    @test result["restoration_confirmed"] && result["resume_permitted"]
                    @test only(result["responses"])["values"]==Float32[3,4]
                    @test length(only(result["responses"])["exposures"])==3
                    @test test.fixture.owner.run==typemax(UInt64) && test.fixture.owner.serial==6
                    @test test.fixture.owner.phase===:released && !test.fixture.owner.held && !test.fixture.owner.faulted
                    wait_proof(()->istaskdone(test.task),5,"owner terminal flush and ingress closure")
                    @test test.failure[]===nothing
                    @test test.actions.endpoint.closed && !test.bridge.runtime.endpoint.closed
                    @test !ispath(joinpath(directory,"calibration.sock"))
                finally
                    stop_proof_child!(child,"Rust calibration client")
                end
            end
        end
    end
end
