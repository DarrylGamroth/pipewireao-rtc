"""Configuration export, one-shot session tools and calibration orchestration.

Scientific algorithms and frame execution remain in their owning packages.
"""
module PipeWireAODeployment

VERSION >= v"1.12" || error("PipeWireAODeployment requires Julia 1.12 or newer; found $VERSION")

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
include("placement.jl")
include("systemd_owners.jl")
include("runtime_export.jl")
include("science_export.jl")
include("native_control_codec.jl")
include("native_runner_codec.jl")
include("native_control_client.jl")
include("native_control_endpoint.jl")
include("native_session_codec.jl")
include("native_session_profile.jl")
include("native_owner_bootstrap_codec.jl")
include("native_owner_bootstrap_runtime.jl")
include("native_parameter_source.jl")
include("native_owner_bootstrap_client.jl")
include("native_acquisition_lifecycle_codec.jl")
include("native_calibration_action_codec.jl")
include("native_acquisition_lifecycle_runtime.jl")
include("native_acquisition_lifecycle_client.jl")
include("native_calibration_action_client.jl")
include("calibration_acquisition.jl")
include("calibration_cli.jl")
include("runner_commands.jl")
include("native_session_discovery.jl")
include("native_session_client.jl")
include("deployment_configuration.jl")
include("wireplumber_session_runtime.jl")

end
