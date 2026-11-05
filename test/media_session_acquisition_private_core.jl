# Optional native AcquisitionLifecycleRuntime selector with controlled owner
# handlers. This checks RTC/native behavior, not production science or HIL.
module MediaSessionAcquisitionPrivateCoreTests
using Test, PipeWireAO, PipeWireAORTC

const S = PipeWireAORTC.MediaSession
const Acquisition = PipeWireAORTC.AcquisitionLifecycleCodec
const Runtime = PipeWireAORTC.AcquisitionLifecycleRuntime
const Endpoint = PipeWireAORTC.ControlEndpoint
const Client = PipeWireAORTC.ControlClient
const PROFILE = Acquisition.CALIBRATION_PROFILE
const SOURCE_INSTANCE = Int64(17)
const OBSERVATION_TIMEOUT_SECONDS = 10.0
const POLL_SECONDS = 0.001
const EFFECT_BUDGET_NS = Int64(5_000_000_000)
const STATUS_OPERATION = Client.operation_id(PROFILE, Acquisition.LifecycleCommand(:status))
const SHUTDOWN_OPERATION =
    Client.operation_id(PROFILE, Acquisition.LifecycleCommand(:shutdown))
const INITIAL = Acquisition.Snapshot(
    Acquisition.Classic,
    nothing,
    nothing,
    false,
    false,
    "initial",
    false,
    false,
    nothing,
)

include("control_private_core.jl")

function respond!(runtime, ticket, ::Acquisition.LifecycleCommand{:status})
    Runtime.complete!(runtime, ticket, runtime.endpoint.lifecycle, INITIAL)
    return nothing
end
function respond!(runtime, ticket, ::Acquisition.LifecycleCommand{:shutdown})
    Runtime.lifecycle!(runtime, Acquisition.Stopped)
    Runtime.complete!(runtime, ticket, Acquisition.Stopped, INITIAL)
    return nothing
end
respond!(runtime, ticket, command) =
    error("unsupported initial owner operation $(typeof(command))")

function check_initial_quit(socket, directory, daemon, lifecycle)
    owner = nothing
    worker = nothing
    session = nothing
    quit = Ref(false)
    operations = UInt32[]
    try
        owner = Runtime.Runtime(PROFILE, socket, "cold-acquisition", SOURCE_INSTANCE)
        Runtime.lifecycle!(owner, lifecycle)
        worker = let runtime = owner
            @async while !quit[]
                if Runtime.has_pending(runtime)
                    Runtime.poll!(runtime)
                    ticket = Runtime.take!(runtime)
                    if ticket !== nothing
                        Endpoint.check_ticket(runtime.endpoint, ticket)
                        push!(operations, ticket.header.operation)
                        respond!(runtime, ticket, ticket.command)
                    end
                end
                sleep(POLL_SECONDS)
            end
        end
        policy = Dict{String,Any}(
            "instance" => "101",
            "controller.instance" => "102",
            "admission.controller-instance" => "103",
            "node.name" => "session-test",
            "controller.node.name" => "pipewireao.rtc.controller.session-test",
            "startup.timeout-ms" => 300000,
            "session.uuid" => "e10d4214-9c5f-4a61-b584-69b65b2193f6",
            "properties" => Dict{String,String}(),
            "core.owner" => Dict("pid" => getpid(daemon), "nodes" => String[]),
            "owners" => [],
            "node.pids" => Dict{String,Int}(),
            "source" => Dict(
                "role" => "acquisition",
                "control-node" => "cold-acquisition",
                "pid" => getpid(),
                "control-protocol" => "pipewireao.rtc.calibration-lifecycle/1",
                "control-instance" => string(SOURCE_INSTANCE),
                "instrument" => "classic",
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
        configuration = Dict(
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
        PipeWireAORTC.ScienceExport.write_spa_config(path, configuration)
        session = S.Session(path; clock = S.Clocks.SystemNanoClock())
        deadline = Client.monotonic() + OBSERVATION_TIMEOUT_SECONDS
        while isempty(session.sources)
            istaskfailed(worker) && fetch(worker)
            S.Agent.do_work(session)
            Client.monotonic() < deadline || error("acquisition capture timed out")
            sleep(POLL_SECONDS)
        end
        @test only(session.sources).previous === nothing
        @test session.machine.lifecycle == PipeWireAORTC.RunnerCodec.Configuring

        # The ten-second harness bound reports failures; the production machine
        # retains its five-second cleanup budget on a real, advancing clock.
        started = S.Clocks.time_nanos(session.source_clock)
        S.stage!(session.queue, S.ShutdownRequested())
        deadline = Client.monotonic() + OBSERVATION_TIMEOUT_SECONDS
        while !session.done
            istaskfailed(worker) && fetch(worker)
            S.Agent.do_work(session)
            Client.monotonic() < deadline || error(
                "initial acquisition Quit timed out: $(session.machine.failure); operations=$operations",
            )
            sleep(POLL_SECONDS)
        end
        elapsed = S.Clocks.time_nanos(session.source_clock) - started
        @test session.done
        @test elapsed <= EFFECT_BUDGET_NS
        @test STATUS_OPERATION in operations
        @test all(
            operation -> operation in (STATUS_OPERATION, SHUTDOWN_OPERATION),
            operations,
        )
        @test count(==(SHUTDOWN_OPERATION), operations) == 1
        @test session.exitcode == 0
        @test session.machine.lifecycle == PipeWireAORTC.RunnerCodec.Offline
        @test only(session.sources).owner.retired
        @test only(session.sources).previous === nothing
    finally
        try
            session === nothing || close(session)
        finally
            quit[] = true
            try
                worker === nothing || wait(worker)
            finally
                owner === nothing || close(owner)
            end
        end
    end
    return nothing
end

@testset "Native initial acquisition Hold and acknowledged cold Shutdown" begin
    @test S.SESSION_EFFECT_TIMEOUT_NS == EFFECT_BUDGET_NS
    with_control_private_core() do socket, directory, daemon
        chmod(dirname(socket), 0o700)
        # The first case must succeed without first exercising the live path.
        for (name, lifecycle) in (
            ("first Preparing", Acquisition.Preparing),
            ("repeated Preparing", Acquisition.Preparing),
            ("Prepared", Acquisition.Prepared),
        )
            @testset "$name" begin
                check_initial_quit(socket, directory, daemon, lifecycle)
            end
        end
    end
end
end
