"""Headless, content-addressed configuration artifacts and SQLite catalog."""
module ConfigurationStore

using SQLite, DBInterface, JSON, SHA, FITSIO
using ..Artifacts

export Store,
    default_root, register!, list_artifacts, get_artifact, read_artifact, materialize!

const PROTOCOL = "pipewireao.configuration/1"
const MAX_MANIFEST_BYTES = 1024 * 1024

"""
    default_root()

Return the shared per-user configuration store location without opening it.
"""
function default_root()
    state_home = get(ENV, "XDG_STATE_HOME", "")
    isabspath(state_home) || (state_home = joinpath(homedir(), ".local", "state"))
    return joinpath(state_home, "pipewireao", "configuration")
end

"A headless Git artifact repository and SQLite catalog under one root."
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
    return addenv(
        command,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_CONFIG_COUNT" => "0",
        "GIT_ATTR_NOSYSTEM" => "1",
        "GIT_AUTHOR_NAME" => "PipeWireAO configuration",
        "GIT_AUTHOR_EMAIL" => "configuration@localhost",
        "GIT_COMMITTER_NAME" => "PipeWireAO configuration",
        "GIT_COMMITTER_EMAIL" => "configuration@localhost",
        "GIT_AUTHOR_DATE" => "@0 +0000",
        "GIT_COMMITTER_DATE" => "@0 +0000",
        "GIT_DIR" => nothing,
        "GIT_WORK_TREE" => nothing,
        "GIT_COMMON_DIR" => nothing,
        "GIT_OBJECT_DIRECTORY" => nothing,
        "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nothing,
        "GIT_NAMESPACE" => nothing,
        "GIT_CONFIG_PARAMETERS" => nothing,
    )
end
function git_read(repository, arguments...; input = nothing)
    command = git_command(repository, arguments...)
    return input === nothing ? read(command) :
           read(pipeline(command; stdin = IOBuffer(input)))
end
git_text(repository, arguments...; kwargs...) =
    strip(String(git_read(repository, arguments...; kwargs...)))

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

function Store(root::AbstractString = default_root())
    root = abspath(bounded_name(root, "root"))
    mkpath(root; mode = 0o700)
    repository = joinpath(root, "artifacts.git")
    format = locked(root) do
        if !isdir(repository)
            git_read(repository, "init", "--bare", "--quiet", repository)
        end
        git_text(repository, "rev-parse", "--is-bare-repository") == "true" ||
            throw(ArgumentError("artifact repository must be bare"))
        format = git_text(repository, "rev-parse", "--show-object-format")
        format in ("sha1", "sha256") ||
            throw(ArgumentError("unsupported Git object format"))
        store = Store(root, repository, joinpath(root, "history.sqlite3"), format)
        database(store) do db
            DBInterface.execute(db, "PRAGMA journal_mode=WAL")
            DBInterface.execute(
                db,
                "CREATE TABLE IF NOT EXISTS configuration_schema(version INTEGER NOT NULL)",
            )
            versions = [
                Int(row.version) for
                row in DBInterface.execute(db, "SELECT version FROM configuration_schema")
            ]
            isempty(versions) &&
                DBInterface.execute(db, "INSERT INTO configuration_schema VALUES(1)")
            isempty(versions) ||
                versions == [1] ||
                throw(ArgumentError("unsupported configuration schema"))
            DBInterface.execute(
                db,
                """CREATE TABLE IF NOT EXISTS artifacts(
sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,
content_oid TEXT NOT NULL,commit_oid TEXT NOT NULL,object_format TEXT NOT NULL,
manifest TEXT NOT NULL,
recorded_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')))""",
            )
            DBInterface.execute(
                db,
                """CREATE TABLE IF NOT EXISTS artifact_materializations(
path TEXT PRIMARY KEY,artifact_id TEXT NOT NULL,storage_order TEXT NOT NULL,sha256 TEXT NOT NULL)""",
            )
        end
        chmod(store.database, 0o600)
        return format
    end
    return Store(root, repository, joinpath(root, "history.sqlite3"), format)
end

checked_oid(store, oid) = throw(ArgumentError("expected a full Git object ID"))
function checked_oid(store, oid::AbstractString)
    length(oid) == (store.object_format == "sha1" ? 40 : 64) &&
    all(c -> c in '0':'9' || c in 'a':'f', oid) ||
        throw(ArgumentError("expected a full Git object ID"))
    return String(oid)
