#!/usr/bin/env julia
# Cold replay of native training, selection and locked data before CORRECT
# export. Uses the captured SDK/HIL environment and public reduction; creates
# no RTC, device, transport endpoint or simulator graph.
using SHA,JSON3,LinearAlgebra
const Started=time_ns()
const IncludedSources=Dict(path=>bytes2hex(open(sha256,path)) for path in
    (@__FILE__,joinpath(@__DIR__,"heart_calibration_capture.jl"),
     joinpath(@__DIR__,"heart_calibration_capture_inputs.jl"),
     joinpath(@__DIR__,"calibration_selection.jl"),joinpath(@__DIR__,"calibration_inverse_analysis.jl"),
     joinpath(@__DIR__,"heart_calibration_telemetry.jl")))
include("heart_calibration_capture_inputs.jl")
include("calibration_selection.jl")
include("heart_calibration_telemetry.jl")
all(bytes2hex(open(sha256,path))==hash for (path,hash) in IncludedSources) || error("correction admission source changed during include")
const Inputs=HeartCalibrationCaptureInputs
const Reader=Inputs.Reader
const Selection=CalibrationSelection
const C=Reader.C
const Groups=Dict("sparse"=>collect(1:4),"mixed"=>collect(5:8))

function verify_references(reference,inputs)
    candidates=[path for path in keys(reference.record["input_files"]) if basename(path)=="references.json"]
    length(candidates)==1 || error("native reference preparation is not uniquely bound")
    preparation=Reader.document(only(candidates))
    preparation["native_ingress_mode"]=="deferred" && length(preparation["stages"])==2 || error("native reference stage contract differs")
    means=Vector{Vector{Float64}}()
    for (index,stage) in enumerate(preparation["stages"])
        package=stage["package"];evidence=joinpath(dirname(package),"evidence")
        descriptor=Reader.bind!(inputs,joinpath(package,"deployment.conf"),stage["descriptor_sha256"])
        specification=Reader.D.profile(descriptor,"/opt/pipewireao")
        for (file,hash) in specification["artifacts"];Reader.bind!(inputs,joinpath(package,file),hash);end
        lifecycle=Reader.document(joinpath(evidence*".lifecycle.json"))
        lifecycle["reference_confirmed"]===true && lifecycle["shutdown_confirmed"]===true &&
            get(lifecycle,"failure",nothing)===nothing && get(lifecycle,"shutdown_failure",nothing)===nothing || error("native reference lifecycle failed")
        completion=Reader.document(joinpath(evidence,"native-plan-result.json"))
        state=Reader.document(joinpath(lifecycle["runtime"],"state.json"))
        state==lifecycle["final"] || error("native actual reference ending state differs")
        Reader.H.validate_stopped_runtime(state,completion["runtime_identity"],lifecycle["runtime"],stage["descriptor_sha256"],34)
        checked=C.run_checked([Base.julia_cmd().exec[1],"--startup-file=no","--project="*joinpath(package,"hil"),
            joinpath(package,"hil/heart_calibration_evidence.jl"),package,evidence];timeout=120)
        checked.returncode==0 || error("native reference payload verification failed: $(checked.stderr)")
        result=Reader.document(joinpath(evidence,"calibration-result.json"))
        length(result["responses"])==1 && length(only(result["responses"])["exposures"])==32 || error("native reference accepted count differs")
        files=filter(path->endswith(path,".tel"),readdir(joinpath(evidence,"heart/native");join=true))
        path=only(filter(path->open(io->startswith(String(read(io,32)),"cbHoGrad0\0"),path),files))
        reader=HeartCalibrationTelemetry.TelemetryReader(path;tag="cbHoGrad0",datatype=8,shape=(3600,1),
            maximum_bytes=UInt64(stage["limits"]["telemetry_max_bytes_per_file"]))
        total=zeros(Float64,3600)
        try
            for number in 1:34
                frame=HeartCalibrationTelemetry.next_frame!(reader)
                if 2<=number<=33
                    pixels=reinterpret(Float32,frame.payload)
                    for pixel in eachindex(total,pixels);total[pixel]+=Float64(pixels[pixel]);end
                end
            end
        finally
            close(reader)
        end
        mean=total./32
        reinterpret(UInt32,Float32.(mean))==reinterpret(UInt32,Float32.(only(result["responses"])["values"])) || error("native reference mean differs from actual public result")
        all(isfinite,mean) && norm(mean)>0 || error("native reference mean is invalid")
        completion["startup_owner_report"]["detector_config"]["rng_seed"]==stage["seed"]==(index==1 ? 522 : 523) || error("native reference seed differs")
        push!(means,mean)
    end
    Float32.(means[1])==Float32.(reference.r) && means[2]==reference.q || error("frozen native reference/qualification values are not reproduced")
    return nothing
