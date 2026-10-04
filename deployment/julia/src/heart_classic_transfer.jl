"""Trusted admission and cold replay of the reviewed finite Classic native transfer."""
module HeartClassicTransfer
using ..Common, ..CalibrationCampaign, ..Deployment, ..HeartCalibrationExport, ..ScienceExport
const D=parentmodule(@__MODULE__)
const C=Common
const RUNNER_SHA="417395f9685f0ea025e0dc80f226edad63ee1f3932f83e699a08af5a4bfbe9c0"
const PREPARER_SHA="c76aa4b1f1f2eeee8ced7a10e14eb2d33f7ac7d224bed04f4fba731370ae8c81"
const CLASSIC_EVIDENCE_SHA="8df89d2a60901a5176d9a08b94121715c36e278e99db19efeb4bae60dec7b0a9"
const ORIGINAL_HELPERS=Dict("heart_calibration_telemetry.jl"=>"158347e3a1ba396c556e15b68eb1d82b6736fbf7014689d1cde781da48d917aa",
    "heart_calibration_method.jl"=>"4c07744f56c2e4731523247306e786a22b653284cc1857d54b815ac59abdfcfe",
    "heart_calibration_evidence.jl"=>"fef6675ceae84d47512cfd7cebd599bd40e75741867b92f3211685b6a5222367")
check(value,message)=value || throw(ArgumentError(message))
function document(path;maximum=16*1024*1024)
    check(!islink(path) && isfile(path) && filesize(path)<=maximum,"missing, linked or oversized admission record")
    C.read_json(path;maximum)
end
function validate_helpers(files)
    for (name,hash) in ORIGINAL_HELPERS
        check(get(files,"hil/"*name,nothing)==hash,"retained Copper helper source differs")
    end
    check(get(files,"hil/heart_classic_calibration_evidence.jl",nothing)==CLASSIC_EVIDENCE_SHA,
        "selected Classic evidence helper source differs")
    return nothing
end
function admit(package,evidence,lifecycle)
    package,evidence,lifecycle=abspath.((package,evidence,lifecycle))
    launch=document(lifecycle)
    check(get(launch,"capture_confirmed",false)===true && get(launch,"shutdown_confirmed",false)===true &&
        get(launch,"failure",nothing)===nothing && get(launch,"shutdown_failure",nothing)===nothing &&
        get(launch,"driver_sha256",nothing)==RUNNER_SHA && get(launch,"package",nothing)==package,
        "actual source-bound capture/shutdown lifecycle missing")
    preparation_path=package*".preparation.json"
    check(C.sha256_file(preparation_path)==launch["preparation_sha256"],"preparation differs from actual launch")
    preparation=document(preparation_path;maximum=64*1024*1024)
    check(preparation["driver_sha256"]==PREPARER_SHA && preparation["package"]==package &&
        preparation["descriptor_sha256"]==launch["descriptor_sha256"]==C.sha256_file(joinpath(package,"deployment.conf")),
        "prepared source or launched descriptor differs")
    files=D.CalibrationCampaign.file_identity(package)
    check(files==preparation["package_files_sha256"],"package/helper/dependency identity differs from actual preparation")
    validate_helpers(files)
    # Use the public deployment seal/profile checker in this trusted SDK before
    # importing any target HIL helper or starting its project environment.
    specification=D.Deployment.profile(joinpath(package,"deployment.conf"),"/opt/pipewireao")
    check(specification["artifacts"]==Dict(name=>hash for (name,hash) in files if name!="deployment.conf"),
        "descriptor does not seal every actual package file")
    provenance=document(joinpath(package,"provenance.json"))
    check(provenance["profile"]=="classic" && provenance["hil"]["backend"]=="cuda" &&
        provenance["heart_calibration"]["classic_transfer"]["policy_sha256"]=="b4f649fbc19a3cd5d4565e8007cc8b1c7261e5b1812013457e8f7bdc61de65be" &&
        preparation["scoring_policy_sha256"]=="160606c8c9c2c21a304b97df1e046b25fd728166a404db766656308b981f14c8",
        "selected Classic profile/backend/policies differ")
    D.CalibrationCampaign.validate_simulator_backend(package,specification,provenance;allowed_backends=("cuda",))
    completion_path=joinpath(evidence,"native-plan-result.json")
    check(C.sha256_file(completion_path)==launch["plan_result_sha256"] && abspath(launch["plan_result"])==completion_path,
        "native completion differs from actual producing launch")
    completion=document(completion_path)
    manifest_path=joinpath(evidence,"native-evidence-manifest.json")
    check(C.sha256_file(manifest_path)==completion["evidence_manifest_sha256"]==launch["evidence_manifest_sha256"],
        "retained native manifest differs from actual launch/completion")
    manifest=document(manifest_path)
    retained=D.CalibrationCampaign.file_identity(evidence)
    expected=copy(manifest);expected["native-plan-result.json"]=C.sha256_file(completion_path)
    expected["native-evidence-manifest.json"]=C.sha256_file(manifest_path)
    check(retained==expected,"retained evidence has changed, missing or unsealed files")
    state_path=joinpath(launch["runtime"],"state.json")
    check(C.sha256_file(state_path)==launch["final_runtime_state_sha256"],"final runtime state differs from actual launch")
    state=document(state_path)
    D.HeartCalibrationExport.validate_stopped_runtime(state,completion["runtime_identity"],launch["runtime"],launch["descriptor_sha256"],1561)
    check(all(name->get(completion,name,false)===true,("restoration_confirmed","release_confirmed","native_counts_confirmed")) &&
        get(completion,"failure",nothing)===nothing && get(completion,"retention_failure",nothing)===nothing,
        "native completion gates are incomplete")
    return Dict("version"=>3,"package_files"=>files,"evidence_files"=>retained,"descriptor_sha256"=>launch["descriptor_sha256"],
        "lifecycle_sha256"=>C.sha256_file(lifecycle),"preparation_sha256"=>C.sha256_file(preparation_path),
        "runtime_state_sha256"=>C.sha256_file(state_path))
