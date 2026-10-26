"""Read a bounded, generic physical mirror description into immutable values."""
function read_mirror_description(path::AbstractString)
    document = InstrumentDefinition._mirror_description(path).document
    return _instrument_seal(document)
end

read_mirror_description(path) = throw(ArgumentError("mirror description path must be a string"))

# Keep this cold parser's owned tree separate from InstrumentDefinition's JSON
# publication representation. Objects become named tuples; arrays become tuples.
_instrument_seal(value::AbstractDict) = NamedTuple{Tuple(Symbol.(collect(keys(value))))}(
    Tuple(_instrument_seal(item) for item in values(value)))
_instrument_seal(value::AbstractVector) = Tuple(_instrument_seal(item) for item in value)
_instrument_seal(value) = value

"Return the number of physical commands in a parsed mirror description."
command_count(description::NamedTuple) = length(description.layout.command_positions)

function _mirror_axis_count(description::NamedTuple)
    columns, rows = description.layout.grid_shape
    columns == rows && columns > 1 || throw(ArgumentError(
        "mirror geometry requires a square source grid with at least two positions per axis",
    ))
    return columns
end

function _pupil_registration(registration::NamedTuple)
    keys(registration) == (:actuator_pitch_pupil_radius,) || throw(ArgumentError(
        "pupil registration requires exactly :actuator_pitch_pupil_radius",
    ))
    pitch = registration.actuator_pitch_pupil_radius
    _valid_pitch(pitch) ||
        throw(ArgumentError("pupil registration actuator_pitch_pupil_radius must be finite and positive"))
    owned_pitch = Float64(pitch)
    pitch32 = Float32(owned_pitch)
    isfinite(owned_pitch) && owned_pitch > 0 && isfinite(pitch32) && pitch32 > 0 ||
        throw(ArgumentError("pupil registration actuator_pitch_pupil_radius must preserve finite positive Float64 and Float32 values"))
    return (; actuator_pitch_pupil_radius=owned_pitch)
end

_pupil_registration(registration) = throw(ArgumentError("pupil registration must be a NamedTuple"))

_valid_pitch(pitch::Real) = isfinite(pitch) && pitch > 0
_valid_pitch(::Bool) = false
_valid_pitch(pitch) = false

function _require_pupil_geometry(description::NamedTuple, registration::NamedTuple)
    axis_count = _mirror_axis_count(description)
    pitch = Float32(_pupil_registration(registration).actuator_pitch_pupil_radius)
    extent = Float32(axis_count - 1) / 2f0 * pitch
    isfinite(extent) || throw(ArgumentError("pupil registration must preserve finite Float32 coordinates"))
    return nothing
end

"Resolve an optional circular clear aperture in the registered pupil coordinates."
function clear_aperture(description::NamedTuple, registration::NamedTuple)
    hasproperty(description,:clear_aperture_diameter_m) || return NamedTuple()
    pitch = _pupil_registration(registration).actuator_pitch_pupil_radius
    radius = (Float64(description.clear_aperture_diameter_m) /
        Float64(description.actuator_pitch_m)) * (pitch / 2)
    aperture = (;radius)
    InstrumentDefinition.validate_clear_aperture(json_value(aperture))
    return (;clear_aperture=aperture)
end

"Build a command-indexed source-grid map from a physical-order mirror description."
function actuator_index_map(description::NamedTuple)
    columns, rows = description.layout.grid_shape
    index_map = zeros(UInt16, rows, columns)
    for (command_index, (column, row)) in pairs(description.layout.command_positions)
        index_map[row, column] = UInt16(command_index)
    end
    return index_map
end

function actuator_coordinates(
    description::NamedTuple, ::Type{T}=Float32;
    pupil_registration,
) where {T<:AbstractFloat}
    registration = _pupil_registration(pupil_registration)
    _require_pupil_geometry(description, registration)
    index_map = actuator_index_map(description)
    coordinates = Matrix{T}(undef, 2, command_count(description))
    pitch = T(registration.actuator_pitch_pupil_radius)
    centre = T(_mirror_axis_count(description) + 1) / T(2)
    for source_row in axes(index_map, 1), column in axes(index_map, 2)
        command_index = Int(index_map[source_row, column])
        iszero(command_index) && continue
        coordinates[1, command_index] = T(column - centre) * pitch
        coordinates[2, command_index] = T(centre - source_row) * pitch
    end
    return coordinates
end

function actuator_grid_indices(description::NamedTuple, ::Type{T}=Int32) where {T<:Integer}
    axis_count = _mirror_axis_count(description)
    index_map = actuator_index_map(description)
    indices = Vector{T}(undef, command_count(description))
    linear_indices = LinearIndices((axis_count, axis_count))
    for source_row in axes(index_map, 1), column in axes(index_map, 2)
        command_index = Int(index_map[source_row, column])
        iszero(command_index) && continue
        increasing_y_index = axis_count + 1 - source_row
        indices[command_index] = T(linear_indices[column, increasing_y_index])
    end
    return indices
end

"""Return normalized source-grid positions for Zernike and Fourier sampling."""
function source_grid_coordinates(description::NamedTuple)
    columns, rows = description.layout.grid_shape
    positions = description.layout.command_positions
    centre_column, centre_row = (columns + 1) / 2, (rows + 1) / 2
    zernike_positions = map(positions) do (column, row)
        ((column - centre_column) / (columns / 2),
            (row - centre_row) / (rows / 2))
    end
    fourier_positions = map(positions) do (column, row)
        (Float64(Float32(columns == 1 ? 0.0 : (column - centre_column) / (columns - 1))),
            Float64(Float32(rows == 1 ? 0.0 : (row - centre_row) / (rows - 1))))
    end
    return (; zernike_positions, fourier_positions)
end
