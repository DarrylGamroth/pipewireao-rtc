# A clocked pupil source owns a physical command, not a camera/HIL exchange.
function pupil_source_configuration(path, document)
    required=("version","mode","plant","command_input","mirror","rate","pacing_rate_hz",
        "backend","device","instrument","rtc_configuration","calibration_identity","prescription_identity")
    InstrumentConfiguration.fields(document,(required...,"applied_command_observation"),required,"pupil source")
    document["mode"]=="pupil-source" || throw(ArgumentError("version 5 requires mode pupil-source"))
    config_path=abspath(path)
    entry=document["plant"]
    InstrumentConfiguration.fields(entry,("definition","graph","settings"),("definition","graph","settings"),"pupil source plant")
    definition=DeploymentConfiguration.relative_asset(dirname(config_path),entry["definition"])
    declaration=InstrumentConfiguration.load_simulation(definition)
    !haskey(declaration.document,"hil") || throw(ArgumentError("pupil source requires a non-HIL graph"))
    configured=InstrumentConfiguration.settings(declaration,entry["settings"])
    selected=InstrumentConfiguration.selected_graph(declaration,entry["graph"])
    selected!="calibration" || throw(ArgumentError("calibration graph cannot be a live pupil source"))
    pupil=InstrumentConfiguration.pupil_output(declaration,configured;simulation_graph=selected)
    pupil===nothing && throw(ArgumentError("pupil source requires a declared scientific pupil output"))
    mirror=text(document["mirror"],"physical mirror")
    mirrors=declaration.instrument.document["deformable_mirrors"]
    haskey(mirrors,mirror) || throw(ArgumentError("pupil source names an unknown physical mirror"))
    mirrors[mirror]["command_scale_m"]==1 || throw(ArgumentError("pupil source physical command must use metres OPD"))
    input=identifier(document["command_input"],"command input")
    graph_document=InstrumentConfiguration.graph_document(declaration,configured;simulation_graph=selected)
    inputs=filter(row->row["name"]==string(input),graph_document["inputs"])
    length(inputs)==1 || throw(ArgumentError("pupil source requires one exact physical command input"))
    endpoint=split(only(inputs)["destination"],'.')
    components=get(declaration.authoring,"components",Dict())
    length(endpoint)==2 && endpoint[2]=="pdm_command" && haskey(components,endpoint[1]) &&
        get(components[endpoint[1]],"template",nothing)=="deformable_mirror" &&
        get(components[endpoint[1]],"mirror",nothing)==mirror ||
        throw(ArgumentError("pupil source command must bind its declared physical mirror component"))
    physical_pupil_route(graph_document,endpoint[1],string(pupil.opd))
    physical=InstrumentConfiguration.json_value(InstrumentConfiguration.physical_definition(declaration.instrument))
    layout=physical["deformable_mirrors"][mirror]["layout"]
    command_count=length(layout["command_positions"])
    command_order=InstrumentDefinition.scientific_identity(InstrumentConfiguration.canonical(Dict(
        "mirror"=>mirror,"units"=>mirrors[mirror]["units"],"layout"=>layout)))
    rate=integer(document["rate"],"rate",1,1_000_000_000)
    period_ns=UInt64(div(1_000_000_000+div(rate,2),rate))
    round(UInt64,Float64(Float32(declaration.document["frame_period_s"]))*1e9)==period_ns ||
        throw(ArgumentError("pupil source cadence differs from its graph"))
    pacing_rate_hz=document["pacing_rate_hz"]
    pacing_period_ns=pacing_period(pacing_rate_hz,rate)
    backend=Symbol(text(document["backend"],"backend"))
    backend in (:cpu,:cuda,:amdgpu) || throw(ArgumentError("unsupported pupil source backend"))
    device=integer(document["device"],"device",0,typemax(Int32))
    (backend===:cpu ? device==0 : backend!==:amdgpu || device>=1) || throw(ArgumentError("invalid pupil source device ordinal"))
    instrument=DeploymentConfiguration.relative_asset(dirname(config_path),document["instrument"])
    rtc_configuration=DeploymentConfiguration.relative_asset(dirname(config_path),document["rtc_configuration"])
    applied_command_observation=boolean(get(document,"applied_command_observation",false),"applied_command_observation")
    return (;version=5,applied_command_observation,mode=:pupil_source,config_path,plant=(;definition,graph=selected,settings=plant_settings(configured)),
        graph=nothing,command_input=input,mirror,command_count,command_order,rate,period_ns,pacing_rate_hz,pacing_period_ns,
        backend,device,instrument,rtc_configuration,pupil_output=true,
        calibration_identity=text(document["calibration_identity"],"calibration identity"),
        prescription_identity=text(document["prescription_identity"],"prescription identity"))
