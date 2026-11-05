# Included inside InstrumentCalibration. RTC-DEV-029 capture-file boundary.
import ..CalibrationActionCodec
import ..ControlClient
import PipeWireAO

const CAPTURE_HEADER_BYTES = 16 * 1024
const CAPTURE_EXPOSURE_BYTES = 64 * 1024
const CAPTURE_METADATA_ABI = 4
const CAPTURE_BYTE_ORDER = ENDIAN_BOM == 0x04030201 ? "little" : "big"
const CLASSIC_CAPTURE_CONTRACTS = (
    raw=(type=UInt16, encoding="U16_LE", shape=(352,352), bytes=247808),
    slopes=(type=Float32, encoding="F32_LE", shape=(188,2), bytes=1504),
    flux=(type=Float32, encoding="F32_LE", shape=(188,), bytes=752),
    validity=(type=Bool, encoding="BOOL8", shape=(188,), bytes=188))
const CLASSIC_CAPTURE_BYTES = sum(contract.bytes for contract in CLASSIC_CAPTURE_CONTRACTS)

_capture_require(condition, message) = condition || throw(ArgumentError(message))
_capture_fields(value, fields) = throw(ArgumentError("capture object fields differ"))
function _capture_fields(value::AbstractDict, fields)
    _capture_require(Set(keys(value)) == Set(fields), "capture object fields differ")
    return value
end
_capture_uint(value, ::Type{T}=UInt64) where T<:Unsigned = throw(ArgumentError("invalid capture integer"))
_capture_uint(value::Bool, ::Type{T}=UInt64) where T<:Unsigned = throw(ArgumentError("invalid capture integer"))
function _capture_uint(value::Integer, ::Type{T}=UInt64) where T<:Unsigned
    _capture_require(0 <= value <= typemax(T), "invalid capture integer")
    return T(value)
end
_capture_int(value) = throw(ArgumentError("invalid signed capture integer"))
_capture_int(value::Bool) = throw(ArgumentError("invalid signed capture integer"))
function _capture_int(value::Integer)
    _capture_require(typemin(Int64) <= value <= typemax(Int64), "invalid signed capture integer")
    return Int64(value)
end
_capture_text(value; maximum=256) = throw(ArgumentError("invalid capture text"))
function _capture_text(value::AbstractString; maximum=256)
    _capture_require(0 < ncodeunits(value) <= maximum && isvalid(value) && !occursin('\0',value), "invalid capture text")
    return String(value)
end
_capture_hash(value; bytes=32) = throw(ArgumentError("invalid capture digest or acquisition domain"))
function _capture_hash(value::AbstractString; bytes=32)
    _capture_require(occursin(Regex("^[0-9a-f]{" * string(2bytes) * "}\$"),value) &&
        (bytes != 16 || any(!=('0'),value)), "invalid capture digest or acquisition domain")
    return String(value)
end
_capture_json(value) = (Common.finite_json(value); Common.JSON.json(value))
_capture_same_json(left,right) = isequal(left,right)
_capture_same_json(left::AbstractDict,right::AbstractDict) = Set(keys(left)) == Set(keys(right)) &&
    all(key -> _capture_same_json(left[key],right[key]),keys(left))
_capture_same_json(left::AbstractVector,right::AbstractVector) = length(left) == length(right) &&
    all(_capture_same_json(a,b) for (a,b) in zip(left,right))
_capture_same_json(left::Integer,right) = false
_capture_same_json(left,right::Integer) = false
_capture_same_json(left::Integer,right::Integer) = left == right
_capture_same_json(left::Bool,right) = left === right
_capture_same_json(left,right::Bool) = left === right
_capture_same_json(left::Bool,right::Integer) = left === right
_capture_same_json(left::Integer,right::Bool) = left === right
_capture_same_json(left::Bool,right::Bool) = left === right

# Bound structure before serialization as well as bounding its encoded length.
function _capture_settings(value, budget=Ref(CAPTURE_HEADER_BYTES), depth=0)
    budget[] -= 1
    _capture_require(budget[] >= 0 && depth <= 32, "capture settings exceed structural bound")
    _capture_setting!(value,budget,depth)
    _capture_require(budget[] >= 0, "capture settings exceed structural bound")
    return value
