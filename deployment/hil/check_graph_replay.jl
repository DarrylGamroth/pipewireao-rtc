#!/usr/bin/env julia
"""
Replay a completed simulator prefix through the installed ordinary JFG graph.

    JULIA_LOAD_PATH="@:/path/to/sdk:@stdlib" julia --startup-file=no \
        --project=PACKAGE/jfg/deployment check_graph_replay.jl \
        --package PACKAGE --report simulator-result.json --output NEW_DIRECTORY

The SDK supplies JSON and SPA-JSON decoding; no Python is used. Execution does
not start a simulator, PipeWire owner or device. Results characterize numerical
differences and ordinary public process! allocations, without an acceptance
tolerance or a foreign callback allocation claim.

Optional --clipping-feedback-control also replays the same fixed ADC inputs
while holding controller feedback at zero. This algorithm counterfactual must
observe nonzero normal controller feedback and a changed demanded component to
be informative; it does not predict a live plant trajectory.
"""
module GraphReplayCheck

using PipeWireAODeployment
using SHA
const Common = PipeWireAODeployment.Common
const Deployment = PipeWireAODeployment.Deployment
const SCALE = 1.0f-6
const FEEDBACK_IN = Symbol("constraint-feedback")
const FEEDBACK_OUT = Symbol("controller-constraint-feedback")
const REQUESTED = Symbol("requested-pdm-command")
const PHYSICAL = Symbol("constraint-feedback")
require(ok, message) = ok || throw(ArgumentError(message))
integer(x) = x isa Integer && !(x isa Bool) && x >= 0
digest(path) = Common.sha256_file(path)
const SCRIPT_SHA256_AT_LOAD = digest(@__FILE__)
function verify_script_identity(path,expected)
    require(digest(path) == expected, "replay script changed during execution")
    return nothing
end
inside(path, root) = path == root || startswith(path, root * "/")

function fresh_output(path, roots)
    output = abspath(path)
    require(!ispath(output) && !islink(output), "output directory must be new")
    parent = dirname(output)
    require(isdir(parent), "output parent directory must exist")
    output = joinpath(realpath(parent), basename(output))
    require(all(root -> !inside(output, realpath(root)), roots),
        "output must be outside installed packages and report directory")
    return output
end

function manifest(package, prefix)
    descriptor = joinpath(package, "deployment.conf")
    data = Deployment.decode(descriptor, prefix)
    require(get(data, "version", nothing) === 1, "deployment descriptor version")
    artifacts = data["artifacts"]
    require(artifacts isa AbstractDict && !isempty(artifacts), "missing artifact manifest")
    for (name, expected) in artifacts
        path = Deployment.relative_asset(package, name)
        require(expected isa String && occursin(r"^[0-9a-f]{64}$", expected) &&
            digest(path) == expected, "artifact hash mismatch: $name")
    end
    for name in ("provenance.json", "graphs/graph.conf.in", "hil/plant.toml")
        require(haskey(artifacts, name), "unbound installed artifact: $name")
    end
    return data
end

function payload(descriptor, report_path, byte_count)
    name = descriptor["file"]
    require(name isa String, "payload file must be a path")
    path = isabspath(name) ? name : joinpath(dirname(report_path), name)
    require(isfile(path) && filesize(path) == byte_count, "payload byte extent: $path")
    require(digest(path) == descriptor["sha256"], "payload hash mismatch: $path")
    return realpath(path)
end

