using Test, PipeWireAORTC
import Hsm

const SO = PipeWireAORTC.SystemdOwners
const INVOCATION = "0123456789abcdef0123456789abcdef"

@testset "systemd owner names and exact invocation discovery" begin
    owner = SO.Coordinator(
        "pipewireao-rtc@test.service", INVOCATION, "/user.slice/core.service"
    )
    service = SO.Service(owner, "source-owner")
    @test service.unit == "pipewireao-owner-$(INVOCATION)-source-owner.service"
    @test service.state == :pending
    @test_throws SO.OwnerError SO.Service(owner, "../source")
    @test_throws SO.OwnerError SO.Service(owner, "Source")
    @test_throws SO.OwnerError SO.valid_invocation("1234")
    listed =
        "pipewireao-owner-$(INVOCATION)-core.service loaded active running Core\n" *
        "pipewireao-owner-$(INVOCATION)-source-owner.service loaded active running Source\n" *
        "pipewireao-owner-$(INVOCATION)f-core.service loaded active running Other\n" *
        "pipewireao-owner-$(INVOCATION)-bad.name.service loaded active running Bad\n"
    @test SO.parse_units(listed, INVOCATION) == [
        "pipewireao-owner-$(INVOCATION)-core.service",
        "pipewireao-owner-$(INVOCATION)-source-owner.service",
    ]
    @test SO.parse_units(
        "● pipewireao-owner-$(INVOCATION)-core.service loaded failed failed Core\n",
        INVOCATION,
    ) == ["pipewireao-owner-$(INVOCATION)-core.service"]
    jobs =
        "82 pipewireao-owner-$(INVOCATION)-core.service start running\n" *
        "83 pipewireao-owner-$(INVOCATION)-source-owner.service stop waiting\n" *
        "84 pipewireao-owner-$(INVOCATION)f-source-owner.service start waiting\n"
    @test SO.parse_jobs(jobs, INVOCATION) ==
        ["82" => "pipewireao-owner-$(INVOCATION)-core.service"]
end

# A separate copy keeps scripted process/systemd evidence out of package methods.
module ServiceBoundary
using PipeWireAORTC
const Common = PipeWireAORTC.Common
const Placement = PipeWireAORTC.Placement
include(joinpath(PipeWireAORTC.package_root(), "src", "deployment", "systemd_owners.jl"))
const S = SystemdOwners
@eval S begin
    const test_values = Ref(Dict{String,String}())
    const test_calls = Any[]
    const test_live = Ref(false)
    const test_old_process = Ref(false)
    const test_empty = Ref(true)
    const test_quiet = Ref(false)
    const test_jobs = Pair{String,String}[]
    const test_stop_code = Ref(0)
    const test_group = "/test.slice/retained.service"
    function properties(unit::String; extra = "", deadline = nothing, clock = nothing)
        push!(test_calls, (:properties, unit, extra))
        return copy(test_values[])
    end
    function start_ticks(pid::Int)
        push!(test_calls, (:start_ticks, pid))
        return UInt64(71)
    end
    function proc_cgroup(pid::Int)
        push!(test_calls, (:proc_cgroup, pid))
        return test_group
    end
    function process_identity(pid::Int, ticks::UInt64, group::String)
        push!(test_calls, (:process_identity, pid, ticks, group))
        return test_live[]
    end
    function old_process_exists(pid::Int, ticks::UInt64)
        push!(test_calls, (:old_process_exists, pid, ticks))
        return test_old_process[]
    end
    function cgroup_empty(group::String)
        push!(test_calls, (:cgroup_empty, group))
        return test_empty[]
    end
    function listed_jobs(invocation::String; deadline = nothing, clock = nothing)
        push!(test_calls, (:listed_jobs, invocation))
        return copy(test_jobs)
    end
    function quiescent_unit(unit::String; deadline = nothing, clock = nothing)
        push!(test_calls, (:quiescent_unit, unit))
        return test_quiet[]
    end
    function checked(argv::Vector{String}; timeout = 5, deadline = nothing, clock = nothing)
        push!(test_calls, (:command, copy(argv)))
        return (; returncode = test_stop_code[], stderr = "")
    end
    function wait_empty(group::String, deadline::Int64; clock = nothing)
        push!(test_calls, (:wait_empty, group))
        return test_empty[]
    end