end
_capture_setting!(value,budget,depth) = throw(ArgumentError("unsupported capture setting"))
_capture_setting!(value::Union{Nothing,Real},budget,depth) = nothing
function _capture_setting!(value::AbstractDict,budget,depth)
    for (key,item) in value
        _capture_setting_key!(key,budget)
        _capture_settings(item,budget,depth+1)
    end
    return nothing
end
_capture_setting_key!(key,budget) = throw(ArgumentError("capture settings require string keys"))
_capture_setting_key!(key::AbstractString,budget) = (budget[] -= ncodeunits(key); nothing)
_capture_setting!(value::Union{AbstractVector,Tuple},budget,depth) =
    foreach(item -> _capture_settings(item,budget,depth+1),value)
_capture_setting!(value::AbstractString,budget,depth) = (budget[] -= ncodeunits(value); nothing)
_capture_snapshot(settings) = throw(ArgumentError("capture settings must be an object"))
function _capture_snapshot(settings::AbstractDict)
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
    cursor::Union{Nothing,CalibrationActionCodec.AcquisitionCursor}
    domain::Union{Nothing,String}
    recording_clock::PipeWireAO.MetadataClock
end
function CaptureStore(directory; stage::String, illumination::String, settings::AbstractDict,
        maximum_bytes::Integer, profile="classic", recording_clock::PipeWireAO.MetadataClock=PipeWireAO.METADATA_CLOCK_REALTIME)
    _capture_require(profile == "classic", "unsupported capture profile")
    _capture_require(recording_clock in (PipeWireAO.METADATA_CLOCK_REALTIME,PipeWireAO.METADATA_CLOCK_TAI),
        "recording clock must be REALTIME or TAI")
    PipeWireAO.reference_timestamp_now(recording_clock)
    _capture_text(stage); _capture_text(illumination)
    maximum = _capture_uint(maximum_bytes)
    _capture_require(maximum > 0, "capture budget must be positive")
    snapshot = _capture_snapshot(settings)
    root = abspath(directory)
    _capture_path(dirname(root);directory=true)
    _capture_require(!ispath(root) && !islink(root), "capture directory must be fresh")
    mkdir(root;mode=0o700)
    chmod(root,0o700)
    return CaptureStore(root,stage,illumination,snapshot,maximum,0,0,0,nothing,nothing,
        recording_clock)
end

_capture_cursor(cursor) = Dict("domain"=>cursor.domain,"generation"=>cursor.generation,
    "sequence"=>cursor.sequence,"model_ns"=>cursor.model_ns)
function _capture_read_cursor(value)
    _capture_fields(value,("domain","generation","sequence","model_ns"))
    result = CalibrationActionCodec.AcquisitionCursor((_capture_uint(value[key]) for key in
        ("domain","generation","sequence","model_ns"))...)
    _capture_require(result.domain > 0 && result.generation > 0 && result.model_ns <= typemax(Int64), "invalid capture cursor")
    return result
end
function _capture_exposure(value, cursor)
    _capture_fields(value,("domain","generation","sequence","start_model_ns","duration_ns"))
    result = CalibrationActionCodec.Exposure((_capture_uint(value[key]) for key in
        ("domain","generation","sequence","start_model_ns","duration_ns"))...)
    _capture_require(result.domain == cursor.domain && result.generation == cursor.generation &&
        cursor.sequence < typemax(UInt64) && result.sequence == cursor.sequence+1 &&
        cursor.model_ns <= result.start_model_ns <= typemax(Int64) && result.duration_ns > 0 &&
        result.duration_ns <= typemax(Int64)-result.start_model_ns, "capture exposure is stale or discontinuous")
    return result
end
_capture_exposure_dict(value) = Dict(string(key)=>getproperty(value,key) for key in
    (:domain,:generation,:sequence,:start_model_ns,:duration_ns))
