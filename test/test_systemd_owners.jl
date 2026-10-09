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

@testset "owner service rendering quotes arguments and applies isolated service policy" begin
    owner = SO.Coordinator("pipewireao-rtc@test.service", INVOCATION, "/user.slice/core.service")
    service = SO.Service(owner, "core")
    argv = ["/bin/echo", "", "two words", "\$HOME", "%n", "line\nbreak", "slash\\path", "a\"b"]
    environment = Dict("SECRET" => "secret '\$() \" value", "NOTIFY_SOCKET" => "/tmp/notify",
        "INVOCATION_ID" => INVOCATION, "JOURNAL_STREAM" => "1:2", "SYSTEMD_EXEC_PID" => "123",
        "PIPEWIREAO_LITERAL" => "\$HOME %n line\nbreak slash\\path a\"b")
    unit = SO.service_unit(service, argv, environment,
        "/tmp", Dict("cpus" => [2, 3], "leader-cpu" => 2))
    @test "ExecStart=:\"/bin/echo\" \"\" \"two words\" \"\$HOME\" \"%%n\" \"line\\nbreak\" \"slash\\\\path\" \"a\\\"b\"" in split(unit, '\n')
    @test "Environment=\"PIPEWIREAO_LITERAL=\$HOME %%n line\\nbreak slash\\\\path a\\\"b\"" in split(unit, '\n')
    @test "Environment=\"SECRET=secret '\$() \\\" value\"" in split(unit, '\n')
    @test !any(line -> startswith(line, "Environment=\"NOTIFY_SOCKET=") ||
        startswith(line, "Environment=\"INVOCATION_ID=") ||
        startswith(line, "Environment=\"JOURNAL_STREAM=") ||
        startswith(line, "Environment=\"SYSTEMD_EXEC_PID="), split(unit, '\n'))
    @test "Type=exec" in split(unit, '\n')
    @test "CPUAffinity=2" in split(unit, '\n')
    @test "LimitRTPRIO=95" in split(unit, '\n')
    @test "LimitMEMLOCK=4294967296" in split(unit, '\n')
    @test "KillMode=control-group" in split(unit, '\n')
    @test "Restart=no" in split(unit, '\n')
    @test !any(line -> startswith(line, "PartOf=") || startswith(line, "Requires=") ||
        startswith(line, "BindsTo="), split(unit, '\n'))
    @test SO.unit_argument("a\tb\n\\\"%n") == "\"a\\tb\\n\\\\\\\"%%n\""
    @test_throws SO.OwnerError SO.unit_argument("bad\0value")
    @test_throws SO.OwnerError SO.service_unit(service, ["/bin/echo", "bad\0arg"], Dict(),
        "/tmp", Dict("cpus" => [2], "leader-cpu" => 2))
    @test_throws SO.OwnerError SO.service_unit(service, ["/bin/echo"], Dict("bad-key" => "x"),
        "/tmp", Dict("cpus" => [2], "leader-cpu" => 2))
    @test_throws SO.OwnerError SO.service_unit(service, ["/bin/echo"], Dict("KEY" => "bad\0value"),
        "/tmp", Dict("cpus" => [2], "leader-cpu" => 2))
    @test_throws SO.OwnerError SO.service_unit(service, ["/bin/echo"], Dict(), "relative",
        Dict("cpus" => [2], "leader-cpu" => 2))
    @test_throws SO.OwnerError SO.service_unit(service, ["/bin/echo"], Dict(), "/missing-owner-cwd",
        Dict("cpus" => [2], "leader-cpu" => 2))
    @test_throws SO.OwnerError SO.service_unit(service, ["/bin/echo"], Dict(), "/tmp",
        Dict("cpus" => [0, 2], "leader-cpu" => 2))
    @test_throws SO.OwnerError SO.service_unit(service, ["echo"], Dict(), "/tmp",
        Dict("cpus" => [2], "leader-cpu" => 2))
end

@testset "cohort service dependencies and target job filtering" begin
    core = "pipewireao-owner-$(INVOCATION)-core.service"
    source = "pipewireao-owner-$(INVOCATION)-source-owner.service"
    target = SO.cohort_name(INVOCATION)
    unit = SO.cohort_unit(INVOCATION, [core, source])
    @test "Wants=$core $source" in split(unit, '\n')
    @test "After=$core $source" in split(unit, '\n')
    @test_throws SO.OwnerError SO.cohort_unit(INVOCATION, [core, core])
    @test_throws SO.OwnerError SO.cohort_unit(INVOCATION,
        ["pipewireao-owner-ffffffffffffffffffffffffffffffff-core.service"])
    @test_throws SO.OwnerError SO.cohort_unit(INVOCATION, ["pipewireao-owner-$(INVOCATION)-bad.role.service"])
    jobs = "82 $core start running\n" *
        "83 $target start waiting\n" *
        "84 $target stop waiting\n" *
        "85 pipewireao-owner-ffffffffffffffffffffffffffffffff-core.service start waiting\n" *
        "86 pipewireao-owner-$(INVOCATION)f-cohort.target start waiting\n"
    @test SO.parse_jobs(jobs, INVOCATION) == ["82" => core, "83" => target]
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
end
