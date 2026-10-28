# Resolve retained optical controller templates only after acquiring real matrices.
function validate_optical_graphs(graphs, contexts, names)
    graphs isa NamedTuple && contexts isa NamedTuple && keys(graphs) == keys(contexts) == names ||
        throw(ArgumentError("concrete graphs and contexts must name every recipe branch in order"))
    all(context -> context isa AbstractDict,contexts) || throw(ArgumentError("optical branch contexts must be mappings"))
    for graph in graphs
        graph isa AbstractDict && haskey(graph,"filter.graph") &&
            !isempty(get(graph["filter.graph"],"nodes",[])) ||
            throw(ArgumentError("publishing optical calibration requires concrete nonempty branch graphs"))
    end
    return nothing
end

function optical_publication_plan(application, selected; graphs, configuration, prefix)
    Export = PipeWireAORTC.InstrumentExport
    D = PipeWireAORTC.DeploymentConfiguration
    if graphs === nothing
        declaration = PipeWireAORTC.Common.read_yaml(D.relative_asset(application,configuration))
        IC.fields(declaration,("graphs","provenance","destination","rtc_configuration",
            "simulation_configuration","recipe","zero_command"),("graphs",),"optical publication configuration")
        graphs = declaration["graphs"]
    end
    names = keys(selected.branches)
    graphs isa AbstractDict && Set(keys(graphs)) == Set(string.(names)) ||
        throw(ArgumentError("authored graphs must name every optical recipe branch exactly once"))
    simulation = D.decode(D.relative_asset(application,"simulation.conf"),prefix)
    get(simulation,"version",nothing) === 4 && get(simulation,"mode",nothing) == "external-pupil" ||
        throw(ArgumentError("optical publication requires a built external-pupil application"))
    rtc = IC.load_rtc(D.relative_asset(application,simulation["rtc_configuration"]))
    plant = simulation["plant"]
    definition = D.relative_asset(application,plant["definition"])
    Calibration.digest(definition) == Calibration.digest(D.relative_asset(application,selected.document["optical_simulation"])) ||
        throw(ArgumentError("optical recipe differs from the built external-pupil definition"))
    declaration = IC.load_simulation(definition)
    IC.canonical(IC.settings(declaration,get(plant,"settings",Dict()))) ==
        IC.canonical(IC.settings(declaration,get(selected.document,"settings",Dict()))) ||
        throw(ArgumentError("optical recipe effective settings differ from built execution"))
    contracts = Export.external_pupil_port_contracts(definition;
        settings=get(plant,"settings",Dict()))
    frames = Dict(string(name)=>Dict("frame_schema"=>contracts["sensors"][getproperty(selected.branches,name)]["schema"])
        for name in names)
    templates = NamedTuple{names}(Tuple(D.decode(D.relative_asset(application,graphs[string(name)]),prefix) for name in names))
    validate_optical_graphs(templates,NamedTuple{names}(Tuple(Dict() for _ in names)),names)
    instrument = PipeWireAORTC.Common.read_json(D.relative_asset(application,"instrument.json"))
    return (;rtc,frames,templates,instrument)
end

