"""
    materialize_calibration(source, built, calibration; graphs, prefix, ...)

Select accepted, simulation-local optical branch bundles in an authored source.
The standard bundles remain byte-for-byte intact under `generated/calibration`;
a generated shared context, `rtc.yaml` and selection receipt bind the selected
RTC identity. The authored RTC configuration is preserved byte-for-byte; the
controller application mode selects the generated RTC configuration explicitly.
This validates numerical acceptance, not application or hardware qualification.
All validation precedes publication. An existing generated selection is preserved;
choose a fresh generated destination to select a subsequent calibration.
"""
function materialize_calibration(source::AbstractString, application::AbstractString,
        calibration::AbstractString; graphs::AbstractDict, prefix::AbstractString, provenance::AbstractString,
        destination="generated/calibration", rtc_configuration="rtc/configuration.yaml",
        simulation_configuration="simulation.conf", recipe="calibration/optical.yaml",
        zero_command="physical-offset-zero.fits")
    Calibration = getfield(parentmodule(@__MODULE__), :InstrumentCalibration)
    root = checked_path(source)
    built, spec = sealed_application(application, prefix)
    bundles = checked_path(calibration)
    !isfile(joinpath(root,"deployment.conf")) || throw(ArgumentError("materialization requires authored source"))
    destination isa String && startswith(destination,"generated/") && normpath(destination)==destination && !outside(destination) ||
        throw(ArgumentError("calibration destination must be an explicit generated source directory"))
    selected = checked_path(joinpath(root,destination))
    zero_command isa String && occursin(r"^[a-z][a-z0-9-]{0,63}\.fits$",zero_command) ||
        throw(ArgumentError("zero command must name a FITS artifact in the generated selection"))
    !ispath(selected) || throw(ArgumentError("generated calibration destination must be fresh"))
    indexpath = D.relative_asset(bundles,"calibration.yaml")
    index = Common.read_yaml(indexpath)
    get(index,"version",nothing) === 1 && get(index,"kind",nothing)=="optical-calibration-index" ||
        throw(ArgumentError("expected optical calibration index version 1"))
    branch_index = index["branches"]
    branch_index isa AbstractDict && 1 <= length(branch_index) <= 16 &&
        all(name -> name isa String && occursin(r"^[a-z][a-z0-9-]{0,31}$",name),keys(branch_index)) ||
        throw(ArgumentError("calibration index requires bounded branch names"))
    Set(keys(graphs)) == Set(keys(branch_index)) && !isempty(graphs) ||
        throw(ArgumentError("graphs must name every indexed branch exactly once"))
    recipepath = D.relative_asset(built,recipe)
    Common.sha256_file(D.relative_asset(root,recipe)) == Common.sha256_file(recipepath) ||
        throw(ArgumentError("authored recipe differs from calibrated built application"))
    recipe_document = Common.read_yaml(recipepath)
    optical = recipe_document["optical_simulation"]
    Common.sha256_file(D.relative_asset(root,optical)) == Common.sha256_file(D.relative_asset(built,optical)) ||
        throw(ArgumentError("authored optical execution differs from calibrated application"))
    provenancepath = D.relative_asset(built,provenance)
    Common.sha256_file(D.relative_asset(root,provenance))==Common.sha256_file(provenancepath) ||
        throw(ArgumentError("authored optical provenance differs from calibrated application"))
    receipt = Common.read_yaml(provenancepath)
    for entry in vcat(receipt["sources"],receipt["graphs"],[receipt["execution"]])
        for directory in (root,built)
            Common.sha256_file(D.relative_asset(directory,entry["path"]))==entry["sha256"] ||
                throw(ArgumentError("optical provenance input changed: $(entry["path"])"))
        end
    end
    simulation = D.decode(D.relative_asset(built,simulation_configuration),prefix)
    get(simulation,"version",nothing)===4 && simulation["mode"]=="external-pupil" ||
        throw(ArgumentError("optical materialization requires a prepared external-pupil owner"))
    identity = index["calibration_identity"]
    identity isa String && occursin(r"^sha256:[0-9a-f]{64}$",identity) || throw(ArgumentError("invalid calibration identity"))
    rtcpath = D.relative_asset(root,rtc_configuration)
    authored_rtc = Common.read_yaml(rtcpath)
    builtin_rtc = InstrumentConfiguration.load_rtc(D.relative_asset(built,rtc_configuration))
    for key in ("controller","dimensions","mirror_controls","instrument")
        get(authored_rtc,key,nothing)==get(builtin_rtc.authoring,key,nothing) ||
            throw(ArgumentError("authored RTC $key differs from calibrated application"))
    end
    # The mirror-free instrument is copied exactly by the normal exporter.
    Common.sha256_file(joinpath(root,"instrument.yaml")) == Common.sha256_file(joinpath(built,"instrument.yaml")) ||
        throw(ArgumentError("authored physical instrument differs from calibrated application"))
    reports = Dict{String,Any}()
    branch_paths = Dict{String,String}()
    context = nothing
    for name in sort!(collect(keys(graphs)))
        entry = branch_index[name]
        entry["path"]==name || throw(ArgumentError("indexed branches must use their own standard bundle directory"))
        branch_path = D.relative_asset(bundles,joinpath(entry["path"],"result.yaml"))
        Common.sha256_file(branch_path)==entry["result_sha256"] || throw(ArgumentError("indexed branch result hash mismatch"))
        branch_root = dirname(branch_path)
        bundle = Calibration.read_bundle(branch_root)
        report = bundle.report
        get(report,"status",nothing)=="accepted" && get(report,"built_application_calibration",false)===true &&
            get(report,"deployable",false)===true && get(report,"diagnostic",true)===false &&
            get(get(report,"held_out",Dict()),"accepted",false)===true &&
            get(report,"calibration_identity",nothing)==identity && get(report,"branch",nothing)==name ||
            throw(ArgumentError("branch must be an accepted matched built-application calibration"))
        report["recipe"]==recipe_document && report["recipe_sha256"]==Common.sha256_file(recipepath) ||
            throw(ArgumentError("branch recipe differs from calibrated application"))
        report["source_graph_sha256"]==Common.sha256_file(D.relative_asset(built,optical)) &&
            report["source_prescription_identity"]==simulation["prescription_identity"] ||
            throw(ArgumentError("branch optical prescription differs from calibrated application"))
        report["branches"][name]["accepted"]===true || throw(ArgumentError("branch numerical gates failed"))
        candidate = deepcopy(bundle.context)
        mask = candidate["pixel_selection_mask"]
        if context === nothing
            context = candidate
            context["pixel_selection_mask"] = merge(mask,Dict("path"=>name*"/"*mask["path"]))
        else
            previous = context["pixel_selection_mask"]
            all(key -> get(previous,key,nothing)==get(mask,key,nothing),
                union(setdiff(Set(keys(previous)),Set(["path"])),setdiff(Set(keys(mask)),Set(["path"])))) ||
                throw(ArgumentError("branch selection masks differ; shared authored selection cannot represent them"))
            delete!(candidate,"pixel_selection_mask")
            for (key,value) in candidate
                haskey(context,key) && context[key]!=value && throw(ArgumentError("branch calibration contexts conflict"))
                context[key] = value
            end
        end
        reports[name] = report
        branch_paths[name] = branch_root
    end
    required_projection = haskey(recipe_document,"upstream_reference") ?
        Set(["command-projection","physical-to-modes","modes-to-reference"]) : Set(["command-projection","physical-to-modes"])
    Set(keys(index["physical_projection"]))==required_projection || throw(ArgumentError("indexed physical mappings are incomplete"))
    for (name,descriptor) in index["physical_projection"]
        path = D.relative_asset(bundles,descriptor["path"])
        Common.sha256_file(path)==descriptor["sha256"] || throw(ArgumentError("shared projection hash mismatch"))
        for report in values(reports)
            get(report["artifact_sha256"],name*".fits",nothing)==descriptor["sha256"] ||
                throw(ArgumentError("branches do not share the indexed projection"))
        end
    end
    mkpath(dirname(selected))
    mktempdir(dirname(selected);prefix=".calibration-materialization-") do temporary
        staged = joinpath(temporary,"calibration")
        mkpath(staged)
        for (name,path) in branch_paths
            cp(path,joinpath(staged,name))
        end
        cp(indexpath,joinpath(staged,"calibration.yaml"))
        command_count = first(values(reports))["command_count"]
        command_count isa Int && 1 <= command_count <= 16384 &&
            all(report -> report["command_count"]==command_count,values(reports)) ||
            throw(ArgumentError("accepted branches must declare the same bounded physical command count"))
        Calibration.write_fits(joinpath(staged,zero_command),zeros(Float32,command_count))
        Common.write_yaml(joinpath(staged,"context.yaml"),context;
            header="Generated by PipeWireAORTC.InstrumentExport.materialize_calibration from accepted branch bundles.")
        resolved = InstrumentConfiguration.calibration_context(context,staged)
        graphcontext = graph_context(InstrumentConfiguration.json_value(InstrumentConfiguration.physical_definition(builtin_rtc.instrument));
            dimensions=builtin_rtc.document["dimensions"],mirror_controls=builtin_rtc.controls["deformable_mirrors"],calibration=resolved)
        for (name,graph) in graphs
            resolve_graph_configuration(D.decode(D.relative_asset(root,graph),prefix),graphcontext)==
                D.decode(joinpath(branch_paths[name],"graph.conf"),prefix) ||
                throw(ArgumentError("accepted context does not reproduce authored branch graph $name"))
        end
        updated = deepcopy(authored_rtc)
        physical = InstrumentConfiguration.referenced_instrument(rtcpath,authored_rtc["instrument"]).path
        D.relative_asset(root,relpath(physical,root))
        updated["instrument"] = relpath(physical,selected)
        updated["calibration"] = destination*"/context.yaml"
        updated["calibration_identity"] = identity
        Common.write_yaml(joinpath(staged,"rtc.yaml"),updated;
            header="Selected accepted simulation calibration; regenerate with InstrumentExport.materialize_calibration from $rtc_configuration.")
        Common.write_yaml(joinpath(staged,"selection.yaml"),Dict("version"=>1,
            "calibration_identity"=>identity,"calibration_index_sha256"=>Common.sha256_file(indexpath),
            "source_application_deployment_sha256"=>Common.sha256_file(joinpath(built,"deployment.conf")),
            "recipe_sha256"=>Common.sha256_file(recipepath),"graphs"=>Dict(graphs),
            "rtc_configuration"=>Dict("path"=>"rtc.yaml","sha256"=>Common.sha256_file(joinpath(staged,"rtc.yaml"))),
            "zero_command"=>Dict("path"=>zero_command,"sha256"=>Common.sha256_file(joinpath(staged,zero_command)),
                "shape"=>[command_count],"type"=>"Float32"),
            "application_accepted"=>false);
            header="Generated accepted simulation calibration selection; application and hardware qualification remain separate.")
        mv(staged,selected)
    end
    return selected
end

"Bind the generated RTC selection to the configuration actually executed by its source owner."
function validate_selected_rtc(application, calibration, selection, index, simulation)
    descriptor = get(selection,"rtc_configuration",nothing)
    descriptor isa AbstractDict && Set(keys(descriptor)) == Set(["path","sha256"]) &&
        descriptor["path"] == "rtc.yaml" || throw(ArgumentError("selected calibration requires its generated RTC descriptor"))
    name = normpath(joinpath(calibration,descriptor["path"]))
    path = D.relative_asset(application,name)
    Common.sha256_file(path) == descriptor["sha256"] ||
        throw(ArgumentError("selected RTC configuration hash differs from calibration receipt"))
    get(simulation,"rtc_configuration",nothing) == name ||
        throw(ArgumentError("source execution is disconnected from selected RTC configuration"))
    rtc = Common.read_yaml(path)
    get(rtc,"calibration_identity",nothing) == get(simulation,"calibration_identity",nothing) == index["calibration_identity"] ||
        throw(ArgumentError("selected RTC and source execution identities differ from calibration index"))
    get(rtc,"calibration",nothing) == normpath(joinpath(calibration,"context.yaml")) ||
        throw(ArgumentError("selected RTC configuration must use its generated calibration context"))
    return name
end