end
function service()
    empty!(S.test_calls)
    empty!(S.test_jobs)
    S.test_live[] = S.test_old_process[] = S.test_quiet[] = false
    S.test_empty[] = true
    S.test_stop_code[] = 0
    owner = S.Coordinator(
        "pipewireao-session@test.service", "0123456789abcdef0123456789abcdef", ""
    )
    service = S.Service(owner, "source-owner")
    S.test_values[] = Dict(
        "LoadState" => "loaded",
        "ActiveState" => "active",
        "MainPID" => "42",
        "InvocationID" => owner.invocation,
        "ControlGroup" => S.test_group,
        "Result" => "exit-code",
        "ExecMainCode" => "1",
        "ExecMainStatus" => "7",
    )
    return service
end
end

@testset "service HSM preserves retained identity and verification order" begin
    S = ServiceBoundary.S
    service = ServiceBoundary.service()
    @test Hsm.current(service) === :Pending && service.state === :pending
    @test :state in propertynames(service) && :state ∉ fieldnames(typeof(service))
    @test_throws ErrorException setproperty!(service, :state, :running)
    @test S.launching!(service) === nothing && service.state === :launching
    @test isempty(S.test_calls)
    @test S.retain!(service, S.test_values[]) === service
    @test service.state === :running && S.pid(service) == 42
    @test S.test_calls == [(:start_ticks, 42), (:proc_cgroup, 42)]
    @test (service.invocation, service.start_ticks, service.cgroup) ==
        (service.coordinator.invocation, UInt64(71), S.test_group)
    S.test_live[] = true
    empty!(S.test_calls)
    @test S.verify!(service) === service
    @test S.test_calls == [
        (:properties, service.unit, ""), (:process_identity, 42, UInt64(71), S.test_group)
    ]
    S.test_values[]["InvocationID"] = repeat("f", 32)
    @test_throws S.OwnerError S.verify!(service)
    @test service.state === :running && service.invocation == service.coordinator.invocation
    @test S.uncertain!(service) === nothing && service.state === :uncertain
    empty!(S.test_calls)
    @test_throws S.OwnerError S.verify!(service)
    @test isempty(S.test_calls)
    @test S.running!(service) === nothing && service.state === :running
    service = ServiceBoundary.service()
    S.launching!(service)
    S.test_values[]["ControlGroup"] = "/test.slice/different.service"
    @test_throws S.OwnerError S.retain!(service, S.test_values[])
    @test service.state === :launching && service.main_pid == 0 && service.start_ticks == 0
    @test service.invocation == service.coordinator.invocation &&
        service.cgroup == S.test_values[]["ControlGroup"]
    @test S.test_calls == [(:start_ticks, 42), (:proc_cgroup, 42)]
end

@testset "service stop events refuse replacements and retain failed outcomes" begin
    S = ServiceBoundary.S
    for (field, value) in (
        ("InvocationID", repeat("f", 32)),
        ("ControlGroup", "/test.slice/replacement.service"),
        ("MainPID", "43"),
    )
        service = ServiceBoundary.service()
        S.retain!(service, S.test_values[])
        S.test_values[][field] = value
        empty!(S.test_calls)
        @test_throws S.OwnerError S.stop!(service)
        @test service.state === :stop_failed
        @test service.error == "owner unit incarnation changed; refusing to stop it"
        @test !any(call -> first(call) === :command, S.test_calls)
        @test (service.main_pid, service.start_ticks, service.cgroup) ==
            (42, UInt64(71), S.test_group)
    end
    service = ServiceBoundary.service()
    @test S.stop!(service) === nothing &&
        service.state === :pending &&
        isempty(S.test_calls)
    @test_throws S.OwnerError S.stop!(service, -1)
    @test service.state === :stop_failed && service.error == "invalid owner exit grace"
    @test isempty(S.test_calls)
    service = ServiceBoundary.service()
    S.launching!(service)
    @test_throws S.OwnerError S.stop_impl!(service, 0)
    @test service.state === :uncertain && isempty(service.error)
    @test_throws S.OwnerError S.stop!(service)
    @test service.state === :stop_failed
    @test service.error ==
        "owner launch identity was never retained; refusing to stop uncertain unit"
    @test !any(call -> first(call) === :command, S.test_calls)
end

