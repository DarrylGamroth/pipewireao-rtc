"""Configuration export, one-shot session tools and calibration orchestration.

Scientific algorithms and frame execution remain in their owning packages.
"""
module PipeWireAORTC

VERSION >= v"1.12" || error("PipeWireAORTC requires Julia 1.12 or newer; found $VERSION")

"""Return this package's current location, including after precompiled relocation."""
package_root() = pkgdir(@__MODULE__)

"""Find required deployment resources in an installed SDK or source checkout."""
function resource_root()
    root = joinpath(package_root(), "assets", "deployment")
    all(isdir(joinpath(root, name)) for name in ("hil", "templates")) &&
    isfile(joinpath(root, "pipewireao-session@.service.in")) ||
        throw(ArgumentError("deployment resources are incomplete: $root"))
    return root
end

"""Map an operational source to a contained, stable evidence-copy path."""
function source_relative_path(path::AbstractString)
    absolute = abspath(path)
    for (root, prefix) in ((package_root(), "julia"),)
        relative = relpath(absolute, root)
        (
            relative == ".." ||
            startswith(relative, ".." * string(Base.Filesystem.path_separator))
        ) && continue
        # SDK source evidence retains its Julia project prefix after relocation.
        return isempty(prefix) ? relative : joinpath(prefix, relative)
    end
    throw(ArgumentError("source is outside deployment package and resources: $path"))
end


include("common.jl")
include("schemas.jl")
include("artifacts.jl")
include("deployment/placement.jl")
include("deployment/systemd_owners.jl")
include("deployment/runtime_export.jl")
include("deployment/science_export.jl")
include("control/control_codec.jl")
include("control/runner_codec.jl")
include("configuration_store.jl")
include("configuration_store_cli.jl")
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
include("control/acquisition_lifecycle_runtime.jl")
include("control/acquisition_lifecycle_client.jl")
include("control/calibration_action_client.jl")
include("control/calibration_endpoint.jl")
include("calibration_acquisition.jl")
include("calibration_preparation.jl")
include("calibration_cli.jl")
include("runner_commands.jl")
include("control/session_discovery.jl")
include("control/session_client.jl")
include("configuration/deployment_configuration.jl")
include("instrument_definition.jl")
include("instrument_configuration.jl")
include("analysis.jl")
include("diagnostics/phase_timing.jl")
include("simulation/runtime.jl")
include("deployment/session_runtime.jl")

include("configuration/session_configuration.jl")
include("deployment/session_launch.jl")
include("deployment/session_install.jl")
include("session_cli.jl")
include("correction/loops.jl")
include("correction/recovery.jl")
include("correction/physical_offsets.jl")
include("correction/supervision.jl")
include("graphs/runtime.jl")
include("deployment/instrument_export.jl")
include("instrument_calibration.jl")
include("simulator_configuration.jl")
include("management_cli.jl")

public Analysis,
    InstrumentExport,
    InstrumentCalibration,
    InstrumentConfiguration,
    InstrumentDefinition,
    ConfigurationStore,
    ConfigurationStoreCLI,
    SimulatorConfiguration,
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

include("media_session/MediaSession.jl")

end
