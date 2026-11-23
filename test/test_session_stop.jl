using Test, PipeWireAO, PipeWireAORTC, JSON
using PipeWireAORTC: SessionLaunch, SessionInstall

@testset "managed stop timing retains missing and late receipts" begin
    Client = PipeWireAORTC.ControlClient
    Envelope = PipeWireAORTC.ControlCodec
    Runner = PipeWireAORTC.RunnerCodec
    CLI = PipeWireAORTC.SessionCLI
    profile = PipeWireAORTC.SessionProfile.Profile()
    trace = Client.Trace(profile)
    observation = Client.Observation(profile, Int64(23), UInt32(getpid()); trace)
    controller = Envelope.ControllerIdentity(UInt32(42), UInt64(8), Int64(9))
    other = Envelope.ControllerIdentity(
        controller.global_id, UInt64(7), controller.instance
    )
    operation = Runner.operation_id(Runner.RunnerCommand(:quit))
    observation.pending = Envelope.RequestHeader(
        controller, Int64(23), Int64(2), operation, Int64(100)
    )
    payload = SPA.Struct(
        Pod(SPA.Id(UInt32(Runner.Offline))),
        Pod(SPA.Id(UInt32(Runner.Accepted))),
        Pod(SPA.Struct(Pod(true))),
    )
    completion(identity, token) = Envelope.encode_completion(
        Envelope.ReplyHeader(identity, Int64(23), token, operation, Int32(0)), payload
    )
    deadline = Int64(100)
    failed = (outcome = :failed, process_exit_at = nothing)
    summary(result = failed; times = trace) = JSON.parse(
        JSON.json(CLI.stop_timing("fixture.service", "fixture", deadline, times, result)),
    )

    first = summary()
    @test first["deadline_ns"] == deadline
    @test first["outcome"] == "failed"
    @test length(filter(key -> endswith(key, "_remaining_ns"), keys(first))) == 8
    @test all(value === nothing for (key, value) in first if endswith(key, "_remaining_ns"))

    trace.submission_at = Int64(70)
    Client.observe!(observation, completion(other, Int64(1)); at = 80)
    @test summary()["offline_remaining_ns"] === nothing
    Client.observe!(observation, completion(controller, Int64(2)); at = 102)
    Client.observe!(observation, completion(controller, Int64(2)); at = 106)
    @test_throws Client.UnknownOutcome Client.matching_reply(
        observation, deadline; now = 107
    )
    late = summary()
    @test late["quit_submission_remaining_ns"] == 30
    @test late["offline_remaining_ns"] == -2
    @test late["process_exit_remaining_ns"] === nothing

    normal = Client.Trace(profile)
    normal_observation = Client.Observation(
        profile, Int64(23), UInt32(getpid()); trace = normal
    )
    normal_observation.pending = observation.pending
    Client.observe!(normal_observation, completion(controller, Int64(2)); at = 92)
    @test Client.matching_reply(normal_observation, deadline; now = 96).lifecycle ==
        Runner.Offline
    exited = summary((outcome = :completed, process_exit_at = Int64(98)); times = normal)
    @test exited["outcome"] == "completed"
    @test exited["offline_remaining_ns"] == 8
    @test exited["process_exit_remaining_ns"] == 2
end

@testset "installed restart requires an explicit valid session" begin
    main = PipeWireAORTC.SessionCLI.main
    @test_throws ArgumentError main(["restart"])
    @test_throws ArgumentError main(["restart", "--session", "not-a-uuid"])
end

@testset "installed session launcher keeps the selected Julia project" begin
    launcher = SessionInstall.installed_launcher(
        "/sdk path/bin/julia"; environment = "/app path/env"
    )
    @test occursin(
        "exec '/sdk path/bin/julia' --startup-file=no --project='/app path/env'", launcher
    )
    @test occursin(
        "using PipeWireAORTC; exit(PipeWireAORTC.SessionCLI.main(ARGS))", launcher
    )
    @test occursin("Base.exit_on_sigint(false)", launcher)
    @test_throws UndefKeywordError SessionInstall.installed_launcher("/sdk/bin/julia")
end

@testset "installed startup commands select -O0" begin
    mktempdir() do directory
        julia = joinpath(mkpath(joinpath(directory, "sdk path")), "julia")
        write(julia, raw"""
            #!/bin/sh
            IFS= read -r ready || exit 1
            printf '%s\n' "$$" "$0" "$PIPEWIREAO_RTC_EXPORT_COMMIT" "$@"
            """)
        chmod(julia, 0o755)
        environment = joinpath(directory, "app path's project")
        commit = "0"^40
        launcher = joinpath(directory, "client launcher")
        write(launcher, SessionInstall.installed_launcher(julia; environment, commit))
        chmod(launcher, 0o755)

        julia_args = ["--startup-file=no", "--project=$environment"]
        entry = "Base.exit_on_sigint(false); using PipeWireAORTC; exit(PipeWireAORTC.SessionCLI.main(ARGS))"
        for command in ("prepare", "publish", "stop", "cleanup", "control", "restart", "sessions", "")
            args = isempty(command) ? String[] : [command, "--runtime-root", "path with spaces", ""]
            optimization = command in ("prepare", "publish") ? ["-O0"] : String[]
            open(`$launcher $args`, "r+") do process
                pid = getpid(process)
                println(process, "ready")
                flush(process)
                @test readlines(process) ==
                    [string(pid), julia, commit, julia_args..., optimization..., "-e", entry, "--", args...]
            end
        end
    end
end

@testset "exact installed graceful stop hook" begin
    request = SessionLaunch.Request(
        "/sdk",
        "/prefix",
        "pipewireao-session@test.service",
        "/sdk/bin/pipewireao-rtc-session",
        "/run/user/1000/pipewireao-session-test",
    )
    hook = "{ path=/sdk/bin/pipewireao-rtc-session ; argv[]=/sdk/bin/pipewireao-rtc-session stop --unit pipewireao-session@test.service --runtime-root /run/user/1000/pipewireao-session-test ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0 }"
    @test SessionLaunch.stop_hook_valid(hook, request)
    for changed in (
        replace(hook, "stop --unit" => "control --unit"),
        replace(hook, "@test.service" => "@foreign.service"),
        replace(hook, "ignore_errors=no" => "ignore_errors=yes"),
        replace(hook, "session-test ;" => "session-foreign ;"),
        hook * " " * hook,
        "",
        "/sdk/bin/pipewireao-rtc-session",
    )
        @test !SessionLaunch.stop_hook_valid(changed, request)
    end
    template = read(
        joinpath(dirname(@__DIR__), "assets/deployment/pipewireao-session@.service.in"),
        String,
    )
    @test "ExecStop=@LAUNCHER@ stop --unit %n --runtime-root %t/pipewireao-session-%i" in
        split(template, '\n')
    @test first(findfirst("ExecStop=", template)) <
        first(findfirst("ExecStopPost=", template))
    @test "KillMode=control-group" in split(template, '\n')
    @test "KillSignal=SIGINT" in split(template, '\n')
    @test "TimeoutStopSec=300" in split(template, '\n')
end
