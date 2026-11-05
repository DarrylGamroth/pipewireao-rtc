# Prepared optical measurement semantics; image arrays retain their existing
# representation and row-major selected-pixel order.
"Measurement semantics selected during optical preparation, independent of diagnostic fields."
abstract type AbstractOpticalMeasurementKind end
"Row-major selected image pixels; signed residual admission remains explicit."
struct SelectedPixels <: AbstractOpticalMeasurementKind end
"The calibrated X=column, Y=row center-of-gravity measurement."
struct CenterOfGravity <: AbstractOpticalMeasurementKind end

optical_identity_fields(::SelectedPixels) = ("reconstructor", "reference", "mask")
optical_identity_fields(::CenterOfGravity) =
    ("reconstructor", "reference", "mask", "coordinates")

optical_measurement_coordinates(::SelectedPixels, mask) = nothing
optical_measurement_coordinates(::CenterOfGravity, mask) =
    optical_centroid_coordinates(mask)

# Probe observations require image validation. Already prepared reference images
# and held-out observations retain the original measurement call sequence.
optical_measurement(::SelectedPixels, image, mask, coordinates, signed) =
    optical_pixels(optical_image(image; signed), mask)
optical_measurement(::CenterOfGravity, image, mask, coordinates, signed) =
    optical_centroid(image, mask, coordinates)
optical_measurement(image, branch) =
    optical_measurement(branch.measurement_kind, image, branch)
optical_measurement(::SelectedPixels, image, branch) = optical_pixels(image, branch.mask)
optical_measurement(::CenterOfGravity, image, branch) =
    optical_centroid(image, branch.mask, branch.coordinates)

optical_fitted_modes(::SelectedPixels, selected, count) = collect(1:count)
optical_fitted_modes(::CenterOfGravity, selected, count) = selected
optical_recovery_error(::SelectedPixels, recovery, selection, selected) =
    LA.norm(recovery-selection)/sqrt(length(selected))
optical_recovery_error(::CenterOfGravity, recovery, selection, selected) =
    LA.norm(recovery[selected, selected]-selection[selected, selected])/sqrt(
        length(selected),
    )

optical_branch(kind::SelectedPixels, branch, coordinates, reference) =
    merge(branch, (; measurement_kind = kind))
optical_branch(kind::CenterOfGravity, branch, coordinates, reference) =
    merge(branch, (; measurement_kind = kind, coordinates, reference_centroid = reference))

require_optical_centroid(::SelectedPixels) =
    throw(ArgumentError("measurement nulling requires a centroid branch"))
require_optical_centroid(::CenterOfGravity) = nothing
optical_measurement_name(::SelectedPixels, signed) =
    signed ? "chopped-pixel-residual" : "intensity"
optical_measurement_name(::CenterOfGravity, signed) = "center-of-gravity"
optical_measurement_report!(::SelectedPixels, report) = nothing
function optical_measurement_report!(::CenterOfGravity, report)
    report["measurement_units"] = "px"
    report["coordinate_order"] = "X=column,Y=row; one-based pixel centers"
    report["measurement_algorithm"] = "FilterGraphAlgorithms.center-of-gravity-f32"
    report["residual_convention"] = "measured centroid minus flat reference centroid, before reconstruction"
    report["thresholds"] = "pixel threshold disabled; flux threshold zero"
    return nothing
end

optical_modal_reference(::SelectedPixels, measurement) =
    -(measurement.reconstructor*optical_measurement(measurement.reference, measurement))
optical_modal_reference(::CenterOfGravity, measurement) =
    zeros(Float32, size(measurement.reconstructor, 1))
optical_measurement_parameters!(::SelectedPixels, parameters, prefix, measurement) = nothing
function optical_measurement_parameters!(::CenterOfGravity, parameters, prefix, measurement)
    parameters[prefix*"coordinates"] = measurement.coordinates
    return nothing
end
optical_measurement_diagnostics!(::SelectedPixels, diagnostics, prefix, measurement) =
    nothing
function optical_measurement_diagnostics!(
    ::CenterOfGravity,
    diagnostics,
    prefix,
    measurement,
)
    diagnostics[prefix*"reference-centroid"] = measurement.reference_centroid
    return nothing
end
optical_reference_image_units(::SelectedPixels, name, report) =
    get(report["branches"][string(name)], "measurement_units", "1")
optical_reference_image_units(::CenterOfGravity, name, report) =
    get(get(report["provenance"], "observation_units", Dict()), string(name), "1")

optical_measurement_count(::SelectedPixels, measurement) = count(measurement.mask)
optical_measurement_count(::CenterOfGravity, measurement) = 2
optical_selection_matches(::SelectedPixels, measurement, frame, dimensions) =
    haskey(frame, "image_shape") ||
    count(measurement.mask) == dimensions["selected_pixel_count"]
optical_selection_matches(::CenterOfGravity, measurement, frame, dimensions) = true
optical_measurement_context!(::SelectedPixels, context, measurement) = nothing
function optical_measurement_context!(::CenterOfGravity, context, measurement)
    context["reference_centroid"] = Float64.(measurement.reference_centroid)
    return nothing
end
validate_optical_measurement_graph(::SelectedPixels, graph, name, measurement) = nothing
validate_optical_measurement_graph(::CenterOfGravity, graph, name, measurement) =
    validate_optical_centroid_graph(graph, name, measurement)
