"""
    calibration_context(document, directory)

Copy calibration metadata, resolving `kind: fits` mappings relative to the
owning context file's `directory` to owned, typed row-major vectors.
FITS references require `kind`, `path`, `hdu`, `axes`, `shape`, `type` and
`storage_order`. The shape and explicit FITS axes select the logical array,
and `storage_order` must be `row-major`. An existing `sha256` field is accepted.
Prepared arrays together must fit the existing artifact image byte limit.
"""
calibration_context(document, directory) =
    _calibration_context(document, directory, Ref(Artifacts.MAX_IMAGE_BYTES))

_calibration_context(document, directory, remaining) = _calibration_context(
    document,
    directory,
    remaining,
    (source, T, shape, _) -> Artifacts.read_fits_data(source, T, shape),
)

function _calibration_context(document::AbstractDict, directory, remaining, read_fits)
    if get(document, "kind", nothing) == "fits"
        required = (
            "kind", "path", "hdu", "axes", "shape", "type", "storage_order"
        )
        fields(document, (required..., "sha256"), required, "calibration FITS reference")
        document["storage_order"] == "row-major" ||
            throw(ArgumentError("calibration FITS storage_order must be row-major"))
        haskey(document, "sha256") && !valid_sha256(document["sha256"]) && throw(
            ArgumentError(
                "calibration FITS sha256 must be 64 lowercase hexadecimal digits"
            ),
        )
        T = get(
            Dict(string(T) => T for T in Artifacts.TARGET_TYPES), document["type"], nothing
        )
        T === nothing && throw(ArgumentError("unsupported calibration FITS type"))
        calibration_axes(document["axes"])
        source = Artifacts.FITSArtifact(
            D.relative_asset(directory, document["path"]);
            hdu = document["hdu"],
            axes = document["axes"],
        )
        shape = Artifacts.checked_shape(document["shape"], sizeof(T))
        bytes = prod(shape) * sizeof(T)
        bytes <= remaining[] ||
            throw(ArgumentError("calibration FITS arrays together exceed 256 MiB"))
        remaining[] -= bytes
        data = read_fits(source, T, shape, document)
        return vec(permutedims(data, Tuple(reverse(1:ndims(data)))))
    end
    return Dict(
        key => _calibration_context(value, directory, remaining, read_fits) for
        (key, value) in document
    )
end
_calibration_context(document::AbstractVector, directory, remaining, read_fits) =
    map(value -> _calibration_context(value, directory, remaining, read_fits), document)
_calibration_context(document, directory, remaining, read_fits) = deepcopy(document)
calibration_axes(value::Union{Tuple,AbstractVector}) = value
calibration_axes(value) =
    throw(ArgumentError("calibration FITS axes must be an explicit permutation"))