function validate_report(report, profile)
    require(get(report, "version", nothing) === 1 && report["profile"] == profile &&
        report["backend"] in ("cpu", "cuda", "amdgpu"), "simulator report version/profile/backend")
    require(report["completed"] === true && report["failure"] === nothing, "incomplete simulator report")
    n = report["completed_frames"]
    require(integer(n) && 1 <= n <= 256, "recorded prefix frame count must be 1:256")
    require(all(k -> integer(report[k]) && report[k] == n,
        ("completed_commands", "requested_frames", "sequence")), "prefix counts differ")
    sequences = report["sequences"]
    require(length(sequences) == n && all(integer, sequences) && sequences == collect(1:n), "prefix sequences")
    period, exposure = report["model_period_ns"], report["exposure_ns"]
    require(integer(period) && period > 0 && integer(exposure) && 0 < exposure <= period, "model period/exposure")
    times = report["model_timestamps_ns"]
    require(length(times) == n && all(integer, times) &&
        all(i -> big(times[i]) == big(i-1) * period, 1:n), "model chronology")
    sources, received, latency = (report[k] for k in
        ("source_published_ns", "command_received_ns", "source_to_command_latency_ns"))
    require(length(sources) == length(received) == length(latency) == n &&
        all(integer, sources) && all(integer, received) && all(integer, latency), "exchange timing extent/type")
    require(all(i -> big(received[i]) - sources[i] == latency[i], 1:n), "exchange chronology")
    require(all(i -> sources[i] < sources[i+1] && received[i] <= sources[i+1], 1:n-1), "single-flight publication chronology")
    shape = profile == "classic" ? [352,352] : [64,64]
    f, c = report["frame"], report["command"]
    require(all(descriptor -> descriptor["shape"] isa AbstractVector &&
        all(dimension -> integer(dimension) && dimension > 0,descriptor["shape"]),(f,c)), "descriptor shape dimensions must be positive integers")
    require(all(kv -> get(f, first(kv), nothing) == last(kv),
        ("element_type"=>"U16_LE", "layout"=>"ROW_MAJOR", "shape"=>shape,
         "units"=>"raw detector ADC code", "encoding"=>"nearest ties to even",
         "schema"=>"org.calculon.ao.raw-detector-pixels/1")), "raw detector contract")
    require(all(kv -> get(c, first(kv), nothing) == last(kv),
        ("recorded_element_type"=>"F32_LE", "shape"=>[277], "recorded_units"=>"metre OPD",
         "plant_units"=>"metre OPD", "layout"=>"frame followed by 277 actuator values",
         "transport_units"=>"micrometre OPD", "transport_element_type"=>"F32_LE",
         "transport_to_plant_scale"=>1e-6, "schema"=>"org.calculon.ao.demanded-pdm-command/1")) &&
         get(report, "transport", "scientific") == "scientific", "command contract")
    return Int(n), Tuple(shape)
end

function expected_parameters(profile)
    if profile == "classic"
        result = Dict(p.name => (p.element_type, Tuple(p.shape)) for p in PipeWireAODeployment.ScienceExport.classic_parameters())
        count = 221
    else
        count = 253
        result = Dict("background"=>("F32_LE",(64,64)), "reconstructor"=>("F32_LE",(253,3600)),
            "active-to-full"=>("F32_LE",(253,253)), "vdm-to-pdm"=>("F32_LE",(277,253)),
            "system-flat"=>("F32_LE",(277,)), "controller-to-vdm"=>("F32_LE",(253,253)),
            "full-to-active"=>("F32_LE",(253,253)), "pdm-to-vdm"=>("F32_LE",(253,277)),
            "vdm-to-controller"=>("F32_LE",(253,253)))
    end
    result["shape-to-hidden"] = ("F32_LE", (1,count))
    result["hidden-to-shape"] = ("F32_LE", (count,1))
    return result
end

function startup_parameters(owner)
    argv = owner["argv"]
    execution = findall(==("--execution"), argv)
    feedback = findall(==("--feedback"), argv)
    require(length(execution) == 1 && argv[only(execution)+1] == "complete-frame", "requires complete-frame owner")
    require(length(feedback) == 1 && argv[only(feedback)+1:only(feedback)+2] ==
        [String(FEEDBACK_IN), String(FEEDBACK_OUT)], "owner delayed feedback contract")
    result = Dict{String,Any}()
    for i in findall(==("--parameter"), argv)
        require(i+4 <= length(argv), "truncated startup parameter")
        name, kind, dims, path = argv[i+1:i+4]
        require(!haskey(result, name), "duplicate startup parameter: $name")
        result[name] = (kind, Tuple(parse.(Int, split(dims, ','))), path)
    end
    declarations = String[]
    for i in findall(==("--algorithm"), argv)
        require(i+1 <= length(argv), "truncated algorithm declaration")
        push!(declarations, argv[i+1])
    end
    require(!("--no-builtins" in argv) && !("--algorithm-package" in argv), "unsupported owner algorithm provider")
    return result, declarations
end

function read_values(path, ::Type{T}, count) where T
    bytes = read(path)
    require(length(bytes) == sizeof(T)*count, "array payload byte extent")
    values = if T === Float32
        copy(reinterpret(Float32, ltoh.(reinterpret(UInt32, bytes))))
    else
        ltoh.(reinterpret(T, bytes))
    end
    T <: AbstractFloat && require(all(isfinite, values), "nonfinite array payload")
    return values
