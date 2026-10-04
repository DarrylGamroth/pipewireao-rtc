using Test

using PipeWireAODeployment
const CopperTestModules=PipeWireAODeployment
const A=CopperTestModules.CalibrationCampaign
const R=CopperTestModules.CopperReference
const Q=CopperTestModules.CopperQuality
const C=CopperTestModules.Common

reference_recipe()=Dict{String,Any}(
    "version"=>1,"dark_frames"=>8,"training_frames"=>8,"qualification_frames"=>8,
    "seeds"=>Dict("dark"=>111,"training"=>222,"qualification"=>333),
    "lamp_magnitude"=>5.752574989159953,"reference"=>zeros(277),
    "settling"=>Dict("kind"=>"discard_exposures","frames"=>1),
    "adc_upper_rail"=>16383,"request_timeout_ns"=>30_000_000_000,
    "stage_timeout_seconds"=>300)
quality_recipe()=Dict{String,Any}(
    "version"=>1,"actuator"=>139,"amplitudes"=>[0.02,0.04,0.08],
    "repeats"=>2,"frames_per_batch"=>8,"reference"=>zeros(277),
    "seed"=>444,"lamp_magnitude"=>5.752574989159953,
    "settling"=>Dict("kind"=>"discard_exposures","frames"=>1),
    "adc_upper_rail"=>16383,"request_timeout_ns"=>30_000_000_000,
    "stage_timeout_seconds"=>300)

@testset "Copper reference policy" begin
    original=reference_recipe()
    accepted=R.validate_recipe(original)
    accepted["reference"][1]=1
    @test original["reference"][1]==0
    for mutation in (r->(r["version"]=true),r->(r["dark_frames"]=1),
                     r->(r["seeds"]["dark"]=r["seeds"]["training"]),
                     r->(r["reference"]=zeros(276)),
                     r->(r["settling"]=Dict("kind"=>"immediate")),
                     r->(r["request_timeout_ns"]=30_000_000_001))
        bad=reference_recipe();mutation(bad)
        @test_throws ArgumentError R.validate_recipe(bad)
    end
end

@testset "Copper quality represented balanced schedule" begin
    original=quality_recipe()
    recipe=Q.validate_recipe(original)
    plan=Q.schedule(recipe)
    @test length(plan)==16
    @test [x["label"] for x in plan[1:8]]==
        ["null_start","positive","negative","positive","negative","positive","negative","null_end"]
    @test [x["sign"] for x in plan[10:15]]==[-1,1,-1,1,-1,1]
    @test [x["amplitude"] for x in plan[10:15]]==
        repeat(reverse(recipe["amplitudes"]);inner=2)
    @test plan[2]["figure"][139]==Float64(Float32(recipe["amplitudes"][1]))
    @test all(x["frames"]==8 && length(x["figure"])==277 for x in plan)
    recipe4=quality_recipe();recipe4["repeats"]=4
    @test length(Q.schedule(Q.validate_recipe(recipe4)))==32
    for mutation in (r->(r["version"]=true),r->(r["actuator"]=278),
                     r->(r["amplitudes"]=[0.02,0.02]),r->(r["amplitudes"]=[0.04,0.02]),
                     r->(r["amplitudes"]=[1e-100]),r->(r["frames_per_batch"]=1),
                     r->(r["repeats"]=5),r->(r["seed"]=true),
                     r->(r["settling"]=Dict("kind"=>"immediate")))
        bad=quality_recipe();mutation(bad)
        @test_throws ArgumentError Q.validate_recipe(bad)
    end
    collapsed=quality_recipe();collapsed["reference"][139]=1_000_000.0
    @test_throws ArgumentError Q.schedule(Q.validate_recipe(collapsed))
end

