# Opt-in startup/lifecycle evidence for an accepted, sealed GPI2 + CAL2 application.
# Including this file performs no installation, connection, service or GPU action.
module ManagedSessionCAL2
using PipeWireAO, PipeWireAORTC
include("managed_session_lifecycle.jl")
const M = ManagedSessionLifecycle
const R, C, D, W = PipeWireAORTC, M.C, M.D, M.W
const E = R.InstrumentExport
const USAGE = "usage: managed_session_cal2.jl APPLICATION FRESH_STAGE PREFIX [--preflight] [--samples N] [--timeout-seconds N]"
require(value, message) = value || throw(ArgumentError(message))

function argument(argv, key)
    positions = findall(value -> value==key || startswith(value,key*"="),argv)
    length(positions)==1 || throw(ArgumentError("owner must declare exactly one $key"))
    index = only(positions)
    argv[index]==key && require(index<length(argv),"owner argument $key requires a value")
    return String(argv[index]==key ? argv[index+1] : last(split(argv[index],'=';limit=2)))
end
function asset(application, value)
    require(startswith(value,"@PACKAGE@/"),"owner asset must be package-relative")
    return D.relative_asset(application,String(chopprefix(value,"@PACKAGE@/")))
end
endpoint(value) = begin
    terms=split(value,':';keepempty=true)
    require(length(terms)==2 && all(!isempty,terms),"expected exact NODE:PORT endpoint")
    String.(terms)
end
capture_node(objects, name) = only(filter(object ->
    get(object,"type",nothing)=="PipeWire:Interface:Node" &&
    get(get(get(object,"info",Dict()),"props",Dict()),"node.name",nothing)==name, objects))
function declared_port(session, name, direction)
    node, port=endpoint(name)
    entries=[entry for section in ("sources","graphs","sinks") for entry in session[section]
        if entry["node.name"]==node]
    entry=only(entries)
    return only(filter(value->value["name"]==port && value["direction"]==direction,entry["ports"]))
end
has_schema(contract) = get(contract,"schema",nothing) isa AbstractString && !isempty(strip(contract["schema"]))
function product(name, output, contract, duration, mapping; model_time=true, priming_exposures=0, acquisition_version=2, chopping=nothing)
    node, port=endpoint(output)
    require(has_schema(contract),"CAL2 selector requires an explicit native export schema: $name")
    require(contract["element-type"]=="F32_LE" && get(contract,"layout","ROW_MAJOR")=="ROW_MAJOR",
        "CAL2 selector requires an explicit row-major Float32 export: $name")
    shape=Tuple(Int.(contract["shape"]))
    require(!isempty(shape) && all(>(0),shape) && prod(shape)<=2*1024^2,"unsupported bounded product shape")
    rate=get(contract,"rate",nothing)
    fraction=rate===nothing ? nothing : SPA.Fraction(parse.(UInt32,split(rate,'/'))...)
    require(priming_exposures in (0,1) && (model_time || priming_exposures==0),"unsupported capture priming")
    return (;name,node,port,role=mapping[node],shape,schema=String(contract["schema"]),rate=fraction,duration=Int64(duration),model_time,priming_exposures,acquisition_version,chopping)
end

# The exporter's graph_port_contracts deliberately retains only shape and type.
# Capture must use the same prepared AlgorithmFormat.schema published by FGPW.
function graph_output_contracts(path)
    FGI=Base.require(Main,:FilterGraphIsland)
    JFG=Base.require(Main,:JuliaFilterGraph)
    options=Base.invokelatest(FGI.parse_arguments,["--graph",String(path),"--check","--execution","complete-frame"])
    graph=Base.invokelatest(FGI.prepare_service_graph,options)
    try
        formats=Base.invokelatest(JFG.output_formats,graph)
        return Dict("outputs"=>Dict(string(name)=>merge(E.port_contract(format),
            Dict("schema"=>format.schema)) for (name,format) in pairs(formats)))
    finally
        Base.invokelatest(FGI.close_execution,graph)
    end
end

function require_return_schema(native, declared, receiver)
    require(has_schema(native) && has_schema(declared) && has_schema(receiver) &&
        native["schema"]==declared["schema"]==receiver["schema"],
        "CAL2 native output, session declaration and receiver branch schemas differ")
    return nothing
end

function correction_control(graph, property)
    node, key = endpoint(property)
    integrator = only(filter(entry->entry["name"]==node,graph["filter.graph"]["nodes"]))
    require(key=="closed" && get(get(integrator,"props",Dict()),key,nothing)===false,
        "lifecycle selector requires CAL2 correction initially open; closed-loop evidence is separate")
    return (;graph=String(graph["node.name"]),node,property=String(property))
end

function require_open_snapshot(control, properties, generation)
    result = properties["result"]
    value = get(result["properties"],control.property,Dict())
    require(result["graph"]==control.graph && get(value,"type",nothing)=="bool" && get(value,"value",nothing)===false,
        "native CAL2 correction is not confirmed open")
    result = generation["result"]
    require(result["graph"]==control.graph && result["node"]==control.node && result["requested"]==result["active"],
        "CAL2 correction has an unadopted property transaction")
    return nothing