end

function verify(path,hash)
    inputs=Dict{String,String}()
    Reader.consumed_sources!(inputs)
    for (source,expected) in IncludedSources;Reader.bind!(inputs,source,expected);end
    Reader.bind!(inputs,path,hash);locked=Reader.document(path)
    locked["engine"]=="heart" && locked["mode"]=="locked" && locked["passed"]===true || error("native locked utility absent")
    selected_path=Reader.bind!(inputs,locked["selection_path"],locked["selection_sha256"])
    selected=Reader.document(selected_path)
    selected["mode"]=="select" && selected["passed"]===true && selected["preparation_sha256"]==locked["preparation_sha256"] || error("native frozen selection differs")
    reference_path=locked["reference_seal_path"];reference_hash=locked["native_reference_seal_sha256"]
    reference=Reader.reference_inputs(reference_path,reference_hash,inputs)
    verify_references(reference,inputs)
    grid_path=locked["preparation_path"];grid_hash=locked["preparation_sha256"]
    preparation=Reader.document(Reader.bind!(inputs,grid_path,grid_hash))
    cohort_path=preparation["cohort_path"];cohort_hash=preparation["cohort_sha256"]
    cohort=Reader.cohort_inputs(cohort_path,cohort_hash,reference,inputs)
    grid=Inputs.grid(grid_path,grid_hash,reference,reference_hash,cohort,cohort_hash,inputs)
    for document in (selected,locked)
        document["native_reference_seal_sha256"]==reference_hash && document["cohort_sha256"]==cohort_hash &&
            document["policy_sha256"]==reference.record["policy_sha256"] &&
            document["physical_map"]==grid.record["physical_map"] || error("native selected/locked geometry or policy differs")
        for (source,expected) in document["input_files"];Reader.bind!(inputs,source,expected);end
    end
    ledger_candidates=[source for (source,expected) in preparation["input_files"] if expected==preparation["completed_run_ledger_sha256"]]
    length(ledger_candidates)==1 || error("native training ledger is not uniquely bound")
    training_names=["zonal-1","zonal-2","hadamard-1","hadamard-2","spatial-1","spatial-2"]
    training=Inputs.captures(only(ledger_candidates),preparation["completed_run_ledger_sha256"],training_names,
        Dict(name=>16 for name in training_names),cohort,cohort_hash,reference_hash,reference.record["policy_sha256"],inputs)
    fitted=Any[]
    for family in ("zonal","hadamard")
        a,b=Inputs.pair(training,family)
        append!(fitted,Selection.family_candidates(family,a.matrix,b.matrix,grid.B,reference.r))
    end
    for candidate in fitted
        index=only(findall(item->item["name"]==candidate.name,grid.record["candidates"]))
        expected=grid.record["candidates"][index]
        reinterpret(UInt32,vec(candidate.matrix))==reinterpret(UInt32,vec(grid.matrices[index])) &&
            candidate.cutoff==expected["cutoff"] && candidate.effective_rank==expected["effective_rank"] ||
            error("native grid is not reproduced from actual native training")
    end
    validation_names=["validation-1","validation-2"]
    validation=Inputs.captures(selected["capture_ledger_path"],selected["capture_ledger_sha256"],validation_names,
        Dict(name=>64 for name in validation_names),cohort,cohort_hash,reference_hash,reference.record["policy_sha256"],inputs)
    Inputs.independent_from!(validation,grid.record["families"])
    pair=Inputs.pair(validation,"validation")
    scores=[[Selection.score_inverse(candidate.matrix,grid.B,capture.figures,capture.responses;groups=Groups) for capture in pair] for candidate in fitted]
    index=Selection.select_candidate(fitted,scores)
    fitted[index].name==selected["selected"] || error("native selected candidate is not reproduced by the frozen rule")
    for (candidate,repeated) in zip(fitted,scores)
        recorded=only(filter(item->item["name"]==candidate.name,selected["candidates"]))
        C.parse_json(JSON3.write(repeated))==recorded["repeated_scores"] || error("native validation scores differ from actual means")
    end
    estimator=Inputs.packed(dirname(selected_path),"selected-estimator.f32le",selected["selected_estimator_sha256"],[253,3600],inputs)
    reinterpret(UInt32,vec(estimator))==reinterpret(UInt32,vec(fitted[index].matrix)) || error("native selected estimator differs")
    native=Inputs.packed(dirname(selected_path),"selected-controller.f32le",selected["selected_controller_sha256"],[253,3600],inputs)
    all(iszero,native[1:3,:]) && native[4:end,:]==-estimator[4:end,:] || error("native negative estimator/null rows differ")
    names=["locked-test-1","locked-test-2"]
    captures=Inputs.captures(locked["capture_ledger_path"],locked["capture_ledger_sha256"],names,
        Dict(name=>64 for name in names),cohort,cohort_hash,reference_hash,reference.record["policy_sha256"],inputs)
    Inputs.independent_from!(captures,grid.record["families"])
    repeated=Inputs.pair(captures,"locked-test")
    all(capture->!(capture.identity in values(selected["capture_identities"])) &&
        !(capture.detector_seed in values(selected["detector_seeds"])),repeated) || error("native locked data reused validation")
    locked_scores=[Selection.score_inverse(estimator,grid.B,capture.figures,capture.responses;groups=Groups) for capture in repeated]
    all(score->score.eligible,locked_scores) && C.parse_json(JSON3.write(locked_scores))==locked["scores"] || error("native locked utility is not reproduced")
    Reader.unchanged_inputs!(inputs)
    return (;version=1,passed=true,engine="heart",native_ingress_mode="deferred",locked_test_sha256=hash,
        selection_sha256=locked["selection_sha256"],selected=selected["selected"],
        selected_estimator_sha256=selected["selected_estimator_sha256"],selected_controller_sha256=selected["selected_controller_sha256"],
        native_reference_seal_sha256=reference_hash,physical_map=grid.record["physical_map"],
        actual_native_captures_revalidated=length(training)+length(validation)+length(captures),actual_native_references_revalidated=2,
        actual_training_grid_reproduced=true,actual_validation_selection_reproduced=true,actual_locked_utility_reproduced=true,
        input_files=inputs,elapsed_ns=time_ns()-Started,
        scope="cold native payload/public AOC replay; no active correction or hardware qualification")
end

function main(arguments=ARGS)
    length(arguments)==3 || error("expected LOCKED_TEST LOCKED_SHA FRESH_ADMISSION_OUTPUT")
    path,hash,output=arguments
    !ispath(output) && !islink(output) && isdir(dirname(abspath(output))) || error("native admission output must be fresh")
    try
        C.write_json(output,verify(path,hash));println(output)
    catch exception
        C.write_json(output,(;version=1,passed=false,locked_test_sha256=hash,failure=sprint(showerror,exception),elapsed_ns=time_ns()-Started))
        rethrow()
    end
end

abspath(PROGRAM_FILE)==(@__FILE__) && main()
