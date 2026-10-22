"""Headless, content-addressed configuration artifacts and native operation history."""
module ConfigurationStore

using SQLite, DBInterface, JSON, SHA, FITSIO
using ..Artifacts
using ..NativeControlCodec
using ..NativeRunnerCodec

export Store, default_root, register!, list_artifacts, get_artifact, read_artifact, materialize!, history

const PROTOCOL = "pipewireao.configuration/1"
const MAX_MANIFEST_BYTES = 1024 * 1024
const OPERATION_SCHEMA = """
CREATE TABLE IF NOT EXISTS operation_events(
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 session_id TEXT NOT NULL,
 operation_key TEXT NOT NULL,
 event TEXT NOT NULL CHECK(event IN ('requested','completed','unknown')),
 record BLOB NOT NULL,
 client_name TEXT NOT NULL DEFAULT '',
 client_pid INTEGER NOT NULL DEFAULT 0,
 recorded_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')))
"""

"Return the shared per-user configuration store location without opening it."
function default_root()
    state_home = get(ENV,"XDG_STATE_HOME","")
    isabspath(state_home) || (state_home=joinpath(homedir(),".local","state"))
    return joinpath(state_home,"pipewireao","configuration")
end

"A headless Git artifact repository and SQLite catalog/journal under one root."
struct Store
    root::String
    repository::String
    database::String
    object_format::String
end

function locked(f, root)
    open(joinpath(root, ".lock"), "a+") do io
        # flock is held by the open description and released on process death.
        ccall(:flock, Cint, (Cint, Cint), fd(io), 2) == 0 || systemerror("flock", true)
        try
            return f()
        finally
            ccall(:flock, Cint, (Cint, Cint), fd(io), 8)
        end
    end
end

function git_command(repository, arguments...)
    command = `git --no-replace-objects --git-dir=$repository -c core.hooksPath=/dev/null -c gc.auto=0 -c core.fsync=all $(collect(arguments))`
    return addenv(command, "GIT_CONFIG_NOSYSTEM"=>"1", "GIT_CONFIG_GLOBAL"=>"/dev/null",
        "GIT_CONFIG_COUNT"=>"0", "GIT_ATTR_NOSYSTEM"=>"1",
        "GIT_AUTHOR_NAME"=>"PipeWireAO configuration", "GIT_AUTHOR_EMAIL"=>"configuration@localhost",
        "GIT_COMMITTER_NAME"=>"PipeWireAO configuration", "GIT_COMMITTER_EMAIL"=>"configuration@localhost",
        "GIT_AUTHOR_DATE"=>"@0 +0000", "GIT_COMMITTER_DATE"=>"@0 +0000",
        "GIT_DIR"=>nothing,"GIT_WORK_TREE"=>nothing,"GIT_COMMON_DIR"=>nothing,
        "GIT_OBJECT_DIRECTORY"=>nothing,"GIT_ALTERNATE_OBJECT_DIRECTORIES"=>nothing,
        "GIT_NAMESPACE"=>nothing,"GIT_CONFIG_PARAMETERS"=>nothing)
end
function git_read(repository, arguments...; input=nothing)
    command = git_command(repository, arguments...)
    return input === nothing ? read(command) : read(pipeline(command; stdin=IOBuffer(input)))
end
git_text(repository, arguments...; kwargs...) = strip(String(git_read(repository, arguments...; kwargs...)))

function database(f, store::Store)
    db = SQLite.DB(store.database)
    try
        DBInterface.execute(db, "PRAGMA busy_timeout=5000")
        DBInterface.execute(db, "PRAGMA synchronous=FULL")
        return f(db)
    finally
        SQLite.close(db)
    end
end

