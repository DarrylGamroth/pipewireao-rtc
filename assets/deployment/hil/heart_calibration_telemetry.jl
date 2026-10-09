module HeartCalibrationTelemetry

using SHA

export TelemetryReader, TelemetryFrame, next_frame!, await_frame!,
    classic_response, copper_response, raw_pixels, confirm_probe,
    FrameAssociation, arm_exposure!, associate!

# Independent decoder of HEART's public telemetry file representation. This
# deliberately supports the selected little-endian, revision-2 CPU profile.
const FILE_HEADER_BYTES = 1024
const BUCKET_HEADER_BYTES = 64

function value_at(::Type{T}, bytes, offset) where {T<:Integer}
    last = Base.checked_add(offset, sizeof(T))
    0 <= offset && last <= length(bytes) || throw(ArgumentError("truncated telemetry field"))
    return ltoh(reinterpret(T, bytes[offset + 1:last])[1])
end
value_at(::Type{Float32}, bytes, offset) = reinterpret(Float32, value_at(UInt32, bytes, offset))
value_at(::Type{Float64}, bytes, offset) = reinterpret(Float64, value_at(UInt64, bytes, offset))

struct TelemetrySpec
    tag::String
    datatype::Int32
    rows::Int
    columns::Int
    element_bytes::Int
    data_bytes::Int
end

function read_spec(bytes, expected_tag, expected_datatype, expected_shape)
    nul = findfirst(iszero, @view bytes[1:32])
    nul === nothing && throw(ArgumentError("unterminated telemetry tag"))
    tag = String(bytes[1:nul - 1])
    datatype = value_at(Int32, bytes, 40)
    rows, columns = Int(value_at(UInt32, bytes, 48)), Int(value_at(UInt32, bytes, 52))
    tag == expected_tag && datatype == expected_datatype && (rows, columns) == expected_shape ||
        throw(ArgumentError("telemetry tag, datatype or extent differs from the declared frontend"))
    value_at(UInt32, bytes, 60) == 0 || throw(ArgumentError("telemetry requires row-major storage"))
    element_bytes = datatype == 7 ? 2 : datatype == 13 ? 16 : datatype in (8, 20) ? 4 :
        throw(ArgumentError("unsupported telemetry datatype"))
    value_at(Float64, bytes, 32) == element_bytes || throw(ArgumentError("telemetry element size differs"))
    payload = Base.checked_mul(Base.checked_mul(rows, columns), element_bytes)
    payload > 0 || throw(ArgumentError("empty telemetry extent"))
    data_bytes = Int(value_at(UInt32, bytes, 56))
    data_bytes == cld(payload, 64) * 64 || throw(ArgumentError("invalid telemetry payload alignment"))
    return TelemetrySpec(tag, datatype, rows, columns, element_bytes, data_bytes)
end

struct TelemetryFrame
    spec::TelemetrySpec
    bucket::UInt64
    sync::UInt32
    timestamp_us::Int64
    state::Int16
    progress::UInt16
    required::UInt16
    payload::Vector{UInt8}
end

mutable struct TelemetryReader
    io::IOStream
    spec::TelemetrySpec
    device::UInt64
    inode::UInt64
    maximum_bytes::UInt64
    observed_bytes::UInt64
    frames::UInt64
    last_bucket::Union{Nothing,UInt64}
    closed::Bool
end

function TelemetryReader(path; tag::String, datatype::Integer, shape::Tuple{Int,Int},
    maximum_bytes::UInt64,
)
    ENDIAN_BOM == 0x04030201 || throw(ArgumentError("HEART telemetry profile requires a little-endian host"))
    maximum_bytes >= FILE_HEADER_BYTES || throw(ArgumentError("telemetry budget is too small"))
    islink(path) && throw(ArgumentError("telemetry input must not be a symlink"))
    io = open(path, "r")
    try
        metadata = stat(io)
        isfile(metadata) && FILE_HEADER_BYTES <= metadata.size <= maximum_bytes ||
            throw(ArgumentError("telemetry file size exceeds its bound or header is incomplete"))
        bytes = read(io, FILE_HEADER_BYTES)
        spec = read_spec(bytes, tag, datatype, shape)
        return TelemetryReader(io, spec, UInt64(metadata.device), UInt64(metadata.inode),
            maximum_bytes, UInt64(metadata.size), 0, nothing, false)
    catch
        close(io)
        rethrow()
    end
end

function Base.close(reader::TelemetryReader)
    reader.closed && return nothing
    reader.closed = true
    close(reader.io)
    return nothing
end

