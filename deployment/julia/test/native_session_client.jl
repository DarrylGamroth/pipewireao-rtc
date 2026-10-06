using Test, JSON3, PipeWireAODeployment
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
    deployment.spec["name"] = "Classic"
    running = Ref(true)
    owner = @async while running[]
        D.serve_control(deployment; snapshot_query=(deployment; deadline, check)->begin
            check()
            supervisor_fixture_snapshot(backend.state)
        end)
        sleep(0.002)
    end
    connections = SessionClient.Connection[]
    D.publish_discovery!(deployment,remote,"test.discover.supervisor")
    registry, record = something(deployment.discovery)
    function choose(item)
        SessionClient.select_session(item; deadline=NativeClient.monotonic()+10)
    end
    try
        listed = only(filter(entry -> entry.record !== nothing &&
            entry.record.session_id == runtime.uuid, Discovery.list_sessions(registry)))
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
        D.retire_discovery!(deployment)
        @test deployment.discovery === nothing
        @test !ispath(joinpath(registry,"session-$(record.session_id).pod"))
    finally
        running[] = false
        istaskdone(owner) || wait(owner)
        foreach(close, reverse(connections))
        close(runtime)
        D.retire_discovery!(deployment)
    end
end

@testset "actual native RTC session selection and retained binding" begin
    with_control_private_core(session_selection_proof)
end

function session_fixture_worker(deployment, backend, running)
    return @async while running[]
        D.serve_control(deployment;snapshot_query=(d;deadline,check)->begin
            check();supervisor_fixture_snapshot(backend.state)
        end)
        sleep(0.002)
    end
end

function duplicate_sessions_proof(first_remote, first_directory, first_daemon)
    chmod(dirname(first_remote),0o700)
    with_control_private_core() do second_remote, second_directory, second_daemon
        chmod(dirname(second_remote),0o700)
        mktempdir(prefix="rtc-session-catalogue-") do user_runtime
            chmod(user_runtime,0o700)
            withenv("XDG_RUNTIME_DIR"=>user_runtime) do
                deployments = []
                runtimes = PublicRuntime.Runtime[]
                connections = SessionClient.Connection[]
                workers = Task[]
                running = Ref(true)
                try
                    for (i,remote) in enumerate((first_remote,second_remote))
                        runtime = PublicRuntime.Runtime(C.PROFILE,remote,
                            "test.duplicate.supervisor",Int64(42+i))
                        push!(runtimes,runtime)
                        deployment,backend,plant = supervisor_fixture()
                        deployment.broker = runtime
                        deployment.spec["name"] = "Classic"
                        # One session is actively running; the other is stopped
                        # but its supervisor remains available for selection.
                        backend.state = i == 1 ? R.Running : R.Ready
                        plant.running = i == 1
                        PublicRuntime.lifecycle!(runtime,C.Admitted)
                        D.publish_discovery!(deployment,remote,"test.duplicate.supervisor")
                        push!(deployments,deployment)
                        push!(workers,session_fixture_worker(deployment,backend,running))
                    end
                    listing = D.list_sessions()
                    @test length(listing) == 2
                    @test all(entry -> entry.verification === Discovery.Unverified,listing)
                    @test all(entry -> entry.record.label == "Classic",listing)
                    @test length(unique(entry.record.session_id for entry in listing)) == 2
                    @test length(unique(entry.record.remote for entry in listing)) == 2
                    for (i,runtime) in enumerate(runtimes)
                        connection = D.select_session(runtime.uuid;deadline=NativeClient.monotonic()+10)
                        push!(connections,connection)
                        @test connection.selected.status.lifecycle === (i == 1 ? :ready : :stopped)
                        @test connection.selected.status.remote == (i == 1 ? first_remote : second_remote)
                    end
                    # Exercise the actual Julia operator CLI in a fresh process.
                    project = PipeWireAODeployment.package_root()
                    cli = joinpath(project,"deploy_cli.jl")
                    executable = Base.julia_cmd().exec[1]
                    listed = PipeWireAODeployment.Common.run_checked([
                        executable,"--startup-file=no","--project=$project",cli,"sessions"];
                        timeout=30,maximum_output_bytes=16_384)
                    @test listed.returncode == 0
                    rendered_listing = JSON3.read(listed.stdout)
                    @test length(rendered_listing) == 2
                    @test all(entry -> entry.verification == "Unverified",rendered_listing)
                    selected = PipeWireAODeployment.Common.run_checked([
                        executable,"--startup-file=no","--project=$project",cli,
                        "select-session","--session",runtimes[2].uuid];
                        timeout=40,maximum_output_bytes=16_384)
                    @test selected.returncode == 0
                    rendered_status = JSON3.read(selected.stdout)
                    @test rendered_status.session_id == runtimes[2].uuid
                    @test rendered_status.lifecycle == "stopped"
                    @test rendered_status.authority == "deployment_supervisor"
                    @test rendered_status.remote == second_remote
                    @test rendered_status.native_token > 0
                    gui_binary=get(ENV,"NATIVE_SESSION_GUI_TEST_BINARY","")
                    if !isempty(gui_binary)
                        isfile(gui_binary) || error("GUI qualification binary is absent")
                        gui = withenv("PIPEWIREAO_GUI_NATIVE_SESSION_UUID"=>runtimes[2].uuid) do
                            PipeWireAODeployment.Common.run_checked([gui_binary,"--ignored","--exact",
                                "rtc_adapter::live_tests::native_supervisor_session_selection_and_read_only_status",
                                "--nocapture"];timeout=40,maximum_output_bytes=32_768)
                        end
                        @test gui.returncode == 0
                        @test occursin("1 passed",gui.stdout)
                        println("ACTUAL_GUI_NATIVE_SESSION_PROOF=",gui.stdout)
                    end
                finally
                    running[] = false
                    foreach(wait,workers)
                    foreach(close,reverse(connections))
                    foreach(close,reverse(runtimes))
                    foreach(D.retire_discovery!,reverse(deployments))
                end
                @test isempty(D.list_sessions())
            end
        end
    end
end

@testset "independent duplicate-name sessions and actual read-only Julia CLI" begin
    with_control_private_core(duplicate_sessions_proof)
end
