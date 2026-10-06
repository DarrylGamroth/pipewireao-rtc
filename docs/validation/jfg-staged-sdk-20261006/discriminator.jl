using Test, TOML, PipeWireAODeployment
const HIL = PipeWireAODeployment.HILExport
mktempdir() do package
    owner = joinpath(package, "jfg/deployment")
    sdk = joinpath(package, "hil/packages/PipeWireAO")
    mkpath(owner); mkpath(sdk)
    path = joinpath(owner, "Project.toml")
    write(path, """
    [deps]
    PipeWireAO = "5d815c25-fdf3-4508-8205-db8be38ea5d0"
    [compat]
    PipeWireAO = "=0.6.13"
    julia = "1.12"
    """)
    write(joinpath(sdk, "Project.toml"), """
    name = "PipeWireAO"
    uuid = "5d815c25-fdf3-4508-8205-db8be38ea5d0"
    version = "0.6.16"
    """)
    HIL.julia_owner_environment(package)
    staged = TOML.parsefile(joinpath(sdk, "Project.toml"))
    actual = TOML.parsefile(path)
    println("staged SDK version=", staged["version"], ", exported compatibility=", actual["compat"]["PipeWireAO"])
    @test actual["compat"]["PipeWireAO"] == "=" * staged["version"]
end
