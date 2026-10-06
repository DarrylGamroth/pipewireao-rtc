using Test, JSON3, PipeWireAODeployment

const NBD = PipeWireAODeployment.Deployment

function native_bootstrap_deployment_fixture(directory; source=false, legacy=false)
    for name in ("session.conf.in", "core.conf.in", "client.conf.in")
        write(joinpath(directory, name), "{}\n")
    end
    placement = Dict("cpus" => [2], "leader-cpu" => 2, "rt-priority" => 0,
        "threads" => Any[], "locked-bytes" => 0)
    role = "julia-wfs"
    node = "julia-wfs.bootstrap"
    argv = ["julia", "--threads=2,0", "--bootstrap-node", node,
        "--bootstrap-instance", "@BOOTSTRAP_INSTANCE_JULIA_WFS@",
        "--remote", "@RUNTIME@/@REMOTE@"]
    owner = Dict{String,Any}("role" => role, "argv" => argv,
        "environment" => Dict{String,String}())
    spec = Dict{String,Any}("version" => 1, "name" => "test-rtc",
        "session" => "session.conf.in", "core" => "core.conf.in",
        "client" => Dict("core" => "client.conf.in", "rtc" => "client.conf.in"),
        "placement" => Dict("core" => deepcopy(placement), "rtc" => deepcopy(placement)),
        "owners" => Any[owner], "environment" => Dict{String,String}(),
        "cpu-latency-us" => nothing,
        "artifacts" => Dict("session.conf.in" => NBD.digest(joinpath(directory, "session.conf.in"))))
    if legacy
        delete!(owner, "argv")
        owner["argv"] = ["julia", "--threads=2,0"]
        owner["prepared"] = "julia.prepared"
        owner["connect"] = "julia.connect"
        owner["connected"] = "julia.connected"
        owner["quit"] = "julia.quit"
    else
        owner["bootstrap-protocol"] = "pipewireao.rtc.owner-bootstrap/1"
        owner["bootstrap-node"] = node
    end
    if source
        spec["source-owner"] = role
        if legacy
            owner["control-request"] = "julia.request"
            owner["control-reply"] = "julia.reply"
        else
            owner["control-protocol"] = "pipewireao.source-control/1"
            owner["control-node"] = "julia-wfs.source"
            append!(owner["argv"], ["--control-node", owner["control-node"]])
        end
    end
    spec["placement"][role] = deepcopy(placement)
    spec["client"][role] = "client.conf.in"
    return spec
end

function check_bootstrap_profile(mutator=identity; legacy_export_input=false, source=false, legacy=false)
    mktempdir() do directory
        spec = native_bootstrap_deployment_fixture(directory; source, legacy)
        mutator(spec)
        path = joinpath(directory, "deployment.conf")
        write(path, JSON3.write(spec))
        return NBD.profile(path, "/unused"; legacy_export_input) == spec
    end
end

