# The standalone source has no WFS frontend or graph parameter adoption. Its
# accepted physical projection is selected explicitly in generated RTC data.
function validate_pupil_equivalence end
function validate_pupil_source end

function prepare_pupil_feedback(mainroot,main,componentroot,extra,output,recipe,document,profilepath,selected_profile;prefix)
    receiver=document["receiver"]
    fields=Set(("kind","owner","mirror","rtc_configuration","simulation_configuration","template","configuration"))
    receiver isa AbstractDict && Set(keys(receiver))==fields && receiver["kind"]=="pupil-source" ||
        throw(ArgumentError("invalid pupil-source receiving composition declaration"))
    namespace=document["namespace"]
    role=receiver["owner"]
    role==main["source-owner"] || throw(ArgumentError("pupil source receiver must belong to the declared source owner"))
    owner=only(filter(owner->owner["role"]==role,main["owners"]))
    configarg=findfirst(==("--config"),owner["argv"])
    configarg!==nothing && configarg<length(owner["argv"]) &&
        owner["argv"][configarg+1]=="@PACKAGE@/"*receiver["simulation_configuration"] ||
        throw(ArgumentError("pupil source owner does not execute its declared simulation configuration"))
    simulation=D.decode(D.relative_asset(mainroot,receiver["simulation_configuration"]),prefix)
    simulation["version"]===5 && simulation["mode"]=="pupil-source" && simulation["mirror"]==receiver["mirror"] ||
        throw(ArgumentError("pupil-source composition requires its declared version-5 physical mirror"))
    upstream=get(selected_profile,"upstream",Dict("backend"=>selected_profile["backend"],"device"=>selected_profile["device"]))
    simulation["backend"]==upstream["backend"] && simulation["device"]==upstream["device"] ||
        throw(ArgumentError("pupil source backend differs from explicit preparation profile"))
    component_simulation=D.decode(D.relative_asset(componentroot,"simulation.conf"),prefix)
    component_simulation["backend"]==selected_profile["backend"] && component_simulation["device"]==selected_profile["device"] ||
        throw(ArgumentError("component backend differs from explicit preparation profile"))
    calibration=document["calibration"]
    indexpath=D.relative_asset(componentroot,calibration*"/calibration.yaml")
    index=Common.read_yaml(indexpath)
    get(index,"version",nothing)===1 && get(index,"kind",nothing)=="optical-calibration-index" ||
        throw(ArgumentError("pupil source requires optical calibration index version 1"))
    selection=Common.read_yaml(D.relative_asset(componentroot,calibration*"/selection.yaml"))
    selection["calibration_index_sha256"]==Common.sha256_file(indexpath) &&
        selection["calibration_identity"]==index["calibration_identity"] || throw(ArgumentError("component calibration selection mismatch"))
    validate_selected_rtc(componentroot,calibration,selection,index,component_simulation)
    branches=index["branches"]
    branches isa AbstractDict && 1<=length(branches)<=8 &&
        all(name->name isa String && occursin(r"^[a-z][a-z0-9-]{0,31}$",name) && branches[name]["path"]==name,keys(branches)) ||
        throw(ArgumentError("physical receiver requires bounded indexed branch directories"))
    Calibration=getfield(parentmodule(@__MODULE__),:InstrumentCalibration)
    reports=Dict{String,Any}()
    for name in sort!(collect(keys(branches)))
        path=D.relative_asset(componentroot,calibration*"/"*name*"/result.yaml")
        Common.sha256_file(path)==branches[name]["result_sha256"] || throw(ArgumentError("indexed branch result hash mismatch"))
        report=Calibration.read_bundle(dirname(path)).report
        validate_chopped_calibration(report,component_simulation)
        get(report,"status",nothing)=="accepted" && get(report,"built_application_calibration",false)===true &&
            get(report,"diagnostic",true)===false && get(report,"deployable",false)===true &&
            get(get(report,"held_out",Dict()),"accepted",false)===true && report["branch"]==name &&
            report["calibration_identity"]==index["calibration_identity"] && report["branches"][name]["accepted"]===true ||
            throw(ArgumentError("selected branch is not an accepted deployable physical calibration"))
        for key in ("command-projection","physical-to-modes")
            descriptor=index["physical_projection"][key]
            report["artifact_sha256"][key*".fits"]==descriptor["sha256"] ||
                throw(ArgumentError("selected branches differ from shared physical calibration"))
        end
        reports[name]=report
    end
    reference=first(values(reports))
    all(report->report["upstream_prescription_identity"]==reference["upstream_prescription_identity"] &&
        report["recipe"]==reference["recipe"] && report["provenance"]==reference["provenance"],values(reports)) ||
        throw(ArgumentError("physical branches do not share their calibrated mirror and recipe"))
    rtc=InstrumentConfiguration.load_rtc(D.relative_asset(mainroot,receiver["rtc_configuration"]))
    simulation["rtc_configuration"]==receiver["rtc_configuration"] || throw(ArgumentError("pupil source RTC selection is disconnected"))
    physical=InstrumentConfiguration.json_value(InstrumentConfiguration.physical_definition(rtc.instrument))
    mirror=physical["deformable_mirrors"][receiver["mirror"]]
    command_order=InstrumentDefinition.scientific_identity(InstrumentConfiguration.canonical(Dict(
        "mirror"=>receiver["mirror"],"units"=>rtc.instrument.document["deformable_mirrors"][receiver["mirror"]]["units"],"layout"=>mirror["layout"])))
    context=graph_context(physical;dimensions=rtc.document["dimensions"],mirror_controls=rtc.controls["deformable_mirrors"],calibration=rtc.calibration)
    shared=index["physical_projection"]
    context["calibration"]["cal2"]=Dict("calibration_identity"=>index["calibration_identity"],"command_order"=>command_order,
        "projection_sha256"=>shared["command-projection"]["sha256"],"inverse_sha256"=>shared["physical-to-modes"]["sha256"])
    contract=Common.configuration_value(Common.read_yaml(composition_source(recipe,receiver["template"])),context)
    Set(keys(contract["branches"]))==Set(keys(branches))==Set(keys(selected_profile["silence_ns"])) ||
        throw(ArgumentError("physical receiver and pacing profile must name every calibrated branch"))
    matrices=Dict{String,Matrix{Float32}}()
    for (field,key) in (("projection","command-projection"),("inverse","physical-to-modes"))
        descriptor=contract[field]
        path=component_asset(componentroot,namespace,receiver["configuration"],descriptor["path"])
        path==D.relative_asset(componentroot,calibration*"/"*shared[key]["path"]) && descriptor["sha256"]==Common.sha256_file(path) ||
            throw(ArgumentError("physical receiver mapping differs from accepted projection"))
        matrices[field]=Artifacts.prepare(Artifacts.FITSArtifact(path;axes=descriptor["axes"]),Float32,Tuple(descriptor["shape"])).data
    end
    for (name,row) in contract["branches"]
        row["modes"]==reports[name]["recipe"]["branch_modes"][name] || throw(ArgumentError("physical branch mode authority differs from calibration"))
        row["silence_ns"]=selected_profile["silence_ns"][name]
    end
    contract["calibration_identity"]==index["calibration_identity"] && contract["command_order"]==command_order ||
        throw(ArgumentError("physical receiver identity differs from selected calibration or instrument"))
    Base.require(Main,:AdaptiveOpticsSim)
    Base.require(Main,:AdaptiveOpticsSimPipeWireHIL)
    Base.require(Main,:AdaptiveOpticsCalibration)
    Base.require(Main,:FilterGraphIsland)
    equivalence=Base.invokelatest(validate_pupil_equivalence,mainroot,componentroot,simulation,reference,matrices["projection"];
        mirror=receiver["mirror"],prefix)
    count=length(mirror["layout"]["command_positions"])
    size(matrices["projection"],1)==count || throw(DimensionMismatch("physical projection differs from command order"))
    arguments=document["owner_arguments"]
    Set(keys(arguments))==Set(("role","threads","append")) && arguments["role"]==role && arguments["threads"] isa String &&
        something(tryparse(Int,first(split(arguments["threads"],','))),0)>=3 ||
        throw(ArgumentError("pupil source requires explicit owner arguments with three default threads"))
    arguments["append"]==["--physical-offsets","@PACKAGE@/"*receiver["configuration"]] ||
        throw(ArgumentError("physical offsets argument must name the explicit receiver contract"))
    argv=copy(owner["argv"])
    argv[only(findall(arg->startswith(arg,"--threads="),argv))]="--threads="*arguments["threads"]
    "--physical-offsets" ∉ argv || throw(ArgumentError("pupil source already selects a receiver"))
    append!(argv,arguments["append"])
    sinks=[Dict("node.name"=>row["node_name"],"ownership"=>"external","ports"=>[Dict("name"=>"input_1","direction"=>"input",
        "shape"=>[count],"element-type"=>"F32_LE","layout"=>"ROW_MAJOR","schema"=>row["schema"])]) for row in values(contract["branches"])]
    selected_rtc="generated/physical-offset-calibration/rtc.yaml"
    !ispath(joinpath(mainroot,dirname(selected_rtc))) || throw(ArgumentError("physical calibration selection destination must be fresh"))
    selected_document=deepcopy(rtc.authoring)
    selected_document["instrument"]=relpath(rtc.instrument.path,joinpath(mainroot,dirname(selected_rtc)))
    selected_document["calibration_identity"]=index["calibration_identity"]
    selected_publication="generated/physical-offset-calibration/instrument.json"
    selected_document["publication"]=selected_publication
    publication=InstrumentConfiguration.json_value(InstrumentConfiguration.publication(D.relative_asset(mainroot,receiver["rtc_configuration"])))
    publication["calibration_identity"]=index["calibration_identity"]
    paced=deepcopy(simulation)
    AOSOwner.pacing_period(selected_profile["pacing_rate_hz"],simulation["rate"])
    paced["pacing_rate_hz"]=selected_profile["pacing_rate_hz"]
    paced["rtc_configuration"]=selected_rtc
    paced["calibration_identity"]=index["calibration_identity"]
    paced["instrument"]=selected_publication
    !ispath(output) || throw(ArgumentError("feedback output must be fresh"))
    mkpath(dirname(output))
    mktempdir(dirname(output);prefix=".pupil-feedback-") do temporary
        files=Dict{String,String}()
        function write_override(relative,document;yaml=false)
            file=joinpath(temporary,string(length(files))*"."*(yaml ? "yaml" : "json"))
            yaml ? Common.write_yaml(file,document;header="Generated from explicit physical calibration selection; regenerate with prepare_feedback.") : Common.write_json(file,document)
            files[relative]=file
            return file
        end
        receiverfile=write_override(receiver["configuration"],contract;yaml=true)
        # Validate exactly the strict v2 contract after rebasing its FITS paths
        # to the composed application; the final check below uses these bytes.
        write_override(receiver["simulation_configuration"],paced)
        rtcfile=write_override(selected_rtc,selected_document;yaml=true)
        write_override(selected_publication,publication)
        receipt=Dict("version"=>1,"calibration_identity"=>index["calibration_identity"],
            "calibration_index_sha256"=>Common.sha256_file(indexpath),"component_calibration"=>"components/"*namespace*"/"*calibration,
            "source_prescription_identity"=>simulation["prescription_identity"],
            "original_calibration_identity"=>rtc.document["calibration_identity"],
            "original_deployment_sha256"=>Common.sha256_file(joinpath(mainroot,"deployment.conf")),
            "original_simulation_sha256"=>Common.sha256_file(D.relative_asset(mainroot,receiver["simulation_configuration"])),
            "original_rtc_configuration"=>receiver["rtc_configuration"],"original_rtc_sha256"=>Common.sha256_file(D.relative_asset(mainroot,receiver["rtc_configuration"])),
            "rtc_configuration"=>Dict("path"=>selected_rtc,"sha256"=>Common.sha256_file(rtcfile)),"physical_equivalence"=>equivalence)
        write_override("generated/physical-offset-calibration/selection.yaml",receipt;yaml=true)
        files["rtc/feedback-composition.yaml"]=recipe
        files["rtc/feedback-profile.yaml"]=profilepath
        # Explicit calibration selection creates a new sealed base. The normal
        # compositor continues protecting both input instrument publications.
        selected_base=joinpath(temporary,"selected-base")
        cp(mainroot,selected_base)
        for relative in (selected_rtc,selected_publication,receiver["simulation_configuration"],"generated/physical-offset-calibration/selection.yaml")
            target=joinpath(selected_base,relative)
            mkpath(dirname(target));cp(pop!(files,relative),target;force=true)
        end
        cp(joinpath(mainroot,"deployment.conf"),joinpath(selected_base,"generated/physical-offset-calibration/original-deployment.conf"))
        cp(D.relative_asset(mainroot,receiver["simulation_configuration"]),joinpath(selected_base,"generated/physical-offset-calibration/original-simulation.conf"))
        selected_spec=deepcopy(main)
        selected_spec["instrument"]=selected_publication
        Common.write_json(joinpath(selected_base,"deployment.conf"),selected_spec)
        seal!(selected_base)
        staged=compose(selected_base,componentroot,joinpath(temporary,"application");namespace,roles=document["roles"],links=document["links"],
            overrides=files,prefix,owner_arguments=Dict(role=>argv),sinks,node_owners=Dict(sink["node.name"]=>role for sink in sinks))
        Base.invokelatest(validate_pupil_source,staged,receiver["simulation_configuration"],receiver["configuration"];prefix)
        mv(staged,output)
        return output
    end
end
