using Test, JSON3, Sockets

using PipeWireAODeployment
const D = PipeWireAODeployment.Deployment
const P = PipeWireAODeployment.Placement

function deployment_fixture(directory)
    for name in ("session.conf.in", "core.conf.in", "client.conf.in")
        write(joinpath(directory, name), "{}\n")
    end
    contract = Dict("cpus" => [2], "leader-cpu" => 2, "rt-priority" => 0,
        "threads" => Any[], "locked-bytes" => 0)
    Dict{String,Any}("version" => 1, "name" => "test-rtc", "session" => "session.conf.in",
        "core" => "core.conf.in", "client" => Dict("core" => "client.conf.in",
            "rtc" => "client.conf.in"),
        "placement" => Dict("core" => deepcopy(contract), "rtc" => deepcopy(contract)),
        "owners" => Any[], "environment" => Dict{String,String}(), "cpu-latency-us" => nothing,
        "artifacts" => Dict("session.conf.in" => D.digest(joinpath(directory, "session.conf.in"))))
end

@testset "Julia deployment portable admission and protocol" begin
    mktempdir() do directory
        spec = deployment_fixture(directory)
        path = joinpath(directory, "deployment.conf")
        write(path, JSON3.write(spec))
        @test D.profile(path, "/unused") == spec
        spec["placement"]["rtc"]["cpus"] = [0, 2]
        write(path, JSON3.write(spec))
        @test_throws P.PlacementError D.profile(path, "/unused")
        spec["placement"]["rtc"]["cpus"] = [2]
        write(path, JSON3.write(spec))
        write(joinpath(directory, "session.conf.in"), "changed")
        @test_throws D.DeploymentError D.profile(path, "/unused")
    end
    mktempdir() do directory
        escape = joinpath(directory, "escape")
        symlink("/etc/passwd", escape)
        @test_throws D.DeploymentError D.relative_asset(directory, "escape")
    end
    mktempdir() do directory
        source = joinpath(directory, "package")
        mkdir(source)
        spec = deployment_fixture(source)
        write(joinpath(source, "pipewireao-rtc@.service.in"), "sealed root service\n")
        mkpath(joinpath(source, "bin"))
        write(joinpath(source, "bin/pipewireao-rtc@.service.in"), "sealed bin service\n")
        for name in ("pipewireao-rtc@.service.in", "bin/pipewireao-rtc@.service.in")
            spec["artifacts"][name] = D.digest(joinpath(source, name))
        end
        write(joinpath(source, "deployment.conf"), JSON3.write(spec))
        destination = joinpath(directory, "installed with spaces")
        D.install((; package=source, destination, pipewire_prefix="/unused prefix"))
        @test isfile(joinpath(destination, "bin/pipewireao-rtc-deploy"))
        @test isfile(joinpath(destination, "julia/Project.toml"))
        @test isfile(joinpath(destination, "julia/assets/deployment/hil/heart_owner.jl"))
        @test isfile(joinpath(destination, "julia/assets/deployment/templates/client-simulator.conf.in"))
        @test read(joinpath(destination, "julia/assets/deployment/pipewireao-rtc@.service.in")) ==
            read(joinpath(PipeWireAODeployment.resource_root(), "pipewireao-rtc@.service.in"))
        @test read(joinpath(destination, "pipewireao-rtc@.service.in"), String) == "sealed root service\n"
        @test read(joinpath(destination, "bin/pipewireao-rtc@.service.in"), String) == "sealed bin service\n"
        @test D.profile(joinpath(destination, "deployment.conf"), "/unused prefix") == spec
        for (name, owner) in D.INSTALLED_ENTRYPOINTS
            entrypoint = joinpath(destination, "bin", name)
            @test isfile(entrypoint)
            @test (stat(entrypoint).mode & 0o111) != 0
            @test occursin("PipeWireAODeployment.$owner.main", read(entrypoint, String))
            result = PipeWireAODeployment.Common.run_checked([entrypoint]; timeout=30)
            @test result.returncode == 1
            @test occursin("missing --", result.stderr)
            flagged = PipeWireAODeployment.Common.run_checked([entrypoint, "--base-package", "fixture"]; timeout=30)
            @test flagged.returncode == 1
            @test occursin("missing --", flagged.stderr)
            @test !occursin("missing --base-package", flagged.stderr)
            @test !occursin("unknown option", flagged.stderr)
            if name == "export_hil"
                version = PipeWireAODeployment.Common.run_checked([entrypoint, "--version"]; timeout=30)
                @test version.returncode == 1
                @test occursin("ArgumentError: unknown option --version", version.stderr)
                @test occursin("PipeWireAODeployment.Common", version.stderr)
                @test occursin("src/common.jl", version.stderr)
            end
        end
        unit = read(joinpath(destination, "systemd/pipewireao-rtc@.service"), String)
        @test occursin("/unused prefix", unit)
        @test occursin("Type=notify", unit)
        @test occursin("KillSignal=SIGINT", unit)
        @test occursin("TimeoutStopSec=300", unit)
        @test !occursin("@LAUNCHER@", unit)
        relocated = joinpath(directory, "relocated package")
        mv(destination, relocated)
        second = joinpath(directory, "installed again")
        result = PipeWireAODeployment.Common.run_checked([
            joinpath(relocated, "bin/pipewireao-rtc-deploy"), "install",
            "--package", relocated, "--destination", second,
            "--pipewire-prefix", "/unused prefix"]; timeout=30)
        @test result.returncode == 0
        @test isfile(joinpath(second, "bin/pipewireao-rtc-deploy"))
        @test D.profile(joinpath(second, "deployment.conf"), "/unused prefix") == spec
        second_unit = read(joinpath(second, "systemd/pipewireao-rtc@.service"), String)
        @test occursin("Type=notify", second_unit)
        @test occursin("KillSignal=SIGINT", second_unit)
        @test occursin("TimeoutStopSec=300", second_unit)
        @test !occursin("@LAUNCHER@", second_unit)
    end
    mktempdir() do directory
        source = joinpath(directory, "sealed-export")
        mkdir(source)
        spec = deployment_fixture(source)
        PipeWireAODeployment.ScienceExport.copy_deployment_runtime(source)
        template = joinpath(source, "julia/assets/deployment/pipewireao-rtc@.service.in")
        write(template, read(template, String) * "\n# incoming-SDK-template-marker\n")
        for (root, _, files) in walkdir(joinpath(source, "julia")), file in files
            relative = relpath(joinpath(root, file), source)
            spec["artifacts"][relative] = D.digest(joinpath(source, relative))
        end
        write(joinpath(source, "deployment.conf"), JSON3.write(spec))
        source_identity = PipeWireAODeployment.CalibrationCampaign.file_identity(source)
        destination = joinpath(directory, "installed")
        D.install((; package=source, destination, pipewire_prefix="/unused prefix"))
        @test occursin("incoming-SDK-template-marker", read(joinpath(destination, "systemd/pipewireao-rtc@.service"), String))
        @test PipeWireAODeployment.CalibrationCampaign.file_identity(source) == source_identity
        @test D.profile(joinpath(destination, "deployment.conf"), "/unused prefix") == spec
        @test read(joinpath(destination, "julia/deploy_cli.jl")) ==
            read(joinpath(source, "julia/deploy_cli.jl"))
    end
    for missing in ("hil/Project.toml", "templates/core.conf.in", "pipewireao-rtc@.service.in")
        mktempdir() do directory
            source = joinpath(directory, "incomplete-SDK")
            mkdir(source)
            spec = deployment_fixture(source)
            PipeWireAODeployment.ScienceExport.copy_deployment_runtime(source)
            rm(joinpath(source, "julia/assets/deployment", missing))
            # Seal the incomplete input itself, so the resource admission check,
            # rather than an artifact hash mismatch, must reject it.
            for (root, _, files) in walkdir(joinpath(source, "julia")), file in files
                relative = relpath(joinpath(root, file), source)
                spec["artifacts"][relative] = D.digest(joinpath(source, relative))
            end
            write(joinpath(source, "deployment.conf"), JSON3.write(spec))
            identity = PipeWireAODeployment.CalibrationCampaign.file_identity(source)
            destination = joinpath(directory, "destination")
            error = try
                D.install((;package=source, destination, pipewire_prefix="/unused prefix"))
                nothing
            catch caught
                caught
            end
            @test error isa D.DeploymentError
            @test occursin("resources are incomplete", sprint(showerror, error))
            @test !ispath(destination)
            @test PipeWireAODeployment.CalibrationCampaign.file_identity(source) == identity
        end
    end
    @test occursin("\\\"", D.substitute("\"@PACKAGE@\"", Dict("PACKAGE" => "a\"b"); quoted=true))
    @test_throws D.DeploymentError D.substitute("@MISSING@", Dict{String,String}())
    good_source = Dict("version" => 1, "id" => 1, "operation" => "status",
        "state" => "paused", "sequence" => 0, "completed" => false,
        "ok" => true, "error" => nothing)
    @test D.validate_source_reply(Vector{UInt8}(JSON3.write(good_source))) == good_source
    bad_source = copy(good_source)
    bad_source["version"] = true
    @test_throws D.DeploymentError D.validate_source_reply(Vector{UInt8}(JSON3.write(bad_source)))
    request = Dict("version" => 1, "id" => "r1", "argv" => ["status"])
    @test D.validate_control_request(Vector{UInt8}(JSON3.write(request))) == request
    request["argv"] = fill("x", 129)
    @test_throws D.DeploymentError D.validate_control_request(Vector{UInt8}(JSON3.write(request)))
    if Sys.islinux() && Sys.which("python3") !== nothing
        mktempdir() do directory
            socket_path = joinpath(directory, "notify.sock")
            ready_path = joinpath(directory, "ready")
            result_path = joinpath(directory, "result.json")
            receiver = joinpath(directory, "receive.py")
            write(receiver, """
import json, socket, struct, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
sock.bind(sys.argv[1])
sock.settimeout(5)
open(sys.argv[2], 'w').close()
message, controls, _, _ = sock.recvmsg(65536, socket.CMSG_SPACE(12))
credentials = next(struct.unpack('3i', data) for level, kind, data in controls
                   if level == socket.SOL_SOCKET and kind == socket.SCM_CREDENTIALS)
with open(sys.argv[3], 'w') as output:
    json.dump({'message': message.decode(), 'pid': credentials[0]}, output)
""")
            receiver_process = Base.run(Cmd(["python3", receiver, socket_path,
                ready_path, result_path]); wait=false)
            previous_socket = get(ENV, "NOTIFY_SOCKET", nothing)
            try
                deadline = time() + 5
                while !isfile(ready_path) && time() < deadline
                    sleep(0.01)
                end
                @test isfile(ready_path)
                ENV["NOTIFY_SOCKET"] = socket_path
                D.notify("READY=1\nSTATUS=RTC admitted")
                wait(receiver_process)
                @test success(receiver_process)
                result = JSON3.read(read(result_path, String), Dict{String,Any})
                @test result["message"] == "READY=1\nSTATUS=RTC admitted"
                @test result["pid"] == getpid()
            finally
                previous_socket === nothing ? delete!(ENV, "NOTIFY_SOCKET") :
                    (ENV["NOTIFY_SOCKET"] = previous_socket)
                process_running(receiver_process) && kill(receiver_process)
                wait(receiver_process)
            end
        end
    end
    mktempdir() do directory
        path = joinpath(directory, "control.sock")
        server = listen(path)
        @test D._is_socket(path)
        alias = joinpath(directory, "alias.sock")
        symlink(path, alias)
        @test !D._is_socket(alias)
        responder = @async begin
            peer = accept(server)
            request = JSON3.read(readline(peer), Dict{String,Any})
            write(peer, JSON3.write(Dict("version" => 1, "id" => request["id"],
                "ok" => true, "state" => "Ready")) * "\n")
            close(peer)
        end
        @test D.control(path, ["status"])["state"] == "Ready"
        wait(responder)
        close(server)
    end
    # The native server answers one request and closes immediately. A fresh
    # Julia client must read that answer without a second, post-reply write.
    mktempdir() do directory
        for index in 1:2
            path = joinpath(directory, "fast-close-$index.sock")
            server = listen(path)
            responder = @async begin
                peer = accept(server)
                request = JSON3.read(readline(peer), Dict{String,Any})
                write(peer, JSON3.write(Dict("version" => 1, "id" => request["id"],
                    "ok" => true, "state" => "Ready")) * "\n")
                close(peer)
            end
            code = "using PipeWireAODeployment; D=PipeWireAODeployment.Deployment; " *
                "@assert D.control(ARGS[1], [\"status\"])[\"state\"]==\"Ready\""
            child = PipeWireAODeployment.Common.run_checked([
                Base.julia_cmd().exec[1], "--startup-file=no", "--project=" * PipeWireAODeployment.package_root(),
                "-e", code, path]; timeout=30)
            wait(responder)
            close(server)
            @test child.returncode == 0
        end
    end
    available = sort!(collect(filter(>=(2), P.inherited_cpus())))
    if !isempty(available)
        cpu = first(available)
        child = Base.run(Cmd(["taskset", "-c", string(cpu), "sleep", "5"]); wait=false)
        try
            contract = Dict("cpus" => [cpu], "leader-cpu" => cpu,
                "rt-priority" => 0, "threads" => Any[], "locked-bytes" => 0)
            observed = P.snapshot(getpid(child), contract)
            @test observed["pid"] == getpid(child)
            @test observed["threads"][1]["cpus"] == [cpu]
        finally
            process_running(child) && kill(child)
            wait(child)
        end
        code = "using PipeWireAODeployment; " *
            "result=PipeWireAODeployment.Placement.pin_supervisor(parse(Int,ARGS[1])); " *
            "println(length(result[\"threads\"]));"
        child = PipeWireAODeployment.Common.run_checked([
            Base.julia_cmd().exec[1], "--startup-file=no", "--threads=4",
            "--project=" * PipeWireAODeployment.package_root(), "-e", code,
            string(cpu)]; timeout=30)
        @test child.returncode == 0
        @test parse(Int, strip(child.stdout)) >= 4
        mktempdir() do directory
            probe = joinpath(directory, "spawn-stderr.jl")
            write(probe, """
using PipeWireAODeployment
D = PipeWireAODeployment.Deployment
runtime = ARGS[1]
cpu = parse(Int, ARGS[2])
mkdir(joinpath(runtime, "core"))
spec = Dict{String,Any}("placement" => Dict("core" => Dict("leader-cpu" => cpu)))
runner = D.DeploymentRunner((;), runtime, spec, Dict{String,String}(), Set([cpu]),
    Tuple{String,Base.Process}[], IdDict{Base.Process,Int}(), runtime,
    nothing, nothing, nothing, nothing, nothing, nothing, 0, nothing,
    false, false, false, nothing,
    Dict{String,Any}("processes" => Dict{String,Any}()))
child = D.spawn(runner, "core", ["sh", "-c", "printf supervised-child-diagnostic >&2"],
    Dict{String,String}(ENV))
wait(child)
success(child) || error("diagnostic child exited unsuccessfully")
""")
            observed = PipeWireAODeployment.Common.run_checked([
                Base.julia_cmd().exec[1], "--startup-file=no", "--project=" * PipeWireAODeployment.package_root(),
                probe, directory,
                string(cpu)]; timeout=30)
            @test observed.returncode == 0
            @test occursin("supervised-child-diagnostic", observed.stderr)
        end
    end
    mktempdir() do directory
        D._enable_subreaper()
        child_pid_file = joinpath(directory, "descendant.pid")
        command = Cmd(Cmd(["sh", "-c", "sleep 30 & echo \$! > \"\$1\"; sleep 0.1; exit 0",
            "owner", child_pid_file]); detach=true)
        owner = Base.run(command; wait=false)
        owner_pid = getpid(owner)
        try
            wait(owner)
            descendant = parse(Int, strip(read(child_pid_file, String)))
            @test ispath("/proc/$descendant")
            @test !isempty(D._live_owned_orphans(owner_pid))
            D._owned_wait(owner, owner_pid, 0)
            @test isempty(D._live_owned_orphans(owner_pid))
            @test !ispath("/proc/$descendant")
        finally
            for member in D._live_owned_orphans(owner_pid)
                ccall(:kill, Cint, (Cint, Cint), member.pid, Base.SIGKILL)
            end
            D._reap_owned_orphans(owner_pid)
        end
    end
end
