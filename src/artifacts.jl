module Artifacts

using FITSIO
using SHA

export FITSArtifact, PreparedArtifact, prepare, pack

const MAX_FITS_BYTES = 512 * 1024 * 1024
const MAX_IMAGE_BYTES = 256 * 1024 * 1024
const TARGET_TYPES = (Float32, Float64, UInt8, UInt16, UInt32, Bool)

"""
    FITSArtifact(path; hdu=1, axes=nothing)

Select a FITS image using a one-based HDU number. `axes` lists FITS NAXIS
dimensions in the owner's logical dimension order, as for `permutedims`.
For example, `axes=(2,1)` maps an image to logical row/column dimensions.
Multidimensional images require an explicit permutation, including square images.
Vectors may omit `axes` to select `(1,)`.
"""
struct FITSArtifact
    path::String
    hdu::Int
    axes::Union{Nothing,Tuple{Vararg{Int}}}
    function FITSArtifact(path::AbstractString; hdu=1, axes=nothing)
        !isempty(path) && !occursin('\0', path) ||
            throw(ArgumentError("FITS artifact path must be nonempty and contain no NUL"))
        hdu isa Integer && !(hdu isa Bool) && 1 <= hdu <= typemax(Int) ||
            throw(ArgumentError("FITS HDU must be a positive one-based integer"))
        permutation = if axes === nothing
            nothing
        else
            axes isa Union{Tuple,AbstractVector} ||
                throw(ArgumentError("FITS axes must be an integer permutation"))
            !isempty(axes) && all(x -> x isa Integer && !(x isa Bool) &&
                1 <= x <= typemax(Int), axes) ||
                throw(ArgumentError("FITS axes must be positive integers"))
            values = Tuple(Int(x) for x in axes)
            sort(collect(values)) == collect(1:length(values)) ||
                throw(ArgumentError("FITS axes must be a permutation of 1:rank"))
            values
        end
        new(abspath(path), Int(hdu), permutation)
    end
end

"""
Owned logical calibration data and provenance of its preparation. The hashes in
`provenance` describe the original FITS snapshot and the prepared values at return;
later caller mutations of `data` do not update that preparation record.
"""
struct PreparedArtifact{T,N}
    data::Array{T,N}
    provenance::Dict{String,Any}
end

function checked_shape(shape, width::Int)
    shape isa Union{Tuple,AbstractVector} && !isempty(shape) ||
        throw(ArgumentError("artifact shape must be a nonempty tuple or vector"))
    count = 1
    for dimension in shape
        dimension isa Integer && !(dimension isa Bool) && 1 <= dimension <= typemax(Int) ||
            throw(ArgumentError("artifact dimensions must be positive integers"))
        dimension <= MAX_IMAGE_BYTES ÷ width ÷ count ||
            throw(ArgumentError("decoded artifact exceeds 256 MiB"))
        count *= Int(dimension)
    end
    return Tuple(Int(dimension) for dimension in shape)
end

function snapshot(path::String; check)
    check()
    isfile(path) && !islink(path) ||
        throw(ArgumentError("FITS artifact must be a regular file: $path"))
    before = lstat(path)
    isfile(before) && before.size <= MAX_FITS_BYTES ||
        throw(ArgumentError("FITS artifact must be a regular file of at most 512 MiB"))
    flags = Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_NOFOLLOW | Base.Filesystem.JL_O_NONBLOCK
    file = Base.Filesystem.open(path, flags)
    try
        opened = stat(file)
        isfile(opened) && opened.device == before.device && opened.inode == before.inode &&
            opened.size == before.size && opened.mtime == before.mtime && opened.ctime == before.ctime ||
            throw(ArgumentError("FITS artifact changed before open"))
        bytes = Vector{UInt8}(undef, Int(opened.size))
        offset = 0
        while offset < length(bytes)
            check()
            count = min(1024 * 1024, length(bytes) - offset)
            read!(file, view(bytes, (offset + 1):(offset + count)))
            offset += count
        end
        after = stat(file)
        after.size == opened.size && after.mtime == opened.mtime && after.ctime == opened.ctime ||
            throw(ArgumentError("FITS artifact changed during capture"))
        check()
        length(bytes) >= 9 && view(bytes, 1:9) == codeunits("SIMPLE  =") ||
            throw(ArgumentError("artifact must be an uncompressed FITS file with a primary HDU"))
        return bytes
    finally
        close(file)
    end
end

function image_axes(source::FITSArtifact, rank::Int)
    permutation = source.axes
    if permutation === nothing
        rank == 1 || throw(ArgumentError("multidimensional FITS artifacts require explicit axes"))
        permutation = (1,)
    end
    length(permutation) == rank ||
        throw(ArgumentError("FITS axis permutation rank differs from image rank"))
    return permutation
end

function convert_value(::Type{Bool}, value)
    isfinite(value) && (value == 0 || value == 1) ||
        throw(ArgumentError("Bool artifact values must be exactly zero or one"))
    return value == 1
end

