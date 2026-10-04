module CalibrationExport

using JSON3
using ..Common
using ..Deployment
using ..ScienceExport

const ROOT = ScienceExport.resource_root()
const REQUESTED_SCHEMA = "org.calculon.ao.requested-pdm-command/1"
const FEEDBACK_SCHEMA = "org.calculon.ao.pdm-constraint-feedback/1"

option(args, name::Symbol, default=nothing) = hasproperty(args, name) ? getproperty(args, name) : default

function validate_capture_budget(profile, maximum_bytes, deployment)
    maximum_bytes === nothing && return nothing
    payload_bytes = get(Dict("classic" => 250252, "copper" => 22596), profile, nothing)
    payload_bytes !== nothing && maximum_bytes isa Int && !(maximum_bytes isa Bool) &&
        1 <= maximum_bytes <= 4096 * payload_bytes && deployment === true ||
        throw(ArgumentError("capture requires Classic/Copper deployment and a bounded positive payload budget"))
    return nothing
end

function spa_json(value, indent::Int=0)
    padding = repeat("    ", indent)
    if value isa AbstractDict
        entries = [repeat("    ", indent + 1) * JSON3.write(String(key)) * " = " * spa_json(item, indent + 1)
                   for (key, item) in value]
        return "{\n" * join(entries, "\n") * "\n" * padding * "}"
    elseif value isa AbstractVector || value isa Tuple
        return "[ " * join((spa_json(item, indent) for item in value), " ") * " ]"
    elseif value isa AbstractFloat && !isfinite(value)
        throw(ArgumentError("nonfinite SPA-JSON number"))
    end
    return JSON3.write(value)
end

function split_graph(source::AbstractDict, profile::AbstractString, engine::AbstractString, name::AbstractString)
    graph = source["filter.graph"]
    labels = ("pixel-calibration-u16-f32",
              profile == "classic" ? "shack-hartmann-image-f32" : (engine == "fgn" ? "pyramid-pixel-image-f32" : "pyramid-pupil-image-f32"),
              "pdm-command-f32")
    selected = Any[]
    for label in labels
        matches = [node for node in graph["nodes"] if get(node, "label", nothing) == label]
        length(matches) == 1 || throw(ArgumentError("calibration requires one maintained $label node"))
        push!(selected, matches[1])
    end
    pixel, wfs, command = selected
    get(command["config"], "actuator_count", nothing) == 277 || throw(ArgumentError("selected calibration requires 277 physical actuator commands"))
    extent = profile == "classic" ? 352 : 64
    all(get(node["config"], key, nothing) == extent for node in (pixel,wfs) for key in ("image_rows","image_columns")) ||
        throw(ArgumentError("selected full-frame WFS detector geometry differs"))
    geometry = profile == "classic" ? Dict("subaperture_count"=>188,"subaperture_rows"=>22,"subaperture_columns"=>22) : Dict("pupil_rows"=>30,"pupil_columns"=>30)
    all(get(wfs["config"],key,nothing) == value for (key,value) in geometry) || throw(ArgumentError("selected full-frame WFS measurement geometry differs"))
    mask = get(wfs["config"], "pupil_mask", nothing)
    profile == "copper" && mask !== nothing && !(length(mask) == 900 && all(x -> x === true, mask)) &&
        throw(ArgumentError("selected Copper requires all 900 pupil coordinates"))
    length(Set(node["name"] for node in graph["nodes"])) == length(graph["nodes"]) || throw(ArgumentError("maintained graph node names must be unique"))
    link = Dict("output" => pixel["name"] * ":calibrated", "input" => wfs["name"] * ":image")
    count(item -> item == link, graph["links"]) == 1 || throw(ArgumentError("maintained graph requires the exact pixel-to-WFS link"))
    result = Dict{String,Any}()
    outputs_wfs = profile == "classic" ? ("slopes", "flux", "validity") : ("reconstruction-pixels", "mean-pupil-intensity")
    for (role, nodes, links, outputs) in (("wfs", [pixel,wfs], [link], [wfs["name"] * ":" * port for port in outputs_wfs]),
                                          ("command", [command], Any[], [command["name"] * ":demanded", command["name"] * ":constraint-feedback"]))
        value = deepcopy(source)
        for key in collect(keys(value))
            (startswith(key, "pipewireao.feedback.") || startswith(key, "pipewireao.startup-parameter.")) && delete!(value,key)
        end
        value["node.name"] = name * "-" * role
        names = Set(node["name"] for node in nodes)
        local_graph = value["filter.graph"]
        local_graph["nodes"] = deepcopy(nodes)
        local_graph["links"] = deepcopy(links)
        local_graph["inputs"] = role == "wfs" ? [port for port in graph["inputs"] if first(split(port, ":"; limit=2)) in names] : [command["name"] * ":requested"]
        local_graph["outputs"] = outputs
        result[role] = value
    end
    return result
