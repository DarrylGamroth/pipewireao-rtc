using Test, PipeWireAORTC
import Clocks
const Runtime = PipeWireAORTC.SessionRuntime

@testset "Failed start cleanup requires the same invocation and a completed ledger" begin
    C = PipeWireAORTC.Common
    for replacement in (false, true)
        mktempdir() do directory
            unit = "pipewireao-session@fixture.service"
            invocation = "a"^32
            fragment = joinpath(directory, unit)
            write(fragment, "[Unit]\nDescription=Fixture\n")
            user = mkpath(joinpath(directory, "systemd", "user"))
            link = joinpath(user, unit)
            symlink(fragment, link)
            root = joinpath(directory, "rtc-runtime")
            runtime = mkpath(joinpath(root, invocation))
            ledger = Dict{String,Any}(
                "version" => PipeWireAORTC.SessionLaunch.LEDGER_VERSION,
                "unit" => unit,
                "runtime" => runtime,
                "invocation" => invocation,
                "cleanup_complete" => true,
                "owners" => Dict(),
            )
            C.write_json(joinpath(runtime, "launch.json"), ledger)
            stopped = joinpath(directory, "stop-requested")
            systemctl = joinpath(directory, "systemctl")
            write(
                systemctl,
                raw"""
   #!/bin/sh
   [ "$1" = --user ] || exit 2
   case "$2" in
       show)
           [ "$5" = "$RTC_TEST_UNIT" ] || exit 2
           state=activating
           invocation="$RTC_TEST_INVOCATION"
           if [ -f "$RTC_TEST_STOPPED" ]; then
               state=failed
               invocation="$RTC_TEST_POST_STOP_INVOCATION"
           fi
           printf '%s\n' "Id=$5" 'LoadState=loaded' "ActiveState=$state" \
               'MainPID=0' "InvocationID=$invocation" 'ControlGroup=' \
               "FragmentPath=$RTC_TEST_FRAGMENT"
           ;;
       stop)
           [ "$3" = "$RTC_TEST_UNIT" ] || exit 2
           : > "$RTC_TEST_STOPPED"
           printf '%s\n' 'manager stopped the unit but lost the acknowledgement' >&2
           exit 1
           ;;
       list-units|list-jobs) ;;
       disable)
           [ "$3" = --runtime ] && [ "$4" = "$RTC_TEST_UNIT" ] || exit 2
           /bin/rm -- "$RTC_TEST_LINK"
           ;;
       *) exit 2 ;;
   esac
   """,
            )
            chmod(systemctl, 0o700)
            failure = ErrorException("session failed to start")
            withenv(
                "PATH" => directory,
                "XDG_RUNTIME_DIR" => directory,
                "RTC_TEST_UNIT" => unit,
                "RTC_TEST_INVOCATION" => invocation,
                "RTC_TEST_POST_STOP_INVOCATION" => (replacement ? "b"^32 : invocation),
                "RTC_TEST_FRAGMENT" => fragment,
                "RTC_TEST_LINK" => link,
                "RTC_TEST_STOPPED" => stopped,
            ) do
                if replacement
                    @test_throws "failed session invocation changed during cleanup" (Runtime._reconcile_failed_start!(
                        directory, unit, root, fragment, true, failure
                    ))
                    @test islink(link)
                    @test !isfile(joinpath(directory, "start-failure.json"))
                    @test !isfile(joinpath(directory, "final-launch.json"))
                else
                    @test Runtime._reconcile_failed_start!(
                        directory, unit, root, fragment, true, failure
                    ) === nothing
                    @test !islink(link)
                    @test C.read_json(joinpath(directory, "final-launch.json")) == ledger
                    receipt = C.read_json(joinpath(directory, "start-failure.json"))
                    @test receipt["cleanup_confirmed"] === true
                    @test receipt["invocation"] == invocation
                    @test receipt["failure"] == "session failed to start"
                    @test occursin(
                        "lost the acknowledgement", receipt["stop_command_error"]
                    )
                end
            end
            @test isfile(stopped)
            @test isfile(fragment)
        end
    end
end

