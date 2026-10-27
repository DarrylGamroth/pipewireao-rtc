# Included inside InstrumentCalibration. RTC-DEV-029 capture-file boundary.
import ..NativeCalibrationActionCodec
import ..NativeControlClient
import PipeWireAO

const CAPTURE_HEADER_BYTES = 16 * 1024
const CAPTURE_EXPOSURE_BYTES = 4096
const CLASSIC_CAPTURE_CONTRACTS = (
    raw=(type=UInt16, encoding="U16_LE", shape=(352,352), bytes=247808),
    slopes=(type=Float32, encoding="F32_LE", shape=(188,2), bytes=1504),
    flux=(type=Float32, encoding="F32_LE", shape=(188,), bytes=752),
    validity=(type=Bool, encoding="BOOL8", shape=(188,), bytes=188))
const CLASSIC_CAPTURE_BYTES = sum(contract.bytes for contract in CLASSIC_CAPTURE_CONTRACTS)

_capture_require(condition, message) = condition || throw(ArgumentError(message))
function _capture_fields(value, fields)
    _capture_require(value isa AbstractDict && Set(keys(value)) == Set(fields), "capture object fields differ")
    return value
end
function _capture_uint(value, ::Type{T}=UInt64) where T<:Unsigned
    _capture_require(value isa Integer && !(value isa Bool) && 0 <= value <= typemax(T), "invalid capture integer")
    return T(value)
end
function _capture_int(value)
    _capture_require(value isa Integer && !(value isa Bool) && typemin(Int64) <= value <= typemax(Int64), "invalid signed capture integer")
    return Int64(value)
end
function _capture_text(value; maximum=256)
    _capture_require(value isa AbstractString && 0 < ncodeunits(value) <= maximum && isvalid(value) && !occursin('\0',value), "invalid capture text")
    return String(value)
end
function _capture_hash(value; bytes=32)
    _capture_require(value isa AbstractString && occursin(Regex("^[0-9a-f]{" * string(2bytes) * "}\$"),value) &&
        (bytes != 16 || any(!=('0'),value)), "invalid capture digest or acquisition domain")
    return String(value)
end
_capture_json(value) = (Common.finite_json(value); Common.JSON.json(value))
function _capture_same_json(left,right)
    if left isa AbstractDict && right isa AbstractDict
        return Set(keys(left)) == Set(keys(right)) &&
            all(key -> _capture_same_json(left[key],right[key]),keys(left))
    elseif left isa AbstractVector && right isa AbstractVector
        return length(left) == length(right) && all(_capture_same_json(a,b) for (a,b) in zip(left,right))
    elseif left isa Bool || right isa Bool
        return left === right
    elseif left isa Integer || right isa Integer
        return left isa Integer && right isa Integer && left == right
    end
    return isequal(left,right)
end

# Bound structure before serialization as well as bounding its encoded length.
function _capture_settings(value, budget=Ref(CAPTURE_HEADER_BYTES), depth=0)
    budget[] -= 1
    _capture_require(budget[] >= 0 && depth <= 32, "capture settings exceed structural bound")
    if value isa AbstractDict
        for (key,item) in value
            _capture_require(key isa AbstractString, "capture settings require string keys")
            budget[] -= ncodeunits(key)
            _capture_settings(item,budget,depth+1)
        end
    elseif value isa AbstractVector || value isa Tuple
        foreach(item -> _capture_settings(item,budget,depth+1),value)
    elseif value isa AbstractString
        budget[] -= ncodeunits(value)
    else
        _capture_require(value === nothing || value isa Bool || value isa Real, "unsupported capture setting")
    end
    _capture_require(budget[] >= 0, "capture settings exceed structural bound")
    return value
end
function _capture_snapshot(settings)
    _capture_require(settings isa AbstractDict, "capture settings must be an object")
    _capture_settings(settings)
    encoded = _capture_json(settings)
    _capture_require(ncodeunits(encoded) <= CAPTURE_HEADER_BYTES, "capture settings exceed 16 KiB")
    return Common.parse_json(encoded)
end

