"""Cold composition of public AOC inverses with declared command/reference maps.

This helper never acquires data or changes a controller. Columns of `forward`
are controller commands in physical µm OPD; rows of `interaction` are the
deployed WFS measurements. Its products are candidates until independently
validated and installed by the deployment owner.
"""
module CalibrationInverseAnalysis

using LinearAlgebra
using AdaptiveOpticsCalibration
const AOC = AdaptiveOpticsCalibration
const Reconstructors = AOC.Reconstructors

function finite_matrix(values, name)
    Base.require_one_based_indexing(values)
    all(isfinite, values) || throw(ArgumentError("nonfinite $name"))
    all(>(0), size(values)) || throw(ArgumentError("empty $name"))
    return Matrix{Float64}(values)
end

"""Remove the component parallel to a frozen nonzero flat-lamp reference.

The rank-one update avoids constructing a measurement-count squared projector.
Use on the training operator before inverse fitting, and on the resulting
inverse's input through `reject_reference_input`; both steps are required.
"""
function reject_reference(values::AbstractMatrix{<:Real}, reference::AbstractVector{<:Real})
    matrix = finite_matrix(values, "response operator")
    Base.require_one_based_indexing(reference)
    length(reference) == size(matrix, 1) || throw(DimensionMismatch("reference measurement extent"))
    r = Float64.(reference)
    all(isfinite, r) || throw(ArgumentError("nonfinite reference"))
    scale = norm(r)
    isfinite(scale) && scale > 0 || throw(ArgumentError("reference must have finite nonzero norm"))
    r ./= scale
    return matrix - r * (r' * matrix)
end

function reject_reference_input(values::AbstractMatrix{<:Real}, reference::AbstractVector{<:Real})
    return permutedims(reject_reference(permutedims(values), reference))
end

"""Factor a physical command map while preserving exact zero wire coordinates.

This is a cold geometric calculation. `rtol` is a numerical map-rank tolerance,
not an optical sensitivity or instrument acceptance threshold.
"""
function physical_coordinates(forward::AbstractMatrix{<:Real};
                              rtol=maximum(size(forward)) * eps(Float64))
    matrix = finite_matrix(forward, "physical command map")
    rtol isa Real && isfinite(rtol) && rtol >= 0 || throw(ArgumentError("invalid map rank tolerance"))
    active = findall(column -> any(!iszero, column), eachcol(matrix))
    isempty(active) && throw(ArgumentError("physical command map has no actuated coordinates"))
    factors = svd(matrix[:, active]; full=false)
    retained = findall(>(rtol * maximum(factors.S)), factors.S)
    isempty(retained) && throw(ArgumentError("physical command map has zero numerical rank"))
    basis = factors.U[:, retained]
    to_controller = zeros(Float64, size(matrix, 2), length(retained))
    to_controller[active, :] = factors.V[:, retained] * Diagonal(inv.(factors.S[retained]))
    return (; forward=matrix, basis, to_controller, active,
        null_coordinates=setdiff(collect(axes(matrix, 2)), active),
        singular_values=factors.S, rank=length(retained), rank_rtol=Float64(rtol),
        composition_error=norm(matrix * to_controller - basis))
end

"""Build a baseline-rejecting inverse in orthonormal physical coordinates.

Fit K = AOC(method, Q D U), then publish R = W K Q, where B W = U.
The packed Float32 product keeps exactly unactuated wire rows exactly zero.
No optical rank, cutoff, uncertainty or scientific acceptance is chosen here.
"""
function candidate(interaction::AbstractMatrix{<:Real},
                   forward::AbstractMatrix{<:Real},
                   reference::AbstractVector{<:Real},
                   method::Reconstructors.AbstractSVDInverse)
    matrix = finite_matrix(interaction, "interaction matrix")
    coordinates = physical_coordinates(forward)
    size(matrix, 2) == size(coordinates.forward, 1) ||
        throw(DimensionMismatch("physical interaction/map extents"))
    physical_response = matrix * coordinates.basis
    projected_response = reject_reference(physical_response, reference)
    specification = Reconstructors.ReconstructorSpecification(
        size(matrix, 1), coordinates.rank, Float64)
    plan = AOC.prepare(method, specification)
    result = AOC.process(plan, Reconstructors.SVDReconstructorInputs(projected_response))
    inverse = reject_reference_input(
        coordinates.to_controller * Reconstructors.reconstructor(result), reference)
    packed = Float32.(inverse)
    all(isfinite, packed) || throw(ArgumentError("inverse cannot be represented as finite Float32"))
    for row in coordinates.null_coordinates
        all(iszero, view(packed, row, :)) || error("unactuated wire coordinate became nonzero")
    end
    return (; matrix=packed, projected_response, physical_response, coordinates,
        singular_values=Reconstructors.singular_values(result),
        effective_rank=Reconstructors.effective_rank(result),
        rejected_response_frobenius=norm(physical_response - projected_response),
        total_response_frobenius=norm(physical_response),
        packed_reference_command_norm=norm(coordinates.forward * (Float64.(packed) * Float64.(reference))))
end

end
