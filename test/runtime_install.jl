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
        source = joinpath(directory, "sealed export")
        @test P.InstrumentExport.prepare(
            authored,
            source;
            profile,
            prefix,
            manifest = joinpath(environment, "Manifest.toml"),
        ) == source
        @test file_hashes(authored) == authored_before
        @test TOML.parsefile(joinpath(source, "Project.toml")) == project
        sealed = D.profile(joinpath(source, "deployment.conf"), prefix)["artifacts"]
        before = file_hashes(source)
        destination = joinpath(directory, "installed")
        @test P.SessionInstall.install((;
            package = source, destination, pipewire_prefix = prefix
        )) == destination
        @test file_hashes(source) == before
        @test !ispath(joinpath(destination, "julia"))
        @test !ispath(joinpath(destination, "test"))
        @test D.profile(joinpath(destination, "deployment.conf"), prefix)["artifacts"] ==
            sealed
        @test all(
            P.Common.sha256_file(joinpath(destination, name)) == hash for
            (name, hash) in sealed
        )
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
        # The software environment relocates; the generated systemd unit retains
        # installation-specific absolute paths and must be regenerated to use it.
        unit = read(joinpath(relocated, "systemd/pipewireao-session@.service"), String)
        @test occursin(destination, unit)
    end
end