function convert_value(::Type{T}, value) where {T<:Unsigned}
    isfinite(value) || throw(ArgumentError("artifact contains a nonfinite value"))
    converted = try
        T(value)
    catch exception
        exception isa InexactError || rethrow()
        throw(ArgumentError("artifact value $value is not exactly representable as $T"))
    end
    converted == value || throw(ArgumentError("artifact integer conversion must be exact"))
    return converted
end

function convert_value(::Type{T}, value) where {T<:AbstractFloat}
    isfinite(value) || throw(ArgumentError("artifact contains a nonfinite value"))
    converted = T(value)
    isfinite(converted) || throw(ArgumentError("artifact value overflows $T"))
    return converted
end

unsigned_word(value::Bool) = UInt8(value)
unsigned_word(value::Unsigned) = value
unsigned_word(value::Float32) = reinterpret(UInt32, value)
unsigned_word(value::Float64) = reinterpret(UInt64, value)

function packed_bytes(data::Array{T,N}; check=()->nothing) where {T,N}
    check()
    checked_shape(size(data), sizeof(T))
    bytes = Vector{UInt8}(undef, length(data) * sizeof(T))
    # Iterating reversed logical dimensions gives last-index-contiguous order.
    storage = PermutedDimsArray(data, Tuple(reverse(1:N)))
    position = 1
    for (index, value) in enumerate(storage)
        (index - 1) % 65536 == 0 && check()
        word = unsigned_word(value)
        for shift in 0:8:(8 * sizeof(T) - 1)
            bytes[position] = UInt8((word >> shift) & 0xff)
            position += 1
        end
    end
    check()
    return bytes
end

"""
    pack(artifact::PreparedArtifact; check=()->nothing)

Return transient little-endian, row-major bytes of the artifact's current data.
Bool values use zero/one bytes. This operation does not write files.
"""
pack(artifact::PreparedArtifact; check=()->nothing) = packed_bytes(artifact.data; check)

"""
    prepare(source::FITSArtifact, ::Type{T}, shape; check=()->nothing)

Capture the original FITS in memory, validate its selected image and explicit axis
mapping, and return an owned `Array{T}` with logical `shape` plus provenance.
Supported targets are Float32, Float64, UInt8, UInt16, UInt32 and Bool. Integer
conversion is exact; Bool requires zero/one. Float rounding follows the target
type, with nonfinite values and overflow rejected. No calibration or unit
conversion is performed. Both the source image and target are limited to 256 MiB.
The optional `check` callback can cancel preparation by throwing; its exception
propagates, and no prepared result is returned. No file is written.
"""
function prepare(source::FITSArtifact, ::Type{T}, shape; check=()->nothing) where T
    check()
    T in TARGET_TYPES || throw(ArgumentError("unsupported artifact target type: $T"))
    target_shape = checked_shape(shape, sizeof(T))
    original = snapshot(source.path; check)
    original_hash = bytes2hex(SHA.sha256(original))
    check()
    # A byte-vector FITS handle has no filename parser and cannot reopen the source.
    return FITS(original, "r") do fits
        source.hdu <= length(fits) || throw(ArgumentError("FITS HDU does not exist: $(source.hdu)"))
        image = fits[source.hdu]
        image isa ImageHDU || throw(ArgumentError("artifact HDU must contain an image"))
        header = read_header(image)
        haskey(header, "BLANK") && throw(ArgumentError("FITS BLANK/null masks are not supported"))
        haskey(header, "ZIMAGE") && throw(ArgumentError("compressed FITS images are not supported"))
        source_shape = checked_shape(size(image), sizeof(eltype(image)))
        permutation = image_axes(source, length(source_shape))
        logical_shape = Tuple(source_shape[axis] for axis in permutation)
        logical_shape == target_shape || throw(DimensionMismatch(
            "FITS logical shape $logical_shape differs from target $target_shape"))
        source_data = read(image)
        check()
        logical = PermutedDimsArray(source_data, permutation)
        data = Array{T}(undef, target_shape)
        for (position, index) in enumerate(CartesianIndices(logical))
            (position - 1) % 65536 == 0 && check()
            data[index] = convert_value(T, logical[index])
        end
        provenance = Dict{String,Any}(
            "source" => source.path, "original_sha256" => original_hash,
            "sha256" => bytes2hex(SHA.sha256(packed_bytes(data; check))),
            "hdu" => source.hdu, "axes" => collect(permutation),
            "source_type" => string(eltype(image)), "source_shape" => collect(source_shape),
            "target_type" => string(T), "target_shape" => collect(target_shape),
            "byte_order" => "little-endian", "storage_order" => "row-major",
            "conversion" => T <: AbstractFloat ? "finite float conversion; target rounding allowed; overflow rejected" :
                T === Bool ? "exact zero/one conversion" : "exact integer conversion")
        for key in ("BSCALE", "BZERO", "BUNIT")
            haskey(header, key) && (provenance[key] = header[key])
        end
        check()
        return PreparedArtifact(data, provenance)
    end
end

end
