using Test, PipeWireAORTC, TOML
const P = PipeWireAORTC
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