end

function parameter_array(record)
    shape = Tuple(record["shape"])
    kind = record["element_type"]
    values = if kind == "Bool"
        bytes = read(record["path"])
        require(length(bytes) == prod(shape) && all(v -> v in (0,1), bytes), "invalid Boolean parameter")
        Bool[Bool(value) for value in bytes]
    else
        read_values(record["path"], kind == "F32_LE" ? Float32 : UInt32, prod(shape))
    end
    length(shape) == 1 && return values
    # Packed calibration and detector payloads are ROW_MAJOR.
    return permutedims(reshape(values, reverse(shape)), reverse(1:length(shape)))
end

function parameter_records(package, descriptor, provenance, owner, profile)
    expected = expected_parameters(profile)
    startup, declarations = startup_parameters(owner)
    require(Set(keys(startup)) == Set(keys(expected)), "unexpected/missing startup parameters")
    declared = Dict{String,Any}()
    for p in vcat(provenance["parameters"], get(provenance, "construction_parameters", Any[]))
        require(!haskey(declared, p["name"]), "duplicate provenance parameter")
        declared[p["name"]] = p
    end
    require(Set(keys(declared)) == setdiff(Set(keys(expected)), Set(("shape-to-hidden", "hidden-to-shape"))), "provenance parameter set")
    records = Any[]
    for name in sort!(collect(keys(expected)))
        kind, shape = expected[name]
        cli_kind, cli_shape, cli_path = startup[name]
        require(cli_kind == Dict("F32_LE"=>"Float32", "U32_LE"=>"UInt32", "Bool"=>"Bool")[kind] &&
            cli_shape == shape, "startup parameter contract: $name")
        path = realpath(replace(cli_path, "@PACKAGE@"=>package))
        require(inside(path, joinpath(package,"calibration")), "parameter escapes calibration: $name")
        require(haskey(descriptor["artifacts"], relpath(path, package)), "unbound parameter: $name")
        p = get(declared, name, nothing)
        if p !== nothing
            require(p["element_type"] == kind && Tuple(p["shape"]) == shape && p["file"] == basename(path) &&
                get(p,"layout","ROW_MAJOR") == "ROW_MAJOR" && get(p,"sha256",digest(path)) == digest(path), "provenance parameter contract: $name")
        end
        record = Dict("name"=>name, "path"=>path, "element_type"=>kind, "shape"=>collect(shape),
            "sha256"=>digest(path), "endpoint"=>p === nothing ? "hidden controller map" : p["endpoint"])
        array = parameter_array(record)
        if name in ("shape-to-hidden", "hidden-to-shape")
            require(all(iszero,array), "hidden maps must be explicit zeros")
        elseif name == "thresholds"
            require(all(>=(0),array), "negative adopted threshold")
        elseif name == "subaperture-origins"
            require(all(v -> v <= 330,array), "Classic ROI origin outside detector")
        end
        push!(records, record)
    end
    return records, declarations
end

