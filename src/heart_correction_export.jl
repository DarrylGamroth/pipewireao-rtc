"""Prepare finite active native Copper or Classic correction comparisons.

Admission requires Copper locked utility or Classic measured transfer of its
accepted inverse. The normal simulator graph and controller gains are retained. Native CORRECT,
actual per-frame telemetry, clipping exclusion, reset and public shutdown are
separate runtime gates; preparation cannot qualify them.
"""
module HeartCorrectionExport

using SHA, TOML
using ..Common, ..DeploymentConfiguration, ..ScienceExport, ..HILExport, ..HeartConfiguration
using ..HeartExport, ..HeartCalibrationExport, ..HeartOwner, ..CalibrationCampaign, ..HeartClassicTransfer
import ..CalibrationExport

const CLASSIC_GEOMETRY_RESOURCE=joinpath(ScienceExport.resource_root(),"hil/heart_classic_projection.jl")
Base.include_dependency(CLASSIC_GEOMETRY_RESOURCE)
include(CLASSIC_GEOMETRY_RESOURCE)
const ClassicGeometry=HeartClassicProjection
const FLAGS_RESOURCE=joinpath(ScienceExport.resource_root(),"hil/heart_correction_flags.jl")
Base.include_dependency(FLAGS_RESOURCE)
include(FLAGS_RESOURCE)
const NativeFlags=HeartCorrectionFlags
const CLASSIC_GEOMETRY_SHA=Common.sha256_file(CLASSIC_GEOMETRY_RESOURCE)

export export_package, main
const HELPERS=(HeartCalibrationExport.HELPERS...,"heart_calibration_coordinates.jl",
    "calibration_inverse_analysis.jl","calibration_selection.jl","heart_correction_telemetry.jl","heart_correction_owner.jl","analyze_correction.jl",
    "heart_calibration_capture.jl","heart_calibration_capture_inputs.jl","heart_correction_admission.jl","heart_correction_analysis.jl","heart_correction_profiles.jl","heart_correction_phases.jl","heart_classic_projection.jl","heart_correction_flags.jl")
const FROZEN_HELPERS=("simulator.jl","simulator_owner.jl","native_owner_bootstrap.jl","jfg_owner.jl","owner_protocol.jl","correction_truth.jl","analyze_correction.jl")
const SOURCE_FILES=("source/blocks/src/hrtClwcBlock.c","source/blocks/src/hrtTfcBlock.c",
    "source/blocks/src/hrtHoReconBlock.c","source/template/src/hrtTemplateCmds.c",
    "source/template/src/hrtTemplateCB.c","source/config/src/hrtConfig.c",
    "source/device/src/hrtStdWfsHandler.c","source/device/src/hrtStdDmHandler.c",
    "source/blocks/src/hrtWcOutputBlock.c","source/util/src/hrtTelemetry.c","source/util/src/hrtCircBuffer.c")
const TAGS=(HeartCalibrationExport.TELEMETRY_TAGS...,"cbClUnclipped#")
digest(path)=Common.sha256_file(path)
option(args,name,default=nothing)=HeartExport.option(args,name,default)

function deployment_name(profile,backend)
    profile in ("copper","classic") && backend in ("cpu","cuda") || throw(ArgumentError("native correction name requires an available profile/backend"))
    name="$profile-heart-$backend-correction"
    occursin(r"^[a-z0-9][a-z0-9-]{0,39}$",name) || throw(ArgumentError("native correction deployment name exceeds its bound"))
    return name
end

function exact_inputs!(inputs,records)
    for (path,hash) in records
        isfile(path) && !islink(path) && digest(path)==hash || throw(ArgumentError("native correction consumed input differs: $path"))
        inputs[abspath(path)]=hash
    end
    return nothing
end

