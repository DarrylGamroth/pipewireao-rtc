module CopperReference

using TOML
import ..Common: read_json, write_json, sha256_file, cli_arguments
import ..CalibrationCampaign as Acquisition
import ..Deployment
import ..CalibrationExport
import ..HILExport

export validate_recipe, validate_base, stage_base, input_snapshot, check_products,
       analysis_products, campaign, main

const STAGES=("dark","training","qualification")
const HELPER=joinpath(HILExport.ROOT,"hil","calibration_reference_analysis.jl")

function validate_recipe(value)
    expected=("version","dark_frames","training_frames","qualification_frames","seeds",
              "lamp_magnitude","reference","settling","adc_upper_rail",
              "request_timeout_ns","stage_timeout_seconds")
    Acquisition.fields(value,expected,"Copper reference recipe")
    Acquisition.isint(value["version"]) && value["version"]==1 ||
        throw(ArgumentError("declare complete Version 1 Copper reference recipe"))
    for stage in STAGES
        Acquisition.positive_integer(value[stage*"_frames"],stage*" frames",64;minimum=2)
    end
    seeds=Acquisition.fields(value["seeds"],STAGES,"Copper detector seeds")
    all(x->Acquisition.isint(x) && 0<=x<=typemax(UInt32),values(seeds)) &&
        length(Set(values(seeds)))==3 || throw(ArgumentError("three distinct UInt32 seeds required"))
    Acquisition.number(value["lamp_magnitude"]) || throw(ArgumentError("lamp magnitude must be finite"))
    reference=value["reference"]
    reference isa AbstractVector && length(reference)==277 || throw(ArgumentError("reference requires 277 coordinates"))
    Acquisition.validate_settling(value["settling"];copper=true)
    Acquisition.positive_integer(value["adc_upper_rail"],"ADC rail",65535)
    Acquisition.positive_integer(value["request_timeout_ns"],"request timeout",30_000_000_000)
    Acquisition.positive_integer(value["stage_timeout_seconds"],"stage timeout",3600)
    result=deepcopy(value)
    result["reference"]=Float64.(Acquisition.wire_float32.(reference))
    return result
end

function validate_base(base,prefix,recipe)
    specification=Deployment.profile(joinpath(base,"deployment.conf"),prefix)
    provenance=read_json(joinpath(base,"provenance.json"))
    provenance["profile"]=="copper" && provenance["engine"] in ("fgn","jfg") &&
        provenance["mode"]=="frame" && get(provenance["hil"],"backend",nothing)=="cpu" ||
        throw(ArgumentError("Copper reference requires complete-frame CPU science"))
    source=only(filter(owner->owner["role"]==specification["source-owner"],specification["owners"]))
    argv=source["argv"]
    count(==("--backend"),argv)==1 && argv[findfirst(==("--backend"),argv)+1]=="cpu" ||
        throw(ArgumentError("source owner must select CPU backend"))
    graph=Deployment.decode(joinpath(base,"graphs","graph.conf.in"),prefix)
    CalibrationExport.split_graph(graph,"copper",provenance["engine"],"reference-validation")
    bindings=filter(item->item["name"]=="background",provenance["parameters"])
    length(bindings)==1 || throw(ArgumentError("one Copper background binding required"))
    binding=only(bindings)
    binding["element_type"]=="F32_LE" && binding["shape"]==[64,64] ||
        throw(ArgumentError("Copper background extent/type differs"))
    pixel=only(filter(node->node["label"]=="pixel-calibration-u16-f32",graph["filter.graph"]["nodes"]))
    filename=binding["file"]
    filename isa AbstractString && basename(filename)==filename && filename ∉ ("",".","..") &&
        binding["endpoint"]==pixel["name"]*":background" &&
        !islink(joinpath(base,"calibration",filename)) || throw(ArgumentError("background binding differs"))
    project=TOML.parsefile(joinpath(base,"hil","Project.toml"))
    get(get(project,"sources",Dict()),"AdaptiveOpticsCalibration",nothing)==Dict("path"=>"packages/AdaptiveOpticsCalibration") ||
        throw(ArgumentError("base must declare local AOC dependency"))
    detector=only(filter(node->node["name"]=="detector",TOML.parsefile(joinpath(base,"hil","plant.toml"))["nodes"]))["config"]
    Acquisition.isint(detector["bits"]) && detector["bits"]==14 ||
        throw(ArgumentError("Copper requires declared 14-bit detector"))
    Acquisition.validate_detector_rail(detector,recipe)
    return specification,provenance,binding
end

function input_snapshot(base,aoc)
    return Dict("base_descriptor_sha256"=>sha256_file(joinpath(base,"deployment.conf")),
                "base_files"=>Acquisition.file_identity(base),
                "aoc_files"=>Acquisition.file_identity(aoc),
                "helpers"=>Dict(basename(path)=>sha256_file(path) for path in
                    readdir(joinpath(HILExport.ROOT,"hil");join=true)
                    if endswith(path,".jl") && !startswith(basename(path),"test_")))
end

