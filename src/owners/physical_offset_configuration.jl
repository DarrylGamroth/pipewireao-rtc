# Shared cold artifact/branch admission; no optional graph or transport package.
function configuration(path; version=1)
    filesize(path)<=65536 || throw(ArgumentError("physical offsets configuration exceeds64KiB"))
    d=Common.read_yaml(path)
    required=Set(("version","command_limit_m","projection","inverse","calibration_identity","command_order","branches"))
    version==1 && union!(required,("parameter","algorithm","clock_output","reference","reference_sign"))
    d isa AbstractDict && Set(keys(d))==required && d["version"]===version ||
        throw(ArgumentError("invalid physical offsets configuration"))
    if version==1
        for key in ("parameter","algorithm","clock_output")
            d[key] isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$",d[key]) ||
                throw(ArgumentError("invalid physical offsets $key"))
        end
    end
    rows=d["branches"]
    rows isa AbstractDict && 1<=length(rows)<=8 && all(name -> name isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$",name),keys(rows)) ||
        throw(ArgumentError("physical offsets require1:8branches"))
    return d
end
function matrix(path,selection)
    selection isa AbstractDict && Set(keys(selection))==Set(("path","sha256","axes","shape")) ||
        throw(ArgumentError("physical projection requires path,sha256,axes,shape"))
    file=DeploymentConfiguration.relative_asset(dirname(abspath(path)),selection["path"])
    hash=selection["sha256"]
    hash isa String && occursin(r"^[a-f0-9]{64}$",hash) ||
        throw(ArgumentError("invalid physical projection content hash"))
    artifact=Artifacts.FITSArtifact(file;axes=selection["axes"])
    prepared=Artifacts.prepare(artifact,Float32,selection["shape"])
    prepared.provenance["original_sha256"]==hash || throw(ArgumentError("physical projection content hash mismatch"))
    prepared.data isa AbstractMatrix || throw(ArgumentError("physical projection must be a matrix"))
    return prepared.data
end


function receiver_inputs(d,P,Q)
    names=Tuple(Symbol.(sort!(collect(keys(d["branches"])))))
    calibrations=map(names) do name
        row=d["branches"][string(name)]
        required=Set(("node_name","schema","modes","command_limit_m","coefficient_limit_m","max_age_ns","silence_ns"))
        row isa AbstractDict && required ⊆ Set(keys(row)) ⊆ union(required,Set(("acquisition_version",))) ||
            throw(ArgumentError("invalid physical offset branch fields"))
        row["node_name"] isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$",row["node_name"]) ||
            throw(ArgumentError("invalid physical offset branch node name"))
        version=get(row,"acquisition_version",2)
        version isa Integer && !(version isa Bool) && version in (2,3) ||
            throw(ArgumentError("physical offset acquisition_version must be 2 or 3"))
        Calibration(;identity=d["calibration_identity"],schema=row["schema"],command_order=d["command_order"],
            projection=P,inverse=Q,modes=row["modes"],command_limit_m=row["command_limit_m"],
            coefficient_limit_m=row["coefficient_limit_m"],max_age_ns=row["max_age_ns"],silence_ns=row["silence_ns"])
    end
    nodes=[d["branches"][string(name)]["node_name"] for name in names]
    length(unique(nodes))==length(nodes) || throw(ArgumentError("physical offset branch node names collide"))
    receiver=Receiver(NamedTuple{names}(calibrations);command_limit_m=d["command_limit_m"])
    buffers=map(_->zeros(Float32,size(P,1)),names)
    total=zeros(Float32,size(P,1))
    return (;declaration=d,receiver,names,calibrations,buffers,total)
end

# Distinct positional type keeps the HIL-only source adapter independent from
# the existing graph receiver's methods and optional graph dependencies.
struct PreparedReceiver{P}
    inputs::P
end

"Prepare a P/Q-only physical receiver bound to an independently declared source."
function prepare(path::AbstractString; command_count::Integer,command_order::AbstractString,
        calibration_identity::AbstractString)
    d=configuration(path;version=2)
    d["command_order"]==command_order && d["calibration_identity"]==calibration_identity ||
        throw(ArgumentError("physical receiver differs from source calibration or command order"))
    P,Q=matrix(path,d["projection"]),matrix(path,d["inverse"])
    size(P,1)==command_count || throw(DimensionMismatch("physical receiver differs from source command extent"))
    return PreparedReceiver(receiver_inputs(d,P,Q))
end

"Poll native branch inputs on their source owner's serialized task."
function poll! end
"Flush branch transport and receipts while the source is held."
function reset_inputs! end