function locked_inputs(path,hash)
    inputs=Dict{String,String}()
    exact_inputs!(inputs,Dict(path=>hash))
    locked=Common.read_json(path;maximum=512*1024*1024)
    get(locked,"engine",nothing)=="heart" && get(locked,"mode",nothing)=="locked" &&
        get(locked,"passed",nothing)===true && get(locked,"native_ingress_mode",nothing)=="deferred" ||
        throw(ArgumentError("native correction requires passed selected-only native locked utility"))
    exact_inputs!(inputs,locked["input_files"])
    selected_path=locked["selection_path"]
    exact_inputs!(inputs,Dict(selected_path=>locked["selection_sha256"]))
    selected=Common.read_json(selected_path;maximum=512*1024*1024)
    selected["engine"]=="heart" && selected["mode"]=="select" && selected["passed"]===true &&
        selected["preparation_sha256"]==locked["preparation_sha256"] &&
        selected["native_reference_seal_sha256"]==locked["native_reference_seal_sha256"] &&
        selected["policy_sha256"]==locked["policy_sha256"] && selected["controller_sign"]==-1 &&
        selected["estimator_shape"]==[253,3600] && selected["layout"]=="ROW_MAJOR" &&
        selected["element_type"]=="F32_LE" || throw(ArgumentError("native locked selection representation differs"))
    exact_inputs!(inputs,selected["input_files"])
    estimator=joinpath(dirname(selected_path),"selected-estimator.f32le")
    controller=joinpath(dirname(selected_path),"selected-controller.f32le")
    exact_inputs!(inputs,Dict(estimator=>selected["selected_estimator_sha256"],controller=>selected["selected_controller_sha256"]))
    locked["selected_estimator_sha256"]==selected["selected_estimator_sha256"] &&
        locked["selected_controller_sha256"]==selected["selected_controller_sha256"] ||
        throw(ArgumentError("native locked controller bytes differ"))
    filesize(controller)==filesize(estimator)==253*3600*4 || throw(ArgumentError("native selected matrix extent differs"))
    R=permutedims(reshape(reinterpret(Float32,read(estimator)),3600,253))
    native=permutedims(reshape(reinterpret(Float32,read(controller)),3600,253))
    all(isfinite,R) && all(isfinite,native) && all(iszero,R[1:3,:]) &&
        all(iszero,native[1:3,:]) && native[4:end,:]==-R[4:end,:] ||
        throw(ArgumentError("native negative-estimator/null-coordinate contract differs"))
    return (;inputs,locked,selected,estimator,controller)
end

function replay_admission(inputs,locked_path,locked_hash)
    grid=Common.read_json(inputs.locked["preparation_path"];maximum=512*1024*1024)
    cohort=Common.read_json(grid["cohort_path"];maximum=512*1024*1024)
    package=only(filter(stage->stage["name"]=="zonal-1",cohort["stages"]))["package"]
    helper=joinpath(ScienceExport.resource_root(),"hil/heart_correction_admission.jl")
    before=digest(helper)
    return mktempdir() do temporary
        output=joinpath(temporary,"admission.json")
        checked=Common.run_checked([Base.julia_cmd().exec[1],"--startup-file=no","--threads=1", "--project="*joinpath(package,"hil"),
            helper,locked_path,locked_hash,output];timeout=1800,
            env=Dict("JULIA_LOAD_PATH"=>joinpath(package,"julia")*":@:@stdlib","JULIA_NUM_THREADS"=>"1","OPENBLAS_NUM_THREADS"=>"1"))
        checked.returncode==0 || throw(ErrorException("native correction cold science replay failed: $(checked.stderr)"))
        digest(helper)==before || throw(ArgumentError("native admission helper changed during replay"))
        result=Common.read_json(output;maximum=512*1024*1024)
        result["passed"]===true && result["locked_test_sha256"]==locked_hash &&
            result["actual_native_captures_revalidated"]==10 && result["actual_native_references_revalidated"]==2 &&
            all(result[key]===true for key in ("actual_training_grid_reproduced","actual_validation_selection_reproduced","actual_locked_utility_reproduced")) ||
            throw(ArgumentError("native correction actual science replay incomplete"))
        return result
    end
end

