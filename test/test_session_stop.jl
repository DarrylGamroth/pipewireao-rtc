using Test, PipeWireAORTC
using PipeWireAORTC: SessionLaunch, SessionInstall

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