"""Consume one committed record; return nothing while the writer is incomplete.

The stream is full rate: any skipped or duplicated CB bucket faults decoding.
Readiness here is file publication only; it does not establish model time,
command adoption, optical validity, or association with an exposure.
"""
function next_frame!(reader::TelemetryReader)
    reader.closed && throw(ArgumentError("telemetry reader is closed"))
    metadata = stat(reader.io)
    UInt64(metadata.device) == reader.device && UInt64(metadata.inode) == reader.inode ||
        throw(ArgumentError("telemetry file identity changed"))
    metadata.size <= reader.maximum_bytes || throw(ArgumentError("telemetry file exceeds its budget"))
    metadata.size >= reader.observed_bytes || throw(ArgumentError("telemetry file was truncated"))
    reader.observed_bytes = UInt64(metadata.size)
    seek(reader.io, 144)
    committed_bytes = read(reader.io, 8)
    length(committed_bytes) == 8 || throw(ArgumentError("telemetry header was truncated"))
    committed = value_at(UInt64, committed_bytes, 0)
    committed >= reader.frames || throw(ArgumentError("telemetry stream rewound"))
    committed == reader.frames && return nothing
    bucket_bytes = Base.checked_add(BUCKET_HEADER_BYTES, reader.spec.data_bytes)
    offset = Base.checked_add(UInt64(FILE_HEADER_BYTES), Base.checked_mul(reader.frames, UInt64(bucket_bytes)))
    finish = Base.checked_add(offset, UInt64(bucket_bytes))
    finish <= reader.maximum_bytes || throw(ArgumentError("telemetry record exceeds its budget"))
    finish <= metadata.size || return nothing
    seek(reader.io, offset)
    bytes = read(reader.io, bucket_bytes)
    length(bytes) == bucket_bytes || throw(ArgumentError("telemetry record was truncated during read"))
    value_at(UInt16, bytes, 34) == 2 || throw(ArgumentError("unsupported telemetry bucket revision"))
    bucket = value_at(UInt64, bytes, 16)
    reader.last_bucket === nothing || bucket == Base.checked_add(reader.last_bucket, UInt64(1)) ||
        throw(ArgumentError("missing or duplicate full-rate telemetry bucket"))
    frame = TelemetryFrame(reader.spec, bucket, value_at(UInt32, bytes, 44),
        value_at(Int64, bytes, 0), value_at(Int16, bytes, 32),
        value_at(UInt16, bytes, 36), value_at(UInt16, bytes, 38), bytes[65:end])
    reader.frames = Base.checked_add(reader.frames, UInt64(1))
    reader.last_bucket = bucket
    return frame
end

function await_frame!(reader; timeout_ns::UInt64, service=() -> nothing)
    0 < timeout_ns <= UInt64(typemax(Int64)) || throw(ArgumentError("invalid telemetry timeout"))
    started = time_ns()
    while time_ns() - started < timeout_ns
        service()
        frame = next_frame!(reader)
        frame === nothing || return frame
        # File readiness poll only; elapsed time never proves science completion.
        sleep(0.001)
    end
    throw(ArgumentError("telemetry completion deadline expired"))
end

function require_complete(frame)
    frame.state == 2 && 0 <= frame.required <= frame.progress && frame.timestamp_us > 0 ||
        throw(ArgumentError("native telemetry frame is incomplete or invalid"))
    return nothing
end

function raw_pixels(frame::TelemetryFrame)
    require_complete(frame)
    frame.spec.datatype == 7 || throw(ArgumentError("expected raw detector telemetry"))
    count = frame.spec.rows * frame.spec.columns
    return [value_at(UInt16, frame.payload, 2(index - 1)) for index in 1:count]
end

"""Extract native Classic state/x/y/flux records using a declared destination order.

order[j] is the one-based native subaperture for destination j. scale maps
native x/y values to the declared measurement units; no angular scale is guessed.
"""
function classic_response(frame::TelemetryFrame; order::Vector{Int},
    scale::NTuple{2,Float64}, active::Vector{Bool},
)
    require_complete(frame)
    (frame.spec.datatype, frame.spec.rows, frame.spec.columns) == (13, 188, 1) ||
        throw(ArgumentError("expected Classic native subaperture records"))
    sort(order) == collect(1:188) && length(active) == 188 && any(active) ||
        throw(ArgumentError("invalid Classic order or active selection"))
    all(isfinite, scale) && all(!iszero, scale) || throw(ArgumentError("Classic scale must be finite and nonzero"))
    slopes, flux, validity = zeros(Float32, 376), zeros(Float32, 188), fill(false, 188)
    for (destination, source) in enumerate(order)
        offset = 16(source - 1)
        state = value_at(Int32, frame.payload, offset)
        state in (-1, 0, 1) || throw(ArgumentError("invalid native subaperture state"))
        slopes[2destination - 1] = Float32(value_at(Float32, frame.payload, offset + 4) * scale[1])
        slopes[2destination] = Float32(value_at(Float32, frame.payload, offset + 8) * scale[2])
        flux[destination] = value_at(Float32, frame.payload, offset + 12)
        validity[destination] = state == 1 && flux[destination] > 0
    end
    all(isfinite, slopes) && all(isfinite, flux) || throw(ArgumentError("nonfinite Classic response"))
    valid = all(index -> !active[index] || validity[index], eachindex(active))
    return (; slopes, flux, validity, valid)
