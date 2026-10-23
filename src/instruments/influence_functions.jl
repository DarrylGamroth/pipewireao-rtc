# FITS is an instrument calibration input, decoded only during preparation.
const _MAX_INFLUENCE_BYTES = 512 * 1024 * 1024
const _INFLUENCE_FIELDS = (:path, :hdu, :axes, :command_indices, :sample_origin,
    :sample_pitch, :opd_scale_m, :reference_command_m)

function _influence_integer(value::Integer, upper, name)
    1 <= value <= upper || throw(ArgumentError("$name must be a bounded positive integer"))
    return Int(value)
end

_influence_integer(::Bool, _, name) = throw(ArgumentError("$name must not be Bool"))
_influence_integer(_, _, name) = throw(ArgumentError("$name must be an integer"))

function _influence_number(value::Real, name)
    isfinite(value) || throw(ArgumentError("$name must be finite"))
    number = Float64(value)
    isfinite(number) || throw(ArgumentError("$name must be representable as finite Float64"))
    return number
end

_influence_number(::Bool, name) = throw(ArgumentError("$name must not be Bool"))
_influence_number(_, name) = throw(ArgumentError("$name must be a real number"))

function _influence_tuple(value::Union{Tuple,AbstractVector}, count, convert, name)
    length(value) == count || throw(ArgumentError("$name must have $count elements"))
    return Tuple(convert(element) for element in value)
end

_influence_tuple(_, _, _, name) = throw(ArgumentError("$name must be a tuple or vector"))

function _influence_spec(spec::NamedTuple, count)
    length(spec) == length(_INFLUENCE_FIELDS) &&
        Set(keys(spec)) == Set(_INFLUENCE_FIELDS) || throw(ArgumentError(
            "influence_functions requires exactly $(_INFLUENCE_FIELDS)",
        ))
    hdu = _influence_integer(spec.hdu, typemax(Int), "influence HDU")
    axes = _influence_tuple(spec.axes, 3,
        v -> _influence_integer(v, 3, "influence axis"), "influence axes")
    Set(axes) == Set((1, 2, 3)) || throw(ArgumentError("influence axes must be a permutation of 1:3"))
    command_indices = _influence_tuple(spec.command_indices, count,
        v -> _influence_integer(v, count, "influence command index"), "influence command_indices")
    length(Set(command_indices)) == count || throw(ArgumentError(
        "influence command_indices must be a full permutation of physical commands",
    ))
    sample_origin = _influence_tuple(spec.sample_origin, 2,
        v -> _influence_number(v, "influence sample origin"), "influence sample_origin")
    sample_pitch = _influence_tuple(spec.sample_pitch, 2,
        v -> _influence_number(v, "influence sample pitch"), "influence sample_pitch")
    all(>(0), sample_pitch) || throw(ArgumentError("influence sample_pitch must be positive"))
    opd_scale_m = _influence_number(spec.opd_scale_m, "influence opd_scale_m")
    opd_scale_m > 0 || throw(ArgumentError("influence opd_scale_m must be positive"))
    reference_command_m = _influence_number(spec.reference_command_m, "influence reference_command_m")
    !iszero(reference_command_m) || throw(ArgumentError("influence reference_command_m must be nonzero"))
    scale = opd_scale_m / reference_command_m
    isfinite(scale) && !iszero(scale) || throw(ArgumentError("influence OPD conversion must be finite and nonzero"))
    return (; hdu, axes, command_indices, sample_origin, sample_pitch,
        opd_scale_m, reference_command_m)
end

# Division before multiplication bounds each intermediate, including malformed
# FITS dimensions, without allowing integer wraparound or a decode allocation.
function _influence_storage_size(shape, element_bytes, name)
    bytes = element_bytes
    for extent in shape
        0 < extent <= _MAX_INFLUENCE_BYTES ÷ bytes || throw(ArgumentError(
            "$name exceeds the 512 MiB influence storage limit or has empty dimensions",
        ))
        bytes *= extent
    end
    return bytes
end

function _influence_snapshot(path::AbstractString)
    isvalid(path) && !isempty(path) && !occursin('\0', path) ||
        throw(ArgumentError("influence path must be a nonempty valid file path"))
    isfile(path) || throw(ArgumentError("influence path must be a regular file"))
    bytes = open(path, "r") do io
        info = stat(io)
        isfile(info) && 0 < info.size <= _MAX_INFLUENCE_BYTES ||
            throw(ArgumentError("influence file must be a regular file of at most 512 MiB"))
        snapshot = read(io, Int(info.size) + 1)
        length(snapshot) == info.size || throw(ArgumentError("influence file changed size during read"))
        snapshot
    end
    # Reject gzip and other whole-file compression before CFITSIO can expand it.
    length(bytes) >= 80 && bytes[1:8] == codeunits("SIMPLE  ") ||
        throw(ArgumentError("influence file must be an uncompressed FITS file"))
    return bytes
