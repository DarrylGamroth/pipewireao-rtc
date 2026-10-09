# Included by HeartCorrectionExport. The actual four-direction native capture
# must reproduce through the maintained trusted SDK/HIL replay before install.
function classic_geometry_inputs(base,provenance,specification,sections,calibration_root,prefix)
    maps=HeartCalibrationExport.classic_selected_resources(base,provenance,specification,prefix)
    offsets=HeartConfiguration.calibration_inputs(base,provenance;pipewire_prefix=prefix)
    offsets.mode=="operational" || throw(ArgumentError("Classic active correction requires the accepted measured offsets"))
    active=read(offsets.active)
    active==UInt8[index in (86,87,102,103) ? 0 : 1 for index in 1:188] || throw(ArgumentError("Classic active eligibility differs"))
    inverse=only(filter(row->row["name"]=="reconstructor",provenance["parameters"]))
    inverse["shape"]==[221,376] && inverse["element_type"]=="F32_LE" || throw(ArgumentError("Classic compact selected inverse differs"))
    compact=joinpath(base,"calibration",inverse["file"])
    specification["artifacts"]["calibration/"*inverse["file"]]==digest(compact)==HeartClassicTransfer.COMPACT_SHA ||
        throw(ArgumentError("Classic inverse bytes differ from the selected descriptor"))
    resource(name)=joinpath(base,"calibration",only(filter(row->row["name"]==name,provenance["parameters"]))["file"])
    T_path=resource("full-to-active");B_path=resource("active-to-full")
    root=realpath(calibration_root)
    source=HeartConfiguration.one(sections["DM"],"VDM_EXTRAPOLATION_FILE","VDM_NUM")["FILE"]
    native_E_path=HeartConfiguration.inside_root(realpath(joinpath(root,source)),root)
    E=ClassicGeometry.sparse_extrapolation(native_E_path)
    R=ClassicGeometry.read_wire(compact,(221,376))
    T=ClassicGeometry.read_wire(T_path,(221,277));B=ClassicGeometry.read_wire(B_path,(277,221))
    lifted=ClassicGeometry.lift(R,T,E,B)
    P=zeros(Float32,277,277);for index in 1:277;P[index,index]=1;end
    inputs=Dict(joinpath(base,"deployment.conf")=>digest(joinpath(base,"deployment.conf")),
        native_E_path=>digest(native_E_path),compact=>digest(compact),T_path=>digest(T_path),B_path=>digest(B_path),
        offsets.active=>digest(offsets.active),offsets.background=>digest(offsets.background),offsets.reference=>digest(offsets.reference),
        CLASSIC_GEOMETRY_RESOURCE=>CLASSIC_GEOMETRY_SHA)
    for (relative,hash) in maps;inputs[joinpath(base,relative)]=hash;end
    exact_inputs!(Dict{String,String}(),inputs)
    return (;E,P,lifted,active,inputs,offsets,native_E_path)
end

