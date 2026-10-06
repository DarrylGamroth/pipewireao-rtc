# Explicit integration test: requires existing immutable HEART package inputs.
# It exercises the wrapper and vendor startup/reset/stop, not scientific pixels.
using Test, JSON3, SHA, PipeWireAO, PipeWireAODeployment
include("native_control_private_core.jl")
const HVC = PipeWireAODeployment.NativeHeartClient
const HCC = PipeWireAODeployment.NativeControlClient
const D = PipeWireAODeployment.Deployment
const HCO = PipeWireAODeployment.Common
const PACKAGE = realpath(ENV["HEART_NATIVE_TEST_PACKAGE"])
const EVIDENCE = mkpath(ENV["HEART_NATIVE_TEST_EVIDENCE"])
const SOURCE_ROOT = dirname(@__DIR__)
include(joinpath(PipeWireAODeployment.resource_root(), "hil", "native_heart_control.jl"))
const ENTRYPOINT = joinpath(PipeWireAODeployment.resource_root(), "hil", "heart_owner.jl")

function vendor_arguments(native_root, socket, node, instance)
    paths = Dict(name => joinpath(PACKAGE, "heart", relative) for (name, relative) in (
        "executable"=>"bin/scaoTemplate", "client"=>"bin/scaoTemplateCmdClient",
        "config"=>"config.yaml.in", "requirements"=>"requirements.json",
        "cpu-map"=>"host.cpu", "thread-map"=>"host.threads", "placement"=>"placement.json"))
    argv = String[first(Base.julia_cmd().exec), "--startup-file=no", "--project=$SOURCE_ROOT", ENTRYPOINT,
        "--package", PACKAGE, "--runtime", native_root, "--remote", socket,
        "--control-node", node, "--control-instance", string(instance),
        "--calibration-root", joinpath(PACKAGE, "heart", "calibration")]
    for (name, path) in sort!(collect(paths); by=first)
        append!(argv, ["--$name", path])
    end
    return argv, paths
end

function qualify_vendor(socket, directory, daemon)
    chmod(dirname(socket), 0o700)
    native_root = joinpath(directory, "vendor-native")
    node = "test.native.vendor.heart"
    instance = Int64(time_ns() % UInt64(typemax(Int64) - 1)) + 1
    argv, paths = vendor_arguments(native_root, socket, node, instance)
    D._enable_subreaper()
    child_pids = UInt32[]
    owner = client = owner_pid = nothing
    log = open(joinpath(EVIDENCE, "owner.log"), "w")
    try
        owner = run(pipeline(addenv(Cmd(Cmd(["taskset", "-c", "3", argv...]); detach=true),
            "HRT_MEMORY_HUGEPAGES"=>"0", "HRT_DEFER_WFS_INGRESS"=>"0");
            stdout=log, stderr=log, stdin=devnull); wait=false)
        owner_pid = getpid(owner)
        owner_alive() = (process_running(owner) || error("vendor wrapper exited during preparation"); nothing)
        deadline = HCC.monotonic() + 90
        client = HVC.connect(socket, node, owner_pid, instance; deadline, check=owner_alive)
        connected = HVC.connect!(client; deadline, check=owner_alive)
        @test connected.generation == 1
        @test connected.alive && connected.placement_validated && connected.diagnostics_disabled
        push!(child_pids, connected.child_pid)
        first_snapshot, report = HVC.generation_report(client, native_root; deadline, check=owner_alive)
        @test first_snapshot.child_pid == connected.child_pid
        @test report.source_config_sha256 == HCO.sha256_file(paths["config"])
        @test report.native_diagnostics.wfs_proc_debug === false
        @test report.native_diagnostics.stdio_wrapper === nothing
        @test HVC.require_ready(client, first_snapshot) === nothing
        cp(first_snapshot.report_path, joinpath(EVIDENCE, basename(first_snapshot.report_path)))
        next_snapshot = HVC.reset!(client, first_snapshot; deadline=HCC.monotonic()+20, check=owner_alive)
        push!(child_pids, next_snapshot.child_pid)
        @test next_snapshot.generation == 2
        @test next_snapshot.child_pid != first_snapshot.child_pid
        @test !isdir("/proc/$(first_snapshot.child_pid)")
        @test_throws ErrorException HVC.require_ready(client, first_snapshot)
        @test HVC.require_ready(client, next_snapshot) === nothing
        current, next_report = HVC.generation_report(client, native_root;
            deadline=HCC.monotonic()+10, check=owner_alive)
        @test current.child_pid == next_snapshot.child_pid
        @test next_report.generation == 2
        cp(current.report_path, joinpath(EVIDENCE, basename(current.report_path)))
        source_options = (; transport=:heart, remote=socket, controller_node=node,
            controller_pid=UInt32(owner_pid), controller_instance=instance,
            quit_request=joinpath(directory,"unused-source.quit"))
        from_source = HILHeartControl.with_controller(source_options) do options
            HILHeartControl.reset!(options)
        end
        push!(child_pids, from_source.child_pid)
        @test from_source.generation == current.generation + 1
        @test from_source.child_pid != current.child_pid
        @test !isdir("/proc/$(current.child_pid)")
        current = HVC.status(client; deadline=HCC.monotonic()+10, check=owner_alive)
        @test current.generation == from_source.generation
        next_snapshot = current
        stopped = HVC.shutdown!(client; deadline=HCC.monotonic()+30)
        @test !stopped.alive
        @test stopped.child_pid == next_snapshot.child_pid
        @test stopped.child_returncode !== nothing
        wait_proof(() -> process_exited(owner), 10, "native HEART owner shutdown")
        wait(owner)
        @test success(owner)
        @test all(pid -> !isdir("/proc/$pid"), child_pids)
        @test !isdir("/proc/$owner_pid")
        @test all(name -> !ispath(joinpath(directory, "heart.$name")), ("prepared","connect","connected","quit"))
        write(joinpath(EVIDENCE, "summary.json"), JSON3.write(Dict(
            "package"=>PACKAGE, "owner_pid"=>owner_pid, "child_pids"=>child_pids,
            "node"=>node, "instance"=>instance, "vendor_source_modified"=>false,
            "pixel_ingress_or_scientific_equivalence_claim"=>false,
            "input_sha256"=>Dict(name=>HCO.sha256_file(path) for (name,path) in paths),
            "checks"=>["native preparation and fresh status", "native connection acknowledgement",
                "vendor initialization and flag acknowledgements", "placement validated",
                "native reset replaced child", "native stopped reply after child exit",
                "wrapper and children exited", "no lifecycle markers"])))
        println("NATIVE_HEART_VENDOR_EVIDENCE=$EVIDENCE")
    finally
        client === nothing || try close(client) catch end
        owner === nothing || D._owned_wait(owner, something(owner_pid), 1)
        if isdir(native_root)
            target = joinpath(EVIDENCE, "native")
            ispath(target) || cp(native_root, target; follow_symlinks=false)
        end
        close(log)
    end
