using Test, PipeWireAODeployment

const SO = PipeWireAODeployment.SystemdOwners
const INVOCATION = "0123456789abcdef0123456789abcdef"

@testset "systemd owner names and exact invocation discovery" begin
    owner = SO.Coordinator("pipewireao-rtc@test.service", INVOCATION, "/user.slice/core.service")
    service = SO.Service(owner, "source-owner")
    @test service.unit == "pipewireao-owner-$(INVOCATION)-source-owner.service"
    @test service.state == :pending
    @test_throws SO.OwnerError SO.Service(owner, "../source")
    @test_throws SO.OwnerError SO.Service(owner, "Source")
    @test_throws SO.OwnerError SO.valid_invocation("1234")
    listed = "pipewireao-owner-$(INVOCATION)-core.service loaded active running Core\n" *
        "pipewireao-owner-$(INVOCATION)-source-owner.service loaded active running Source\n" *
        "pipewireao-owner-$(INVOCATION)f-core.service loaded active running Other\n" *
        "pipewireao-owner-$(INVOCATION)-bad.name.service loaded active running Bad\n"
    @test SO.parse_units(listed, INVOCATION) == [
        "pipewireao-owner-$(INVOCATION)-core.service",
        "pipewireao-owner-$(INVOCATION)-source-owner.service"]
    @test SO.parse_units("● pipewireao-owner-$(INVOCATION)-core.service loaded failed failed Core\n", INVOCATION) ==
        ["pipewireao-owner-$(INVOCATION)-core.service"]
    jobs = "82 pipewireao-owner-$(INVOCATION)-core.service start running\n" *
        "83 pipewireao-owner-$(INVOCATION)-source-owner.service stop waiting\n" *
        "84 pipewireao-owner-$(INVOCATION)f-source-owner.service start waiting\n"
    @test SO.parse_jobs(jobs, INVOCATION) == ["82" => "pipewireao-owner-$(INVOCATION)-core.service"]
end

@testset "owner command preserves arguments and strips coordinator notification state" begin
    owner = SO.Coordinator("pipewireao-rtc@test.service", INVOCATION, "/user.slice/core.service")
    service = SO.Service(owner, "core")
    secret = "secret '\$() \" value"
    command = SO.launch_command(service, ["/bin/echo", "literal \$HOME", "a'b", "a\"b"],
        Dict("SECRET" => secret, "NOTIFY_SOCKET" => "/tmp/notify", "INVOCATION_ID" => INVOCATION,
            "JOURNAL_STREAM" => "1:2", "SYSTEMD_EXEC_PID" => "123"),
        "/tmp", Dict("cpus" => [2, 3], "leader-cpu" => 2))
    @test command[1:4] == ["systemd-run", "--user", "--service-type=exec", "--expand-environment=no"]
    @test command[end-4:end] == ["--", "/bin/echo", "literal \$HOME", "a'b", "a\"b"]
    @test "--setenv=SECRET=" * secret in command
    @test !any(x -> startswith(x, "--setenv=NOTIFY_SOCKET=") ||
        startswith(x, "--setenv=INVOCATION_ID=") ||
        startswith(x, "--setenv=JOURNAL_STREAM=") ||
        startswith(x, "--setenv=SYSTEMD_EXEC_PID="), command)
    @test "--property=CPUAffinity=2" in command
    @test !any(x -> startswith(x, "--property=AllowedCPUs="), command)
    @test "--property=KillMode=control-group" in command
    @test "--property=Restart=no" in command
    @test "--property=UMask=0077" in command
    @test SO.launch_command(service, ["/bin/echo", ""], Dict(), "/tmp",
        Dict("cpus" => [2], "leader-cpu" => 2))[end] == ""
    @test_throws SO.OwnerError SO.launch_command(service, ["/bin/echo"], Dict(), "/tmp",
        Dict("cpus" => [0, 2], "leader-cpu" => 2))
    @test_throws SO.OwnerError SO.launch_command(service, ["echo"], Dict(), "/tmp",
        Dict("cpus" => [2], "leader-cpu" => 2))
end

@testset "retained owner identity and recursive cgroup evidence" begin
    owner = SO.Coordinator("pipewireao-rtc@test.service", INVOCATION, "/user.slice/core.service")
    service = SO.Service(owner, "core")
    service.main_pid = getpid()
    service.start_ticks = SO.start_ticks(getpid())
    service.cgroup = SO.proc_cgroup(getpid())
    service.invocation = INVOCATION
    service.state = :running
    @test SO.alive(service)
    @test !SO.process_identity(getpid(), service.start_ticks + 1, service.cgroup)
    @test SO.old_process_exists(getpid(), service.start_ticks)
    values = Dict("InvocationID" => INVOCATION, "ControlGroup" => service.cgroup,
        "MainPID" => string(getpid()))
    @test SO.same_incarnation(service, values)
    values["InvocationID"] = repeat("a", 32)
    @test !SO.same_incarnation(service, values)
    values["InvocationID"] = INVOCATION
    values["ControlGroup"] *= "-replacement"
    @test !SO.same_incarnation(service, values)
    @test SO.parse_populated("populated 1\nfrozen 0\n") # descendants count even when cgroup.procs is empty
    @test !SO.parse_populated("populated 0\nfrozen 0\n")
    @test_throws SO.OwnerError SO.parse_populated("frozen 0\n")
    @test_throws SO.OwnerError SO.parse_populated("populated 2\n")
    @test SO.parse_properties("Id=unit.service\nExecStopPost=argv[]=x=y\n")["ExecStopPost"] == "argv[]=x=y"
    @test_throws SO.OwnerError SO.parse_properties("Id=a\nId=b\n")
    launcher = "/tmp/package/bin/pipewireao-rtc-deploy"
    hook = "{ path=" * launcher * " ; argv[]=" * launcher *
        " cleanup-systemd-owners --invocation \${INVOCATION_ID} ; ignore_errors=no ; " *
        "start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
    @test SO.cleanup_hook_valid(hook, launcher)
    spaced = "/tmp/package with spaces/bin/pipewireao-rtc-deploy"
    @test SO.cleanup_hook_valid(replace(hook, launcher => spaced), spaced)
    @test !SO.cleanup_hook_valid("/bin/echo cleanup-systemd-owners --invocation \${INVOCATION_ID}", launcher)
    @test !SO.cleanup_hook_valid(replace(hook, "path=" * launcher => "path=/bin/echo"), launcher)
    @test !SO.cleanup_hook_valid(replace(hook, "argv[]=" * launcher => "argv[]=/bin/echo"), launcher)
    @test !SO.cleanup_hook_valid(replace(hook, "--invocation \${INVOCATION_ID}" => "--invocation wrong"), launcher)
    @test !SO.cleanup_hook_valid(replace(hook, " cleanup-systemd-owners --invocation \${INVOCATION_ID}" => ""), launcher)
    @test !SO.cleanup_hook_valid(replace(hook, "ignore_errors=no" => "ignore_errors=yes"), launcher)
    @test !SO.cleanup_hook_valid(hook * " { path=" * launcher * " ; argv[]=another ; }", launcher)
end