@testset "direct attach retains only the current unit incarnation" begin
    CLI = PipeWireAORTC.SessionCLI
    C = PipeWireAORTC.Common
    mktempdir() do directory
        withenv("XDG_RUNTIME_DIR" => directory) do
            unit = "pipewireao-session@fixture.service"
            root = mkdir(Runtime.runtime_directory(unit))
            invocation = "a"^32
            replacement = "b"^32
            handle = Runtime.Handle(unit, root, invocation, 120, UInt64(7), "/fixture", false, nothing)
            args = (; unit, runtime_root = root, direct = true)
            path = joinpath(root, "launch.json")
            record = Dict{String,Any}(
                "version" => 2,
                "direct_attach" => true,
                "unit" => unit,
                "invocation" => invocation,
                "runtime" => root,
                "session_pid" => handle.main_pid,
                "session_start_ticks" => handle.start_ticks,
                "phase" => "prepared",
            )

            @test CLI._direct_stop_record(args, invocation; missing_ok = true) === nothing
            C.write_json(path, record; atomic = true)
            @test Runtime._retained_ledger(handle) == record
            @test CLI._direct_stop_record(args, replacement; missing_ok = true) === nothing
            @test_throws ArgumentError CLI._record_direct_stop!(args, replacement, 120, UInt64(7))
            @test_throws ArgumentError CLI._record_direct_stop!(args, invocation, 120, UInt64(7))
            @test C.read_json(path) == record

            record["phase"] = "stopped"
            record["cleanup_complete"] = true
            C.write_json(path, record; atomic = true)
            @test_throws ArgumentError CLI._record_direct_stop!(args, invocation, 120, UInt64(9))
            @test CLI._record_direct_stop!(args, invocation, 120, UInt64(7)) === nothing
            stopped = Runtime.final_record(root; invocation, unit)
            @test stopped["systemd_quit"] == Dict("attempted" => true, "accepted" => true)

            record["invocation"] = replacement
            C.write_json(path, record; atomic = true)
            @test_throws ArgumentError Runtime._retained_ledger(handle)
            @test_throws ArgumentError Runtime.final_record(root; invocation, unit)
            @test readdir(root) == ["launch.json"]
        end
    end
end

@testset "Final reports honor the supplied unit and invocation" begin
    C = PipeWireAORTC.Common
    mktempdir() do directory
        withenv("XDG_RUNTIME_DIR" => directory) do
            unit = "pipewireao-session@report.service"
            wrong_unit = "pipewireao-session@other.service"
            invocation = "a"^32
            wrong_invocation = "b"^32
            root = mkdir(Runtime.runtime_directory(unit))
            stage = mkdir(joinpath(directory, "stage"))
            record = Dict(
                "version" => 2, "direct_attach" => true, "phase" => "stopped",
                "unit" => unit, "invocation" => invocation, "runtime" => root,
            )
            C.write_json(joinpath(root, "launch.json"), record)
            C.write_json(joinpath(stage, "session.json"), Dict(
                "unit" => unit, "invocation" => invocation, "runtime_root" => root,
            ))

            @test Runtime.final_record(root; unit, invocation) == record
            @test_throws ArgumentError Runtime.final_record(root)
            @test_throws ArgumentError Runtime.final_record(root; unit)
            @test_throws ArgumentError Runtime.final_record(root; invocation)
            @test_throws ArgumentError Runtime.final_record(root; unit = wrong_unit, invocation)
            @test_throws ArgumentError Runtime.final_record(root; unit, invocation = wrong_invocation)

            for retained in (false, true)
                if retained
                    record["service_result"] = "success"
                    C.write_json(joinpath(stage, "final-launch.json"), record)
                end
                @test Runtime.final_record(stage) == record
                @test Runtime.final_record(stage; unit) == record
                @test Runtime.final_record(stage; invocation) == record
                @test Runtime.final_record(stage; unit, invocation = uppercase(invocation)) == record
                @test_throws ArgumentError Runtime.final_record(stage; unit = wrong_unit)
                @test_throws ArgumentError Runtime.final_record(stage; invocation = wrong_invocation)
            end
        end
    end
