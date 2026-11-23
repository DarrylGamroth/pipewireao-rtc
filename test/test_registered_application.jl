using Test, TOML, JSON, PipeWireAORTC

const D = PipeWireAORTC.DeploymentConfiguration
const I = PipeWireAORTC.SessionInstall

@testset "registered application environment" begin
    mktempdir() do directory
        write(
            joinpath(directory, "Project.toml"),
            """
[deps]
PipeWireAORTC = "a3e2c7da-f73f-4284-8482-36ac422b34e6"
""",
        )
        manifest = joinpath(directory, "Manifest.toml")
        write(
            manifest,
            """
manifest_format = "2.0"
[[deps.PipeWireAORTC]]
uuid = "a3e2c7da-f73f-4284-8482-36ac422b34e6"
version = "0.1.2"
git-tree-sha1 = "0000000000000000000000000000000000000000"
""",
        )
        spec = Dict("runtime" => Dict("kind" => "registered", "project" => "."))
        @test D.registered_application(spec)
        @test !D.registered_application(Dict())
        @test D.application_environment(spec, directory) == realpath(directory)
        @test_throws D.DeploymentError D.application_environment(Dict(), directory)
        project_path = joinpath(directory, "Project.toml")
        original_project = read(project_path, String)
        project = TOML.parse(original_project)
        project["workspace"] = Dict("projects" => ["test"])
        open(project_path, "w") do io
            TOML.print(io, project)
        end
        @test_throws D.DeploymentError D.application_environment(spec, directory)
        write(project_path, original_project)
        @test D.application_environment(spec, directory) == realpath(directory)
        for field in ("path", "repo-url", "repo-rev")
            original = read(manifest, String)
            write(manifest, original * "$field = \"unsealed\"\n")
            @test_throws D.DeploymentError D.application_environment(spec, directory)
            write(manifest, original)
        end
        original = read(manifest, String)
        for invalid in (
            "manifest_format = \"2.0\"\n",
            replace(
                original,
                "uuid = \"a3e2c7da-f73f-4284-8482-36ac422b34e6\"" => "uuid = \"missing\"",
            ),
            replace(
                original,
                "git-tree-sha1 = \"0000000000000000000000000000000000000000\"" => "deps = [\"MissingDependency\"]",
            ),
        )
            write(manifest, invalid)
            @test_throws D.DeploymentError D.application_environment(spec, directory)
        end
        write(manifest, original)
        for name in ("JuliaProject.toml", "JuliaManifest.toml", "Manifest-v1.13.toml")
            alternative = joinpath(directory, name)
            write(alternative, original)
            @test_throws D.DeploymentError D.application_environment(spec, directory)
            rm(alternative)
        end
        @test D.application_environment(spec, directory) == realpath(directory)
        for runtime in (
            Dict("kind" => "copied", "project" => "."),
            Dict("kind" => "registered", "project" => dirname(directory)),
            Dict("kind" => "registered", "project" => ".."),
            Dict("kind" => "registered", "project" => ".", "unknown" => true),
        )
            @test_throws D.DeploymentError D.application_environment(
                Dict("runtime" => runtime), directory
            )
        end
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
    @test_throws UndefKeywordError I.installed_launcher("/julia/bin/julia")
end

@testset "session unit pins its leader within the placement envelope" begin
    template = read(
        joinpath(
            PipeWireAORTC.package_root(), "assets/deployment/pipewireao-session@.service.in"
        ),
        String,
    )
    placement = Dict(
        "cpus" => [2, 3],
        "leader-cpu" => 3,
        "threads" => [Dict("name" => "data-loop", "cpus" => [2])],
    )
    spec = Dict(
        "placement" => Dict("session" => placement),
        "source-owner" => "simulator",
        "startup-timeout-ms" => 120000,
    )
    original = deepcopy(spec)
    unit = I.installed_unit(
        template,
        spec;
        launcher = "/a space/session",
        package = "/application/100%",
        prefix = "/sdk",
        executable = "/sdk/bin/rtc",
    )
    @test filter(line -> startswith(line, "CPUAffinity="), split(unit, '\n')) ==
        ["CPUAffinity=3"]
    @test spec == original
    @test "TimeoutStartSec=120.0" in split(unit, '\n')
    @test occursin("ExecStart=\"/sdk/bin/rtc\" -c \${RTC_CONFIG}", unit)
    @test occursin("--package \"/application/100%%\"", unit)
    @test occursin("--source-role simulator", unit)
    @test !occursin(r"@[A-Z_]+@", unit)
    external = (; core = "ao-core.service", socket = "/private/100% core", source = "ao-input.service")
    attached = I.installed_unit(template, spec; launcher = "/launcher", package = "/app",
                               prefix = "/sdk", executable = "/sdk/bin/rtc", external)
    @test occursin("Environment=\"PIPEWIREAORTC_CORE_SOCKET=/private/100%% core\"", attached)
    @test occursin("Environment=\"PIPEWIREAORTC_SOURCE_UNIT=ao-input.service\"", attached)
end


@testset "site bindings for independent core and source services" begin
    L = PipeWireAORTC.SessionLaunch
    @test L.external_services(Dict()) === nothing
    keys = L.EXTERNAL_SERVICE_ENV
    env = Dict(zip(keys, ("ao-private.service", "/run/user/42/ao/private", "ao-simulator.service")))
    external = L.external_services(env)
    @test external == (; core = env[keys[1]], socket = env[keys[2]], source = env[keys[3]])
    for key in keys
        @test_throws L.LaunchError L.external_services(filter(pair -> first(pair) != key, env))
    end
    for unit in (env[keys[1]], "pipewireao-session@one.service",
                 "pipewireao-owner-a-source.service", "x.target", "../x.service")
        @test_throws L.LaunchError L.external_services(merge(env, Dict(keys[3] => unit)))
    end
    @test_throws L.LaunchError L.external_services(merge(env, Dict(keys[2] => "pipewire-0")))
    record = Dict("source_role" => "simulator", "version" => 2,
                  "owners" => Dict("simulator" => Dict("external" => true, "unit" => external.source)))
    @test L.cleanup_role!(record, "simulator", 0) === nothing
    @test L.retained_service(record, "simulator") === nothing
    @test PipeWireAORTC.SessionRuntime._source_endpoint(
        Dict("external" => true, "control-protocol" => "external-stream")
    ) == Dict("profile" => "external-stream")
end