function export_classic_package(args,base,output,backend,specification,provenance)
    required=(:transfer_package,:transfer_evidence,:transfer_lifecycle,:transfer_score,:transfer_score_sha256,:forward_model,:accepted_preparation)
    all(hasproperty(args,key) for key in required) || throw(ArgumentError("Classic active correction requires actual sealed native transfer evidence and maintained replay inputs"))
    provenance["engine"]=="fgn" && provenance["profile"]=="classic" && provenance["hil"]["frames"]==256 ||
        throw(ArgumentError("Classic correction requires the frozen normal 256-frame FGN plant"))
    CalibrationCampaign.validate_simulator_backend(base,specification,provenance;allowed_backends=(backend,))
    name=deployment_name("classic",backend)
    evidence=abspath(args.owner_evidence_directory)
    !ispath(evidence) && !islink(evidence) && isdir(dirname(evidence)) &&
        ncodeunits(joinpath(evidence,"window-2","probe-$(typemax(UInt64)).csv"))<=127 ||
        throw(ArgumentError("Classic evidence must be fresh and leave bounded native command paths"))
    evidence!=output && !startswith(evidence,output*"/") || throw(ArgumentError("Classic evidence must be external"))
    override=realpath(args.pipewireao_jl_root)
    read(joinpath(override,"Project.toml"))==read(joinpath(base,"hil/packages/PipeWireAO/Project.toml")) &&
        occursin("allow_zero_sequence::Bool=false",read(joinpath(override,"src/ndarray_exchange.jl"),String)) ||
        throw(ArgumentError("Classic correction requires the exact-zero public receive dependency"))
    helper_hashes=Dict(name=>digest(joinpath(base,"hil",name)) for name in FROZEN_HELPERS)
    all(digest(joinpath(ScienceExport.resource_root(),"hil",name))==hash for (name,hash) in helper_hashes) ||
        throw(ArgumentError("Classic correction must preserve all four normal scientific helpers"))
    _,source_sections=HeartConfiguration.load_config(args.heart_source_config)
    geometry=classic_geometry_inputs(base,provenance,specification,source_sections,args.calibration_root,args.pipewire_prefix)
    source_hashes=Dict(name=>digest(joinpath(args.heart_root,name)) for name in SOURCE_FILES)
    plant_hash=digest(joinpath(base,"hil/plant.toml"))
    admission=HeartClassicTransfer.replay_admission(realpath(args.transfer_package),realpath(args.transfer_evidence),
        realpath(args.transfer_lifecycle),realpath(args.transfer_score);reported_sha256=args.transfer_score_sha256,
        forward_model=realpath(args.forward_model),accepted_preparation=realpath(args.accepted_preparation))
    admission["selected_compact_inverse_sha256"]==HeartClassicTransfer.COMPACT_SHA &&
        admission["selected_controller_sha256"]==HeartClassicTransfer.PADDED_FITS_SHA || throw(ArgumentError("Classic reproduced inverse identity differs"))
    inputs=merge(copy(admission["input_files"]),geometry.inputs)
    exact_inputs!(Dict{String,String}(),inputs)
    mkpath(dirname(output))
    return mktempdir(dirname(output);prefix=".rtc-heart-correct-") do temporary
        package=joinpath(temporary,"package")
        HeartExport.export_package(merge(args,(;output=package,readout_us=0));simulator_backend=backend)
        staged=DeploymentConfiguration.profile(joinpath(package,"deployment.conf"),args.pipewire_prefix)
        staged_provenance=Common.read_json(joinpath(package,"provenance.json"))
        for file in HELPERS
            destination=joinpath(package,"hil",file);ispath(destination) && rm(destination)
            ScienceExport.copy_file(joinpath(ScienceExport.resource_root(),"hil",file),destination)
        end
        all(digest(joinpath(package,"hil",file))==hash for (file,hash) in helper_hashes) &&
            digest(joinpath(package,"hil/plant.toml"))==plant_hash || throw(ArgumentError("Classic export altered normal plant/helpers"))
        HILExport.replace_staged_package(override,package,"PipeWireAO")
        write(joinpath(package,"heart/physical-projection.f32le"),vec(permutedims(geometry.P)))
        write(joinpath(package,"heart/native-extrapolation.f32le"),vec(permutedims(geometry.E)))
        write(joinpath(package,"heart/classic-active.u8"),geometry.active)
        padded=joinpath(temporary,"padded-controller.f32le");write(padded,vec(permutedims(geometry.lifted.padded)))
        controller_file="selected-native-controller.fits"
        controller=joinpath(package,"heart/calibration",controller_file)
        HeartConfiguration.write_offset_fits(padded,controller,[277,376])
        digest(controller)==admission["selected_controller_sha256"] || throw(ArgumentError("Classic padded installed inverse differs from actual accepted transfer"))
        document,sections=HeartConfiguration.load_config(joinpath(package,"heart/config.yaml.in"))
        recurrence=native_config_contract(sections;profile="classic")
        clipping_native=basename(HeartConfiguration.one(sections["DM"],"PDM_CLIPPINGS_FILE","PDM_NUM")["FILE"])
        validate_clipping_file(joinpath(package,"heart/calibration",clipping_native))
        extrapolation_native=basename(HeartConfiguration.one(sections["DM"],"VDM_EXTRAPOLATION_FILE","VDM_NUM")["FILE"])
        digest(joinpath(package,"heart/calibration",extrapolation_native))==digest(geometry.native_E_path) || throw(ArgumentError("Classic original sparse E changed while copying"))
        HeartConfiguration.one(sections["HO"],"HO_CONTROL_MATRIX_FILE","WFS_NUM")["FILE"]="./config/"*controller_file
        sections["CB"]["TELEMETRY_FILE_STREAMS"]=[Dict("tagName"=>tag,"decimate"=>0,"pollPeriod"=>0.001) for tag in TAGS]
        pop!(sections["CB"],"TELEMETRY_SOCKET_STREAMS",nothing)
        write(joinpath(package,"heart/config.yaml.in"),HeartConfiguration.serialize_config(document,args.heart_source_config))
        native=only(filter(owner->owner["role"]=="heart",staged["owners"]))
        native["environment"]["HRT_DEFER_WFS_INGRESS"]="0";append!(native["argv"],["--native-ingress-mode","streaming"])
        simulator=only(filter(owner->owner["role"]==staged["source-owner"],staged["owners"]))
        CalibrationExport.correction_source_control!(simulator, "classic")
        simulator["argv"]=owner_arguments(simulator["argv"],evidence,128*1024*1024;profile="classic")
        Common.write_json(joinpath(package,"session.conf.in"),HeartCalibrationExport.calibration_session(provenance["hil"]["wall_rate_hz"];profile="classic"))
        core=DeploymentConfiguration.decode(joinpath(package,staged["core"]),args.pipewire_prefix)
        wfs=only(filter(item->get(get(item,"args",Dict()),"factory.name",nothing)=="api.heart.std-wfs.sink",core["context.objects"]))["args"]
        ingress=HeartCalibrationExport.ingress_contract("streaming","classic",wfs,joinpath(package,"heart/bin/scaoTemplate");source_revision=staged_provenance["heart"]["revision"])
        runtime_inputs=Dict(basename(path)=>digest(path) for path in readdir(joinpath(package,"heart/calibration");join=true))
        threshold_native=basename(HeartConfiguration.one(sections["HO"],"SUBAP_THRES_FLUX","WFS_NUM")["FILE"])
        threshold_values=HeartConfiguration.native_float_values(joinpath(package,"heart/calibration",threshold_native),[1,188])
        thresholds=Float32.(threshold_values)
        all(==(1000f0),thresholds) || throw(ArgumentError("Classic qualified normal flux thresholds differ"))
        threshold_wire=joinpath(package,"heart/classic-flux-thresholds.f32le")
        write(threshold_wire,thresholds)
        flags=[Dict("section"=>section,"field"=>field,"value"=>value) for (section,field,value) in HeartOwner.read_requirements(joinpath(package,"heart/requirements.json"))]
        NativeFlags.validate_flags(flags,:classic)
        contract=merge(recurrence,Dict("version"=>1,"profile"=>"classic","controller_coordinates"=>277,"frames"=>256,
            "native_ingress_mode"=>"streaming","native_telemetry_max_bytes"=>128*1024*1024,
            "detector_acceptance_policy"=>"normal-correction-adc-bounded-replay-v1",
            "normal_response_policy"=>"normal-classic-flux-state-v1","flux_threshold_native_file"=>threshold_native,
            "flux_threshold_native_sha256"=>runtime_inputs[threshold_native],"flux_threshold_wire_sha256"=>digest(threshold_wire),"native_ingress"=>ingress,"runtime_flags"=>flags,"plant_sha256"=>plant_hash,
            "projection_wire_sha256"=>digest(joinpath(package,"heart/physical-projection.f32le")),"projection_native_file"=>nothing,
            "physical_projection_mode"=>"native-default-copy","extrapolation_wire_sha256"=>digest(joinpath(package,"heart/native-extrapolation.f32le")),
            "extrapolation_native_file"=>extrapolation_native,"wfs_active_sha256"=>digest(joinpath(package,"heart/classic-active.u8")),
            "runtime_inputs"=>runtime_inputs,"clipping_native_file"=>clipping_native,"native_config_sha256"=>digest(joinpath(package,"heart/config.yaml.in")),
            "native_executable_sha256"=>digest(joinpath(package,"heart/bin/scaoTemplate")),"native_source_revision"=>staged_provenance["heart"]["revision"],
            "native_source_files"=>source_hashes,"frozen_helpers"=>helper_hashes,"transfer_score_sha256"=>args.transfer_score_sha256,
            "selected_compact_inverse_sha256"=>admission["selected_compact_inverse_sha256"],"selected_controller_sha256"=>admission["selected_controller_sha256"],
            "native_controller_file"=>controller_file,"native_controller_fits_sha256"=>runtime_inputs[controller_file],
            "controlled_native_indices"=>geometry.lifted.indices,"scope"=>"finite Classic active CORRECT after actual bounded accepted-inverse transfer; active utility/reset/shutdown remain empirical gates"))
        Common.write_json(joinpath(package,"heart-cold-admission.json"),admission)
        contract["cold_admission_sha256"]=digest(joinpath(package,"heart-cold-admission.json"))
        Common.write_json(joinpath(package,"heart-active-contract.json"),contract)
        staged_provenance["heart_correction"]=Dict("version"=>1,"active_contract_sha256"=>digest(joinpath(package,"heart-active-contract.json")),
            "input_files"=>inputs,"normal_base_sha256"=>digest(joinpath(base,"deployment.conf")),"plant_sha256"=>plant_hash,
            "frozen_helpers"=>helper_hashes,"native_ingress"=>ingress,"scope"=>"Classic positive padded selected inverse through original sparse E; original HO gain/pole retained; active correction pending")
        Common.write_json(joinpath(package,"provenance.json"),staged_provenance)
        staged["name"]=name;staged["artifacts"]=HeartExport._artifacts(package)
        Common.write_json(joinpath(package,"deployment.conf"),staged)
        exact_inputs!(Dict{String,String}(),inputs)
        all(digest(joinpath(args.heart_root,file))==hash for (file,hash) in source_hashes) || throw(ArgumentError("native source changed during Classic preparation"))
        DeploymentConfiguration.profile(joinpath(package,"deployment.conf"),args.pipewire_prefix)
        mv(package,output)
        return joinpath(output,"deployment.conf")
    end
end