end

function graph_parameters(graph::AbstractDict, parameters)
    inputs = Set(graph["filter.graph"]["inputs"])
    return ScienceExport.Parameter[ScienceExport.Parameter(item) for item in parameters if item["endpoint"] in inputs]
end

function julia_arguments(graph::AbstractDict, parameters, role::AbstractString, rate::AbstractString, executable::AbstractString)
    argv = String[executable, "--startup-file=no", "--threads=2,0", "--project=@PACKAGE@/jfg/deployment",
                  "@PACKAGE@/jfg/deployment/run_island.jl", "--graph", "@PACKAGE@/graphs/$role.conf.in",
                  "--name", graph["node.name"], "--remote", "@REMOTE@", "--rate", rate,
                  "--boundary-layout", "row-major", "--session-run-control", "--fifo-inputs", "--execution", "complete-frame"]
    any(node -> node["label"] == "pyramid-pupil-image-f32", graph["filter.graph"]["nodes"]) &&
        append!(argv, ["--algorithm", "FilterGraphAlgorithms.PyramidPupilImageF32"])
    for parameter in parameters
        append!(argv, ["--parameter", last(split(parameter.endpoint, ":"; limit=2)), ScienceExport.JULIA_TYPES[parameter.element_type],
                       join(parameter.shape, ","), "@PACKAGE@/calibration/" * parameter.file])
    end
    for endpoint in graph["filter.graph"]["outputs"]
        append!(argv, ["--warmup-output", last(split(endpoint, ":"; limit=2))])
    end
    return argv
end

function boundary_contract(graph::AbstractDict, profile::AbstractString, role::AbstractString, engine::AbstractString)
    nodes = graph["filter.graph"]["nodes"]
    endpoint(node, leaf) = engine == "fgn" ? node["name"] * ":" * leaf : leaf
    if role == "command"
        return [ScienceExport.port(endpoint(nodes[1], leaf), direction, [277], schema) for (leaf,direction,schema) in
                (("requested","input",REQUESTED_SCHEMA), ("demanded","output",ScienceExport.COMMAND_SCHEMA), ("constraint-feedback","output",FEEDBACK_SCHEMA))]
    end
    extent = profile == "classic" ? 352 : 64
    value = [ScienceExport.port(endpoint(nodes[1], "raw"), "input", [extent,extent], ScienceExport.RAW_SCHEMA, "U16_LE")]
    measures = profile == "classic" ? (("slopes",[188,2],"shack-hartmann-slopes","F32_LE"),
                                        ("flux",[188],"shack-hartmann-flux","F32_LE"),
                                        ("validity",[188],"shack-hartmann-validity","BOOL8")) :
                                       (("reconstruction-pixels",[4,900],"pyramid-reconstruction-pixels","F32_LE"),
                                        ("mean-pupil-intensity",[1],"pyramid-mean-pupil-intensity","F32_LE"))
    append!(value, [ScienceExport.port(endpoint(nodes[2],leaf), "output", shape, "org.calculon.ao.$schema/1", element)
                    for (leaf,shape,schema,element) in measures])
    return value
end

