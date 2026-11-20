"""Scientific preparation for authored AOS instrument graphs."""
module PipeWireAORTCOpticsExt

using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
import AdaptiveOpticsSim.Optics
import PipeWireAORTC
import PipeWireAORTC: AOSOwner

const Backends = AdaptiveOpticsSim.Backends

include("aos/optical_observation.jl")
include("aos/optical_model_paths.jl")

"Compose AOS scientific factories with application-relative optical model paths."
configured_graph_node_types(directory = nothing) =
    instrument_optical_factories(builtin_graph_node_types(), directory)

function copy_to_target(device, values)
    destination = Backends.allocate_device_array(device, eltype(values), size(values)...)
    copyto!(destination, values)
    return destination
end

include("aos/instruments.jl")

function Instruments._influence_modes(
    samples::AbstractArray{<:AbstractFloat,3},
    grid_shape,
    metadata,
    resolution,
    registration,
)
    return Optics.resample_measured_influences(
        samples;
        grid_shape,
        sample_origin = metadata.sample_origin,
        sample_pitch = metadata.sample_pitch,
        pupil_resolution = resolution,
        actuator_pitch_pupil_radius = registration.actuator_pitch_pupil_radius,
        command_indices = metadata.command_indices,
        opd_scale_m = metadata.opd_scale_m,
        reference_command_m = metadata.reference_command_m,
    )
end

end
