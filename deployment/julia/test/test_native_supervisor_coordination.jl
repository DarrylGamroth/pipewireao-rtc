using Test, PipeWireAODeployment
const D=PipeWireAODeployment.Deployment
const R=PipeWireAODeployment.NativeRunnerCodec
const C=PipeWireAODeployment.NativeSupervisorCodec
const E=PipeWireAODeployment.NativeControlCodec

mutable struct SupervisorRunnerFixture
    calls::Vector{Tuple{Symbol,Float64}}
    state::R.Lifecycle
end
mutable struct SupervisorSourceFixture
    calls::Vector{Tuple{Symbol,Float64}}
    running::Bool
    generation::Int64
    reject_resume::Bool
end
SupervisorSourceFixture(calls,running,generation)=SupervisorSourceFixture(calls,running,generation,false)
function PipeWireAODeployment.NativeRunnerClient.request!(client::SupervisorRunnerFixture,command::R.RunnerCommand{O};deadline::Float64,check=()->nothing) where O
    check();push!(client.calls,(O,deadline))
    if O in (:session_start,:session_stop,:reset,:source_ended)
        client.state=O===:session_start ? R.Running : R.Ready
        details=(state=client.state,);outcome=R.Completed
    elseif O===:quit
        details=(shutdown=true,);outcome=R.Accepted
    elseif O===:properties_set
        details=(graph=command.args[1],generations=[(node="node",requested=Int64(1),active=Int64(1))],active_adoption_observed=true)
        outcome=R.Active
    else
        error("unexpected fixture operation")
    end
    result=R.RunnerResult{O,typeof(details)}(outcome,details)
    header=E.ReplyHeader(E.ControllerIdentity(UInt32(7),UInt64(8),Int64(9)),Int64(10),Int64(length(client.calls)),R.operation_id(command),Int32(0))
    return R.Completion(header,client.state,result,nothing)
end
function PipeWireAODeployment.NativeSourceClient.request!(client::SupervisorSourceFixture,operation::String,token::Int64;deadline::Float64,check=()->nothing)
    check();push!(client.calls,(Symbol(operation),deadline))
    if operation=="resume"&&client.reject_resume
        return Dict{String,Any}("version"=>1,"id"=>token,"operation"=>operation,"ok"=>false,
            "error"=>"fixture source resume rejected","state"=>client.running ? "running" : "paused","sequence"=>0,"completed"=>false)
    end
    client.running=operation=="resume" ? true : operation=="pause"||operation=="reset" ? false : client.running
    operation=="reset"&&(client.generation+=1)
    return Dict{String,Any}("version"=>1,"id"=>token,"operation"=>operation,"ok"=>true,"error"=>nothing,
        "state"=>client.running ? "running" : "paused","sequence"=>0,"completed"=>false)
end
function supervisor_fixture(;source=true)
    backend=SupervisorRunnerFixture(Tuple{Symbol,Float64}[],R.Running)
    plant=SupervisorSourceFixture(Tuple{Symbol,Float64}[],true,1)
    owner=source ? Dict{String,Any}("role"=>"source","control-protocol"=>"pipewireao.source-control/1","control-node"=>"source") : nothing
    record=Dict{String,Any}("phase"=>"running","admitted"=>true,"error"=>nothing)
    deployment=D.DeploymentRunner((;),"",Dict{String,Any}("owners"=>Any[]),Dict{String,String}(),Set{Int}(),
        Tuple{String,Base.Process}[],IdDict{Base.Process,Int}(),nothing,nothing,backend,nothing,nothing,nothing,
        owner,plant,0,"running",false,false,false,nothing,record,nothing,nothing,nothing)
    return deployment,backend,plant