# Reject symbolic links in every existing path component, including ancestors.
function _capture_path(path; directory=false)
    absolute = abspath(path)
    current = absolute
    while true
        _capture_require(!islink(current), "capture paths must not traverse symbolic links")
        parent = dirname(current)
        parent == current && break
        current = parent
    end
    _capture_require(directory ? isdir(absolute) : isfile(absolute), "capture path is missing or has the wrong kind")
    return absolute
end

"""
    CaptureStore(directory; stage, illumination, settings, maximum_bytes, profile="classic")

Own a fresh mode-0700 directory for finite Classic capture evidence. The caller
must supply exact detector, source, graph and mask identities in `settings`.
Only Classic is implemented here; Copper rejects before creating storage.
Payload budget is cumulative and reserved before acquisition, including failed
requests. Files left by interrupted requests have no completed manifest.
Exact live probe and after-cursor authority remains with the serialized owner.
"""
mutable struct CaptureStore
    directory::String
    stage::String
    illumination::String
    settings::Dict{String,Any}
    maximum_bytes::UInt64
    used_bytes::UInt64
    run::UInt64
    serial::UInt64
    cursor::Union{Nothing,NativeCalibrationActionCodec.AcquisitionCursor}
    domain::Union{Nothing,String}
end
function CaptureStore(directory; stage::String, illumination::String, settings::AbstractDict,
        maximum_bytes::Integer, profile="classic")
    _capture_require(profile == "classic", "unsupported capture profile")
    _capture_text(stage); _capture_text(illumination)
    maximum = _capture_uint(maximum_bytes)
    _capture_require(maximum > 0, "capture budget must be positive")
    snapshot = _capture_snapshot(settings)
    root = abspath(directory)
    _capture_path(dirname(root);directory=true)
    _capture_require(!ispath(root) && !islink(root), "capture directory must be fresh")
    mkdir(root;mode=0o700)
    chmod(root,0o700)
    return CaptureStore(root,stage,illumination,snapshot,maximum,0,0,0,nothing,nothing)
end

_capture_cursor(cursor) = Dict("domain"=>cursor.domain,"generation"=>cursor.generation,
    "sequence"=>cursor.sequence,"model_ns"=>cursor.model_ns)
function _capture_read_cursor(value)
    _capture_fields(value,("domain","generation","sequence","model_ns"))
    result = NativeCalibrationActionCodec.AcquisitionCursor((_capture_uint(value[key]) for key in
        ("domain","generation","sequence","model_ns"))...)
    _capture_require(result.domain > 0 && result.generation > 0 && result.model_ns <= typemax(Int64), "invalid capture cursor")
    return result
end
function _capture_exposure(value, cursor)
    _capture_fields(value,("domain","generation","sequence","start_model_ns","duration_ns"))
    result = NativeCalibrationActionCodec.Exposure((_capture_uint(value[key]) for key in
        ("domain","generation","sequence","start_model_ns","duration_ns"))...)
    _capture_require(result.domain == cursor.domain && result.generation == cursor.generation &&
        cursor.sequence < typemax(UInt64) && result.sequence == cursor.sequence+1 &&
        result.start_model_ns >= cursor.model_ns && result.duration_ns > 0 &&
        result.duration_ns <= typemax(Int64)-result.start_model_ns, "capture exposure is stale or discontinuous")
    return result
end
_capture_exposure_dict(value) = Dict(string(key)=>getproperty(value,key) for key in
    (:domain,:generation,:sequence,:start_model_ns,:duration_ns))
_capture_end(value) = NativeCalibrationActionCodec.AcquisitionCursor(value.domain,value.generation,
    value.sequence,value.start_model_ns+value.duration_ns)