@testset "native owner bootstrap deployment profile" begin
    @testset "empty deployment remains valid" begin
        mktempdir() do directory
            spec = NBD.profile(
                let path = joinpath(directory, "deployment.conf")
                    fixture = native_bootstrap_deployment_fixture(directory)
                    empty!(fixture["owners"])
                    delete!(fixture["placement"], "julia-wfs")
                    delete!(fixture["client"], "julia-wfs")
                    write(path, JSON3.write(fixture))
                    path
                end,
                "/unused",
            )
            @test isempty(spec["owners"])
        end
    end

    @testset "legacy markers require the explicit export-input path" begin
        @test_throws NBD.DeploymentError check_bootstrap_profile(; legacy=true)
        @test check_bootstrap_profile(; legacy=true, legacy_export_input=true)
    end

    @testset "ordinary owner uses exact native bootstrap descriptor" begin
        @test check_bootstrap_profile()
        @test NBD.bootstrap_instance_key("julia-wfs") == "BOOTSTRAP_INSTANCE_JULIA_WFS"
        @test_throws NBD.DeploymentError check_bootstrap_profile(spec -> begin
            spec["owners"][1]["prepared"] = "stale.prepared"
        end)
        @test_throws NBD.DeploymentError check_bootstrap_profile(spec -> begin
            spec["owners"][1]["bootstrap-protocol"] = "pipewireao.rtc.owner-bootstrap/2"
        end)
    end

    @testset "bootstrap argv requires one exact flag/value pair" begin
        invalid_argv = (
            ["julia", "--threads=2,0", "--bootstrap-instance", "@BOOTSTRAP_INSTANCE_JULIA_WFS@",
                "--remote", "@RUNTIME@/@REMOTE@"],
            ["julia", "--threads=2,0", "--bootstrap-node", "wrong.bootstrap",
                "--bootstrap-instance", "@BOOTSTRAP_INSTANCE_JULIA_WFS@",
                "--remote", "@RUNTIME@/@REMOTE@"],
            ["julia", "--threads=2,0", "--bootstrap-node", "julia-wfs.bootstrap",
                "--bootstrap-node", "julia-wfs.bootstrap", "--bootstrap-instance",
                "@BOOTSTRAP_INSTANCE_JULIA_WFS@", "--remote", "@RUNTIME@/@REMOTE@"],
            ["julia", "--threads=2,0", "--bootstrap-node=julia-wfs.bootstrap",
                "--bootstrap-instance", "@BOOTSTRAP_INSTANCE_JULIA_WFS@",
                "--remote", "@RUNTIME@/@REMOTE@"],
            ["julia", "--threads=2,0", "--bootstrap-node", "julia-wfs.bootstrap",
                "--bootstrap-instance", "wrong.instance", "--remote", "@RUNTIME@/@REMOTE@"],
            ["julia", "--threads=2,0", "--bootstrap-node", "julia-wfs.bootstrap",
                "--bootstrap-instance", "@BOOTSTRAP_INSTANCE_JULIA_WFS@",
                "--bootstrap-instance", "@BOOTSTRAP_INSTANCE_JULIA_WFS@",
                "--remote", "@RUNTIME@/@REMOTE@"],
            ["julia", "--threads=2,0", "--bootstrap-node", "julia-wfs.bootstrap",
                "--remote", "@RUNTIME@/@REMOTE@"],
            ["julia", "--threads=2,0", "--bootstrap-node", "julia-wfs.bootstrap",
                "--bootstrap-instance=@BOOTSTRAP_INSTANCE_JULIA_WFS@",
                "--remote", "@RUNTIME@/@REMOTE@"],
            ["julia", "--threads=2,0", "--bootstrap-node", "julia-wfs.bootstrap",
                "--bootstrap-instance", "@BOOTSTRAP_INSTANCE_JULIA_WFS@",
                "--remote", "wrong.remote"],
            ["julia", "--threads=2,0", "--bootstrap-node", "julia-wfs.bootstrap",
                "--bootstrap-instance", "@BOOTSTRAP_INSTANCE_JULIA_WFS@",
                "--remote", "@RUNTIME@/@REMOTE@", "--remote", "@RUNTIME@/@REMOTE@"],
            ["julia", "--threads=2,0", "--bootstrap-node", "julia-wfs.bootstrap",
                "--bootstrap-instance", "@BOOTSTRAP_INSTANCE_JULIA_WFS@",
                "--remote=@RUNTIME@/@REMOTE@"],
        )
        for argv in invalid_argv
            @test_throws NBD.DeploymentError check_bootstrap_profile(spec ->
                (spec["owners"][1]["argv"] = argv))
        end
    end

    @testset "bootstrap requires isolated default-pool threads" begin
        for threads in ("--threads=1,0", "--threads=2,1", "--threads=auto,0")
            @test_throws NBD.DeploymentError check_bootstrap_profile(spec -> begin
                argv = spec["owners"][1]["argv"]
                argv[findfirst(arg -> startswith(arg, "--threads="), argv)] = threads
            end)
        end
    end

    @testset "bootstrap rejects legacy file-control flags" begin
        for flag in ("--prepared-event", "--connect-request", "--connect-reply",
                "--quit-request", "--control-request", "--control-reply")
            @test_throws NBD.DeploymentError check_bootstrap_profile(spec ->
                push!(spec["owners"][1]["argv"], flag, "julia.marker"))
            @test_throws NBD.DeploymentError check_bootstrap_profile(spec ->
                push!(spec["owners"][1]["argv"], flag * "=julia.marker"))
        end
    end

    @testset "source owner requires native source control" begin
        @test_throws NBD.DeploymentError check_bootstrap_profile(; source=true, legacy=true)
        @test check_bootstrap_profile(; source=true)
        @test_throws NBD.DeploymentError check_bootstrap_profile(spec -> begin
            spec["owners"][1]["control-protocol"] = "pipewireao.source-control/2"
        end; source=true)
        @test_throws NBD.DeploymentError check_bootstrap_profile(spec -> begin
            owner = spec["owners"][1]
            owner["control-node"] = owner["bootstrap-node"]
            argv = owner["argv"]
            argv[end] = owner["control-node"]
        end; source=true)
        @test_throws NBD.DeploymentError check_bootstrap_profile(spec -> begin
            spec["owners"][1]["argv"][end] = "wrong.source"
        end; source=true)
        @test_throws NBD.DeploymentError check_bootstrap_profile(spec -> begin
            filter!(arg -> arg != "--control-node", spec["owners"][1]["argv"])
        end; source=true)
        @test_throws NBD.DeploymentError check_bootstrap_profile(spec -> begin
            argv = spec["owners"][1]["argv"]
            argv[end - 1] = "--control-node=$(argv[end])"
            pop!(argv)
        end; source=true)
    end
end
