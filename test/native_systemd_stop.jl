# Opt-in integration: owns only its uniquely named user units/private core.
# CPU 12/13, no CUDA, no science/hardware or installed live sessions.
using Test, PipeWireAODeployment, JSON3
include("native_control_private_core.jl")
const C = PipeWireAODeployment.Common
const S = PipeWireAODeployment.SystemdOwners
const repo = dirname(@__DIR__)
const julia = Base.julia_cmd().exec[1]
const baseline = "--baseline" in ARGS
const user_runtime = ENV["XDG_RUNTIME_DIR"]
const user_bus = get(ENV, "DBUS_SESSION_BUS_ADDRESS", "unix:path=" * joinpath(ENV["XDG_RUNTIME_DIR"], "bus"))
const evidence = joinpath(get(ENV, "RTC_STOP_EVIDENCE_ROOT", dirname(tempdir())),
    "systemd-stop-$(getpid())-$(baseline ? "before" : "after")")
mkpath(evidence)

function stop_case(remote, directory, mode)
    root = joinpath(directory, "stop-" * mode)
    mkpath(root)
    unit = "codex-rtc-stop-$(getpid())-$(mode).service"
    fragment = joinpath(root, unit)
    hook = "ExecStop=$julia --startup-file=no --project=$repo $repo/test/native_systemd_stop_launcher.jl $repo/wireplumber_cli.jl $root stop --unit $unit --runtime-root $root"
    environment = join(["Environment=" * String(JSON3.write(key * "=" * ENV[key]))
        for key in ("PIPEWIREAO_CONFIG_DIR", "PIPEWIREAO_MODULE_DIR", "PIPEWIREAO_SPA_PLUGIN_DIR", "LD_LIBRARY_PATH")], '\n')
    write(fragment, """
    [Service]
    Type=exec
    ExecStart=$julia --startup-file=no --project=$repo $repo/test/native_systemd_stop_owner.jl $root $remote $unit $mode
    $(baseline ? "" : hook)
    ExecStopPost=/usr/bin/touch $root/cleanup
    KillMode=control-group
    # Test-only forced revocation: Julia signal diagnostics/finalizers are a
    # separate behavior from retaining authority through the native request.
    KillSignal=SIGKILL
    CPUAffinity=12 13
    TimeoutStartSec=30
    TimeoutStopSec=300
    Restart=no
    $environment
    """)
    link = joinpath(homedir(), ".config/systemd/user", unit)
    ispath(link) || islink(link) ? error("test unit already exists") : nothing
    mkpath(dirname(link))
    symlink(fragment, link)
    try
        run(`systemctl --user daemon-reload`)
        run(`systemctl --user start $unit`)
        wait_proof(() -> isfile(joinpath(root, "ready")), 30, "test session readiness")
        record_dirs = filter(name -> occursin(r"^[0-9a-f]{32}$", name), readdir(root))
        @test length(record_dirs) == 1
        ledger = joinpath(root, only(record_dirs), "launch.json")
        record = C.read_json(ledger)
        if mode == "wrong-pid"
            record["wireplumber_pid"] += 1
        elseif mode == "wrong-ticks"
            record["wireplumber_start_ticks"] += 1
        elseif mode == "wrong-uuid"
            record["session_uuid"] = "b5555555-5555-4555-8555-555555555555"
        elseif mode == "submitted"
            record["systemd_quit"] = Dict("attempted"=>true, "accepted"=>false)
        end
        C.write_json(ledger, record; atomic=true)
        mode == "missing-ledger" && rm(ledger)
        if mode == "exited"
            write(joinpath(root, "exit-owner"), "1")
            wait_proof(() -> S.properties(unit)["MainPID"] == "0", 30, "naturally exited owner")
        end
        # The test gates one already admitted frame/command at Quit entry.
        stopping = run(`systemctl --user stop $unit`; wait=false)
        if mode == "normal"
            # Separate new Julia process/code preparation from the owner's
            # actual eight-second native request. Production uses this same
            # 300-second service stop bound; no request deadline is extended.
            deadline = time_ns()/1e9 + 120
            while !isfile(joinpath(root, "quit-entry")) && !Base.process_exited(stopping) && time_ns()/1e9 < deadline
                sleep(0.005)
            end
            baseline && println("SYSTEMD_STOP_BASELINE owner_revoked=$(Base.process_exited(stopping)) quit_entered=$(isfile(joinpath(root, "quit-entry"))) command_adopted=$(isfile(joinpath(root, "command-adopted")))")
            @test isfile(joinpath(root, "quit-entry"))
            isfile(joinpath(root, "quit-entry")) || error("systemd revoked the session before native Quit drained its command")
            @test !Base.process_exited(stopping)
            @test !isfile(joinpath(root, "graph-stopped"))
            write(joinpath(root, "adopt-command"), "1")
        end
        wait_proof(() -> Base.process_exited(stopping), 120, "bounded ExecStop cleanup")
        wait(stopping)
        @test isfile(joinpath(root, "cleanup"))
        values = S.properties(unit; extra="Result")
        @test values["MainPID"] == "0"
        @test S.quiescent_unit(unit)
        @test values["Result"] == (mode in ("normal", "exited") ? "success" : "exit-code")
        mode == "missing-ledger" || (record = C.read_json(ledger))
        submissions_path = joinpath(root, "quit-submissions")
        submissions = isfile(submissions_path) ? length(readlines(submissions_path)) : 0
        @test submissions == (mode in ("normal", "unknown") ? 1 : 0)
        if mode == "normal"
            @test success(stopping)
            @test record["systemd_quit"]["accepted"] === true
            events = ["quit-entry", "command-adopted", "graph-stopped", "links-withdrawn", "report-written", "terminal-consumed"]
            @test all(name -> isfile(joinpath(root, name)), events)
            stamps = [parse(UInt64, read(joinpath(root, name), String)) for name in events]
            @test issorted(stamps)
        elseif mode == "unknown"
            @test record["systemd_quit"]["attempted"] === true
            @test record["systemd_quit"]["accepted"] === false
            @test !isfile(joinpath(root, "graph-stopped"))
        elseif mode == "submitted"
            @test record["systemd_quit"]["attempted"] === true
            @test record["systemd_quit"]["accepted"] === false
            @test !isfile(joinpath(root, "quit-entry"))
        else
            @test !haskey(record, "systemd_quit")
            @test !isfile(joinpath(root, "quit-entry"))
        end
        println("SYSTEMD_STOP mode=$mode cleanup=true quiescent=true quit_submissions=$submissions accepted=$(get(get(record,"systemd_quit",Dict()),"accepted",false))")
        timing_names = ["helper-launch", "helper-loaded", "helper-budget-start",
            "connect-begin", "connect-end", "status-request", "status-complete",
            "quit-request", "quit-entry", "command-adopted", "quit-complete",
            "client-close-begin", "client-close-end", "mainpid-exit-observed", "helper-finish"]
        for name in timing_names
            path = joinpath(root, name)
            isfile(path) && println("SYSTEMD_STOP_TIME mode=$mode stage=$name monotonic_ns=$(read(path,String))")
        end
    finally
        if S.properties(unit)["MainPID"] != "0"
            run(ignorestatus(`systemctl --user kill --signal=SIGKILL --kill-whom=all $unit`))
        end
        run(ignorestatus(`systemctl --user stop $unit`))
        write(joinpath(root, "systemd-properties"), read(`systemctl --user show $unit`, String))
        write(joinpath(root, "journal"), read(`journalctl --user -u $unit --no-pager -o short-monotonic`, String))
        cp(root, joinpath(evidence, mode); force=true)
        run(pipeline(ignorestatus(`systemctl --user reset-failed $unit`); stderr=devnull))
        rm(link)
        run(`systemctl --user daemon-reload`)
    end
end

@testset "systemd preserves native authority until graceful Quit" begin
    with_control_private_core(; temporary_prefix="rtc-stop-", remote_name="rtc-stop-$(getpid())") do remote, directory, daemon
        chmod(dirname(remote), 0o700)
        withenv("DBUS_SESSION_BUS_ADDRESS"=>user_bus, "XDG_RUNTIME_DIR"=>user_runtime) do
            for mode in (baseline ? ["normal"] : ["normal", "fault", "unknown", "wrong-pid", "wrong-ticks", "wrong-uuid", "submitted", "missing-ledger", "exited"])
                stop_case(remote, directory, mode)
            end
        end
    end
end
