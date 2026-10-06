pushfirst!(LOAD_PATH,"/home/dgamroth/workspaces/codex/pipewire/PipeWireAO.jl")
using PipeWireAO
popfirst!(LOAD_PATH)
using PipeWireAODeployment, Test, SHA
include("/home/dgamroth/workspaces/codex/pipewire/rtc-bootstrap-allocation-review/deployment/julia/test/native_control_private_core.jl")
for path in ("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls/deployment/julia/src/deploy.jl", "/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls/deployment/qualify_sustained.jl")
 println("SOURCE_SHA256 ",bytes2hex(sha256(read(path)))," ",path)
end
include("/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls/deployment/qualify_sustained.jl")
const D=PipeWireAODeployment.Deployment
const C=PipeWireAODeployment.NativeSupervisorCodec
const R=PipeWireAODeployment.NativeSupervisorRuntime
const N=PipeWireAODeployment.NativeSupervisorClient
const Q=PipeWireAODeployment.NativeRunnerCodec
const K=PipeWireAODeployment.NativeControlClient
function proof(remote,directory,daemon)
 chmod(dirname(remote),0o700)
 runtime=R.Runtime(C.PROFILE,remote,"review.retained.scope",Int64(91))
 running=Ref(true)
 owner=@async while running[]
  R.poll!(runtime)
  ticket=R.take!(runtime)
  if ticket!==nothing
   R.complete!(runtime,ticket,C.Preparing,C.Snapshot(C.OwnedProcess[],nothing,nothing,nothing))
  end
  sleep(0.002)
 end
 PipeWireAODeployment.Common.write_json(joinpath(directory,"control.json"),Dict("version"=>1,"profile"=>"pipewireao.rtc.deployment-supervisor/1","remote"=>remote,"node"=>"review.retained.scope","owner_pid"=>getpid(),"instance"=>91))
 retained=Ref{Any}(nothing)
 try
  @testset "actual native retained callback scope" begin
   returned=D.wait_state(directory,s->s["supervisor_phase"]=="preparing";timeout=20) do state,client
    retained[]=client
    @test !client.closed
    @test N.live_uuid(client)==runtime.uuid==state["deployment_uuid"]
    @test client.observation.owner_pid==getpid()
    @test N.request!(client,Q.RunnerCommand(:status);deadline=K.monotonic()+10).header.result==0
    :callback_value
   end
   @test returned===:callback_value
   @test retained[].closed
   expected=ErrorException("deliberate callback failure")
   caught=try
    D.wait_state(directory,s->true;timeout=20) do state,client
     retained[]=client
     @test !client.closed
     throw(expected)
    end
    nothing
   catch err
    err
   end
   @test caught===expected
   @test retained[].closed
   state=D.wait_state(directory,s->true;timeout=20)
   @test state["deployment_uuid"]==runtime.uuid
   @test state["supervisor_phase"]=="preparing"
  end
  record=Dict{String,Any}("success"=>false,"shutdown_confirmed"=>true,"cleanup"=>Dict("status"=>"complete"))
  try
   D.wait_state(directory,s->true;timeout=20) do state,client
    retained[]=client
    record["success"]=true
    client.active=true # Diagnostic injection: make actual close refuse active work.
   end
  catch err
   record["failure"]=sprint(showerror,err)
  finally
   retained[].active=false;close(retained[])
  end
  println("CLOSE_FAILURE_RECORD ",record)
  println("CURRENT_EXIT_CODE ",SustainedQualification.qualification_exit_code(record))
  @test haskey(record,"failure")
  @test SustainedQualification.qualification_exit_code(record)==1 # Same native close failure must now fail qualification.
 finally
  running[]=false;wait(owner);close(runtime)
 end
end
with_control_private_core(proof)