_capture_end(value) = CalibrationActionCodec.AcquisitionCursor(value.domain,value.generation,
    value.sequence,value.start_model_ns+value.duration_ns)

function _capture_timing(value)
    value === nothing && return nothing
    return Dict("start_nanoseconds"=>value.has_start ? value.start_nanoseconds : nothing,
        "clock"=>value.has_start ? UInt32(value.clock) : nothing,
        "duration_nanoseconds"=>value.has_duration ? value.duration_nanoseconds : nothing)
end
function _capture_reference(value)
    value === nothing && return nothing
    return Dict("timestamp_nanoseconds"=>value.timestamp_nanoseconds,
        "clock"=>UInt32(value.clock),
        "duration_nanoseconds"=>value.has_duration ? value.duration_nanoseconds : nothing)
end
_capture_recording_policy(store) = Dict("clock"=>UInt32(store.recording_clock))
function _capture_recording_time(store)
    value=PipeWireAO.reference_timestamp_now(store.recording_clock)
    return Dict("clock"=>UInt32(value.clock),"timestamp_nanoseconds"=>value.timestamp_nanoseconds)
end
function _capture_check_recording_policy(value)
    _capture_fields(value,("clock",))
    clock=_capture_uint(value["clock"],UInt32)
    _capture_require(clock in UInt32.((PipeWireAO.METADATA_CLOCK_REALTIME,PipeWireAO.METADATA_CLOCK_TAI)),"invalid recording clock")
    return value
end
function _capture_check_recording(value,policy)
    _capture_fields(value,("received","payload_written"))
    for key in ("received","payload_written")
        time=_capture_fields(value[key],("clock","timestamp_nanoseconds"))
        _capture_require(_capture_uint(time["clock"],UInt32)==policy["clock"],"recorder clock differs")
        _capture_require(_capture_uint(time["timestamp_nanoseconds"])<typemax(UInt64),"invalid recorder timestamp")
    end
    return value
end
function _capture_record_storage(snapshot)
    return GC.@preserve snapshot Dict("abi"=>CAPTURE_METADATA_ABI,"byte_order"=>CAPTURE_BYTE_ORDER,
        "entries"=>[Dict("type"=>PipeWireAO.metadata_type(snapshot,i),
            "data"=>bytes2hex(collect(PipeWireAO.metadata_bytes(snapshot,i))))
            for i in 1:PipeWireAO.metadata_count(snapshot)])
end
function _capture_receipt(receipt)
    header = receipt.header
    return Dict("identity"=>Dict("domain"=>bytes2hex(collect(receipt.identity.domain.bytes)),
            "generation"=>receipt.identity.generation,"sequence"=>receipt.identity.sequence),
        "model_start_ns"=>receipt.model_start_ns,"duration_ns"=>receipt.duration_ns,
        "header"=>Dict(string(key)=>getproperty(header,key) for key in (:flags,:offset,:pts,:dts_offset,:sequence)),
        "optical_classification"=>receipt.optical_classification === nothing ? nothing : UInt32(receipt.optical_classification),
        "trigger_classification"=>receipt.trigger_classification === nothing ? nothing : UInt32(receipt.trigger_classification),
        "exposure_timing"=>_capture_timing(receipt.exposure_timing),
        "reference_timestamp"=>_capture_reference(receipt.reference_timestamp),
        "records"=>_capture_record_storage(receipt.records))
end
_capture_metadata_entries(entries) = throw(ArgumentError("capture metadata count exceeds bound"))
_capture_metadata_entries(entries::AbstractVector) = _capture_require(1 <= length(entries) <= 64,
    "capture metadata count exceeds bound")
_capture_metadata_hex(hex) = throw(ArgumentError("invalid capture metadata bytes"))
_capture_metadata_hex(hex::AbstractString) = _capture_require(iseven(ncodeunits(hex)) &&
    ncodeunits(hex) <= 8192 && occursin(r"^[0-9a-f]*$",hex), "invalid capture metadata bytes")