function _capture_receipt(receipt)
    header = receipt.header
    start, reference = receipt.wire_start, receipt.ptp_reference
    return Dict("identity"=>Dict("domain"=>bytes2hex(collect(receipt.identity.domain.bytes)),
            "generation"=>receipt.identity.generation,"sequence"=>receipt.identity.sequence),
        "model_start_ns"=>receipt.model_start_ns,"duration_ns"=>receipt.duration_ns,
        "header"=>Dict(string(key)=>getproperty(header,key) for key in (:flags,:offset,:pts,:dts_offset,:sequence)),
        "acquisition_version"=>receipt.acquisition_version,"acquisition_flags"=>receipt.acquisition_flags,
        "wire_start"=>start === nothing ? nothing : Dict("nanoseconds"=>start.nanoseconds,
            "uncertainty_nanoseconds"=>start.uncertainty_nanoseconds),
        "timebase"=>receipt.timebase === nothing ? nothing : UInt32(receipt.timebase),
        "ptp_reference"=>reference === nothing ? nothing : Dict(
            "grandmaster"=>bytes2hex(collect(reference.grandmaster.bytes)),"domain_number"=>reference.domain_number))
end
function _capture_check_receipt(value, exposure, domain)
    _capture_fields(value,("identity","model_start_ns","duration_ns","header","acquisition_version",
        "acquisition_flags","wire_start","timebase","ptp_reference"))
    identity = _capture_fields(value["identity"],("domain","generation","sequence"))
    full = _capture_hash(identity["domain"];bytes=16)
    _capture_require((domain === nothing || full == domain) &&
        _capture_uint(identity["generation"]) == exposure.generation &&
        _capture_uint(identity["sequence"]) == exposure.sequence &&
        _capture_int(value["model_start_ns"]) == exposure.start_model_ns &&
        _capture_uint(value["duration_ns"]) == exposure.duration_ns, "capture receipt identity/model time differs")
    header = _capture_fields(value["header"],("flags","offset","pts","dts_offset","sequence"))
    flags = _capture_uint(header["flags"],UInt32)
    _capture_uint(header["offset"],UInt32); _capture_int(header["pts"]); _capture_int(header["dts_offset"])
    _capture_require(_capture_uint(header["sequence"]) == exposure.sequence && flags & (PipeWireAO.SPA.META_HEADER_FLAG_CORRUPTED | PipeWireAO.SPA.META_HEADER_FLAG_GAP) == 0,
        "capture header is stale, corrupted or a gap")
    version = _capture_uint(value["acquisition_version"],UInt32)
    acquisition_flags = _capture_uint(value["acquisition_flags"],UInt32)
    required_flags = UInt32(PipeWireAO.ACQUISITION_FLAG_IDENTITY_VALID | PipeWireAO.ACQUISITION_FLAG_EXPOSURE_DURATION_VALID)
    _capture_require(version in (2,3) && acquisition_flags & required_flags == required_flags, "capture acquisition metadata is invalid")
    start, timebase, reference = value["wire_start"],value["timebase"],value["ptp_reference"]
    _capture_require((start !== nothing) == (acquisition_flags & PipeWireAO.ACQUISITION_FLAG_EXPOSURE_START_VALID != 0) &&
        (reference !== nothing) == (acquisition_flags & PipeWireAO.ACQUISITION_FLAG_PTP_REFERENCE_VALID != 0) &&
        (timebase !== nothing) == (start !== nothing), "capture optional clock flags differ")
    if start !== nothing
        _capture_fields(start,("nanoseconds","uncertainty_nanoseconds"))
        _capture_int(start["nanoseconds"]); _capture_uint(start["uncertainty_nanoseconds"])
        _capture_require(_capture_uint(timebase,UInt32) in UInt32.((PipeWireAO.ACQUISITION_TIMEBASE_MONOTONIC,
            PipeWireAO.ACQUISITION_TIMEBASE_TAI)), "unknown capture clock timebase")
    end
    if reference !== nothing
        _capture_fields(reference,("grandmaster","domain_number"))
        _capture_hash(reference["grandmaster"];bytes=8)
        _capture_require(any(!=('0'),reference["grandmaster"]) &&
            timebase == UInt32(PipeWireAO.ACQUISITION_TIMEBASE_TAI), "invalid capture PTP reference")
        _capture_uint(reference["domain_number"],UInt8)
    end
    return full
end