end

function reference_products!(products, missing, graph, contracts, receiver, period, mapping)
    algorithm = receiver["algorithm"]
    input = only(filter(link->link["input"]==algorithm*":reconstructed-residual",graph["filter.graph"]["links"]))
    for (name,endpoint) in (("adopted-offset",algorithm*":physical-offset"),
            ("reference-before",input["output"]),("reference-after",algorithm*":compensated-residual"))
        exports = filter(port->port["endpoint"]==endpoint,graph["filter.graph"]["outputs"])
        if length(exports)==1
            port = only(exports)["name"]
            push!(products,product(name,graph["node.name"]*":"*port,contracts["outputs"][port],period,mapping;model_time=false))
        else
            push!(missing,"No unique exported $endpoint; receiving-frame $name cannot be observed.")
        end
    end
    return nothing
end

function modal_product!(products, missing, name, graph, contracts, control, duration, mapping; priming_exposures=0, acquisition_version=2)
    input = only(filter(link->link["input"]==control.node*":input",graph["filter.graph"]["links"]))
    exports = filter(port->port["endpoint"]==input["output"],graph["filter.graph"]["outputs"])
    if length(exports)==1
        port = only(exports)["name"]
        contract=contracts["outputs"][port]
        if has_schema(contract)
            push!(products,product(name*"-modal-residual",graph["node.name"]*":"*port,contract,duration,mapping;priming_exposures,acquisition_version))
        else
            push!(missing,"No explicit native schema for $(input["output"]); $name modal residual cannot be observed.")
        end
    else
        push!(missing,"No unique exported $(input["output"]); $name modal residual cannot be observed.")
    end
    return nothing
end

function selected_calibration(component, optical)
    configuration=get(optical,"rtc_configuration",nothing)
    require(configuration isa String && normpath(configuration)==configuration &&
        startswith(configuration,"generated/") && basename(configuration)=="rtc.yaml" &&
        dirname(configuration)!="generated",
        "CAL2 capture requires an explicit generated calibration RTC configuration")
    D.relative_asset(component,configuration)
    calibration=dirname(configuration)
    selection=C.read_yaml(D.relative_asset(component,calibration*"/selection.yaml"))
    indexpath=D.relative_asset(component,calibration*"/calibration.yaml")
    index=C.read_yaml(indexpath)
    require(selection["calibration_index_sha256"]==C.sha256_file(indexpath) &&
        selection["calibration_identity"]==index["calibration_identity"],"selected calibration index differs")
    E.validate_selected_rtc(component,calibration,selection,index,optical)
    return (;calibration,selection,index)
end