@testset "service stop and failure evidence remain systemd-owned" begin
    S = ServiceBoundary.S
    service = ServiceBoundary.service()
    S.retain!(service, S.test_values[])
    empty!(S.test_calls)
    @test S.failure(service) ==
        "owner process identity exited or left its cgroup; Result=exit-code, ExecMainCode=1, ExecMainStatus=7"
    retained = copy(S.test_calls)
    @test S.failure(service) == service.error && S.test_calls == retained
    @test service.state === :running
    @test S.stop!(service) === nothing && service.state === :stopped
    commands = filter(call -> first(call) === :command, S.test_calls)
    @test commands == [(:command, ["systemctl", "--user", "stop", service.unit])]
    @test last(S.test_calls) == (:old_process_exists, 42, UInt64(71))
    stopped_calls = copy(S.test_calls)
    @test S.stop!(service) === nothing && S.test_calls == stopped_calls
    @test S.failure(service) == service.error && S.test_calls == stopped_calls

    service = ServiceBoundary.service()
    S.retain!(service, S.test_values[])
    S.test_values[]["ActiveState"] = "inactive"
    S.test_values[]["MainPID"] = "0"
    empty!(S.test_calls)
    @test S.stop!(service) === nothing && service.state === :stopped
    @test !any(call -> first(call) === :command, S.test_calls)
    @test last(S.test_calls) == (:listed_jobs, service.coordinator.invocation)

    service = ServiceBoundary.service()
    S.retain!(service, S.test_values[])
    S.test_empty[] = false
    @test_throws S.OwnerError S.stop!(service)
    @test service.state === :stop_failed &&
        service.error == "owner cgroup remains populated after stop"
    @test count(call -> first(call) === :command, S.test_calls) == 1
end

@testset "owner runtime preserves inherited ROCr helper affinity" begin
    owner = SO.Coordinator(
        "pipewireao-rtc@test.service", INVOCATION, "/user.slice/core.service"
    )
    service = SO.Service(owner, "optics")
    placement = Dict("cpus" => [2, 3], "leader-cpu" => 2)
    environment = Dict("OPENBLAS_NUM_THREADS" => "1")
    before = copy(environment)
    unit = SO.service_unit(service, ["/usr/bin/julia"], environment, "/tmp", placement)
    @test "Environment=\"HSA_OVERRIDE_CPU_AFFINITY_DEBUG=0\"" in split(unit, '\n')
    @test environment == before
    environment["HSA_OVERRIDE_CPU_AFFINITY_DEBUG"] = "0"
    before = copy(environment)
    unit = SO.service_unit(service, ["/usr/bin/julia"], environment, "/tmp", placement)
    @test count(
        ==("Environment=\"HSA_OVERRIDE_CPU_AFFINITY_DEBUG=0\""), split(unit, '\n')
    ) == 1
    @test environment == before
    environment["HSA_OVERRIDE_CPU_AFFINITY_DEBUG"] = "1"
    before = copy(environment)
    @test_throws SO.OwnerError SO.service_unit(
        service, ["/usr/bin/julia"], environment, "/tmp", placement
    )
    @test environment == before
    environment["HSA_OVERRIDE_CPU_AFFINITY_DEBUG"] = ""
    @test_throws SO.OwnerError SO.service_unit(
        service, ["/usr/bin/julia"], environment, "/tmp", placement
    )
end

@testset "placement affinity failure identifies process and thread" begin
    placement = Dict("cpus" => [typemax(Int)], "leader-cpu" => typemax(Int))
    error = try
        SO.Placement.snapshot(getpid(), placement)
    catch exception
        exception
    end
    @test error isa SO.Placement.PlacementError
    message = sprint(showerror, error)
    @test occursin("process $(getpid()) thread $(getpid())", message)
    @test occursin("exceeds deployment envelope", message)
end