function Store(root::AbstractString=default_root())
    root = abspath(bounded_name(root,"root"))
    mkpath(root; mode=0o700)
    repository = joinpath(root, "artifacts.git")
    format = locked(root) do
        if !isdir(repository)
            git_read(repository, "init", "--bare", "--quiet", repository)
        end
        git_text(repository, "rev-parse", "--is-bare-repository") == "true" ||
            throw(ArgumentError("artifact repository must be bare"))
        format = git_text(repository, "rev-parse", "--show-object-format")
        format in ("sha1", "sha256") || throw(ArgumentError("unsupported Git object format"))
        store = Store(root, repository, joinpath(root, "history.sqlite3"), format)
        database(store) do db
            DBInterface.execute(db, "PRAGMA journal_mode=WAL")
            DBInterface.execute(db, "CREATE TABLE IF NOT EXISTS configuration_schema(version INTEGER NOT NULL)")
            versions = [Int(row.version) for row in DBInterface.execute(db, "SELECT version FROM configuration_schema")]
            isempty(versions) && DBInterface.execute(db, "INSERT INTO configuration_schema VALUES(1)")
            isempty(versions) || versions == [1] || throw(ArgumentError("unsupported configuration schema"))
            DBInterface.execute(db, """CREATE TABLE IF NOT EXISTS artifacts(
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,
                content_oid TEXT NOT NULL,commit_oid TEXT NOT NULL,object_format TEXT NOT NULL,
                manifest TEXT NOT NULL,
                recorded_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')))""")
            DBInterface.execute(db,"""CREATE TABLE IF NOT EXISTS artifact_materializations(
                path TEXT PRIMARY KEY,artifact_id TEXT NOT NULL,storage_order TEXT NOT NULL,sha256 TEXT NOT NULL)""")
            DBInterface.execute(db, OPERATION_SCHEMA)
            columns = Set(String(row.name) for row in DBInterface.execute(db,"PRAGMA table_info(operation_events)"))
            "client_name" in columns || DBInterface.execute(db,"ALTER TABLE operation_events ADD COLUMN client_name TEXT NOT NULL DEFAULT ''")
            "client_pid" in columns || DBInterface.execute(db,"ALTER TABLE operation_events ADD COLUMN client_pid INTEGER NOT NULL DEFAULT 0")
            "operation_key" in columns || DBInterface.execute(db,"ALTER TABLE operation_events ADD COLUMN operation_key TEXT NOT NULL DEFAULT ''")
            DBInterface.execute(db,"UPDATE operation_events SET operation_key='legacy:'||sequence WHERE operation_key=''")
            DBInterface.execute(db,"CREATE UNIQUE INDEX IF NOT EXISTS operation_events_key_event ON operation_events(operation_key,event)")
            DBInterface.execute(db,"CREATE INDEX IF NOT EXISTS operation_events_event_sequence ON operation_events(event,sequence)")
            DBInterface.execute(db,"CREATE INDEX IF NOT EXISTS operation_events_session_event_sequence ON operation_events(session_id,event,sequence)")
        end
        chmod(store.database, 0o600)
        return format
    end
    return Store(root, repository, joinpath(root, "history.sqlite3"), format)
end

function checked_oid(store, oid)
    oid isa AbstractString && length(oid) == (store.object_format == "sha1" ? 40 : 64) &&
        all(c -> c in '0':'9' || c in 'a':'f', oid) || throw(ArgumentError("expected a full Git object ID"))
    return String(oid)
end
blob_oid(store, bytes; write=false) = git_text(store.repository, "hash-object", "--no-filters",
    (write ? ["-w"] : String[])..., "--stdin"; input=bytes)
function read_blob(store, oid; limit=Artifacts.MAX_FITS_BYTES)
    oid = checked_oid(store, oid)
    size = parse(Int, git_text(store.repository, "cat-file", "-s", oid))
    0 <= size <= limit || throw(ArgumentError("Git object exceeds byte limit"))
    bytes = git_read(store.repository, "cat-file", "blob", oid)
    length(bytes) == size && blob_oid(store, bytes) == oid || throw(ArgumentError("Git object integrity failure"))
    return bytes
end

# JSON identity is independent of dictionary iteration order, including nested metadata.
function canonical_json(value)
    if value isa AbstractDict
        all(key -> key isa AbstractString, keys(value)) || throw(ArgumentError("metadata keys must be strings"))
        names = sort!(String.(collect(keys(value))))
        return "{" * join((String(JSON.json(name)) * ":" * canonical_json(value[name]) for name in names), ",") * "}"
    elseif value isa Union{AbstractVector,Tuple}
        return "[" * join(canonical_json.(value), ",") * "]"
    elseif value isa Union{AbstractString,Bool,Integer,Nothing}
        return String(JSON.json(value))
    elseif value isa AbstractFloat
        isfinite(value) || throw(ArgumentError("metadata numbers must be finite"))
        return String(JSON.json(value))
    end
    throw(ArgumentError("metadata must contain JSON values"))
