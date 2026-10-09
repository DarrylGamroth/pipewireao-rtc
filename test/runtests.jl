using Test, PipeWireAODeployment

include("test_native_session_discovery.jl")
include("test_native_session_client.jl")
include("test_calibration_acquisition.jl")
include("test_calibration_install.jl")
include("test_wireplumber_configuration.jl")

for name in ("common", "runtime_export", "systemd_owners", "native_control_codec", "native_runner_codec", "native_control_client", "native_owner_bootstrap_codec", "native_acquisition_lifecycle_codec", "native_acquisition_lifecycle_client", "native_calibration_action_codec", "native_calibration_action_client", "runner_commands", "installed_wireplumber", "package")
    suite = Module(Symbol("Suite_", name))
    Base.include(suite, joinpath(@__DIR__, "test_" * name * ".jl"))
end
