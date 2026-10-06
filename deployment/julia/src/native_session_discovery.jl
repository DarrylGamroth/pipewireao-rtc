"""Owner-published, per-user discovery hints for live RTC supervisors."""
module NativeSessionDiscovery

using PipeWireAO

const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod
const SCHEMA_VERSION = Int32(1)
const MAX_RECORD_BYTES = 4096
const MAX_ENTRIES = 128
const MAX_LABEL_BYTES = 256
const MAX_REMOTE_BYTES = 2048
const MAX_NODE_NAME_BYTES = 128
const MAX_DETAIL_BYTES = 512
const RECORD_SUFFIX = ".pod"
const RECORD_PREFIX = "session-"

export SessionRecord, Verification, DiscoveryEntry, FreshSupervisorStatus,
    SelectedSession, registry_directory, encode_record, decode_record,
    publish!, remove!, list_sessions, select_session

@enum Verification::UInt8 Unverified=1 Verified=2 Inaccessible=3 Replaced=4 Malformed=5

"Identity and locator hints published by one live deployment supervisor."
struct SessionRecord
    label::String
    session_id::String
    owner_pid::UInt32
    incarnation::Int64
    remote::String
    node_name::String
    function SessionRecord(label::AbstractString, session_id::AbstractString,
            owner_pid::UInt32, incarnation::Int64, remote::AbstractString,
            node_name::AbstractString)
        name = _string(label; limit=MAX_LABEL_BYTES)
        id = _session_id(session_id)
        owner_pid > 0 || throw(ArgumentError("session owner PID must be positive"))
        incarnation > 0 || throw(ArgumentError("supervisor incarnation must be positive"))
        private_remote = _string(remote; limit=MAX_REMOTE_BYTES)
        isabspath(private_remote) || throw(ArgumentError("session remote must be an absolute private socket path"))
        node = _node_name(node_name)
        new(name, id, owner_pid, incarnation, private_remote, node)
    end
end

"A fresh native status result returned by the injected selection verifier."
struct FreshSupervisorStatus
    session_id::String
    owner_pid::UInt32
    incarnation::Int64
    remote::String
    node_name::String
    global_id::UInt32
    object_serial::UInt64
    query_token::Int64
    lifecycle::Symbol
    authority::Symbol
    function FreshSupervisorStatus(session_id::AbstractString, owner_pid::UInt32,
            incarnation::Int64, remote::AbstractString, node_name::AbstractString, global_id::UInt32,
            object_serial::UInt64, query_token::Int64, lifecycle::Symbol, authority::Symbol)
        id = _session_id(session_id)
        owner_pid > 0 && incarnation > 0 && global_id > 0 && global_id < typemax(UInt32) &&
            object_serial > 0 && query_token > 0 ||
            throw(ArgumentError("invalid fresh supervisor identity or status token"))
        lifecycle in (:preparing, :ready, :fault, :stopped) ||
            throw(ArgumentError("unknown supervisor lifecycle"))
        authority in (:deployment_supervisor, :standalone_runner) ||
            throw(ArgumentError("unknown native endpoint authority"))
        private_remote = _string(remote; limit=MAX_REMOTE_BYTES)
        isabspath(private_remote) || throw(ArgumentError("fresh supervisor remote must be absolute"))
        new(id, owner_pid, incarnation, private_remote,
            _node_name(node_name),
            global_id, object_serial, query_token, lifecycle, authority)
    end
end

struct DiscoveryEntry
    record::Union{Nothing,SessionRecord}
    verification::Verification
    detail::String
    function DiscoveryEntry(record::Union{Nothing,SessionRecord}, verification::Verification,
            detail::AbstractString)
        new(record, verification, _diagnostic(detail))
    end
end
struct SelectedSession
    record::SessionRecord
    status::FreshSupervisorStatus
end

