using Test
using JSON3
include("calibration_quality_analysis.jl")
const CQA = CalibrationQualityAnalysis
const CRA = CQA.CalibrationReferenceAnalysis

json_write(path,value) = write(path,JSON3.write(value))
json_read(path) = JSON3.read(read(path,String),Dict{String,Any})
dict(value) = JSON3.read(JSON3.write(value),Dict{String,Any})

function fixture(root; reference_value=0f0, amplitudes=Float32[.02,.04], frames=3)
    output,evidence = joinpath(root,"output"),joinpath(root,"training-evidence")
    mkpath(output);mkpath(evidence)
    reference=zeros(Float32,277);reference[139]=reference_value
    recipe=dict((;version=1,actuator=139,amplitudes,repeats=2,frames_per_batch=frames,
        reference,seed=444,lamp_magnitude=5.752574989159953,
        settling=(;kind="discard_exposures",frames=1),adc_upper_rail=16383,
        request_timeout_ns=30_000_000_000,stage_timeout_seconds=900))
    json_write(joinpath(output,"recipe.json"),recipe)
    schedule=CQA.expected_schedule(recipe)
    json_write(joinpath(output,"schedule.json"),schedule)
    producer=joinpath(output,"reference-candidate","training-evidence");mkpath(producer)
    producer_recipe=(;version=1,dark_frames=2,training_frames=2,qualification_frames=2,
        seeds=(;dark=1,training=2,qualification=3),lamp_magnitude=recipe["lamp_magnitude"],
        reference,settling=recipe["settling"],adc_upper_rail=16383,
        request_timeout_ns=30_000_000_000,stage_timeout_seconds=900)
    producer_recipe_path=joinpath(output,"reference-candidate","recipe.json")
    json_write(producer_recipe_path,producer_recipe)
    producer_stage_path=joinpath(producer,"stage-result.json");json_write(producer_stage_path,(;completed=true))
    reference_pixels=Float32[1+j/4096 for j in 1:3600]
    reference_path=joinpath(output,"measured-reference-pixels.f32le")
    write(reference_path,CRA.packed(reference_pixels))
    helper_path=joinpath(output,"training-package","hil");mkpath(helper_path)
    for name in ("calibration_quality_analysis.jl","calibration_reference_analysis.jl")
        cp(joinpath(@__DIR__,name),joinpath(helper_path,name))
    end
    producing_report=(;version=1,profile="copper",stage="training",status="valid-candidate",
        public_method="Diagnostics.RepeatedResponseMoments",public_status="ResponseMomentsValid",
        analysis_source_sha256=CRA.digest(joinpath(@__DIR__,"calibration_reference_analysis.jl")),
        measurement_order=CRA.MEASUREMENT_ORDER,variance_normalization="N-1",
        variance_scope=CRA.VARIANCE_SCOPE,qualification=CRA.QUALIFICATION_SCOPE,
        artifacts=[(;path="measured-reference-pixels.f32le",sha256=CRA.digest(reference_path),
            bytes=14400,shape=[3600],element_type="F32_LE",layout="ROW_MAJOR",units="normalized pixel")],
        input_identities=(;recipe_sha256=CRA.digest(producer_recipe_path),stage_result_sha256=CRA.digest(producer_stage_path)))
    json_write(joinpath(producer,"analysis.json"),producing_report)
    detector=(;rows=64,columns=64,bits=14,rng_seed=444,exposure_duration_s=.002)
    mapping=(;opaque_domain=1,complete_domain=collect(1:16))
    settings=(;detector_config=detector,graph_sha256="a"^64,wfs_active_sha256=nothing)
    settings_sha=bytes2hex(CRA.SHA.sha256(JSON3.write(settings)))
    cur(sequence,model_ns)=(;domain=1,generation=1,sequence,model_ns)
    startup=(;version=1,profile="copper",backend="cpu",calibration_stage="training",
        failure=nothing,illumination="lamp",command_transport_units="micrometre OPD",
        plant_command_units="metre OPD",detector_config=detector,
        acquisition_domain_mapping=mapping,acquisition_generation=1,
        graph_sha256=settings.graph_sha256,capture_settings_sha256=settings_sha,
        wfs_active=nothing,wfs_active_sha256=nothing,capture_max_bytes=length(schedule)*frames*22596,
        sequence=0,cursor_model_ns=0)
    requests=Any[];captures=Any[];expected=Matrix{Float32}[]
    function receipt(serial,action,result)
        push!(requests,(;request=(;version=1,run=1,serial,timeout_ns=recipe["request_timeout_ns"],action),
            reply=(;version=1,run=1,serial,result)))
    end
    previous=cur(0,0);receipt(1,(;kind="hold"),(;kind="held",cursor=previous))
    for (i,batch) in enumerate(schedule)
        probe=i-1;serial=3*i-1
        receipt(serial,(;kind="adopt",probe,figure=batch.figure),
            (;kind="adopted",cursor=previous,figure=batch.figure,clipped=false))
        settled=cur(previous.sequence+1,previous.model_ns+2_000_000)
        receipt(serial+1,(;kind="settle",probe,after=previous,rule=recipe["settling"]),
            (;kind="settled",cursor=settled))
        serial+=2;exposures=Any[];pixels=Matrix{Float32}(undef,3600,frames)
        for frame in 1:frames
            frame_path=joinpath(evidence,"captured",string(serial),string(frame));mkpath(frame_path)
            pixels[:,frame] .= Float32[1+j/4096+2*Float64(batch.figure[139])*(1+j/8192)+frame/1024 for j in 1:3600]
            values=(fill(UInt16(12+frame),4096),pixels[:,frame],Float32[20+frame/16])
            files=Dict()
            for (channel,value) in zip(CRA.CHANNELS,values)
                path=joinpath(frame_path,channel.filename);write(path,CRA.packed(value))
                files[channel.name]=(;path=channel.filename,element_type=channel.element,
                    shape=channel.shape,layout="ROW_MAJOR",bytes=channel.bytes,sha256=CRA.digest(path))
            end
            push!(exposures,(;domain=1,generation=1,sequence=settled.sequence+frame,
                start_model_ns=settled.model_ns+(frame-1)*2_000_000,duration_ns=2_000_000,
                valid=true,directory=string(frame),files))
        end
        push!(expected,pixels)
        manifest=(;version=1,run=1,serial,probe,stage="training",profile="copper",illumination="lamp",
            settings,settings_sha256=settings_sha,acquisition_domain_mapping=mapping,
            frames,bytes=frames*22596,exposures)
        manifest_path=joinpath(evidence,"captured",string(serial),"manifest.json");json_write(manifest_path,manifest)
        completion=(;kind="captured",cursor=cur(settled.sequence+frames,settled.model_ns+frames*2_000_000),
            manifest="$serial/manifest.json",sha256=CRA.digest(manifest_path),frames,bytes=frames*22596,
            metadata_bytes=filesize(manifest_path))
        receipt(serial,(;kind="capture",probe,after=settled,frames),completion)
        push!(captures,(;probe,serial,figure=batch.figure,settled_cursor=settled,completion))
        previous=completion.cursor
    end
    serial=3*length(schedule)+2
    receipt(serial,(;kind="restore",figure=reference,rule=recipe["settling"]),
        (;kind="restored",figure=reference,clipped=false))
    receipt(serial+1,(;kind="release"),(;kind="released"))
    stage=(;stage="training",restoration_confirmed=true,release_confirmed=true,shutdown_confirmed=true,
        launcher_exit=0,startup_report=startup,requests,captures,
        final=(;phase="stopped",error=nothing,source=(;operation="pause",state="paused",
            completed=true,ok=true,error=nothing,sequence=previous.sequence+1)))
    json_write(joinpath(evidence,"stage-result.json"),stage)
    f=(;output,evidence,expected)
    reseal(f)
    return f