end

_influence_snapshot(_) = throw(ArgumentError("influence path must be a file path string"))

function _influence_image_shape(hdu::FITSIO.ImageHDU{T,3}, metadata, count) where {T}
    T <: Real && T !== Bool || throw(ArgumentError("influence FITS image must contain real numbers"))
    header = FITSIO.read_header(hdu)
    any(key -> haskey(header, key), ("BLANK", "ZIMAGE", "ZCMPTYPE", "ZBITPIX", "ZNAXIS")) &&
        throw(ArgumentError("influence FITS image must not use BLANK or compression"))
    native_shape = size(hdu)
    _influence_storage_size(native_shape, sizeof(T), "decoded FITS image")
    logical_shape = ntuple(i -> native_shape[metadata.axes[i]], 3)
    logical_shape[1] >= 2 && logical_shape[2] >= 2 || throw(ArgumentError(
        "influence FITS image requires at least two samples along each spatial axis",
    ))
    logical_shape[3] == count || throw(ArgumentError("influence FITS plane count must equal physical command count"))
    return (logical_shape[1], logical_shape[2])
end

_influence_image_shape(_, _, _) = throw(ArgumentError("influence HDU must be a three-dimensional real FITS image"))

function _influence_sample_coordinates(metadata, spatial_shape, description, resolution, registration)
    columns, rows = description.layout.grid_shape
    half = resolution / 2
    # AOS pupil arrays index increasing normalized x first, increasing y second.
    # The mirror description indexes source columns rightward and rows downward.
    coordinates = ntuple(2) do axis
        centre = (axis == 1 ? columns : rows) / 2 + 0.5
        direction = axis == 1 ? 1 : -1
        values = [((centre + direction * ((i - (resolution + 1) / 2) / half) /
            registration.actuator_pitch_pupil_radius - metadata.sample_origin[axis]) /
            metadata.sample_pitch[axis] + 1) for i in 1:resolution]
        all(isfinite, values) && minimum(values) >= 1 && maximum(values) <= spatial_shape[axis] ||
            throw(ArgumentError("influence sampling domain does not cover the full target pupil square"))
        values
    end
    return coordinates
end

"""
    _load_influence_functions(spec, description, pupil_resolution, pupil_registration)

Snapshot a supplied FITS calibration and prepare dimensionless, physical-command
ordered response columns. FITS logical spatial samples refer to the intrinsic
mirror source grid. Bilinear interpolation covers the entire square pupil; no
extrapolation, aperture masking, normalization, or reflection factor is added.
"""
function _load_influence_functions(spec::NamedTuple, description, pupil_resolution, pupil_registration)
    count = command_count(description)
    metadata = _influence_spec(spec, count)
    resolution = _influence_integer(pupil_resolution, typemax(Int), "pupil resolution")
    _influence_storage_size((resolution, resolution, count), sizeof(Float32), "influence output")
    registration = _pupil_registration(pupil_registration)
    _require_pupil_geometry(description, registration)
    snapshot = _influence_snapshot(spec.path)
    digest = bytes2hex(SHA.sha256(snapshot))
    return FITSIO.FITS(snapshot) do file
        metadata.hdu <= length(file) || throw(ArgumentError("influence HDU is outside the FITS file"))
        hdu = file[metadata.hdu]
        spatial_shape = _influence_image_shape(hdu, metadata, count)
        column_samples, row_samples = _influence_sample_coordinates(
            metadata, spatial_shape, description, resolution, registration)
        native = read(hdu)
        all(isfinite, native) || throw(ArgumentError("influence FITS samples must all be finite"))
        logical = PermutedDimsArray(native, metadata.axes)
        modes = Matrix{Float32}(undef, resolution * resolution, count)
        scale = metadata.opd_scale_m / metadata.reference_command_m
        for (plane, command) in pairs(metadata.command_indices)
            interpolant = Interpolations.interpolate(view(logical, :, :, plane),
                Interpolations.BSpline(Interpolations.Linear()))
            for j in 1:resolution, i in 1:resolution
                value = Float32(interpolant(column_samples[i], row_samples[j]) * scale)
                isfinite(value) || throw(ArgumentError("resampled influence response must remain finite Float32"))
                modes[i + (j - 1) * resolution, command] = value
            end
        end
        provenance = (; sha256=digest, metadata..., spatial_shape,
            pupil_registration=registration, pupil_resolution=resolution, interpolation="bilinear")
        return (; modes, provenance)
    end
end

_load_influence_functions(_, _, _, _) = throw(ArgumentError("influence_functions must be a NamedTuple"))
