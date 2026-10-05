using Test
using PipeWireAO

module SourceClientFixture
include(joinpath(@__DIR__, "..", "..", "hil", "source_control.jl"))
include(joinpath(@__DIR__, "..", "src", "source_client.jl"))
end

const SourceNative = SourceClientFixture.NativeSourceClient
const SourceControl = SourceClientFixture.HILSourceControl

function source_snapshot(instance::Int64=Int64(17); kind=SourceControl.INITIAL,
        token=Int64(0), result=Int32(0), generation=Int64(1), sequence=Int64(0),
        running=false, completed=false, report_generation=generation, report_sequence=sequence)
    return SourceControl.snapshot_values(instance, kind, token, result, generation,
        sequence, running, completed, report_generation, report_sequence)
end

source_pod(values; rejection=false) = PipeWireAO.props!(PropsBuffer(
    rejection ? SourceControl.REJECTION_NAMES : SourceControl.SNAPSHOT_NAMES, values), values)

function source_initial_observation()
    observation = SourceNative.Observation(Int64(17))
    SourceNative.observe!(observation, run_control_status(0, 0, :stopped))
    SourceNative.observe!(observation, reset_control_status(0, 0))
    SourceNative.observe!(observation, source_pod(source_snapshot()))
    return observation
end

@testset "native source observation and correlation" begin
    observation = SourceNative.Observation(Int64(17))
    @test !SourceNative.initial_ready(observation)
    observation = source_initial_observation()
    @test SourceNative.initial_ready(observation)
    initial = observation.snapshot
    @test SourceNative.matching_reply(observation, "status", Int64(1), initial) === nothing
    values = source_snapshot(; kind=SourceControl.QUERY, token=Int64(1))
    SourceNative.observe!(observation, source_pod(values))
    status = SourceNative.matching_reply(observation, "status", Int64(1), initial)
    @test status["id"] == 1
    @test status["operation"] == "status"
    @test status["state"] == "paused"
    @test status["instance"] == 17
    @test status["report-ready"]
    SourceNative.observe!(observation, source_pod(initial))
    @test observation.snapshot == values
    @test observation.failure === nothing

    resume = source_snapshot(; kind=SourceControl.RUN, token=Int64(2), running=true)
    SourceNative.observe!(observation, source_pod(resume))
    @test SourceNative.matching_reply(observation, "resume", Int64(2), values) === nothing
    SourceNative.observe!(observation, run_control_status(2, 0, :running))
    @test SourceNative.matching_reply(observation, "resume", Int64(2), values)["ok"]
    # A rejection is independent and does not erase a committed duplicate ACK.
    rejected = source_snapshot(; kind=SourceControl.RUN, token=Int64(2),
        result=Int32(-Base.Libc.ESTALE), running=true)
    SourceNative.observe!(observation, source_pod(rejected; rejection=true))
    @test observation.snapshot == resume
    @test SourceNative.matching_reply(observation, "resume", Int64(2), values)["ok"]
    busy = source_snapshot(; kind=SourceControl.RESET, token=Int64(3),
        result=Int32(-Base.Libc.EBUSY), running=true)
    SourceNative.observe!(observation, source_pod(busy; rejection=true))
    reply = SourceNative.matching_reply(observation, "reset", Int64(3), resume)
    @test !reply["ok"]
    @test reply["state"] == "running"
    @test observation.snapshot == resume

    reset = source_snapshot(; kind=SourceControl.RESET, token=Int64(4), generation=Int64(2))
    SourceNative.observe!(observation, reset_control_status(4, 0))
    SourceNative.observe!(observation, source_pod(reset))
    @test SourceNative.matching_reply(observation, "reset", Int64(4), resume)["generation"] == 2
    @test_throws Exception SourceNative.matching_reply(observation, "status", Int64(3), resume)

    wrong_native = source_initial_observation()
    SourceNative.observe!(wrong_native, run_control_status(1, 0, :stopped))
    SourceNative.observe!(wrong_native, source_pod(source_snapshot(; kind=SourceControl.RUN, token=Int64(1), running=true)))
    @test_throws Exception SourceNative.matching_reply(wrong_native, "resume", Int64(1), initial)
    no_report = source_initial_observation()
    SourceNative.observe!(no_report, run_control_status(1, 0, :stopped))
    SourceNative.observe!(no_report, source_pod(source_snapshot(; kind=SourceControl.RUN,
        token=Int64(1), sequence=Int64(10), report_sequence=Int64(0))))
    @test !SourceNative.matching_reply(no_report, "pause", Int64(1), initial)["report-ready"]
    finite_without_report = source_initial_observation()
    SourceNative.observe!(finite_without_report, run_control_status(1, 0, :stopped))
    SourceNative.observe!(finite_without_report, source_pod(source_snapshot(; kind=SourceControl.RUN,
        token=Int64(1), sequence=Int64(10), completed=true, report_sequence=Int64(0))))
    @test_throws Exception SourceNative.matching_reply(finite_without_report, "pause", Int64(1), initial)
    backwards = source_initial_observation()
    SourceNative.observe!(backwards, source_pod(source_snapshot(; kind=SourceControl.QUERY,
        token=Int64(2), sequence=Int64(3))))
    @test_throws Exception SourceNative.matching_reply(backwards, "status", Int64(2),
        source_snapshot(; kind=SourceControl.RUN, token=Int64(1), sequence=Int64(4)))
    for values in (
        source_snapshot(Int64(18)), source_snapshot(; generation=Int64(0)),
        source_snapshot(; sequence=Int64(-1)), source_snapshot(; running=true, completed=true),
        source_snapshot(; report_generation=Int64(2)), source_snapshot(; report_sequence=Int64(1)),
        source_snapshot(; kind=SourceControl.RUN),
    )
        bad = source_initial_observation()
        SourceNative.observe!(bad, source_pod(values))
        @test bad.failure !== nothing
    end
    malformed = source_initial_observation()
    SourceNative.observe!(malformed, Pod(Int32(3)))
    @test malformed.failure !== nothing
    conflict = source_initial_observation()
    SourceNative.observe!(conflict, run_control_status(0, -1, :stopped))
    @test conflict.failure !== nothing
