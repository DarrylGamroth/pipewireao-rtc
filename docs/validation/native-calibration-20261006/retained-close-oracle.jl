using PipeWireAODeployment, PipeWireAO, Test
const RTC=get(ENV,"CALIBRATION_REVIEW_SOURCE","/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-calibration-consumer")
include(joinpath(RTC,"deployment/qualify_calibration_native.jl"))
include(joinpath(RTC,"deployment/julia/test/native_control_private_core.jl"))
const CQ=NativeCalibrationQualification
const D=PipeWireAODeployment.Deployment
const C=PipeWireAODeployment.NativeSupervisorCodec
const R=PipeWireAODeployment.NativeSupervisorRuntime
const N=PipeWireAODeployment.NativeSupervisorClient
const Q=PipeWireAODeployment.NativeRunnerCodec
const K=PipeWireAODeployment.NativeControlClient
function proof(remote,directory,daemon)
    chmod(dirname(remote),0o700)
    runtime=R.Runtime(C.PROFILE,remote,"review.calibration.retained.close",Int64(91))
    running=Ref(true)
    owner=@async while running[]
        R.poll!(runtime)
        ticket=R.take!(runtime)
        ticket===nothing || R.complete!(runtime,ticket,C.Preparing,
            C.Snapshot(C.OwnedProcess[],nothing,nothing,nothing))
        sleep(0.002)
    end
    PipeWireAODeployment.Common.write_json(joinpath(directory,"control.json"),
        Dict("version"=>1,"profile"=>"pipewireao.rtc.deployment-supervisor/1","remote"=>remote,
            "node"=>"review.calibration.retained.close","owner_pid"=>getpid(),"instance"=>91))
    retained=Ref{Any}(nothing)
    record=Dict{String,Any}("success"=>false,"restoration_confirmed"=>true,
        "release_confirmed"=>true,"shutdown_confirmed"=>true,
        "cleanup"=>Dict("status"=>"complete","launcher_exited"=>true,
            "groups"=>Dict("simulator"=>Dict("status"=>"complete"))))
    try
        @testset "calibration postcallback native close failure" begin
            try
                D.wait_state(directory,s->true;timeout=20) do state,client
                    retained[]=client
                    @test !client.closed && N.live_uuid(client)==runtime.uuid
                    record["success"]=true
                    client.active=true # Diagnostic only: actual close must refuse pending work.
                end
            catch error
                record["failure"]=sprint(showerror,error)
            finally
                retained[].active=false
                close(retained[])
            end
            code=isdefined(CQ,:qualification_exit_code) ? CQ.qualification_exit_code(record) :
                (record["success"] ? 0 : 1) # Exact 987297b return expression.
            println("SOURCE_REVISION=",readchomp(Cmd(["git","-C",RTC,"rev-parse","HEAD"])))
            println("SDK_SOURCE=",pathof(PipeWireAO))
            println("CLOSE_FAILURE_RECORD=",record)
            println("QUALIFICATION_EXIT_CODE=",code)
            @test haskey(record,"failure")
            @test code==1
        end
    finally
        running[]=false;wait(owner);close(runtime)
    end
end
with_control_private_core(proof)