function native_config_contract(sections;profile::String="copper")
    profile in ("copper","classic") || throw(ArgumentError("unsupported native correction profile"))
    copper=profile=="copper"
    coordinates=copper ? 253 : 277
    gain=copper ? 0.01 : -0.3
    HC=HeartConfiguration
    gen,ho,lo,dm,tfc,clwc=(sections[key] for key in ("GEN","HO","LO","DM","TFC","CLWC"))
    for (section,key,value) in ((gen,"MODAL_CTRL",copper ? 1 : 0),(gen,"HO_POLC",0),(gen,"LO_POLC",0),
        (ho,"RECONSTRUCTED_VECT_SIZE",coordinates),(lo,"WFS_COUNT",0),(dm,"VDM_COUNT",1),(dm,"PDM_COUNT",1),
        (clwc,"CLWC_DM_SCALAR",1.0),(clwc,"CLWC_DM_LEAK_PARAM",0.99))
        HC.require_value(section,key,value)
    end
    HC.require_value(dm,"VDM_SIZES",[Dict("VDM_NUM"=>0,"SIZE"=>coordinates,"SIZE_FULL"=>coordinates,"NUM_OF_PDM"=>1)])
    HC.require_value(tfc,"TFC_INIT_GAIN_FILTER",[Dict("HO"=>gain,"LO"=>0.0)])
    for key in ("PDM_SYS_FLAT_FILE","PDM_OFFSETS_FILE")
        HC.one(dm,key,"PDM_NUM")["FILE"]=="" || throw(ArgumentError("native correction requires zero $key"))
    end
    tfc["TFC_HO_NCPA_REF_VEC_FILEPATH"]=="" || throw(ArgumentError("native correction temporal NCPA term differs"))
    reference=HC.one(ho,"NCPA_GRADS_FILE","WFS_NUM")["FILE"]
    (copper ? reference=="" : !isempty(reference)) || throw(ArgumentError("native measurement reference mode differs"))
    gains=HC.one(ho,"OPTICAL_GAIN_INITIAL","WFS_NUM")
    gains["X"]==gains["Y"]==1.0 || throw(ArgumentError("native WFS optical gain differs"))
    !haskey(ho,"OPTICAL_GAIN_HO_VECT_INITIAL") ||
        all(item->get(item,"FILE",nothing)=="",ho["OPTICAL_GAIN_HO_VECT_INITIAL"]) || throw(ArgumentError("native post-reconstructor optical gain differs"))
    for key in ("TFC_HO_TEMPORAL_FILTER","TFC_LO_TEMPORAL_FILTER")
        !haskey(tfc,key) || all(item->item["EXISTS"]==0,tfc[key]) || throw(ArgumentError("native temporal filter differs"))
    end
    for key in ("PDM_SLEW_RATE_LIMIT","PDM_MODE_SELECT")
        !haskey(dm,key) || isempty(dm[key]) ||
            (!copper && key=="PDM_SLEW_RATE_LIMIT" && all(item->item["EXISTS"]==0,dm[key])) ||
            throw(ArgumentError("native correction requires disabled $key"))
    end
    if !copper
        !haskey(dm,"VDM_TO_PDM_FILE") || throw(ArgumentError("Classic requires the original native default physical copy"))
        !isempty(HC.one(dm,"VDM_EXTRAPOLATION_FILE","VDM_NUM")["FILE"]) || throw(ArgumentError("Classic requires its original sparse extrapolation"))
    end
    return Dict("gain"=>gain,"pole"=>0.99,"integration_scalar"=>1.0,"controller_sign"=>(copper ? -1 : 1),
        "modal_intermediates"=>(copper ? "exact identity" : "padded zonal controller followed by original native sparse E and default physical copy"),
        "measurement_reference_mode"=>(copper ? "native empty gradient offset" : "exact accepted operational reference applied by unchanged native WFS"),
        "additive_terms"=>(copper ? "empty native flat/offset/NCPA files and acknowledged disabled figure/disturbance/dither/LO/POL terms" :
            "empty physical flat/offset and temporal NCPA files; bound operational WFS reference; acknowledged disabled figure/disturbance/dither/LO/POL terms"),
        "flag_scope"=>"exact INIT configuration plus strict public command ACK semantics; no private GMS/effective readback",
        "vdm_association"=>"serialized cbClUnclipped bucket/count only; null-header sync remains zero",
        "dm_association"=>"startup bucket0/sync0; active bucket1..F/sync1..F; restore bucketF+1/syncF")
end