end
blob_oid(store, bytes; write = false) = git_text(
    store.repository,
    "hash-object",
    "--no-filters",
    (write ? ["-w"] : String[])...,
    "--stdin";
    input = bytes,
)
function read_blob(store, oid; limit = Artifacts.MAX_FITS_BYTES)
    oid = checked_oid(store, oid)
    size = parse(Int, git_text(store.repository, "cat-file", "-s", oid))
    0 <= size <= limit || throw(ArgumentError("Git object exceeds byte limit"))
    bytes = git_read(store.repository, "cat-file", "blob", oid)
    length(bytes) == size && blob_oid(store, bytes) == oid ||
        throw(ArgumentError("Git object integrity failure"))
    return bytes
end

# JSON identity is independent of dictionary iteration order, including nested metadata.
function canonical_json(value::AbstractDict)
    foreach(metadata_key, keys(value))
    names = sort!(String.(collect(keys(value))))
    return "{" *
           join(
               (
                   String(JSON.json(name)) * ":" * canonical_json(value[name]) for
                   name in names
               ),
               ",",
           ) *
           "}"
end
metadata_key(key::AbstractString) = nothing
metadata_key(key) = throw(ArgumentError("metadata keys must be strings"))
canonical_json(value::Union{AbstractVector,Tuple}) =
    "[" * join(canonical_json.(value), ",") * "]"
canonical_json(value::Union{AbstractString,Bool,Integer,Nothing}) = String(JSON.json(value))
function canonical_json(value::AbstractFloat)
    isfinite(value) || throw(ArgumentError("metadata numbers must be finite"))
    return String(JSON.json(value))
end
canonical_json(value) = throw(ArgumentError("metadata must contain JSON values"))

bounded_name(value, field; empty = false) = throw(ArgumentError("invalid $field"))
function bounded_name(value::AbstractString, field; empty = false)
    (empty || !isempty(value)) &&
    ncodeunits(value) <= 4096 &&
    isvalid(value) &&
    !occursin('\0', value) || throw(ArgumentError("invalid $field"))
    return String(value)
end

artifact_scope(scope::AbstractDict) = JSON.parse(canonical_json(scope), Dict{String,Any})
artifact_scope(scope) = bounded_name(scope, "scope")
checked_metadata(metadata::AbstractDict) = metadata
checked_metadata(metadata) = throw(ArgumentError("metadata must be a JSON object"))

"""
    register!(store, source, ::Type{T}, shape; label, scope, metadata=Dict{String, Any}(), schema="")

Capture and validate the original FITS once, then pin Git objects before indexing them.
"""
function register!(
    store::Store,
    source::Artifacts.FITSArtifact,
    ::Type{T},
    shape;
    label,
    scope,
    metadata = Dict{String,Any}(),
    schema = "",
) where {T}
    label = bounded_name(label, "label")
    scope = artifact_scope(scope)
    schema = bounded_name(schema, "schema"; empty = true)
    checked_metadata(metadata)
    T in Artifacts.TARGET_TYPES || throw(ArgumentError("unsupported target type"))
    Artifacts.checked_shape(shape, sizeof(T))
    original = Artifacts.snapshot(source.path; check = () -> nothing)
    prepared = Artifacts.prepare_snapshot(source, T, shape, original)
    provenance = copy(prepared.provenance)
    delete!(provenance, "source")
    # Validate metadata before importing any Git objects.
    canonical_json(metadata)
    return locked(store.root) do
        content = blob_oid(store, original)
        manifest = Dict(
            "protocol" => PROTOCOL,
            "content_oid" => content,
            "object_format" => store.object_format,
            "label" => label,
            "scope" => scope,
            "schema" => schema,
            "metadata" => metadata,
            "preparation" => provenance,
        )
        text = canonical_json(manifest)
        ncodeunits(text) <= MAX_MANIFEST_BYTES ||
            throw(ArgumentError("manifest exceeds 1 MiB"))
        blob_oid(store, original; write = true) == content ||
            error("Git content identity mismatch")
        id = blob_oid(store, codeunits(text); write = true)
        tree = git_text(
            store.repository,
            "mktree";
            input = codeunits(
                "100644 blob $content\toriginal.fits\n100644 blob $id\tmanifest.json\n"
            ),
        )
        commit = git_text(
            store.repository,
            "commit-tree",
            tree;
            input = codeunits("Configuration artifact $id\n"),
        )
        ref = "refs/artifacts/$id"
        existing = git_text(store.repository, "for-each-ref", "--format=%(objectname)", ref)
        if isempty(existing)
            git_read(store.repository, "update-ref", ref, commit, repeat("0", length(id)))
        else
            existing == commit || throw(ArgumentError("immutable artifact ref differs"))
        end
        database(store) do db
            DBInterface.execute(
                db,
                "INSERT OR IGNORE INTO artifacts(id,content_oid,commit_oid,object_format,manifest) VALUES(?,?,?,?,?)",
                (id, content, commit, store.object_format, text),
            )
        end
        return get_artifact(store, id)
    end
end

