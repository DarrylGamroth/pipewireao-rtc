module HeartCalibrationCaptureInputs

include("heart_calibration_capture.jl")
const Reader=HeartCalibrationCapture
using SHA,LinearAlgebra,JSON3

function checked_payload(root,name,hash,inputs)
    name isa AbstractString && basename(name)==name && name!="." && name!=".." ||
        error("native grid payload must be a direct file")
    return Reader.bind!(inputs,joinpath(root,name),hash)
end

function packed(root,name,hash,shape,inputs;type=Float32)
    path=checked_payload(root,name,hash,inputs)
    length(shape)==2 && all(value->value isa Integer && value>0,shape) || error("native packed shape differs")
    rows,columns=Int.(shape)
    filesize(path)==sizeof(type)*rows*columns || error("native packed extent differs")
    result=permutedims(reshape(reinterpret(type,read(path)),columns,rows))
    all(isfinite,result) || error("nonfinite native packed matrix")
    return result
end

function grid(path,hash,reference,reference_hash,cohort,cohort_hash,inputs)
    Reader.bind!(inputs,path,hash)
    record=Reader.document(path)
    record["version"]==1 && record["engine"]=="heart" && record["backend"]=="cuda" &&
        record["native_ingress_mode"]=="deferred" && record["controller_sign"]==-1 &&
        record["grid_multipliers"]==[1,2,4] || error("native frozen grid contract differs")
    record["native_reference_seal_sha256"]==reference_hash &&
        record["reference_sha256"]==reference.record["native_reference_sha256"] &&
        record["qualification_mean_sha256"]==reference.record["native_qualification_sha256"] &&
        record["policy_sha256"]==reference.record["policy_sha256"] &&
        record["cohort_sha256"]==cohort_hash || error("native grid reference/policy/cohort differs")
    for (source,expected) in record["input_files"];Reader.bind!(inputs,source,expected);end
    root=dirname(path)
    names=Set(record["name"] for record in record["candidates"])
    names==Set("$family-$multiplier" for family in ("zonal","hadamard") for multiplier in (1,2,4)) &&
        length(record["candidates"])==6 || error("native candidate grid differs")
    matrices=Matrix{Float32}[]
    for candidate in record["candidates"]
        candidate["name"]==candidate["family"]*"-"*string(candidate["multiplier"]) &&
            candidate["family"] in ("zonal","hadamard") && candidate["multiplier"] in (1,2,4) &&
            candidate["layout"]=="ROW_MAJOR" && candidate["element_type"]=="F32_LE" &&
            candidate["shape"]==[253,3600] && candidate["repeat_scale"]>0 &&
            isfinite(candidate["repeat_scale"]) &&
            candidate["cutoff"]==candidate["multiplier"]*candidate["repeat_scale"] &&
            candidate["eligible_rank"]==(candidate["effective_rank"]>0) || error("native grid candidate differs")
        push!(matrices,packed(root,candidate["path"],candidate["sha256"],candidate["shape"],inputs))
        packed(root,candidate["forward_path"],candidate["forward_sha256"],[3600,277],inputs;type=Float64)
    end
    package=only(filter(stage->stage["name"]=="zonal-1",cohort["stages"]))["package"]
    B,proof=Reader.command_map(package,inputs)
    # JSON arrays replace Tuple shapes and NamedTuple fields after serialization.
    Reader.C.parse_json(JSON3.write(proof))==record["physical_map"] ||
        error("native grid physical map differs")
    return (;record,root,matrices,B)
end

function captures(path,hash,names,frames,cohort,cohort_hash,reference_hash,policy_hash,inputs)
    Reader.bind!(inputs,path,hash)
    ledger=Reader.document(path)
    ledger["version"]==1 && Set(keys(ledger))==Set(("version","runs")) || error("native capture ledger differs")
    records=Dict{String,Any}()
    for item in ledger["runs"]
        Set(keys(item))==Set(("path","sha256")) || error("native capture ledger entry differs")
        Reader.bind!(inputs,item["path"],item["sha256"])
        run=Reader.document(item["path"])
        run["cohort_sha256"]==cohort_hash && run["reference_freeze_sha256"]==reference_hash &&
            run["policy_sha256"]==policy_hash || error("native completed run binding differs")
        for completed in run["completed"]
            name=completed["name"]
            name in names && !haskey(records,name) || error("extra or duplicate native capture")
            stage=only(filter(stage->stage["name"]==name,cohort["stages"]))
            Reader.document(joinpath(stage["package"],"heart-calibration-plan.json"))["frames_per_probe"]==frames[name] ||
                error("native frozen averaging differs")
            records[name]=Reader.capture(stage,item["path"],item["sha256"],cohort,inputs)
        end
    end
    Set(keys(records))==Set(names) || error("independent native capture pair is incomplete")
    return records
end

function pair(records,family)
    a=records[family*"-1"];b=records[family*"-2"]
    a.detector_seed!=b.detector_seed && a.run!=b.run && a.identity!=b.identity && a.figures==b.figures ||
        error("native repeats must retain independent seeds/runs and the same represented figures")
    return (a,b)
end

function independent_from!(captures,training_families)
    identities=Set(identity for family in values(training_families) for identity in family["identities"])
    seeds=Set(seed for family in values(training_families) for seed in family["detector_seeds"])
    all(capture->!(capture.identity in identities) && !(capture.detector_seed in seeds),values(captures)) ||
        error("native validation reuses a training identity/seed")
    return nothing
end

function unchanged_inputs!(inputs)
    for (path,hash) in inputs;Reader.digest(path)==hash || error("native analysis input changed during calculation");end
    return nothing
end

end