function quality_report_fixture(root)
    evidence=joinpath(root,"training-evidence")
    mkpath(evidence)
    helper=joinpath(root,"training-package","hil","calibration_quality_analysis.jl")
    mkpath(dirname(helper));write(helper,"helper\n")
    producer=joinpath(root,"reference-candidate","training-evidence","analysis.json")
    mkpath(dirname(producer));write(producer,"{}\n")
    write(joinpath(root,"measured-reference-pixels.f32le"),zeros(UInt8,14400))
    C.write_json(joinpath(root,"quality-inputs.json"),Dict())
    recipe=quality_recipe();recipe["amplitudes"]=[0.02];recipe["frames_per_batch"]=2
    recipe=Q.validate_recipe(recipe)
    plan=Q.schedule(recipe)
    C.write_json(joinpath(root,"recipe.json"),recipe)
    C.write_json(joinpath(root,"schedule.json"),plan)
    captures=Any[]
    for (index,batch) in enumerate(plan)
        serial=4+3*(index-1)
        path=joinpath(evidence,"captured",string(serial),"manifest.json")
        mkpath(dirname(path));write(path,"{}\n")
        push!(captures,Dict("probe"=>index-1,"figure"=>batch["figure"],
            "completion"=>Dict("manifest"=>"$(serial)/manifest.json","sha256"=>C.sha256_file(path))))
    end
    C.write_json(joinpath(evidence,"stage-result.json"),Dict("captures"=>captures))
    contracts=Dict(
        "batch-means.f64le"=>([length(plan),3600],"normalized pixel"),
        "batch-variances.f64le"=>([length(plan),3600],"normalized pixel squared"),
        "derivative-repeats.f64le"=>([1,2,3600],"normalized pixel per micrometre OPD"),
        "derivative-means.f64le"=>([1,3600],"normalized pixel per micrometre OPD"))
    artifacts=Any[]
    for (name,(shape,units)) in contracts
        bytes=prod(shape)*8
        path=joinpath(root,name)
        write(path,zeros(UInt8,bytes))
        push!(artifacts,Dict("path"=>name,"sha256"=>C.sha256_file(path),"bytes"=>bytes,
            "shape"=>shape,"element_type"=>"F64_LE","layout"=>"ROW_MAJOR","units"=>units))
    end
    report=Dict{String,Any}("version"=>1,"profile"=>"copper","status"=>"characterized-candidate",
        "public_methods"=>["Diagnostics.RepeatedResponseMoments","InteractionMatrices.ZonalPushPull"],
        "scope"=>Q.SCOPE,"actuator"=>recipe["actuator"],"samples_per_batch"=>2,
        "analysis_source_sha256"=>C.sha256_file(helper),
        "batches"=>[Dict("probe"=>index-1,"label"=>batch["label"],"repeat"=>batch["repeat"],
            "sign"=>batch["sign"],"amplitude"=>batch["amplitude"]) for (index,batch) in enumerate(plan)],
        "amplitudes"=>[Dict()],"artifacts"=>artifacts,
        "inputhashes"=>Dict("quality_inputs_sha256"=>C.sha256_file(joinpath(root,"quality-inputs.json")),
            "recipe_sha256"=>C.sha256_file(joinpath(root,"recipe.json")),
            "schedule_sha256"=>C.sha256_file(joinpath(root,"schedule.json")),
            "stage_result_sha256"=>C.sha256_file(joinpath(evidence,"stage-result.json")),
            "producing_reference_analysis_sha256"=>C.sha256_file(producer),
            "measured_reference_sha256"=>C.sha256_file(joinpath(root,"measured-reference-pixels.f32le")),
            "capture_manifest_sha256"=>[x["completion"]["sha256"] for x in captures]))
    C.write_json(joinpath(evidence,"analysis.json"),report)
    return evidence,recipe,plan,report
end

@testset "Copper quality typed producer report" begin
    mktempdir() do root
        evidence,recipe,plan,report=quality_report_fixture(root)
        products,_=Q.analysis_products(root,evidence,recipe,plan)
        @test Set(keys(products))==Set(("batch-means.f64le","batch-variances.f64le",
            "derivative-repeats.f64le","derivative-means.f64le"))
        path=joinpath(evidence,"analysis.json")
        for mutation in (r->(r["version"]=true),r->(r["status"]="complete"),
                         r->(r["batches"][1]["probe"]=true),
                         r->(r["inputhashes"]["recipe_sha256"]="wrong"),
                         r->push!(r["artifacts"],Dict("path"=>"extra")))
            bad=deepcopy(report);mutation(bad)
            C.write_json(path,bad)
            @test_throws ArgumentError Q.analysis_products(root,evidence,recipe,plan)
        end
        C.write_json(path,report)
        write(joinpath(root,"batch-means.f64le"),"changed")
        @test_throws ArgumentError Q.analysis_products(root,evidence,recipe,plan)
    end
end
