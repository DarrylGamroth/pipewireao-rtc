# Optional source-cohort selector; see docs/SESSION_POLICY_MIGRATION.md.
module MediaSessionProcessTests
using PipeWireAORTC, PipeWireAO, Test
const C = PipeWireAORTC.ControlClient
const R = PipeWireAORTC.RunnerCodec
const D = PipeWireAORTC.DeploymentConfiguration
const Common = PipeWireAORTC.Common
include("control_private_core.jl")
@testset "Public session process, saved binding and startup $termination" for termination in (:quit, :interrupt, :publisher_exit)
    with_control_private_core() do socket, directory, daemon
        chmod(dirname(socket), 0o700)
        uuid = "e10d4214-9c5f-4a61-b584-69b65b2193f6"
        policy = Dict{String,Any}(
            "instance" => "101",
            "controller.instance" => "102",
            "admission.controller-instance" => "103",
            "node.name" => "pipewireao.rtc.session.process-test",
            "controller.node.name" => "pipewireao.rtc.controller.process-test",
            "startup.timeout-ms" => 300000,
            "session.uuid" => uuid,
            "properties" => Dict("pipewireao.rtc.session.session-uuid" => uuid),
            "core.owner" => Dict("pid" => getpid(daemon), "nodes" => String[]),
            "owners" => [],
            "node.pids" => Dict{String,Int}(),
            "source" => Dict(
                "role" => "missing-source",
                "control-node" => "not-published",
                "pid" => getpid(),
            ),
            "session" => Dict(
                "sources" => [],
                "graphs" => [],
                "sinks" => [],
                "links" => [
                    Dict(
                        "output" => "not-published:output",
                        "input" => "not-published-sink:input",
                    ),
                ],
            ),
        )
        config = Dict(
            "context.properties" => Dict(
                "remote.name" => socket,
                "library.use-fallback" => false,
                "support.dbus" => false,
            ),
            "context.modules" => [
                Dict("name" => "libpipewire-module-protocol-native"),
                Dict("name" => "libpipewire-module-client-node"),
            ],
            "pipewireao.session" => policy,
        )
        path = joinpath(directory, "session.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path, config)
        julia = realpath(Base.julia_cmd().exec[1])
        project = realpath(dirname(Base.active_project()))
        argv = PipeWireAORTC.ScienceExport.rtc_arguments(julia, project, path)
        binding = Common.parse_json(
            Common.metadata_json(
                Dict(
                    "julia" => julia, "project" => project, "config" => path, "argv" => argv
                ),
            ),
        )
        log = open(joinpath(directory, "session.log"), "w+")
        rtc = PipeWireAORTC.ScienceExport.stage_rtc!(directory)
        command = addenv(
            Cmd([joinpath(rtc, "bin/pipewireao-rtc"), "-c", path]),
            "PIPEWIREAORTC_JULIA" => julia,
            "PIPEWIREAORTC_PROJECT" => project,
        )
        child = run(pipeline(command; stdout = log, stderr = log); wait = false)
        client = nothing
        try
            client = C.connect(
                PipeWireAORTC.SessionProfile.Profile(),
                socket,
                policy["node.name"],
                getpid(child),
                101;
                deadline = C.monotonic() + 120,
                controller_instance = 103,
                check = () -> (
                    process_exited(child) &&
                    error("session process exited during discovery")
                ),
            )
            @test D.verify_session_process(getpid(child), binding) === nothing
            altered = deepcopy(binding)
            altered["project"] = dirname(project)
            @test_throws D.DeploymentError D.verify_session_process(getpid(child), altered)
            warm = C.request!(
                client,
                PipeWireAORTC.SessionCodec.WarmupCommand();
                deadline = C.monotonic() + 60,
            )
            @test warm.lifecycle == R.Configuring && !warm.warmed
            status = C.request!(
                client, R.RunnerCommand(:status); deadline = C.monotonic() + 60
            )
            @test status.lifecycle == R.Configuring && !status.result.details.running
            groups = C.request!(
                client, R.RunnerCommand(:groups); deadline = C.monotonic() + 60
            )
            @test isempty(groups.result.details.groups)
            if termination === :quit
                quit = C.request!(client, R.RunnerCommand(:quit); deadline = C.monotonic() + 60)
                @test quit.lifecycle == R.Offline && quit.result.details.shutdown
            elseif termination === :interrupt
                kill(child, Base.SIGINT)
            else
                close(client)
                client = nothing
            end
            timedwait(() -> process_exited(child), 60; pollint = 0.01) == :ok ||
                error("session did not exit after $termination")
            wait(child)
            @test success(child)
        catch
            flush(log)
            seekstart(log)
            print(stderr, read(log, String))
            rethrow()
        finally
            client === nothing || close(client)
            stop_proof_child!(child, "test-owned Julia session")
            close(log)
        end
    end
end

end