end

@testset "native source identity and deadline" begin
    properties = merge(SourceControl.source_properties(SourceControl.Mailbox(Int64(17))),
        Dict("node.name" => "source", "object.serial" => "42"))
    @test SourceNative.validate_metadata(properties, "source", Int64(getpid())) == (17, "42")
    for key in ("node.name", "object.serial", "pipewireao.run-control", "pipewireao.reset-control",
        "pipewireao.source-query.version", "pipewireao.source-snapshot.version",
        "pipewireao.source-rejection.version", "pipewireao.source-control.owner-pid",
        "pipewireao.source-control.instance")
        bad = copy(properties)
        delete!(bad, key)
        @test_throws Exception SourceNative.validate_metadata(bad, "source", Int64(getpid()))
    end
    @test_throws Exception SourceNative.validate_metadata(properties, "source", Int64(getpid() + 1))
    @test_throws Exception SourceNative.check_deadline(SourceNative.monotonic() - 1, () -> nothing)
    @test_throws ArgumentError SourceNative.check_deadline(Inf, () -> nothing)
    @test_throws Exception SourceNative.check_deadline(SourceNative.monotonic() + 1, () -> error("owner exited"))
end

# This fixture owns a fresh daemon and runtime directory. It never connects to
# the user's PipeWire session and does not create a GPU or scientific plant.
function with_source_private_core(f)
    prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
    libdir = isdir(joinpath(prefix, "lib", "x86_64-linux-gnu")) ?
        joinpath(prefix, "lib", "x86_64-linux-gnu") : joinpath(prefix, "lib")
    daemon_path = joinpath(prefix, "bin", "pipewire-ao")
    mktempdir(prefix="pipewireao-source-client-") do directory
        runtime, config = joinpath(directory, "runtime"), joinpath(directory, "configuration")
        mkpath(runtime)
        mkpath(config)
        remote = "source-client-$(getpid())-$(time_ns())"
        write(joinpath(config, "private-core.conf"), """
        context.properties = { core.daemon = true core.name = $remote support.dbus = false library.use-fallback = false }
        context.spa-libs = { support.* = support/libspa-support }
        context.modules = [
            { name = libpipewire-module-scheduler-v1 }
            { name = libpipewire-module-protocol-native }
            { name = libpipewire-module-client-node }
            { name = libpipewire-module-link-factory }
            { name = libpipewire-module-metadata }
            { name = libpipewire-module-access }
        ]
        """)
        write(joinpath(config, "client.conf"), """
        context.properties = { support.dbus = false }
        context.spa-libs = { support.* = support/libspa-support }
        context.modules = [
            { name = libpipewire-module-protocol-native }
            { name = libpipewire-module-client-node }
            { name = libpipewire-module-metadata }
        ]
        """)
        environment = Dict("XDG_RUNTIME_DIR" => runtime, "PIPEWIREAO_RUNTIME_DIR" => runtime,
            "PIPEWIREAO_CONFIG_DIR" => config, "PIPEWIREAO_MODULE_DIR" => joinpath(libdir, "pipewire-ao-0.3"),
            "PIPEWIREAO_SPA_PLUGIN_DIR" => joinpath(libdir, "spa-ao-0.2"), "PIPEWIREAO_DEBUG" => "0",
            "LD_LIBRARY_PATH" => libdir * ":" * get(ENV, "LD_LIBRARY_PATH", ""))
        log = open(joinpath(directory, "core.log"), "w+")
        daemon = nothing
        try
            daemon = run(pipeline(addenv(`$daemon_path -c private-core.conf`, environment);
                stdout=log, stderr=log); wait=false)
            timedwait(() -> ispath(joinpath(runtime, remote)), 10; pollint=0.01) == :ok ||
                error("private source daemon socket deadline expired")
            withenv(environment...) do
                f(remote)
            end
            @test !Base.process_exited(daemon)
        catch
            flush(log)
            seekstart(log)
            print(stderr, read(log, String))
            rethrow()
        finally
            if daemon !== nothing
                Base.process_exited(daemon) || kill(daemon)
                wait(daemon)
            end
            close(log)
        end
    end
