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
        write(project_path, original_project * "\n[compat]\nPipeWireAORTC = \"0.1.1\"\n")
        @test D.application_environment(spec, directory) == realpath(directory)
        write(project_path, original_project * "\n[compat]\nPipeWireAORTC = \"=0.1.1\"\n")
        @test_throws r"locked version 0.1.2 does not satisfy" D.application_environment(
            spec, directory
        )
        alternate = joinpath(directory, "override.toml")
        cp(manifest, alternate)
        write(project_path, "manifest = \"override.toml\"\n" * original_project)
        @test_throws r"runtime environment must use Manifest.toml" D.application_environment(
            spec, directory
        )
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
    spec["session-runtime"] = Dict("environment" => Dict("JULIA_DEPOT_PATH" => "/session-only"))
    original = deepcopy(spec)
    activation = (; julia = "/bin/julia", project = "/application/100%", digest = "a"^64)
    unit = I.installed_unit(
        template,
        spec;
        launcher = "/a space/session",
        package = "/application/100%",
        prefix = "/sdk",
        executable = "/sdk/bin/rtc", activation,
    )
    @test filter(line -> startswith(line, "CPUAffinity="), split(unit, '\n')) ==
        ["CPUAffinity=3"]
    @test spec == original
    @test "TimeoutStartSec=120.0" in split(unit, '\n')
    @test occursin("ExecStart=\"/bin/julia\" ", unit)
    @test occursin("\"--compiled-modules=strict\"", unit)
    @test occursin("\"--\" -c %t/pipewireao-session-%i/\${INVOCATION_ID}/rtc/rtc.conf", unit)
    @test !occursin("ExecStartPre=", unit)
    @test !occursin("EnvironmentFile=", unit)
    @test !occursin("/session-only", unit)
    @test occursin("PIPEWIREAORTC_INSTALLATION=/application/100%%", unit)
    @test occursin("--source-role simulator", unit)
    @test !occursin(r"@[A-Z_]+@", unit)
    external = (; core = "ao-core.service", socket = "/private/100% core", source = "ao-input.service")
    attached = I.installed_unit(template, spec; launcher = "/launcher", package = "/app",
                               prefix = "/sdk", executable = "/sdk/bin/rtc", activation, external)
    @test occursin("Environment=\"PIPEWIREAORTC_CORE_SOCKET=/private/100%% core\"", attached)
    @test occursin("Environment=\"PIPEWIREAORTC_SOURCE_UNIT=ao-input.service\"", attached)
    image = merge(activation, (sysimage = "/image/100% \$rc.so",))
    with_image = I.installed_unit(template, spec; launcher = "/launcher", package = "/app",
        prefix = "/sdk", executable = "/sdk/bin/rtc", activation = image)
    @test occursin("\"--sysimage=/image/100%% \$\$rc.so\"", with_image)
    @test occursin("\"--threads=1,0\"", with_image)
    @test occursin("\"--\" -c %t/pipewireao-session-%i/\${INVOCATION_ID}/rtc/rtc.conf", with_image)
    @test occursin("ExecStop=\"/launcher\" stop --unit", with_image)
    older_template = replace(template, I.INSTALLED_COMMAND => "@RTC_COMMAND@")
    legacy_template = replace(older_template, "@RTC_COMMAND@" => "@RTC_EXECUTABLE@")
    @test I.installed_unit(legacy_template, spec; launcher = "/launcher", package = "/app",
        prefix = "/sdk", executable = "/sdk/bin/rtc", activation) ==
        I.installed_unit(older_template, spec; launcher = "/launcher", package = "/app",
            prefix = "/sdk", executable = "/sdk/bin/rtc", activation)
    @test_throws ArgumentError I.installed_unit(legacy_template, spec; launcher = "/launcher",
        package = "/app", prefix = "/sdk", executable = "/sdk/bin/rtc", activation = image)
end