end

const FORWARD_SHA="4c9d472f10d992361ff0fc44976ddd496e24fd9189af9c3697924d73b3eb2d5a"
const ACCEPTED_PREPARATION_SHA="8249e964ec5e1be5844294316ac19b83e67204e90bb14664c67dca06ddcf0c08"
const COMPACT_SHA="bb9aa68345a3402445b65a350e796b212e048453bf917245cee7f36efa015813"
const PADDED_FITS_SHA="df3bf5c06416b2600e282b6415386d7804c6147853a242c2cda4ef7bac54e47f"
const LOADED_SOURCE_SHA=C.sha256_file(@__FILE__)
const WORKER_NAME="heart_classic_transfer_score.jl"
Base.include_dependency(joinpath(ScienceExport.resource_root(),"hil",WORKER_NAME))
const WORKER_SHA=C.sha256_file(joinpath(ScienceExport.resource_root(),"hil",WORKER_NAME))
export score_capture, replay_admission

function source_inputs()
    root=D.package_root()
    source=joinpath(root,"src","heart_classic_transfer.jl")
    check(C.sha256_file(source)==LOADED_SOURCE_SHA,"loaded Classic transfer SDK source differs")
    worker=joinpath(ScienceExport.resource_root(),"hil",WORKER_NAME)
    check(C.sha256_file(worker)==WORKER_SHA,"maintained Classic transfer worker differs")
    inputs=Dict(joinpath(root,"src",name)=>hash for (name,hash) in CalibrationCampaign.file_identity(joinpath(root,"src")))
    inputs[worker]=WORKER_SHA
    return inputs
end

function input_files(package,evidence,lifecycle,admission,data,sources)
    inputs=merge(copy(data),sources)
    for (root,key) in ((package,"package_files"),(evidence,"evidence_files"))
        for (name,hash) in admission[key]
            inputs[joinpath(root,name)]=hash
        end
    end
    inputs[lifecycle]=admission["lifecycle_sha256"]
    inputs[package*".preparation.json"]=admission["preparation_sha256"]
    launch=document(lifecycle)
    inputs[joinpath(launch["runtime"],"state.json")]=admission["runtime_state_sha256"]
    return inputs
end

function external_output(output,package,evidence)
    check(all(root->output!=abspath(root)&&!startswith(output,abspath(root)*string(Base.Filesystem.path_separator)),
        (package,evidence)),"Classic replay output must be outside immutable inputs")
end

