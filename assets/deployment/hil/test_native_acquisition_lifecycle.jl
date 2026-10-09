using Test, PipeWireAO, PipeWireAODeployment

include(joinpath(PipeWireAODeployment.package_root(), "test", "native_control_private_core.jl"))
include("owner_protocol.jl")
include("native_acquisition_lifecycle.jl")

const Lifecycle = HILNativeAcquisitionLifecycle
const Codec = Lifecycle.Codec
const Caller = PipeWireAODeployment.NativeAcquisitionLifecycleClient
const CallerCodec = PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const Generic = PipeWireAODeployment.NativeControlClient

@testset "HIL lifecycle bridge retains released action facts on expired completion" begin
    with_control_private_core() do socket, _, daemon
        chmod(dirname(socket),0o700)
        instance=Int64(time_ns() % UInt64(typemax(Int64)-1))+1
        node="test.hil.acquisition.bridge"
        options=(;profile=:classic,remote=socket,control_node=node,control_instance=instance)
        bridge=Lifecycle.Bridge(options,Codec.CALIBRATION_PROFILE)
        state=HILOwnerProtocol.OwnerState()
        # Mutable action facts model the already completed Release effect.
        phase=Ref("initial"); held=Ref(false); restored=Ref(false)
        cursor=Ref{Union{Nothing,Codec.AcquisitionCursor}}(nothing)
        delay_snapshot=Ref(false)
        owner_failure=Ref{Any}(nothing)
        stop=Ref(false)
        safe_mode=Ref(true)
        worker=nothing;client=nothing
        check=() -> (Base.process_exited(daemon) && error("private core exited");nothing)
        deadline(seconds=15.0)=Generic.monotonic()+seconds
        try
            Lifecycle.lifecycle!(bridge,Codec.Prepared)
            Lifecycle.has_pending(bridge;safe=false)
            @test (@allocated Lifecycle.has_pending(bridge;safe=false))==0
            snapshot!()=begin
                delay_snapshot[] && sleep(0.2)
                Lifecycle.snapshot(bridge,state,cursor[];phase=phase[],held=held[],restored=restored[])
            end
            connect!(_)=begin
                cursor[]=Codec.AcquisitionCursor(1,1,0,0)
                phase[]="held";held[]=true
                nothing
            end
            worker=@async begin
                try
                    while !stop[]
                        Lifecycle.dispatch!(bridge,state;safe=safe_mode[],period_ns=UInt64(2_000_000),
                            snapshot!,connect!,reset! = _ -> (Int32(-95),"unsupported"),
                            allow_shutdown=() -> !held[])
                        sleep(0.002)
                    end
                catch error
                    owner_failure[]=error
                end
            end
            client=Caller.connect(CallerCodec.CALIBRATION_PROFILE,socket,node,getpid(),instance,
                CallerCodec.Classic;deadline=deadline(),check)
            connected=Caller.connect_owner!(client;deadline=deadline(),check)
            @test connected.snapshot.held
            @test connected.snapshot.phase=="held"
            safe_mode[]=false
            deferred=@async Caller.request!(client,:reset;deadline=deadline(),check)
            wait_proof(() -> bridge.deferred,3,"deferred Reset";check)
            @test !Lifecycle.has_pending(bridge;safe=false)
            @test !istaskdone(deferred)
            safe_mode[]=true
            @test fetch(deferred).header.result==-95
            # Release already succeeded before the later Status completion expires.
            phase[]="released";held[]=false;restored[]=true
            delay_snapshot[]=true
            outcome=@async try
                Caller.request!(client,:status;deadline=deadline(0.1),check)
            catch error
                error
            end
            wait_proof(() -> istaskdone(outcome),3,"expired caller";check)
            @test fetch(outcome) isa Generic.UnknownOutcome
            wait_proof(() -> owner_failure[]!==nothing,3,"expired owner completion";check)
            @test owner_failure[] isa Lifecycle.TransportFailure
            @test phase[]=="released"
            @test !held[] && restored[]
            @test bridge.runtime.endpoint.lifecycle===Codec.Connected
        finally
            stop[]=true
            worker===nothing || wait(worker)
            client===nothing || close(client)
            close(bridge)
        end
    end
end