_struct(fields::Pod...) = SPA.Struct(Pod[fields...])
_fields(value::SPA.Struct) = value.values
function _fields(pod::Pod)
    PipeWireAO.pod_type(pod) == SPA.POD_STRUCT || throw(ArgumentError("discovery record must be a SPA Struct"))
    return PipeWireAO.pod_value(SPA.Struct, pod).values
end
function _scalar(pod::Pod, type::UInt32, ::Type{T}) where T
    PipeWireAO.pod_type(pod) == type || throw(ArgumentError("wrong discovery scalar POD type"))
    sizeof(pod) == 8 + sizeof(T) || throw(ArgumentError("wrong discovery scalar POD width"))
    return PipeWireAO.pod_value(T, pod)
end
_int(pod) = _scalar(pod, SPA.POD_INT, Int32)
_long(pod) = _scalar(pod, SPA.POD_LONG, Int64)
_id(pod) = _scalar(pod, SPA.POD_ID, SPA.Id).value
function _pod_string(pod, label; limit)
    PipeWireAO.pod_type(pod) == SPA.POD_STRING || throw(ArgumentError("$label must be a String POD"))
    return _string(PipeWireAO.pod_value(String, pod); limit)
end
function _string(value::AbstractString; limit::Int)
    !isempty(value) && ncodeunits(value) <= limit && !occursin('\0', value) && isvalid(value) ||
        throw(ArgumentError("invalid or oversized discovery string"))
    return String(value)
end
function _session_id(value::AbstractString)
    id = _string(value; limit=36)
    occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id) ||
        throw(ArgumentError("session ID must be a lowercase UUID"))
    return id
end
function _node_name(value::AbstractString)
    name = _string(value; limit=MAX_NODE_NAME_BYTES)
    all(c -> isascii(c) && (isletter(c) || isnumeric(c) || c in ('_', '.', '-')), name) ||
        throw(ArgumentError("supervisor node name must use ASCII letters, digits, underscore, dot, or hyphen"))
    return name
end
_filename(record::SessionRecord) = RECORD_PREFIX * record.session_id * RECORD_SUFFIX

function encode_record(record::SessionRecord)
    pod = Pod(_struct(Pod(SCHEMA_VERSION), Pod(record.label), Pod(record.session_id),
        Pod(SPA.Id(record.owner_pid)), Pod(record.incarnation), Pod(record.remote),
        Pod(record.node_name)))
    sizeof(pod) <= MAX_RECORD_BYTES || throw(ArgumentError("session discovery record exceeds 4 KiB"))
    return pod
end

function _decode_record(pod::Pod)
    sizeof(pod) <= MAX_RECORD_BYTES || throw(ArgumentError("session discovery record exceeds 4 KiB"))
    data = pod.data
    length(data) >= 8 || throw(ArgumentError("incomplete discovery POD"))
    Int(only(reinterpret(UInt32, @view data[1:4]))) + 8 == length(data) ||
        throw(ArgumentError("discovery POD has trailing or truncated bytes"))
    f = _fields(pod)
    length(f) == 7 || throw(ArgumentError("wrong discovery record arity"))
    _int(f[1]) == SCHEMA_VERSION || throw(ArgumentError("unsupported discovery schema version"))
    return SessionRecord(_pod_string(f[2], "display label"; limit=MAX_LABEL_BYTES),
        _pod_string(f[3], "session ID"; limit=36), _id(f[4]), _long(f[5]),
        _pod_string(f[6], "private remote"; limit=MAX_REMOTE_BYTES),
        _pod_string(f[7], "supervisor node name"; limit=MAX_NODE_NAME_BYTES))
end

function decode_record(bytes::AbstractVector{UInt8})
    length(bytes) <= MAX_RECORD_BYTES || throw(ArgumentError("session discovery record exceeds 4 KiB"))
    length(bytes) >= 8 || throw(ArgumentError("incomplete discovery POD"))
    start = firstindex(bytes)
    Int(only(reinterpret(UInt32, @view bytes[start:(start + 3)]))) + 8 == length(bytes) ||
        throw(ArgumentError("discovery POD has trailing or truncated bytes"))
    return _decode_record(Pod(Vector{UInt8}(bytes)))