end

function reseal(f)
    files=Dict{String,String}()
    for (directory,_,names) in walkdir(f.output),name in names
        path=joinpath(directory,name)
        name=="quality-inputs.json" && continue
        files[relpath(path,f.output)]=CRA.digest(path)
    end
    json_write(joinpath(f.output,"quality-inputs.json"),(;version=1,files))
end
function change_stage(f,modify)
    path=joinpath(f.evidence,"stage-result.json");stage=json_read(path)
    modify(stage);json_write(path,stage)
end
change_stage(modify::Function,f)=change_stage(f,modify)
function change_manifest(f,modify;probe=0)
    serial=3*probe+4
    path=joinpath(f.evidence,"captured",string(serial),"manifest.json")
    manifest=json_read(path);modify(manifest);json_write(path,manifest)
    change_stage(f) do stage
        completion=stage["captures"][probe+1]["completion"]
        completion["sha256"]=CRA.digest(path);completion["metadata_bytes"]=filesize(path)
        stage["requests"][serial]["reply"]["result"]=deepcopy(completion)
    end
end
change_manifest(modify::Function,f;kwargs...)=change_manifest(f,modify;kwargs...)
function change_payload(f,name,values;update_hash=true)
    channel=only(filter(c -> c.name==name,CRA.CHANNELS))
    path=joinpath(f.evidence,"captured","4","1",channel.filename)
    write(path,CRA.packed(values))
    if update_hash
        change_manifest(f) do manifest
            manifest["exposures"][1]["files"][name]["sha256"]=CRA.digest(path)
        end
    end
