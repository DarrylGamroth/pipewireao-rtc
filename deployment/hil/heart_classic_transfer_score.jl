"""Cold retained Classic transfer science; launched only after trusted SDK admission."""
module HeartClassicTransferScore
using JSON3, SHA, LinearAlgebra
const POLICY_SHA="b4f649fbc19a3cd5d4565e8007cc8b1c7261e5b1812013457e8f7bdc61de65be"
const INVERSE_SHA="bb9aa68345a3402445b65a350e796b212e048453bf917245cee7f36efa015813"
digest(path)=bytes2hex(open(sha256,path))
document(path,::Type{T}=Dict{String,Any}) where T=JSON3.read(read(path,String),T)
check(value,message)=value || throw(ArgumentError(message))
function matrix(path,::Type{T},shape,hash) where T
    check(!islink(path) && digest(path)==hash && filesize(path)==sizeof(T)*prod(shape),"matrix artifact differs")
    values=reinterpret(T,read(path));check(all(isfinite,values),"nonfinite matrix artifact")
    return Matrix(permutedims(reshape(values,reverse(shape)...)))
end

function paired_losses(r,b,m,plan,y,labels,active)
    eligibility=repeat(active;inner=2)
    check(length(eligibility)==size(y,2),"interleaved eligibility extent differs")
    excluded=findall(!,eligibility)
    check(all(iszero,@view r[:,excluded]) && all(iszero,@view m[excluded,:]),"accepted inverse/forward uses excluded coordinates")
    projected=copy(y);projected[:,excluded].=0.0
    raw_prediction=b*r*permutedims(y)
    projected_prediction=b*r*permutedims(projected)
    check(reinterpret(UInt64,vec(raw_prediction))==reinterpret(UInt64,vec(projected_prediction)),"eligibility changed physical prediction")
    check(size(y,1)==length(plan["probes"])==length(labels),"one actual mean per frozen probe is required")
    q=reduce(vcat,(permutedims(Float64.(figure)) for figure in plan["probes"]))
    check(size(b,2)==size(r,1) && size(r,2)==size(y,2) && size(m)==(size(y,2),size(q,2)) && size(b,1)==size(q,2),"transfer basis extents differ")
    check(all(isfinite,r) && all(isfinite,b) && all(isfinite,m) && all(isfinite,y),"nonfinite transfer inputs")
    records=Any[]
    for repeat in 1:2, group in ("sparse","mixed")
        ids=group=="sparse" ? (1,8) : (9,16)
        forward=0.0;forward_zero=0.0;raw_forward=0.0;raw_forward_zero=0.0;inverse=0.0;inverse_zero=0.0
        paired=Any[]
        for direction in ids
            slots=(2repeat-1,2repeat)
            indices=[only(findall(row->row["kind"]=="signed" && row["direction"]==direction && row["slot"]==slot,labels)) for slot in slots]
            first,second=indices
            check(q[first,:]==-q[second,:],"frozen probe pair is not symmetric")
            raw_observation=(y[first,:]-y[second,:])/2
            observation=(projected[first,:]-projected[second,:])/2
            target=q[first,:]
            predicted_response=m*target
            predicted_command=b*r*observation
            raw_forward+=sum(abs2,predicted_response-raw_observation);raw_forward_zero+=sum(abs2,raw_observation)
            forward+=sum(abs2,predicted_response-observation);forward_zero+=sum(abs2,observation)
            inverse+=sum(abs2,predicted_command-target);inverse_zero+=sum(abs2,target)
            push!(paired,Dict("direction"=>direction,"source_batch_indices"=>indices,"observed_response"=>observation,
                "raw_observed_response"=>raw_observation,"inactive_raw_paired_response"=>raw_observation[excluded],
                "forward_prediction"=>predicted_response,"physical_prediction"=>predicted_command,"physical_target"=>target))
        end
        finite=all(isfinite,(forward,forward_zero,inverse,inverse_zero))
        passed=finite && forward_zero>0 && inverse_zero>0 && forward<forward_zero && inverse<inverse_zero
        push!(records,Dict("group"=>group,"pair_repeat"=>repeat,"projected_forward_sse_detector_coordinate2"=>forward,
            "projected_zero_response_sse_detector_coordinate2"=>forward_zero,"raw_forward_sse_detector_coordinate2"=>raw_forward,
            "raw_zero_response_sse_detector_coordinate2"=>raw_forward_zero,"inverse_sse_um2_opd"=>inverse,
            "zero_command_sse_um2_opd"=>inverse_zero,"passed"=>passed,"paired"=>paired))
    end
    nulls=[let before=only(findall(row->row["kind"]=="reference" && row["direction"]==direction && row["position"]=="before",labels)),
        after=only(findall(row->row["kind"]=="reference" && row["direction"]==direction && row["position"]=="after",labels))
        Dict("direction"=>direction,"before_norm2"=>sum(abs2,y[before,:]),"after_norm2"=>sum(abs2,y[after,:]),
            "reference_drift_norm2"=>sum(abs2,y[after,:]-y[before,:]),
            "projected_before_norm2"=>sum(abs2,projected[before,:]),"projected_after_norm2"=>sum(abs2,projected[after,:]),
            "projected_reference_drift_norm2"=>sum(abs2,projected[after,:]-projected[before,:]))
        end for direction in (1,8,9,16)]
    return Dict("raw_and_projected_physical_predictions_bit_identical"=>true,"inactive_measurements_zero_based"=>excluded.-1,
        "raw_native_means"=>[collect(@view y[row,:]) for row in axes(y,1)],"paired_scores"=>records,"reference_nulls"=>nulls,"passed"=>all(row->row["passed"],records))