@testset "installed activation pins the configuration, executable and calibration" begin
    mktempdir() do package
        prefix = PipeWireAORTC.SessionLaunch.LibPipeWire.PipeWireAO_jll.artifact_dir
        rtc = joinpath(package, "rtc/bin/pipewireao-rtc")
        launcher = joinpath(package, "session-launcher")
        mkpath(dirname(rtc))
        write(rtc, "rtc")
        write(launcher, "session")
        names = ["deployment.conf", "session.conf", "client.conf", "core.conf", "calibration.fits",
                 "Project.toml", "Manifest.toml"]
        for name in names
            write(joinpath(package, name), name)
        end
        spec = Dict(
            "artifacts" => Dict("calibration.fits" => nothing),
            "client" => Dict("session" => "client.conf"),
            "session" => "session.conf", "core" => "core.conf",
            "session-runtime" => Dict("argv" => ["@PACKAGE@/rtc/bin/pipewireao-rtc", "-c",
                "@RUNTIME@/rtc/rtc.conf"], "environment" => Dict()),
        )
        activation = I.install_activation!(
            package, prefix, realpath(Base.julia_cmd().exec[1]), package, launcher, spec, nothing
        )
        read_activation(digest) = PipeWireAORTC.SessionCLI.activation_document(package, digest)
        @test read_activation(activation.digest)["profile"] == spec
        launch = PipeWireAORTC.SessionLaunch
        withenv(launch.ACTIVATION_ENV => activation.digest, launch.INSTALLATION_ENV => package,
                launch.ADMISSION_UNIT_ENV => "pipewireao-session@test.service",
                "INVOCATION_ID" => "a"^32, "XDG_RUNTIME_DIR" => package) do
            root = joinpath(package, "pipewireao-session-test", "a"^32)
            @test_throws ArgumentError PipeWireAORTC.SessionCLI.with_installed_attachment(identity, "/other.conf")
            @test_throws D.DeploymentError PipeWireAORTC.SessionCLI.with_installed_attachment(
                identity, joinpath(root, "rtc", "rtc.conf")
            )
            @test !ispath(root)
        end

        mkdir(joinpath(package, "graphs"))
        write(joinpath(package, "graphs", "late.conf.in"), "{}")
        @test isempty(read_activation(activation.digest)["graph-templates"])

        @test_throws PipeWireAORTC.SessionLaunch.LaunchError read_activation("0"^64)
        alternate = joinpath(package, "Manifest-v1.13.toml")
        write(alternate, "")
        @test_throws ArgumentError read_activation(activation.digest)
        rm(alternate)
        replacement = joinpath(package, "new.fits")
        write(replacement, "calibration.fits")
        mv(replacement, joinpath(package, "calibration.fits"); force = true)
        @test_throws ArgumentError read_activation(activation.digest)
        @test_throws ArgumentError I.install_activation!(
            package, prefix, realpath(Base.julia_cmd().exec[1]), package, launcher, spec, nothing
        )
        rm(joinpath(package, "systemd", launch.ACTIVATION_FILE))
        image = joinpath(package, "image.so")
        write(image, "original sysimage")
        @test I.selected_sysimage(image) == image
        @test_throws ArgumentError I.selected_sysimage("relative.so")
        @test_throws ArgumentError I.validate_sysimage(realpath(Base.julia_cmd().exec[1]), package, image)
        sealed_image = I.install_activation!(
            package, prefix, realpath(Base.julia_cmd().exec[1]), package, launcher, spec, nothing; sysimage = image,
        )
        selection = read_activation(sealed_image.digest)
        @test selection["julia-sysimage"] == image
        @test selection["julia-sysimage-sha256"] == PipeWireAORTC.Common.sha256_file(image)
        @test haskey(selection["files"], image)
        write(image, "modified sysimage bytes")
        @test_throws ArgumentError read_activation(sealed_image.digest)
    end
end

@testset "sysimage preloaded packages match the installed Manifest" begin
    installer = PipeWireAORTC.SessionInstall
    check = Base.include_string(
        Module(gensym(:SysimageCheck)),
        installer.SYSIMAGE_PACKAGE_CHECK * "\ncheck_sysimage_packages",
    )
    mktempdir() do root
        depot = joinpath(root, "depot")
        rtc = Base.PkgId(PipeWireAORTC)
        dependency = Base.PkgId(Base.UUID("73e7db08-fa80-4c66-b159-217bdccb5d45"), "ImageDependency")
        extension = Base.PkgId(Base.uuid5(dependency.uuid, "ImageDependencyExt"), "ImageDependencyExt")
        stdlib = Base.PkgId(Base.UUID("6462fe0b-24de-5631-8697-dd941f90decc"), "Sockets")

        function source(id, tree)
            slug = Base.version_slug(id.uuid, Base.SHA1(tree))
            path = joinpath(depot, "packages", id.name, slug, "src", id.name * ".jl")
            mkpath(dirname(path))
            write(path, "")
            return path
        end

        rtc_tree, old_tree, new_tree = "1"^40, "2"^40, "3"^40
        rtc_path = source(rtc, rtc_tree)
        old_dependency = source(dependency, old_tree)
        new_dependency = source(dependency, new_tree)
        ext_path = joinpath(dirname(dirname(old_dependency)), "ext", extension.name * ".jl")
        mkpath(dirname(ext_path))
        write(ext_path, "")

        function project(name, tree)
            directory = mkdir(joinpath(root, name))
            path = joinpath(directory, "Project.toml")
            write(path, """
                [deps]
                PipeWireAORTC = "$(rtc.uuid)"
                """)
            write(joinpath(directory, "Manifest.toml"), """
                manifest_format = "2.0"
                [[deps.PipeWireAORTC]]
                uuid = "$(rtc.uuid)"
                version = "0.7.30"
                git-tree-sha1 = "$rtc_tree"
                deps = ["ImageDependency"]

                [[deps.ImageDependency]]
                uuid = "$(dependency.uuid)"
                version = "1.0.0"
                git-tree-sha1 = "$tree"
                weakdeps = ["Sockets"]

                [deps.ImageDependency.extensions]
                ImageDependencyExt = "Sockets"
                """)
            return path
        end

        before = project("built", old_tree)
        after = project("installed", new_tree)
        preloaded = Dict(rtc => rtc_path, dependency => old_dependency,
                         extension => ext_path, stdlib => Base.manifest_uuid_path(Sys.STDLIB, stdlib))
        pushfirst!(DEPOT_PATH, depot)
        try
            @test Base.invokelatest(check, before, preloaded) === nothing
            @test Base.explicit_manifest_uuid_path(after, rtc) == rtc_path
            @test Base.explicit_manifest_uuid_path(after, dependency) == new_dependency
            # Isolate the dependency mismatch from the corresponding extension.
            delete!(preloaded, extension)
            @test_throws r"different ImageDependency package source" Base.invokelatest(
                check, after, preloaded,
            )
            undeclared = Base.PkgId(Base.UUID("73e7db08-fa80-4c66-b159-217bdccb5d46"), "OtherPackage")
            @test_throws r"OtherPackage is unavailable" Base.invokelatest(
                check, before, merge(preloaded, Dict(undeclared => old_dependency)),
            )
            @test_throws r"does not preload PipeWireAORTC" Base.invokelatest(
                check, before, Dict(dependency => old_dependency),
            )
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

