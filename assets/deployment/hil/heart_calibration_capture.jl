module HeartCalibrationCapture

using PipeWireAODeployment, SHA, JSON3, LinearAlgebra
const C=PipeWireAODeployment.Common
const H=PipeWireAODeployment.HeartCalibrationExport
const D=PipeWireAODeployment.DeploymentConfiguration
const MethodPath=joinpath(@__DIR__,"heart_calibration_method.jl")
const CoordinatesPath=joinpath(@__DIR__,"heart_calibration_coordinates.jl")
const IncludedSources=Dict(path=>bytes2hex(open(sha256,path)) for path in
    (MethodPath,CoordinatesPath,@__FILE__,joinpath(dirname(MethodPath),"calibration_client.jl"),
     joinpath(dirname(CoordinatesPath),"calibration_inverse_analysis.jl")))
include(MethodPath)
include(CoordinatesPath)
all(bytes2hex(open(sha256,path))==hash for (path,hash) in IncludedSources) ||
    error("native analysis helper changed during include")
const Method=HeartCalibrationMethod
const Coordinates=HeartCalibrationCoordinates
digest(path)=bytes2hex(open(sha256,path))
document(path)=C.read_json(path;maximum=512*1024*1024)

function bind!(inputs,path,expected=digest(path))
    !islink(path) && isfile(path) && digest(path)==expected || error("consumed native analysis input differs")
    inputs[abspath(path)]=expected
    return path
end

function reference_inputs(path,expected,inputs)
    bind!(inputs,path,expected)
    reference=document(path)
    reference["native_ingress_mode"]=="deferred" && reference["seeds"]==[522,523] &&
        reference["accepted_frames_each"]==32 || error("native reference contract differs")
    for (source,hash) in reference["input_files"];bind!(inputs,source,hash);end
    rpath=bind!(inputs,reference["reference_path"],reference["native_reference_sha256"])
    qpath=bind!(inputs,reference["qualification_path"],reference["native_qualification_sha256"])
    r=Float64.(reinterpret(Float32,read(rpath)));q=collect(reinterpret(Float64,read(qpath)))
    length(r)==length(q)==3600 && all(isfinite,r) && all(isfinite,q) && norm(r)>0 || error("native reference representation differs")
    return (;record=reference,r,q)
end

function cohort_inputs(path,expected,reference,inputs)
    bind!(inputs,path,expected)
    cohort=document(path)
    cohort["native_ingress_mode"]==reference.record["native_ingress_mode"] &&
        cohort["policy_sha256"]==reference.record["policy_sha256"] || error("native cohort reference/policy differs")
    return cohort
end