"""Score a successful frozen four-direction capture in its own HIL environment.

Both accepted scientific data paths are explicit and checked against reviewed bytes.
This does not install or qualify an active controller. All outputs must be fresh.
"""
function score_capture(package,evidence,lifecycle;output,forward_model,accepted_preparation)
    package,evidence,lifecycle,output,forward_model,accepted_preparation=
        abspath.((package,evidence,lifecycle,output,forward_model,accepted_preparation))
    external_output(output,package,evidence)
    all(path->!ispath(path)&&!islink(path),(output,output*".stdout",output*".stderr")) ||
        throw(ArgumentError("Classic transfer score outputs must be fresh"))
    before=admit(package,evidence,lifecycle)
    data=Dict(forward_model=>FORWARD_SHA,accepted_preparation=>ACCEPTED_PREPARATION_SHA)
    for (path,hash) in data
        check(!islink(path)&&isfile(path)&&C.sha256_file(path)==hash,"accepted Classic scientific data differs")
    end
    sources=source_inputs()
    return mktempdir() do temporary
        worker_output=joinpath(temporary,"score.json");request=joinpath(temporary,"admission.json")
        arguments=[package,evidence,lifecycle,worker_output,forward_model,accepted_preparation]
        C.write_json(request,Dict("version"=>1,"arguments"=>arguments,"admission"=>before,"data_files"=>data))
        request_hash=C.sha256_file(request)
        worker=joinpath(ScienceExport.resource_root(),"hil",WORKER_NAME)
        process=C.run_checked([Base.julia_cmd().exec[1],"--startup-file=no","--threads=1","--depwarn=error",
            "--project="*joinpath(package,"hil"),worker,arguments...,request,request_hash];timeout=600,
            env=Dict("OPENBLAS_NUM_THREADS"=>"1"),stdout_path=output*".stdout",stderr_path=output*".stderr")
        check(before==admit(package,evidence,lifecycle)&&sources==source_inputs()&&C.sha256_file(request)==request_hash,
            "Classic transfer package/evidence/source changed during replay")
        check(all(C.sha256_file(path)==hash for (path,hash) in data),"accepted Classic data changed during replay")
        check(process.returncode in (0,1)&&isfile(worker_output),"Classic cold worker failed before a science result")
        result=document(worker_output)
        check((process.returncode==0)==result["passed"]&&result["driver_sha256"]==WORKER_SHA,"Classic worker exit/source differs")
        binding=document(joinpath(package,"provenance.json"))["heart_calibration"]["classic_transfer"]
        native=binding["retained_native_inverse"]
        check(native["shape"]==[277,376]&&native["sha256"]==PADDED_FITS_SHA&&
            C.sha256_file(joinpath(package,native["path"]))==PADDED_FITS_SHA,"retained padded accepted inverse differs")
        result["admission_passed"]=true
        result["input_files"]=input_files(package,evidence,lifecycle,before,data,sources)
        result["actual_native_transfer_reproduced"]=true
        result["actual_native_captures_revalidated"]=1
        result["actual_native_frames_revalidated"]=1561
        result["actual_native_accepted_frames_revalidated"]=1536
        result["selected_compact_inverse_sha256"]=COMPACT_SHA
        result["selected_controller_sha256"]=PADDED_FITS_SHA
        result["selected_controller_path"]=joinpath(package,native["path"])
        result["replay_source_sha256"]=LOADED_SOURCE_SHA
        C.write_json(output,result)
        return result
    end
end

"""Reproduce the complete reported science and input ledger before active export."""
function replay_admission(package,evidence,lifecycle,reported;reported_sha256,forward_model,accepted_preparation,output=nothing)
    reported=abspath(reported)
    output===nothing || check(!ispath(output)&&!islink(output),"Classic replay output must be fresh")
    output===nothing || external_output(abspath(output),package,evidence)
    check(!islink(reported)&&C.sha256_file(reported)==reported_sha256,"reported Classic transfer differs")
    expected=document(reported;maximum=64*1024*1024)
    check(get(expected,"passed",nothing)===true&&get(expected,"admission_passed",nothing)===true,
        "Classic active correction requires a passed actual transfer")
    return mktempdir() do temporary
        destination=joinpath(temporary,"replay.json")
        actual=score_capture(package,evidence,lifecycle;output=destination,forward_model,accepted_preparation)
        check(actual==expected&&C.sha256_file(reported)==reported_sha256,"actual Classic transfer science/input ledger did not reproduce")
        actual["transfer_score_sha256"]=reported_sha256
        actual["input_files"][reported]=reported_sha256
        output===nothing || C.write_json(abspath(output),actual)
        return actual
    end
end
end
