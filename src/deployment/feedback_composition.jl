function validate_feedback end

function composition_source(configuration, path)
    path isa String && !isabspath(path) || throw(ArgumentError("composition authoring paths must be relative"))
    return D.relative_asset(dirname(configuration),path)
end

function component_asset(component, namespace, destination, relative)
    resolved = normpath(joinpath(dirname(destination),relative))
    prefix = "components/"*namespace*"/"
    startswith(resolved,prefix) || throw(ArgumentError("feedback calibration asset must belong to the selected component"))
    return D.relative_asset(component,String(chopprefix(resolved,prefix)))
end

# Retain the same backward dependency closure used by the calibrated frontend.
# The raw endpoint is an explicit input cut, and the residual is an internal output.
function feedback_frontend(document, raw_endpoint, residual_endpoint)
    graph = document["filter.graph"]
    node_name(endpoint) = begin
        terms = split(endpoint,':';keepempty=true)
        length(terms)==2 && all(!isempty,terms) || throw(ArgumentError("invalid frontend endpoint"))
        String(first(terms))
    end
    nodes = Dict(node["name"]=>node for node in graph["nodes"])
    length(nodes)==length(graph["nodes"]) || throw(ArgumentError("duplicate frontend node names"))
    links = get(graph,"links",[])
    selected = Set{String}()
    function visit(name)
        name in selected && return
        haskey(nodes,name) || throw(ArgumentError("frontend endpoint names an absent node"))
        push!(selected,name)
        for link in links
            node_name(link["input"])==name && link["input"]!=raw_endpoint && visit(node_name(link["output"]))
        end
    end
    visit(node_name(residual_endpoint))
    node_name(raw_endpoint) in selected || throw(ArgumentError("raw input does not reach calibrated residual"))
    incoming = Dict(link["input"]=>link for link in links if node_name(link["input"]) in selected)
    inputs = Dict((port isa String ? port : port["endpoint"])=>port for port in graph["inputs"]
        if node_name(port isa String ? port : port["endpoint"]) in selected)
    return (;nodes=Dict(name=>nodes[name] for name in selected),links=incoming,inputs)
end

