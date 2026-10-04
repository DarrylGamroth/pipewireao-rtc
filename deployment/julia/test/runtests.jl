using Test, PipeWireAODeployment

for name in ("common", "deploy", "preparation_timeout", "heart_configuration", "heart_owner", "exports", "heart_calibration_export", "heart_classic_calibration_export", "heart_classic_transfer", "heart_correction_export", "campaigns", "copper", "calibration_method", "package")
    suite = Module(Symbol("Suite_", name))
    Base.include(suite, joinpath(@__DIR__, "test_" * name * ".jl"))
end