function _capture_arrays(arrays)
    _capture_require(Set(keys(arrays)) == Set(keys(CLASSIC_CAPTURE_CONTRACTS)), "capture payload roles differ")
    for (role,contract) in pairs(CLASSIC_CAPTURE_CONTRACTS)
        array = getproperty(arrays,role)
        _capture_require(array isa AbstractArray && eltype(array) === contract.type && size(array) == contract.shape,
            "capture $role type or shape differs")
    end
    return arrays
end
_capture_quality(arrays) = Dict("finite_slopes"=>all(isfinite,arrays.slopes),
    "finite_flux"=>all(isfinite,arrays.flux),"valid_rois"=>count(arrays.validity))
function _capture_encode(array)
    dense = collect(array)
    values = ndims(dense) == 1 ? vec(dense) : vec(permutedims(dense,reverse(1:ndims(dense))))
    eltype(values) === Bool && return UInt8.(values)
    bits = eltype(values) === Float32 ? reinterpret(UInt32,values) : values
    return collect(reinterpret(UInt8,htol.(bits)))
end
function _capture_decode(bytes, contract)
    _capture_require(length(bytes) == contract.bytes, "capture payload byte length differs")
    if contract.type === Bool
        _capture_require(all(value -> value in (0,1),bytes), "invalid BOOL8 capture payload")
        return Bool.(bytes)
    end
    unsigned = contract.type === Float32 ? UInt32 : UInt16
    bits = ltoh.(reinterpret(unsigned,bytes))
    values = contract.type === Float32 ? collect(reinterpret(Float32,bits)) : collect(bits)
    return length(contract.shape) == 1 ? values : permutedims(reshape(values,reverse(contract.shape)),reverse(1:length(contract.shape)))
end
_capture_name(index,role) = "frame-" * lpad(string(index),6,'0') * "-" * string(role) * ".bin"
_capture_request(run,serial) = "run-$(run)-serial-$(serial)"
function _capture_write(path, bytes, check)
    check()
    flags = Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_EXCL | Base.Filesystem.JL_O_NOFOLLOW
    file = Base.Filesystem.open(path,flags,0o600)
    try
        _capture_require(write(file,bytes) == length(bytes), "incomplete capture file write")
        check()
    finally
        close(file)
    end
    chmod(path,0o444)
    return nothing
end

"""
    capture_preflight(store; run, serial, probe, cursor, frames, deadline, check=()->nothing)

Validate a request without changing the store, reserving bytes, creating files
or acquiring an exposure. The serialized owner may translate an ArgumentError
from this boundary into a known rejection before any endpoint effect. Later
capture failures must retain their post-effect disposition. `capture!` repeats
this check immediately before reserving its complete request budget.
"""
function capture_preflight(store::CaptureStore; run::UInt64,serial::UInt64,probe::UInt32,
        cursor,frames::UInt32,deadline::Float64,check=()->nothing)
    _capture_require(run > 0 && serial > 0 && probe <= 16383 && 1 <= frames <= 4096, "invalid capture request")
    _capture_require(isfinite(deadline), "capture deadline must be finite")
    checked() = (check(); NativeControlClient.monotonic() < deadline || throw(InvalidStateException("capture deadline expired",:deadline)))
    checked()
    after = _capture_read_cursor(_capture_cursor(cursor))
    _capture_require(store.run in (0,run) && serial > store.serial, "capture run/serial is stale")
    if store.cursor !== nothing
        last = store.cursor
        consistent = (after.sequence == last.sequence && after.model_ns == last.model_ns) ||
            (after.sequence > last.sequence && after.model_ns > last.model_ns)
        _capture_require(after.domain == last.domain && after.generation == last.generation &&
            consistent, "capture cursor is stale")
    end
    bytes = UInt64(frames)*UInt64(CLASSIC_CAPTURE_BYTES)
    _capture_require(bytes <= store.maximum_bytes-store.used_bytes, "capture payload budget exhausted")
    _capture_path(store.directory;directory=true)
    request = _capture_request(run,serial)
    directory = joinpath(store.directory,request)
    _capture_require(!ispath(directory) && !islink(directory), "capture request directory already exists")
    header = Dict{String,Any}("schema_version"=>1,"profile"=>"classic","run"=>run,"serial"=>serial,
        "probe"=>probe,"stage"=>store.stage,"illumination"=>store.illumination,"settings"=>store.settings,
        "after"=>_capture_cursor(after),"cursor"=>_capture_cursor(after),"payload_bytes"=>bytes,
        "domain_mapping"=>Dict("coordinator"=>after.domain,"wire"=>something(store.domain,repeat("0",32))))
    _capture_require(ncodeunits(_capture_json(header))+32 <= CAPTURE_HEADER_BYTES, "capture header exceeds 16 KiB")
    return (;after,bytes,directory,header,request,checked)
