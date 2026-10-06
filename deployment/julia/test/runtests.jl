using Test, PipeWireAODeployment

include("test_native_session_discovery.jl")
include("test_native_session_client.jl")

for name in ("common", "native_control_codec", "native_runner_codec", "native_supervisor_codec", "native_supervisor_coordination", "native_control_client", "native_owner_bootstrap_codec", "native_heart_codec", "native_acquisition_lifecycle_codec", "native_calibration_action_codec", "native_calibration_action_client", "runner_commands", "native_runner_coordination", "deploy", "native_acquisition_deployment", "native_bootstrap_deployment", "native_bootstrap_exports", "control_interrupt", "observation_boundary", "observation_loop", "preparation_timeout", "heart_configuration", "heart_owner", "exports", "calibration_export_name", "heart_calibration_export", "heart_classic_calibration_export", "heart_classic_transfer", "heart_correction_export", "campaigns", "copper", "calibration_method", "package")
    suite = Module(Symbol("Suite_", name))
    Base.include(suite, joinpath(@__DIR__, "test_" * name * ".jl"))
end

suite = Module(:Suite_source_client)
Base.include(suite, joinpath(@__DIR__, "source_client.jl"))