function matching_parameters(records, source, provenance, source_graph;
                             allow_reconstructor_difference=false, source_artifacts=nothing)
    declared = Dict{String,Any}()
    construction = Set(p["name"] for p in get(provenance,"construction_parameters",Any[]))
    for p in vcat(provenance["parameters"], get(provenance,"construction_parameters",Any[]))
        require(!haskey(declared,p["name"]), "duplicate source provenance parameter")
        declared[p["name"]] = p
    end
    differences = Any[]
    for record in records
        name = record["name"]
        if haskey(declared,name)
            p = declared[name]
            require(p["element_type"] == record["element_type"] && p["shape"] == record["shape"] &&
                get(p,"layout","ROW_MAJOR") == "ROW_MAJOR", "source parameter descriptor differs: $name")
        end
        embedded = get(provenance,"engine",nothing) == "fgn" && name in construction &&
            name in ("subaperture-origins", "active")
        if embedded || (!haskey(declared,name) && name in ("subaperture-origins", "active"))
            nodes = filter(n -> n["label"] == "shack-hartmann-image-f32", source_graph["filter.graph"]["nodes"])
            require(length(nodes) == 1, "source Classic sensing node")
            array = parameter_array(record)
            expected = name == "active" ? collect(array) : [collect(array[i,:]) for i in axes(array,1)]
            field = name == "active" ? "active" : "initial_subaperture_origins"
            require(only(nodes)["config"][field] == expected, "source/JFG sensing construction differs: $name")
            if embedded
                require(get(declared[name],"sha256",record["sha256"]) == record["sha256"], "source/JFG construction hash differs: $name")
            end
        elseif haskey(declared,name)
            p = declared[name]
            path = Deployment.relative_asset(source,"calibration/" * p["file"])
            source_artifacts === nothing || require(haskey(source_artifacts,relpath(path,source)), "unbound source parameter: $name")
            source_digest = digest(path)
            require(get(p,"sha256",source_digest) == source_digest, "source provenance hash differs: $name")
            if source_digest != record["sha256"]
                require(allow_reconstructor_difference && name == "reconstructor", "source/JFG parameter bytes differ: $name")
                source_array = parameter_array(merge(record,Dict("path"=>path)))
                jfg_array = parameter_array(record)
                delta = Float64.(jfg_array).-Float64.(source_array)
                denominator = sqrt(sum(abs2,Float64.(source_array)))
                push!(differences,Dict("name"=>name, "source_sha256"=>source_digest,
                    "jfg_sha256"=>record["sha256"], "max_abs_difference"=>maximum(abs,delta),
                    "rms_difference"=>sqrt(sum(abs2,delta)/length(delta)),
                    "relative_frobenius_difference"=>denominator == 0 ? nothing : sqrt(sum(abs2,delta))/denominator,
                    "nonidentical_components"=>count(!iszero,delta),
                    "decision"=>"explicitly permitted for characterization; no numerical tolerance or acceptance applied"))
            end
        else
            require(name in ("shape-to-hidden", "hidden-to-shape"), "missing source parameter: $name")
        end
    end
    return differences
end

function one_node(graph, label)
    nodes = filter(n -> n["label"] == label, graph["filter.graph"]["nodes"])
    require(length(nodes) == 1, "requires one $label node")
    return only(nodes)
end

function matching_controller(graph, source_graph)
    for label in ("closed-loop-correction-f32", "controller-to-vdm-f32", "vdm-to-pdm-f32",
                  "pdm-feedback-to-vdm-f32", "vdm-feedback-to-controller-f32", "pdm-command-f32")
        current, source = one_node(graph,label), one_node(source_graph,label)
        require(get(current,"props",Dict()) == get(source,"props",Dict()), "source/JFG coefficients differ: $label")
        a, b = deepcopy(current["config"]), deepcopy(source["config"])
        pop!(a,"rate",nothing)
        pop!(b,"rate",nothing)
        if label == "pdm-command-f32"
            for field in ("initial_current", "slew_limit", "quantization_origin", "quantization_step", "dither_seed")
                require(get(a,field,nothing) === nothing && get(b,field,nothing) === nothing, "unsupported nondefault limiter initialization: $field")
                pop!(a,field,nothing)
                pop!(b,field,nothing)
            end
            require(get(a,"slew_mode","independent") == get(b,"slew_mode","independent") == "independent", "unsupported slew mode")
            pop!(a,"slew_mode",nothing)
            pop!(b,"slew_mode",nothing)
        end
        require(a == b, "source/JFG controller construction differs: $label")
    end
end

function diagnostic_graph(original, decoded, profile)
    g = decoded["filter.graph"]
    projection = one_node(decoded,"vdm-to-pdm-f32")["name"]
    command = one_node(decoded,"pdm-command-f32")["name"]
    controller = one_node(decoded,"vdm-feedback-to-controller-f32")["name"]
    require(g["outputs"] == [command * ":demanded", controller * ":" * String(FEEDBACK_OUT)], "unexpected ordinary graph outputs")
    require((projection,command) == (profile == "classic" ? ("vdm-to-pdm","pdm-command") : ("physical","command")), "unexpected maintained diagnostic endpoints")
    matches = collect(eachmatch(r"(\"outputs\"\s*[:=]\s*\[)([^\]]*)(\])", original))
    require(length(matches) == 1, "requires one ordinary output declaration")
    m = only(matches)
    closing = m.offset + ncodeunits(m.match) - 1
    extra = " \"$projection:$(String(REQUESTED))\" \"$command:$(String(PHYSICAL))\" "
    return original[1:prevind(original,closing)] * extra * original[closing:end]
end