end

"""
    capture!(store, acquire; run, serial, probe, cursor, frames, deadline, check=()->nothing)

Write each completed sink-owned Classic sample before calling `acquire()` again.
`acquire()` returns `(sample, exposure)`; samples contain `arrays` and `metadata`.
A request creates `run-R-serial-S/manifest.json` only after all payloads succeed.
Manifest version 1 contains a bounded settings header, after/final cursors,
`domain_mapping` (`coordinator` UInt64 to 16-byte hex `wire` domain), and an
`exposures` array. Each entry binds native model time, full wire identities,
all copied clock/header metadata, intrinsic quality, and four fixed payload
records (`path`, `encoding`, `layout`, `shape`, `bytes`, `sha256`). A false WFS
validity bit is preserved and never interpreted as interaction acceptance.
"""
function capture!(store::CaptureStore, acquire; run::UInt64,serial::UInt64,probe::UInt32,
        cursor,frames::UInt32,deadline::Float64,check=()->nothing)
    (;after,bytes,directory,header,request,checked) = capture_preflight(store;
        run,serial,probe,cursor,frames,deadline,check)
    # Reserve the complete request before any exposure. Interrupted work stays charged.
    store.used_bytes += bytes
    store.run,store.serial = run,serial
    mkdir(directory;mode=0o700)
    records = Dict{String,Any}[]
    for index in 1:Int(frames)
        checked()
        sample, supplied = acquire()
        checked()
        exposure = _capture_exposure(_capture_exposure_dict(supplied),after)
        arrays = _capture_arrays(sample.arrays)
        _capture_require(Set(keys(sample.metadata)) == Set(keys(CLASSIC_CAPTURE_CONTRACTS)), "capture receipt roles differ")
        metadata = Dict{String,Any}()
        payloads = Dict{String,Any}()
        for (role,contract) in pairs(CLASSIC_CAPTURE_CONTRACTS)
            receipt = _capture_receipt(getproperty(sample.metadata,role))
            domain = _capture_check_receipt(receipt,exposure,store.domain)
            store.domain = domain
            metadata[string(role)] = receipt
            encoded = _capture_encode(getproperty(arrays,role))
            name = _capture_name(index,role)
            _capture_write(joinpath(directory,name),encoded,checked)
            payloads[string(role)] = Dict("path"=>name,"encoding"=>contract.encoding,"layout"=>"ROW_MAJOR",
                "shape"=>collect(contract.shape),"bytes"=>contract.bytes,"sha256"=>bytes2hex(sha256(encoded)))
        end
        record = Dict{String,Any}("exposure"=>_capture_exposure_dict(exposure),"metadata"=>metadata,
            "payloads"=>payloads,"quality"=>_capture_quality(arrays))
        _capture_require(ncodeunits(_capture_json(record))+1 <= CAPTURE_EXPOSURE_BYTES, "capture exposure metadata exceeds 4096 bytes")
        push!(records,record)
        after = _capture_end(exposure)
        store.cursor = after
    end
    header["cursor"] = _capture_cursor(after)
    header["domain_mapping"]["wire"] = something(store.domain)
    _capture_require(ncodeunits(_capture_json(header))+32 <= CAPTURE_HEADER_BYTES, "capture header exceeds 16 KiB")
    header["exposures"] = records
    encoded = Vector{UInt8}(codeunits(_capture_json(header)*"\n"))
    _capture_require(length(encoded) <= CAPTURE_HEADER_BYTES+CAPTURE_EXPOSURE_BYTES*Int(frames), "capture metadata exceeds bound")
    temporary = joinpath(directory,"manifest.partial")
    _capture_write(temporary,encoded,checked)
    checked()
    completed = joinpath(directory,"manifest.json")
    mv(temporary,completed)
    try
        checked()
    catch
        # Only this request's just-published manifest is withdrawn on interruption.
        rm(completed)
        rethrow()
    end
    return NativeCalibrationActionCodec.Captured(after,request*"/manifest.json",bytes2hex(sha256(encoded)),
        frames,bytes,UInt64(length(encoded)))
