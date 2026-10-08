module CopperQuality

using TOML
import ..Common: read_json, write_json, sha256_file, cli_arguments
import ..CalibrationCampaign as Acquisition
import ..CopperReference as Reference
import ..CalibrationExport
import ..HILExport
import ..DeploymentConfiguration

export validate_recipe, schedule, validate_candidate, analysis_products, campaign, main

const PRODUCTS=("measured-background.f32le","measured-dark-variance.f64le",
    "measured-reference-pixels.f32le","measured-reference-variance.f64le","qualification-mean.f64le")
const SCOPE="descriptive one-direction candidate; no interaction-matrix, inverse, correction or rate acceptance"

function validate_recipe(value)
    expected=("version","actuator","amplitudes","repeats","frames_per_batch","reference","seed",
              "lamp_magnitude","settling","adc_upper_rail","request_timeout_ns","stage_timeout_seconds")
    Acquisition.fields(value,expected,"Copper quality recipe")
    Acquisition.isint(value["version"]) && value["version"]==1 ||
        throw(ArgumentError("complete Version 1 Copper quality recipe required"))
    Acquisition.positive_integer(value["actuator"],"actuator",277)
    Acquisition.positive_integer(value["repeats"],"repeats",4;minimum=2)
    Acquisition.positive_integer(value["frames_per_batch"],"frames per batch",16;minimum=2)
    Acquisition.isint(value["seed"]) && 0<=value["seed"]<=typemax(UInt32) ||
        throw(ArgumentError("seed must be UInt32"))
    Acquisition.number(value["lamp_magnitude"]) || throw(ArgumentError("lamp magnitude must be finite"))
    amplitudes=value["amplitudes"]
    amplitudes isa AbstractVector && 1<=length(amplitudes)<=3 || throw(ArgumentError("one to three amplitudes required"))
    reference=value["reference"]
    reference isa AbstractVector && length(reference)==277 || throw(ArgumentError("277 physical coordinates required"))
    Acquisition.validate_settling(value["settling"];copper=true)
    Acquisition.positive_integer(value["adc_upper_rail"],"ADC rail",65535)
    Acquisition.positive_integer(value["request_timeout_ns"],"request timeout",30_000_000_000)
    Acquisition.positive_integer(value["stage_timeout_seconds"],"stage timeout",1800)
    result=deepcopy(value)
    converted=Acquisition.wire_float32.(amplitudes)
    all(>(0),converted) && all(converted[i]<converted[i+1] for i in 1:length(converted)-1) ||
        throw(ArgumentError("distinct ascending positive Float32 amplitudes required"))
    result["amplitudes"]=Float64.(converted)
    result["reference"]=Float64.(Acquisition.wire_float32.(reference))
    return result
end

function schedule(recipe)
    reference=Float32.(recipe["reference"])
    actuator=recipe["actuator"]
    for value in recipe["amplitudes"]
        amplitude=Float32(value)
        plus=reference[actuator]+amplitude
        minus=reference[actuator]-amplitude
        isfinite(plus) && isfinite(minus) && plus>reference[actuator]>minus ||
            throw(ArgumentError("Float32 probe interval collapsed or overflowed"))
    end
    batches=Any[]
    function append_batch(label,repeat,amplitude,sign)
        figure=copy(reference)
        sign==0 || (figure[actuator]=figure[actuator]+Float32(sign)*Float32(amplitude))
        push!(batches,Dict{String,Any}("label"=>label,"repeat"=>repeat,"amplitude"=>amplitude,
            "sign"=>sign,"figure"=>Float64.(figure),"frames"=>recipe["frames_per_batch"]))
    end
    for repeat in 0:recipe["repeats"]-1
        append_batch("null_start",repeat,nothing,0)
        amplitudes=iseven(repeat) ? recipe["amplitudes"] : reverse(recipe["amplitudes"])
        signs=iseven(repeat) ? (1,-1) : (-1,1)
        for amplitude in amplitudes, sign in signs
            append_batch(sign>0 ? "positive" : "negative",repeat,amplitude,sign)
        end
        append_batch("null_end",repeat,nothing,0)
    end
    length(batches)<=32 || throw(ArgumentError("quality schedule exceeds 32 batches"))
    Acquisition.validate_batches([Dict("figure"=>item["figure"],"frames"=>item["frames"]) for item in batches])
    return batches