end

function main(arguments=ARGS)
    length(arguments)==6 || error("expected PACKAGE EVIDENCE LIFECYCLE FRESH_REPORT FORWARD_MODEL ACCEPTED_PREPARATION")
    package,evidence,lifecycle,output,forward_model,accepted_preparation=abspath.(arguments)
    check(!ispath(output)&&!islink(output),"score output must be fresh")
    provenance=document(joinpath(package,"provenance.json"));binding=provenance["heart_calibration"]["classic_transfer"]
    check(provenance["profile"]=="classic" && binding["policy_sha256"]==POLICY_SHA && binding["accepted_inverse_sha256"]==INVERSE_SHA,"selected Classic transfer source differs")
    policy_path=joinpath(package,"heart/classic-transfer/policy.json")
    check(digest(policy_path)==POLICY_SHA,"frozen transfer policy differs")
    score_policy_path=joinpath(package,"heart/classic-transfer/scoring-policy-v2.json")
    check(digest(score_policy_path)=="160606c8c9c2c21a304b97df1e046b25fd728166a404db766656308b981f14c8","frozen eligibility scoring policy differs")
    policy=document(policy_path)
    for (name,hash) in binding["inputs_sha256"]
        check(digest(joinpath(package,"heart/classic-transfer",name))==hash,"frozen transfer input changed")
    end
    completion=document(joinpath(evidence,"native-plan-result.json"));launch=document(lifecycle)
    check(launch["capture_confirmed"]===true && launch["shutdown_confirmed"]===true && get(launch,"failure",nothing)===nothing &&
        get(launch,"shutdown_failure",nothing)===nothing && launch["descriptor_sha256"]==digest(joinpath(package,"deployment.conf")),"actual capture/public shutdown gates incomplete")
    identity=completion["runtime_identity"];state=document(joinpath(launch["runtime"],"state.json"))
    check(state["phase"]=="stopped" && state["admitted"]===false && state["pid"]==identity["launcher_pid"] &&
        state["instance"]==identity["instance"] && state["ready"]["session_id"]==identity["ready_session_id"] &&
        state["source"]["sequence"]==1561 && !ispath(joinpath(launch["runtime"],identity["instance"])),"same captured runtime did not stop")
    verification=Base.invokelatest(HeartClassicCalibrationEvidence.verify,package,evidence)
    plan=document(joinpath(package,"heart-calibration-plan.json"));labels=document(joinpath(package,"heart/classic-transfer/probe-labels.json"),Vector{Dict{String,Any}})
    check(plan["measurements"]==376 && plan["frames_per_probe"]==64 && length(plan["probes"])==24,"frozen finite plan extent differs")
    result_path=joinpath(evidence,"calibration-result.json")
    prepared=(;plan=JSON3.read(JSON3.write(plan)),figures=permutedims(hcat(plan["probes"]...)),measurements=376,frames_per_probe=64)
    y=Float64.(Base.invokelatest(HeartClassicCalibrationEvidence.CalibrationClient.validate_result,read(result_path,String),prepared))
    r=Float64.(matrix(joinpath(package,binding["selected_inverse_path"]),Float32,(221,376),INVERSE_SHA))
    bpath=only([path for (path,hash) in binding["map_files_sha256"] if hash==policy["physical_B_sha256"]])
    b=Float64.(matrix(joinpath(package,bpath),Float32,(277,221),policy["physical_B_sha256"]))
    check(digest(accepted_preparation)=="8249e964ec5e1be5844294316ac19b83e67204e90bb14664c67dca06ddcf0c08","accepted Classic preparation differs")
    m=matrix(forward_model,Float64,(376,277),policy["accepted_forward_model"]["sha256"])
    active_bytes=read(joinpath(package,"heart/classic-active.u8"))
    check(bytes2hex(sha256(active_bytes))=="04090c0ed1a3808cd3b8ad03503008eb4915bab3c5eedbc856b14cc8db543697","accepted eligibility differs")
    active=Vector{Bool}(active_bytes .== 1)
    score=paired_losses(r,b,m,plan,y,labels,active)
    score["version"]=2;score["scoring_policy_sha256"]=digest(score_policy_path);score["policy_sha256"]=POLICY_SHA;score["estimator_origin"]="accepted CPU Classic hadamard-1 rank206; no native fit"
    score["accepted_inverse_sha256"]=INVERSE_SHA;score["driver_sha256"]=digest(@__FILE__)
    score["descriptor_sha256"]=digest(joinpath(package,"deployment.conf"));score["public_result_sha256"]=digest(result_path)
    score["native_completion_sha256"]=digest(joinpath(evidence,"native-plan-result.json"));score["lifecycle_sha256"]=digest(lifecycle)
    score["source_backend"]=provenance["hil"]["backend"];score["measurement_basis"]="raw native interleaved376 detector coordinates, scale1; inactive inverse columns exact+0"
    score["native_payload_verification"]=verification;score["scope"]=policy["scope"];score["seed_scope"]=policy["seed_scope"]
    check(digest(policy_path)==POLICY_SHA && digest(joinpath(package,binding["selected_inverse_path"]))==INVERSE_SHA,"frozen scientific input changed during scoring")
    open(output,"w") do io
        JSON3.write(io,score);write(io,'\n')
    end
    return score["passed"] ? 0 : 1