end
function bounded_name(value, field; empty=false)
    value isa AbstractString && (empty || !isempty(value)) && ncodeunits(value) <= 4096 &&
        isvalid(value) && !occursin('\0', value) || throw(ArgumentError("invalid $field"))
    return String(value)
end

"""Capture and validate the original FITS once, then pin Git objects before indexing them."""
function register!(store::Store, source::Artifacts.FITSArtifact, ::Type{T}, shape;
        label, scope, metadata=Dict{String,Any}(), schema="") where T
    label = bounded_name(label, "label")
    scope = scope isa AbstractDict ? JSON.parse(canonical_json(scope), Dict{String,Any}) : bounded_name(scope, "scope")
    schema = bounded_name(schema, "schema"; empty=true)
    metadata isa AbstractDict || throw(ArgumentError("metadata must be a JSON object"))
    T in Artifacts.TARGET_TYPES || throw(ArgumentError("unsupported target type"))
    Artifacts.checked_shape(shape, sizeof(T))
    original = Artifacts.snapshot(source.path; check=()->nothing)
    prepared = Artifacts.prepare_snapshot(source, T, shape, original)
    provenance = copy(prepared.provenance)
    delete!(provenance, "source")
    # Validate metadata before importing any Git objects.
    canonical_json(metadata)
    return locked(store.root) do
        content = blob_oid(store, original)
        manifest = Dict("protocol"=>PROTOCOL, "content_oid"=>content,
            "object_format"=>store.object_format,"label"=>label,"scope"=>scope,
            "schema"=>schema,"metadata"=>metadata,"preparation"=>provenance)
        text = canonical_json(manifest)
        ncodeunits(text) <= MAX_MANIFEST_BYTES || throw(ArgumentError("manifest exceeds 1 MiB"))
        blob_oid(store, original; write=true) == content || error("Git content identity mismatch")
        id = blob_oid(store, codeunits(text); write=true)
        tree = git_text(store.repository, "mktree"; input=codeunits(
            "100644 blob $content\toriginal.fits\n100644 blob $id\tmanifest.json\n"))
        commit = git_text(store.repository, "commit-tree", tree; input=codeunits("Configuration artifact $id\n"))
        ref = "refs/artifacts/$id"
        existing = git_text(store.repository, "for-each-ref", "--format=%(objectname)", ref)
        if isempty(existing)
            git_read(store.repository, "update-ref", ref, commit, repeat("0", length(id)))
        else
            existing == commit || throw(ArgumentError("immutable artifact ref differs"))
        end
        database(store) do db
            DBInterface.execute(db, "INSERT OR IGNORE INTO artifacts(id,content_oid,commit_oid,object_format,manifest) VALUES(?,?,?,?,?)",
                (id, content, commit, store.object_format, text))
        end
        return get_artifact(store, id)
    end
end

"""Register generated host arrays through the same FITS preparation contract."""
function register!(store::Store, data::Array{T}; label, scope, metadata=Dict{String,Any}(), schema="") where T
    T in Artifacts.TARGET_TYPES || throw(ArgumentError("unsupported target type"))
    Artifacts.checked_shape(size(data), sizeof(T))
    mktempdir() do directory
        path = joinpath(directory, "generated.fits")
        FITS(path, "w") do fits
            write(fits, T === Bool ? UInt8.(data) : data)
        end
        return register!(store, Artifacts.FITSArtifact(path; axes=Tuple(1:ndims(data))), T, size(data);
            label, scope, metadata, schema)
    end
end

function row_record(store, row; verify=true)
    text = String(row.manifest)
    if verify
        String(read_blob(store, String(row.id); limit=MAX_MANIFEST_BYTES)) == text ||
            throw(ArgumentError("catalog manifest differs from Git"))
    end
    manifest = JSON.parse(text, Dict{String,Any})
    manifest["content_oid"] == String(row.content_oid) && manifest["object_format"] == store.object_format ||
        throw(ArgumentError("catalog manifest identity mismatch"))
    checked_oid(store,String(row.content_oid)); checked_oid(store,String(row.commit_oid))
    return Dict("id"=>String(row.id),"content_oid"=>String(row.content_oid),
        "commit_oid"=>String(row.commit_oid),"object_format"=>String(row.object_format),
        "sequence"=>Int(row.sequence),"recorded_at"=>String(row.recorded_at),
        "manifest"=>manifest)