_capture_array(array,role,contract) = throw(ArgumentError("capture $role type or shape differs"))
_capture_array(array::AbstractArray,role,contract) = _capture_require(
    eltype(array) === contract.type && size(array) == contract.shape, "capture $role type or shape differs")
_capture_exposure_records(records,frames) = throw(ArgumentError("capture exposure count differs"))
_capture_exposure_records(records::AbstractVector,frames) = _capture_require(length(records) == frames,
    "capture exposure count differs")
_capture_shape_matches(shape,expected) = false
_capture_shape_matches(shape::AbstractVector,expected) = length(shape) == length(expected) &&
    Tuple(_capture_uint.(shape)) == expected

function _capture_read_record_storage(value)
    _capture_fields(value,("abi","byte_order","entries"))
    _capture_require(value["abi"] === CAPTURE_METADATA_ABI && value["byte_order"] == CAPTURE_BYTE_ORDER,
        "capture metadata ABI or native byte order is incompatible")
    entries=value["entries"]
    _capture_metadata_entries(entries)
    used=0
    decoded=Pair{UInt32,Vector{UInt8}}[]
    for entry in entries
        _capture_fields(entry,("type","data"))
        type=_capture_uint(entry["type"],UInt32)
        hex=entry["data"]
        _capture_metadata_hex(hex)
        bytes=div(ncodeunits(hex),2)
        used += (bytes+7)&~7
        _capture_require(used <= 4096, "capture metadata exceeds native byte budget")
        push!(decoded,type=>hex2bytes(hex))
    end
    return PipeWireAO.MetadataSnapshot(decoded)
end
const CAPTURE_RECORD_REQUIREMENTS = (
    PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_ACQUISITION_IDENTITY;required=true),
    PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_EXPOSURE_TIMING;required=true),
    PipeWireAO.MetadataRequirement(PipeWireAO.SPA.META_REFERENCE_TIMESTAMP;required=true))
function _capture_check_receipt(value, exposure, domain)
    _capture_fields(value,("identity","model_start_ns","duration_ns","header","optical_classification",
        "trigger_classification","exposure_timing","reference_timestamp","records"))
    snapshot=_capture_read_record_storage(value["records"])
    PipeWireAO.metadata_records_valid(snapshot,CAPTURE_RECORD_REQUIREMENTS) ||
        throw(ArgumentError("capture lacks required independent records"))
    identity=PipeWireAO.acquisition_identity(snapshot)
    header=PipeWireAO.buffer_header(snapshot)
    timing=PipeWireAO.exposure_timing(snapshot)
    reference=PipeWireAO.reference_timestamp(snapshot)
    _capture_require(header !== nothing && identity !== nothing && timing !== nothing && reference !== nothing,
        "capture record facts are incomplete")
    full=bytes2hex(collect(identity.domain.bytes))
    _capture_require((domain === nothing || full == domain) &&
        identity.generation == exposure.generation && identity.sequence == exposure.sequence &&
        _capture_int(value["model_start_ns"]) == exposure.start_model_ns &&
        _capture_uint(value["duration_ns"]) == exposure.duration_ns &&
        timing.has_duration && timing.duration_nanoseconds == exposure.duration_ns,
        "capture receipt identity/model/exposure time differs")
    _capture_require(header.flags & (PipeWireAO.SPA.META_HEADER_FLAG_CORRUPTED | PipeWireAO.SPA.META_HEADER_FLAG_GAP) == 0,
        "capture header is corrupted or a gap")
    canonical=_capture_receipt((; identity,model_start_ns=exposure.start_model_ns,duration_ns=exposure.duration_ns,
        header,optical_classification=PipeWireAO.optical_classification(snapshot),
        trigger_classification=PipeWireAO.trigger_classification(snapshot),exposure_timing=timing,
        reference_timestamp=reference,records=snapshot))
    _capture_require(_capture_same_json(value,canonical), "capture facts differ from their native record payloads")
    return full
end