function admit(package_path, report_path, output_path; prefix="/opt/pipewireao", allow_reconstructor_difference=false)
    package, report_path = realpath(package_path), realpath(report_path)
    descriptor = manifest(package,prefix)
    provenance = Common.read_json(joinpath(package,"provenance.json"))
    profile = provenance["profile"]
    require(profile in ("classic","copper") && provenance["engine"] == "jfg" && provenance["mode"] == "frame", "requires installed Classic/Copper JFG complete-frame package")
    for name in ("jfg/deployment/Project.toml", "jfg/deployment/Manifest.toml")
        require(haskey(descriptor["artifacts"],name), "unbound JFG environment: $name")
    end
    report = Common.read_json(report_path)
    n, shape = validate_report(report,profile)
    raw = payload(report["frame"],report_path,2*prod(shape)*n)
    command = payload(report["command"],report_path,4*277*n)
    read_values(command,Float32,277*n)
    plant = realpath(report["graph"])
    source = dirname(dirname(plant))
    source_descriptor = manifest(source,prefix)
    require(plant == joinpath(source,"hil/plant.toml") && digest(plant) == report["graph_sha256"], "recorded plant identity")
    source_provenance = Common.read_json(joinpath(source,"provenance.json"))
    require(source_provenance["profile"] == profile && source_provenance["engine"] in ("fgn","jfg") && source_provenance["mode"] == "frame", "source package profile/engine/mode")
    require(digest(joinpath(package,"hil/plant.toml")) == digest(plant), "source/JFG plant differs")
    output = fresh_output(output_path,(package,source,dirname(report_path)))
    owners = filter(o -> o["role"] == "julia",descriptor["owners"])
    require(length(owners) == 1, "requires one Julia owner")
    records, algorithms = parameter_records(package,descriptor,provenance,only(owners),profile)
    graph_path = joinpath(package,"graphs/graph.conf.in")
    source_graph_path = joinpath(source,"graphs/graph.conf.in")
    graph = Deployment.decode(graph_path,prefix)
    source_graph = Deployment.decode(source_graph_path,prefix)
    differences = matching_parameters(records,source,source_provenance,source_graph;
        allow_reconstructor_difference, source_artifacts=source_descriptor["artifacts"])
    if source_provenance["engine"] == "jfg"
        source_owners = filter(o -> o["role"] == "julia",source_descriptor["owners"])
        require(length(source_owners) == 1, "requires one source Julia owner")
        source_records, source_algorithms = parameter_records(source,source_descriptor,source_provenance,only(source_owners),profile)
        require(source_algorithms == algorithms, "source/JFG algorithm declarations differ")
        source_records_by_name = Dict(p["name"]=>p for p in source_records)
        for record in records
            record["name"] == "reconstructor" && allow_reconstructor_difference && continue
            require(source_records_by_name[record["name"]]["sha256"] == record["sha256"], "source/JFG startup parameter differs: $(record["name"])")
        end
    end
    # Compare the controller coefficients directly, without inventing science
    # equivalence for the different Copper pupil reconstruction declarations.
    matching_controller(graph,source_graph)
    control = one_node(graph,"closed-loop-correction-f32")
    require(control["config"]["hidden_mode_count"] == 1 && control["props"]["hidden-mode-gain"] == 0, "hidden controller mode contract")
    diagnostic = diagnostic_graph(read(graph_path,String),graph,profile)
    mkdir(output)
    diagnostic_path = joinpath(output,"diagnostic-graph.conf")
    write(diagnostic_path,diagnostic)
    decoded_diagnostic = Deployment.decode(diagnostic_path,prefix)
    expected = deepcopy(graph)
    append!(expected["filter.graph"]["outputs"], profile == "classic" ?
        ["vdm-to-pdm:requested-pdm-command","pdm-command:constraint-feedback"] :
        ["physical:requested-pdm-command","command:constraint-feedback"])
    require(decoded_diagnostic == expected, "diagnostic copy changed more than output declarations")
    metadata = Dict("package"=>package, "source_package"=>source, "profile"=>profile,
        "source_engine"=>source_provenance["engine"], "simulator_backend"=>report["backend"],
        "frame_count"=>n, "frame_shape"=>collect(shape), "controller_count"=>profile == "classic" ? 221 : 253,
        "model_timestamps_ns"=>report["model_timestamps_ns"], "raw_path"=>raw,
        "command_path"=>command, "report_path"=>report_path, "parameters"=>records,
        "frame_descriptor"=>report["frame"], "command_descriptor"=>report["command"],
        "algorithms"=>algorithms, "diagnostic_graph"=>diagnostic_path,
        "allow_reconstructor_difference"=>allow_reconstructor_difference, "parameter_differences"=>differences,
        "hashes"=>Dict("report"=>digest(report_path), "raw"=>digest(raw), "commands"=>digest(command),
            "descriptor"=>digest(joinpath(package,"deployment.conf")), "source_descriptor"=>digest(joinpath(source,"deployment.conf")),
            "provenance"=>digest(joinpath(package,"provenance.json")), "source_provenance"=>digest(joinpath(source,"provenance.json")),
            "graph"=>digest(graph_path), "source_graph"=>digest(source_graph_path), "diagnostic_graph"=>digest(diagnostic_path),
            "project"=>digest(joinpath(package,"jfg/deployment/Project.toml")), "manifest"=>digest(joinpath(package,"jfg/deployment/Manifest.toml")),
            "plant"=>digest(plant)))
    Common.write_json(joinpath(output,"input-metadata.json"),metadata)
    return metadata, output