function calibration_session(records, profile, engine, rate)
    extent = profile == "classic" ? 352 : 64
    function repeated_port(name,direction,shape,schema,element)
        value = ScienceExport.port(name,direction,shape,schema,element)
        value["rate"] = rate
        return value
    end
    sources = Any[Dict("ownership"=>"external","node.name"=>"simulator-wfs","ports"=>[repeated_port("output_1","output",[extent,extent],ScienceExport.RAW_SCHEMA,"U16_LE")]),
                  Dict("ownership"=>"external","node.name"=>"calibration-probe","ports"=>[repeated_port("output_1","output",[277],REQUESTED_SCHEMA,"F32_LE")])]
    sinks = Any[Dict("ownership"=>"external","node.name"=>"simulator-command","ports"=>[repeated_port("input_1","input",[277],ScienceExport.COMMAND_SCHEMA,"F32_LE")]),
                Dict("ownership"=>"external","node.name"=>"calibration-feedback","ports"=>[repeated_port("input_1","input",[277],FEEDBACK_SCHEMA,"F32_LE")])]
    wfs = only([record for record in records if record["role"] == "wfs"])
    command = only([record for record in records if record["role"] == "command"])
    response_names = profile == "classic" ? ("calibration-slopes","calibration-flux","calibration-validity") :
                                            ("calibration-reconstruction-pixels","calibration-mean-pupil-intensity")
    for (name,port) in zip(response_names,wfs["ports"][2:end])
        push!(sinks, Dict("ownership"=>"external","node.name"=>name,"ports"=>
                         [repeated_port("input_1","input",port["shape"],port["schema"],port["element-type"])]))
    end
    push!(sinks, Dict("ownership"=>"external","node.name"=>"calibration-raw","ports"=>
                     [repeated_port("input_1","input",[extent,extent],ScienceExport.RAW_SCHEMA,"U16_LE")]))
    graphs = Any[]
    for record in records
        graph = Dict{String,Any}("node.name"=>record["node.name"],"ports"=>record["ports"])
        if engine == "fgn"
            merge!(graph, Dict("factory"=>"pipewireao.fgn-native","module"=>"libpipewire-module-ndarray-filter-chain",
                               "config.path"=>"\${PIPEWIREAO_RTC_GRAPH_CALIBRATION_$(uppercase(record["role"]))}"))
        else
            merge!(graph, Dict("ownership"=>"external","run-control"=>"session"))
        end
        push!(graphs,graph)
    end
    wfs_node, command_node = wfs["node.name"], command["node.name"]
    links = Any[
        Dict("output"=>"simulator-wfs:output_1","input"=>"$wfs_node:$(wfs["ports"][1]["name"])","passive"=>true),
        Dict("output"=>"simulator-wfs:output_1","input"=>"calibration-raw:input_1","passive"=>false),
        Dict("output"=>"calibration-probe:output_1","input"=>"$command_node:$(command["ports"][1]["name"])","passive"=>true),
        Dict("output"=>"$command_node:$(command["ports"][2]["name"])","input"=>"simulator-command:input_1","passive"=>false),
        Dict("output"=>"$command_node:$(command["ports"][3]["name"])","input"=>"calibration-feedback:input_1","passive"=>false)]
    append!(links, [Dict("output"=>"$wfs_node:$(port["name"])","input"=>"$sink:input_1","passive"=>false)
                    for (port,sink) in zip(wfs["ports"][2:end],response_names)])
    return Dict{String,Any}("profile"=>"development","execution"=>"complete-frame","authority"=>"none",
        "claim"=>"development-characterization","rate"=>rate,"sources"=>sources,"graphs"=>graphs,"sinks"=>sinks,
        "execution-groups"=>[Dict("name"=>"calibration","nodes"=>[graph["node.name"] for graph in graphs])],
        "properties"=>Dict(),"parameters"=>Dict(),"observations"=>Any[],"links"=>links)
end

function julia_pin_cpu_arguments(argv)
    positions = findall(arg -> arg == "--pin-cpus" || startswith(arg,"--pin-cpus="), argv)
    length(positions) <= 1 || throw(ArgumentError("existing Julia owner has duplicate --pin-cpus options"))
    isempty(positions) && return String[]
    i = only(positions)
    value = argv[i] == "--pin-cpus" ? (i < length(argv) ? argv[i+1] : "") : split(argv[i], "="; limit=2)[2]
    !isempty(value) && !startswith(value,"--") || throw(ArgumentError("existing Julia owner --pin-cpus requires a nonempty value"))
    return ["--pin-cpus",value]
end

function classic_active(graph, parameters, package)
    node = only([node for node in graph["filter.graph"]["nodes"] if node["label"] == "shack-hartmann-image-f32"])
    supplied = [parameter for parameter in parameters if parameter.endpoint == node["name"] * ":active"]
    length(supplied) <= 1 || throw(ArgumentError("Classic has duplicate active parameters"))
    values = if !isempty(supplied)
        read(joinpath(package,"calibration",supplied[1].file))
    else
        configured = get(node["config"],"active",nothing)
        configured !== nothing && all(x -> x isa Bool,configured) || throw(ArgumentError("Classic requires an explicit deployed active selection"))
        UInt8[x ? 1 : 0 for x in configured]
    end
    length(values) == 188 && all(x -> x <= 1,values) && any(x -> x != 0,values) ||
        throw(ArgumentError("Classic active selection requires 188 entries and at least one active ROI"))
    return values
