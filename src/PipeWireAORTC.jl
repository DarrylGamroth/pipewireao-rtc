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
        (relative == ".." || startswith(relative, ".." * string(Base.Filesystem.path_separator))) && continue
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
include("native/native_control_codec.jl")
include("native/native_runner_codec.jl")
include("configuration_store.jl")
include("configuration_store_cli.jl")
include("native/native_control_client.jl")
include("native/native_control_endpoint.jl")
include("native/native_session_codec.jl")
include("native/native_session_profile.jl")
include("native/native_owner_bootstrap_codec.jl")
include("owners/native_owner_bootstrap_runtime.jl")
include("owners/native_source_control.jl")
include("owners/native_parameter_source.jl")
include("native/native_owner_bootstrap_client.jl")
include("native/native_acquisition_lifecycle_codec.jl")
include("native/native_calibration_action_codec.jl")
include("owners/native_acquisition_lifecycle_runtime.jl")
include("native/native_acquisition_lifecycle_client.jl")
include("native/native_calibration_action_client.jl")
include("calibration_acquisition.jl")
include("calibration_cli.jl")
include("runner_commands.jl")
include("native/native_session_discovery.jl")
include("native/native_session_client.jl")
include("configuration/deployment_configuration.jl")
include("instrument_definition.jl")
include("instrument_configuration.jl")
include("analysis.jl")
include("owners/phase_timing.jl")
include("owners/aos_owner.jl")
include("deployment/session_runtime.jl")

include("configuration/session_configuration.jl")
include("deployment/session_launch.jl")
include("deployment/session_install.jl")
include("session_cli.jl")
include("owners/correction_loops.jl")
include("owners/correction_recovery.jl")
include("owners/correction_supervision.jl")
include("owners/graph_owner.jl")
include("deployment/instrument_export.jl")
include("instrument_calibration.jl")
include("simulator_configuration.jl")

public Analysis, InstrumentExport, InstrumentCalibration, InstrumentConfiguration, InstrumentDefinition, ConfigurationStore, ConfigurationStoreCLI, SimulatorConfiguration, AOSOwner, Artifacts, SessionConfiguration, SessionInstall, SessionRuntime,
    NativeSessionClient, CalibrationAcquisition, CalibrationCLI, SessionCLI,
    NativeOwnerBootstrapRuntime, NativeParameterSource, NativeSourceControl, GraphOwner,
    CorrectionRecovery, CorrectionSupervision

end
