_configuration_fields(value, required, message) = throw(ArgumentError(message))
_configuration_fields(value::AbstractDict, required, message) =
    Set(keys(value)) == required || throw(ArgumentError(message))
_configuration_name(value, message) = throw(ArgumentError(message))
_configuration_name(value::String, message) =
    occursin(r"^[a-zA-Z0-9_.-]{1,128}$", value) || throw(ArgumentError(message))
_configuration_branches(rows) = throw(ArgumentError("physical offsets require1:8branches"))
function _configuration_branches(rows::AbstractDict)
    1 <= length(rows) <= 8 || throw(ArgumentError("physical offsets require1:8branches"))
    foreach(
        name -> _configuration_name(name, "physical offsets require1:8branches"),
        keys(rows),
    )
    return nothing
end
_projection_hash(value) = throw(ArgumentError("invalid physical projection content hash"))
_projection_hash(value::String) =
    occursin(r"^[a-f0-9]{64}$", value) ||
    throw(ArgumentError("invalid physical projection content hash"))
_projection_matrix(value) = throw(ArgumentError("physical projection must be a matrix"))
_projection_matrix(value::AbstractMatrix) = value

# Shared cold artifact/branch admission; no optional graph or transport package.
function configuration(path; version = 1)
    filesize(path)<=65536 ||
        throw(ArgumentError("physical offsets configuration exceeds64KiB"))
    d=Common.read_yaml(path)
    required=Set((
        "version",
        "command_limit_m",
        "projection",
        "inverse",
        "calibration_identity",
        "command_order",
        "branches",
    ))
    version==1 && union!(
        required,
        ("parameter", "algorithm", "clock_output", "reference", "reference_sign"),
    )
    _configuration_fields(d, required, "invalid physical offsets configuration")
    d["version"]===version || throw(ArgumentError("invalid physical offsets configuration"))
    if version==1
        for key in ("parameter", "algorithm", "clock_output")
            _configuration_name(d[key], "invalid physical offsets $key")
        end
    end
    rows=d["branches"]
    _configuration_branches(rows)
    return d
end
function matrix(path, selection)
    _configuration_fields(
        selection,
        Set(("path", "sha256", "axes", "shape")),
        "physical projection requires path,sha256,axes,shape",
    )
    file=DeploymentConfiguration.relative_asset(dirname(abspath(path)), selection["path"])
    hash=selection["sha256"]
    _projection_hash(hash)
    artifact=Artifacts.FITSArtifact(file; axes = selection["axes"])
    prepared=Artifacts.prepare(artifact, Float32, selection["shape"])
    prepared.provenance["original_sha256"]==hash ||
        throw(ArgumentError("physical projection content hash mismatch"))
    return _projection_matrix(prepared.data)
end


function receiver_inputs(d, P, Q)
    names=Tuple(Symbol.(sort!(collect(keys(d["branches"])))))
    calibrations=map(names) do name
        row=d["branches"][string(name)]
        required=Set((
            "node_name",
            "schema",
            "modes",
            "command_limit_m",
            "coefficient_limit_m",
            "max_age_ns",
            "silence_ns",
        ))
        _configuration_fields(row, required, "invalid physical offset branch fields")
        _configuration_name(row["node_name"], "invalid physical offset branch node name")
        Calibration(;
            identity = d["calibration_identity"],
            schema = row["schema"],
            command_order = d["command_order"],
            projection = P,
            inverse = Q,
            modes = row["modes"],
            command_limit_m = row["command_limit_m"],
            coefficient_limit_m = row["coefficient_limit_m"],
            max_age_ns = row["max_age_ns"],
            silence_ns = row["silence_ns"],
        )
    end
    nodes=[d["branches"][string(name)]["node_name"] for name in names]
    length(unique(nodes))==length(nodes) ||
        throw(ArgumentError("physical offset branch node names collide"))
    receiver=Receiver(
        NamedTuple{names}(calibrations);
        command_limit_m = d["command_limit_m"],
    )
    buffers=map(_->zeros(Float32, size(P, 1)), names)
    total=zeros(Float32, size(P, 1))
    return (; declaration = d, receiver, names, calibrations, buffers, total)
end

# Distinct positional type keeps the HIL-only source adapter independent from
# the existing graph receiver's methods and optional graph dependencies.
struct PreparedReceiver{P}
    inputs::P
end

"Prepare a P/Q-only physical receiver bound to an independently declared source."
function prepare(
    path::AbstractString;
    command_count::Integer,
    command_order::AbstractString,
    calibration_identity::AbstractString,
)
    d=configuration(path; version = 2)
    d["command_order"]==command_order && d["calibration_identity"]==calibration_identity ||
        throw(
            ArgumentError(
                "physical receiver differs from source calibration or command order",
            ),
        )
    P, Q=matrix(path, d["projection"]), matrix(path, d["inverse"])
    size(P, 1)==command_count ||
        throw(DimensionMismatch("physical receiver differs from source command extent"))
    return PreparedReceiver(receiver_inputs(d, P, Q))
end

"Poll native branch inputs on their source owner's serialized task."
function poll! end
"Flush branch transport and receipts while the source is held."
function reset_inputs! end