fits_units(::Nothing) = nothing
fits_units(units) = throw(
    ArgumentError(
        "generated FITS units must fit one 68-character ASCII string card without surrounding whitespace",
    ),
)
function fits_units(units::AbstractString)
    isvalid(units) &&
    !isempty(units) &&
    ncodeunits(units) + count(==('\''), units) <= 68 &&
    strip(units) == units &&
    all(c -> isascii(c) && !iscntrl(c), units) || throw(
        ArgumentError(
            "generated FITS units must fit one 68-character ASCII string card without surrounding whitespace",
        ),
    )
    return String(units)
end

"""
    register!(store, data; label, scope, metadata=Dict{String, Any}(), schema="", units=nothing)

Register generated host arrays through the same FITS preparation contract.

Optional `units` writes the FITS BUNIT card, retained in the prepared artifact
contract. Units are declared, not converted or inferred from a schema.
"""
function register!(
    store::Store,
    data::Array{T};
    label,
    scope,
    metadata = Dict{String,Any}(),
    schema = "",
    units = nothing,
) where {T}
    T in Artifacts.TARGET_TYPES || throw(ArgumentError("unsupported target type"))
    Artifacts.checked_shape(size(data), sizeof(T))
    units = fits_units(units)
    mktempdir() do directory
        path = joinpath(directory, "generated.fits")
        FITS(path, "w") do fits
            header = FITSHeader(
                ["ORIGIN", "COMMENT"],
                Any["PipeWireAORTC", nothing],
                ["", "Generated by PipeWireAORTC from a host array."],
            )
            write(fits, T === Bool ? UInt8.(data) : data; header)
            if units !== nothing
                write_key(fits[1], "BUNIT", units)
                read_header(fits[1])["BUNIT"] == units || throw(
                    ArgumentError(
                        "generated FITS BUNIT did not preserve the declared units exactly",
                    ),
                )
            end
        end
        return register!(
            store,
            Artifacts.FITSArtifact(path; axes = Tuple(1:ndims(data))),
            T,
            size(data);
            label,
            scope,
            metadata,
            schema,
        )
    end
end

function row_record(store, row; verify = true)
    text = String(row.manifest)
    if verify
        String(read_blob(store, String(row.id); limit = MAX_MANIFEST_BYTES)) == text ||
            throw(ArgumentError("catalog manifest differs from Git"))
    end
    manifest = JSON.parse(text, Dict{String,Any})
    manifest["content_oid"] == String(row.content_oid) &&
    manifest["object_format"] == store.object_format ||
        throw(ArgumentError("catalog manifest identity mismatch"))
    checked_oid(store, String(row.content_oid))
    checked_oid(store, String(row.commit_oid))
    return Dict(
        "id" => String(row.id),
        "content_oid" => String(row.content_oid),
        "commit_oid" => String(row.commit_oid),
        "object_format" => String(row.object_format),
        "sequence" => Int(row.sequence),
        "recorded_at" => String(row.recorded_at),
        "manifest" => manifest,
    )
end
page_limit(limit) = throw(ArgumentError("limit must be in 1:100"))
page_limit(limit::Bool) = page_limit(nothing)
function page_limit(limit::Integer)
    1 <= limit <= 100 || throw(ArgumentError("limit must be in 1:100"))
    return Int(limit)
end
"""
    get_artifact(store, id)

Return catalog metadata after verifying the pinned Git manifest, tree and original bytes.
"""
function get_artifact(store::Store, id::AbstractString)
    id = checked_oid(store, id)
    record = database(store) do db
        for row in DBInterface.execute(db, "SELECT * FROM artifacts WHERE id=?", (id,))
            return row_record(store, row)
        end
        throw(KeyError(id))
    end
    manifest = record["manifest"]
    manifest["content_oid"] == record["content_oid"] &&
    manifest["object_format"] == store.object_format ||
        throw(ArgumentError("catalog identity mismatch"))
    commit = checked_oid(store, record["commit_oid"])
    pinned = git_text(
        store.repository, "for-each-ref", "--format=%(objectname)", "refs/artifacts/$id"
    )
    pinned == commit || throw(ArgumentError("artifact Git commit is not pinned"))
    tree = git_text(store.repository, "ls-tree", commit)
    expected = "100644 blob $(record["id"])\tmanifest.json\n100644 blob $(record["content_oid"])\toriginal.fits"
    tree == expected || throw(ArgumentError("artifact Git tree differs from catalog"))
    read_blob(store, record["content_oid"])
    return record
end
"""
    read_artifact(store, id)

Read and verify the exact original FITS bytes by immutable catalog identity.
"""
read_artifact(store::Store, id::AbstractString) =
    read_blob(store, get_artifact(store, id)["content_oid"])
