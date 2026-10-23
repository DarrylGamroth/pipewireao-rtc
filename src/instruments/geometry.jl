"""Read a bounded, generic physical mirror description into immutable values."""
function read_mirror_description(path::AbstractString)
    isvalid(path) && !isempty(path) && !occursin('\0', path) ||
        throw(ArgumentError("mirror description path must be a nonempty valid file path"))
    isfile(path) || throw(ArgumentError("mirror description must be a regular file"))
    bytes = open(path) do io
        read(io, 64 * 1024 + 1)
    end
    length(bytes) <= 64 * 1024 || throw(ArgumentError("mirror description exceeds 64 KiB"))
    json = String(bytes)
    isvalid(json) || throw(ArgumentError("mirror description is not valid UTF-8"))
    parsed = try
        JSON.parse(json; dicttype=Dict{String,Any}, duplicate_keys=:error, maxdepth=64)
    catch error
        throw(_mirror_json_error(error))
    end
    document = Common.json_number(parsed)
    InstrumentDefinition.object_value(document) ||
        throw(ArgumentError("mirror description requires a JSON object"))
    InstrumentDefinition.bounded(document)
    Set(keys(document)) == Set(("schema_version", "id", "manufacturer", "model", "layout")) &&
        get(document, "schema_version", nothing) === 1 ||
        throw(ArgumentError("expected mirror description schema version 1"))
    for key in ("id", "manufacturer", "model")
        InstrumentDefinition.nonempty_text(get(document, key, nothing)) ||
            throw(ArgumentError("invalid mirror $key"))
    end
    layout = get(document, "layout", nothing)
    InstrumentDefinition.object_value(layout) ||
        throw(ArgumentError("mirror description requires a layout object"))
    positions = get(layout, "command_positions", nothing)
    InstrumentDefinition.array_value(positions) && 1 <= length(positions) <= 16384 ||
        throw(ArgumentError("mirror description requires a bounded positive command count"))
    InstrumentDefinition.mirror_layout(layout, length(positions))
    return _instrument_seal(document)
end

read_mirror_description(path) = throw(ArgumentError("mirror description path must be a string"))

_mirror_json_error(error::JSON.DuplicateKeyError) = ArgumentError("duplicate mirror description field")
_mirror_json_error(error) = error

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
    keys(registration) == (:actuator_pitch,) || throw(ArgumentError(
        "pupil registration requires exactly :actuator_pitch",
    ))
    pitch = registration.actuator_pitch
    _valid_pitch(pitch) ||
        throw(ArgumentError("pupil registration actuator_pitch must be finite and positive"))
    owned_pitch = Float64(pitch)
    pitch32 = Float32(owned_pitch)
    isfinite(owned_pitch) && owned_pitch > 0 && isfinite(pitch32) && pitch32 > 0 ||
        throw(ArgumentError("pupil registration actuator_pitch must preserve finite positive Float64 and Float32 values"))
    return (; actuator_pitch=owned_pitch)
end

_pupil_registration(registration) = throw(ArgumentError("pupil registration must be a NamedTuple"))

_valid_pitch(pitch::Real) = isfinite(pitch) && pitch > 0
_valid_pitch(::Bool) = false
_valid_pitch(pitch) = false

function _require_pupil_geometry(description::NamedTuple, registration::NamedTuple)
    axis_count = _mirror_axis_count(description)
    pitch = Float32(_pupil_registration(registration).actuator_pitch)
    extent = Float32(axis_count - 1) / 2f0 * pitch
    isfinite(extent) || throw(ArgumentError("pupil registration must preserve finite Float32 coordinates"))
    return nothing
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
    pitch = T(registration.actuator_pitch)
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