end
function rejects(modify)
    mktempdir() do root
        f=fixture(root);modify(f)
        @test_throws Exception CQA.main(f.output,f.evidence)
        @test !ispath(joinpath(f.evidence,"analysis.json"))
        @test !ispath(joinpath(f.output,"batch-means.f64le"))
    end
end

@testset "Balanced schedule and represented command intervals" begin
    mktempdir() do root
        f=fixture(root;reference_value=.13f0,amplitudes=Float32[.02,.04,.08])
        recipe=json_read(joinpath(f.output,"recipe.json"));schedule=CQA.expected_schedule(recipe)
        @test length(schedule)==16
        @test getproperty.(schedule[2:7],:sign)==[1,-1,1,-1,1,-1]
        @test getproperty.(schedule[10:15],:sign)==[-1,1,-1,1,-1,1]
        @test getproperty.(schedule[10:15],:amplitude)==Float32[.08,.08,.04,.04,.02,.02]
        report=CQA.main(f.output,f.evidence)
        @test report.status=="characterized-candidate"
        @test report.artifacts[1].shape==[16,3600]
        @test report.artifacts[3].shape==[3,2,3600]
        means=reshape(CRA.read_packed(joinpath(f.output,"batch-means.f64le"),Float64,16*3600),3600,16)
        variances=reshape(CRA.read_packed(joinpath(f.output,"batch-variances.f64le"),Float64,16*3600),3600,16)
        for (i,pixels) in enumerate(f.expected)
            expected_mean=vec(sum(Float64.(pixels);dims=2))/3
            expected_variance=vec(sum((Float64.(pixels).-expected_mean).^2;dims=2))/2
            @test means[:,i] ≈ expected_mean rtol=1e-14
            @test variances[:,i] ≈ expected_variance rtol=1e-12
        end
        derivatives=reshape(CRA.read_packed(joinpath(f.output,"derivative-repeats.f64le"),Float64,3*2*3600),3600,2,3)
        for (a,amplitude) in enumerate(Float32[.02,.04,.08]),repeat in 0:1
            positive=only(findall(b -> b.repeat==repeat && b.sign==1 && b.amplitude==amplitude,schedule))
            negative=only(findall(b -> b.repeat==repeat && b.sign==-1 && b.amplitude==amplitude,schedule))
            interval=Float64(schedule[positive].figure[139])-Float64(schedule[negative].figure[139])
            @test derivatives[:,repeat+1,a] ≈ (means[:,positive]-means[:,negative])/interval rtol=1e-14
        end
        pair=report.amplitudes[1].pair_midpoints[1]
        @test pair.actual_half_interval != Float64(.02f0)
        @test pair.command_pair_midpoint_reference_offset == (Float64(schedule[2].figure[139])+Float64(schedule[3].figure[139]))/2-Float64(.13f0)
        for descriptor in report.artifacts
            @test descriptor.layout=="ROW_MAJOR" && descriptor.element_type=="F64_LE"
            @test descriptor.bytes==prod(descriptor.shape)*8
            @test descriptor.sha256==CRA.digest(joinpath(f.output,descriptor.path))
        end
        @test report.inputhashes.producing_reference_analysis_sha256 == CRA.digest(joinpath(f.output,"reference-candidate","training-evidence","analysis.json"))
        @test report.batches[1].first_frame.current_intensity==20.0625
        @test report.batches[1].first_frame.remaining_current_intensity_mean==20.15625
    end
    @test CQA.comparison(zeros(3600),zeros(3600)).cosine === nothing
    @test CQA.comparison(zeros(3600),ones(3600)).relative_difference === nothing
    mktempdir() do root
        f=fixture(root;frames=2)
        change_stage(f,d -> foreach(r -> r["request"]["timeout_ns"]=1,d["requests"]))
        @test CQA.main(f.output,f.evidence).samples_per_batch==2
    end
end

