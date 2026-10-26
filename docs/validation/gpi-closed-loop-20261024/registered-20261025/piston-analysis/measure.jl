using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Statistics, LinearAlgebra
const IC=PipeWireAORTC.InstrumentConfiguration
const AG=AdaptiveOpticsSim.AlgorithmGraphs
const C=PipeWireAORTC.Common
const ROOT="/home/dgamroth/.local/state/pipewireao/gpi2-annular-live-20261025b"
const APP=joinpath(ROOT,"session/installed")
function progress(s);println(s);flush(stdout);end
function rms_nm(values,valid)
    x=Float64.(vec(values)[valid]);x.-=mean(x);sqrt(mean(abs2,x))*1e9
end
function summary(values)
    Dict("mean"=>mean(values),"minimum"=>minimum(values),"maximum"=>maximum(values),"samples"=>values)
end
function main()
    out=Dict{String,Any}("completed"=>false,"scope"=>"Offline CPU woofer demanded/requested piston and command statistics; no live connection or controls",
        "driver_sha256"=>C.sha256_file(@__FILE__))
    try
        recipe=C.read_yaml(joinpath(APP,"calibration-recipe.yaml"))
        receipt=C.read_yaml(joinpath(APP,"calibration/result.yaml"))
        declaration=IC.load_simulation(joinpath(APP,recipe["simulation"]))
        settings=IC.settings(declaration,get(recipe,"settings",Dict()))
        identity=IC.prescription_identity(declaration,settings)
        expected=get(receipt,"staged_prescription_identity",receipt["source_prescription_identity"])
        identity==expected || error("prescription differs from exact staged calibration")
        out["prescription_identity"]=identity
        doc=IC.graph_document(declaration,settings;calibration=true)
        names=("woofer","tweeter")
        selected=Dict("schema_version"=>doc["schema_version"],"name"=>"saved_native_clipping_optics",
            "nodes"=>filter(n -> n["name"] in names,doc["nodes"]),
            "parameters"=>filter(p -> first(split(p["destination"],'.')) in names,get(doc,"parameters",[])),
            "inputs"=>filter(p -> p["name"] in names,doc["inputs"]),
            "outputs"=>filter(p -> p["name"] in ("woofer_opd","tweeter_opd"),doc["outputs"]))
        out["mirror_graph"]=selected
        specs=declaration.document["bindings"]
        binding_names=unique([p["binding"] for section in ("inputs","parameters") for p in selected[section]])
        values=Tuple(IC.binding_values(declaration,settings,specs[n]) for n in binding_names)
        bindings=NamedTuple{Tuple(Symbol.(binding_names))}(values)
        definition=AG.load_algorithm_graph(selected;bindings)
        progress("prepare exact two-mirror graph")
        graph=AG.prepare_algorithm_graph(definition;target=AdaptiveOpticsSim.Backends.HostComputeDevice())
        support=IC.binding_values(declaration,settings,Dict("kind"=>"pupil_support","resolution"=>"pupil_resolution"))
        valid=findall(vec(support).!=0)
        out["pupil"]=Dict("shape"=>collect(size(support)),"sample_count"=>length(valid),
            "central_obstruction_ratio"=>declaration.instrument.document["telescope"]["central_obstruction_ratio"],
            "ordering"=>"AOS native x-first/y-second arrays; physical command labels from exact mirror-grid binding",
            "metric"=>"unweighted piston-removed RMS on exact telescope annular support; nm OPD")
        raw=C.read_json(joinpath(ROOT,"clipping-native-samples.json");maximum=32*1024*1024)
        analysis=C.read_json(joinpath(ROOT,"clipping-native-analysis.json"))
        sequences=intersect(analysis["mirrors"]["woofer"]["sequences"],analysis["mirrors"]["tweeter"]["sequences"])
        out["sequences"]=sequences
        payload(name,seq)=Float32.(raw[name]["samples"][findfirst(==(seq),raw[name]["sequences"])])
        function maps(w,t)
            copyto!(bindings.woofer,w);copyto!(bindings.tweeter,t);AG.step_graph!(graph)
            copy(AG.graph_output(graph,:woofer_opd)),copy(AG.graph_output(graph,:tweeter_opd))
        end
        zero_t=zeros(Float32,2304)
        measurements=Dict(name=>Dict(key=>Float64[] for key in ("command_mean_nm","command_min_nm","command_max_nm","command_span_nm","pupil_piston_nm","pupil_centered_rms_nm")) for name in ("demanded","requested"))
        for seq in sequences
            wd=payload("woofer",seq); wf=payload("woofer-constraint-feedback",seq)
            for (name,w) in (("demanded",wd),("requested",wd.+wf))
                wmap,_=maps(w,zero_t)
                vals=Float64.(vec(wmap)[valid]); coeff=Float64.(w)
                entries=(mean(coeff),minimum(coeff),maximum(coeff),maximum(coeff)-minimum(coeff),mean(vals),sqrt(mean(abs2,vals.-mean(vals))))
                for (key,value) in zip(("command_mean_nm","command_min_nm","command_max_nm","command_span_nm","pupil_piston_nm","pupil_centered_rms_nm"),entries)
                    push!(measurements[name][key],1e9*value)
                end
            end
        end
        out["measurements"]=Dict(name=>Dict(key=>summary(v) for(key,v) in metrics) for(name,metrics) in measurements)
        out["inputs_sha256"]=Dict(f=>C.sha256_file(joinpath(ROOT,f)) for f in ("clipping-native-samples.json","clipping-native-analysis.json"))
        out["runtime"]=Dict("julia"=>string(VERSION),"aos_source"=>pathof(AdaptiveOpticsSim),"rtc_source"=>pathof(PipeWireAORTC),"backend"=>"HostComputeDevice; no GPU packages imported")
        out["completed"]=true
    catch error
        out["failure"]=sprint(showerror,error,catch_backtrace());rethrow()
    finally
        C.write_json("/home/dgamroth/.cache/pipewireao/gpi2-registered-20261025/piston-analysis/result.json",out)
        progress("piston analysis completed="*string(out["completed"]))
    end
end
main()