"Cold preflight: accepts real deployable selections only, and never starts a core."
function preflight(application, prefix; sample_count=40, timeout_seconds=nothing)
    application,spec=E.sealed_application(realpath(application),prefix)
    D.profile(joinpath(application,"deployment.conf"),prefix)
    require(D.registered_application(spec),"a sealed registered application is required")
    roles=Set(owner["role"] for owner in spec["owners"])
    expected=Set(["cal2-optics","cal2-llowfs","cal2-scc"])
    require(expected ⊆ roles && spec["source-owner"] ∉ expected,"CAL2 native owner roles differ from the normal composition")
    require("cal2-optics" in get(spec,"auxiliary-source-owners",[]),"CAL2 optics must be an auxiliary source")
    receipt=C.read_yaml(D.relative_asset(application,"composition/receipt.yaml"))
    require(receipt["namespace"]=="cal2" && Set(values(receipt["roles"]))==expected,"composition role receipt differs")
    for owner in spec["owners"]
        require(D.native_bootstrap(owner),"normal cohort requires existing native owner bootstrap")
    end
    session=D.decode(D.relative_asset(application,spec["session"]),prefix)
    require(session["profile"]=="development" && session["authority"]=="none","development authority=none is required")
    mapping=spec["node-owners"]
    primary=only(filter(owner->owner["role"]==spec["source-owner"],spec["owners"]))
    auxiliary=only(filter(owner->owner["role"]=="cal2-optics",spec["owners"]))
    primary_config=asset(application,argument(primary["argv"],"--config"))
    auxiliary_config=asset(application,argument(auxiliary["argv"],"--config"))
    upstream=D.decode(primary_config,prefix)
    optical=D.decode(auxiliary_config,prefix)
    require(upstream["version"]==3 && get(upstream,"pupil_output",false),"primary source must export its scientific pupil")
    require(optical["version"]==4 && optical["mode"]=="external-pupil","CAL2 must use the mirror-free external-pupil owner")
    require(Set(keys(optical["sensor_nodes"]))==Set(["llowfs","scc"]),"expected independent SCC and LLOWFS branches")
    component=dirname(auxiliary_config)
    (;calibration,index)=selected_calibration(component,optical)
    require(Set(keys(index["branches"]))==Set(["llowfs","scc"]),"selected branch index differs")
    for name in ("llowfs","scc")
        entry=index["branches"][name]
        require(entry["path"]==name,"branch index must retain its own bundle directory")
        path=D.relative_asset(component,calibration*"/"*name*"/result.yaml")
        require(C.sha256_file(path)==entry["result_sha256"],"branch result hash differs")
        report=R.InstrumentCalibration.read_bundle(dirname(path)).report
        require(report["status"]=="accepted" && report["branch"]==name &&
            get(report,"deployable",false)===true && get(report,"diagnostic",true)===false &&
            report["held_out"]["accepted"]===true && report["branches"][name]["accepted"]===true &&
            report["calibration_identity"]==index["calibration_identity"],"bootstrap/diagnostic/rejected calibration is not admitted")
        E.validate_reference_backend(report["upstream_reference"],upstream)
        for (key,descriptor) in index["physical_projection"]
            require(report["artifact_sha256"][key*".fits"]==descriptor["sha256"],"selected shared physical factors differ")
        end
    end
    receiving=only(filter(owner->"--physical-offsets" in owner["argv"],spec["owners"]))
    receiver_path=asset(application,argument(receiving["argv"],"--physical-offsets"))
    receiver=C.read_yaml(receiver_path)
    require(receiver["calibration_identity"]==index["calibration_identity"],"receiving calibration differs")
    require(parse(Int,first(split(argument(receiving["argv"],"--threads"),',')))>=3,"receiver requires three default Julia threads")
    graph_path=asset(application,argument(receiving["argv"],"--graph"))
    binding_path=asset(application,argument(receiving["argv"],"--fits-bindings"))
    Base.require(Main,:FilterGraphIsland)
    Base.require(Main,:AdaptiveOpticsSimPipeWireHIL)
    Base.invokelatest(E.validate_feedback,application,relpath(graph_path,application),relpath(binding_path,application),relpath(receiver_path,application))
    contracts=graph_output_contracts(graph_path)
    graph=D.decode(graph_path,prefix)
    graph_node=graph["node.name"]
    require(mapping[graph_node]==receiving["role"],"receiving graph owner differs")
    pupil_link=only(filter(link->link["input"]==optical["pupil_node"]*":input_1",session["links"]))
    pupil_node=first(endpoint(pupil_link["output"]))
    require(mapping[pupil_node]==spec["source-owner"],"pupil producer is not the primary source")
    period=round(Int64,1e9/upstream["rate"])
    require(upstream["exposure_ns"]==period,"selector requires completely covered primary model intervals")
    products=Any[product("pupil",pupil_link["output"],declared_port(session,pupil_link["output"],"output"),period,mapping)]
    declaration=R.InstrumentConfiguration.load_simulation(D.relative_asset(component,optical["plant"]["definition"]))
    durations=Dict{String,Int64}()
    controls=Any[]
    missing=String["Receiver-specific arm/disarm and rejection counters have no declared native observation export; generic parameter generations are captured separately.",
        "Correction-open exact-zero startup cannot establish nonzero contribution acceptance or transaction adoption."]
    for name in ("llowfs","scc")
        sensor=declaration.instrument.document["optical_paths"][name]["sensor"]
        duration=round(Int64,1e9*declaration.instrument.document["wavefront_sensors"][sensor]["acquisition"]["exposure_duration_s"])
        durations[name]=duration
        output=optical["sensor_nodes"][name]*":output_1"
        require(mapping[optical["sensor_nodes"][name]]=="cal2-optics","sensor owner differs")
        chopping = get(get(optical["plant"],"chopping",Dict()),name,nothing)
        acquisition_version = chopping === nothing ? 2 : 3
        push!(products,product(name,output,declared_port(session,output,"output"),duration,mapping;acquisition_version,chopping))
        branch=receiver["branches"][name]
        link=only(filter(link->link["input"]==branch["node_name"]*":input_1",session["links"]))
        require(mapping[first(endpoint(link["output"]))]=="cal2-"*name,"return stream owner differs")
        controller=only(filter(owner->owner["role"]=="cal2-"*name,spec["owners"]))
        controller_path=asset(application,argument(controller["argv"],"--graph"))
        controller_graph=D.decode(controller_path,prefix)
        control=correction_control(controller_graph,argument(controller["argv"],"--correction-property"))
        push!(controls,control)
        branch_contracts=graph_output_contracts(controller_path)
        declared=declared_port(session,link["output"],"output")
        require_return_schema(branch_contracts["outputs"][last(endpoint(link["output"]))],declared,branch)
        # Chopped controllers suppress the first exposure while the pair primes.
        priming_exposures = haskey(get(optical["plant"],"chopping",Dict()),name) ? 1 : 0
        push!(products,product(name*"-offset",link["output"],declared,duration,mapping;priming_exposures,acquisition_version))
        modal_product!(products,missing,name,controller_graph,branch_contracts,control,duration,mapping;priming_exposures,acquisition_version)
    end
    physical=receiver["clock_output"]
    push!(products,product("physical",graph_node*":"*physical,contracts["outputs"][physical],period,mapping;model_time=false))
    reference_products!(products,missing,graph,contracts,receiver,period,mapping)
    require(40<=sample_count<=128 && sample_count*period % durations["scc"]==0,"sample count must be in40:128 and cover whole SCC exposures")
    pacing=upstream["pacing_rate_hz"]
    require(pacing isa Real && !(pacing isa Bool) && isfinite(pacing) && pacing>0,"explicit positive wall pacing is required")
    timeout=timeout_seconds===nothing ? 90+2*sample_count/pacing : Float64(timeout_seconds)
    require(isfinite(timeout) && sample_count/pacing<timeout<=3600,"epoch timeout must exceed paced collection and be at most3600seconds")
    return (;application,spec,session,primary,auxiliary,products=Tuple(products),period,sample_count,timeout,
        pacing,calibration_identity=index["calibration_identity"],controls=Tuple(controls),
        reference=(graph=graph_node,node=receiver["algorithm"]),missing)