end

"""Preserve the actual native quadrant-major normalized pixel representation."""
function copper_response(frame::TelemetryFrame)
    require_complete(frame)
    (frame.spec.datatype, frame.spec.rows, frame.spec.columns) == (8, 3600, 1) ||
        throw(ArgumentError("expected Copper native reconstruction pixels"))
    pixels = [value_at(Float32, frame.payload, 4(index - 1)) for index in 1:3600]
    all(isfinite, pixels) || throw(ArgumentError("nonfinite Copper response"))
    # All-zero initialization/dark data cannot authorize an illuminated batch.
    return (; pixels, valid=any(!iszero, pixels))
end

"""Compare native physical micrometres against the normal DM source receipt.

Call only after actual plant adoption and a serialized command fence. A native
command SUCCESS alone is insufficient. The returned figure remains micrometres.
"""
function confirm_probe(frame::TelemetryFrame, requested_um::Vector{Float32},
    received_metres::Vector{Float32},
)
    require_complete(frame)
    (frame.spec.datatype, frame.spec.rows, frame.spec.columns) == (20, 277, 1) ||
        throw(ArgumentError("expected native physical DM command telemetry"))
    length(requested_um) == length(received_metres) == 277 || throw(DimensionMismatch("DM figure extent differs"))
    actual_um = [value_at(Float32, frame.payload, 4(index - 1)) for index in 1:277]
    all(isfinite, requested_um) && all(isfinite, actual_um) && all(isfinite, received_metres) ||
        throw(ArgumentError("nonfinite command evidence"))
    converted = Float32.(Float64.(actual_um) .* 1e-6)
    reinterpret(UInt32, converted) == reinterpret(UInt32, received_metres) ||
        throw(ArgumentError("normal DM receipt differs from the native command"))
    return (; figure=actual_um, clipped=reinterpret(UInt32, actual_um) != reinterpret(UInt32, requested_um),
        native_bucket=frame.bucket, native_sync=frame.sync)
end

mutable struct FrameAssociation
    raw_bucket::Union{Nothing,UInt64}
    measurement_bucket::Union{Nothing,UInt64}
    native_sync::UInt32
    last_sequence::UInt64
    identity_domain::Union{Nothing,Tuple{UInt64,UInt64}}
    model_end_ns::UInt64
    pending::Any
    faulted::Bool
end

"Create after a fresh native child and a drained, externally fenced exposure path."
FrameAssociation(; raw_bucket::Union{Nothing,UInt64}=nothing,
    measurement_bucket::Union{Nothing,UInt64}=nothing, native_sync::UInt32=UInt32(0),
    last_sequence::UInt64=UInt64(0), model_end_ns::UInt64=UInt64(0)) =
    FrameAssociation(raw_bucket, measurement_bucket, native_sync, last_sequence, nothing,
        model_end_ns, nothing, false)

function arm_exposure!(association, exposure, raw::Vector{UInt16})
    association.faulted && throw(ArgumentError("native association is faulted"))
    association.pending === nothing || throw(ArgumentError("one native exposure is already pending"))
    propertynames(exposure) == (:domain, :generation, :sequence, :start_model_ns, :duration_ns) &&
        all(field -> typeof(field) === UInt64, values(exposure)) ||
        throw(ArgumentError("exposure requires the complete integer acquisition record"))
    exposure.domain > 0 && exposure.generation > 0 && exposure.duration_ns > 0 ||
        throw(ArgumentError("invalid acquisition domain, generation or exposure duration"))
    end_ns = Base.checked_add(exposure.start_model_ns, exposure.duration_ns)
    association.model_end_ns <= exposure.start_model_ns && end_ns <= UInt64(typemax(Int64)) ||
        throw(ArgumentError("exposure model interval is stale or out of range"))
    identity_domain = (exposure.domain, exposure.generation)
    association.identity_domain === nothing || association.identity_domain == identity_domain ||
        throw(ArgumentError("acquisition domain or generation changed"))
    exposure.sequence == Base.checked_add(association.last_sequence, UInt64(1)) ||
        throw(ArgumentError("acquisition sequence skipped or duplicated"))
    association.native_sync < typemax(UInt32) || throw(ArgumentError("native counter wrap requires a fresh session"))
    association.identity_domain = identity_domain
    association.pending = (; exposure, end_ns, raw_sha256=sha256(reinterpret(UInt8, raw)))
    return nothing