end

function selected_calibration_binary(args)
    option(args,:deployment,false) === true || return nothing
    source = option(args,:calibration_binary)
    source isa AbstractString && isfile(source) && !islink(source) || throw(ArgumentError("--deployment requires an existing --calibration-binary"))
    return realpath(source)
end
function selected_rtc_binary(args)
    option(args,:deployment,false) === true || return nothing
    source = option(args,:rtc_binary)
    source isa AbstractString && isfile(source) && !islink(source) || throw(ArgumentError("--deployment requires an existing --rtc-binary"))
    return realpath(source)
end
function copy_calibration_binary(package,source)
    path = "bin/rtc-calibrate"
    ScienceExport.copy_file(source,joinpath(package,path))
    return Dict("path"=>path,"sha256"=>ScienceExport.sha256(joinpath(package,path)))
end
function copy_rtc_binary(package,source)
    path = "bin/pipewireao-rtc"
    ScienceExport.copy_file(source,joinpath(package,path))
    return Dict("path"=>path,"sha256"=>ScienceExport.sha256(joinpath(package,path)))
end

function _artifacts(package; include_deployment=false)
    result = Dict{String,Any}()
    for (directory,_,files) in walkdir(package)
        for file in sort(files)
            path = joinpath(directory,file)
            islink(path) && throw(ArgumentError("symlink in export package: $path"))
            relative = relpath(path,package)
            relative == "deployment.conf" && !include_deployment && continue
            result[relative] = ScienceExport.sha256(path)
        end
    end
    return result
end

function deployment_descriptor(package,base,specification,records,profile,engine,session,prefix;
                               illumination="lamp",stage="interaction",capture_max_bytes=nothing)
    simulator = only([owner for owner in specification["owners"] if owner["role"] == get(specification,"source-owner",nothing)])
    if engine == "fgn"
        environment = get!(specification,"environment",Dict{String,Any}())
        environment["PIPEWIREAO_RTC_GRAPH_CALIBRATION_WFS"] = "@RUNTIME@/wfs.conf"
        environment["PIPEWIREAO_RTC_GRAPH_CALIBRATION_COMMAND"] = "@RUNTIME@/command.conf"
    end
    argv = copy(simulator["argv"])
    i = findfirst(arg -> endswith(arg,"/hil/simulator.jl"),argv)
    i === nothing && throw(ArgumentError("HIL source owner has no maintained simulator entrypoint"))
    argv[i] = "@PACKAGE@/hil/calibration_owner.jl"
    append!(argv,["--calibration-socket","@RUNTIME@/calibration.sock","--illumination",illumination,"--calibration-stage",stage])
    capture_max_bytes === nothing || append!(argv,["--capture-directory","@RUNTIME@/captured","--capture-max-bytes",string(capture_max_bytes)])
    profile == "classic" && append!(argv,["--wfs-active","@PACKAGE@/calibration/wfs-active.u8"])
    simulator["argv"] = argv
    specification["name"] *= "-calibration"
    specification["session"] = "session.conf.in"
    get!(specification["client"],"simulator","client-simulator.conf.in")
    for file in ("client-simulator.conf.in","core.conf.in")
        source = joinpath(base,file)
        isfile(source) && !isfile(joinpath(package,file)) && ScienceExport.copy_file(source,joinpath(package,file))
    end
    if engine == "jfg"
        old = only([owner for owner in specification["owners"] if owner["role"] == "julia"])
        pins = julia_pin_cpu_arguments(old["argv"])
        placement = pop!(specification["placement"],"julia")
        client = pop!(specification["client"],"julia")
        filter!(owner -> owner["role"] != "julia",specification["owners"])
        for record in records
            role = "julia-" * record["role"]
            owner = Dict{String,Any}("role"=>role,"argv"=>vcat(record["owner_arguments"],pins),"environment"=>deepcopy(old["environment"]))
            for (flag,key) in (("--prepared-event","prepared"),("--connect-request","connect"),("--connect-reply","connected"),("--quit-request","quit"))
                marker = role * "." * key
                owner[key] = marker
                append!(owner["argv"],[flag,"@RUNTIME@/" * marker])
            end
            push!(specification["owners"],owner)
            specification["placement"][role] = deepcopy(placement)
            specification["client"][role] = client
        end
    end
    for client in Set(values(specification["client"]))
        source = joinpath(base,client)
        isfile(source) && !isfile(joinpath(package,client)) && ScienceExport.copy_file(source,joinpath(package,client))
    end
    Common.write_json(joinpath(package,"session.conf.in"),session)
    specification["artifacts"] = _artifacts(package)
    Common.write_json(joinpath(package,"deployment.conf"),specification)
    Deployment.profile(joinpath(package,"deployment.conf"),prefix)
    return specification