end
function page_limit(limit)
    limit isa Integer && !(limit isa Bool) && 1 <= limit <= 100 || throw(ArgumentError("limit must be in 1:100"))
    return Int(limit)
end
"Return catalog metadata after verifying the pinned Git manifest, tree and original bytes."
function get_artifact(store::Store, id::AbstractString)
    id = checked_oid(store, id)
    record = database(store) do db
        for row in DBInterface.execute(db, "SELECT * FROM artifacts WHERE id=?", (id,))
            return row_record(store, row)
        end
        throw(KeyError(id))
    end
    manifest = record["manifest"]
    manifest["content_oid"] == record["content_oid"] && manifest["object_format"] == store.object_format ||
        throw(ArgumentError("catalog identity mismatch"))
    commit = checked_oid(store,record["commit_oid"])
    pinned = git_text(store.repository,"for-each-ref","--format=%(objectname)","refs/artifacts/$id")
    pinned == commit || throw(ArgumentError("artifact Git commit is not pinned"))
    tree = git_text(store.repository,"ls-tree",commit)
    expected = "100644 blob $(record["id"])\tmanifest.json\n100644 blob $(record["content_oid"])\toriginal.fits"
    tree == expected || throw(ArgumentError("artifact Git tree differs from catalog"))
    read_blob(store, record["content_oid"])
    return record
end
"Read and verify the exact original FITS bytes by immutable catalog identity."
read_artifact(store::Store, id::AbstractString) = read_blob(store, get_artifact(store, id)["content_oid"])
"Publish verified read-only transport cache bytes; retain them until explicit maintenance."
function materialize!(store::Store, id::AbstractString; storage_order="row-major")
    storage_order in ("row-major","column-major") || throw(ArgumentError("unsupported storage order"))
    record = get_artifact(store,id)
    preparation = record["manifest"]["preparation"]
    T = only(filter(T->string(T)==preparation["target_type"],Artifacts.TARGET_TYPES))
    original = read_artifact(store,id)
    source = Artifacts.FITSArtifact("catalog-snapshot";hdu=preparation["hdu"],axes=preparation["axes"])
    prepared = Artifacts.prepare_snapshot(source,T,preparation["target_shape"],original)
    bytes = if storage_order == "row-major"
        Artifacts.pack(prepared)
    else
        output = Vector{UInt8}(undef,length(prepared.data)*sizeof(T))
        position = 1
        for value in prepared.data
            word = Artifacts.unsigned_word(value)
            for shift in 0:8:(8*sizeof(T)-1)
                output[position] = UInt8((word >> shift) & 0xff)
                position += 1
            end
        end
        output
    end
    digest = bytes2hex(SHA.sha256(bytes))
    return locked(store.root) do
        directory = joinpath(store.root,"materialized",id)
        mkpath(joinpath(store.root,"materialized");mode=0o700)
        cache = joinpath(store.root,"materialized")
        cache_bytes = 0
        cache_files = 0
        for (base,_,files) in walkdir(cache)
            for name in files
                entry = joinpath(base,name)
                islink(entry) && throw(ArgumentError("materialization cache contains a symlink"))
                cache_bytes += filesize(entry)
                cache_files += 1
            end
        end
        original_missing = !isfile(joinpath(directory,"original.fits"))
        prepared_missing = !isfile(joinpath(directory,storage_order*".bin"))
        addition = (original_missing ? length(original) : 0) +
            (prepared_missing ? length(bytes) : 0)
        additional_files = Int(original_missing) + Int(prepared_missing)
        cache_bytes + addition <= 1024^3 && cache_files + additional_files <= 1024 ||
            throw(ArgumentError("materialization cache capacity exceeded; explicit maintenance required"))
        mkpath(directory;mode=0o700)
        function retain(name,content)
            retained_path = joinpath(directory,name)
            if ispath(retained_path)
                isfile(retained_path) && !islink(retained_path) && filesize(retained_path)==length(content) && read(retained_path)==content || throw(ArgumentError("materialized artifact integrity failure"))
            else
                temporary,io = mktemp(directory)
                try
                    write(io,content); flush(io)
                    ccall(:fsync,Cint,(Cint,),fd(io)) == 0 || systemerror("fsync",true)
                    close(io); chmod(temporary,0o400); mv(temporary,retained_path)
                    open(directory) do directory_io
                        ccall(:fsync,Cint,(Cint,),fd(directory_io)) == 0 || systemerror("fsync",true)
                    end
                finally
                    isopen(io) && close(io)
                    ispath(temporary) && rm(temporary)
                end
            end
            return retained_path
        end
        path = retain("original.fits",original)
        prepared_path = retain(storage_order*".bin",bytes)
        database(store) do db
            DBInterface.execute(db,"INSERT OR IGNORE INTO artifact_materializations(path,artifact_id,storage_order,sha256) VALUES(?,?,?,?)",
                (prepared_path,id,storage_order,digest))
        end
        merge!(record,Dict("path"=>path,"prepared_path"=>prepared_path,"storage_order"=>storage_order,
            "sha256"=>digest,"target_type"=>string(T),"shape"=>preparation["target_shape"],"schema"=>record["manifest"]["schema"]))
        return record
    end