@testset "owner service rendering quotes arguments and applies isolated service policy" begin
    owner = SO.Coordinator(
        "pipewireao-rtc@test.service", INVOCATION, "/user.slice/core.service"
    )
    service = SO.Service(owner, "core")
    argv = [
        "/bin/echo", "", "two words", "\$HOME", "%n", "line\nbreak", "slash\\path", "a\"b"
    ]
    environment = Dict(
        "SECRET" => "secret '\$() \" value",
        "NOTIFY_SOCKET" => "/tmp/notify",
        "INVOCATION_ID" => INVOCATION,
        "JOURNAL_STREAM" => "1:2",
        "SYSTEMD_EXEC_PID" => "123",
        "PIPEWIREAO_LITERAL" => "\$HOME %n line\nbreak slash\\path a\"b",
    )
    unit = SO.service_unit(
        service, argv, environment, "/tmp", Dict("cpus" => [2, 3], "leader-cpu" => 2)
    )
    @test "ExecStart=:\"/bin/echo\" \"\" \"two words\" \"\$HOME\" \"%%n\" \"line\\nbreak\" \"slash\\\\path\" \"a\\\"b\"" in
        split(unit, '\n')
    @test "Environment=\"PIPEWIREAO_LITERAL=\$HOME %%n line\\nbreak slash\\\\path a\\\"b\"" in
        split(unit, '\n')
    @test "Environment=\"SECRET=secret '\$() \\\" value\"" in split(unit, '\n')
    @test !any(
        line ->
            startswith(line, "Environment=\"NOTIFY_SOCKET=") ||
            startswith(line, "Environment=\"INVOCATION_ID=") ||
            startswith(line, "Environment=\"JOURNAL_STREAM=") ||
            startswith(line, "Environment=\"SYSTEMD_EXEC_PID="),
        split(unit, '\n'),
    )
    @test "Type=exec" in split(unit, '\n')
    @test "CPUAffinity=2" in split(unit, '\n')
    @test "LimitRTPRIO=95" in split(unit, '\n')
    @test "LimitMEMLOCK=4294967296" in split(unit, '\n')
    @test "KillMode=control-group" in split(unit, '\n')
    @test "Restart=no" in split(unit, '\n')
    @test !any(
        line ->
            startswith(line, "PartOf=") ||
            startswith(line, "Requires=") ||
            startswith(line, "BindsTo="),
        split(unit, '\n'),
    )
    @test SO.unit_argument("a\tb\n\\\"%n") == "\"a\\tb\\n\\\\\\\"%%n\""
    @test_throws SO.OwnerError SO.unit_argument("bad\0value")
    @test_throws SO.OwnerError SO.service_unit(
        service,
        ["/bin/echo", "bad\0arg"],
        Dict(),
        "/tmp",
        Dict("cpus" => [2], "leader-cpu" => 2),
    )
    @test_throws SO.OwnerError SO.service_unit(
        service,
        ["/bin/echo"],
        Dict("bad-key" => "x"),
        "/tmp",
        Dict("cpus" => [2], "leader-cpu" => 2),
    )
    @test_throws SO.OwnerError SO.service_unit(
        service,
        ["/bin/echo"],
        Dict("KEY" => "bad\0value"),
        "/tmp",
        Dict("cpus" => [2], "leader-cpu" => 2),
    )
    @test_throws SO.OwnerError SO.service_unit(
        service, ["/bin/echo"], Dict(), "relative", Dict("cpus" => [2], "leader-cpu" => 2)
    )
    @test_throws SO.OwnerError SO.service_unit(
        service,
        ["/bin/echo"],
        Dict(),
        "/missing-owner-cwd",
        Dict("cpus" => [2], "leader-cpu" => 2),
    )
    @test_throws SO.OwnerError SO.service_unit(
        service, ["/bin/echo"], Dict(), "/tmp", Dict("cpus" => [0, 2], "leader-cpu" => 2)
    )
    @test_throws SO.OwnerError SO.service_unit(
        service, ["echo"], Dict(), "/tmp", Dict("cpus" => [2], "leader-cpu" => 2)
    )
end

@testset "cohort service dependencies and target job filtering" begin
    core = "pipewireao-owner-$(INVOCATION)-core.service"
    source = "pipewireao-owner-$(INVOCATION)-source-owner.service"
    target = SO.cohort_name(INVOCATION)
    unit = SO.cohort_unit(INVOCATION, [core, source])
    @test "Wants=$core $source" in split(unit, '\n')
    @test "After=$core $source" in split(unit, '\n')
    @test_throws SO.OwnerError SO.cohort_unit(INVOCATION, [core, core])
    @test_throws SO.OwnerError SO.cohort_unit(
        INVOCATION, ["pipewireao-owner-ffffffffffffffffffffffffffffffff-core.service"]
    )
    @test_throws SO.OwnerError SO.cohort_unit(
        INVOCATION, ["pipewireao-owner-$(INVOCATION)-bad.role.service"]
    )
    jobs =
        "82 $core start running\n" *
        "83 $target start waiting\n" *
        "84 $target stop waiting\n" *
        "85 pipewireao-owner-ffffffffffffffffffffffffffffffff-core.service start waiting\n" *
        "86 pipewireao-owner-$(INVOCATION)f-cohort.target start waiting\n"
    @test SO.parse_jobs(jobs, INVOCATION) == ["82" => core, "83" => target]
