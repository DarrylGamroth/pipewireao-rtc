using Test, PipeWireAORTC, TOML
const P = PipeWireAORTC

@testset "optional three-package graph integration" begin
    project = TOML.parsefile(joinpath(P.package_root(), "Project.toml"))
    graph_packages = ("FilterGraphAlgorithms", "FilterGraphs", "FilterGraphPipeWire")
    @test project["weakdeps"]["FilterGraphs"] == "8053475d-7091-4a8a-adbc-8ed688b6da8d"
    @test Set(project["extensions"]["PipeWireAORTCGraphExt"]) == Set(graph_packages)
    for retired in ("JuliaFilterGraph", "FilterGraphIsland")
        @test !haskey(project["weakdeps"], retired)
        for extension in (
            "PipeWireAORTCGraphExt",
            "PipeWireAORTCCalibrationExt",
            "PipeWireAORTCOffsetsExt",
        )
            @test retired ∉ project["extensions"][extension]
        end
    end
    @test all(name -> !haskey(project["deps"], name), graph_packages)
    @test all(name -> haskey(project["deps"], name), ("Agent", "Clocks", "Hsm"))
    @test project["extensions"]["PipeWireAORTCOpticsExt"] == "AdaptiveOpticsSim"
    @test Base.ispublic(P, :CaptureFiles)
end

@testset "callable package modules and operational scripts" begin
    @test Base.PkgId(P).uuid == Base.UUID("a3e2c7da-f73f-4284-8482-36ac422b34e6")
    manifest = TOML.parsefile(joinpath(P.package_root(), "Manifest.toml"))
    self = filter(
        row -> row["uuid"] == string(Base.PkgId(P).uuid),
        [
            merge(item, Dict("name" => name)) for (name, rows) in manifest["deps"] for
            item in rows
        ],
    )
    @test only(self)["name"] == "PipeWireAORTC"
    @test P.SessionCLI.SessionConfiguration === P.SessionConfiguration
    @test P.SessionCLI.SessionLaunch === P.SessionLaunch
    @test P.SessionCLI.SessionInstall === P.SessionInstall
    for name in (
        :SessionConfiguration,
        :SessionInstall,
        :SessionRuntime,
        :SessionClient,
        :CalibrationEndpoint,
        :CalibrationAcquisition,
        :CalibrationCLI,
        :SessionCLI,
        :OwnerBootstrapRuntime,
        :ParameterSource,
        :SourceControl,
    )
        @test Base.ispublic(P, name)
        @test parentmodule(getproperty(P, name)) === P
    end
    for (script, name) in (
        ("configuration", :SessionConfiguration),
        ("launch", :SessionLaunch),
        ("install", :SessionInstall),
        ("cli", :SessionCLI),
    )
        sandbox = Module(gensym(:OperationalScript))
        Base.include(sandbox, joinpath(P.package_root(), "session_" * script * ".jl"))
        @test Base.invokelatest(getproperty, sandbox, name) === getproperty(P, name)
    end
end