function _capture_arrays(arrays)
    _capture_require(Set(keys(arrays)) == Set(keys(CLASSIC_CAPTURE_CONTRACTS)), "capture payload roles differ")
    for (role,contract) in pairs(CLASSIC_CAPTURE_CONTRACTS)
        array = getproperty(arrays,role)
        _capture_array(array,role,contract)
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
    checked() = (check(); ControlClient.monotonic() < deadline || throw(InvalidStateException("capture deadline expired",:deadline)))
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
    header = Dict{String,Any}("schema_version"=>4,"profile"=>"classic","run"=>run,"serial"=>serial,
        "probe"=>probe,"stage"=>store.stage,"illumination"=>store.illumination,"settings"=>store.settings,
        "after"=>_capture_cursor(after),"cursor"=>_capture_cursor(after),"payload_bytes"=>bytes,
        "domain_mapping"=>Dict("coordinator"=>after.domain,"wire"=>something(store.domain,repeat("0",32))),
        "recording"=>_capture_recording_policy(store))
    _capture_require(ncodeunits(_capture_json(header))+32 <= CAPTURE_HEADER_BYTES, "capture header exceeds 16 KiB")
    return (;after,bytes,directory,header,request,checked)
end

"""
    capture!(store, acquire; run, serial, probe, cursor, frames, deadline, check=()->nothing)

Write each completed sink-owned Classic sample before calling `acquire()` again.
`acquire()` returns `(sample, exposure)`; samples contain `arrays` and `metadata`.
A request creates `run-R-serial-S/manifest.json` only after all payloads succeed.
Manifest version 4 contains a bounded settings header, after/final cursors,
`domain_mapping` (`coordinator` UInt64 to 16-byte hex `wire` domain), and an
`exposures` array. Each entry binds native model time, full wire identities,
all independent clock/header records, explicitly labelled native metadata ABI/byte
order, intrinsic quality, and four fixed payload
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
        received=_capture_recording_time(store)
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
            "payloads"=>payloads,"quality"=>_capture_quality(arrays),
            "recording"=>Dict("received"=>received,
                "payload_written"=>_capture_recording_time(store)))
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
    return CalibrationActionCodec.Captured(after,request*"/manifest.json",bytes2hex(sha256(encoded)),
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
function read_capture(directory, descriptor::CalibrationActionCodec.Captured;
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
        "after","cursor","payload_bytes","domain_mapping","recording","exposures")
    _capture_fields(manifest,fields)
    _capture_require(manifest["schema_version"] === 4 && manifest["profile"] == expected_profile &&
        manifest["stage"] == expected_stage && manifest["illumination"] == expected_illumination &&
        _capture_same_json(manifest["settings"],settings), "capture profile/stage/illumination/settings differ")
    run,serial = _capture_uint(manifest["run"]),_capture_uint(manifest["serial"])
    _capture_require(run > 0 && serial > 0 && _capture_uint(manifest["probe"],UInt32) <= 16383 &&
        descriptor.manifest == _capture_request(run,serial)*"/manifest.json" &&
        _capture_uint(manifest["payload_bytes"]) == descriptor.bytes, "capture request identity or size differs")
    recording_policy=_capture_check_recording_policy(manifest["recording"])
    records = manifest["exposures"]
    _capture_exposure_records(records,descriptor.frames)
    header = filter(pair -> first(pair) != "exposures",manifest)
    _capture_require(ncodeunits(_capture_json(header))+32 <= CAPTURE_HEADER_BYTES, "capture header exceeds 16 KiB")
    cursor = _capture_read_cursor(manifest["after"])
    mapping = _capture_fields(manifest["domain_mapping"],("coordinator","wire"))
    _capture_require(_capture_uint(mapping["coordinator"]) == cursor.domain, "capture domain mapping differs")
    domain = _capture_hash(mapping["wire"];bytes=16)
    samples = NamedTuple[]
    for (index,record) in enumerate(records)
        _capture_fields(record,("exposure","metadata","payloads","quality","recording"))
        _capture_check_recording(record["recording"],recording_policy)
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
                payload["layout"] == "ROW_MAJOR" && _capture_shape_matches(payload["shape"],contract.shape) &&
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