end

mutable struct Samples
    records::Vector{Dict{String,Any}}
    first::Array{Float32}
    last::Array{Float32}
    history::Union{Nothing,Vector{Vector{Float32}}}
    bound::Int
end
Samples(product,bound)=Samples(Dict{String,Any}[],zeros(Float32,product.shape),zeros(Float32,product.shape),
    length(product.shape)==1 ? Vector{Float32}[] : nothing,bound)
identity_record(value)=Dict("domain"=>bytes2hex(collect(value.domain.bytes)),"generation"=>value.generation,"sequence"=>value.sequence)
function covered_count(product, covered)
    require(covered % product.duration==0,"coverage must end on an exposure boundary")
    count = div(covered,product.duration)-product.priming_exposures
    require(count>0,"coverage must include a completed controller measurement")
    return count
end

function record!(samples, values, receipt, duration; model_time=true, priming_exposures=0, name="unnamed")
    require(length(samples.records)<samples.bound,"bounded capture exhausted before completion")
    require(all(isfinite,values) && receipt.duration==duration && receipt.pts>=0 && receipt.lost_samples==0,"invalid/lost model interval or payload")
    identity=identity_record(receipt.identity)
    require(identity["sequence"]>=1,"acquisition sequence must be positive")
    # GPI camera Headers use publication time; its declared complete acquisition
    # cadence and sequence locate model coverage. Preserve the original Header.
    model_pts = model_time ? receipt.pts : Base.checked_mul(Int64(identity["sequence"]-1),duration)
    if isempty(samples.records)
        require(identity["sequence"]==priming_exposures+1 && model_pts==priming_exposures*duration,
            "new acquisition did not start at its declared first complete measurement")
        copyto!(samples.first,values)
    else
        previous=last(samples.records)
        (identity["domain"]==previous["domain"] && identity["generation"]==previous["generation"] &&
            identity["sequence"]==previous["sequence"]+1 && model_pts==previous["model_pts"]+previous["duration"] &&
            receipt.pts>=previous["pts"]) || throw(ArgumentError(
            "acquisition gap or changed cohort for $name: "*
            "previous=(domain=$(previous["domain"]), generation=$(previous["generation"]), "*
            "sequence=$(previous["sequence"]), pts=$(previous["pts"]), model_pts=$(previous["model_pts"]), duration=$(previous["duration"])); "*
            "rejected=(domain=$(identity["domain"]), generation=$(identity["generation"]), sequence=$(identity["sequence"]), "*
            "pts=$(receipt.pts), duration=$(receipt.duration), lost_samples=$(receipt.lost_samples), "*
            "trigger_state=$(receipt.trigger_state), model_pts=$model_pts)"))
    end
    push!(samples.records,merge(identity,Dict("pts"=>receipt.pts,"model_pts"=>model_pts,"duration"=>receipt.duration,
        "trigger_state"=>string(receipt.trigger_state))))
    copyto!(samples.last,values)
    samples.history===nothing || push!(samples.history,copy(vec(values)))
    return nothing
end

function require_chopped_exposure(product, receipt)
    selection = product.chopping
    selection === nothing && return nothing
    require(receipt.duration==product.duration && receipt.pts>=0 && receipt.pts % product.duration==0,
        "chopped sensor exposure does not occupy its declared model window")
    first_fringed = selection["initial_phase"] == "fringed"
    fringed = iseven(div(receipt.pts,product.duration)) == first_fringed
    expected = fringed == selection["trigger_high_is_fringed"] ?
        ACQUISITION_TRIGGER_HIGH : ACQUISITION_TRIGGER_LOW
    require(receipt.trigger_state==expected,"observed chopped exposure classification differs from its optical phase")
    return nothing
end

function require_reset_product(product, previous, current)
    require((current["domain"]!=previous["domain"] || current["generation"]>previous["generation"]) && current["sequence"]==product.priming_exposures+1,
        "post-Reset output did not establish a new acquisition generation")
    return nothing
end