end

function candidate_paths(candidate)
    paths=[joinpath(candidate,name) for name in PRODUCTS]
    append!(paths,[joinpath(candidate,name) for name in ("recipe.json","reference-result.json",
        joinpath("training-package","hil","calibration_reference_analysis.jl"))])
    for stage in Reference.STAGES, name in ("analysis.json","stage-result.json")
        push!(paths,joinpath(candidate,stage*"-evidence",name))
    end
    return paths
end

function validate_candidate(candidate,base,recipe)
    record=read_json(joinpath(candidate,"reference-result.json"))
    original=Reference.validate_recipe(read_json(joinpath(candidate,"recipe.json")))
    record["phase"]=="complete-candidate" && record["profile"]=="copper" &&
        Set(keys(record["stages"]))==Set(Reference.STAGES) &&
        record["recipe_sha256"]==sha256_file(joinpath(candidate,"recipe.json")) ||
        throw(ArgumentError("complete Copper reference candidate required"))
    Acquisition.same_figure(original["reference"],recipe["reference"]) &&
        original["lamp_magnitude"]==recipe["lamp_magnitude"] &&
        original["adc_upper_rail"]==recipe["adc_upper_rail"] ||
        throw(ArgumentError("reference candidate lamp/reference/rail differs"))
    record["copy_inputs"]["base_descriptor_sha256"]==sha256_file(joinpath(base,"deployment.conf")) ||
        throw(ArgumentError("reference candidate science base differs"))
    helper_sha=sha256_file(joinpath(candidate,"training-package","hil","calibration_reference_analysis.jl"))
    products=Dict{String,String}()
    reports=Dict{String,String}()
    for stage in Reference.STAGES
        evidence=joinpath(candidate,stage*"-evidence")
        stage_result=read_json(joinpath(evidence,"stage-result.json"))
        all(get(stage_result,name,false)===true for name in
            ("restoration_confirmed","release_confirmed","shutdown_confirmed")) &&
            !haskey(stage_result,"failure") || throw(ArgumentError("reference candidate stage incomplete"))
        new_products,report_sha=Reference.analysis_products(candidate,evidence,stage,original,helper_sha)
        record["stages"][stage]["analysis_sha256"]==report_sha ||
            throw(ArgumentError("reference report digest differs"))
        merge!(products,new_products)
        reports[joinpath(evidence,"analysis.json")]=report_sha
    end
    products==record["artifacts"] || throw(ArgumentError("reference products differ"))
    Reference.check_products(candidate,products,reports)
    training_base=joinpath(candidate,"training-base")
    training_provenance=read_json(joinpath(training_base,"provenance.json"))
    base_provenance=read_json(joinpath(base,"provenance.json"))
    all(training_provenance[name]==base_provenance[name] for name in ("profile","engine","mode")) ||
        throw(ArgumentError("reference science graph differs"))
    sha256_file(joinpath(training_base,"graphs","graph.conf.in"))==
        sha256_file(joinpath(base,"graphs","graph.conf.in")) ||
        throw(ArgumentError("reference graph differs"))
    base_files=Acquisition.file_identity(joinpath(base,"calibration"))
    training_files=Acquisition.file_identity(joinpath(training_base,"calibration"))
    Set(keys(base_files))==Set(keys(training_files)) || throw(ArgumentError("science binding set differs"))
    background_name=only(item["file"] for item in base_provenance["parameters"] if item["name"]=="background")
    for name in keys(base_files)
        name==background_name && continue
        base_files[name]==training_files[name] || throw(ArgumentError("science binding differs: $name"))
    end
    training_files[background_name]==products["measured-background.f32le"] ||
        throw(ArgumentError("training background differs"))
    function fixture(path)
        model=TOML.parsefile(path)
        nodes=Dict(node["name"]=>node["config"] for node in model["nodes"])
        delete!(nodes["detector"],"rng_seed")
        delete!(nodes["pwfs"],"source_magnitude")
        return model
    end
    fixture(joinpath(base,"hil","plant.toml"))==fixture(joinpath(training_base,"hil","plant.toml")) ||
        throw(ArgumentError("reference detector or PWFS noise fixture differs"))
    return record,original
