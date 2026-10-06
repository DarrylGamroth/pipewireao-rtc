using Test, PipeWireAODeployment
include("test_native_supervisor_coordination.jl")
include("native_control_private_core.jl")
const SessionClient = PipeWireAODeployment.NativeSessionClient
const Discovery = PipeWireAODeployment.NativeSessionDiscovery
const PublicRuntime = PipeWireAODeployment.NativeSupervisorRuntime
const NativeClient = PipeWireAODeployment.NativeControlClient

function session_selection_proof(remote, directory, daemon)
    chmod(dirname(remote), 0o700)
    runtime = PublicRuntime.Runtime(C.PROFILE, remote, "test.discover.supervisor", Int64(42))
    deployment, backend, plant = supervisor_fixture()
    deployment.broker = runtime
    running = Ref(true)
    owner = @async while running[]
        D.serve_control(deployment; snapshot_query=(deployment; deadline, check)->begin
            check()
            supervisor_fixture_snapshot(backend.state)
        end)
        sleep(0.002)
    end
    connections = SessionClient.Connection[]
    registry = Discovery.registry_directory(directory)
    record = Discovery.SessionRecord("Classic", runtime.uuid, UInt32(getpid()),
        Int64(42), remote, "test.discover.supervisor")
    function choose(item)
        SessionClient.select_session(item; deadline=NativeClient.monotonic()+10)
    end
    try
        Discovery.publish!(registry, record)
        listed = only(Discovery.list_sessions(registry))
        @test listed.verification === Discovery.Unverified
        @test isempty(backend.calls) && isempty(plant.calls)
        preparing = choose(listed)
        @test preparing isa SessionClient.Connection
        push!(connections, preparing)
        @test preparing.selected.status.lifecycle === :preparing
        @test preparing.selected.status.session_id == runtime.uuid
        @test preparing.selected.status.global_id == preparing.client.global_id
        @test preparing.selected.status.object_serial == preparing.client.serial
        @test preparing.selected.status.query_token > 0
        @test isempty(backend.calls) && isempty(plant.calls)

        PublicRuntime.lifecycle!(runtime, C.Admitted)
        admitted = choose(listed)
        @test admitted isa SessionClient.Connection
        push!(connections, admitted)
        @test admitted.selected.status.lifecycle === :ready
        @test admitted.selected.status.global_id == preparing.selected.status.global_id
        @test admitted.client.identity != preparing.client.identity
        # Subsequent explicit controls keep the original, exact verified client.
        stopped = SessionClient.request!(admitted, R.RunnerCommand(:session_stop);
            deadline=NativeClient.monotonic()+10)
        @test stopped.header.result == 0 && backend.state === R.Ready
        paused = choose(listed)
        @test paused isa SessionClient.Connection
        push!(connections, paused)
        @test paused.selected.status.lifecycle === :stopped
        @test paused.selected.status.session_id == runtime.uuid

        previous = (length(backend.calls), length(plant.calls))
        wrong_uuid = Discovery.SessionRecord("Classic", "11234567-89ab-cdef-0123-456789abcdef",
            record.owner_pid, record.incarnation, record.remote, record.node_name)
        replaced = choose(Discovery.DiscoveryEntry(wrong_uuid, Discovery.Unverified, "hint"))
        @test replaced.verification === Discovery.Replaced
        @test (length(backend.calls), length(plant.calls)) == previous
        @test Discovery.decode_record(read(joinpath(registry,"session-$(record.session_id).pod"))) == record

        close(runtime)
        inaccessible = choose(listed)
        @test inaccessible.verification === Discovery.Inaccessible
        @test_throws NativeClient.UnknownOutcome SessionClient.request!(admitted,
            R.RunnerCommand(:session_start); deadline=NativeClient.monotonic()+5)
        @test (length(backend.calls), length(plant.calls)) == previous
        @test Discovery.remove!(registry, record)
        @test isempty(Discovery.list_sessions(registry))
    finally
        running[] = false
        istaskdone(owner) || wait(owner)
        foreach(close, reverse(connections))
        close(runtime)
        Discovery.remove!(registry, record)
    end
end

@testset "actual native RTC session selection and retained binding" begin
    with_control_private_core(session_selection_proof)
end