end

@testset "staging uses exact instance names for installed support units" begin
    mktempdir() do directory
        unit = joinpath(directory, "pipewireao-session@fixture.service")
        template = joinpath(directory, "pipewireao-parameters-instrument@.service")
        write(unit, "[Unit]\nWants=pipewireao-parameters-instrument@%i.service unrelated.service\n")
        @test Runtime._stage_support_units(unit) == [
            "pipewireao-parameters-instrument@fixture.service" => template,
        ]
    end
end

@testset "direct manager exit and scoped-service cleanup require live proof" begin
    handle = Runtime.Handle("pipewireao-session@fixture.service", "/runtime", "a"^32,
        120, UInt64(7), "/fixture", true, nothing)
    stopped = Dict("LoadState" => "loaded", "ActiveState" => "inactive", "MainPID" => "0",
        "InvocationID" => handle.invocation, "ExecMainPID" => "120", "ExecMainCode" => "1",
        "ExecMainStatus" => "0", "Result" => "success")
    @test Runtime._verify_direct_unit_exit(handle, stopped) === nothing
    for pair in ("Result" => "exit-code", "ActiveState" => "failed", "InvocationID" => "",
                 "InvocationID" => "b"^32, "ExecMainPID" => "0", "ExecMainStatus" => "1")
        @test_throws ArgumentError Runtime._verify_direct_unit_exit(handle, merge(stopped, Dict(pair)))
    end
    analysis = "pipewireao-analysis-instrument-observer@fixture.service"
    # A manager reload may replace Wants while this invocation is shutting down.
    receipt = Dict("scoped_services" => [analysis])
    stopped["Wants"] = "pipewireao-analysis-replacement@fixture.service"
    @test Runtime._direct_scoped_units(handle, receipt) == [analysis]
    @test_throws ArgumentError Runtime._direct_scoped_units(handle,
        Dict("scoped_services" => [replace(analysis, "@fixture" => "@other")]))
    owner = Dict("LoadState" => "loaded", "ActiveState" => "deactivating", "MainPID" => "121",
        "PartOf" => handle.unit, "ControlGroup" => "/fixture-analysis")
    @test !Runtime._scoped_unit_quiet(handle, owner)
    @test !Runtime._scoped_unit_quiet(handle, merge(owner, Dict("MainPID" => "0")))
    @test Runtime._scoped_unit_quiet(handle, merge(owner, Dict("ActiveState" => "inactive",
        "MainPID" => "0", "ControlGroup" => "")))
    @test_throws ArgumentError Runtime._scoped_unit_quiet(handle,
        merge(owner, Dict("PartOf" => "pipewireao-session@other.service")))
end

source_endpoint(profile, instance) = Dict{String,Any}(
    "control-protocol" => profile,
    "control-node" => "simulator-wfs",
    "control-instance" => instance,
)

@testset "readiness accepts the declared native source profile" begin
    for profile in (
        "pipewireao.rtc.calibration-lifecycle/1",
        "pipewireao.rtc.correction-lifecycle/1",
        "pipewireao.source-control/1",
    )
        source = source_endpoint(profile, "19")
        @test Runtime._source_endpoint(source) ==
            Dict("node" => "simulator-wfs", "instance" => Int64(19), "profile" => profile)
        if PipeWireAORTC.DeploymentConfiguration.uses_source_control_protocol(source)
            # Native source owners publish their live mailbox incarnation;
            # SessionLaunch does not reserve an acquisition control-instance.
            source["control-instance"] = nothing
            @test Runtime._source_endpoint(source) == Dict(
                "node" => "simulator-wfs", "instance" => nothing, "profile" => profile
            )
        else
            source["control-instance"] = nothing
            @test_throws ArgumentError Runtime._source_endpoint(source)
        end
        for invalid in
            (0, -1, "", "not-an-instance", "1.0", string(big(typemax(Int64)) + 1))
            source["control-instance"] = invalid
            @test_throws ArgumentError Runtime._source_endpoint(source)
        end
        for node in (nothing, "", "source with spaces", "a"^129)
            source["control-instance"] = "19"
            source["control-node"] = node
            @test_throws ArgumentError Runtime._source_endpoint(source)
        end
    end
    for profile in (nothing, "", "pipewireao.source-control/2", "pipewireao.rtc.heart/1")
        @test_throws ArgumentError Runtime._source_endpoint(source_endpoint(profile, "19"))
    end
