"""
    calibration_context(document, directory)

Copy calibration metadata, resolving `kind: fits` mappings relative to the
owning context file's `directory` to owned, typed row-major vectors.
FITS references require exactly `kind`, `path`, `hdu`, `axes`,
`shape`, `type`, `sha256` and `storage_order`. The shape and explicit FITS axes
select the logical array; `storage_order` must be `row-major`. The SHA-256 binds
the original file snapshot used for preparation. Prepared arrays together must
fit the existing artifact image byte limit. No source file is modified.
"""
calibration_context(document, directory) =
    _calibration_context(document, directory, Ref(Artifacts.MAX_IMAGE_BYTES))

function _calibration_context(document, directory, remaining)
    if document isa AbstractDict
        if get(document, "kind", nothing) == "fits"
            required = ("kind", "path", "hdu", "axes", "shape", "type", "sha256", "storage_order")
            fields(document, required, required, "calibration FITS reference")
            document["storage_order"] == "row-major" ||
                throw(ArgumentError("calibration FITS storage_order must be row-major"))
            hash = document["sha256"]
            hash isa String && occursin(r"^[0-9a-f]{64}$", hash) ||
                throw(ArgumentError("calibration FITS sha256 must be 64 lowercase hexadecimal digits"))
            T = get(Dict(string(T) => T for T in Artifacts.TARGET_TYPES), document["type"], nothing)
            T === nothing && throw(ArgumentError("unsupported calibration FITS type"))
            document["axes"] isa Union{Tuple,AbstractVector} ||
                throw(ArgumentError("calibration FITS axes must be an explicit permutation"))
            source = Artifacts.FITSArtifact(D.relative_asset(directory, document["path"]);
                hdu=document["hdu"], axes=document["axes"])
            shape = Artifacts.checked_shape(document["shape"], sizeof(T))
            bytes = prod(shape) * sizeof(T)
            bytes <= remaining[] ||
                throw(ArgumentError("calibration FITS arrays together exceed 256 MiB"))
            remaining[] -= bytes
            original = Artifacts.snapshot(source.path; check=()->nothing)
            bytes2hex(SHA.sha256(original)) == hash ||
                throw(ArgumentError("calibration FITS sha256 differs from the file snapshot"))
            prepared = Artifacts.prepare_snapshot(source, T, shape, original)
            return vec(permutedims(prepared.data, Tuple(reverse(1:ndims(prepared.data)))))
        end
        return Dict(key => _calibration_context(value, directory, remaining) for (key, value) in document)
    elseif document isa AbstractVector
        return map(value -> _calibration_context(value, directory, remaining), document)
    end
    return deepcopy(document)
end