end

"List a bounded page in registration order, using an exclusive sequence cursor."
function list_artifacts(store::Store; limit=50, after_sequence=0)
    limit = page_limit(limit)
    after_sequence isa Integer && after_sequence >= 0 || throw(ArgumentError("invalid cursor"))
    items = database(store) do db
        items = Dict{String,Any}[]
        total = 0
        for row in DBInterface.execute(db,
                "SELECT * FROM artifacts WHERE sequence>? ORDER BY sequence LIMIT ?", (after_sequence, limit))
            # At most four MiB of canonical manifests per catalog page.
            bytes = ncodeunits(row.manifest)
            total + bytes > 4*MAX_MANIFEST_BYTES && !isempty(items) && break
            push!(items,row_record(store,row))
            total += bytes
        end
        items
    end
    return Dict("items"=>items, "next_after_sequence"=>isempty(items) ? nothing : items[end]["sequence"])
end

function header_key(session, header)
    c = header.controller
    c === nothing && throw(ArgumentError("history record has no controller"))
    return join((session,header.endpoint_instance,c.global_id,reinterpret(Int64,c.serial),c.instance,header.token), ":")
end
function header_fields(session, header)
    c = header.controller
    return Dict{String,Any}("key"=>header_key(session,header),"session_id"=>session,
        "endpoint_instance"=>header.endpoint_instance,"token"=>header.token,
        "controller"=>Dict("global_id"=>c.global_id,"serial"=>c.serial,"instance"=>c.instance),
        "operation"=>String(NativeRunnerCodec.OPERATIONS[Int(header.operation)]),
        "graph"=>nothing,"changes"=>nothing,"outcome"=>"unknown","error"=>nothing)
end
function json_value(value::NativeRunnerCodec.RunnerScalar)
    numeric = value.kind === :float ? reinterpret(Float32,value.value) :
        value.kind === :double ? reinterpret(Float64,value.value) : value.value
    result = Dict{String,Any}("kind"=>String(value.kind),"value"=>numeric)
    value.kind in (:float,:double) && (result["bits"] = string(value.value))
    return result
end
json_value(value::NamedTuple) = Dict(String(key)=>json_value(v) for (key,v) in pairs(value))
json_value(value::AbstractDict) = Dict(String(key)=>json_value(v) for (key,v) in pairs(value))
json_value(value::Union{AbstractVector,Tuple}) = json_value.(collect(value))
json_value(value::Enum) = string(value)
json_value(value) = value