end

function difference_statistics(predicted, actual)
    require(size(predicted) == size(actual) && !isempty(predicted), "comparison extent")
    delta = Float64.(predicted) .- Float64.(actual)
    maximum_m = maximum(abs,delta)
    rms_m = sqrt(sum(abs2,delta)/length(delta))
    return (; max_abs_difference_m=maximum_m, rms_difference_m=rms_m,
        max_abs_difference_um=maximum_m/Float64(SCALE), rms_difference_um=rms_m/Float64(SCALE),
        nonidentical_components=count(!iszero,delta))
end

function vector_statistics(array)
    return (; max_abs_um=maximum(abs,array), rms_um=sqrt(sum(abs2,Float64.(array))/length(array)),
        l2_um=sqrt(sum(abs2,Float64.(array))), nonzero_components=count(!iszero,array))
end

function aggregate_statistics(records, field)
    statistics = [getproperty(record,field) for record in records]
    return (; max_abs_um=maximum(s -> s.max_abs_um,statistics),
        rms_um=sqrt(sum(s -> s.rms_um^2,statistics)/length(statistics)),
        nonzero_components=sum(s -> s.nonzero_components,statistics),
        nonzero_frames=count(s -> s.nonzero_components > 0,statistics))
end

function load_frame!(raw, values, sequence)
    rows, columns = size(raw)
    first = (sequence-1)*length(raw)
    for row in 1:rows, column in 1:columns
        raw[row,column] = values[first+(row-1)*columns+column]
    end
    return raw
end

complete(result) = result isa NamedTuple && all(v -> v === true,values(result))

# Concrete function arguments keep compilation and dynamic dispatch outside
# the allocation counter. Only the public call is measured.
function allocated_process!(process::F, outputs::O, graph::G, inputs::I) where {F,O,G,I}
    result = nothing
    bytes = @allocated result = process(outputs,graph,inputs)
    return bytes, result
end

function replay_frames!(process::F, reset::R, graph::G, inputs::I, outputs::O,
                        raw_values, actual, timestamps; measure=false,carry_feedback=true) where {F,R,G,I,O}
    n = size(actual,2)
    raw, feedback = inputs.raw, getproperty(inputs,FEEDBACK_IN)
    load_frame!(raw,raw_values,1)
    fill!(feedback,0)
    require(complete(process(outputs,graph,inputs)), "incomplete warm frame")
    # Warm the allocation wrapper too, then restore the initial state before
    # replaying every frame, including frame one.
    measure && allocated_process!(process,outputs,graph,inputs)
    reset(graph)
    fill!(feedback,0)
    predicted = similar(actual)
    records = Any[]
    allocation_bytes = Int[]
    for sequence in 1:n
        load_frame!(raw,raw_values,sequence)
        result = if measure
            bytes, published = allocated_process!(process,outputs,graph,inputs)
            push!(allocation_bytes,bytes)
            published
        else
            process(outputs,graph,inputs)
        end
        require(complete(result), "incomplete JFG frame $sequence")
        demanded, requested = outputs.demanded, getproperty(outputs,REQUESTED)
        physical, controller = getproperty(outputs,PHYSICAL), getproperty(outputs,FEEDBACK_OUT)
        require(all(array -> all(isfinite,array),(demanded,requested,physical,controller)), "nonfinite public frame outputs")
        for actuator in axes(predicted,1)
            predicted[actuator,sequence] = demanded[actuator]*SCALE
        end
        push!(records,(; sequence, model_timestamp_ns=timestamps[sequence],
            difference_statistics(@view(predicted[:,sequence]),@view(actual[:,sequence]))...,
            requested_minus_demanded=vector_statistics(Float64.(requested).-Float64.(demanded)),
            physical_constraint_feedback=vector_statistics(physical), controller_constraint_feedback=vector_statistics(controller),
            demanded=vector_statistics(demanded), requested=vector_statistics(requested)))
        # This copy, input loading and diagnostics are outside @allocated.
        if carry_feedback
            copyto!(feedback,controller)
        else
            fill!(feedback,0)
        end
    end
    return (; predicted, records, allocation_bytes)