end
decode_record(pod::Pod) = _decode_record(pod)

_uid() = ccall(:geteuid, Cuint, ())
_private(st) = (st.mode & 0o077) == 0
function _diagnostic(value::AbstractString)
    message = replace(String(value), '\0' => ' ')
    ncodeunits(message) <= MAX_DETAIL_BYTES && return message
    stop = 0
    for index in eachindex(message)
        next = nextind(message, index)
        next - firstindex(message) <= MAX_DETAIL_BYTES || break
        stop = index
    end
    return stop == 0 ? "diagnostic exceeds 512 bytes" : String(SubString(message, firstindex(message), stop))
end
function _check_directory(path::AbstractString)
    isabspath(path) && ncodeunits(path) <= 4096 && !occursin('\0', path) ||
        throw(ArgumentError("discovery directory must be a bounded absolute path"))
    st = lstat(path)
    isdir(st) && st.uid == _uid() && (st.mode & 0o700) == 0o700 && _private(st) ||
        throw(ArgumentError("discovery directory must be an owned, private, non-symlink directory"))
    return String(path)
end
function _ensure_private_child(parent::String, name::String)
    path = joinpath(parent, name)
    if !ispath(path) && !islink(path)
        try
            mkdir(path; mode=0o700)
        catch error
            ispath(path) || rethrow(error)
        end
    end
    st = lstat(path)
    isdir(st) && st.uid == _uid() && (st.mode & 0o700) == 0o700 && _private(st) ||
        throw(ArgumentError("discovery path component must be an owned, private directory: $path"))
    return path
end

"Create or validate XDG_RUNTIME_DIR/pipewireao-rtc/sessions (mode 0700)."
function registry_directory(runtime_dir::AbstractString=get(ENV, "XDG_RUNTIME_DIR", ""))
    isempty(runtime_dir) && throw(ArgumentError("XDG_RUNTIME_DIR is required for local session discovery"))
    root = _check_directory(runtime_dir)
    app = _ensure_private_child(root, "pipewireao-rtc")
    return _ensure_private_child(app, "sessions")
end

function _check_registry(path::AbstractString)
    directory = _check_directory(path)
    return directory
end
function _check_file(path::String; absent_ok::Bool=false)
    if !ispath(path) && !islink(path)
        absent_ok && return nothing
        throw(ArgumentError("discovery record does not exist"))
    end
    st = lstat(path)
    isfile(st) && st.uid == _uid() && _private(st) && (st.mode & 0o400) == 0o400 ||
        throw(ArgumentError("discovery record must be an owned, private, non-symlink file"))
    st.size <= MAX_RECORD_BYTES || throw(ArgumentError("discovery record exceeds 4 KiB"))
    return st
end
function _read_record(path::String)
    before = _check_file(path)
    bytes = open(path, "r") do io
        read(io, MAX_RECORD_BYTES + 1)
    end
    length(bytes) <= MAX_RECORD_BYTES || throw(ArgumentError("discovery record exceeds 4 KiB"))
    after = _check_file(path)
    (before.device, before.inode) == (after.device, after.inode) ||
        throw(ArgumentError("discovery record changed while reading"))
    return decode_record(bytes)
end

function _with_registry_lock(f, directory::String)
    lockpath = joinpath(directory, ".lock")
    if !ispath(lockpath) && !islink(lockpath)
        open(lockpath, "w") do io
            chmod(lockpath, 0o600)
        end
    end
    st = lstat(lockpath)
    isfile(st) && st.uid == _uid() && _private(st) ||
        throw(ArgumentError("session discovery lock must be owned and private"))
    open(lockpath, "r+") do io
        ccall(:flock, Cint, (Cint, Cint), Base.fd(io), 6) == 0 ||
            throw(ArgumentError("session discovery registry is busy"))
        try
            return f()
        finally
            ccall(:flock, Cint, (Cint, Cint), Base.fd(io), 8)
        end
    end
