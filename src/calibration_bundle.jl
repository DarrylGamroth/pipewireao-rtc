# Included inside InstrumentCalibration. This contract checks bytes and metadata;
# scientific owners remain responsible for array shapes and optical semantics.

const _BUNDLE_INTEGRITY_FIELDS = ("version", "context_sha256", "graph_sha256",
    "artifact_sha256", "parameter_names", "parameter_files")

function _bundle_name(value; artifact=false)
    value isa AbstractString && occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", value) ||
        throw(ArgumentError("calibration artifact names must be plain filenames"))
    artifact && !endswith(value, ".fits") &&
        throw(ArgumentError("calibration artifacts must have a .fits extension"))
    return String(value)
end

function _bundle_file(directory, name; maximum=Artifacts.MAX_FITS_BYTES)
    path = joinpath(directory, name)
    isfile(path) && !islink(path) && filesize(path) <= maximum ||
        throw(ArgumentError("calibration bundle file is missing, linked or too large: $name"))
    return DeploymentConfiguration.relative_asset(directory, name)
end

function _bundle_hash(value, label)
    value isa AbstractString && occursin(r"^[0-9a-f]{64}$", value) ||
        throw(ArgumentError("invalid calibration $label SHA-256"))
    return value
end

function _bundle_report(report)
    report isa AbstractDict && all(key -> key isa String, keys(report)) ||
        throw(ArgumentError("calibration result must be a mapping with string keys"))
    for key in ("recipe", "source_prescription_identity", "source_graph_sha256")
        haskey(report, key) || throw(ArgumentError("calibration result is missing $key"))
    end
    report["recipe"] isa AbstractDict || throw(ArgumentError("calibration recipe must be a mapping"))
    identity = report["source_prescription_identity"]
    identity isa AbstractString && !isempty(strip(identity)) ||
        throw(ArgumentError("calibration source prescription identity must be nonempty text"))
    _bundle_hash(report["source_graph_sha256"], "source graph")
    return report
end

"""
    read_bundle(directory)

Validate a version-1 calibration bundle without loading scientific packages.
Return the report, parsed context, graph path, artifact paths keyed by FITS
basename, and runtime parameter names. Every file is hashed before return;
array interpretation belongs to the caller.
"""
function read_bundle(directory::AbstractString)
    isdir(directory) && !islink(directory) ||
        throw(ArgumentError("calibration bundle must be a non-symlink directory"))
    entries = Set(readdir(directory))
    required = Set(("result.yaml", "context.yaml", "graph.conf", "artifacts"))
    allowed = union(required, Set(("recipe.yaml", "recipe.conf", "inputs", "history", "README.md")))
    issubset(required, entries) && issubset(entries, allowed) ||
        throw(ArgumentError("calibration bundle contains missing or unknown files"))
    for name in entries
        path = joinpath(directory, name)
        islink(path) && throw(ArgumentError("calibration bundle contains a symlink: $name"))
        if name in ("artifacts", "inputs", "history")
            isdir(path) || throw(ArgumentError("calibration bundle $name must be a directory"))
        else
            isfile(path) || throw(ArgumentError("calibration bundle $name must be a regular file"))
        end
    end
    report = _bundle_report(Common.read_yaml(_bundle_file(directory, "result.yaml"; maximum=1024^2)))
    get(report, "version", nothing) isa Integer && !(report["version"] isa Bool) && report["version"] == 1 ||
        throw(ArgumentError("calibration bundle requires version 1"))
    for key in _BUNDLE_INTEGRITY_FIELDS
        haskey(report, key) || throw(ArgumentError("calibration result is missing $key"))
    end
    context_path = _bundle_file(directory, "context.yaml"; maximum=1024^2)
    graph = _bundle_file(directory, "graph.conf"; maximum=16 * 1024^2)
    for (key, path) in (("context_sha256", context_path), ("graph_sha256", graph))
        Common.sha256_file(path) == _bundle_hash(report[key], key) ||
            throw(ArgumentError("calibration bundle $key mismatch"))
    end
    context = Common.read_yaml(context_path)
    context isa AbstractDict || throw(ArgumentError("calibration context must be a mapping"))
    artifact_directory = joinpath(directory, "artifacts")
    isdir(artifact_directory) && !islink(artifact_directory) ||
        throw(ArgumentError("calibration artifacts must be a non-symlink directory"))
    manifest = report["artifact_sha256"]
    manifest isa AbstractDict || throw(ArgumentError("calibration artifact_sha256 must be a mapping"))
    for name in keys(manifest)
        _bundle_name(name; artifact=true)
    end
    Set(readdir(artifact_directory)) == Set(keys(manifest)) ||
        throw(ArgumentError("calibration artifact manifest does not exactly cover artifact files"))
    artifacts = Dict{String,String}()
    for (name, expected) in manifest
        path = _bundle_file(artifact_directory, name)
        # Reuse the bounded no-follow FITS snapshot reader, including inode checks.
        bytes = Artifacts.snapshot(path; check=()->nothing)
        bytes2hex(sha256(bytes)) == _bundle_hash(expected, "artifact $name") ||
            throw(ArgumentError("calibration artifact hash mismatch: $name"))
        artifacts[name] = path
    end
    if haskey(report, "history_sha256")
        history = report["history_sha256"]
        history isa AbstractDict || throw(ArgumentError("calibration history_sha256 must be a mapping"))
        for (name, expected) in history
            name isa AbstractString || throw(ArgumentError("calibration history path must be text"))
            components = split(name, '/'; keepempty=true)
            length(components) >= 2 && first(components) == "history" ||
                throw(ArgumentError("calibration history path must be relative to history/"))
            path = String(directory)
            for component in components
                _bundle_name(component)
                path = joinpath(path, component)
                islink(path) && throw(ArgumentError("calibration history path contains a symlink"))
            end
            path = _bundle_file(directory, String(name))
            Common.sha256_file(path) == _bundle_hash(expected, "history $name") ||
                throw(ArgumentError("calibration history hash mismatch: $name"))
        end
    end
    parameter_names = report["parameter_names"]
    parameter_names isa AbstractVector && all(name -> name isa AbstractString, parameter_names) ||
        throw(ArgumentError("calibration parameter_names must be a list of names"))
    length(unique(parameter_names)) == length(parameter_names) ||
        throw(ArgumentError("calibration parameter_names contains duplicates"))
    parameter_files=report["parameter_files"]
    parameter_files isa AbstractDict && Set(keys(parameter_files))==Set(parameter_names) ||
        throw(ArgumentError("calibration parameter_files must cover exactly the runtime parameters"))
    for name in parameter_names
        _bundle_name(name)
        filename=_bundle_name(parameter_files[name];artifact=true)
        haskey(artifacts, filename) ||
            throw(ArgumentError("calibration parameter has no artifact: $name"))
    end
    return (; report, context, graph, artifacts, parameter_names=String.(parameter_names),
        parameter_files=Dict{String,String}(parameter_files))