end

function declarations(fga, names)
    algorithms = fga.algorithms()
    for name in names
        parts = split(name,'.')
        require(length(parts) == 2 && parts[1] == "FilterGraphAlgorithms" &&
            Base.isidentifier(parts[2]), "unsupported installed algorithm declaration")
        identifier = Symbol(parts[2])
        require(Base.isexported(fga,identifier), "algorithm declaration is not exported")
        algorithms = (algorithms...,getproperty(fga,identifier))
    end
    return Tuple(unique(algorithms))
end

function prepared_replay(metadata, fga, jfg, raw_values, actual; measure=false,carry_feedback=true)
    bindings = map(p -> Symbol(p["name"])=>parameter_array(p),metadata["parameters"])
    graph = jfg.prepare_graph(metadata["diagnostic_graph"]; algorithms=declarations(fga,metadata["algorithms"]))
    cleanup_available = applicable(close,graph)
    try
        jfg.replace_parameters!(graph,bindings...)
        raw = zeros(UInt16,Tuple(metadata["frame_shape"]))
        feedback = zeros(Float32,metadata["controller_count"])
        inputs = NamedTuple{(:raw,FEEDBACK_IN)}((raw,feedback))
        outputs = map(format -> zeros(format.element_type,format.shape),graph.output_formats)
        require(size(outputs.demanded) == size(getproperty(outputs,REQUESTED)) == size(getproperty(outputs,PHYSICAL)) == (277,) &&
            size(getproperty(outputs,FEEDBACK_OUT)) == size(feedback), "ordinary public output shapes")
        return replay_frames!(jfg.process!,jfg.reset!,graph,inputs,outputs,raw_values,actual,
            metadata["model_timestamps_ns"];measure,carry_feedback), cleanup_available
    finally
        cleanup_available && close(graph)
    end
end

function feedback_control_report(normal,no_carry,actual)
    controller = aggregate_statistics(normal.records,:controller_constraint_feedback)
    difference = difference_statistics(no_carry.predicted,normal.predicted)
    informative = controller.nonzero_components > 0 && difference.nonidentical_components > 0
    return Dict("scope"=>"fixed recorded ADC inputs; algorithm counterfactual with controller feedback held zero; not a live plant trajectory or numerical acceptance test",
        "feedback"=>"fresh prepared graph; warm then reset; feedback input zero before every process!; observed controller output discarded after each frame",
        "normal_controller_nonzero_components"=>controller.nonzero_components,
        "normal_controller_nonzero_frames"=>controller.nonzero_frames,
        "no_carry_vs_normal"=>difference,
        "no_carry_vs_recorded"=>difference_statistics(no_carry.predicted,actual),
        "informative"=>informative,"flag_gate_passed"=>informative,
        "flag_gate"=>"nonzero normal controller feedback and at least one exact Float32 adopted-command component difference when carry is removed; no numerical acceptance threshold",
        "constraint_summary"=>Dict(string(field)=>aggregate_statistics(no_carry.records,field) for field in
            (:requested_minus_demanded,:physical_constraint_feedback,:controller_constraint_feedback)),
        "per_frame"=>no_carry.records)
end

function require_informative_feedback_control(control)
    require(control["informative"] && control["flag_gate_passed"],
        "clipping feedback control is uninformative: require nonzero controller feedback and a changed no-carry demanded component")
    return nothing
end