end

# JSON's ordinary Dict materializer overwrites duplicate keys. Reject them here.
struct CaptureObject <: AbstractDict{String,Any}
    values::Dict{String,Any}
end
CaptureObject() = CaptureObject(Dict{String,Any}())
Base.length(value::CaptureObject) = length(value.values)
Base.iterate(value::CaptureObject,state...) = iterate(value.values,state...)
Base.getindex(value::CaptureObject,key) = value.values[key]
Base.haskey(value::CaptureObject,key) = haskey(value.values,key)
function Base.setindex!(value::CaptureObject,item,key)
    _capture_require(!haskey(value,key), "duplicate capture JSON key")
    return value.values[key] = item
end
function _capture_read(path, maximum)
    _capture_path(path)
    before = lstat(path)
    _capture_require(before.size <= maximum, "capture file exceeds size bound")
    file = Base.Filesystem.open(path,Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_NOFOLLOW | Base.Filesystem.JL_O_NONBLOCK)
    try
        opened = stat(file)
        _capture_require(isfile(opened) && opened.device == before.device && opened.inode == before.inode &&
            opened.size == before.size && opened.mtime == before.mtime && opened.ctime == before.ctime, "capture file changed before open")
        bytes = Vector{UInt8}(undef,Int(opened.size))
        read!(file,bytes)
        after = stat(file)
        _capture_require(after.size == opened.size && after.mtime == opened.mtime && after.ctime == opened.ctime, "capture file changed during read")
        return bytes
    finally
        close(file)
    end
end