end

function verify_pupil_source_declaration(options)
    IC=InstrumentConfiguration
    actual=InstrumentDefinition.load(options.instrument).document
    actual==IC.json_value(IC.publication(options.rtc_configuration)) ||
        throw(ArgumentError("pupil source publication differs from its RTC declaration"))
    declaration=IC.load_simulation(options.plant.definition)
    rtc=IC.load_rtc(options.rtc_configuration)
    rtc.instrument.path==declaration.instrument.path || throw(ArgumentError("pupil source and RTC physical instruments differ"))
    options.calibration_identity==rtc.document["calibration_identity"] || throw(ArgumentError("pupil source calibration identity differs"))
    options.prescription_identity==IC.prescription_identity(declaration,IC.settings(declaration,options.plant.settings)) ||
        throw(ArgumentError("pupil source prescription identity differs"))
    return nothing
end

# This nominal handoff uses the existing additive pupil operator unchanged.
# More complex propagation between DM and pupil needs separate calibration.
function physical_pupil_route(graph,mirror,pupil)
    # Each named binding is prepared once. Reusing the command binding anywhere
    # else would make another input/state depend on the source's mutable command
    # even when no graph link exposes that dependency.
    command=only(filter(row->row["destination"]==mirror*".pdm_command",graph["inputs"]))
    binding=command["binding"]
    count(row->row["binding"]==binding,graph["inputs"])==1 &&
        all(row->row["binding"]!=binding,get(graph,"parameters",[])) &&
        all(row->row["initial"]!=binding,get(graph,"delayed_links",[])) &&
        all(node->all(!=(binding),values(get(node,"bindings",Dict()))),graph["nodes"]) ||
        throw(ArgumentError("physical command binding must be exclusive to its controlled mirror input"))
    output=only(filter(row->row["name"]==pupil,graph["outputs"]))["source"]
    output==mirror*".surface_opd" && return nothing
    endpoint=split(output,'.')
    length(endpoint)==2 && endpoint[2]=="pupil_opd" || throw(ArgumentError("unsupported physical pupil output route"))
    name=endpoint[1]
    nodes=filter(node->node["name"]==name,graph["nodes"])
    length(nodes)==1 && only(nodes)["type"]=="pupil_opd_composition_f32" ||
        throw(ArgumentError("physical pupil requires the unchanged additive composition operator"))
    links=get(graph,"links",[])
    delayed=get(graph,"delayed_links",[])
    surface=name*".surface_opd"
    incoming=filter(row->row["destination"]==surface,links)
    length(incoming)==1 && only(incoming)["source"]==mirror*".surface_opd" &&
        all(row->row["destination"]!=surface,delayed) &&
        all(row->row["destination"]!=surface,graph["inputs"]) ||
        throw(ArgumentError("physical mirror must directly supply the pupil surface input once"))
    dependencies=vcat(links,delayed)
    seen=Set{String}()
    function independent(node)
        node==mirror && return false
        node in seen && return true
        push!(seen,node)
        return all(row->independent(first(split(row["source"],'.'))),
            filter(row->first(split(row["destination"],'.'))==node,dependencies))
    end
    all(row->independent(first(split(row["source"],'.'))),
        filter(row->row["destination"]==name*".uncompensated_opd",dependencies)) ||
        throw(ArgumentError("facility residual must be independent of the controlled mirror"))
    return nothing
end