function replay_graph(metadata, output, fga, jfg; clipping_feedback_control=false)
    project = joinpath(metadata["package"],"jfg/deployment/Project.toml")
    require(Base.active_project() !== nothing && realpath(Base.active_project()) == realpath(project),
        "run with exact installed --project=PACKAGE/jfg/deployment")
    n = metadata["frame_count"]
    raw_values = read_values(metadata["raw_path"],UInt16,prod(metadata["frame_shape"])*n)
    actual = reshape(read_values(metadata["command_path"],Float32,277*n),277,n)
    numerical, close_numerical = prepared_replay(metadata,fga,jfg,raw_values,actual)
    measured, close_measured = prepared_replay(metadata,fga,jfg,raw_values,actual;measure=true)
    require(numerical.predicted == measured.predicted, "separate reset allocation replay changed trajectory")
    path = joinpath(output,"predicted.commands.f32le")
    write(path,reinterpret(UInt8,htol.(reinterpret(UInt32,vec(numerical.predicted)))))
    bytes = measured.allocation_bytes
    result = Dict("version"=>1, "executed"=>true, "julia_version"=>string(VERSION),
        "scope"=>"shared recorded ADC prefix; ordinary arrays; numerical and allocation characterization only; no tolerance or scientific acceptance",
        "feedback"=>"zero after warm/reset; chronological controller feedback copied after each successful frame",
        "conversion"=>"Float32 demanded * 1.0f-6 compared with recorded Float32 metre OPD",
        "input_metadata"=>metadata, "prediction_path"=>path, "prediction_sha256"=>digest(path),
        "summary"=>difference_statistics(numerical.predicted,actual), "per_frame"=>numerical.records,
        "constraint_summary"=>Dict(string(field)=>aggregate_statistics(numerical.records,field) for field in
            (:requested_minus_demanded,:physical_constraint_feedback,:controller_constraint_feedback)),
        "ordinary_process_allocations"=>Dict("per_frame_bytes"=>bytes, "total_bytes"=>sum(bytes),
            "max_bytes"=>maximum(bytes), "nonzero_frames"=>count(!iszero,bytes),
            "measurement"=>"separately prepared graph; warm then reset; every prefix process! measured; preallocated input/output; feedback copy and diagnostics outside counter",
            "scope"=>"ordinary public process! only; excludes foreign transport callbacks"),
        "public_close_available"=>close_numerical && close_measured,
        "source_identity_limit"=>"current installed manifest identity verified; v1 report does not bind acquisition-time controller helper hashes; different Copper pupil declarations are not asserted numerically equivalent")
    if clipping_feedback_control
        no_carry, close_no_carry = prepared_replay(metadata,fga,jfg,raw_values,actual;carry_feedback=false)
        control = feedback_control_report(numerical,no_carry,actual)
        control_path = joinpath(output,"no-carry.commands.f32le")
        write(control_path,reinterpret(UInt8,htol.(reinterpret(UInt32,vec(no_carry.predicted)))))
        control["prediction_path"] = control_path
        control["prediction_sha256"] = digest(control_path)
        control["public_close_available"] = close_no_carry
        result["clipping_feedback_control"] = control
    end
    return result
end

function main(argv=ARGS)
    script_at_start = digest(@__FILE__)
    verify_script_identity(@__FILE__,SCRIPT_SHA256_AT_LOAD)
    options = Common.cli_arguments(argv;required=["package","report","output"],
        flags=["allow-reconstructor-difference","clipping-feedback-control"],defaults=(prefix="/opt/pipewireao",))
    project = joinpath(realpath(options.package),"jfg/deployment/Project.toml")
    require(Base.active_project() !== nothing && realpath(Base.active_project()) == realpath(project),
        "run with exact installed --project=PACKAGE/jfg/deployment")
    metadata, output = admit(options.package,options.report,options.output;prefix=options.prefix,
        allow_reconstructor_difference=options.allow_reconstructor_difference)
    metadata["script_sha256_at_start"] = script_at_start
    Common.write_json(joinpath(output,"input-metadata.json"),metadata)
    fga = @eval begin
        import FilterGraphAlgorithms
        FilterGraphAlgorithms
    end
    jfg = @eval begin
        import JuliaFilterGraph
        JuliaFilterGraph
    end
    result = Base.invokelatest(replay_graph,metadata,output,fga,jfg;
        clipping_feedback_control=options.clipping_feedback_control)
    verify_script_identity(@__FILE__,script_at_start)
    result["script_sha256"] = script_at_start
    result["script_identity_scope"] = "file SHA checked at module initialization, main entry and before report; execution file must remain immutable; these checks do not independently prove parsed-code byte identity"
    Common.write_json(joinpath(output,"graph-replay.json"),result)
    options.clipping_feedback_control && require_informative_feedback_control(result["clipping_feedback_control"])
    return result
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && GraphReplayCheck.main()
