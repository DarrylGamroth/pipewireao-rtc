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
    haskey(registration,:actuator_pitch_pupil_radius) &&
        all(key -> key in (:actuator_pitch_pupil_radius,:rotation_deg,:flip_y,:offset_actuators),keys(registration)) || throw(ArgumentError(
        "pupil registration requires actuator_pitch_pupil_radius and optional rotation_deg, flip_y and offset_actuators",
    ))
    pitch = registration.actuator_pitch_pupil_radius
    _valid_pitch(pitch) ||
        throw(ArgumentError("pupil registration actuator_pitch_pupil_radius must be finite and positive"))
    owned_pitch = Float64(pitch)
    pitch32 = Float32(owned_pitch)
    isfinite(owned_pitch) && owned_pitch > 0 && isfinite(pitch32) && pitch32 > 0 ||
        throw(ArgumentError("pupil registration actuator_pitch_pupil_radius must preserve finite positive Float64 and Float32 values"))
    rotation = get(registration,:rotation_deg,0.0)
    InstrumentDefinition.finite_bound(rotation) && isfinite(Float64(rotation)) ||
        throw(ArgumentError("pupil registration rotation_deg must be a finite Float64 real number"))
    rotation_deg = rem(Float64(rotation),360.0)
    flip_y = get(registration,:flip_y,false)
    flip_y isa Bool || throw(ArgumentError("pupil registration flip_y must be Boolean"))
    offsets = get(registration,:offset_actuators,(0.0,0.0))
    (offsets isa Tuple || offsets isa AbstractVector) && length(offsets) == 2 &&
        all(value -> InstrumentDefinition.finite_bound(value) && isfinite(Float64(value)),offsets) ||
        throw(ArgumentError("pupil registration offset_actuators must contain two finite Float64 real numbers"))
    offset_actuators = map(Float64,Tuple(offsets))
    # Preserve the original value and fingerprint for omitted or explicit defaults.
    iszero(rotation_deg) && !flip_y && all(iszero,offset_actuators) &&
        return (;actuator_pitch_pupil_radius=owned_pitch)
    return (;actuator_pitch_pupil_radius=owned_pitch,rotation_deg,flip_y,offset_actuators)
end

_pupil_registration(registration) = throw(ArgumentError("pupil registration must be a NamedTuple"))

_valid_pitch(pitch::Real) = isfinite(pitch) && pitch > 0
_valid_pitch(::Bool) = false
_valid_pitch(pitch) = false

function _require_pupil_geometry(description::NamedTuple, registration::NamedTuple)
    axis_count = _mirror_axis_count(description)
    registration = _pupil_registration(registration)
    pitch = Float32(registration.actuator_pitch_pupil_radius)
    extent = Float32(axis_count - 1) / 2f0 * pitch
    isfinite(extent) || throw(ArgumentError("pupil registration must preserve finite Float32 coordinates"))
    if haskey(registration,:rotation_deg)
        # Bound the whole source grid and both frame origins before coordinate
        # conversion. This also leaves headroom for native-axis GUI arithmetic.
        extent64 = (axis_count - 1) / 2 * registration.actuator_pitch_pupil_radius
        dx,dy = registration.actuator_pitch_pupil_radius .* registration.offset_actuators
        sine,cosine = sincosd(registration.rotation_deg)
        reflected_dy = registration.flip_y ? -dy : dy
        half_width = (abs(sine) + abs(cosine)) * extent64
        bounds = (registration.actuator_pitch_pupil_radius,extent64,dx,dy,
            half_width + abs(cosine*dx - sine*reflected_dy),
            half_width + abs(sine*dx + cosine*reflected_dy))
        all(InstrumentDefinition.renderable_pupil_value,bounds) || throw(ArgumentError(
            "pupil registration must preserve Float32-renderable native and pupil coordinates"))
    end
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

"""
Return command-indexed normalized pupil x/y coordinates. Native mirror x points
right and y upward; registration subtracts the pupil-center offset, reflects y
when requested, then rotates counterclockwise. Command order is unchanged.
"""
function actuator_coordinates(
    description::NamedTuple, ::Type{T}=Float32;
    pupil_registration,
) where {T<:AbstractFloat}
    registration = _pupil_registration(pupil_registration)
    _require_pupil_geometry(description, registration)
    index_map = actuator_index_map(description)
    coordinates = Matrix{T}(undef, 2, command_count(description))
    if haskey(registration,:rotation_deg)
        pitch = registration.actuator_pitch_pupil_radius
        centre = (_mirror_axis_count(description) + 1) / 2
        dx,dy = pitch .* registration.offset_actuators
        sine,cosine = sincosd(registration.rotation_deg)
        for source_row in axes(index_map, 1), column in axes(index_map, 2)
            command_index = Int(index_map[source_row, column])
            iszero(command_index) && continue
            x = (column - centre) * pitch - dx
            y = (centre - source_row) * pitch - dy
            registration.flip_y && (y = -y)
            coordinates[1,command_index] = T(cosine*x - sine*y)
            coordinates[2,command_index] = T(sine*x + cosine*y)
        end
        return coordinates
    end
    # Keep the established pitch-only arithmetic unchanged, including rounding.
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