"""
    materialize!(store, id; storage_order="row-major")

Publish verified read-only transport cache bytes and retain them until explicit maintenance.
"""
function materialize!(store::Store, id::AbstractString; storage_order = "row-major")
    storage_order in ("row-major", "column-major") ||
        throw(ArgumentError("unsupported storage order"))
    record = get_artifact(store, id)
    preparation = record["manifest"]["preparation"]
    T = only(filter(T -> string(T) == preparation["target_type"], Artifacts.TARGET_TYPES))
    original = read_artifact(store, id)
    source = Artifacts.FITSArtifact(
        "catalog-snapshot"; hdu = preparation["hdu"], axes = preparation["axes"]
    )
    prepared = Artifacts.prepare_snapshot(source, T, preparation["target_shape"], original)
    bytes = if storage_order == "row-major"
        Artifacts.pack(prepared)
    else
        output = Vector{UInt8}(undef, length(prepared.data) * sizeof(T))
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
        directory = joinpath(store.root, "materialized", id)
        mkpath(joinpath(store.root, "materialized"); mode = 0o700)
        cache = joinpath(store.root, "materialized")
        cache_bytes = 0
        cache_files = 0
        for (base, _, files) in walkdir(cache)
            for name in files
                entry = joinpath(base, name)
                islink(entry) &&
                    throw(ArgumentError("materialization cache contains a symlink"))
                cache_bytes += filesize(entry)
                cache_files += 1
            end
        end
        original_missing = !isfile(joinpath(directory, "original.fits"))
        prepared_missing = !isfile(joinpath(directory, storage_order * ".bin"))
        addition =
            (original_missing ? length(original) : 0) +
            (prepared_missing ? length(bytes) : 0)
        additional_files = Int(original_missing) + Int(prepared_missing)
        cache_bytes + addition <= 1024^3 && cache_files + additional_files <= 1024 || throw(
            ArgumentError(
                "materialization cache capacity exceeded; explicit maintenance required"
            ),
        )
        mkpath(directory; mode = 0o700)
        function retain(name, content)
            retained_path = joinpath(directory, name)
            if ispath(retained_path)
                isfile(retained_path) &&
                !islink(retained_path) &&
                filesize(retained_path) == length(content) &&
                read(retained_path) == content ||
                    throw(ArgumentError("materialized artifact integrity failure"))
            else
                temporary, io = mktemp(directory)
                try
                    write(io, content)
                    flush(io)
                    ccall(:fsync, Cint, (Cint,), fd(io)) == 0 || systemerror("fsync", true)
                    close(io)
                    chmod(temporary, 0o400)
                    mv(temporary, retained_path)
                    open(directory) do directory_io
                        ccall(:fsync, Cint, (Cint,), fd(directory_io)) == 0 ||
                            systemerror("fsync", true)
                    end
                finally
                    isopen(io) && close(io)
                    ispath(temporary) && rm(temporary)
                end
            end
            return retained_path
        end
        path = retain("original.fits", original)
        prepared_path = retain(storage_order * ".bin", bytes)
        database(store) do db
            DBInterface.execute(
                db,
                "INSERT OR IGNORE INTO artifact_materializations(path,artifact_id,storage_order,sha256) VALUES(?,?,?,?)",
                (prepared_path, id, storage_order, digest),
            )
        end
        merge!(
            record,
            Dict(
                "path" => path,
                "prepared_path" => prepared_path,
                "storage_order" => storage_order,
                "sha256" => digest,
                "target_type" => string(T),
                "shape" => preparation["target_shape"],
                "schema" => record["manifest"]["schema"],
            ),
        )
        return record
    end
end

artifact_cursor(value) = throw(ArgumentError("invalid cursor"))
artifact_cursor(value::Integer) = value >= 0 ? value : artifact_cursor(nothing)

"""
    list_artifacts(store; limit=50, after_sequence=0)

List a bounded page in registration order, using an exclusive sequence cursor.
"""
function list_artifacts(store::Store; limit = 50, after_sequence = 0)
    limit = page_limit(limit)
    after_sequence = artifact_cursor(after_sequence)
    items = database(store) do db
        items = Dict{String,Any}[]
        total = 0
        for row in DBInterface.execute(
            db,
            "SELECT * FROM artifacts WHERE sequence>? ORDER BY sequence LIMIT ?",
            (after_sequence, limit),
        )
            # At most four MiB of canonical manifests per catalog page.
            bytes = ncodeunits(row.manifest)
            total + bytes > 4 * MAX_MANIFEST_BYTES && !isempty(items) && break
            push!(items, row_record(store, row))
            total += bytes
        end
        items
    end
    return Dict(
        "items" => items,
        "next_after_sequence" => isempty(items) ? nothing : items[end]["sequence"],
    )
end


end