"""Project the shared raw native journal. Missing/unknown completions never imply success.

Pages contain at most `limit` operations and are ordered by first event sequence.
The cursor excludes newer operations while retaining every event of each returned operation.
"""
function history(store::Store; limit=50, before_sequence=typemax(Int64), session_id=nothing, include_records=false)
    limit = page_limit(limit)
    before_sequence isa Integer && before_sequence > 0 || throw(ArgumentError("invalid history cursor"))
    session_id === nothing || bounded_name(session_id,"session_id")
    include_records isa Bool || throw(ArgumentError("include_records must be a boolean"))
    items = Dict{String,Any}[]
    database(store) do db
        query = """SELECT e.sequence,e.operation_key FROM operation_events e WHERE e.sequence<?
            AND NOT EXISTS(SELECT 1 FROM operation_events prior
                WHERE prior.operation_key=e.operation_key AND prior.sequence<e.sequence)""" *
            (session_id === nothing ? "" : " AND e.session_id=?") * " ORDER BY e.sequence DESC LIMIT ?"
        args = session_id === nothing ? (before_sequence,limit) : (before_sequence,session_id,limit)
        # Copy the bounded seed rows before running another statement on this connection.
        seeds = [(Int(row.sequence),String(row.operation_key)) for row in DBInterface.execute(db,query,args)]
        for (start_sequence,key) in seeds
            item = nothing
            unresolved = false
            for row in DBInterface.execute(db,"SELECT sequence,session_id,event,recorded_at,client_name,client_pid,length(record) AS record_size,CASE WHEN length(record)<=65536 THEN record ELSE NULL END AS record FROM operation_events WHERE operation_key=? ORDER BY sequence LIMIT 3",(key,))
                sequence = Int(row.sequence); session = String(row.session_id)
                event = String(row.event)
                bytes = row.record === missing ? UInt8[] : Vector{UInt8}(row.record)
                try
                    Int(row.record_size) <= 65536 || throw(ArgumentError("journal record exceeds native lifecycle byte limit"))
                    if event in ("completed","unknown")
                        completion = NativeRunnerCodec.decode_completion(bytes)
                        header = completion.header
                        header_key(session,header) == key || throw(ArgumentError("journal operation key differs from native identity"))
                        item === nothing && (item = header_fields(session,header))
                        item["operation"] == String(NativeRunnerCodec.OPERATIONS[Int(header.operation)]) || throw(ArgumentError("history operation identity mismatch"))
                        include_records && (item[event*"_hex"] = bytes2hex(bytes))
                        unresolved |= event == "unknown"
                        item["outcome"] = unresolved ? "unknown" :
                            completion.error === nothing ? string(completion.result.outcome) : "failed"
                        item["error"] = completion.error === nothing ? nothing :
                            Dict("field"=>completion.error.field,"message"=>completion.error.message,"result"=>header.result)
                        if completion.result !== nothing
                            details = completion.result.details
                            if haskey(details,:graph)
                                get(item,"graph",nothing) in (nothing,details.graph) ||
                                    throw(ArgumentError("journal request/completion graph differs"))
                                item["graph"] = details.graph
                            end
                            item["details"] = json_value(details)
                        end
                    else
                        header,payload = NativeControlCodec.decode_request(bytes)
                        command = NativeRunnerCodec.decode_request(header,payload)
                        header_key(session,header) == key || throw(ArgumentError("journal operation key differs from native identity"))
                        item === nothing && (item = header_fields(session,header))
                        item["operation"] == String(NativeRunnerCodec.OPERATIONS[Int(header.operation)]) || throw(ArgumentError("history operation identity mismatch"))
                        include_records && (item["request_hex"] = bytes2hex(bytes))
                        if header.operation in (13,14)
                            item["graph"] = command.args[1]
                            item["changes"] = header.operation == 13 ? json_value(command.args[2]) :
                                Dict("parameter"=>command.args[2],"element_type"=>command.args[3],
                                    "shape"=>command.args[4],"schema"=>command.args[5],"path"=>command.args[6])
                        end
                        if header.operation == 14
                            item["artifact_id"] = nothing
                            for match in DBInterface.execute(db,"SELECT artifact_id FROM artifact_materializations WHERE path=?",(command.args[6],))
                                item["artifact_id"] = String(match.artifact_id)
                            end
                        end
                    end
                catch exception
                    unresolved = true
                    item === nothing && (item=Dict{String,Any}("key"=>key,"session_id"=>session))
                    item["outcome"] = "unknown"
                    item["error"] = sprint(showerror,exception)
                    include_records && (item["record_hex"] = bytes2hex(bytes))
                end
                item["start_sequence"] = start_sequence
                item["updated_sequence"] = sequence
                item["recorded_at"] = String(row.recorded_at)
                item["client_name"] = String(row.client_name)
                item["client_pid"] = Int(row.client_pid)
            end
            item === nothing || push!(items,item)
        end
    end
    return Dict("items"=>items,"next_before_sequence"=>isempty(items) ? nothing : items[end]["start_sequence"])
end

end