end

@testset "retained owner identity and recursive cgroup evidence" begin
    owner = SO.Coordinator(
        "pipewireao-rtc@test.service", INVOCATION, "/user.slice/core.service"
    )
    service = SO.Service(owner, "core")
    service.main_pid = getpid()
    service.start_ticks = SO.start_ticks(getpid())
    service.cgroup = SO.proc_cgroup(getpid())
    service.invocation = INVOCATION
    SO.running!(service)
    @test SO.alive(service)
    @test !SO.process_identity(getpid(), service.start_ticks + 1, service.cgroup)
    @test SO.old_process_exists(getpid(), service.start_ticks)
    values = Dict(
        "InvocationID" => INVOCATION,
        "ControlGroup" => service.cgroup,
        "MainPID" => string(getpid()),
    )
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
    @test SO.parse_properties("Id=unit.service\nExecStopPost=argv[]=x=y\n")["ExecStopPost"] ==
        "argv[]=x=y"
    @test_throws SO.OwnerError SO.parse_properties("Id=a\nId=b\n")
end

module OwnerClockBoundary
import Clocks
import PipeWireAORTC
const deadline_ns = PipeWireAORTC.SystemdOwners.deadline_ns
const fail = PipeWireAORTC.SystemdOwners.fail
const empty = Ref(false)
const probes = Ref(0)
cgroup_empty(group) = (probes[] += 1; empty[])
module Common
const calls = Any[]
run_checked(argv; kwargs...) = (push!(calls, (; argv, kwargs...)); (; returncode = 0))
end
for name in ("checked", "wait_empty")
    source = read(
        joinpath(pkgdir(PipeWireAORTC), "src/deployment/systemd_owners.jl"), String
    )
    position = first(findfirst("function " * name * "(", source))
    expression, _ = Meta.parse(source, position)
    Core.eval(@__MODULE__, expression)
end
end

import Clocks
mutable struct OwnerClock <: Clocks.AbstractNanoClock
    ticks::Vector{Int64}
    reads::Int
end
OwnerClock(ticks::Int64...) = OwnerClock(collect(ticks), 0)
function Clocks.time_nanos(clock::OwnerClock)
    clock.reads += 1
    return clock.ticks[min(clock.reads, length(clock.ticks))]
end

@testset "Signed owner waits and subprocess budgets preserve clock boundaries" begin
    B = OwnerClockBoundary
    for origin in (Int64(-10), Int64(0), Int64(2)^53 + 1)
        clock = OwnerClock(origin, origin + 1)
        B.empty[] = false
        B.probes[] = 0
        @test !B.wait_empty("unused", origin + 1; clock)
        @test clock.reads == 2 && B.probes[] == 2
        clock = OwnerClock(origin)
        B.empty[] = true
        @test B.wait_empty("unused", origin + 1; clock)
        @test clock.reads == 1
        empty!(B.Common.calls)
        clock = OwnerClock(origin)
        @test B.checked(["unused"]; deadline = origin + 1, clock).returncode == 0
        @test only(B.Common.calls).timeout === 1.0e-9 && clock.reads == 1
        empty!(B.Common.calls)
        @test_throws SO.OwnerError B.checked(["unused"]; deadline = origin, clock)
        @test isempty(B.Common.calls)
    end
    B.empty[] = false
    clock = OwnerClock(Int64(-10), Int64(-11))
    @test_throws SO.OwnerError B.wait_empty("unused", Int64(-9); clock)
    @test clock.reads == 2
    empty!(B.Common.calls)
    @test_throws OverflowError B.checked(
        ["unused"];
        deadline = typemax(Int64),
        clock = Clocks.CachedNanoClock(typemin(Int64)),
    )
    @test isempty(B.Common.calls)
    @test SO.deadline_ns(1.25) === Int64(1_250_000_000)
    @test SO.deadline_ns(Int64(2)^53 + 1) === Int64(2)^53 + 1
    for invalid in (Inf, -Inf, NaN)
        @test_throws SO.OwnerError SO.deadline_ns(invalid)
        @test_throws SO.OwnerError SO.duration_ns(invalid)
    end
    service = ServiceBoundary.service()
    ServiceBoundary.S.running!(service)
    @test_throws OverflowError ServiceBoundary.S.stop!(
        service, 1; clock = Clocks.CachedNanoClock(typemax(Int64))
    )
    @test service.state === :stop_failed
    @test isempty(ServiceBoundary.S.test_calls)
end
