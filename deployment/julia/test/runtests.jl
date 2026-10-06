using Test, PipeWireAODeployment

for name in ("common", "native_control_codec", "native_runner_codec", "native_control_client", "native_heart_codec", "native_acquisition_lifecycle_codec", "runner_commands", "native_runner_coordination", "deploy", "control_interrupt", "preparation_timeout", "heart_configuration", "heart_owner", "exports", "heart_calibration_export", "heart_classic_calibration_export", "heart_classic_transfer", "heart_correction_export", "campaigns", "copper", "calibration_method", "package")
    suite = Module(Symbol("Suite_", name))
    Base.include(suite, joinpath(@__DIR__, "test_" * name * ".jl"))
end

suite = Module(:Suite_source_client)
Base.include(suite, joinpath(@__DIR__, "source_client.jl"))
