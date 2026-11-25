# Opt-in integration using only uniquely named transient units and CPU 0.
using Test, PipeWireAORTC, UUIDs
import Clocks
import Sockets

const S = PipeWireAORTC.SystemdOwners
const L = PipeWireAORTC.SessionLaunch

systemctl(args...) = Cmd(["systemctl", "--user", args...])

function start_fixture(unit, stop; post = nothing)
    args = [
        "systemd-run", "--user", "--quiet", "--collect", "--unit=$unit",
        "--property=Type=exec", "--property=CPUAffinity=0",
        "--property=TimeoutStopSec=5s", "--property=ExecStop=$stop",
    ]
    post === nothing || push!(args, "--property=ExecStopPost=$post")
    run(Cmd([args; "/usr/bin/sleep"; "60"]))
    return nothing
end

@testset "Systemd bus authentication respects the operation deadline" begin
    mktempdir() do directory
        path = joinpath(directory, "silent-bus")
        server = Sockets.listen(path)
        accepted = @async Sockets.accept(server)
        project = dirname(@__DIR__)
        script = """
        using PipeWireAORTC
        import Clocks
        S = PipeWireAORTC.SystemdOwners
        clock = Clocks.SystemNanoClock()
        try
            deadline = Clocks.time_nanos(clock) + 400_000_000
            manager = S.UserManager(("silent-bus.service",); deadline, clock)
            close(manager)
            error("silent bus unexpectedly accepted authentication")
        catch err
            err isa S.OwnerError && occursin("exceeded its deadline", err.message) || rethrow()
        end
        """
        cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing
            --threads=1 --project=$project -e $script`
        process = run(addenv(cmd, "DBUS_SESSION_BUS_ADDRESS" => "unix:path=$path"); wait = false)
        peer = nothing
        try
            @test timedwait(() -> istaskdone(accepted) || process_exited(process), 60) == :ok
            @test istaskdone(accepted)
            if istaskdone(accepted)
                peer = fetch(accepted)
                @test timedwait(() -> process_exited(process), 1.5) == :ok
                @test process_exited(process) && success(process)
            end
        finally
            process_exited(process) || kill(process, Base.SIGKILL)
            wait(process)
            peer === nothing || close(peer)
            close(server)
        end
    end
end

@testset "Native systemd admission snapshots" begin
    tag = string(uuid4())
    unit = "codex-rtc-unit-bus-$tag.service"
    wrong_unit = "codex-rtc-unit-bus-$tag-wrong.service"
    failed_unit = "codex-rtc-unit-bus-$tag-failed.service"
    launcher = "/usr/bin/true"
    clock = Clocks.SystemNanoClock()
    mktempdir() do root
        manager = S.UserManager((unit, wrong_unit, failed_unit); clock)
        try
            extra = "FragmentPath,DropInPaths,NeedDaemonReload,ExecStop,ExecStopPost," *
                    "Type,NotifyAccess,Restart,KillMode"
            absent = S.unit_properties(manager, unit; extra, clock)
            @test absent["LoadState"] == "not-found"
            @test absent["ActiveState"] == "inactive"
            @test absent["MainPID"] === 0
            @test absent["InvocationID"] == ""
            @test absent["ExecStop"] isa Vector{S.ExecCommand}
            @test isempty(absent["ExecStop"]) && isempty(absent["ExecStopPost"])

            start_fixture(unit, "$launcher stop --unit $unit --runtime-root $root --direct")
            active = S.unit_properties(manager, unit; extra, clock)
            legacy = S.properties(unit; extra, clock)
            for field in ("Id", "LoadState", "ActiveState", "InvocationID", "ControlGroup",
                          "FragmentPath", "Type", "NotifyAccess", "Restart", "KillMode")
                @test active[field] == legacy[field]
            end
            @test active["MainPID"] === parse(Int, legacy["MainPID"]) > 0
            @test active["NeedDaemonReload"] === false
            @test active["DropInPaths"] isa Vector{String}
            @test isempty(active["DropInPaths"]) && isempty(active["ExecStopPost"])
            request = L.Request(root, root, unit, launcher, root)
            @test L.stop_hook_valid(active["ExecStop"], request; direct = true)
            @test L.stop_hook_valid(legacy["ExecStop"], request; direct = true)

            service = S.Service(S.Coordinator(unit, active["InvocationID"], active["ControlGroup"]), "probe")
            service.unit = unit
            S.retain!(service, active)
            @test S.verify!(manager, service; clock) === service

            # systemctl displays the same argv text for --unit and its value
            # when they are separate arguments or a single quoted argument.
            start_fixture(
                wrong_unit, "$launcher stop \"--unit $wrong_unit\" --runtime-root $root --direct";
                post = "-$launcher \"after stop\" \"\"",
            )
            wrong_request = L.Request(root, root, wrong_unit, launcher, root)
            wrong = S.unit_properties(manager, wrong_unit; extra, clock)
            @test L.stop_hook_valid(
                S.properties(wrong_unit; extra = "ExecStop", clock)["ExecStop"],
                wrong_request; direct = true,
            )
            @test !L.stop_hook_valid(wrong["ExecStop"], wrong_request; direct = true)
            cleanup = only(wrong["ExecStopPost"])
            @test cleanup.path == launcher
            @test cleanup.argv == [launcher, "after stop", ""]
            @test cleanup.ignore_failure

            failure = Cmd([
                "systemd-run", "--user", "--quiet", "--unit=$failed_unit",
                "--property=Type=oneshot", "--property=CPUAffinity=0",
                "--property=TimeoutStartSec=5s", "/usr/bin/false",
            ])
            @test !success(pipeline(failure; stderr = devnull))
            failed = S.unit_properties(manager, failed_unit; clock)
            @test failed["LoadState"] == "loaded"
            @test failed["ActiveState"] == "failed"
            @test failed["MainPID"] === 0
            @test !isempty(failed["InvocationID"])

            @test_throws S.OwnerError S.unit_properties(
                manager, unit; deadline = Clocks.time_nanos(clock), clock,
            )
            @test !S.check_unit_changes!(manager; clock)
            run(systemctl("restart", unit))
            @test timedwait(() -> S.check_unit_changes!(manager; clock), 5) == :ok
            @test_throws S.OwnerError S.verify!(manager, service; clock)
            @test_throws S.OwnerError S.check_unit_changes!(manager; clock)

            # Observe a separate unit's removal without restarting the bus or
            # changing the configuration of any other user-managed unit.
            removal = S.UserManager((wrong_unit,); clock)
            try
                S.unit_properties(removal, wrong_unit; clock)
                run(systemctl("stop", wrong_unit))
                @test timedwait(5) do
                    try
                        S.check_unit_changes!(removal; clock)
                        false
                    catch error
                        error isa S.OwnerError || rethrow()
                        occursin("removed watched unit", error.message)
                    end
                end == :ok
            finally
                close(removal)
            end
        finally
            close(manager)
            close(manager)
            for name in (unit, wrong_unit, failed_unit)
                success(pipeline(systemctl("stop", name); stderr = devnull))
                success(pipeline(systemctl("reset-failed", name); stderr = devnull))
            end
        end
        @test_throws S.OwnerError S.unit_properties(manager, unit; clock)
    end
end
