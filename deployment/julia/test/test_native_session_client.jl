module NativeSessionClientTests
using Test, PipeWireAODeployment
const S = PipeWireAODeployment.NativeSessionClient
const D = PipeWireAODeployment.NativeSessionDiscovery
const C = PipeWireAODeployment.NativeSupervisorCodec
const E = PipeWireAODeployment.NativeControlCodec
const R = PipeWireAODeployment.NativeRunnerCodec

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
end # module NativeSessionClientTests
