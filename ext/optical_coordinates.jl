# Command-coordinate semantics are selected while preparing the calibration,
# independently of optional diagnostic arrays attached to its result.
"Command coordinates selected during preparation, independent of optional inverse diagnostics."
abstract type AbstractOpticalCommandCoordinates end
"Projection rows follow physical mirror command order."
struct PhysicalCommandCoordinates <: AbstractOpticalCommandCoordinates end
"Projection rows follow active VDM order, with an explicit physical completion matrix."
struct CompletedVDMCoordinates <: AbstractOpticalCommandCoordinates end

optical_inverse_name(::PhysicalCommandCoordinates) = "physical-to-modes"
optical_inverse_name(::CompletedVDMCoordinates) = "vdm-to-modes"
optical_command_count(::PhysicalCommandCoordinates, dimensions) =
    dimensions["physical_command_count"]
optical_command_count(::CompletedVDMCoordinates, dimensions) =
    dimensions["active_vdm_count"]
optical_controlled_key(::PhysicalCommandCoordinates) = "controlled_physical_commands"
optical_controlled_key(::CompletedVDMCoordinates) = "controlled_active_vdm_commands"

optical_coordinate_parameters!(::PhysicalCommandCoordinates, parameters, calibration) =
    nothing
function optical_coordinate_parameters!(::CompletedVDMCoordinates, parameters, calibration)
    parameters["active-to-full"] = calibration.completion
    parameters["vdm-to-pdm"] = Matrix{Float32}(
        LA.I,
        size(calibration.completion, 1),
        size(calibration.completion, 1),
    )
    return nothing
end
optical_coordinate_units!(::PhysicalCommandCoordinates, units) = nothing
function optical_coordinate_units!(::CompletedVDMCoordinates, units)
    units["active-to-full"] = "native command / native command"
    units["vdm-to-pdm"] = "native command / native command"
    return nothing
end
optical_projection_names(::PhysicalCommandCoordinates) =
    ("command-projection", "physical-to-modes")
optical_projection_names(::CompletedVDMCoordinates) =
    ("command-projection", "vdm-to-modes", "active-to-full", "vdm-to-pdm")

# This inverse is an optional measured diagnostic in physical coordinates, not
# the discriminant selecting physical versus completed VDM command coordinates.
optical_feedback_diagnostic!(diagnostics, ::Nothing) = nothing
function optical_feedback_diagnostic!(diagnostics, inverse::AbstractMatrix)
    diagnostics["physical-to-modes"] = inverse
    return nothing
end
optical_feedback_units!(units, ::Nothing, report) = nothing
function optical_feedback_units!(units, inverse::AbstractMatrix, report)
    units["physical-to-modes"] =
        "m OPD / "*get(
            get(report["provenance"], "mirror_response", Dict()),
            "command_units",
            "native command",
        )
    return nothing
end
optical_feedback_names(::Nothing) = ()
optical_feedback_names(::AbstractMatrix) = ("physical-to-modes",)