end

function export_package(args)
    output = abspath(args.output)
    !ispath(output) && !islink(output) || throw(ArgumentError("export output must be new: $output"))
    calibration_binary = selected_calibration_binary(args)
    rtc_binary = selected_rtc_binary(args)
    base = realpath(args.base_package)
    specification = Deployment.profile(joinpath(base,"deployment.conf"),args.pipewire_prefix)
    provenance = Common.read_json(joinpath(base,"provenance.json"))
    profile,engine = provenance["profile"],provenance["engine"]
    illumination,stage = option(args,:illumination,"lamp"),option(args,:calibration_stage,"interaction")
    capture = option(args,:capture_max_bytes)
    illumination in ("dark","lamp") || throw(ArgumentError("illumination must be dark or lamp"))
    stage isa AbstractString && occursin(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$",stage) || throw(ArgumentError("calibration stage must be a simple 1..64 character identifier"))
    deployment = option(args,:deployment,false) === true
    validate_capture_budget(profile,capture,deployment)
    profile in ("classic","copper") && engine in ("fgn","jfg") && provenance["mode"] == "frame" ||
        throw(ArgumentError("initial calibration requires selected full-frame Classic/Copper FGN/JFG science"))
    session = Deployment.decode(joinpath(base,specification["session"]),args.pipewire_prefix)
    session["execution"] == "complete-frame" || throw(ArgumentError("initial calibration requires complete-frame science"))
    source_path = joinpath(base,"graphs/graph.conf.in")
    source = Deployment.decode(source_path,args.pipewire_prefix)
    name = "revolt-$profile-$engine-initial-calibration"
    graphs = split_graph(source,profile,engine,name)
    mkpath(dirname(output))
    return mktempdir(dirname(output); prefix=".rtc-calibration-export-") do temporary
        package = joinpath(temporary,"package")
        mkpath(joinpath(package,"graphs")); mkpath(joinpath(package,"calibration"))
        calibration_command = rtc_runner = nothing
        if deployment
            isfile(joinpath(base,"hil/calibration_acquisition.jl")) || throw(ArgumentError("calibration deployment descriptor requires calibration_acquisition.jl in the HIL package"))
            ScienceExport.copy_deployment_runtime(package)
            ScienceExport.copy_tree(joinpath(base,"hil"),joinpath(package,"hil"))
            for filename in ("calibration_owner.jl","calibration_acquisition.jl","calibration_server.jl","calibration_client.jl")
                source = joinpath(ROOT,"hil",filename)
                isfile(source) && cp(source,joinpath(package,"hil",filename);force=true)
            end
            mkpath(joinpath(package,"bin"))
            calibration_command = copy_calibration_binary(package,calibration_binary)
            rtc_runner = copy_rtc_binary(package,rtc_binary)
        end
        if engine == "fgn"
            ScienceExport.copy_tree(joinpath(base,"lib"),joinpath(package,"lib"))
        else
            ScienceExport.copy_tree(joinpath(base,"jfg"),joinpath(package,"jfg"))
            transport = joinpath(base,"hil/packages/PipeWireAO")
            isdir(transport) && !isdir(joinpath(package,"hil/packages/PipeWireAO")) && ScienceExport.copy_tree(transport,joinpath(package,"hil/packages/PipeWireAO"))
        end
        records = Any[]; parameters = ScienceExport.Parameter[]
        for role in ("wfs","command")
            graph = graphs[role]
            selected = graph_parameters(graph,provenance["parameters"])
            for parameter in selected
                destination = joinpath(package,"calibration",parameter.file)
                !isfile(destination) && ScienceExport.copy_file(joinpath(base,"calibration",parameter.file),destination)
                ScienceExport.validate_parameter(joinpath(package,"calibration"),parameter)
                if engine == "fgn"
                    parameter.element_type == "F32_LE" || throw(ArgumentError("native startup parameters require F32_LE"))
                    graph["pipewireao.startup-parameter." * parameter.endpoint] = "@PACKAGE@/calibration/" * parameter.file
                end
            end
            append!(parameters,selected)
            relative = "graphs/$role.conf.in"
            write(joinpath(package,relative),spa_json(graph)*"\n")
            record = Dict{String,Any}("role"=>role,"file"=>relative,"node.name"=>graph["node.name"],
                                     "ports"=>boundary_contract(graph,profile,role,engine),
                                     "parameters"=>[ScienceExport.parameter_dict(p) for p in selected])
            if engine == "jfg"
                owner = only([item for item in specification["owners"] if item["role"] == "julia"])
                record["owner_arguments"] = julia_arguments(graph,selected,role,session["rate"],owner["argv"][1])
            end
            push!(records,record)
        end
        retained = Set(node["name"] for graph in values(graphs) for node in graph["filter.graph"]["nodes"])
        if deployment && profile == "classic"
            write(joinpath(package,"calibration/wfs-active.u8"),classic_active(graphs["wfs"],parameters,package))
        end
        metadata = Dict{String,Any}(
            "profile"=>profile,"engine"=>engine,"mode"=>"frame","rate"=>session["rate"],
            "artifact_scope"=>"initial-calibration-graph-assets","operational_acquisition"=>"not-established",
            "requested_commands"=>"absolute prepared physical-actuator figures including reference",
            "additional_system_flat"=>false,"layout"=>"row-major","calibration_stage"=>stage,
            "illumination"=>illumination,"capture_max_payload_bytes"=>capture,
            "source_deployment_sha256"=>ScienceExport.sha256(joinpath(base,"deployment.conf")),
            "source_graph_sha256"=>ScienceExport.sha256(source_path),
            "source_provenance_sha256"=>ScienceExport.sha256(joinpath(base,"provenance.json")),
            "source_provenance"=>provenance,"rtc_revision"=>ScienceExport.revision(normpath(joinpath(ROOT,".."))),
            "exporter_sha256"=>ScienceExport.sha256(@__FILE__),"parameter_initialization"=>"owner-preload",
            "parameters"=>[merge(ScienceExport.parameter_dict(p),Dict("sha256"=>ScienceExport.sha256(joinpath(package,"calibration",p.file)))) for p in parameters],
            "construction_parameters"=>[item for item in get(provenance,"construction_parameters",Any[]) if first(split(item["endpoint"],":";limit=2)) in retained],
            "graphs"=>records,"artifacts"=>_artifacts(package;include_deployment=true))
        if deployment
            metadata["deployment_descriptor"] = "deployment.conf"
            metadata["deployment_entrypoint"] = isfile(joinpath(package,"hil/calibration_owner.jl")) ? "hil/calibration_owner.jl" : "missing: hil/calibration_owner.jl"
            metadata["artifact_scope"] = "initial-calibration-graphs-and-deployment-descriptor"
            metadata["calibration_command"] = calibration_command
            metadata["rtc_runner"] = rtc_runner
        end
        Common.write_json(joinpath(package,"provenance.json"),metadata)
        if deployment
            deployed_session = calibration_session(records,profile,engine,session["rate"])
            deployment_descriptor(package,base,specification,records,profile,engine,deployed_session,args.pipewire_prefix;
                                  illumination,stage,capture_max_bytes=capture)
        end
        mv(package,output)
        return joinpath(output,"provenance.json")
    end
end

function main(argv=ARGS)
    options = Common.cli_arguments(argv; flags=["deployment"], required=["base-package","output","pipewire-prefix"],
        defaults=(illumination="lamp", calibration_stage="interaction"),
        allowed=["calibration-binary","rtc-binary","capture-max-bytes"])
    capture = hasproperty(options,:capture_max_bytes) ? parse(Int,options.capture_max_bytes) : nothing
    args = merge(options,(capture_max_bytes=capture,))
    println(export_package(args))
    return 0
end

end # module
