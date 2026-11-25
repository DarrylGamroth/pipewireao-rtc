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

@testset "installed session launcher uses minimal compilation only for preparation" begin
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
            optimization = command == "prepare" ? ["-O0", "--compile=min"] : String[]
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
    direct_hook = replace(hook, "session-test ;" => "session-test --direct ;")
    @test SessionLaunch.stop_hook_valid(direct_hook, request; direct = true)
    @test !SessionLaunch.stop_hook_valid(direct_hook, request)
    @test !SessionLaunch.stop_hook_valid(hook, request; direct = true)
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
    @test "Type=notify" in split(template, '\n')
    @test "NotifyAccess=main" in split(template, '\n')
    @test !occursin("ExecStartPost=", template)
    @test "KillMode=control-group" in split(template, '\n')
    @test "KillSignal=SIGINT" in split(template, '\n')
    @test "TimeoutStopSec=300" in split(template, '\n')
end

@testset "installed admission binds native identity to the prepared invocation" begin
    CLI = PipeWireAORTC.SessionCLI
    pid = Int(getpid())
    endpoint = (
        session_id = "a5555555-5555-4555-8555-555555555555",
        instance = Int64(29),
        remote = "/runtime/core",
        node_name = "pipewireao.rtc.session.fixture",
        owner_pid = UInt32(pid),
        global_id = UInt32(3),
        serial = UInt64(81),
    )
    request = SessionLaunch.Request(
        "/package", "/prefix", "pipewireao-session@fixture.service",
        "/package/bin/pipewireao-rtc-session", "/runtime",
    )
    record = Dict{String,Any}(
        "version" => SessionLaunch.LEDGER_VERSION, "name" => "fixture",
        "session_uuid" => endpoint.session_id, "session_control_instance" => endpoint.instance,
        "session_pid" => pid, "remote" => endpoint.remote,
    )
    context = CLI.InstalledAdmission(
        request, "a"^32, "/runtime/rtc/rtc.conf", record, (pid, UInt64(1), "/cgroup"),
        (endpoint.global_id, endpoint.serial), nothing,
    )
    @test CLI._endpoint_identity(context, endpoint) == context.endpoint
    for changed in (
        (; endpoint..., session_id = "b5555555-5555-4555-8555-555555555555"),
        (; endpoint..., instance = Int64(30)),
        (; endpoint..., remote = "/runtime/foreign"),
        (; endpoint..., node_name = "pipewireao.rtc.session.foreign"),
        (; endpoint..., owner_pid = UInt32(pid + 1)),
        (; endpoint..., global_id = UInt32(0)),
        (; endpoint..., global_id = typemax(UInt32)),
        (; endpoint..., serial = UInt64(0)),
    )
        @test_throws ArgumentError CLI._endpoint_identity(context, changed)
    end
    @test_throws "native endpoint changed after installed admission" CLI.publish_ready!(
        () -> error("must not reach publication"),
        context, (; endpoint..., serial = UInt64(82)); deadline = nothing, clock = nothing,
    )
    withenv(SessionLaunch.ADMISSION_UNIT_ENV => nothing, "INVOCATION_ID" => "a"^32) do
        @test CLI.installed_admission("/arbitrary/direct.conf") === nothing
    end
    withenv(SessionLaunch.ADMISSION_UNIT_ENV => request.unit, "INVOCATION_ID" => "stale") do
        @test_throws "invalid systemd invocation identity" CLI.installed_admission(context.config)
    end
    @test_throws ArgumentError CLI.main(["publish"])
end

@testset "installed discovery preserves a conflicting incarnation" begin
    CLI = PipeWireAORTC.SessionCLI
    Discovery = PipeWireAORTC.SessionDiscovery
    name = "fixture"
    id = "a5555555-5555-4555-8555-555555555555"
    pid = UInt32(getpid())
    remote = "/runtime/core"
    node = "pipewireao.rtc.session.fixture"
    ready = Discovery.SessionRecord(name, id, pid, Int64(29), remote, node)
    conflict = Discovery.SessionRecord(name, id, pid, Int64(30), remote, node)
    record = Dict{String,Any}(
        "version" => SessionLaunch.LEDGER_VERSION, "session_uuid" => id,
        "session_pid" => pid, "session_control_instance" => conflict.incarnation,
    )
    mktempdir() do runtime
        withenv("XDG_RUNTIME_DIR" => runtime) do
            path = CLI._verified_discovery!(record, ready)
            @test_throws "different session already owns discovery UUID" CLI._verified_discovery!(
                record, conflict
            )
            @test Discovery._read_record(path).incarnation == ready.incarnation
            @test CLI._verified_discovery!(record, ready) == path
            CLI.retire_record!(record, path)
            @test isfile(path)
            record["session_control_instance"] = ready.incarnation
            CLI.retire_record!(record, path)
            @test !ispath(path)
        end
    end
end

@testset "session unit rendering follows the pinned RTC cohort" begin
    mktempdir() do root
        package_id = Base.PkgId(PipeWireAORTC)
        project = mkdir(joinpath(root, "application"))
        write(joinpath(project, "Project.toml"), "[deps]\nPipeWireAORTC = \"$(package_id.uuid)\"\n")
        for (package, policy) in (
            ("exec", "Type=exec\nExecStartPost=@LAUNCHER@ publish\n"),
            ("notify", "Type=notify\nNotifyAccess=main\n"),
        )
            source = joinpath(root, package)
            write(joinpath(mkpath(joinpath(source, "src")), "PipeWireAORTC.jl"), "")
            assets = mkpath(joinpath(source, "assets", "deployment"))
            write(joinpath(assets, "pipewireao-session@.service.in"), policy)
            write(
                joinpath(project, "Manifest.toml"),
                """
                manifest_format = "2.0"

                [[deps.PipeWireAORTC]]
                path = "../$package"
                uuid = "$(package_id.uuid)"
                version = "0.7.30"
                """,
            )
            @test SessionInstall.resolved_unit_template(project) == policy
        end
    end
    installed = Dict(
        "Type" => "notify", "NotifyAccess" => "main", "KillMode" => "control-group",
        "Restart" => "no",
    )
    @test SessionLaunch.session_lifetime_valid(installed)
    @test !SessionLaunch.session_lifetime_valid(merge(installed, Dict("NotifyAccess" => "all")))
    historical = merge(installed, Dict("Type" => "exec", "NotifyAccess" => "none"))
    @test !SessionLaunch.session_lifetime_valid(historical)
    @test SessionLaunch.session_lifetime_valid(historical; allow_exec = true)
    @test !SessionLaunch.session_lifetime_valid(
        merge(historical, Dict("KillMode" => "process")); allow_exec = true,
    )
end