end

mutable struct SourceMock
    mailbox::SourceControl.Mailbox
    generation::Int64
    sequence::Int64
    running::Bool
    completed::Bool
    silent::Bool
end

function (mock::SourceMock)(stream::Stream, id::UInt32, pod::Union{Nothing,Pod})
    mock.silent && return nothing
    SourceControl.ParameterChanged(mock.mailbox)(stream, id, pod)
    kind, token, requested = SourceControl.pending(mock.mailbox)
    kind == SourceControl.INITIAL && return nothing
    if kind == SourceControl.RUN
        mock.running = requested
        mock.sequence += requested ? 1 : 0
    elseif kind == SourceControl.RESET
        mock.generation += 1
        mock.sequence = 0
        mock.running = false
        mock.completed = false
    end
    mock.mailbox.report_generation = mock.generation
    mock.mailbox.report_sequence = mock.sequence
    SourceControl.publish!(mock.mailbox, stream, kind, token, Int32(0), mock, mock.generation)
    return nothing
end

@testset "finite private-core native source client" begin
    with_source_private_core() do remote
        loop = ThreadLoop("test.source.owner")
        context = core = stream = client = removal_stream = removal_client = nothing
        try
            mailbox = SourceControl.Mailbox(Int64(17))
            mock = SourceMock(mailbox, 1, 0, false, false, false)
            with_thread_loop_lock(loop) do _
                context = Context(loop)
                core = CoreConnection(context; properties=Dict("remote.name" => remote))
                properties = merge(SourceControl.source_properties(mailbox), Dict(
                    "node.name" => "test.native.source", "media.class" => "Stream/Output/Audio"))
                stream = Stream(core, "test.native.source"; properties, on_param_changed=mock)
                connect!(stream, :output; flags=STREAM_INACTIVE, params=mailbox.parameters.params)
            end
            start!(loop)
            @test_throws Exception SourceNative.connect(remote, "test.native.source", getpid() + 1;
                deadline=SourceNative.monotonic() + 2)
            # The supervisor has a different runtime directory than its child
            # owners. An absolute native remote must select the owned socket.
            owned_socket = joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"], remote)
            client = withenv("PIPEWIREAO_RUNTIME_DIR" => "/absent-source-client-runtime",
                             "XDG_RUNTIME_DIR" => "/absent-source-client-runtime") do
                SourceNative.connect(owned_socket, "test.native.source", getpid();
                    deadline=SourceNative.monotonic() + 10)
            end
            @test SourceNative.prepare_requests!(client;
                deadline=SourceNative.monotonic() + 10) === client
            @test client.observation.last_token == 0
            @test client.observation.snapshot[4] == client.observation.snapshot[7] == 0
            @test !client.observation.snapshot[8]
            @test_throws ArgumentError SourceNative.prepare_requests!(client; deadline=Inf)
            @test_throws Exception SourceNative.prepare_requests!(client;
                deadline=SourceNative.monotonic() - 1)
            @test SourceNative.request!(client, "status", Int64(1); deadline=SourceNative.monotonic() + 5)["sequence"] == 0
            @test_throws Exception SourceNative.prepare_requests!(client;
                deadline=SourceNative.monotonic() + 1)
            resumed = SourceNative.request!(client, "resume", Int64(2); deadline=SourceNative.monotonic() + 5)
            @test resumed["state"] == "running"
            @test resumed["sequence"] == 1
            paused = SourceNative.request!(client, "pause", Int64(3); deadline=SourceNative.monotonic() + 5)
            @test paused["state"] == "paused"
            @test paused["report-ready"]
            reset = SourceNative.request!(client, "reset", Int64(4); deadline=SourceNative.monotonic() + 5)
            @test reset["generation"] == 2
            @test reset["sequence"] == 0
            @test SourceNative.request!(client, "status", Int64(5); deadline=SourceNative.monotonic() + 5)["generation"] == 2
            @test_throws ArgumentError SourceNative.request!(client, "resume", Int64(5); deadline=SourceNative.monotonic() + 1)
            with_thread_loop_lock(loop) do _
                mock.silent = true
            end
            started = SourceNative.monotonic()
            @test_throws Exception SourceNative.request!(client, "status", Int64(6); deadline=started + 0.1)
            @test SourceNative.monotonic() - started < 1
            @test_throws Exception SourceNative.request!(client, "resume", Int64(7); deadline=SourceNative.monotonic() + 1)
            closed_client = client
            close(client)
            @test !isopen(closed_client.loop)
            @test !isopen(something(closed_client.node))
            close(closed_client)
            client = nothing
            # A fresh connection can observe the retained state but cannot
            # admit a non-initial source or replay any mutation automatically.
            @test_throws Exception SourceNative.connect(remote, "test.native.source", getpid(); deadline=SourceNative.monotonic() + 1)
            @test_throws Exception SourceNative.connect(remote, "absent.source", getpid(); deadline=SourceNative.monotonic() + 0.1)
            removal_mailbox = SourceControl.Mailbox(Int64(18))
            removal_mock = SourceMock(removal_mailbox, 1, 0, false, false, false)
            with_thread_loop_lock(loop) do _
                properties = merge(SourceControl.source_properties(removal_mailbox), Dict(
                    "node.name" => "test.removable.source", "media.class" => "Stream/Output/Audio"))
                removal_stream = Stream(core, "test.removable.source"; properties, on_param_changed=removal_mock)
                connect!(removal_stream, :output; flags=STREAM_INACTIVE, params=removal_mailbox.parameters.params)
            end
            removal_client = SourceNative.connect(remote, "test.removable.source", getpid(); deadline=SourceNative.monotonic() + 5)
            with_thread_loop_lock(loop) do _
                removal_mock.silent = true
            end
            waiter = @async try
                SourceNative.request!(removal_client, "status", Int64(1); deadline=SourceNative.monotonic() + 5)
            catch failure
                failure
            end
            @test timedwait(() -> with_thread_loop_lock(removal_client.loop) do _
                removal_client.observation.pending_token == 1
            end, 1; pollint=0.005) == :ok
            with_thread_loop_lock(loop) do _
                close(removal_stream)
            end
            @test timedwait(() -> istaskdone(waiter), 2; pollint=0.005) == :ok
            @test fetch(waiter) isa Exception
        finally
            removal_client === nothing || close(removal_client)
            client === nothing || close(client)
            with_thread_loop_lock(loop) do _
                removal_stream === nothing || close(removal_stream)
                stream === nothing || close(stream)
                core === nothing || close(core)
                context === nothing || close(context)
            end
            close(loop)
        end
    end
end