end

function source_snapshot(base,aoc,candidate,arguments)
    source=Dict{String,Any}("base"=>Acquisition.file_identity(base),
        "aoc"=>Acquisition.file_identity(aoc),"training_base"=>Acquisition.file_identity(joinpath(candidate,"training-base")),
        "helpers"=>Reference.input_snapshot(base,aoc)["helpers"],
        "orchestration"=>Acquisition.orchestration_sources())
    paths=vcat(candidate_paths(candidate),[arguments.recipe,arguments.calibration_binary,
        joinpath(HILExport.ScienceExport.package_root(),"src","copper_quality.jl"),joinpath(HILExport.ScienceExport.package_root(),"src","calibration_campaign.jl"),joinpath(HILExport.ScienceExport.package_root(),"src","copper_reference.jl")])
    source["files"]=Dict(abspath(path)=>sha256_file(Acquisition.regular(path)) for path in paths)
    return source
end

function copy_candidate(candidate,output)
    for name in PRODUCTS
        cp(Acquisition.regular(joinpath(candidate,name)),joinpath(output,name))
    end
    provenance=joinpath(output,"reference-candidate")
    mkpath(provenance)
    for name in ("recipe.json","reference-result.json")
        cp(Acquisition.regular(joinpath(candidate,name)),joinpath(provenance,name))
    end
    for stage in Reference.STAGES
        source=joinpath(candidate,stage*"-evidence")
        target=joinpath(provenance,stage*"-evidence")
        mkpath(target)
        for name in ("analysis.json","stage-result.json")
            cp(Acquisition.regular(joinpath(source,name)),joinpath(target,name))
        end
    end
end

function seal_files(output,package)
    files=Dict{String,String}()
    for name in ("recipe.json","schedule.json",PRODUCTS...)
        files[name]=sha256_file(joinpath(output,name))
    end
    for directory in ("reference-candidate",relpath(package,output))
        for (relative,sha) in Acquisition.file_identity(joinpath(output,directory))
            files[joinpath(directory,relative)]=sha
        end
    end
    return files
end

function check_seal(output,seal)
    seal["version"]==1 || throw(ArgumentError("quality input seal version differs"))
    actual=seal_files(output,joinpath(output,"training-package"))
    actual==seal["files"] || throw(ArgumentError("quality input seal differs"))
end

