# Opt-in integration using only uniquely named transient units and CPU 0.
using Test, PipeWireAORTC, UUIDs
import Clocks
import Sockets

const S = PipeWireAORTC.SystemdOwners
const L = PipeWireAORTC.SessionLaunch
const Runtime = PipeWireAORTC.SessionRuntime

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

@testset "Systemd bus authentication respects the $operation deadline" for operation in
    ("admission", "unit reference")
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
            unit = "silent-bus.service"
            deadline = Clocks.time_nanos(clock) + 1_000_000_000
            if only(ARGS) == "admission"
                manager = S.UserManager((unit,); deadline, clock)
                close(manager)
            else
                S.with_unit_reference(unit; deadline, clock) do
                    error("silent bus unexpectedly acquired a unit reference")
                end
            end
            error("silent bus unexpectedly accepted authentication")
        catch err
            err isa S.OwnerError && occursin("exceeded its deadline", err.message) || rethrow()
        end
        """
        cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing
            --threads=1 --compile=min -O0 --project=$project -e $script $operation`
        process = run(addenv(cmd, "DBUS_SESSION_BUS_ADDRESS" => "unix:path=$path"); wait = false)
        peer = nothing
        try
            @test timedwait(() -> istaskdone(accepted) || process_exited(process), 60) == :ok
            @test timedwait(() -> istaskdone(accepted), 1) == :ok
            if istaskdone(accepted)
                peer = fetch(accepted)
                @test timedwait(() -> process_exited(process), 2.5) == :ok
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

include("control_private_core.jl")

@testset "A unit reference retains the exact exit result after native Quit" begin
    C = PipeWireAORTC.Common
    Client = PipeWireAORTC.ControlClient
    CLI = PipeWireAORTC.SessionCLI
    profile = PipeWireAORTC.SessionProfile.Profile()
    quit = PipeWireAORTC.SessionCodec.RunnerCommand(:quit)
    user_runtime = ENV["XDG_RUNTIME_DIR"]
    user_bus = get(ENV, "DBUS_SESSION_BUS_ADDRESS", "unix:path=" * joinpath(user_runtime, "bus"))
    unit = "codex-rtc-unit-reference-$(uuid4()).service"
    clock = Clocks.SystemNanoClock()
    with_control_private_core() do remote, directory, _
        chmod(dirname(remote), 0o700)
        env = ["--setenv=$key=$(ENV[key])" for key in (
            "PIPEWIREAO_CONFIG_DIR", "PIPEWIREAO_MODULE_DIR", "PIPEWIREAO_SPA_PLUGIN_DIR",
            "LD_LIBRARY_PATH",
        )]
        withenv("XDG_RUNTIME_DIR" => user_runtime, "DBUS_SESSION_BUS_ADDRESS" => user_bus) do
            julia = Base.julia_cmd().exec[1]
            project = dirname(@__DIR__)
            owner = joinpath(@__DIR__, "systemd_stop_owner.jl")
            try
                run(`systemd-run --user --quiet --collect --unit=$unit --property=Type=exec
                    --property=CPUAffinity=0 --property=RuntimeMaxSec=120s --property=TimeoutStopSec=5s
                    $env $julia --startup-file=no --compiled-modules=existing --threads=1
                    --project=$project -O0 $owner $directory $remote $unit normal`)
                wait_proof(() -> isfile(joinpath(directory, "ready")), 60, "native Quit owner")
                active = S.properties(unit)
                invocation = active["InvocationID"]
                pid = S.parsed_pid(active)
                handle = Runtime.Handle(unit, directory, invocation, pid, S.start_ticks(pid),
                    active["ControlGroup"], false, nothing)
                record = C.read_json(joinpath(directory, invocation, "launch.json"))
                extra = "Result,ExecMainCode,ExecMainStatus,ExecMainPID"
                deadline = Clocks.time_nanos(clock) + 30_000_000_000
                S.with_unit_reference(unit; deadline, clock) do
                    touch(joinpath(directory, "adopt-command"))
                    client = Client.connect(profile, remote, "pipewireao.rtc.session.stop-test",
                        UInt32(pid), Int64(record["session_control_instance"]); deadline, clock)
                    try
                        @test CLI.confirm_shutdown(Client.request!(client, quit; deadline)) === nothing
                    finally
                        close(client)
                    end
                    wait_proof(10, "referenced unit exit") do
                        S.properties(unit; deadline, clock)["ActiveState"] == "inactive"
                    end
                    stopped = S.properties(unit; extra, deadline, clock)
                    @test Runtime._verify_direct_unit_exit(handle, stopped) === nothing
                    @test isfile(joinpath(directory, "terminal-consumed"))
                end
                @test timedwait(() -> S.properties(unit)["LoadState"] == "not-found", 5) == :ok
            finally
                success(pipeline(systemctl("stop", unit); stderr = devnull))
                success(pipeline(systemctl("reset-failed", unit); stderr = devnull))
            end
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