function validate_clipping_file(path)
    !islink(path) && filesize(path)<=65536 || throw(ArgumentError("native clipping calibration exceeds its bound"))
    lines=split(chomp(read(path,String)),'\n')
    length(lines)==3 && split(lines[1])==["2","277","1","float"] || throw(ArgumentError("native physical clipping extent differs"))
    for (line,expected) in zip(lines[2:end],(0.8,-0.8))
        parse.(Float64,split(line,','))==fill(expected,277) || throw(ArgumentError("native correction requires retained limits ±0.8 micrometres"))
    end
    return nothing
end

function owner_arguments(argv,evidence,budget;profile::String="copper")
    profile in ("copper","classic") || throw(ArgumentError("unsupported native correction owner profile"))
    result=copy(argv)
    positions=findall(argument->endswith(argument,"/hil/simulator.jl"),result)
    length(positions)==1 || throw(ArgumentError("native correction requires the normal simulator owner"))
    result[only(positions)]="@PACKAGE@/hil/heart_correction_owner.jl"
    index=findfirst(==("--correction-diagnostics"),result)
    index!==nothing && result[index+1]=="true" || throw(ArgumentError("native correction requires unchanged direct OPD diagnostics"))
    append!(result,["--heart-client","@PACKAGE@/heart/bin/scaoTemplateCmdClient",
        "--heart-native-runtime","@RUNTIME@/heart/native","--heart-probe-directory",evidence,
        "--heart-telemetry-max-bytes",string(budget),"--heart-native-ingress-mode",profile=="copper" ? "deferred" : "streaming",
        "--heart-active-contract","@PACKAGE@/heart-active-contract.json",
        "--heart-projection","@PACKAGE@/heart/physical-projection.f32le"])
    profile=="classic" && append!(result,["--heart-classic-active","@PACKAGE@/heart/classic-active.u8"])
    return result
end