function analysis_products(output,evidence,recipe,plan)
    report_path=Acquisition.regular(joinpath(evidence,"analysis.json"))
    report=read_json(report_path)
    Acquisition.isint(report["version"]) && report["version"]==1 &&
        report["profile"]=="copper" && report["status"]=="characterized-candidate" &&
        report["public_methods"]==["Diagnostics.RepeatedResponseMoments","InteractionMatrices.ZonalPushPull"] &&
        report["scope"]==SCOPE && report["actuator"]==recipe["actuator"] &&
        report["samples_per_batch"]==recipe["frames_per_batch"] &&
        report["analysis_source_sha256"]==sha256_file(joinpath(output,"training-package","hil","calibration_quality_analysis.jl")) ||
        throw(ArgumentError("quality report declaration differs"))
    stage_path=joinpath(evidence,"stage-result.json")
    stage=read_json(stage_path)
    captures=stage["captures"]
    length(captures)==length(plan)==length(report["batches"]) &&
        length(report["amplitudes"])==length(recipe["amplitudes"]) ||
        throw(ArgumentError("quality report probe count differs"))
    manifests=String[]
    for (index,(capture,batch,batch_report)) in enumerate(zip(captures,plan,report["batches"]))
        probe=index-1
        all(Acquisition.isint(batch_report[name]) for name in ("probe","repeat","sign")) &&
            capture["probe"]==probe && Acquisition.same_figure(capture["figure"],batch["figure"]) &&
            batch_report["probe"]==probe && batch_report["label"]==batch["label"] &&
            batch_report["repeat"]==batch["repeat"] && batch_report["sign"]==batch["sign"] &&
            ((batch["amplitude"]===nothing && batch_report["amplitude"]===nothing) ||
             (batch["amplitude"]!==nothing && batch_report["amplitude"]!==nothing &&
              Acquisition.wire_float32(batch_report["amplitude"])==Acquisition.wire_float32(batch["amplitude"]))) ||
            throw(ArgumentError("quality report probe association differs"))
        completion=capture["completion"]
        path=Acquisition.regular(joinpath(evidence,"captured",completion["manifest"]))
        sha256_file(path)==completion["sha256"] || throw(ArgumentError("quality manifest changed"))
        push!(manifests,completion["sha256"])
    end
    expected_hashes=Dict("quality_inputs_sha256"=>sha256_file(joinpath(output,"quality-inputs.json")),
        "recipe_sha256"=>sha256_file(joinpath(output,"recipe.json")),
        "schedule_sha256"=>sha256_file(joinpath(output,"schedule.json")),
        "stage_result_sha256"=>sha256_file(stage_path),
        "producing_reference_analysis_sha256"=>sha256_file(joinpath(output,"reference-candidate","training-evidence","analysis.json")),
        "measured_reference_sha256"=>sha256_file(joinpath(output,"measured-reference-pixels.f32le")),
        "capture_manifest_sha256"=>manifests)
    report["inputhashes"]==expected_hashes || throw(ArgumentError("quality report input identities differ"))
    batch_count=length(plan);amplitude_count=length(recipe["amplitudes"]);repeats=recipe["repeats"]
    expected=Dict(
        "batch-means.f64le"=>([batch_count,3600],"normalized pixel"),
        "batch-variances.f64le"=>([batch_count,3600],"normalized pixel squared"),
        "derivative-repeats.f64le"=>([amplitude_count,repeats,3600],"normalized pixel per micrometre OPD"),
        "derivative-means.f64le"=>([amplitude_count,3600],"normalized pixel per micrometre OPD"))
    records=report["artifacts"]
    length(records)==4 && Set(item["path"] for item in records)==Set(keys(expected)) ||
        throw(ArgumentError("quality numerical artifact set differs"))
    products=Dict{String,String}()
    for item in records
        name=item["path"]
        shape,units=expected[name]
        bytes=prod(shape)*8
        Set(keys(item))==Set(("path","sha256","bytes","shape","element_type","layout","units")) &&
            item["shape"]==shape && item["bytes"]==bytes && item["element_type"]=="F64_LE" &&
            item["layout"]=="ROW_MAJOR" && item["units"]==units ||
            throw(ArgumentError("quality artifact contract differs"))
        path=Acquisition.regular(joinpath(output,name))
        filesize(path)==bytes && sha256_file(path)==item["sha256"] ||
            throw(ArgumentError("quality artifact bytes differ"))
        products[name]=item["sha256"]
    end
    return products,sha256_file(report_path)
end

