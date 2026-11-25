# Read the native Core on a private socket before starting any RTC-owned graph.
using Test, Clocks, Sockets, PipeWireAORTC, PipeWireAO

include(joinpath(@__DIR__, "..", "control_private_core.jl"))

@testset "independent core socket belongs to the declared service" begin
    prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
    with_control_private_core(; prefix) do socket, _, daemon
        launch = PipeWireAORTC.SessionLaunch
        @test launch.verify_external_core(prefix, socket, getpid(daemon), Dict(ENV)) === nothing
        @test_throws launch.LaunchError launch.verify_external_core(prefix, socket, getpid(), Dict(ENV))
    end
end

const RTC = PipeWireAORTC.MediaSession
const Launch = PipeWireAORTC.SessionLaunch
const CLI = PipeWireAORTC.SessionCLI
const ENDPOINT_NAMES = Set(("pipewireao.rtc.session.identity-test", "pipewireao.rtc.controller.identity-test"))

function attachment_fixture(socket, directory, pid, prefix)
    source = Dict("role" => "simulator", "pid" => getpid(), "control-protocol" => "external-stream")
    configuration = Dict(
        "context.properties" => Dict("remote.name" => socket, "support.dbus" => false),
        "context.modules" => [
            Dict("name" => "libpipewire-module-protocol-native"),
            Dict("name" => "libpipewire-module-client-node"),
        ],
        "pipewireao.session" => Dict{String,Any}(
            "instance" => "101",
            "controller.instance" => "102",
            "admission.controller-instance" => "103",
            "node.name" => "pipewireao.rtc.session.identity-test",
            "controller.node.name" => "pipewireao.rtc.controller.identity-test",
            "session.uuid" => "e10d4214-9c5f-4a61-b584-69b65b2193f6",
            "startup.timeout-ms" => 300000,
            "properties" => Dict{String,String}(),
            "core.owner" => Dict("pid" => pid, "nodes" => String[]),
            "owners" => [source],
            "source" => source,
            "node.pids" => Dict("simulator" => getpid()),
            "session" => Dict(
                "sources" => [Dict("node.name" => "simulator", "ownership" => "external",
                    "ports" => [Dict("name" => "output", "direction" => "output")])],
                "links" => [Dict("output" => "simulator:output", "input" => "graph:input")],
            ),
        ),
    )
    path = joinpath(directory, "identity-rtc.conf")
    PipeWireAORTC.ScienceExport.write_spa_config(path, configuration)
    request = Launch.Request(directory, prefix, "rtc-identity-test.service", path, directory)
    invocation = repeat("1", 32)
    record = Dict{String,Any}("version" => Launch.LEDGER_VERSION, "direct_attach" => true,
        "owners" => Dict("core" => Dict("pid" => pid)))
    deployment = CLI.InstalledAdmission(request, invocation, path, record,
        (Int(getpid()), UInt64(1), "/fixture"), nothing, nothing, nothing)
    return path, (; config = configuration, deployment)
end

@testset "Direct attachment verifies its own connection before exposing either endpoint" begin
    prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
    with_control_private_core(; prefix) do _, _, declared_daemon
        with_control_private_core(; prefix) do socket, directory, daemon
            clock = Clocks.SystemNanoClock()
            deadline() = Clocks.time_nanos(clock) + 10_000_000_000
            loop = MainLoop()
            context = Context(loop)
            sequence = Ref(Cint(0))
            core = CoreConnection(context; properties = Dict("remote.name" => socket),
                on_done = (_, id, serial) -> id == 0 && (sequence[] = serial))
            registry = Registry(core)
            published = String[]
            listener = add_listener!(registry; on_global_added = (_, object) -> begin
                name = get(object.properties, "node.name", "")
                object.type == "PipeWire:Interface:Node" && name in ENDPOINT_NAMES &&
                    push!(published, name)
                return nothing
            end)
            function synchronize_observer()
                serial = PipeWireAO.sync!(core)
                wait_proof(5, "core identity observer barrier") do
                    PipeWireAO.iterate!(loop)
                    sequence[] == serial
                end
                return nothing
            end
            function await_endpoints(session)
                wait_proof(5, "verified RTC endpoints") do
                    RTC.Agent.do_work(session)
                    PipeWireAO.iterate!(loop)
                    Set(published) == ENDPOINT_NAMES && session.controller !== nothing
                end
            end
            try
                synchronize_observer()
                path, snapshot = attachment_fixture(socket, directory, getpid(declared_daemon), prefix)
                attachment = (; snapshot..., deadline = deadline())
                @test_throws ArgumentError("declared core process differs from remote core") begin
                    session = RTC.Session(path; attachment, clock)
                    try
                        await_endpoints(session)
                    finally
                        close(session)
                    end
                end
                synchronize_observer()
                @test isempty(published)

                silent_socket = joinpath(directory, "no-core-info.sock")
                server = Sockets.listen(silent_socket)
                try
                    path, snapshot = attachment_fixture(silent_socket, directory, getpid(daemon), prefix)
                    attachment = (; snapshot..., deadline = Clocks.time_nanos(clock) + 150_000_000)
                    @test_throws ArgumentError("timed out verifying the declared PipeWire core") RTC.Session(path; attachment, clock)
                finally
                    close(server)
                end

                # This connection receives Done but deliberately has no CoreInfo observer.
                queue = RTC.EventQueue()
                stage_listener = add_listener!(core; on_done =
                    (_, id, serial) -> RTC.stage!(queue, RTC.CoreDone(id, serial)))
                try
                    @test_throws ArgumentError("remote CoreInfo is unavailable") RTC.verify_attachment_core!(
                        loop, core, queue, getpid(daemon); deadline = deadline(), clock,
                    )
                finally
                    close(stage_listener)
                end

                path, snapshot = attachment_fixture(socket, directory, getpid(daemon), prefix)
                attachment = (; snapshot..., deadline = deadline())
                session = RTC.Session(path; attachment, clock)
                try
                    await_endpoints(session)
                    @test RTC._core_identity(session).pid == getpid(daemon)
                    @test session.client_id > 0
                    @test session.controller.global_id == node_id(session.controller_endpoint)
                finally
                    close(session)
                end
                @test !isopen(session.core)
                wait_proof(5, "RTC endpoint withdrawal") do
                    PipeWireAO.iterate!(loop)
                    all(ENDPOINT_NAMES) do name
                        isempty(PipeWireAO.find_globals(registry; interface = "PipeWire:Interface:Node",
                            properties = ("node.name" => name,)))
                    end
                end
            finally
                foreach(close, (listener, registry, core, context, loop))
            end
        end
    end
end