function zero_reference_proof(products, samples, covered)
    byname=Dict(product.name=>sample for (product,sample) in zip(products,samples))
    names=("physical","adopted-offset","reference-before","reference-after")
    all(name->haskey(byname,name),names) || return Dict("available"=>false,"nonzero_adoption_observed"=>false)
    logs=map(name->byname[name],names)
    frame_count=count(record->record["model_pts"]+record["duration"]<=covered,first(logs).records)
    require(frame_count>0,"receiving-frame comparison requires a covered prefix")
    for log in logs
        require(log.history!==nothing && length(log.records)>=frame_count && log.records[1:frame_count]==first(logs).records[1:frame_count],
            "reference/offset observations do not share the receiving physical-output frames")
    end
    offset,before,after=logs[2:4]
    require(all(values->all(iszero,values),offset.history[1:frame_count]),"startup reference comparison requires exact-zero offset")
    difference=0.0
    for index in 1:frame_count
        require(before.history[index]==after.history[index],"zero offset changed the reconstructed reference")
        difference=max(difference,maximum(abs,Float64.(before.history[index]).-Float64.(after.history[index])))
    end
    return Dict("available"=>true,"receiving_frames"=>frame_count,"maximum_absolute_reference_difference"=>difference,
        "frame_reference"=>"GPI physical-output frame; CAL2 exposure/input latency is separate",
        "nonzero_adoption_observed"=>false,"scope"=>"Exact-zero reference equality only; no finite-signal or nonzero CQu proof")
end

function sources(handle,selected,stage,name)
    ledger=W._ledger(handle)
    objects=M.dump_graph(handle,selected.prefix)
    require(!any(object->startswith(string(get(get(get(object,"info",Dict()),"props",Dict()),"node.name","")),
        "cal2-lifecycle-$(getpid())-"),objects),"test-owned observer nodes survived retirement")
    result=Dict{String,Any}()
    for source in (selected.plan.primary,selected.plan.auxiliary)
        node=only(filter(object->get(get(get(object,"info",Dict()),"props",Dict()),"node.name",nothing)==source["control-node"],objects))
        props=node["info"]["props"]
        identity=(;id=UInt32(node["id"]),serial=parse(UInt64,string(props["object.serial"])))
        value=M.Faults.decode_aos_source(objects,source,ledger["owners"][source["role"]],identity)
        report=C.read_json(joinpath(dirname(ledger["remote"]),source["control-node"]*"-report.json"))
        M.Faults.validate_source_report(report,value)
        result[source["role"]]=value
    end
    C.write_json(joinpath(stage,name*"-sources.json"),result)
    return result
end

function wait_until(predicate,deadline,description)
    while !predicate()
        W.monotonic()<deadline || error("timed out waiting for $description")
        sleep(0.005)
    end
end

