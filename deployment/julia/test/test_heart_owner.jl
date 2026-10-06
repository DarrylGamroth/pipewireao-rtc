using Test, JSON3, Sockets

using PipeWireAODeployment
const H = PipeWireAODeployment.HeartOwner

const HEART_REQUIREMENTS = Dict("runtime_requirements" => [
    Dict("block" => "clwcBlock", "control" => "ENABLE_HRT_FLAGS", "flags" =>
        Dict("enableClippingFeedback" => 1, "enableNotClearingIntg" => 0)),
    Dict("block" => "tfcBlock", "control" => "ENABLE_HRT_FLAGS", "flags" =>
        Dict("enableInHoVect" => 1, "enableOutDmErrs" => 1))])

@testset "HEART owner portable validation and generation reports" begin
    mktempdir() do directory
        path = joinpath(directory, "requirements.json")
        write(path, JSON3.write(HEART_REQUIREMENTS))
        @test length(H.read_requirements(path)) == 4
        options = (; config=path, requirements=path, runtime=directory,
            )
        owner = H.Owner(options)
        original = owner.source_config_sha256
        write(path, "changed")
        H.report(owner)
        @test JSON3.read(read(owner.status_path, String))["source_config_sha256"] == original
        snapshot = H.snapshot(owner)
        @test !snapshot.alive && snapshot.child_pid === nothing
        @test snapshot.generation == 0 && snapshot.report_sha256 == ""
        H.seal_generation!(owner)
        @test owner.generation_report_sha256 == PipeWireAODeployment.Common.sha256_file(owner.generation_report)
        sealed = read(owner.generation_report)
        H.report(owner, "diagnostic failure")
        @test read(owner.generation_report) == sealed
        @test_throws ErrorException H.seal_generation!(owner)
    end
    mktempdir() do directory
        path = joinpath(directory, "requirements.json")
        write(path, JSON3.write(HEART_REQUIREMENTS))
        owner = H.Owner((; config=path, requirements=path, runtime=directory))
        child = run(`sleep 600`; wait=false)
        owner.child = child
        owner.child_pid = UInt32(getpid(child))
        pid = owner.child_pid
        try
            kill(child)
            wait(child)
            stopped = H.snapshot(owner)
            @test stopped.child_pid == pid
            @test !stopped.alive
            @test stopped.child_returncode !== nothing
            H.report(owner)
            saved = JSON3.read(read(owner.status_path, String))
            @test saved.child_pid == pid
            @test saved.child_returncode == stopped.child_returncode
            @test !isdir("/proc/$pid")
        finally
            process_running(child) && kill(child, Base.SIGKILL)
            wait(child)
        end
    end
    mktempdir() do directory
        path = joinpath(directory, "requirements.json")
        bad = deepcopy(HEART_REQUIREMENTS)
        bad["runtime_requirements"][2]["flags"]["enableInHoVect"] = 0
        write(path, JSON3.write(bad))
        @test_throws ArgumentError H.read_requirements(path)
        placement = Dict("cpus" => [3, 4], "workers" => [
            Dict("name" => "HOP0.wfs.w", "cpus" => [4], "policy" => 1, "priority" => 15)])
        write(path, JSON3.write(placement))
        declaration = H.read_placement(path)
        thread = Dict("tid" => 1, "name" => "HOP0.wfs.w", "cpus" => [4],
            "policy" => 1, "priority" => 15)
        @test H.validate_placement([thread], declaration) === nothing
        @test_throws ErrorException H.validate_placement([thread, thread], declaration)
        placement["cpus"] = [0, 4]
        write(path, JSON3.write(placement))
        @test_throws Exception H.read_placement(path)
    end
    @test H.acknowledged(0, "ack<0><ACCEPTED> status<0><SUCCESS>")
    @test !H.acknowledged(1, "ack<0><ACCEPTED> status<0><SUCCESS>")
    @test !H.acknowledged(0, "ack<0><ACCEPTED>")
    mktempdir() do directory
        package = joinpath(directory, "package with spaces")
        mkdir(package)
        input = Dict(name => joinpath(directory, name) for name in
            ("executable", "client", "config", "requirements", "cpu-map", "thread-map"))
        for path in values(input)
            write(path, "fixture")
        end
        for name in ("executable", "client")
            chmod(input[name], 0o755)
        end
        write(input["config"], "CAL: \"@PACKAGE@/calibration\"\n")
        write(input["requirements"], JSON3.write(HEART_REQUIREMENTS))
        runtime = joinpath(directory, "runtime")
        remote = joinpath(directory, "core.sock")
        server = listen(remote)
        option_values = merge(input, Dict("runtime" => runtime, "package" => package,
            "remote" => remote, "control-node" => "fixture.heart", "control-instance" => "17"))
        argv = String[]
        for (name, path) in option_values
            append!(argv, ["--" * name, path])
        end
        @test_throws ArgumentError H.arguments(vcat(argv, ["--native-debug-stdio-wrapper", "/absent/stdbuf"]))
        @test_throws ArgumentError H.arguments(vcat(argv, ["--native-wfs-proc-debug", "true", "--native-debug-stdio-wrapper", "/absent/stdbuf"]))
        options = H.arguments(vcat(argv, ["--native-wfs-proc-debug", "true", "--native-debug-stdio-wrapper", "/usr/bin/stdbuf"]))
        @test options.native_debug_stdio_wrapper == realpath("/usr/bin/stdbuf")
        @test options.native_wfs_proc_debug
        diagnostic_owner = H.Owner(options)
        H.report(diagnostic_owner)
        diagnostics = JSON3.read(read(diagnostic_owner.status_path, String))["native_diagnostics"]
        @test diagnostics["stdio_wrapper_sha256"] == PipeWireAODeployment.Common.sha256_file("/usr/bin/stdbuf")
        @test diagnostics["child_argv"][1:3] == [realpath("/usr/bin/stdbuf"), "-oL", "-eL"]
        @test occursin("scientific acceptance excluded", diagnostics["qualification"])
        @test isfile(joinpath(options.runtime, "config/heart.yaml"))
        @test occursin(package, read(joinpath(options.runtime, "config/heart.yaml"), String))
        @test read(joinpath(options.runtime, "config/host.cpu"), String) == "fixture"
        @test_throws ArgumentError H.arguments(argv)
        close(server)
    end
end