end

@testset "unchanged vendor HEART native wrapper lifecycle" begin
    with_control_private_core(qualify_vendor)
end

function qualify_vendor_failure(socket, directory, daemon, scenario::Symbol)
    chmod(dirname(socket), 0o700)
    native_root = joinpath(directory, "vendor-native")
    node = "test.native.vendor.heart.failure"
    instance = Int64(time_ns() % UInt64(typemax(Int64) - 1)) + 1
    argv, paths = vendor_arguments(native_root, socket, node, instance)
    if scenario === :preparation
        index = findfirst(==("--executable"), argv)
        argv[index+1] = "/bin/false"
    end
    destination = mkpath(joinpath(EVIDENCE, String(scenario)))
    log = open(joinpath(destination, "owner.log"), "w")
    owner = client = owner_pid = nothing
    child_pid = nothing
    try
        owner = run(pipeline(addenv(Cmd(Cmd(["taskset", "-c", "3", argv...]); detach=true),
            "HRT_MEMORY_HUGEPAGES"=>"0", "HRT_DEFER_WFS_INGRESS"=>"0");
            stdout=log, stderr=log, stdin=devnull); wait=false)
        owner_pid = getpid(owner)
        check_owner() = (process_running(owner) || error("owned wrapper exited"); nothing)
        if scenario === :preparation
            @test_throws Union{ErrorException,HCC.UnknownOutcome} HVC.connect(socket, node, owner_pid, instance;
                deadline=HCC.monotonic()+45, check=check_owner)
        else
            client = HVC.connect(socket, node, owner_pid, instance;
                deadline=HCC.monotonic()+90, check=check_owner)
            current = HVC.status(client; deadline=HCC.monotonic()+10, check=check_owner)
            child_pid = current.child_pid
            @test current.generation == 1 && current.alive
            if scenario === :reset
                # Only the task-owned rendered configuration is removed. The
                # retained package/vendor sources and calibration remain intact.
                rm(joinpath(native_root, "config", "heart.yaml"))
                @test_throws Union{ErrorException,HCC.UnknownOutcome} HVC.reset!(client, current;
                    deadline=HCC.monotonic()+20)
            elseif scenario === :child_exit
                result = HCO.run_checked([paths["client"], "-cmdName", "SHUTDOWN",
                    "-address", "127.0.0.1", "-port", "5001"]; timeout=5, cwd=destination,
                    stdout_path=joinpath(destination,"child-shutdown.log"),
                    stderr_path=joinpath(destination,"child-shutdown.stderr"))
                @test result.returncode == 0
            else
                error("unknown vendor failure scenario")
            end
            wait_proof(() -> with_thread_loop_lock(client.loop) do _
                client.observation.failure !== nothing ||
                    client.observation.capability.lifecycle === PipeWireAODeployment.NativeHeartCodec.Fault
            end, 20, "native wrapper failure observation")
            @test_throws Union{ErrorException,HCC.UnknownOutcome} HVC.require_ready(client, current)
        end
        wait_proof(() -> process_exited(owner), 20, "failed native wrapper exit")
        wait(owner)
        @test owner.exitcode == 1
        report = JSON3.read(read(joinpath(native_root,"heart-owner-status.json"),String))
        @test report.state == "failed"
        @test report.error !== nothing
        @test report.child_returncode !== nothing
        @test !isdir("/proc/$(report.child_pid)")
        @test child_pid === nothing || !isdir("/proc/$child_pid")
        @test !isdir("/proc/$owner_pid")
        @test !process_exited(daemon)
        write(joinpath(destination,"summary.json"), JSON3.write(Dict(
            "scenario"=>String(scenario), "owner_pid"=>owner_pid,
            "generation"=>report.generation, "child_pid"=>report.child_pid,
            "child_returncode"=>report.child_returncode, "error"=>report.error,
            "vendor_source_modified"=>false, "pixel_ingress"=>false)))
    finally
        client === nothing || try close(client) catch end
        owner === nothing || D._owned_wait(owner, something(owner_pid), 1)
        if isdir(native_root)
            cp(native_root,joinpath(destination,"native");follow_symlinks=false)
        end
        close(log)
    end
end

@testset "native HEART preparation, failed reset and child exit" begin
    for scenario in (:preparation, :reset, :child_exit)
        @testset "$scenario" begin
            with_control_private_core((socket, directory, daemon) ->
                qualify_vendor_failure(socket, directory, daemon, scenario))
        end
    end
end