function observe_epoch(handle,selected,stage,name)
    plan=selected.plan
    for (index,control) in enumerate(plan.controls)
        properties=M.request(handle,stage,name*"-open-properties-"*string(index),["properties",control.graph])
        generation=M.request(handle,stage,name*"-open-generation-"*string(index),["property-generation",control.graph,control.node])
        require_open_snapshot(control,properties,generation)
    end
    reference_before=M.request(handle,stage,name*"-reference-before",["parameter-generation",plan.reference.graph,plan.reference.node])
    HIL=Base.require(Main,:AdaptiveOpticsSimPipeWireHIL)
    ledger=W._ledger(handle)
    remote=ledger["remote"]
    require(isabspath(remote) && dirname(remote)==ledger["runtime"],"observer requires exact private-cohort remote")
    live=M.dump_graph(handle,selected.prefix)
    C.write_json(joinpath(stage,name*"-graph.json"),live)
    options=Tuple(HIL.PipeWireArrayStreamOptions(node_name="cal2-lifecycle-$(getpid())-$(index)",media_name=product.name,
        schema=product.schema,acquisition_version=product.acquisition_version,format=NdArrayFormat(NdArray.F32_LE,product.shape;layout=NdArray.ROW_MAJOR,rate=product.rate))
        for (index,product) in enumerate(plan.products))
    samples=map(product->Samples(product,plan.sample_count+128),plan.products)
    arrays=map(product->zeros(Float32,product.shape),plan.products)
    endpoints=Dict{String,Any}[]
    started=W.monotonic()
    return HIL.with_array_streams(options;remote,input=ntuple(_->true,length(options))) do wire
        registry=HIL.with_array_stream(wire,1) do _; Registry(wire.core); end
        links=Any[]
        trackers=Any[]
        try
            deadline=W.monotonic()+30
            for (index,product) in enumerate(plan.products)
                node=capture_node(live,product.node)
                props=node["info"]["props"]
                client=only(filter(object->get(object,"type",nothing)=="PipeWire:Interface:Client" && object["id"]==parse(Int,string(props["client.id"])),live))
                require(parse(Int,string(client["info"]["props"]["pipewire.sec.pid"]))==ledger["owners"][product.role]["pid"],"observed producer PID differs from exact cohort")
                ports=Ref{Any}(nothing)
                wait_until(deadline,"declared exported ports: $(product.name)") do
                    HIL.with_array_stream(wire,index) do stream
                        outputs=find_globals(registry;interface="PipeWire:Interface:Port",properties=("node.id"=>string(node["id"]),"port.direction"=>"out","port.name"=>product.port))
                        inputs=find_globals(registry;interface="PipeWire:Interface:Port",properties=("node.id"=>string(node_id(stream)),"port.direction"=>"in"))
                        length(outputs)==length(inputs)==1 || return false
                        ports[]=(only(outputs),only(inputs));true
                    end
                end
                output,input=ports[]
                push!(endpoints,Dict("product"=>product.name,"node"=>product.node,"node_id"=>node["id"],
                    "node_serial"=>string(props["object.serial"]),"port_id"=>output.id,
                    "port_serial"=>output.properties["object.serial"],"owner_role"=>product.role))
                HIL.with_array_stream(wire,index) do stream
                    link=create_object(wire.core,"link-factory",Link;properties=Dict("link.output.node"=>string(node["id"]),
                        "link.output.port"=>string(output.id),"link.input.node"=>string(node_id(stream)),
                        "link.input.port"=>string(input.id),"object.linger"=>"false"))
                    push!(links,link);push!(trackers,track_info!(link))
                end
                HIL.drain_pipewire_array!(arrays[index],wire,index) # Warm the owned drain while sources are held.
            end
            wait_until(deadline,"held observer negotiation") do
                HIL.with_array_stream(wire,1) do _
                    all(tracker->has_current_info(tracker) && current_info(tracker).state in
                        (PipeWireAO.LINK_STATE_PAUSED,PipeWireAO.LINK_STATE_ACTIVE),trackers)
                end
            end
            # Retire any cached held sample before the new observed epoch.
            # Only these test-owned streams are reset; all producers remain held.
            for index in eachindex(plan.products)
                HIL.reset_pipewire_array!(wire,index)
            end
            require(M.request(handle,stage,name*"-run",["session-start"])["state"]=="Running","Run did not reach Running")
            deadline=W.monotonic()+plan.timeout
            covered=plan.sample_count*plan.period
            complete()=all(log->!isempty(log.records) && last(log.records)["model_pts"]+last(log.records)["duration"]>=covered,samples)
            while !complete()
                W.monotonic()<deadline || error("paced CAL2 model collection timed out")
                for index in eachindex(plan.products)
                    status=HIL.array_stream_status(wire,index)
                    require(!status.failed && status.rejected==0 && status.dropped==0 && status.gaps==0,"observer transport rejected or lost a complete sample")
                    receipt=HIL.drain_pipewire_array!(arrays[index],wire,index)
                    if receipt!==nothing
                        product=plan.products[index]
                        if isempty(samples[index].records)
                            C.write_json(joinpath(stage,name*"-"*product.name*"-first-arrival.json"),
                                merge(identity_record(receipt.identity),Dict("pts"=>receipt.pts,
                                    "duration"=>receipt.duration,"lost_samples"=>receipt.lost_samples)))
                        end
                        if endswith(product.name,"-offset")
                            require(all(iszero,arrays[index]),"startup-only lifecycle observed a nonzero CAL2 offset")
                        elseif product.name in ("llowfs","scc")
                            require(sum(arrays[index])>0,"sensor image has zero optical power")
                        elseif product.name=="pupil"
                            amplitude=view(arrays[index],2,:,:)
                            require(all(>=(0),amplitude) && any(>(0),amplitude),"invalid pupil amplitude")
                        end
                        require_chopped_exposure(product,receipt)
                        record!(samples[index],arrays[index],receipt,product.duration;model_time=product.model_time,priming_exposures=product.priming_exposures,name=product.name)
                    end
                end
                sleep(0.005)
            end
            statistics=[Dict(string(key)=>value for (key,value) in pairs(HIL.array_stream_status(wire,index))) for index in eachindex(plan.products)]
            require(M.request(handle,stage,name*"-pause",["session-stop"])["state"]=="Ready","Pause did not reach Ready")
            reference_after=M.request(handle,stage,name*"-reference-after",["parameter-generation",plan.reference.graph,plan.reference.node])
            records=Dict{String,Any}()
            for (index,product) in enumerate(plan.products)
                log=samples[index]
                prefix=filter(record->record["model_pts"]+record["duration"]<=covered,log.records)
                require(length(prefix)==covered_count(product,covered),"covered prefix has missing exposures: $(product.name)")
                records[product.name]=Dict("node"=>product.node,"port"=>product.port,"shape"=>collect(product.shape),
                    "header_time"=>(product.model_time ? "model nanoseconds" : "publication nanoseconds; model coverage from declared acquisition cadence"),
                    "acquisition_version"=>product.acquisition_version,"priming_exposures"=>product.priming_exposures,"schema"=>product.schema,"samples"=>prefix,"observed_samples"=>length(log.records),"transport"=>statistics[index])
                records[product.name]["first_payload_sample"]=first(log.records)
                records[product.name]["last_payload_sample"]=last(log.records)
                if log.history!==nothing
                    path=joinpath(stage,name*"-"*product.name*"-covered.fits")
                    values=hcat(log.history[1:length(prefix)]...)
                    R.InstrumentCalibration.write_fits(path,values)
                    records[product.name]["covered_payloads_fits"]=Dict("path"=>basename(path),"sha256"=>C.sha256_file(path),
                        "shape"=>collect(size(values)),"axes"=>[2,1],"sample_axis"=>2)
                end
                for (suffix,data) in (("first",log.first),("last",log.last))
                    path=joinpath(stage,name*"-"*product.name*"-"*suffix*".fits")
                    R.InstrumentCalibration.write_fits(path,data)
                    records[product.name][suffix*"_fits"]=Dict("path"=>basename(path),"sha256"=>C.sha256_file(path))
                end
            end
            for branch in ("llowfs","scc")
                priming = records[branch*"-offset"]["priming_exposures"]
                measured = records[branch]["samples"][priming+1:end]
                require(measured==records[branch*"-offset"]["samples"],"controller output changed sensor acquisition metadata")
                if haskey(records,branch*"-modal-residual")
                    require(measured==records[branch*"-modal-residual"]["samples"],"modal residual changed sensor acquisition metadata")
                end
            end
            publisher=capture_node(M.dump_graph(handle,selected.prefix),plan.products[1].node)
            props=publisher["info"]["props"]
            publisher_status=Dict(key=>value for (key,value) in props if startswith(key,"aos.pupil-output."))
            require(get(publisher_status,"aos.pupil-output.failed",nothing)=="false","pupil publisher reported failure")
            for key in ("dropped","transport-dropped","gaps")
                require(parse(UInt64,string(publisher_status["aos.pupil-output."*key]))==0,"pupil publisher reported loss")
            end
            result=Dict("streams"=>records,"endpoints"=>endpoints,"publisher"=>publisher_status,
                "covered_model_ns"=>covered,"elapsed_wall_seconds"=>W.monotonic()-started,
                "pacing_rate_hz"=>plan.pacing,"epoch_timeout_seconds"=>plan.timeout,
                "scope"=>"Covered startup/lifecycle prefix; direct test-owned taps, no closed-loop or deadline claim",
                "offset_readback_observed"=>haskey(records,"adopted-offset"),"transaction_adoption_observed"=>false,
                "native_correction_open_confirmed"=>true,"reference_comparison"=>zero_reference_proof(plan.products,samples,covered),
                "reference_parameter_generations"=>Dict("before_run"=>reference_before,"after_pause"=>reference_after),
                "missing_observability"=>plan.missing)
            C.write_json(joinpath(stage,name*"-capture.json"),result)
            return result
        catch error
            C.write_json(joinpath(stage,name*"-capture-failure.json"),Dict(
                "failure"=>sprint(showerror,error),"endpoints"=>endpoints,
                "streams"=>Dict(product.name=>Dict("node"=>product.node,"port"=>product.port,
                    "schema"=>product.schema,"shape"=>collect(product.shape),"samples"=>log.records)
                    for (product,log) in zip(plan.products,samples)),
                "scope"=>"Partial bounded lifecycle observation; no passing cohort claim"))
            rethrow()
        finally
            HIL.with_array_stream(wire,1) do _
                foreach(close,reverse(trackers));foreach(close,reverse(links));close(registry)
            end
        end
    end