function optical_publication_graphs(plan, calibration)
    names = keys(calibration.branches)
    keys(plan.templates) == names || throw(ArgumentError("measured optical branches differ from authored templates"))
    dimensions = plan.rtc.document["dimensions"]
    size(calibration.projection) == (dimensions["physical_command_count"],dimensions["controller_command_count"]) ||
        throw(DimensionMismatch("measured physical projection differs from cold RTC dimensions"))
    contexts = map(names) do name
        measured = getproperty(calibration.branches,name)
        shape = (dimensions["image_rows"],dimensions["image_columns"])
        size(measured.mask) == size(measured.reference) == shape ||
            throw(DimensionMismatch("measured optical image differs from cold RTC dimensions"))
        eltype(measured.mask) === Bool || throw(ArgumentError("optical selection mask must contain Bool values"))
        size(measured.reconstructor) == (dimensions["controller_command_count"],count(measured.mask)) &&
            count(measured.mask) == dimensions["selected_pixel_count"] ||
            throw(DimensionMismatch("measured reconstructor differs from declared pixel selection"))
        context = Dict{String,Any}(deepcopy(plan.frames))
        # Match calibration_context's row-major FITS conversion exactly. The
        # bundle writer replaces this real measured mask with its typed FITS ref.
        context["pixel_selection_mask"] = vec(permutedims(measured.mask,(2,1)))
        context
    end
    contexts = NamedTuple{names}(contexts)
    graphs = map(contexts,plan.templates) do calibration_context, template
        context = PipeWireAORTC.InstrumentExport.graph_context(plan.instrument;
            dimensions,mirror_controls=plan.rtc.controls["deformable_mirrors"],calibration=calibration_context)
        PipeWireAORTC.InstrumentExport.resolve_graph_configuration(template,context)
    end
    return (;graphs,contexts)
end

function publish_optical_bundles(result, destination, graphs, contexts)
    validate_optical_graphs(graphs,contexts,keys(result.calibration.branches))
    result.calibration.report["status"] == "accepted" ||
        throw(ArgumentError("cannot publish a rejected optical calibration"))
    mkpath(dirname(destination))
    temporary = mktempdir(dirname(destination);prefix=".optical-calibration-")
    try
        reports = map(keys(graphs)) do name
            branch = joinpath(temporary,string(name))
            report = Calibration.calibrate_optical(result.calibration,branch;
                report=merge(result.report,Dict("branch"=>string(name))),context=getproperty(contexts,name),
                concrete_graph=getproperty(graphs,name),branch=name)
            # Prepare the exact published graph with all real typed FITS inputs
            # before making the bundle index visible. This owns no live graph.
            mktempdir() do directory
                entries = [Dict("port"=>parameter,"path"=>joinpath(branch,"artifacts",filename),
                    "hdu"=>1,"axes"=>parameter == string(name)*"-modal-reference" ? [1] : [2,1])
                    for (parameter,filename) in report["parameter_files"]]
                bindings = joinpath(directory,"parameters.conf")
                PipeWireAORTC.Common.write_json(bindings,Dict("parameters"=>entries))
                GraphOwner.read_bindings(joinpath(branch,"graph.conf"),bindings)
            end
            report
        end
        reports = NamedTuple{keys(graphs)}(reports)
        first_branch = first(keys(reports))
        shared_names = hasproperty(result.calibration,:fast_reference) ?
            ("command-projection","physical-to-modes","modes-to-reference") :
            ("command-projection","physical-to-modes")
        shared = Dict(name=>Dict("path"=>string(first_branch)*"/artifacts/"*name*".fits",
            "sha256"=>getproperty(reports,first_branch)["artifact_sha256"][name*".fits"])
            for name in shared_names)
        for report in reports, name in keys(shared)
            report["artifact_sha256"][name*".fits"] == shared[name]["sha256"] ||
                throw(ArgumentError("branch bundles did not preserve identical physical projection artifacts"))
        end
        index = Dict("version"=>1,"kind"=>"optical-calibration-index",
            "calibration_identity"=>result.report["calibration_identity"],
            "physical_projection"=>shared,
            "branches"=>Dict(string(name)=>Dict("path"=>string(name),
                "result_sha256"=>Calibration.digest(joinpath(temporary,string(name),"result.yaml"))) for name in keys(reports)))
        PipeWireAORTC.Common.write_yaml(joinpath(temporary,"calibration.yaml"),index;
            header="Generated by PipeWireAORTC optical calibration; regenerate from built applications and the retained optical recipe.")
        mv(temporary,destination;force=false)
        return merge(result,(;reports,index,directory=destination))
    finally
        isdir(temporary) && rm(temporary;recursive=true)
    end
end