"""
    prepare_feedback(base, component, fresh_output, recipe; prefix)

Prepare explicitly authored receiving graph, FITS bindings and physical-offset
contract, then compose two sealed built applications. The recipe supplies the
owner role/thread count and complete additional arguments, cross-application
links, component role map and every selected template/output path. The component
must already contain an accepted generated calibration selection and zero command.
No process is launched or installed.
"""
function prepare_feedback(base::AbstractString,component::AbstractString,destination::AbstractString,
        recipe::AbstractString;prefix::AbstractString,profile::Union{Nothing,AbstractString}=nothing)
    recipe = checked_path(recipe)
    document = Common.read_yaml(recipe)
    required = Set(["version","namespace","roles","links","calibration","receiver","owner_arguments","profile"])
    document isa AbstractDict && Set(keys(document))==required && document["version"]===1 ||
        throw(ArgumentError("invalid feedback composition recipe"))
    mainroot, main = sealed_application(base,prefix)
    componentroot, extra = sealed_application(component,prefix)
    namespace = document["namespace"]
    profilepath = profile===nothing ? composition_source(recipe,document["profile"]) : checked_path(profile)
    selected_profile = Common.read_yaml(profilepath)
    selected_profile isa AbstractDict && Set(keys(selected_profile))==Set(["version","backend","device","pacing_rate_hz","silence_ns"]) &&
        selected_profile["version"]===1 || throw(ArgumentError("invalid explicit feedback preparation profile"))
    selected_profile["backend"] in ("cpu","amdgpu") && typeof(selected_profile["device"])===Int &&
        (selected_profile["backend"]=="cpu" ? selected_profile["device"]==0 : selected_profile["device"]>=1) ||
        throw(ArgumentError("feedback preparation requires an explicit CPU or AMDGPU device"))
    component_simulation = D.decode(D.relative_asset(componentroot,"simulation.conf"),prefix)
    component_simulation["backend"]==selected_profile["backend"] && component_simulation["device"]==selected_profile["device"] ||
        throw(ArgumentError("component backend differs from selected feedback preparation profile"))
    selected = D.relative_asset(componentroot,document["calibration"]*"/calibration.yaml")
    selection = Common.read_yaml(D.relative_asset(componentroot,document["calibration"]*"/selection.yaml"))
    index = Common.read_yaml(selected)
    get(index,"version",nothing)===1 && get(index,"kind",nothing)=="optical-calibration-index" ||
        throw(ArgumentError("feedback requires optical calibration index version 1"))
    branches = index["branches"]
    branches isa AbstractDict && 1 <= length(branches) <= 16 &&
        all(name->name isa String && occursin(r"^[a-z][a-z0-9-]{0,31}$",name) && branches[name]["path"]==name,keys(branches)) ||
        throw(ArgumentError("indexed branches require bounded names and their own bundle directories"))
    selection["calibration_index_sha256"]==Common.sha256_file(selected) &&
        selection["calibration_identity"]==index["calibration_identity"] || throw(ArgumentError("component calibration selection mismatch"))
    firstbranch = first(sort!(collect(keys(index["branches"]))))
    Calibration = getfield(parentmodule(@__MODULE__),:InstrumentCalibration)
    first_result = D.relative_asset(componentroot,document["calibration"]*"/"*firstbranch*"/result.yaml")
    bundle = Calibration.read_bundle(dirname(first_result))
    bundle.report["status"]=="accepted" && bundle.report["built_application_calibration"]===true ||
        throw(ArgumentError("feedback composition requires an accepted built-application calibration"))
    receiver = document["receiver"]
    fields = Set(["owner","mirror","rtc_configuration","simulation_configuration","graph_template","graph",
        "parameters_append","parameters","template","configuration"])
    receiver isa AbstractDict && Set(keys(receiver))==fields || throw(ArgumentError("invalid receiving composition declaration"))
    role = receiver["owner"]
    owner = only(filter(owner->owner["role"]==role,main["owners"]))
    rtc = InstrumentConfiguration.load_rtc(D.relative_asset(mainroot,receiver["rtc_configuration"]))
    upstream = D.decode(D.relative_asset(mainroot,receiver["simulation_configuration"]),prefix)
    upstream["backend"]==selected_profile["backend"] && upstream["device"]==selected_profile["device"] ||
        throw(ArgumentError("receiving source backend differs from selected feedback preparation profile"))
    paced = deepcopy(upstream)
    AOSOwner.pacing_period(selected_profile["pacing_rate_hz"],upstream["rate"])
    paced["pacing_rate_hz"] = selected_profile["pacing_rate_hz"]
    bundle.report["upstream_prescription_identity"]==upstream["prescription_identity"] ||
        throw(ArgumentError("calibration upstream prescription differs from receiving application"))
    for (name,entry) in index["branches"]
        reportpath = D.relative_asset(componentroot,document["calibration"]*"/"*entry["path"]*"/result.yaml")
        Common.sha256_file(reportpath)==entry["result_sha256"] || throw(ArgumentError("indexed branch result hash mismatch"))
        branch = Calibration.read_bundle(dirname(reportpath))
        report = branch.report
        report["status"]=="accepted" && get(report,"built_application_calibration",false)===true &&
            get(report,"diagnostic",true)===false && get(report,"deployable",false)===true &&
            get(get(report,"held_out",Dict()),"accepted",false)===true &&
            report["calibration_identity"]==index["calibration_identity"] &&
            report["branch"]==name &&
            report["upstream_prescription_identity"]==upstream["prescription_identity"] &&
            report["branches"][name]["accepted"]===true || throw(ArgumentError("selected branch is not a deployable accepted matched calibration"))
        for (key,descriptor) in index["physical_projection"]
            report["artifact_sha256"][key*".fits"]==descriptor["sha256"] ||
                throw(ArgumentError("selected branches differ from shared physical calibration"))
        end
        report["upstream_reference"]==bundle.report["upstream_reference"] ||
            throw(ArgumentError("selected branches do not share the same calibrated frontend"))
    end
    reference = bundle.report["upstream_reference"]
    executed = InstrumentConfiguration.load_simulation(D.relative_asset(mainroot,upstream["plant"]["definition"]))
    effective = InstrumentConfiguration.settings(executed,get(upstream["plant"],"settings",Dict()))
    InstrumentDefinition.scientific_identity(InstrumentConfiguration.canonical(effective))==reference["effective_settings_identity"] ||
        throw(ArgumentError("receiving effective simulation settings differ from reference calibration"))
    get(effective,"adc",Dict())==reference["adc_settings"] ||
        throw(ArgumentError("receiving ADC settings differ from reference calibration"))
    execution_graph = get(upstream["plant"],"graph","production")
    execution_graph==reference["execution_graph"] || throw(ArgumentError("receiving simulator graph selection differs from calibration"))
    if InstrumentConfiguration.graph_requires_proper(executed,effective;simulation_graph=execution_graph)
        Base.require(Main,:AdaptiveOpticsSim);Base.require(Main,:AdaptiveOpticsSimPipeWireHIL);Base.require(Main,:Proper)
    end
    for (key,keywords) in (("execution_graph_identity",(;simulation_graph=execution_graph)),("calibration_graph_identity",(;calibration=true)))
        graph = Base.invokelatest(InstrumentConfiguration.graph_document,executed,effective;keywords...)
        InstrumentDefinition.scientific_identity(InstrumentConfiguration.canonical(graph))==reference[key] ||
            throw(ArgumentError("receiving simulator graph differs from reference calibration"))
    end
    reference["source_graph_sha256"]==Common.sha256_file(D.relative_asset(mainroot,receiver["graph"])) ||
        throw(ArgumentError("calibration reference frontend differs from receiving graph"))
    parameters = D.decode(D.relative_asset(mainroot,receiver["parameters"]),prefix)
    for (name,hash) in merge(reference["parameter_sha256"],reference["baseline_parameter_sha256"])
        row = only(filter(row->row["port"]==name,parameters["parameters"]))
        Common.sha256_file(D.relative_asset(mainroot,normpath(joinpath(dirname(receiver["parameters"]),row["path"]))))==hash ||
            throw(ArgumentError("receiving reference parameter changed: $name"))
    end
    physical = InstrumentConfiguration.json_value(InstrumentConfiguration.physical_definition(rtc.instrument))
    mirror = physical["deformable_mirrors"][receiver["mirror"]]
    command_order = InstrumentDefinition.scientific_identity(InstrumentConfiguration.canonical(Dict(
        "mirror"=>receiver["mirror"],"units"=>rtc.instrument.document["deformable_mirrors"][receiver["mirror"]]["units"],"layout"=>mirror["layout"])))
    context = graph_context(physical;dimensions=rtc.document["dimensions"],
        mirror_controls=rtc.controls["deformable_mirrors"],calibration=rtc.calibration)
    shared = index["physical_projection"]
    context["calibration"]["cal2"] = Dict("calibration_identity"=>index["calibration_identity"],
        "command_order"=>command_order,"projection_sha256"=>shared["command-projection"]["sha256"],
        "inverse_sha256"=>shared["physical-to-modes"]["sha256"],"reference_sha256"=>shared["modes-to-reference"]["sha256"])
    graphpath = composition_source(recipe,receiver["graph_template"])
    graph = resolve_graph_configuration(D.decode(graphpath,prefix),context)
    original = D.decode(D.relative_asset(mainroot,receiver["graph"]),prefix)
    feedback_frontend(original,reference["raw_endpoint"],reference["residual_endpoint"])==
        feedback_frontend(graph,reference["raw_endpoint"],reference["residual_endpoint"]) ||
        throw(ArgumentError("receiving graph changes the calibrated frontend dependency closure"))
    contract = Common.configuration_value(Common.read_yaml(composition_source(recipe,receiver["template"])),context)
    contract["reference_sign"]==reference["reference_sign"] || throw(ArgumentError("receiving reference sign differs from calibration"))
    Set(keys(contract["branches"]))==Set(keys(index["branches"])) || throw(ArgumentError("receiving branch authority differs from calibration"))
    Set(keys(selected_profile["silence_ns"]))==Set(keys(contract["branches"])) ||
        throw(ArgumentError("feedback profile must explicitly name every branch silence limit"))
    for (name,limit) in selected_profile["silence_ns"]
        contract["branches"][name]["silence_ns"] = limit
    end
    matrices = Dict{String,Matrix{Float32}}()
    for (field,name) in (("projection","command-projection"),("inverse","physical-to-modes"),("reference","modes-to-reference"))
        descriptor = contract[field]
        path = component_asset(componentroot,namespace,receiver["configuration"],descriptor["path"])
        expected = D.relative_asset(componentroot,document["calibration"]*"/"*shared[name]["path"])
        path==expected && descriptor["sha256"]==Common.sha256_file(path) || throw(ArgumentError("receiving calibration mapping differs from accepted index"))
        prepared = getfield(parentmodule(@__MODULE__),:Artifacts).prepare(
            getfield(parentmodule(@__MODULE__),:Artifacts).FITSArtifact(path;axes=descriptor["axes"]),Float32,Tuple(descriptor["shape"]))
        matrices[field] = prepared.data
    end
    command_count = length(mirror["layout"]["command_positions"])
    size(matrices["projection"],1)==command_count || throw(DimensionMismatch("projection does not match declared physical command order"))
    Offsets = getfield(parentmodule(@__MODULE__),:PhysicalOffsets)
    calibrations = map(sort!(collect(keys(contract["branches"])))) do name
        branch = contract["branches"][name]
        branch["modes"]==bundle.report["recipe"]["branch_modes"][name] || throw(ArgumentError("branch mode authority differs from calibration"))
        Offsets.Calibration(;identity=contract["calibration_identity"],schema=branch["schema"],command_order,
            projection=matrices["projection"],inverse=matrices["inverse"],modes=branch["modes"],
            command_limit_m=branch["command_limit_m"],coefficient_limit_m=branch["coefficient_limit_m"],
            max_age_ns=branch["max_age_ns"],silence_ns=branch["silence_ns"])
    end
    names = Tuple(Symbol.(sort!(collect(keys(contract["branches"])))))
    Offsets.Receiver(NamedTuple{names}(Tuple(calibrations));command_limit_m=contract["command_limit_m"])
    additions = Common.read_yaml(composition_source(recipe,receiver["parameters_append"]))
    Set(keys(additions))==Set(["parameters"]) || throw(ArgumentError("parameter additions require the standard FITS bindings document"))
    append!(parameters["parameters"],additions["parameters"])
    ports = [row["port"] for row in parameters["parameters"]]
    length(unique(ports))==length(ports) || throw(ArgumentError("feedback FITS parameter names collide"))
    zero = selection["zero_command"]
    zeropath = D.relative_asset(componentroot,document["calibration"]*"/"*zero["path"])
    Common.sha256_file(zeropath)==zero["sha256"] && zero["shape"]==[command_count] || throw(ArgumentError("zero physical command differs from selected calibration"))
    zerorow = only(filter(row->row["port"]==contract["parameter"],additions["parameters"]))
    component_asset(componentroot,namespace,receiver["parameters"],zerorow["path"])==zeropath || throw(ArgumentError("zero offset FITS binding differs from calibration selection"))
    Artifact = getfield(parentmodule(@__MODULE__),:Artifacts)
    all(iszero,Artifact.prepare(Artifact.FITSArtifact(zeropath),Float32,(command_count,)).data) ||
        throw(ArgumentError("startup physical offset must be exactly zero"))
    for (field,endpoint) in (("inverse","physical-to-modes"),("reference","modes-to-reference"))
        input = only(filter(input->input["endpoint"]==contract["algorithm"]*":"*endpoint,graph["filter.graph"]["inputs"]))
        row = only(filter(row->row["port"]==input["name"],additions["parameters"]))
        component_asset(componentroot,namespace,receiver["parameters"],row["path"])==
            component_asset(componentroot,namespace,receiver["configuration"],contract[field]["path"]) ||
            throw(ArgumentError("receiving graph factor differs from accepted contract"))
    end
    arguments = document["owner_arguments"]
    Set(keys(arguments))==Set(["role","threads","append"]) && arguments["role"]==role || throw(ArgumentError("explicit owner argument preparation requires role, threads and append"))
    arguments["threads"] isa String && something(tryparse(Int,first(split(arguments["threads"],','))),0)>=3 ||
        throw(ArgumentError("receiving graph, bootstrap monitor and offset pump require at least three default Julia threads"))
    argv = copy(owner["argv"])
    position = only(findall(arg->startswith(arg,"--threads="),argv))
    argv[position] = "--threads="*arguments["threads"]
    append!(argv,arguments["append"])
    expected_arguments = ["--physical-offsets","@PACKAGE@/"*receiver["configuration"]]
    arguments["append"]==expected_arguments || throw(ArgumentError("physical offsets argument must name the explicitly selected receiving contract"))
    sinks = [Dict("node.name"=>branch["node_name"],"ownership"=>"external","ports"=>[
        Dict("name"=>"input_1","direction"=>"input","shape"=>[command_count],"element-type"=>"F32_LE",
            "schema"=>branch["schema"],"layout"=>"ROW_MAJOR")]) for branch in values(contract["branches"])]
    output = checked_path(destination)
    !ispath(output) || throw(ArgumentError("feedback output must be fresh"))
    mkpath(dirname(output))
    mktempdir(dirname(output);prefix=".feedback-") do temporary
        graphfile = joinpath(temporary,"graph.conf");ScienceExport.write_spa_config(graphfile,graph)
        parameterfile = joinpath(temporary,"parameters.conf");Common.write_json(parameterfile,parameters)
        receiverfile = joinpath(temporary,"receiver.yaml");Common.write_yaml(receiverfile,contract;
            header="Generated from explicit receiving contract and accepted optical calibration.")
        recipefile = joinpath(temporary,"feedback-recipe.yaml");cp(recipe,recipefile)
        profilefile = joinpath(temporary,"feedback-profile.yaml");cp(profilepath,profilefile)
        simulationfile = joinpath(temporary,"simulation.conf");Common.write_json(simulationfile,paced)
        overrides = Dict(receiver["graph"]=>graphfile,receiver["parameters"]=>parameterfile,
            receiver["configuration"]=>receiverfile,"rtc/feedback-composition.yaml"=>recipefile,
            "rtc/feedback-profile.yaml"=>profilefile,receiver["simulation_configuration"]=>simulationfile)
        staged = compose(mainroot,componentroot,joinpath(temporary,"application");namespace,roles=document["roles"],links=document["links"],
            overrides,prefix,owner_arguments=Dict(role=>argv),sinks,node_owners=Dict(sink["node.name"]=>role for sink in sinks))
        Base.require(Main,:FilterGraphIsland)
        Base.require(Main,:AdaptiveOpticsSimPipeWireHIL)
        Base.invokelatest(validate_feedback,staged,receiver["graph"],receiver["parameters"],receiver["configuration"])
        mv(staged,output)
        return output
    end
end