@testset "Strict recipe, seal and producer guards" begin
    for change in (
        d -> d["actuator"]=0,d -> d["actuator"]=278,d -> d["repeats"]=1,
        d -> d["frames_per_batch"]=17,d -> d["seed"]=true,d -> d["reference"]=zeros(276),
        d -> d["reference"][1]=1e100,d -> d["amplitudes"]=[.04,.02],
        d -> d["amplitudes"]=[.02,.02],d -> d["amplitudes"]=[1e-100],
        d -> d["amplitudes"]=[.01,.02,.03,.04],d -> d["amplitudes"]=[true],
        d -> d["adc_upper_rail"]=16384,d -> d["settling"]=Dict("kind"=>"immediate"),
        d -> d["extra"]=1,d -> d["reference"][139]=1e20,
    )
        rejects(f -> begin
            path=joinpath(f.output,"recipe.json");recipe=json_read(path);change(recipe);json_write(path,recipe);reseal(f)
        end)
    end
    rejects(f -> write(joinpath(f.output,"measured-reference-pixels.f32le"),CRA.packed(zeros(Float32,3600))))
    rejects(f -> begin
        path=joinpath(f.output,"reference-candidate","training-evidence","analysis.json")
        report=json_read(path);report["artifacts"][1]["sha256"]="f"^64;json_write(path,report);reseal(f)
    end)
    rejects(f -> begin
        path=joinpath(f.output,"training-package","hil","calibration_quality_analysis.jl")
        write(path,"different executed helper");reseal(f)
    end)
    rejects(f -> begin
        path=joinpath(f.output,"schedule.json");schedule=JSON3.read(read(path,String),Vector{Dict{String,Any}})
        schedule[2]["sign"]=-1;json_write(path,schedule);reseal(f)
    end)
end

# JSON3 normalizes integral decimals (1.0) to integers. These mutations use
# nonintegral values to exercise parsed-value integer guards without changing
# the public parser; acquisition admission checks original metadata types.
@testset "Receipts, payload bounds and lamp validity precede publication" begin
    for change in (
        d -> d["restoration_confirmed"]=false,d -> d["release_confirmed"]=false,
        d -> d["shutdown_confirmed"]=false,d -> d["final"]["phase"]="running",
        d -> d["final"]["source"]["sequence"]=1,d -> d["startup_report"]["profile"]="classic",
        d -> d["startup_report"]["detector_config"]["rng_seed"]=5,
        d -> d["startup_report"]["sequence"]=0.5,
        d -> d["startup_report"]["acquisition_domain_mapping"]["complete_domain"]=zeros(Int,16),
        d -> d["requests"][2]["reply"]["result"]["clipped"]=true,
        d -> d["requests"][5]["request"]["action"]["probe"]=0,
        d -> d["requests"][3]["reply"]["result"]["cursor"]["sequence"]=0,
        d -> d["requests"][3]["request"]["action"]["after"]["generation"]=1.5,
        d -> d["requests"][3]["request"]["action"]["rule"]["frames"]=1.5,
        d -> d["requests"][4]["request"]["action"]["after"]["generation"]=1.5,
        d -> d["requests"][4]["request"]["timeout_ns"]=0,
        d -> d["requests"][4]["reply"]["serial"]=3,
        d -> d["requests"][end-1]["reply"]["result"]["figure"][1]=1,
        d -> d["captures"][1]["probe"]=1,
        d -> d["captures"][1]["settled_cursor"]["generation"]=1.5,
    )
        rejects(f -> change_stage(f,change))
    end
    for change in (
        d -> d["probe"]=1,d -> d["profile"]="classic",
        d -> d["exposures"][1]["valid"]=false,
        d -> d["exposures"][2]["sequence"]=2,
        d -> d["exposures"][2]["start_model_ns"]=1,
        d -> d["exposures"][1]["files"]["pixels"]["shape"]=[900,4],
        d -> d["exposures"][1]["files"]["pixels"]["shape"]=[4.5,900.5],
        d -> d["exposures"][1]["files"]["raw"]["layout"]="COLUMN_MAJOR",
    )
        rejects(f -> change_manifest(f,change))
    end
    rejects(f -> change_payload(f,"pixels",fill(Float32(NaN),3600)))
    rejects(f -> change_payload(f,"intensity",Float32[0]))
    rejects(f -> change_payload(f,"intensity",Float32[Inf]))
    rejects(f -> change_payload(f,"raw",fill(UInt16(16383),4096)))
    rejects(f -> change_payload(f,"pixels",zeros(Float32,3599)))
    rejects(f -> change_payload(f,"pixels",zeros(Float32,3600);update_hash=false))
    rejects(f -> begin
        path=joinpath(f.evidence,"captured","4","1","pixels.f32le")
        mv(path,path*".original");symlink(path*".original",path)
    end)
end