end
function verify_request(request, expected_hash, arguments)
    check(digest(request)==expected_hash,"cold worker admission request differs")
    ledger=document(request)
    check(ledger["arguments"]==abspath.(arguments),"cold worker arguments differ from SDK admission")
    admission=ledger["admission"]
    package,evidence,lifecycle,_,forward_model,accepted_preparation=arguments
    for (root,key) in ((package,"package_files"),(evidence,"evidence_files"))
        for (relative,hash) in admission[key]
            path=abspath(joinpath(root,relative))
            check(startswith(path,abspath(root)*"/") && !islink(path) && digest(path)==hash,"cold worker input identity differs")
        end
    end
    for path in (forward_model,accepted_preparation)
        check(!islink(path) && digest(path)==ledger["data_files"][path],"accepted scientific data differs")
    end
    check(digest(lifecycle)==admission["lifecycle_sha256"],"cold worker lifecycle differs")
    check(digest(joinpath(package,"hil/heart_classic_calibration_evidence.jl"))=="8df89d2a60901a5176d9a08b94121715c36e278e99db19efeb4bae60dec7b0a9","cold worker helper source differs")
    return nothing
end
function invoke(arguments=ARGS)
    length(arguments)==8 || error("expected PACKAGE EVIDENCE LIFECYCLE FRESH_REPORT FORWARD_MODEL ACCEPTED_PREPARATION ADMISSION_REQUEST REQUEST_SHA")
    selected=abspath.(arguments[1:6]);request=abspath(arguments[7]);expected=arguments[8]
    verify_request(request,expected,selected)
    Base.include(@__MODULE__,joinpath(selected[1],"hil/heart_classic_calibration_evidence.jl"))
    status=Base.invokelatest(main,selected)
    verify_request(request,expected,selected)
    return status
end
end
if abspath(PROGRAM_FILE)==(@__FILE__)
    exit(HeartClassicTransferScore.invoke())
end
