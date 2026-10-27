# Typed startup validation and staging shared by all sensor procedures.
const C = PipeWireAORTC.Common
const E = PipeWireAORTC.InstrumentExport
const D = PipeWireAORTC.DeploymentConfiguration
const R = PipeWireAORTC.RuntimeExport
const Owner = PipeWireAORTC.GraphOwner
const Artifacts = PipeWireAORTC.Artifacts

function bundle_graph(calibration)
    bundle=Calibration.read_bundle(calibration)
    options=FilterGraphIsland.parse_arguments(["--graph",bundle.graph,"--check","--execution","complete-frame"])
    return FilterGraphIsland.prepare_service_graph(options;initial_parameters=formats->begin
        Set(string.(keys(formats)))==Set(bundle.parameter_names) ||
            throw(ArgumentError("calibration runtime parameter manifest differs from graph"))
        entries=[Owner.FITSBinding(name,Artifacts.FITSArtifact(bundle.artifacts[bundle.parameter_files[string(name)]];
            axes=length(format.shape)>1 ? collect(reverse(1:length(format.shape))) : nothing))
            for (name,format) in pairs(formats)]
        Owner.prepare_bindings(entries,formats)
    end)
end

function Calibration.stage_calibration(source, application, calibration, destination)
    source, application, calibration, destination = E.checked_path.((source, application, calibration, destination))
    isdir(source) && isdir(application) && isdir(calibration) || throw(ArgumentError("source, application and calibration must be directories"))
    !isfile(joinpath(source,"deployment.conf")) && !isdir(joinpath(source,"shared-runtime")) ||
        throw(ArgumentError("staging requires the authored instrument source, not a built application"))
    !ispath(destination) && !islink(destination) || throw(ArgumentError("staging destination must be fresh"))
    E.outside(relpath(destination, source)) && E.outside(relpath(destination, application)) &&
        E.outside(relpath(destination, calibration)) ||
        throw(ArgumentError("staging destination must be outside source and calibration directories"))
    bundle = Calibration.read_bundle(calibration)
    resultpath=joinpath(calibration,"result.yaml")
    graphpath=bundle.graph
    report=bundle.report
    Calibration.read_recipe(application)==report["recipe"] ||
        throw(ArgumentError("calibration recipe differs from the selected application"))
    recipe = report["recipe"]
    IC.bounded_yaml(joinpath(source,"calibration/recipe.yaml"))==
        IC.bounded_yaml(joinpath(application,"calibration/recipe.yaml")) ||
        throw(ArgumentError("source calibration recipe differs from the built application"))
    declaration = IC.load_simulation(D.relative_asset(application, recipe["simulation"]))
    settings = calibration_settings(application,recipe,declaration)
    original_identity = IC.prescription_identity(declaration, settings)
    original_identity == report["source_prescription_identity"] ||
        throw(ArgumentError("calibration source prescription differs from the selected instrument"))
    authored_graph = D.relative_asset(application, recipe["graph_source"])
    C.sha256_file(D.relative_asset(source,recipe["graph_source"]))==report["source_graph_sha256"] ||
        throw(ArgumentError("source graph template differs from the calibrated application"))
    C.sha256_file(authored_graph) == report["source_graph_sha256"] ||
        throw(ArgumentError("calibration authored graph differs from the selected instrument"))
    C.sha256_file(graphpath) == report["graph_sha256"] ||
        throw(ArgumentError("calibration concrete graph hash differs from its receipt"))
    hashes = report["artifact_sha256"]
    mkpath(dirname(destination))
    temporary = mktempdir(dirname(destination); prefix="calibration-stage-")
    staged = joinpath(temporary, "source")
    count = Ref(0)
    try
        E.copy_source(source, staged; runtime_configurations=false)
        # Replace the selection only in this owned staging copy.
        # Preserve authored recipe and calibration inputs. Git retains prior selections.
        selected=joinpath(staged,"calibration")
        mkpath(selected)
        rm(joinpath(selected,"recipe.conf");force=true)
        rm(joinpath(selected,"history");recursive=true,force=true)
        for name in ("artifacts","result.yaml","context.yaml","graph.conf")
            path=joinpath(selected,name)
            rm(path;recursive=true,force=true)
            origin=joinpath(calibration,name)
            isdir(origin) ? R.copy_tree(origin,path) : R.copy_file(origin,path)
        end
        rm(joinpath(staged, "rtc", "calibration.yaml"); force=true)
        staged_declaration = IC.load_simulation(D.relative_asset(staged, recipe["simulation"]))
        staged_settings = IC.settings(staged_declaration,settings)
        IC.prescription_identity(staged_declaration,staged_settings)==original_identity ||
            throw(ArgumentError("authored source prescription differs from the calibrated application"))
        copied_report = deepcopy(report)
        copied_report["staged_prescription_identity"] = IC.prescription_identity(staged_declaration, staged_settings)
        copied_resultpath = joinpath(staged, "calibration", "result.yaml")
        C.write_yaml(copied_resultpath, copied_report;
            header="Copied simulation calibration receipt with the localized source prescription identity.")
        configurationpath = D.relative_asset(staged, recipe["rtc_configuration"])
        configuration = C.read_yaml(configurationpath)
        configuration["calibration"] = "calibration/context.yaml"
        configuration["calibration_identity"] = "sha256:" * C.sha256_file(copied_resultpath)
        if haskey(report,"dimensions")
            dimensions=deepcopy(report["dimensions"])
            configuration["controller"]["command_count"]=pop!(dimensions,"controller_command_count")
            for (name,value) in dimensions
                original=get(configuration["dimensions"],name,nothing)
                original isa AbstractDict && haskey(original,"\$ref") && continue
                configuration["dimensions"][name]=value
            end
        end
        C.write_yaml(configurationpath, configuration;
            header="Selected finite simulation calibration; source recipe and receipt define its scope.")
        rtc = IC.load_rtc(configurationpath)
        context = E.graph_context(IC.json_value(IC.physical_definition(rtc.instrument));
            dimensions=rtc.document["dimensions"], mirror_controls=rtc.controls["deformable_mirrors"],
            calibration=rtc.calibration)
        prefix = get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
        E.resolve_graph_configuration(D.decode(D.relative_asset(staged, recipe["graph_source"]), prefix), context) ==
            D.decode(graphpath, prefix) ||
            throw(ArgumentError("calibration context does not reproduce its recorded concrete graph"))
        # Cold source publication must see the newly selected dimensions and parameters.
        R.copy_file(graphpath,D.relative_asset(staged,recipe["graph"]))
        options = FilterGraphIsland.parse_arguments([
            "--graph", graphpath, "--check", "--execution", "complete-frame"])
        graph = FilterGraphIsland.prepare_service_graph(options; initial_parameters=formats -> begin
            Set(string.(keys(formats)))==Set(bundle.parameter_names) ||
                throw(ArgumentError("calibration runtime parameter manifest differs from graph"))
            rows = Dict{String,Any}[]
            entries = Owner.FITSBinding[]
            for name in sort!(collect(keys(formats)); by=string)
                format = getproperty(formats, name)
                filename = bundle.parameter_files[string(name)]
                haskey(hashes, filename) || throw(ArgumentError("calibration receipt omits parameter $name"))
                axes = collect(reverse(1:length(format.shape)))
                path = joinpath(staged, "calibration", "artifacts", filename)
                row = Dict{String,Any}("port" => string(name),
                    "path" => "../calibration/artifacts/" * filename, "hdu" => 1)
                length(axes) > 1 && (row["axes"] = axes)
                push!(rows, row)
                push!(entries, Owner.FITSBinding(name,
                    Artifacts.FITSArtifact(path; hdu=1, axes=length(axes) > 1 ? axes : nothing)))
            end
            C.write_yaml(joinpath(staged, "rtc", "parameters.yaml"), Dict("parameters" => rows);
                header="FITS bindings validated against the typed graph; axes reverse the calibration serialization order.")
            values = Owner.prepare_bindings(entries, formats)
            count[] = length(values)
            values
        end)
        try
            # Every selected array has passed the production owner format/byte checks and
            # the scientific parameter replacement contract before publication.
            length(JuliaFilterGraph.parameter_formats(graph)) == count[] ||
                throw(ArgumentError("calibration parameter coverage differs from the graph"))
        finally
            FilterGraphIsland.close_execution(graph)
        end
        Calibration.read_bundle(selected)
        # Mask publication depends on the newly validated typed startup bindings.
        IC.publication(configurationpath)
        IC.prescription_identity(IC.load_simulation(declaration.path), settings) == original_identity &&
            C.sha256_file(authored_graph) == report["source_graph_sha256"] ||
            throw(ArgumentError("instrument source changed while staging its calibration"))
        mv(staged, destination)
    finally
        rm(temporary; recursive=true, force=true)
    end
    println("staged parameters=", count[], " calibration_identity=sha256:",
        C.sha256_file(joinpath(destination, "calibration", "result.yaml")))
    return destination
end
