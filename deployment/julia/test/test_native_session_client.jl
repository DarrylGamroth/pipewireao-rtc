module NativeSessionClientTests
using Test, PipeWireAODeployment
const S = PipeWireAODeployment.NativeSessionClient
const D = PipeWireAODeployment.NativeSessionDiscovery
const E = PipeWireAODeployment.NativeControlCodec
const R = PipeWireAODeployment.NativeRunnerCodec
const C = PipeWireAODeployment.NativeSessionCodec
const identity = E.ControllerIdentity(UInt32(7), UInt64(8), Int64(9))

function completion(state; result=Int32(0), operation=UInt32(3))
    details = (running=state === R.Running, owned_nodes=UInt64(0),
        owned_links=UInt64(3), discarded_buffers=UInt64(0),
        discarded_by_sink=Dict{String,UInt64}())
    status = R.RunnerResult{:status,typeof(details)}(R.Observed, details)
    return C.Completion(E.ReplyHeader(identity, Int64(10), Int64(11), operation, result),
        state, status, nothing)
end

@testset "fresh direct session lifecycle" begin
    for (state, expected) in ((R.Offline,:offline), (R.Configuring,:configuring),
            (R.Ready,:ready), (R.Running,:running), (R.Fault,:fault))
        @test S.lifecycle(completion(state)) === expected
    end
    @test_throws ArgumentError S.lifecycle(completion(R.Ready; result=Int32(-1)))
    @test_throws ArgumentError S.lifecycle(completion(R.Ready; operation=UInt32(2)))
end

@testset "invalid listings never initiate native selection" begin
    malformed = D.DiscoveryEntry(nothing, D.Malformed, "broken record")
    @test S.select_session(malformed; deadline=0.0).verification === D.Malformed
    record = D.SessionRecord("Classic", "01234567-89ab-cdef-0123-456789abcdef",
        UInt32(getpid()), Int64(1), "/run/user/1000/absent", "rtc.session")
    retired = D.DiscoveryEntry(record, D.Replaced, "explicit new selection required")
    @test S.select_session(retired; deadline=0.0) === retired
    unverified = D.DiscoveryEntry(record, D.Unverified, "hint")
    @test S.select_session(unverified; deadline=0.0).verification === D.Inaccessible
    @test S.select_direct_session(unverified; deadline=0.0).verification === D.Inaccessible
end

@testset "operator discovery never creates its registry" begin
    mktempdir() do directory
        chmod(directory,0o700)
        withenv("XDG_RUNTIME_DIR"=>directory) do
            @test D.existing_registry_directory() === nothing
            @test isempty(readdir(directory))
            app=joinpath(directory,"pipewireao-rtc");mkdir(app;mode=0o700)
            @test D.existing_registry_directory() === nothing
            registry=D.registry_directory()
            before=sort(readdir(registry))
            @test isempty(D.list_sessions(registry))
            @test readdir(registry)==before
            @test !ispath(joinpath(registry,".lock"))
            chmod(registry,0o755)
            @test_throws ArgumentError D.existing_registry_directory()
            chmod(registry,0o700)
        end
    end
end
end
