# Included inside InstrumentCalibration. This contract checks bytes and metadata;
# scientific owners remain responsible for array shapes and optical semantics.

const _BUNDLE_INTEGRITY_FIELDS = (
    "version",
    "context_sha256",
    "graph_sha256",
    "artifact_sha256",
    "parameter_names",
    "parameter_files",
)

_bundle_name(value; artifact = false) =
    throw(ArgumentError("calibration artifact names must be plain filenames"))
function _bundle_name(value::AbstractString; artifact = false)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", value) ||
        throw(ArgumentError("calibration artifact names must be plain filenames"))
    artifact &&
        !endswith(value, ".fits") &&
        throw(ArgumentError("calibration artifacts must have a .fits extension"))
    return String(value)
end

function _bundle_file(directory, name; maximum = Artifacts.MAX_FITS_BYTES)
    path = joinpath(directory, name)
    isfile(path) && !islink(path) && filesize(path) <= maximum || throw(
        ArgumentError("calibration bundle file is missing, linked or too large: $name"),
    )
    return DeploymentConfiguration.relative_asset(directory, name)
end

_bundle_hash(value, label) = throw(ArgumentError("invalid calibration $label SHA-256"))
function _bundle_hash(value::AbstractString, label)
    occursin(r"^[0-9a-f]{64}$", value) ||
        throw(ArgumentError("invalid calibration $label SHA-256"))
    return value
end

_bundle_report(report) =
    throw(ArgumentError("calibration result must be a mapping with string keys"))
function _bundle_report(report::AbstractDict)
    foreach(_bundle_report_key, keys(report))
    haskey(report, "history_sha256") &&
        throw(ArgumentError("calibration history belongs in Git, not the bundle"))
    for key in ("recipe", "source_prescription_identity", "source_graph_sha256")
        haskey(report, key) || throw(ArgumentError("calibration result is missing $key"))
    end
    _bundle_mapping(report["recipe"], "recipe")
    identity = report["source_prescription_identity"]
    _bundle_identity(identity)
    _bundle_hash(report["source_graph_sha256"], "source graph")
    return report
end

_bundle_report_key(key) =
    throw(ArgumentError("calibration result must be a mapping with string keys"))
_bundle_report_key(::String) = nothing
_bundle_mapping(value, label) = throw(ArgumentError("calibration $label must be a mapping"))
_bundle_mapping(value::AbstractDict, label) = value
_bundle_identity(value) =
    throw(ArgumentError("calibration source prescription identity must be nonempty text"))
_bundle_identity(value::AbstractString) =
    !isempty(strip(value)) ||
    throw(ArgumentError("calibration source prescription identity must be nonempty text"))
_bundle_version(value) = throw(ArgumentError("calibration bundle requires version 1"))
_bundle_version(value::Bool) = throw(ArgumentError("calibration bundle requires version 1"))
_bundle_version(value::Integer) =
    value == 1 || throw(ArgumentError("calibration bundle requires version 1"))
_bundle_parameter_names(value) =
    throw(ArgumentError("calibration parameter_names must be a list of names"))
_bundle_parameter_names(value::AbstractVector) = foreach(_bundle_parameter_name, value)
_bundle_parameter_name(value) =
    throw(ArgumentError("calibration parameter_names must be a list of names"))
_bundle_parameter_name(::AbstractString) = nothing
_bundle_parameter_files(files, names) = throw(
    ArgumentError("calibration parameter_files must cover exactly the runtime parameters"),
)
_bundle_parameter_files(files::AbstractDict, names) =
    Set(keys(files)) == Set(names) || throw(
        ArgumentError(
            "calibration parameter_files must cover exactly the runtime parameters",
        ),
    )
_bundle_artifact_mappings(parameters, diagnostics) =
    throw(ArgumentError("calibration parameters and diagnostics must be mappings"))
_bundle_artifact_mappings(::AbstractDict, ::AbstractDict) = nothing
_bundle_artifact_name(key) = throw(ArgumentError("invalid calibration artifact name"))
_bundle_artifact_name(key::Union{Symbol,AbstractString}) = _bundle_name(String(key))
_bundle_array(array, name) =
    throw(ArgumentError("calibration artifact $name must be an array"))