function check_products(output,products,reports)
    for (name,expected) in products
        path=Acquisition.regular(joinpath(output,name))
        sha256_file(path)==expected || throw(ArgumentError("measured candidate changed: $name"))
    end
    for (path,expected) in reports
        sha256_file(Acquisition.regular(path))==expected || throw(ArgumentError("producing analysis report changed"))
    end
end

function analysis_products(output,evidence,stage,recipe,helper_sha)
    path=Acquisition.regular(joinpath(evidence,"analysis.json"))
    report=read_json(path)
    method=stage=="dark" ? "ReferenceFrames.DarkFrameMoments" : "Diagnostics.RepeatedResponseMoments"
    identities=report["input_identities"]
    report["profile"]=="copper" && report["stage"]==stage && report["status"]=="valid-candidate" &&
        report["public_method"]==method && report["samples"]==recipe[stage*"_frames"] &&
        report["analysis_source_sha256"]==helper_sha &&
        identities["recipe_sha256"]==sha256_file(joinpath(output,"recipe.json")) &&
        identities["stage_result_sha256"]==sha256_file(joinpath(evidence,"stage-result.json")) ||
        throw(ArgumentError("Copper producing report differs from declared stage"))
    expected=stage=="dark" ? Dict(
        "measured-background.f32le"=>(16384,[64,64],"F32_LE","ADC"),
        "measured-dark-variance.f64le"=>(32768,[64,64],"F64_LE","ADC squared")) :
        stage=="training" ? Dict(
        "measured-reference-pixels.f32le"=>(14400,[3600],"F32_LE","normalized pixel"),
        "measured-reference-variance.f64le"=>(28800,[3600],"F64_LE","normalized pixel squared")) :
        Dict("qualification-mean.f64le"=>(28800,[3600],"F64_LE","normalized pixel"))
    records=report["artifacts"]
    length(records)==length(expected) && Set(item["path"] for item in records)==Set(keys(expected)) ||
        throw(ArgumentError("Copper producing report artifact set differs"))
    hashes=Dict{String,String}()
    for item in records
        name=item["path"]
        bytes,shape,element,units=expected[name]
        item["bytes"]==bytes && item["shape"]==shape && item["element_type"]==element &&
            item["layout"]=="ROW_MAJOR" && item["units"]==units ||
            throw(ArgumentError("Copper candidate artifact contract differs"))
        candidate=Acquisition.regular(joinpath(output,name))
        filesize(candidate)==bytes && sha256_file(candidate)==item["sha256"] ||
            throw(ArgumentError("Copper candidate bytes differ from report"))
        hashes[name]=item["sha256"]
    end
    return hashes,sha256_file(path)
end

function stage_base(base,output,recipe,stage,background,aoc_source,prefix)
    stage in STAGES || throw(ArgumentError("unknown Copper reference stage"))
    _,provenance,binding=validate_base(base,prefix,recipe)
    length(background)==16384 && all(isfinite,reinterpret(Float32,background)) ||
        throw(ArgumentError("Copper background requires 4096 finite Float32 ADC values"))
    !ispath(output) && !islink(output) || throw(ArgumentError("Copper stage base must be fresh"))
    Acquisition.copy_tree(base,output)
    path=joinpath(output,"calibration",binding["file"])
    write(path,background)
    haskey(binding,"sha256") && (binding["sha256"]=sha256_file(path))
    model_path=joinpath(output,"hil","plant.toml")
    model=Acquisition.set_model_setting(read(model_path,String),"pwfs","source_magnitude",recipe["lamp_magnitude"])
    model=Acquisition.set_model_setting(model,"detector","rng_seed",recipe["seeds"][stage])
    write(model_path,model)
    target=joinpath(output,"hil","packages","AdaptiveOpticsCalibration")
    rm(target;recursive=true)
    HILExport.copy_package(aoc_source,target)
    for helper in readdir(joinpath(HILExport.ROOT,"hil");join=true)
        endswith(helper,".jl") && !startswith(basename(helper),"test_") || continue
        cp(helper,joinpath(output,"hil",basename(helper));force=true)
    end
    provenance["reference_campaign_inputs"]=Dict("stage"=>stage,"recipe"=>recipe,
        "source_deployment_sha256"=>sha256_file(joinpath(base,"deployment.conf")),
        "background_sha256"=>sha256_file(path),"aoc_files"=>Acquisition.file_identity(target),
        "qualification"=>"measured candidate only; no reference adoption, interaction matrix, inverse or correction acceptance",
        "historical_fixture"=>"Only background replaced; other offset provenance remains historical.")
    write_json(joinpath(output,"provenance.json"),provenance)
    descriptor=read_json(joinpath(output,"deployment.conf"))
    descriptor["artifacts"]=Dict(relative=>sha for (relative,sha) in Acquisition.file_identity(output)
        if relative!="deployment.conf")
    write_json(joinpath(output,"deployment.conf"),descriptor)
    Deployment.profile(joinpath(output,"deployment.conf"),prefix)
    return output
end