end

@testset "source Status remains calibration-specific" begin
    # Invalid profiles must fail before any connection or process lookup.
    for profile in
        ("pipewireao.source-control/1", "pipewireao.rtc.correction-lifecycle/1", "unknown")
        record = Dict("source_endpoint" => Dict("profile" => profile))
        @test_throws ArgumentError Runtime.source_status(record, "classic"; deadline = 0)
    end
    @test_throws ArgumentError Runtime.source_status(Dict(), "unsupported"; deadline = 0)
end

mutable struct SessionWaitClock <: Clocks.AbstractNanoClock
    ticks::Vector{Int64}
    reads::Int
end
SessionWaitClock(ticks::Int64...) = SessionWaitClock(collect(ticks), 0)
function Clocks.time_nanos(clock::SessionWaitClock)
    clock.reads += 1
    return clock.ticks[min(clock.reads, length(clock.ticks))]
end

@testset "Signed runtime deadline arithmetic" begin
    for origin in (Int64(-10), Int64(0), Int64(2)^53 + 1)
        @test Runtime.remaining(origin + 1, 1, origin) === 1.0e-9
        @test_throws ArgumentError Runtime.remaining(origin, 1, origin)
    end
    @test_throws OverflowError Runtime.remaining(typemax(Int64), 1, typemin(Int64))
    for limit in (0, -1, NaN, Inf, 1.0e-10)
        @test_throws ArgumentError Runtime.remaining(Int64(1), limit, Int64(0))
    end
    @test_throws OverflowError PipeWireAORTC.SessionCLI.control_session(
        "unused", ["status"]; timeout = 1, clock = Clocks.CachedNanoClock(typemax(Int64))
    )
    S = PipeWireAORTC.SystemdOwners
    @test_throws S.OwnerError S.with_unit_reference(
        () -> error("expired reference invoked its callback"), "unused.service";
        deadline = typemax(Int64), clock = Clocks.CachedNanoClock(typemax(Int64)),
    )
end

module CoreClockBoundary
import Clocks
import PipeWireAORTC
const fail = PipeWireAORTC.SessionLaunch.fail
module S
import PipeWireAORTC.SystemdOwners: duration_ns
const calls = Ref(0)
alive(service) = (calls[] += 1; false)
end
source = read(joinpath(pkgdir(PipeWireAORTC), "src/deployment/session_launch.jl"), String)
position = first(findfirst("function wait_core!(", source))
expression, _ = Meta.parse(source, position)
Core.eval(@__MODULE__, expression)
end

@testset "Private core setup rejects signed expiry, regression and overflow" begin
    B = CoreClockBoundary
    for origin in (Int64(-10), Int64(0), Int64(2)^53 + 1)
        B.S.calls[] = 0
        clock = SessionWaitClock(origin)
        @test_throws PipeWireAORTC.SessionLaunch.LaunchError B.wait_core!(
            nothing, "unused"; clock
        )
        @test clock.reads == 2 && B.S.calls[] == 1
        B.S.calls[] = 0
        clock = SessionWaitClock(origin, origin + 1)
        @test_throws PipeWireAORTC.SessionLaunch.LaunchError B.wait_core!(
            nothing, "unused"; seconds = 1.0e-9, clock
        )
        @test clock.reads == 2 && B.S.calls[] == 0
    end
    B.S.calls[] = 0
    clock = SessionWaitClock(Int64(-10), Int64(-11))
    @test_throws PipeWireAORTC.SessionLaunch.LaunchError B.wait_core!(
        nothing, "unused"; clock
    )
    @test clock.reads == 2 && B.S.calls[] == 0
    @test_throws OverflowError B.wait_core!(
        nothing, "unused"; clock = Clocks.CachedNanoClock(typemax(Int64))
    )
    @test B.S.calls[] == 0
end