_bundle_array(::AbstractArray, name) = nothing

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
    allowed = union(required, Set(("recipe.yaml", "recipe.conf", "inputs", "README.md")))
    issubset(required, entries) && issubset(entries, allowed) ||
        throw(ArgumentError("calibration bundle contains missing or unknown files"))
    for name in entries
        path = joinpath(directory, name)
        islink(path) && throw(ArgumentError("calibration bundle contains a symlink: $name"))
        if name in ("artifacts", "inputs")
            isdir(path) ||
                throw(ArgumentError("calibration bundle $name must be a directory"))
        else
            isfile(path) ||
                throw(ArgumentError("calibration bundle $name must be a regular file"))
        end
    end
    report = _bundle_report(
        Common.read_yaml(_bundle_file(directory, "result.yaml"; maximum = 1024^2)),
    )
    _bundle_version(get(report, "version", nothing))
    for key in _BUNDLE_INTEGRITY_FIELDS
        haskey(report, key) || throw(ArgumentError("calibration result is missing $key"))
    end
    context_path = _bundle_file(directory, "context.yaml"; maximum = 1024^2)
    graph = _bundle_file(directory, "graph.conf"; maximum = 16 * 1024^2)
    for (key, path) in (("context_sha256", context_path), ("graph_sha256", graph))
        Common.sha256_file(path) == _bundle_hash(report[key], key) ||
            throw(ArgumentError("calibration bundle $key mismatch"))
    end
    context = Common.read_yaml(context_path)
    _bundle_mapping(context, "context")
    artifact_directory = joinpath(directory, "artifacts")
    isdir(artifact_directory) && !islink(artifact_directory) ||
        throw(ArgumentError("calibration artifacts must be a non-symlink directory"))
    manifest = report["artifact_sha256"]
    _bundle_mapping(manifest, "artifact_sha256")
    for name in keys(manifest)
        _bundle_name(name; artifact = true)
    end
    Set(readdir(artifact_directory)) == Set(keys(manifest)) || throw(
        ArgumentError(
            "calibration artifact manifest does not exactly cover artifact files",
        ),
    )
    artifacts = Dict{String,String}()
    for (name, expected) in manifest
        path = _bundle_file(artifact_directory, name)
        # Reuse the bounded no-follow FITS snapshot reader, including inode checks.
        bytes = Artifacts.snapshot(path; check = ()->nothing)
        bytes2hex(sha256(bytes)) == _bundle_hash(expected, "artifact $name") ||
            throw(ArgumentError("calibration artifact hash mismatch: $name"))
        artifacts[name] = path
    end
    # Construction-time values use the same bounded, hash-verified FITS inputs
    # as cold RTC preparation; the stored context remains a small declaration.
    InstrumentConfiguration.calibration_context(context, directory)
    parameter_names = report["parameter_names"]
    _bundle_parameter_names(parameter_names)
    length(unique(parameter_names)) == length(parameter_names) ||
        throw(ArgumentError("calibration parameter_names contains duplicates"))
    parameter_files=report["parameter_files"]
    _bundle_parameter_files(parameter_files, parameter_names)
    for name in parameter_names
        _bundle_name(name)
        filename=_bundle_name(parameter_files[name]; artifact = true)
        haskey(artifacts, filename) ||
            throw(ArgumentError("calibration parameter has no artifact: $name"))
    end
    return (;
        report,
        context,
        graph,
        artifacts,
        parameter_names = String.(parameter_names),
        parameter_files = Dict{String,String}(parameter_files),
    )
end

"""
    write_bundle(directory, report, context, concrete_graph, parameters; diagnostics=Dict())

Publish a fresh version-1 calibration bundle by renaming a complete sibling
staging directory. Parameters and diagnostics map port/artifact stems to arrays;
only parameters are listed in parameter_names. Generated integrity fields cannot
be supplied in report. Return the generated report.
"""
function write_bundle(
    directory::AbstractString,
    report,
    context,
    concrete_graph,
    parameters;
    diagnostics = Dict(),
    artifact_units = Dict(),
)
    _bundle_report(report)
    any(key -> haskey(report, key), _BUNDLE_INTEGRITY_FIELDS) && throw(
        ArgumentError("calibration report must not supply generated integrity fields"),
    )
    _bundle_mapping(context, "context")
    _bundle_artifact_mappings(parameters, diagnostics)
    arrays = Dict{String,Any}()
    parameter_names = String[]
    for (values, runtime) in ((parameters, true), (diagnostics, false))
        for (key, array) in values
            name = _bundle_artifact_name(key)
            haskey(arrays, name) &&
                throw(ArgumentError("duplicate calibration artifact name: $name"))
            _bundle_array(array, name)
            arrays[name] = array
            runtime && push!(parameter_names, name)
        end
    end
    target = abspath(directory)
    !ispath(target) && !islink(target) ||
        throw(ArgumentError("calibration output must be fresh: $target"))
    mkpath(dirname(target))
    temporary = mktempdir(dirname(target); prefix = ".calibration-")
    try
        mkdir(joinpath(temporary, "artifacts"))
        Common.write_yaml(joinpath(temporary, "context.yaml"), context)
        ScienceExport.write_spa_config(joinpath(temporary, "graph.conf"), concrete_graph)
        hashes = Dict{String,String}()
        for name in sort!(collect(keys(arrays)))
            path = joinpath(temporary, "artifacts", name * ".fits")
            write_fits(path, arrays[name]; units = get(artifact_units, name, nothing))
            hashes[name*".fits"] = Common.sha256_file(path)
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
        mv(temporary, target; force = false)
        return result
    finally
        isdir(temporary) && rm(temporary; recursive = true)
    end
end