end

"""
    write_bundle(directory, report, context, concrete_graph, parameters; diagnostics=Dict())

Publish a fresh version-1 calibration bundle by renaming a complete sibling
staging directory. Parameters and diagnostics map port/artifact stems to arrays;
only parameters are listed in parameter_names. Generated integrity fields cannot
be supplied in report. Return the generated report.
"""
function write_bundle(directory::AbstractString, report, context, concrete_graph, parameters;
        diagnostics=Dict())
    _bundle_report(report)
    any(key -> haskey(report, key), _BUNDLE_INTEGRITY_FIELDS) &&
        throw(ArgumentError("calibration report must not supply generated integrity fields"))
    context isa AbstractDict || throw(ArgumentError("calibration context must be a mapping"))
    parameters isa AbstractDict && diagnostics isa AbstractDict ||
        throw(ArgumentError("calibration parameters and diagnostics must be mappings"))
    arrays = Dict{String,Any}()
    parameter_names = String[]
    for (values, runtime) in ((parameters, true), (diagnostics, false))
        for (key, array) in values
            key isa Union{Symbol,AbstractString} || throw(ArgumentError("invalid calibration artifact name"))
            name = _bundle_name(String(key))
            haskey(arrays, name) && throw(ArgumentError("duplicate calibration artifact name: $name"))
            array isa AbstractArray || throw(ArgumentError("calibration artifact $name must be an array"))
            arrays[name] = array
            runtime && push!(parameter_names, name)
        end
    end
    target = abspath(directory)
    !ispath(target) && !islink(target) || throw(ArgumentError("calibration output must be fresh: $target"))
    mkpath(dirname(target))
    temporary = mktempdir(dirname(target); prefix=".calibration-")
    try
        mkdir(joinpath(temporary, "artifacts"))
        Common.write_yaml(joinpath(temporary, "context.yaml"), context)
        ScienceExport.write_spa_config(joinpath(temporary, "graph.conf"), concrete_graph)
        hashes = Dict{String,String}()
        for name in sort!(collect(keys(arrays)))
            path = joinpath(temporary, "artifacts", name * ".fits")
            write_fits(path, arrays[name])
            hashes[name * ".fits"] = Common.sha256_file(path)
        end
        result = Dict{String,Any}(report)
        result["version"] = 1
        result["parameter_names"] = sort!(parameter_names)
        result["parameter_files"] = Dict(name=>name*".fits" for name in parameter_names)
        result["context_sha256"] = Common.sha256_file(joinpath(temporary, "context.yaml"))
        result["graph_sha256"] = Common.sha256_file(joinpath(temporary, "graph.conf"))
        result["artifact_sha256"] = hashes
        Common.write_yaml(joinpath(temporary, "result.yaml"), result)
        read_bundle(temporary)
        # force=false preserves an output created concurrently while staging.
        mv(temporary, target; force=false)
        return result
    finally
        isdir(temporary) && rm(temporary; recursive=true)
    end
end
