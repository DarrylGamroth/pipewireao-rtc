module NativeSessionClientTests
using Test, PipeWireAODeployment
const S = PipeWireAODeployment.NativeSessionClient
const D = PipeWireAODeployment.NativeSessionDiscovery
const C = PipeWireAODeployment.NativeSupervisorCodec
const E = PipeWireAODeployment.NativeControlCodec
const R = PipeWireAODeployment.NativeRunnerCodec
const Deployment = PipeWireAODeployment.Deployment

const identity = E.ControllerIdentity(UInt32(7), UInt64(8), Int64(9))
const header = E.ReplyHeader(identity, Int64(10), Int64(11), UInt32(3), Int32(0))
const empty_snapshot = C.Snapshot(C.OwnedProcess[], nothing, nothing, nothing)
completion(phase; snapshot=empty_snapshot, result=Int32(0)) = C.Completion(
    E.ReplyHeader(identity, Int64(10), Int64(11), UInt32(3), result), phase,
    phase === C.Admitted, snapshot, nothing, nothing)

function runner_snapshot(state)
    details = (running=state === R.Running, owned_nodes=UInt64(2),
        owned_links=UInt64(2), discarded_buffers=UInt64(0),
        discarded_by_sink=Dict("sink"=>UInt64(0)))
    result = R.RunnerResult{:status,typeof(details)}(R.Observed, details)
    binding = C.Binding("runner", "pipewireao.rtc.runner/1", UInt32(101),
        UInt32(21), UInt64(22), Int64(10))
    runner = C.RunnerObservation(binding, Int64(1), "native-runner-instance:10",
        C.RunnerRecord(state, result))
    return C.Snapshot([C.OwnedProcess("rtc", UInt32(101))], runner, nothing, nothing)
end

@testset "fresh native discovery lifecycle" begin
    @test S.lifecycle(completion(C.Preparing)) === :preparing
    @test S.lifecycle(completion(C.Failed)) === :fault
    @test S.lifecycle(completion(C.Stopping)) === :stopped
    @test S.lifecycle(completion(C.Stopped)) === :stopped
    for (state, expected) in ((R.Ready,:stopped), (R.Offline,:stopped),
            (R.Running,:ready), (R.Fault,:fault), (R.Configuring,:preparing))
        @test S.lifecycle(completion(C.Admitted; snapshot=runner_snapshot(state))) === expected
    end
    @test_throws ArgumentError S.lifecycle(completion(C.Admitted))
    @test_throws ArgumentError S.lifecycle(completion(C.Admitted; result=Int32(-1)))
end

@testset "invalid listings never initiate native selection" begin
    malformed = D.DiscoveryEntry(nothing, D.Malformed, "broken record")
    @test S.select_session(malformed; deadline=0.0).verification === D.Malformed
    record = D.SessionRecord("Classic", "01234567-89ab-cdef-0123-456789abcdef",
        UInt32(getpid()), Int64(1), "/run/user/1000/absent", "rtc.supervisor")
    retired = D.DiscoveryEntry(record, D.Replaced, "explicit new selection required")
    @test S.select_session(retired; deadline=0.0) === retired
    unverified = D.DiscoveryEntry(record, D.Unverified, "hint")
    @test S.select_session(unverified; deadline=0.0).verification === D.Inaccessible
end

@testset "explicit deployment session command selection" begin
    uuid = "01234567-89ab-cdef-0123-456789abcdef"
    @test Deployment._options(["sessions"]).command == "sessions"
    @test Deployment._options(["select-session","--session",uuid]).session_id == uuid
    @test Deployment._options(["control","--session",uuid,"--","status"]).argv == ["status"]
    @test Deployment._options(["control","--runtime","/tmp/rtc","--","status"]).session_id === nothing
    @test_throws Deployment.DeploymentError Deployment._options(["control","--","status"])
    @test_throws Deployment.DeploymentError Deployment._options([
        "control","--session",uuid,"--runtime","/tmp/rtc","--","status"])
    @test_throws Deployment.DeploymentError Deployment._options(["select-session"])
    @test_throws ArgumentError Deployment._options(["select-session","--session","broken"])
    @test_throws Deployment.DeploymentError Deployment._options(["sessions","--runtime","/tmp/rtc"])
end
@testset "native locator has one immutable bounded hint copy" begin
    P=PipeWireAODeployment.NativeSupervisorClient
    Common=PipeWireAODeployment.Common
    mktempdir() do directory
        path=joinpath(directory,"control.json")
        hints=Dict("version"=>1,"profile"=>"pipewireao.rtc.deployment-supervisor/1",
            "remote"=>joinpath(directory,"private","pw"),"node"=>"supervisor",
            "owner_pid"=>getpid(),"instance"=>Int64(19))
        Common.write_json(path,hints)
        copied=P.read_locator(path)
        hints["owner_pid"]=getpid()+1;hints["remote"]=joinpath(directory,"replacement","pw")
        Common.write_json(path,hints;atomic=true)
        @test copied.owner_pid==getpid()
        @test copied.remote==joinpath(directory,"private","pw")
        @test copied.instance==19
        @test P.read_locator(path).remote==hints["remote"]
        for (field,value) in (("remote","relative"),("remote","bad\0path"),
                ("node",repeat("x",129)),("owner_pid",true),("instance",false))
            malformed=copy(hints);malformed[field]=value;Common.write_json(path,malformed)
            @test_throws ArgumentError P.read_locator(path)
        end
        alias=joinpath(directory,"alias");symlink(path,alias)
        @test_throws ArgumentError P.read_locator(alias)
    end
end
end # module NativeSessionClientTests