end
function supervisor_fixture_snapshot(state=R.Running;source=true,sink="sink")
    details=(running=state===R.Running,owned_nodes=UInt64(2),owned_links=UInt64(2),discarded_buffers=UInt64(0),discarded_by_sink=Dict(sink=>UInt64(0)))
    status=R.RunnerResult{:status,typeof(details)}(R.Observed,details)
    runner=C.RunnerObservation(C.Binding("runner","pipewireao.rtc.runner/1",UInt32(101),UInt32(21),UInt64(22),Int64(10)),Int64(1),"native-runner-instance:10",C.RunnerRecord(state,status))
    plant=source ? C.SourceObservation(C.Binding("source","pipewireao.source-control/1",UInt32(102),UInt32(23),UInt64(24),Int64(1)),Int64(1),nothing,
        C.SimulatorSnapshot(Int32(1),Int64(1),Int32(3),Int64(1),Int32(0),Int64(1),Int64(0),state===R.Running,false,Int64(1),Int64(0))) : nothing
    return C.Snapshot([C.OwnedProcess("rtc",UInt32(101)),C.OwnedProcess("source",UInt32(102))],runner,plant,nothing)
end
@testset "typed supervisor carries one absolute deadline through coordination" begin
    deployment,backend,plant=supervisor_fixture()
    deadline=D.monotonic()+60.0
    stopped=D.coordinate(deployment,R.RunnerCommand(:session_stop),supervisor_fixture_snapshot();deadline,check=()->nothing)
    @test stopped.lifecycle===R.Ready
    @test plant.calls==[(:pause,deadline)]
    @test backend.calls==[(:session_stop,deadline)]
    D.coordinate(deployment,R.RunnerCommand(:reset),supervisor_fixture_snapshot(R.Ready);deadline,check=()->nothing)
    D.coordinate(deployment,R.RunnerCommand(:session_start),supervisor_fixture_snapshot(R.Ready);deadline,check=()->nothing)
    @test plant.calls==[(:pause,deadline),(:reset,deadline),(:resume,deadline)]
    @test all(call->call[2]===deadline,backend.calls)
    @test plant.generation==2&&plant.running
    @test !deployment.source_failed
    # A capacity rejection precedes both source pause and runner mutation.
    before=supervisor_fixture_snapshot(;sink=repeat("s",64_500))
    source_count=length(plant.calls);runner_count=length(backend.calls)
    @test_throws ArgumentError C.preflight_mutation_reply(R.RunnerCommand(:session_stop),before;snapshot_bound=D.future_snapshot_bound(before))
    @test length(plant.calls)==source_count&&length(backend.calls)==runner_count
end
@testset "unavailable optional observation preserves required admission placement" begin
    deployment,_,_=supervisor_fixture(;source=false)
    science=Dict("cpus"=>[2],"policy"=>"fifo","priority"=>83,"count"=>4,"name"=>"science")
    observer=Dict("cpus"=>[14],"policy"=>"fifo","priority"=>83,"count"=>1,"name"=>"observer-loop")
    other=Dict("cpus"=>[14],"policy"=>"fifo","priority"=>83,"count"=>2,"name"=>"observer-loop")
    contract=Dict{String,Any}("cpus"=>[2,14],"leader-cpu"=>2,"rt-priority"=>83,"locked-bytes"=>4096,"threads"=>[science,observer,other])
    deployment.spec["placement"]=Dict("core"=>contract,"rtc"=>deepcopy(contract))
    original=deepcopy(deployment.spec)
    @test D.admission_placement(deployment,"core")===contract
    deployment.spec["detector-observation"]=true
    chosen=D.admission_placement(deployment,"core")
    @test chosen["threads"]==[science,other]
    @test all(chosen[key]==contract[key] for key in ("cpus","leader-cpu","rt-priority","locked-bytes"))
    @test deployment.spec["placement"]==original["placement"]
    @test D.admission_placement(deployment,"rtc")===deployment.spec["placement"]["rtc"]
    deployment.observation_boundary=:available
    @test D.admission_placement(deployment,"core")===contract
end