function campaign(arguments)
    started=time_ns()
    Base.ENDIAN_BOM==0x04030201 || throw(ArgumentError("packed capture requires little-endian host"))
    recipe=validate_recipe(read_json(arguments.recipe))
    plan=schedule(recipe)
    base=abspath(arguments.base_package)
    candidate=abspath(arguments.reference_candidate)
    aoc=abspath(arguments.aoc_source)
    Reference.validate_base(base,arguments.pipewire_prefix,recipe)
    validate_candidate(candidate,base,recipe)
    for relative in (joinpath("src","reference_frames","dark_frame_moments.jl"),
                     joinpath("src","diagnostics","repeated_response_moments.jl"))
        isfile(joinpath(aoc,relative)) || throw(ArgumentError("AOC reference/response methods required"))
    end
    output=abspath(arguments.output)
    !ispath(output) && !islink(output) && !ispath(arguments.runtime) && !islink(arguments.runtime) ||
        throw(ArgumentError("quality output and runtime roots must be fresh"))
    snapshot=source_snapshot(base,aoc,candidate,arguments)
    mkpath(output)
    write_json(joinpath(output,"recipe.json"),recipe)
    write_json(joinpath(output,"schedule.json"),plan)
    copy_candidate(candidate,output)
    record=Dict{String,Any}("version"=>1,"phase"=>"candidate","profile"=>"copper",
        "scope"=>"CPU measured precision/linearity characterization candidate only; no reference adoption, inverse, correction or cadence acceptance",
        "source_files"=>snapshot,"reference_candidate_sha256"=>sha256_file(joinpath(candidate,"reference-result.json")))
    try
        recipe_sha=sha256_file(joinpath(output,"recipe.json"))
        schedule_sha=sha256_file(joinpath(output,"schedule.json"))
        product_hashes=Dict(name=>sha256_file(joinpath(output,name)) for name in PRODUCTS)
        copied=Acquisition.file_identity(joinpath(output,"reference-candidate"))
        training=Dict("seeds"=>Dict("training"=>recipe["seed"]),
            "lamp_magnitude"=>recipe["lamp_magnitude"],"adc_upper_rail"=>recipe["adc_upper_rail"])
        prepared=Reference.stage_base(base,joinpath(output,"training-base"),training,"training",
            read(joinpath(output,"measured-background.f32le")),aoc,arguments.pipewire_prefix)
        package=joinpath(output,"training-package")
        total_bytes=sum(item["frames"]*22596 for item in plan)
        CalibrationExport.export_package((;base_package=prepared,output=package,
            pipewire_prefix=arguments.pipewire_prefix,deployment=true,
            calibration_binary=arguments.calibration_binary,
            illumination="lamp",calibration_stage="training",capture_max_bytes=total_bytes))
        seal=Dict("version"=>1,"files"=>seal_files(output,package))
        write_json(joinpath(output,"quality-inputs.json"),seal)
        seal_sha=sha256_file(joinpath(output,"quality-inputs.json"))
        record["quality_inputs_sha256"]=seal_sha
        check_inputs=()->begin
            source_snapshot(base,aoc,candidate,arguments)==snapshot || throw(ArgumentError("quality source changed"))
            sha256_file(joinpath(output,"recipe.json"))==recipe_sha &&
                sha256_file(joinpath(output,"schedule.json"))==schedule_sha ||
                throw(ArgumentError("quality recipe or schedule changed"))
            all(sha256_file(joinpath(output,name))==hash for (name,hash) in product_hashes) ||
                throw(ArgumentError("copied reference candidate changed"))
            Acquisition.file_identity(joinpath(output,"reference-candidate"))==copied ||
                throw(ArgumentError("candidate provenance changed"))
            sha256_file(joinpath(output,"quality-inputs.json"))==seal_sha ||
                throw(ArgumentError("quality seal changed"))
            check_seal(output,seal)
        end
        check_inputs()
        evidence=joinpath(output,"training-evidence")
        batches=[Dict("figure"=>item["figure"],"frames"=>item["frames"]) for item in plan]
        record["stage"]=Acquisition.run_stage(package,evidence,joinpath(arguments.runtime,"training"),
            recipe,"training";batches)
        check_inputs()
        analysis_started=time_ns()
        Acquisition.checked_analysis([arguments.julia,"--startup-file=no","--threads=1,0",
            "--project="*joinpath(package,"hil"),joinpath(package,"hil","calibration_quality_analysis.jl"),
            output,evidence],evidence,"analysis",recipe["stage_timeout_seconds"])
        record["analysis_wall_ns"]=time_ns()-analysis_started
        check_inputs()
        products,report_sha=analysis_products(output,evidence,recipe,plan)
        record["artifacts"]=products
        record["analysis_sha256"]=report_sha
        record["phase"]="complete-candidate"
    catch error
        record["phase"]="failed-candidate"
        record["failure"]=sprint(showerror,error)
        rethrow()
    finally
        record["timing_ns"]=Dict("total_campaign"=>time_ns()-started)
        DeploymentConfiguration.atomic_record(joinpath(output,"quality-result.json"),record)
    end
    return joinpath(output,"quality-result.json")
end

function main(argv=ARGS)
    arguments=cli_arguments(argv;required=["base-package","output","recipe","aoc-source",
        "calibration-binary","runtime","reference-candidate"],
        defaults=(pipewire_prefix="/opt/pipewireao",julia="julia"))
    arguments.pipewire_prefix=="/opt/pipewireao" || throw(ArgumentError("only /opt/pipewireao supported"))
    println(campaign(arguments))
    return 0
end

end # module
