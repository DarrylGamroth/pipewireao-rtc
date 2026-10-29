using Test, TOML, JSON, PipeWireAORTC

const D = PipeWireAORTC.DeploymentConfiguration
const I = PipeWireAORTC.SessionInstall

@testset "registered application environment" begin
    mktempdir() do directory
        write(joinpath(directory, "Project.toml"), """
            [deps]
            PipeWireAORTC = "a3e2c7da-f73f-4284-8482-36ac422b34e6"
            """)
        manifest = joinpath(directory, "Manifest.toml")
        write(manifest, """
            manifest_format = "2.0"
            [[deps.PipeWireAORTC]]
            uuid = "a3e2c7da-f73f-4284-8482-36ac422b34e6"
            version = "0.1.2"
            git-tree-sha1 = "0000000000000000000000000000000000000000"
            """)
        spec = Dict("runtime" => Dict("kind" => "registered", "project" => "."))
        seal!() = (spec["artifacts"] = Dict(name => D.digest(joinpath(directory, name))
            for name in ("Project.toml", "Manifest.toml")))
        seal!()
        @test D.registered_application(spec)
        @test !D.registered_application(Dict())
        @test D.application_environment(spec, directory) == realpath(directory)
        for field in ("path", "repo-url", "repo-rev")
            original = read(manifest, String)
            write(manifest, original * "$field = \"unsealed\"\n")
            seal!()
            @test_throws D.DeploymentError D.application_environment(spec, directory)
            write(manifest, original)
            seal!()
        end
        original = read(manifest, String)
        for invalid in ("manifest_format = \"2.0\"\n", replace(original,
                "uuid = \"a3e2c7da-f73f-4284-8482-36ac422b34e6\"" => "uuid = \"missing\""),
                replace(original, "git-tree-sha1 = \"0000000000000000000000000000000000000000\"" => "deps = [\"MissingDependency\"]"))
            write(manifest, invalid)
            seal!()
            @test_throws D.DeploymentError D.application_environment(spec, directory)
        end
        write(manifest, original)
        seal!()
        delete!(spec["artifacts"], "Manifest.toml")
        @test_throws D.DeploymentError D.application_environment(spec, directory)
        seal!()
        for runtime in (Dict("kind" => "copied", "project" => "."),
                Dict("kind" => "registered", "project" => dirname(directory)),
                Dict("kind" => "registered", "project" => ".."),
                Dict("kind" => "registered", "project" => ".", "unknown" => true))
            @test_throws D.DeploymentError D.application_environment(Dict("runtime" => runtime), directory)
        end
        seal!()
        open(joinpath(directory, "Project.toml"), "a") do io
            write(io, "\n[sources]\nPipeWireAORTC = {path=\"../source\"}\n")
        end
        @test_throws D.DeploymentError D.application_environment(spec, directory)
    end
end

@testset "registered launcher selects the application" begin
    environment = "/application/a space's environment"
    launcher = I.installed_launcher("/julia/bin/julia"; environment)
    @test occursin(D.shell_quote(environment), launcher)
    @test occursin("PipeWireAORTC.SessionCLI.main(ARGS)", launcher)
    @test !occursin("session_cli.jl", launcher)
    @test occursin("session_cli.jl", I.installed_launcher("/julia/bin/julia"))
end

@testset "session unit pins its leader within the placement envelope" begin
    template = read(joinpath(PipeWireAORTC.package_root(),
        "assets/deployment/pipewireao-session@.service.in"), String)
    placement = Dict("cpus" => [2, 3], "leader-cpu" => 3,
        "threads" => [Dict("name" => "data-loop", "cpus" => [2])])
    spec = Dict("placement" => Dict("session" => placement),
        "source-owner" => "simulator", "startup-timeout-ms" => 120000)
    original = deepcopy(spec)
    unit = I.installed_unit(template, spec; launcher="/a space/session",
        package="/application/100%", prefix="/sdk", executable="/sdk/bin/rtc")
    @test filter(line -> startswith(line, "CPUAffinity="), split(unit, '\n')) ==
        ["CPUAffinity=3"]
    @test spec == original
    @test "TimeoutStartSec=120.0" in split(unit, '\n')
    @test occursin("ExecStart=\"/sdk/bin/rtc\" -c \${RTC_CONFIG}", unit)
    @test occursin("--package \"/application/100%%\"", unit)
    @test occursin("--source-role simulator", unit)
    @test !occursin(r"@[A-Z_]+@", unit)
end