end

"""Associate one fenced, admitted exposure with raw and native WFS telemetry.

The native sync is checked independently of the AOS identity. Exact detector
bytes provide another check; they cannot replace the caller's admission fence.
On any mismatch retain the pending association and fault, preventing reuse.
"""
function associate!(association, raw::TelemetryFrame, measurement::TelemetryFrame)
    association.faulted && throw(ArgumentError("native association is faulted"))
    pending = association.pending
    pending === nothing && throw(ArgumentError("no native exposure is pending"))
    try
        require_complete(raw)
        require_complete(measurement)
        raw.bucket == next_bucket(association.raw_bucket) &&
            measurement.bucket == next_bucket(association.measurement_bucket) ||
            throw(ArgumentError("native frame buckets skipped or duplicated"))
        raw.sync == measurement.sync == association.native_sync + UInt32(1) ||
            throw(ArgumentError("native WFS response sync differs from the admitted frame"))
        sha256(reinterpret(UInt8, raw_pixels(raw))) == pending.raw_sha256 ||
            throw(ArgumentError("native detector bytes differ from the admitted exposure"))
        association.raw_bucket, association.measurement_bucket = raw.bucket, measurement.bucket
        association.native_sync = raw.sync
        association.last_sequence = pending.exposure.sequence
        association.model_end_ns = pending.end_ns
        association.pending = nothing
        return (; exposure=pending.exposure, native_sync=raw.sync,
            raw_bucket=raw.bucket, measurement_bucket=measurement.bucket,
            raw_sha256=bytes2hex(pending.raw_sha256))
    catch
        association.faulted = true
        rethrow()
    end
end

next_bucket(::Nothing) = UInt64(0)
next_bucket(bucket::UInt64) = Base.checked_add(bucket, UInt64(1))

"""Verify all records of a retained full-rate Copper session against finite counts.

The live owner establishes raw frame digests and AOS association; this final
check detects missing or additional native output after the controller hold.
"""
function verify_copper_counts(directory; frames::Int, commands::Int, maximum_bytes::UInt64)
    0 < frames <= typemax(UInt32) && commands > 0 || throw(ArgumentError("invalid native record counts"))
    contracts = (("cbHoPixelsRaw0", 7, (64, 64), frames),
        ("cbHoPixelsCalib0", 8, (64, 64), frames),
        ("cbHoGrad0", 8, (3600, 1), frames), ("cbDmCmd0", 20, (277, 1), commands))
    result = Dict{String,Int}()
    for (tag, datatype, shape, expected) in contracts
        # Exact header tag is authoritative; recorder filenames also contain a
        # date, state and timestamp and need not start with their tag.
        paths = String[]
        for path in readdir(directory; join=true)
            endswith(path, ".tel") && isfile(path) || continue
            islink(path) && throw(ArgumentError("retained native telemetry is linked"))
            filesize(path) >= FILE_HEADER_BYTES || throw(ArgumentError("retained telemetry header is incomplete"))
            header_tag = open(path) do io
                bytes = read(io, 32)
                zero = findfirst(iszero, bytes)
                String(bytes[1:(zero === nothing ? 32 : zero - 1)])
            end
            header_tag == tag && push!(paths, path)
        end
        length(paths) == 1 || throw(ArgumentError("expected exactly one retained native $tag stream"))
        reader = TelemetryReader(only(paths); tag, datatype, shape, maximum_bytes)
        try
            for index in 1:expected
                frame = next_frame!(reader)
                frame === nothing && throw(ArgumentError("retained native $tag has too few records"))
                frame.bucket == UInt64(index - 1) || throw(ArgumentError("native $tag did not begin at bucket zero"))
                frame.sync == (tag == "cbDmCmd0" ? UInt32(0) : UInt32(index)) ||
                    throw(ArgumentError("native $tag sync differs from serialized admission"))
                frame.state == 2 && frame.progress == frame.required &&
                    (tag == "cbHoPixelsCalib0" ? frame.timestamp_us >= 0 : frame.timestamp_us > 0) ||
                    throw(ArgumentError("native $tag record is incomplete"))
            end
            next_frame!(reader) === nothing || throw(ArgumentError("retained native $tag has extra records"))
            seek(reader.io, 144)
            value_at(UInt64, read(reader.io, 8), 0) == expected || throw(ArgumentError("native $tag committed count differs"))
            expected_bytes = FILE_HEADER_BYTES + expected * (BUCKET_HEADER_BYTES + reader.spec.data_bytes)
            filesize(only(paths)) == expected_bytes || throw(ArgumentError("native $tag contains a partial or extra record"))
            result[tag] = expected
        finally
            close(reader)
        end
    end
    return result
end

end