"""
    read_capture(directory, descriptor; expected_profile, expected_stage,
        expected_illumination, expected_settings)

Verify a completed immutable capture against caller-selected contracts/settings.
Returns `(manifest, samples)`, where each sample has fresh owned `arrays` and
JSON `metadata` receipts, native `exposure`, and intrinsic `quality`. Descriptor
and payload hashes, exact fields/lengths, full acquisition identities, sequence
continuity, nonoverlapping model-time intervals and canonical paths are verified
before returning any sample. The
manifest cannot choose a profile or relax the expected startup snapshot.
"""
function read_capture(directory, descriptor::NativeCalibrationActionCodec.Captured;
        expected_profile,expected_stage,expected_illumination,expected_settings)
    _capture_require(expected_profile == "classic", "unsupported expected capture profile")
    _capture_text(expected_stage); _capture_text(expected_illumination)
    settings = _capture_snapshot(expected_settings)
    _capture_require(1 <= descriptor.frames <= 4096 && descriptor.bytes == UInt64(descriptor.frames)*CLASSIC_CAPTURE_BYTES &&
        0 < descriptor.metadata_bytes <= CAPTURE_HEADER_BYTES+CAPTURE_EXPOSURE_BYTES*UInt64(descriptor.frames), "capture descriptor bounds differ")
    _capture_hash(descriptor.sha256)
    _capture_require(occursin(r"^run-[1-9][0-9]*-serial-[1-9][0-9]*/manifest\.json$",descriptor.manifest), "capture manifest path is not canonical")
    root = _capture_path(directory;directory=true)
    path = joinpath(root,descriptor.manifest)
    encoded = _capture_read(path,Int(descriptor.metadata_bytes))
    _capture_require(length(encoded) == descriptor.metadata_bytes && bytes2hex(sha256(encoded)) == descriptor.sha256, "capture manifest length or digest differs")
    text = String(encoded)
    _capture_require(isvalid(text), "capture manifest is not UTF-8")
    manifest = Common.json_number(Common.JSON.parse(text;dicttype=CaptureObject,maxdepth=64))
    fields = ("schema_version","profile","run","serial","probe","stage","illumination","settings",
        "after","cursor","payload_bytes","domain_mapping","exposures")
    _capture_fields(manifest,fields)
    _capture_require(manifest["schema_version"] === 1 && manifest["profile"] == expected_profile &&
        manifest["stage"] == expected_stage && manifest["illumination"] == expected_illumination &&
        _capture_same_json(manifest["settings"],settings), "capture profile/stage/illumination/settings differ")
    run,serial = _capture_uint(manifest["run"]),_capture_uint(manifest["serial"])
    _capture_require(run > 0 && serial > 0 && _capture_uint(manifest["probe"],UInt32) <= 16383 &&
        descriptor.manifest == _capture_request(run,serial)*"/manifest.json" &&
        _capture_uint(manifest["payload_bytes"]) == descriptor.bytes, "capture request identity or size differs")
    records = manifest["exposures"]
    _capture_require(records isa AbstractVector && length(records) == descriptor.frames, "capture exposure count differs")
    header = filter(pair -> first(pair) != "exposures",manifest)
    _capture_require(ncodeunits(_capture_json(header))+32 <= CAPTURE_HEADER_BYTES, "capture header exceeds 16 KiB")
    cursor = _capture_read_cursor(manifest["after"])
    mapping = _capture_fields(manifest["domain_mapping"],("coordinator","wire"))
    _capture_require(_capture_uint(mapping["coordinator"]) == cursor.domain, "capture domain mapping differs")
    domain = _capture_hash(mapping["wire"];bytes=16)
    samples = NamedTuple[]
    for (index,record) in enumerate(records)
        _capture_fields(record,("exposure","metadata","payloads","quality"))
        _capture_require(ncodeunits(_capture_json(record))+1 <= CAPTURE_EXPOSURE_BYTES, "capture exposure metadata exceeds bound")
        exposure = _capture_exposure(record["exposure"],cursor)
        metadata,payloads = record["metadata"],record["payloads"]
        roles = string.(keys(CLASSIC_CAPTURE_CONTRACTS))
        _capture_fields(metadata,roles); _capture_fields(payloads,roles)
        arrays = map(collect(pairs(CLASSIC_CAPTURE_CONTRACTS))) do (role,contract)
            domain = _capture_check_receipt(metadata[string(role)],exposure,domain)
            payload = _capture_fields(payloads[string(role)],("path","encoding","layout","shape","bytes","sha256"))
            name = _capture_name(index,role)
            _capture_require(payload["path"] == name && payload["encoding"] == contract.encoding &&
                payload["layout"] == "ROW_MAJOR" && payload["shape"] isa AbstractVector &&
                length(payload["shape"]) == length(contract.shape) &&
                Tuple(_capture_uint.(payload["shape"])) == contract.shape &&
                _capture_uint(payload["bytes"]) == contract.bytes, "capture payload contract differs")
            _capture_hash(payload["sha256"])
            bytes = _capture_read(joinpath(dirname(path),name),contract.bytes)
            _capture_require(length(bytes) == contract.bytes && bytes2hex(sha256(bytes)) == payload["sha256"], "capture payload length or digest differs")
            _capture_decode(bytes,contract)
        end
        arrays = NamedTuple{keys(CLASSIC_CAPTURE_CONTRACTS)}(Tuple(arrays))
        _capture_require(_capture_same_json(record["quality"],_capture_quality(arrays)), "capture intrinsic quality differs")
        push!(samples,(;arrays,metadata,exposure,quality=record["quality"]))
        cursor = _capture_end(exposure)
    end
    final_cursor = _capture_read_cursor(manifest["cursor"])
    _capture_require(isequal(_capture_cursor(cursor),_capture_cursor(descriptor.cursor)) &&
        isequal(_capture_cursor(cursor),_capture_cursor(final_cursor)), "capture final cursor differs")
    return (;manifest,samples)
end
