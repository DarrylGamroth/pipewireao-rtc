# Standalone cold selector. Requires the current RTC version and its dependencies
# in a registry (a temporary local validation registry is sufficient). Uses only
# temporary applications; never starts a core, owner, or service. Run with Julia
# >= 1.13: julia --project=. test/runtime_install.jl
# Add --prepare-only for the offline export regression without registry setup.
using Test, TOML, PipeWireAORTC

const P = PipeWireAORTC
const D = P.DeploymentConfiguration
const E = P.ScienceExport

file_hashes(root) = Dict(
    relpath(joinpath(directory, name), root) =>
        P.Common.sha256_file(joinpath(directory, name)) for
    (directory, _, names) in walkdir(root) for name in names
)

function cold_application(project, code, arguments = String[])
    result = P.Common.run_checked(
        [
            Base.julia_cmd().exec[1],
            "--startup-file=no",
            "--project=" * project,
            "-e",
            code,
            arguments...,
        ];
        env = Dict("JULIA_LOAD_PATH" => "@:@stdlib", "JULIA_PKG_PRECOMPILE_AUTO" => "0"),
        timeout = 180,
    )
    result.returncode == 0 || error(result.stdout * result.stderr)
    return result
end

@testset "registered application cold install and software relocation" begin
    VERSION >= v"1.13" || error("this selector requires Julia >= 1.13")
    prefix = get(ENV, "PIPEWIREAO_PREFIX", nothing)
    prefix === nothing && error("set PIPEWIREAO_PREFIX to a compatible native SDK")
    D.installed_paths(prefix)
    mktempdir() do directory
        source = mkpath(joinpath(directory, "export"))
        project = Dict(
            "deps" => Dict("PipeWireAORTC" => string(Base.PkgId(P).uuid)),
            "compat" => Dict("PipeWireAORTC" => "=" * string(Base.pkgversion(P))),
        )
        open(joinpath(source, "Project.toml"), "w") do io
            TOML.print(io, project; sorted = true)
        end
        # This declared native acquisition source is never launched: the gate
        # covers dependency installation and relocation, not owner readiness.
        owner = Dict(
            "role" => "simulator",
            "instrument" => "classic",
            "control-protocol" => "pipewireao.rtc.calibration-lifecycle/1",
            "control-node" => "install-source",
            "environment" => Dict(),
            "argv" => [
                "julia",
                "--control-node",
                "install-source",
                "--control-instance",
                "@SOURCE_OWNER_INSTANCE@",
                "--profile",
                "classic",
                "--remote",
                "@RUNTIME@/@REMOTE@",
            ],
        )
        spec = Dict(
            "version" => 1,
            "name" => "cold-install",
            "session" => "session.conf",
            "core" => "shared-runtime/core.conf.in",
            "environment" => Dict(),
            "cpu-latency-us" => nothing,
            "client" => Dict(
                role => "shared-runtime/client-simulator.conf.in" for
                role in ("core", "rtc", "session", "simulator")
            ),
            "owners" => [owner],
            "source-owner" => "simulator",
            "node-owners" => Dict(),
            "session-runtime" => Dict(
                "argv" => [
                    "@PACKAGE@/rtc/bin/pipewireao-rtc",
                    "-c",
                    "@RUNTIME@/rtc/rtc.conf",
                ],
                "environment" => Dict(),
            ),
            "runtime" => Dict("kind" => "registered", "project" => "."),
        )
        spec["client"]["rtc"] = "shared-runtime/client-rtc.conf.in"
        spec["runtime-configurations"] = [
            Dict(
                "source" => "rtc/session.yaml",
                "path" => "session.conf",
                "format" => "spa-json",
            ),
        ]
        mkpath(joinpath(source, "rtc"))
        for (name, document) in (
            "instrument.yaml" => Dict(
                "schema_version" => 1,
                "id" => "install-sensor",
                "deformable_mirrors" => Dict(),
                "wavefront_sensors" => Dict(
                    "camera" => Dict(
                        "kind" => "scc",
                        "expected_schema" => "install/frame",
                        "detector" => Dict(
                            "name" => "camera",
                            "rows" => 2,
                            "columns" => 2,
                            "pixel_sampling_m" => [1e-6, 1e-6],
                        ),
                    ),
                ),
            ),
            "rtc/configuration.yaml" => Dict(
                "schema_version" => 1,
                "instrument" => "../instrument.yaml",
                "dimensions" => Dict(),
                "mirror_controls" => "rtc/mirror-controls.yaml",
                "publication" => "instrument.json",
                "calibration_identity" => "sha256:" * "0"^64,
            ),
            "rtc/mirror-controls.yaml" =>
                Dict("schema_version" => 1, "deformable_mirrors" => Dict()),
            "rtc/application.yaml" => spec,
            "rtc/session.yaml" =>
                Dict(section => [] for section in ("sources", "graphs", "sinks", "links")),
        )
            P.Common.write_yaml(joinpath(source, name), document)
        end
        E.write_spa_config(joinpath(source, "rtc/core.conf"), Dict("context.modules" => []))
        processes = Dict{String,Any}(
            role => Dict{String,Any}("cpus" => [2], "leader-cpu" => 2) for
            role in ("core", "rtc", "session", "simulator")
        )
        processes["core"]["data-loops"] = Dict(
            "rtc-data-loop" => [2], "telemetry-loop" => [2]
        )
        processes["rtc"]["data-loops"] = Dict("rtc-data-loop" => [2])
        profile = Dict("scheduling" => Dict("processes" => processes))
        write(joinpath(source, "README.md"), "# Export documentation\n")
        authored = source
        authored_before = file_hashes(authored)
        offline = joinpath(directory, "offline export")
        @test P.InstrumentExport.prepare(authored, offline; profile, prefix) == offline
        @test file_hashes(authored) == authored_before
        @test !ispath(joinpath(offline, "Manifest.toml"))
        @test TOML.parsefile(joinpath(offline, "Project.toml")) == project
        for name in
            ("rtc/configuration.yaml", "rtc/mirror-controls.yaml", "rtc/application.yaml")
            @test read(joinpath(offline, name)) == read(joinpath(authored, name))
        end
        @test isfile(joinpath(offline, "rtc/bin/pipewireao-rtc"))
        @test P.InstrumentDefinition.load(joinpath(offline, "instrument.json")).document["id"] ==
            "install-sensor"
        # A site-supervised detector has no simulator binary or command endpoint.
        independent = joinpath(directory, "independent instrument")
        cp(authored, independent)
        declaration = deepcopy(spec)
        declaration["source-owner"] = "detector"
        declaration["owners"] = [Dict("role" => "detector", "control-protocol" => "external-stream")]
        declaration["client"]["detector"] = pop!(declaration["client"], "simulator")
        external_profile = deepcopy(profile)
        placements = external_profile["scheduling"]["processes"]
        placements["detector"] = pop!(placements, "simulator")
        P.Common.write_yaml(joinpath(independent, "rtc/application.yaml"), declaration)
        destination = joinpath(directory, "external export")
        @test P.InstrumentExport.prepare(independent, destination; profile = external_profile, prefix) == destination
        external_spec = D.decode(joinpath(destination, "deployment.conf"), prefix)
        @test external_spec["owners"] == declaration["owners"]
        @test !ispath(joinpath(destination, "optical-startup"))

        "--prepare-only" in ARGS && return nothing
        # Resolve separately so export never mutates the authored instrument or
        # a sealed application; no copied manifest or source override is used.
        environment = mkpath(joinpath(directory, "dependencies"))
        cp(joinpath(authored, "Project.toml"), joinpath(environment, "Project.toml"))
        cold_application(environment, "using Pkg; Pkg.resolve(); Pkg.instantiate()")
        manifest = TOML.parsefile(joinpath(environment, "Manifest.toml"))
        @test !haskey(manifest, "workspace")
        @test !haskey(manifest["deps"], "Test")
        for entries in values(manifest["deps"]), entry in entries
            @test !haskey(entry, "path")
            @test !haskey(entry, "repo-url")
            @test !haskey(entry, "repo-rev")
        end
        source = joinpath(directory, "registered export")
        @test P.InstrumentExport.prepare(
            authored,
            source;
            profile,
            prefix,
            manifest = joinpath(environment, "Manifest.toml"),
        ) == source
        @test file_hashes(authored) == authored_before
        @test TOML.parsefile(joinpath(source, "Project.toml")) == project
        inventory = D.profile(joinpath(source, "deployment.conf"), prefix)["artifacts"]
        @test all(
            !haskey(inventory, name) for name in
            ("Project.toml", "Manifest.toml", "README.md", "rtc/application.yaml")
        )
        @test all(
            haskey(inventory, name) for name in
            ("session.conf", "shared-runtime/core.conf.in", "instrument.json")
        )
        session = joinpath(source, "session.conf")
        open(session, "a") do io
            write(io, "\n# changed after export\n")
        end
        for name in ("Project.toml", "Manifest.toml", "README.md")
            open(joinpath(source, name), "a") do io
                write(io, "\n# additional comment\n")
            end
        end
        destination = joinpath(directory, "installed")
        options = (; package = source, destination, pipewire_prefix = prefix)
        dangling = joinpath(source, "unavailable")
        incomplete = joinpath(directory, "incomplete")
        symlink("missing", dangling)
        @test_throws Base.IOError P.SessionInstall.install((; options..., destination = incomplete))
        @test !ispath(incomplete) && !islink(incomplete)
        rm(dangling)

        before = file_hashes(source)
        manual = joinpath(source, "manual.md")
        symlink("README.md", manual)
        nested = joinpath(source, "nested-install")
        @test_throws "inside" P.SessionInstall.install((; options..., destination = nested))
        @test !ispath(nested)
        occupied = joinpath(directory, "occupied")
        symlink(source, occupied)
        @test_throws "install destination must be new" P.SessionInstall.install((
            ; options..., destination = occupied,
        ))
        @test islink(occupied) && realpath(occupied) == source
        independent_service_env = P.SessionLaunch.EXTERNAL_SERVICE_ENV
        withenv((key => nothing for key in independent_service_env)...) do
            @test_throws "persistent graph owners require independent core and source bindings" (
                P.SessionInstall.install((; options..., persistent_graph_owners = true))
            )
            @test !ispath(destination) && !islink(destination)
            @test P.SessionInstall.install(options) == destination
        end
        @test !islink(joinpath(destination, "manual.md"))
        @test read(joinpath(destination, "manual.md")) == read(joinpath(source, "README.md"))
        @test islink(manual)
        rm(manual)
        @test file_hashes(source) == before
        @test !ispath(joinpath(destination, "julia"))
        @test !ispath(joinpath(destination, "test"))
        @test D.profile(joinpath(destination, "deployment.conf"), prefix)["artifacts"] ==
            inventory
        @test all(isnothing, values(inventory))
        @test read(joinpath(destination, "session.conf")) == read(session)
        launcher = P.Common.run_checked(
            [
                joinpath(destination, "bin/pipewireao-rtc-session"),
                "unknown-install-selector-command",
            ];
            env = Dict("JULIA_LOAD_PATH" => "@:@stdlib"),
            timeout = 180,
        )
        @test launcher.returncode != 0
        @test occursin("unknown one-shot RTC command", launcher.stderr)
        installed = file_hashes(destination)
        relocated = joinpath(directory, "relocated application")
        mv(destination, relocated)
        code = """
        using Pkg
        Pkg.instantiate()
        using PipeWireAORTC
        P = PipeWireAORTC
        @assert Base.active_project() == joinpath(ARGS[1], "Project.toml")
        @assert Base.pkgversion(P) == VersionNumber(ARGS[2])
        dependency = Pkg.dependencies()[Base.PkgId(P).uuid]
        @assert dependency.is_tracking_registry
        @assert pkgdir(P) == dependency.source
        @assert !startswith(pkgdir(P), ARGS[1] * "/")
        @assert read(joinpath(pkgdir(P), "src/deployment/session_install.jl"), String) == read(ARGS[3], String)
        @assert P.DeploymentConfiguration.application_environment(
            P.Common.read_json(joinpath(ARGS[1], "deployment.conf")), ARGS[1]) == realpath(ARGS[1])
        """
        cold_application(
            relocated,
            code,
            [
                relocated,
                string(Base.pkgversion(P)),
                joinpath(P.package_root(), "src/deployment/session_install.jl"),
            ],
        )
        @test file_hashes(relocated) == installed
        @test file_hashes(source) == before
        # Sealed launchers must match the pinned installer arguments and one
        # of the exact generated scripts, including the historical form.
        sealed_source = joinpath(directory, "export with sealed launcher")
        cp(source, sealed_source)
        sealed_launcher = joinpath(sealed_source, "bin", "pipewireao-rtc-session")
        mkpath(dirname(sealed_launcher))
        julia_executable = Base.julia_cmd().exec[1]
        for (name, legacy, minimal_prepare, historical_publish) in (
            ("preserved launcher", true, false, false),
            ("sealed startup launcher", false, false, true),
            ("sealed external publisher launcher", false, true, true),
            ("sealed preparation launcher", false, true, false),
        )
            sealed_destination = joinpath(directory, name)
            script = P.SessionInstall.installed_launcher(
                julia_executable; environment = sealed_destination, legacy, minimal_prepare, historical_publish
            )
            write(sealed_launcher, script)
            P.InstrumentExport.seal!(sealed_source)
            @test P.SessionInstall.install((;
                package = sealed_source, destination = sealed_destination,
                pipewire_prefix = prefix, julia_executable
            )) == sealed_destination
            installed_launcher = joinpath(sealed_destination, "bin/pipewireao-rtc-session")
            @test read(installed_launcher, String) == script
            activation = P.Common.read_json(joinpath(
                sealed_destination, "systemd", P.SessionLaunch.ACTIVATION_FILE,
            ))
            hook = activation["launcher"]
            @test hook == joinpath(sealed_destination, "bin/pipewireao-rtc-session-hook")
            @test haskey(activation["files"], installed_launcher)
            @test activation["files"][hook] == P.SessionLaunch.graph_file_identity(hook)
            unit = read(joinpath(sealed_destination, "systemd/pipewireao-session@.service"), String)
            @test startswith(only(filter(startswith("ExecStop="), split(unit, '\n'))),
                "ExecStop=\"$hook\" stop --unit %n")
            @test startswith(only(filter(startswith("ExecStopPost="), split(unit, '\n'))),
                "ExecStopPost=\"$hook\" cleanup --invocation \${INVOCATION_ID}")
        end
        sealed_destination = joinpath(directory, "tampered launcher")
        script = P.SessionInstall.installed_launcher(julia_executable; environment = sealed_destination)
        write(sealed_launcher, replace(script, "-O0" => "-O1"))
        P.InstrumentExport.seal!(sealed_source)
        @test_throws "sealed session launcher differs from the selected Julia executable" begin
            P.SessionInstall.install((;
                package = sealed_source, destination = sealed_destination,
                pipewire_prefix = prefix, julia_executable
            ))
        end
        # The software environment relocates; the generated systemd unit retains
        # installation-specific absolute paths and must be regenerated to use it.
        unit = read(joinpath(relocated, "systemd/pipewireao-session@.service"), String)
        @test occursin(destination, unit)
    end
end
