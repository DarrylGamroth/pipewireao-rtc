"""Scientific preparation requiring AOS without a transport or HIL dependency."""
module PipeWireAORTCOpticsExt

import AdaptiveOpticsSim.Optics
import PipeWireAORTC.InstrumentConfiguration as IC

function IC._influence_modes(
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