function export_package(args)
    base=realpath(args.base_package);output=abspath(args.output)
    !ispath(output) && !islink(output) || throw(ArgumentError("native correction output must be fresh"))
    backend=option(args,:simulator_backend,"cuda")
    backend in ("cpu","cuda") || throw(ArgumentError("native correction simulator backend unavailable"))
    specification=DeploymentConfiguration.profile(joinpath(base,"deployment.conf"),args.pipewire_prefix)
    provenance=Common.read_json(joinpath(base,"provenance.json"))
    provenance["profile"]=="classic" && return export_classic_package(args,base,output,backend,specification,provenance)
    all(hasproperty(args,key) for key in (:locked_test,:locked_test_sha256)) || throw(ArgumentError("Copper correction requires sealed locked utility"))
    name=deployment_name("copper",backend)
    provenance["engine"]=="fgn" && provenance["profile"]=="copper" && provenance["hil"]["frames"]==256 ||
        throw(ArgumentError("native correction requires the frozen normal Copper 256-frame FGN plant"))
    CalibrationCampaign.validate_simulator_backend(base,specification,provenance;allowed_backends=(backend,))
    inputs=locked_inputs(realpath(args.locked_test),args.locked_test_sha256)
    evidence=abspath(args.owner_evidence_directory)
    !ispath(evidence) && !islink(evidence) && isdir(dirname(evidence)) &&
        ncodeunits(joinpath(evidence,"window-2","probe-$(typemax(UInt64)).csv"))<=127 ||
        throw(ArgumentError("native correction evidence must be fresh and leave native CSV paths within 127 bytes"))
    !startswith(evidence,output*"/") && evidence!=output || throw(ArgumentError("native correction evidence must be external"))
    override=realpath(args.pipewireao_jl_root)
    read(joinpath(override,"Project.toml"))==read(joinpath(base,"hil/packages/PipeWireAO/Project.toml")) &&
        occursin("allow_zero_sequence::Bool=false",read(joinpath(override,"src/ndarray_exchange.jl"),String)) ||
        throw(ArgumentError("native correction requires the exact-zero public receive dependency"))
    helper_hashes=Dict(name=>digest(joinpath(base,"hil",name)) for name in FROZEN_HELPERS)
    all(digest(joinpath(ScienceExport.resource_root(),"hil",name))==hash for (name,hash) in helper_hashes) ||
        throw(ArgumentError("native correction must preserve the frozen normal scientific helpers and bootstrap SDK"))
    plant_hash=digest(joinpath(base,"hil/plant.toml"))
    projection=only(filter(item->item["name"]=="vdm-to-pdm",provenance["parameters"]))
    projection["shape"]==[277,253] || throw(ArgumentError("native physical projection shape differs"))
    projection_path=joinpath(base,"calibration",projection["file"])
    digest(projection_path)==projection["sha256"]==inputs.locked["physical_map"]["physical_map_sha256"] ||
        throw(ArgumentError("native selected physical command map differs"))
    source_hashes=Dict(name=>digest(joinpath(args.heart_root,name)) for name in SOURCE_FILES)
    admission=replay_admission(inputs,realpath(args.locked_test),args.locked_test_sha256)
    mkpath(dirname(output))
    return mktempdir(dirname(output);prefix=".rtc-heart-correct-") do temporary
        package=joinpath(temporary,"package")
        HeartExport.export_package(merge(args,(;output=package,readout_us=1000));simulator_backend=backend)
        staged=DeploymentConfiguration.profile(joinpath(package,"deployment.conf"),args.pipewire_prefix)
        staged_provenance=Common.read_json(joinpath(package,"provenance.json"))
        for name in HELPERS
            destination=joinpath(package,"hil",name);ispath(destination) && rm(destination)
            ScienceExport.copy_file(joinpath(ScienceExport.resource_root(),"hil",name),destination)
        end
        all(digest(joinpath(package,"hil",name))==hash for (name,hash) in helper_hashes) &&
            digest(joinpath(package,"hil/plant.toml"))==plant_hash || throw(ArgumentError("native export altered frozen plant/helpers"))
        HILExport.replace_staged_package(override,package,"PipeWireAO")
        ScienceExport.copy_file(projection_path,joinpath(package,"heart/physical-projection.f32le"))
        controller_file="selected-native-controller.fits"
        HeartConfiguration.write_offset_fits(inputs.controller,joinpath(package,"heart/calibration",controller_file),[253,3600])
        document,sections=HeartConfiguration.load_config(joinpath(package,"heart/config.yaml.in"))
        recurrence=native_config_contract(sections)
        clipping_native=basename(HeartConfiguration.one(sections["DM"],"PDM_CLIPPINGS_FILE","PDM_NUM")["FILE"])
        validate_clipping_file(joinpath(package,"heart/calibration",clipping_native))
        HeartConfiguration.one(sections["HO"],"HO_CONTROL_MATRIX_FILE","WFS_NUM")["FILE"]="./config/"*controller_file
        sections["CB"]["TELEMETRY_FILE_STREAMS"]=[Dict("tagName"=>tag,"decimate"=>0,"pollPeriod"=>0.001) for tag in TAGS]
        pop!(sections["CB"],"TELEMETRY_SOCKET_STREAMS",nothing)
        write(joinpath(package,"heart/config.yaml.in"),HeartConfiguration.serialize_config(document,args.heart_source_config))
        native=only(filter(owner->owner["role"]=="heart",staged["owners"]))
        core=DeploymentConfiguration.decode(joinpath(package,staged["core"]),args.pipewire_prefix)
        wfs=only(filter(item->get(get(item,"args",Dict()),"factory.name",nothing)=="api.heart.std-wfs.sink",core["context.objects"]))["args"]
        ingress=HeartCalibrationExport.ingress_contract("deferred","copper",wfs,joinpath(package,"heart/bin/scaoTemplate");source_revision=staged_provenance["heart"]["revision"])
        native["environment"]["HRT_DEFER_WFS_INGRESS"]="1";append!(native["argv"],["--native-ingress-mode","deferred"])
        simulator=only(filter(owner->owner["role"]==staged["source-owner"],staged["owners"]))
        CalibrationExport.correction_source_control!(simulator, "copper")
        simulator["argv"]=owner_arguments(simulator["argv"],evidence,16*1024*1024)
        Common.write_json(joinpath(package,"session.conf.in"),HeartCalibrationExport.calibration_session(provenance["hil"]["wall_rate_hz"]))
        runtime_inputs=Dict(basename(path)=>digest(path) for path in readdir(joinpath(package,"heart/calibration");join=true))
        projection_native=basename(HeartConfiguration.one(sections["DM"],"VDM_TO_PDM_FILE","PDM_NUM")["FILE"])
        flags=[Dict("section"=>section,"field"=>field,"value"=>value) for (section,field,value) in
            HeartOwner.read_requirements(joinpath(package,"heart/requirements.json"))]
        NativeFlags.validate_flags(flags,:copper)
        contract=merge(recurrence,Dict("version"=>1,"profile"=>"copper","controller_coordinates"=>253,"frames"=>256,
            "native_ingress_mode"=>"deferred","native_telemetry_max_bytes"=>16*1024*1024,
            "detector_acceptance_policy"=>"normal-correction-adc-bounded-replay-v1","native_ingress"=>ingress,"runtime_flags"=>flags,
            "plant_sha256"=>plant_hash,"projection_wire_sha256"=>digest(joinpath(package,"heart/physical-projection.f32le")),
            "projection_native_file"=>projection_native,"runtime_inputs"=>runtime_inputs,"clipping_native_file"=>clipping_native,
            "native_config_sha256"=>digest(joinpath(package,"heart/config.yaml.in")),
            "native_executable_sha256"=>digest(joinpath(package,"heart/bin/scaoTemplate")),
            "native_source_revision"=>staged_provenance["heart"]["revision"],"native_source_files"=>source_hashes,
            "frozen_helpers"=>helper_hashes,"locked_test_sha256"=>args.locked_test_sha256,
            "selection_sha256"=>inputs.locked["selection_sha256"],"native_reference_seal_sha256"=>inputs.locked["native_reference_seal_sha256"],
            "selected_estimator_sha256"=>inputs.selected["selected_estimator_sha256"],
            "selected_controller_sha256"=>inputs.selected["selected_controller_sha256"],
            "native_controller_file"=>controller_file,"native_controller_fits_sha256"=>runtime_inputs[controller_file],
            "scope"=>"finite active native CORRECT comparison fixture; preparation excludes runtime scientific acceptance"))
        Common.write_json(joinpath(package,"heart-cold-admission.json"),admission)
        contract["cold_admission_sha256"]=digest(joinpath(package,"heart-cold-admission.json"))
        Common.write_json(joinpath(package,"heart-active-contract.json"),contract)
        staged_provenance["heart_correction"]=Dict("version"=>1,"active_contract_sha256"=>digest(joinpath(package,"heart-active-contract.json")),
            "input_files"=>inputs.inputs,"normal_base_sha256"=>digest(joinpath(base,"deployment.conf")),
            "plant_sha256"=>plant_hash,"frozen_helpers"=>helper_hashes,"native_ingress"=>ingress,
            "scope"=>"new locked native253 inverse only; normal plant and original gains preserved; two actual256-frame windows/reset/truth/publicshutdown pending")
        Common.write_json(joinpath(package,"provenance.json"),staged_provenance)
        staged["name"]=name;staged["artifacts"]=HeartExport._artifacts(package)
        Common.write_json(joinpath(package,"deployment.conf"),staged)
        exact_inputs!(Dict(),inputs.inputs)
        all(digest(joinpath(args.heart_root,name))==hash for (name,hash) in source_hashes) || throw(ArgumentError("native source changed during preparation"))
        DeploymentConfiguration.profile(joinpath(package,"deployment.conf"),args.pipewire_prefix)
        mv(package,output)
        return joinpath(output,"deployment.conf")
    end
end

include("heart_classic_correction.jl")

function main(argv=ARGS)
    args=Common.cli_arguments(argv;required=["base-package","output","heart-root","heart-source-config","calibration-root",
        "owner-evidence-directory","pipewireao-jl-root"],
        defaults=(pipewire_prefix="/opt/pipewireao",simulator_backend="cuda"),allowed=["adapter-root","locked-test","locked-test-sha256",
            "transfer-package","transfer-evidence","transfer-lifecycle","transfer-score","transfer-score-sha256",
            "forward-model","accepted-preparation"])
    println(export_package(args));return 0
end

end