end

function main(args)
    require(length(args)>=3,USAGE)
    application,stage,prefix=abspath.(args[1:3])
    stage=E.checked_path(stage)
    require(E.outside(relpath(stage,application)) && E.outside(relpath(stage,prefix)),
        "validation stage must be outside the sealed application and selected native prefix")
    options=Dict{String,String}();cold=false;index=4
    while index<=length(args)
        key=args[index]
        if key=="--preflight"
            require(!cold,"duplicate --preflight");cold=true;index+=1;continue
        end
        require(key in ("--samples","--timeout-seconds") && !haskey(options,key) && index<length(args),USAGE)
        options[key]=args[index+1];index+=2
    end
    require(!ispath(stage) && !islink(stage),"validation stage must be fresh")
    plan=preflight(application,prefix;sample_count=parse(Int,get(options,"--samples","40")),
        timeout_seconds=haskey(options,"--timeout-seconds") ? parse(Float64,options["--timeout-seconds"]) : nothing)
    summary=Dict("deployment_sha256"=>C.sha256_file(joinpath(application,"deployment.conf")),
        "manifest_sha256"=>C.sha256_file(joinpath(application,plan.spec["runtime"]["project"],"Manifest.toml")),
        "prefix"=>prefix,"julia_version"=>string(VERSION),"selector_rtc_version"=>string(pkgversion(R)),
        "native_sha256"=>Dict(relative=>C.sha256_file(joinpath(prefix,relative)) for relative in
            ("bin/pipewireao-rtc","lib/pipewireao-rtc/modules/libwireplumber-module-ao-control-endpoint.so",
                "share/pipewireao-rtc/scripts/ao/session.lua")),
        "roles"=>[owner["role"] for owner in plan.spec["owners"]],"analysis"=>get(plan.spec,"analysis",[]),
        "expected_runtime_roles"=>sort!(collect(union(Set(["core"]),Set(owner["role"] for owner in plan.spec["owners"]),
            Set(values(plan.spec["node-owners"]))))),
        "products"=>[Dict("name"=>product.name,"node"=>product.node,"port"=>product.port,"schema"=>product.schema,
            "shape"=>collect(product.shape),"duration_ns"=>product.duration) for product in plan.products],
        "calibration_identity"=>plan.calibration_identity,"sample_count"=>plan.sample_count,
        "correction_controls"=>[Dict(string(key)=>value for (key,value) in pairs(control)) for control in plan.controls],
        "pacing_rate_hz"=>plan.pacing,"epoch_timeout_seconds"=>plan.timeout,
        "missing_observability"=>plan.missing,"harness_sha256"=>C.sha256_file(@__FILE__))
    cold && return summary # No stage, systemd operation, native connection or GPU import.
    mkpath(stage;mode=0o700)
    C.write_json(joinpath(stage,"preflight.json"),summary)
    selected=(;plan,prefix)
    handle=nothing
    result=merge(summary,Dict{String,Any}("completed"=>false,"scope"=>"Accepted application startup/lifecycle evidence; no closed-loop, fault or hardware qualification"))
    try
        handle=W.start!(application,joinpath(stage,"session");prefix,deadline=W.monotonic()+M.Faults.startup_budget(plan.spec))
        ledger=W._ledger(handle)
        require(Set(keys(ledger["owners"]))==Set(summary["expected_runtime_roles"]),
            "retained native owner roles differ from authored and generated session roles")
        for owner in values(ledger["owners"])
            require(owner["state"]=="running" && R.SystemdOwners.process_identity(owner["pid"],UInt64(owner["start-ticks"]),owner["cgroup"]),
                "retained native owner process incarnation differs")
        end
        result["runtime_roles"]=sort!(collect(keys(ledger["owners"])))
        result["native_external_roles"]=sort!(filter(!=("core"),collect(keys(ledger["owners"]))))
        require(M.request(handle,stage,"initial-status",["status"])["state"]=="Ready","new session did not reach Ready held")
        ready=sources(handle,selected,stage,"ready")
        require(all(source->!source["snapshot"]["running"] && source["snapshot"]["sequence"]==0,values(ready)),"sources did not start held at sequence zero")
        first_epoch=Base.invokelatest(observe_epoch,handle,selected,stage,"first")
        held=sources(handle,selected,stage,"held")
        require(all(source->!source["snapshot"]["running"] && source["snapshot"]["sequence"]>=plan.sample_count,values(held)),
            "Pause did not hold every source after covered progress")
        require(M.request(handle,stage,"reset",["reset"])["state"]=="Ready","Reset did not return Ready held")
        reset=sources(handle,selected,stage,"reset")
        for role in keys(held)
            require(reset[role]["instance"]==held[role]["instance"] &&
                reset[role]["snapshot"]["generation"]>held[role]["snapshot"]["generation"] &&
                reset[role]["snapshot"]["sequence"]==0 && !reset[role]["snapshot"]["running"],"Reset did not establish a fresh held source generation")
        end
        second_epoch=Base.invokelatest(observe_epoch,handle,selected,stage,"second")
        final=sources(handle,selected,stage,"final-held")
        require(all(source->!source["snapshot"]["running"] && source["snapshot"]["sequence"]>=plan.sample_count,values(final)),
            "second Pause did not hold every source after covered progress")
        for product in plan.products
            previous=last(first_epoch["streams"][product.name]["samples"])
            current=first(second_epoch["streams"][product.name]["samples"])
            require_reset_product(product,previous,current)
        end
        result["epochs"]=[first_epoch,second_epoch]
        result["source_snapshots"]=Dict("ready"=>ready,"held"=>held,"reset"=>reset,"final-held"=>final)
        result["shutdown"]=M.shutdown(handle,joinpath(stage,"session"))
        result["completed"]=true
    catch error
        result["failure"]=sprint(showerror,error)
        rethrow()
    finally
        if handle!==nothing && !result["completed"]
            try M.Faults.cleanup!(handle,joinpath(stage,"session");failed=true)
            catch error;result["cleanup_failure"]=sprint(showerror,error) end
        end
        C.write_json(joinpath(stage,"cal2-lifecycle-result.json"),result)
    end
    return result
end

if abspath(PROGRAM_FILE)==@__FILE__
    main(ARGS)
    println("--preflight" in ARGS ? "CAL2 lifecycle preflight passed; no session started" :
        "CAL2 lifecycle complete; receipt: "*joinpath(abspath(ARGS[2]),"cal2-lifecycle-result.json"))
end
end