@testset "session environment is applied at exec under the original PID" begin
    script = raw"""
        using PipeWireAORTC
        launch = PipeWireAORTC.SessionLaunch
        key = "PIPEWIREAORTC_TEST_SESSION_VARIABLE"
        haskey(ENV, key) && error("unexpected initial value")
        ENV[launch.ACTIVATION_ENV] = "initial"
        executable = "/bin/sh"
        argv = [executable, "-c",
                raw"test $$ = $1 && test x$PIPEWIREAORTC_TEST_SESSION_VARIABLE = xdeclared && test x${PIPEWIREAORTC_ACTIVATION_SHA256+x} = x",
                "session-environment", string(getpid())]
        launch.apply_session_environment!(Dict(key => "declared"), Dict(key => "declared"),
                                          Dict("julia" => executable, "argv" => argv))
        error("expected exec")
        """
    @test success(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $script`)
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

@testset "Installed Julia services can restart after shared RTC cache replacement" begin
    science = PipeWireAORTC.ScienceExport
    julia = Base.julia_cmd().exec[1]
    mktempdir() do directory
        shared = mkdir(joinpath(directory, "depot"))
        project = mkdir(joinpath(directory, "app with space"))
        package = mkdir(joinpath(directory, "rtc"))
        uuid = "a3e2c7da-f73f-4284-8482-36ac422b34e6"
        write(joinpath(project, "Project.toml"), "[deps]\nPipeWireAORTC = \"$uuid\"\n")
        helper = mkdir(joinpath(directory, "helper"))
        helper_uuid = "c130b872-fe56-40d8-962e-2d12398be2d8"
        write(joinpath(helper, "Project.toml"), "name = \"CacheHelper\"\nuuid = \"$helper_uuid\"\n")
        write(joinpath(mkdir(joinpath(helper, "src")), "CacheHelper.jl"),
            "module CacheHelper\nvalue(args) = last(args)\nend\n")
        write(joinpath(project, "Manifest.toml"), """
            manifest_format = "2.0"
            [[deps.CacheHelper]]
            path = "../helper"
            uuid = "$helper_uuid"
            [[deps.PipeWireAORTC]]
            deps = ["CacheHelper"]
            path = "../rtc"
            uuid = "$uuid"
            version = "0.1.0"
            """)
        write(joinpath(package, "Project.toml"), """
            name = "PipeWireAORTC"
            uuid = "$uuid"
            [deps]
            CacheHelper = "$helper_uuid"
            """)
        source = joinpath(mkdir(joinpath(package, "src")), "PipeWireAORTC.jl")
        write(source, """
            module PipeWireAORTC
            module MediaSession
            using CacheHelper
            main(args) = (print(CacheHelper.value(args)); 0)
            end
            module SessionCLI
            main(args) = (print(join(args, '\\n')); 0)
            end
            end
            """)
        config = "/rtc/file with space"
        service = Cmd(science.rtc_arguments(julia, project, config; installed_cache = true))
        client = joinpath(project, "client")
        sealed = I.installed_launcher(julia; environment = project, legacy = true)
        write(client, sealed)
        chmod(client, 0o755)
        strict = I.installed_launcher(julia; environment = project, installed_cache = true)
        hook = I.install_service_launcher!(client, strict)
        @test hook != client && read(client, String) == sealed
        @test I.install_service_launcher!(hook, strict) == hook
        @test_throws "reserved session hook" I.install_service_launcher!(client, strict)

        unit = "pipewireao-session@test.service"
        runtime = joinpath(directory, "pipewireao-session-test")
        invocation = "a"^32
        spec = Dict("placement" => Dict("session" => Dict("leader-cpu" => 2)),
                    "source-owner" => "detector")
        activation = (; julia, project, digest = "a"^64)
        direct = (; config, environment = Dict(), services = Dict(),
                  requisite = String[], wants = String[])
        launch = PipeWireAORTC.SessionLaunch
        request = launch.Request(project, "/sdk", unit, hook, runtime)
        template(suffix) = read(joinpath(
            PipeWireAORTC.package_root(), "assets/deployment",
            "pipewireao-session$suffix@.service.in",
        ), String)
        render(template; direct = nothing, launcher = hook) = I.installed_unit(
            template, spec; launcher, package = project, prefix = "/sdk",
            executable = "/sdk/bin/rtc", activation, direct,
        )
        managed_unit = render(template(""))
        direct_unit = render(template("-direct"); direct)
        function hook_command(unit_text, directive)
            line = only(filter(startswith(directive), split(unit_text, '\n')))
            return Cmd(Base.shell_split(replace(chopprefix(line, directive),
                "%n" => unit, "%t/pipewireao-session-%i" => runtime,
                "\${INVOCATION_ID}" => invocation)))
        end
        stop = hook_command(managed_unit, "ExecStop=")
        cleanup = hook_command(managed_unit, "ExecStopPost=")
        direct_stop = hook_command(direct_unit, "ExecStop=")
        @test stop.exec == [hook, "stop", "--unit", unit, "--runtime-root", runtime]
        @test direct_stop.exec == [stop.exec; "--direct"]
        @test cleanup.exec == [
            hook, "cleanup", "--invocation", invocation, "--runtime-root", runtime,
            "--source-role", "detector",
        ]
        @test !occursin("ExecStopPost=", direct_unit)
        stop_record = launch.S.ExecCommand(hook, direct_stop.exec, false)
        @test launch.stop_hook_valid([stop_record], request; direct = true)
        legacy_request = launch.Request(project, "/sdk", unit, client, runtime)
        @test !launch.stop_hook_valid([stop_record], legacy_request; direct = true)
        older_template = replace(template(""), I.INSTALLED_COMMAND => "@RTC_COMMAND@")
        older_unit = render(older_template; launcher = client)
        historical_stop = hook_command(older_unit, "ExecStop=")
        @test historical_stop.exec[1] == client
        @test hook_command(older_unit, "ExecStopPost=").exec[1] == client
        withenv("JULIA_DEPOT_PATH" => shared * ":", "JULIA_LOAD_PATH" => "@:@stdlib") do
            @test !success(pipeline(service; stdout = devnull, stderr = devnull))
            @test !isdir(joinpath(shared, "compiled"))
            # The foreground command can build the missing image. Installation
            # must also keep a usable private copy when this shared image exists.
            @test read(Cmd(science.rtc_arguments(julia, project, config)), String) == config
            I.prepare_package_cache(julia, project)
            rm(joinpath(shared, "compiled"); recursive = true)
            @test read(service, String) == config
            for command in (stop, direct_stop, cleanup)
                @test read(command, String) == join(command.exec[2:end], '\n')
            end
            @test !isdir(joinpath(shared, "compiled"))
            @test read(historical_stop, String) == join(historical_stop.exec[2:end], '\n')
            @test isdir(joinpath(shared, "compiled"))
            rm(joinpath(shared, "compiled"); recursive = true)
            cache = joinpath(project, science.RTC_CACHE_DIRECTORY)
            rm(cache; recursive = true)
            @test !success(pipeline(service; stdout = devnull, stderr = devnull))
            for command in (stop, direct_stop, cleanup)
                @test !success(pipeline(command; stdout = devnull, stderr = devnull))
            end
            @test !isdir(cache)
            @test !isdir(joinpath(shared, "compiled"))
            # The managed entry and its re-exec can use different depot settings.
            alternate = mkdir(joinpath(directory, "alternate"))
            settings = I.cache_environment(Dict("JULIA_DEPOT_PATH" => "@PACKAGE@/alternate:",
                "JULIA_LOAD_PATH" => "@:@stdlib", "RTC_LOG" => "@RUNTIME@/log"), directory, "", nothing)
            @test settings == Dict("JULIA_DEPOT_PATH" => alternate * ":")
            I.prepare_package_cache(julia, project; settings)
            @test read(addenv(service, settings...), String) == config
            @test read(service, String) == config
        end
    end
end
