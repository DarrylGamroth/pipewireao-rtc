"""Configuration export, one-shot session tools and calibration orchestration.

Scientific algorithms and frame execution remain in their owning packages.
"""
module PipeWireAORTC

public Analysis,
    InstrumentExport,
    InstrumentCalibration,
    CaptureFiles,
    InstrumentConfiguration,
    InstrumentDefinition,
    ConfigurationStore,
    ConfigurationStoreCLI,
    ManagementCLI,
    AOSOwner,
    Artifacts,
    SessionConfiguration,
    SessionInstall,
    SessionRuntime,
    SessionClient,
    CalibrationEndpoint,
    CalibrationAcquisition,
    CalibrationPreparation,
    CalibrationCLI,
    SessionCLI,
    OwnerBootstrapRuntime,
    ParameterSource,
    SourceControl,
    GraphOwner,
    CorrectionRecovery,
    CorrectionSupervision,
    MediaSession

VERSION >= v"1.13" || error("PipeWireAORTC requires Julia 1.13 or newer; found $VERSION")

"""Return this package's current location, including after precompiled relocation."""
package_root() = pkgdir(@__MODULE__)

"""Find required deployment resources relative to the installed package."""
function resource_root()
    root = joinpath(package_root(), "assets", "deployment")
    all(isdir(joinpath(root, name)) for name in ("hil", "templates")) &&
    isfile(joinpath(root, "pipewireao-session@.service.in")) ||
        throw(ArgumentError("deployment resources are incomplete: $root"))
    return root
end

include("common.jl")
include("configuration/schemas.jl")
include("deployment/artifacts.jl")
include("deployment/placement.jl")
include("deployment/systemd_owners.jl")
include("deployment/runtime_export.jl")
include("deployment/science_export.jl")
include("control/control_codec.jl")
include("control/runner_codec.jl")
include("configuration/store.jl")
include("configuration/store_cli.jl")
include("control/control_client.jl")
include("control/control_endpoint.jl")
include("control/session_codec.jl")
include("control/session_profile.jl")
include("control/owner_bootstrap_codec.jl")
include("control/owner_bootstrap_runtime.jl")
include("control/source_control.jl")
include("control/parameter_source.jl")
include("control/owner_bootstrap_client.jl")
include("control/acquisition_lifecycle_codec.jl")
include("control/calibration_action_codec.jl")
include("control/acquisition_lifecycle_client.jl")
include("control/calibration_action_client.jl")
include("calibration/capture_files.jl")
include("control/calibration_endpoint.jl")
include("calibration/acquisition.jl")
include("calibration/preparation.jl")
include("calibration/cli.jl")
include("control/runner_commands.jl")
include("control/session_discovery.jl")
include("control/session_client.jl")
include("configuration/deployment_configuration.jl")
include("instruments/definition.jl")
include("instruments/configuration.jl")
include("analysis/Analysis.jl")
include("simulation/configuration.jl")
include("deployment/session_runtime.jl")

include("configuration/session_configuration.jl")
include("deployment/session_launch.jl")
include("deployment/session_install.jl")
include("deployment/session_cli.jl")
include("correction/loops.jl")
include("correction/recovery.jl")
include("correction/physical_offsets.jl")
include("correction/supervision.jl")
include("graphs/runtime.jl")
include("deployment/instrument_export.jl")
include("calibration/instrument.jl")
include("deployment/management_cli.jl")

include("media_session/MediaSession.jl")

end