function campaign(arguments)
    started=time_ns()
    Base.ENDIAN_BOM==0x04030201 || throw(ArgumentError("packed capture requires little-endian host"))
    recipe=validate_recipe(read_json(arguments.recipe))
    base=abspath(arguments.base_package)
    validate_base(base,arguments.pipewire_prefix,recipe)
    aoc=abspath(arguments.aoc_source)
    for relative in (joinpath("src","reference_frames","dark_frame_moments.jl"),
                     joinpath("src","diagnostics","repeated_response_moments.jl"))
        isfile(joinpath(aoc,relative)) || throw(ArgumentError("AOC dark/repeated-response methods required"))
    end
    output=abspath(arguments.output)
    !ispath(output) && !islink(output) && !ispath(arguments.runtime) && !islink(arguments.runtime) ||
        throw(ArgumentError("candidate and runtime roots must be fresh"))
    snapshot=input_snapshot(base,aoc)
    orchestration=Acquisition.orchestration_sources()
    sources=copy(orchestration)
    merge!(sources,Dict(abspath(path)=>sha256_file(path) for path in
        (HELPER,abspath(arguments.rtc_binary),abspath(arguments.calibration_binary),
         abspath(arguments.recipe))))
    mkpath(output)
    write_json(joinpath(output,"recipe.json"),recipe)
    recipe_sha=sha256_file(joinpath(output,"recipe.json"))
    record=Dict{String,Any}("version"=>1,"phase"=>"candidate","stages"=>Dict{String,Any}(),
        "profile"=>"copper","source_files"=>sources,"copy_inputs"=>snapshot,
        "recipe_sha256"=>recipe_sha,
        "scope"=>"CPU measured dark/reference candidates; no scientific acceptance, activation, interaction matrix or cadence qualification")
    background=zeros(UInt8,16384)
    products=Dict{String,String}()
    reports=Dict{String,String}()
    check_inputs=()->begin
        input_snapshot(base,aoc)==snapshot && sha256_file(joinpath(output,"recipe.json"))==recipe_sha ||
            throw(ArgumentError("reference copy inputs or recipe changed"))
        Acquisition.orchestration_sources()==orchestration &&
            all(sha256_file(path)==digest for (path,digest) in sources) ||
            throw(ArgumentError("reference campaign source changed"))
        check_products(output,products,reports)
    end
    try
        for stage in STAGES
            check_inputs()
            count=recipe[stage*"_frames"]
            prepared=stage_base(base,joinpath(output,stage*"-base"),recipe,stage,background,aoc,arguments.pipewire_prefix)
            package=joinpath(output,stage*"-package")
            CalibrationExport.export_package((;base_package=prepared,output=package,
                pipewire_prefix=arguments.pipewire_prefix,deployment=true,
                rtc_binary=arguments.rtc_binary,calibration_binary=arguments.calibration_binary,
                illumination=stage=="dark" ? "dark" : "lamp",calibration_stage=stage,
                capture_max_bytes=count*22596))
            evidence=joinpath(output,stage*"-evidence")
            check_inputs()
            record["stages"][stage]=Acquisition.run_stage(package,evidence,joinpath(arguments.runtime,stage),
                recipe,stage;frames=count)
            check_inputs()
            analysis_started=time_ns()
            response=Acquisition.checked_analysis([arguments.julia,"--startup-file=no","--threads=1,0",
                "--project="*joinpath(package,"hil"),joinpath(package,"hil","calibration_reference_analysis.jl"),
                stage,output,evidence],evidence,"analysis",recipe["stage_timeout_seconds"])
            record["stages"][stage]["analysis_wall_ns"]=time_ns()-analysis_started
            new_products,report_sha=analysis_products(output,evidence,stage,recipe,
                sources[HELPER])
            if stage=="qualification"
                comparison=read_json(joinpath(evidence,"analysis.json"))["comparison"]
                comparison["reference_sha256"]==products["measured-reference-pixels.f32le"] ||
                    throw(ArgumentError("qualification differs from frozen training reference"))
            end
            merge!(products,new_products)
            reports[joinpath(evidence,"analysis.json")]=report_sha
            record["stages"][stage]["analysis_sha256"]=report_sha
            stage=="dark" && (background=read(joinpath(output,"measured-background.f32le")))
        end
        check_inputs()
        record["phase"]="complete-candidate"
    catch error
        record["phase"]="failed-candidate"
        record["failure"]=sprint(showerror,error)
        rethrow()
    finally
        record["artifacts"]=products
        record["timing_ns"]=Dict("total_campaign"=>time_ns()-started)
        Deployment.atomic_record(joinpath(output,"reference-result.json"),record)
    end
    return joinpath(output,"reference-result.json")
end

function main(argv=ARGS)
    arguments=cli_arguments(argv;required=["base-package","output","recipe","aoc-source","rtc-binary",
        "calibration-binary","runtime"],defaults=(pipewire_prefix="/opt/pipewireao",julia="julia"))
    arguments.pipewire_prefix=="/opt/pipewireao" || throw(ArgumentError("only /opt/pipewireao supported"))
    println(campaign(arguments))
end

end # module