"""Read an actual native stage after public shutdown and repeat public reduction.

The bound reader requires the cohort's exact package, runtime/PIDs/session,
actual retained native payloads and the public AOC result. Hashes and booleans
alone cannot substitute another engine's capture.
"""
function capture(stage,run_path,run_sha,cohort,inputs)
    bind!(inputs,run_path,run_sha)
    run=document(run_path)
    run["status"]=="completed-selected-stages" || error("native cohort run incomplete")
    entry=only(filter(item->item["name"]==stage["name"],run["completed"]))
    root=dirname(run_path);name=stage["name"];package=stage["package"]
    runtime=run["runtime_paths"][name];evidence=joinpath(root,name*"-evidence");candidate=joinpath(root,name*"-candidate")
    descriptor=bind!(inputs,joinpath(package,"deployment.conf"),stage["descriptor_sha256"])
    specification=D.profile(descriptor,"/opt/pipewireao")
    for (file,hash) in specification["artifacts"];bind!(inputs,joinpath(package,file),hash);end
    document(joinpath(package,"provenance.json"))["heart_calibration"]["native_ingress"]["mode"]==cohort["native_ingress_mode"] ||
        error("actual native capture ingress differs from the cohort")
    sdkroot=dirname(pathof(PipeWireAODeployment))
    for (file,hash) in specification["artifacts"]
        startswith(file,"julia/src/") || continue
        bind!(inputs,joinpath(sdkroot,file[length("julia/src/")+1:end]),hash)
    end
    digest(joinpath(package,"hil/heart_calibration_method.jl"))==digest(MethodPath) || error("consumed method helper differs from sealed method")
    lifecycle_path=bind!(inputs,evidence*".lifecycle.json",entry["lifecycle_sha256"])
    lifecycle=document(lifecycle_path)
    all(get(lifecycle,key,false)===true for key in ("plan_confirmed","shutdown_confirmed","reduction_confirmed")) &&
        get(lifecycle,"failure",nothing)===nothing && get(lifecycle,"shutdown_failure",nothing)===nothing || error("native public lifecycle failed")
    completion_path=bind!(inputs,joinpath(evidence,"native-plan-result.json"),entry["native_completion_sha256"])
    completion=document(completion_path)
    state_path=bind!(inputs,joinpath(runtime,"state.json"))
    document(state_path)==lifecycle["final"] || error("native actual ending state differs")
    H.validate_stopped_runtime(document(state_path),completion["runtime_identity"],runtime,
        stage["descriptor_sha256"],stage["plan"]["limits"]["completed_exposures"])
    manifest_path=bind!(inputs,joinpath(evidence,"native-evidence-manifest.json"),completion["evidence_manifest_sha256"])
    for (file,hash) in document(manifest_path)
        path=abspath(joinpath(evidence,file))
        startswith(path,abspath(evidence)*"/") || error("native evidence escapes its root")
        bind!(inputs,path,hash)
    end
    metadata_path=bind!(inputs,joinpath(candidate,"candidate-response.json"),entry["candidate_sha256"])
    metadata=document(metadata_path)
    metadata["engine"]=="heart" && metadata["status"]=="complete-unaccepted-candidate" &&
        metadata["deployment_sha256"]==stage["descriptor_sha256"] &&
        metadata["native_completion_sha256"]==digest(completion_path) || error("native candidate identity differs")
    aocroot=dirname(dirname(pathof(Method.CalibrationClient.AdaptiveOpticsCalibration)))
    for (file,hash) in metadata["aoc_package_files"]
        startswith(file,"hil/packages/AdaptiveOpticsCalibration/") || continue
        bind!(inputs,joinpath(aocroot,file[length("hil/packages/AdaptiveOpticsCalibration/")+1:end]),hash)
    end
    payload=bind!(inputs,joinpath(candidate,metadata["path"]),metadata["sha256"])
    mktempdir() do temporary
        rederived=H.reduce_plan(package,evidence,runtime,joinpath(temporary,"candidate");
            expected_deployment_sha256=stage["descriptor_sha256"],timeout_seconds=600)
        document(rederived)==metadata && digest(joinpath(dirname(rederived),metadata["path"]))==metadata["sha256"] ||
            error("revalidated native public AOC candidate differs")
    end
    selected=Method.prepared_method(joinpath(package,"heart-method"),metadata["frozen_identity_sha256"])
    cli_path=bind!(inputs,joinpath(evidence,"calibration-result.json"),metadata["cli_result_sha256"])
    chronological=Method.CalibrationClient.validate_result(read(cli_path,String),selected.chronological)
    responses=Float32.(chronological[invperm(selected.permutation),:])
    rows,columns=metadata["shape"]
    length(read(payload))==4rows*columns || error("native interaction payload extent differs")
    matrix=permutedims(reshape(reinterpret(Float32,read(payload)),columns,rows))
    report=completion["final_owner_report"]
    adc=report["detector_diagnostics"]
    adc["frames"]==report["sequence"] && adc["upper_rail_frames"]==adc["upper_rail_pixels"]==0 &&
        report["detector_config"]["rng_seed"]==stage["seed"] || error("native ADC/seed differs")
    return (;name,package,matrix,responses,figures=selected.canonical.figures,
        detector_seed=stage["seed"],run=selected.canonical.plan.run,
        identity=metadata["frozen_identity_sha256"],cli_sha256=metadata["cli_result_sha256"],
        phase_elapsed_ns=lifecycle["phase_elapsed_ns"],report)
end

function command_map(package,inputs)
    ppath=bind!(inputs,joinpath(package,"heart/calibration/dm0ModesToActuators_250new.fits"))
    fpath=bind!(inputs,joinpath(package,"heart/calibration/dm0ActuatorsToModes_250new.fits"))
    P=Coordinates.floating_matrix(ppath;shape=(277,253))
    null=findall(column->all(iszero,column),eachcol(P))
    null==[1,2,3] || error("native unactuated coordinates differ")
    return Float64.(P),(;projection_sha256=digest(ppath),feedback_sha256=digest(fpath),
        physical_map_sha256=bytes2hex(sha256(reinterpret(UInt8,vec(permutedims(P))))),shape=size(P),
        null_coordinates=null,modal_intermediates="exact identity",controller_sign=-1)
end

function consumed_sources!(inputs)
    for (path,hash) in IncludedSources
        bind!(inputs,path,hash)
    end
end

function unchanged_inputs!(inputs)
    for (path,hash) in inputs
        !islink(path) && isfile(path) && digest(path)==hash || error("native analysis input changed during calculation")
    end
    return nothing
end

end