end

function _atomic_replace(directory::String, path::String, pod::Pod)
    temp, io = mktemp(directory)
    try
        chmod(temp, 0o600)
        write(io, pod.data)
        flush(io)
        close(io)
        Base.Filesystem.rename(temp, path)
    finally
        isopen(io) && close(io)
        ispath(temp) && rm(temp)
    end
    return path
end

"Atomically publish this process's locator under its stable session UUID."
function publish!(directory::AbstractString, record::SessionRecord)
    record.owner_pid == UInt32(getpid()) || throw(ArgumentError("only the owning supervisor may publish its locator"))
    dir = _check_registry(directory)
    pod = encode_record(record)
    path = joinpath(dir, _filename(record))
    return _with_registry_lock(dir) do
        _check_file(path; absent_ok=true)
        _atomic_replace(dir, path, pod)
    end
end

"Remove only this incarnation's record; a replacement incarnation is retained."
function remove!(directory::AbstractString, expected::SessionRecord)
    expected.owner_pid == UInt32(getpid()) || throw(ArgumentError("only the owning supervisor may remove its locator"))
    dir = _check_registry(directory)
    path = joinpath(dir, _filename(expected))
    return _with_registry_lock(dir) do
        _check_file(path; absent_ok=true) === nothing && return false
        current = _read_record(path)
        (current.session_id, current.owner_pid, current.incarnation) ==
            (expected.session_id, expected.owner_pid, expected.incarnation) || return false
        rm(path)
        return true
    end
end

function _entry(path::String)
    name = basename(path)
    match_id = match(r"^session-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.pod$", name)
    match_id === nothing && return DiscoveryEntry(nothing, Malformed,
        "invalid session discovery filename")
    try
        record = _read_record(path)
        record.session_id == match_id.captures[1] || throw(ArgumentError("record UUID differs from its filename"))
        return DiscoveryEntry(record, Unverified, "listing is a locator hint; live status has not been queried")
    catch error
        return DiscoveryEntry(nothing, Malformed, sprint(showerror, error))
    end
end

"List bounded owner-published records. No liveness or lifecycle is inferred."
function list_sessions(directory::AbstractString)
    dir = _check_registry(directory)
    files = filter(name -> endswith(name, RECORD_SUFFIX), readdir(dir; join=true))
    length(files) <= MAX_ENTRIES || throw(ArgumentError("session discovery exceeds 128 records"))
    entries = DiscoveryEntry[]
    for path in sort(files)
        push!(entries, _entry(path))
    end
    return entries
end

function _matches(record::SessionRecord, status::FreshSupervisorStatus)
    return status.session_id == record.session_id && status.owner_pid == record.owner_pid &&
        status.incarnation == record.incarnation && status.remote == record.remote &&
        status.node_name == record.node_name &&
        status.authority === :deployment_supervisor
end

"Verify an explicitly selected listing against a fresh native supervisor status callback."
function select_session(entry::DiscoveryEntry, verifier)
    entry.record === nothing && return DiscoveryEntry(nothing, Malformed, "record cannot be selected")
    entry.verification === Unverified || return DiscoveryEntry(entry.record, entry.verification, entry.detail)
    record = entry.record::SessionRecord
    status = try
        verifier(record)
    catch error
        return DiscoveryEntry(record, Inaccessible, sprint(showerror, error))
    end
    return _selected_result(record, status)
end

function _selected_result(record::SessionRecord, status::FreshSupervisorStatus)
    status.authority === :deployment_supervisor || return DiscoveryEntry(record, Replaced,
        "verified endpoint is a standalone runner, not the deployment supervisor")
    _matches(record, status) || return DiscoveryEntry(record, Replaced,
        "fresh endpoint identity does not match the selected supervisor incarnation")
    return SelectedSession(record, status)
end
_selected_result(record::SessionRecord, status) = DiscoveryEntry(record, Inaccessible,
    "verifier did not return a fresh supervisor identity and status")

end # module NativeSessionDiscovery
