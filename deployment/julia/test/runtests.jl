using Test, PipeWireAODeployment

for name in ("common", "deploy", "heart_configuration", "heart_owner", "exports", "campaigns", "copper", "package")
    suite = Module(Symbol("Suite_", name))
    Base.include(suite, joinpath(@__DIR__, "test_" * name * ".jl"))
end
