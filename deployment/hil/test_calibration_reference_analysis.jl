using Test
using JSON3
using SHA
using AdaptiveOpticsCalibration
include("calibration_reference_analysis.jl")
const CRA = CalibrationReferenceAnalysis

json_write(path, value) = write(path, JSON3.write(value))
json_read(path) = JSON3.read(read(path,String),Dict{String,Any})
dict(value) = JSON3.read(JSON3.write(value),Dict{String,Any})
function fixture(root; stage="training", count=3)
    output, evidence = joinpath(root,"output"), joinpath(root,"evidence")
    mkpath(output); mkpath(evidence)
    recipe = dict((;version=1,dark_frames=count,training_frames=count,qualification_frames=count,
        seeds=(;dark=1,training=2,qualification=3),lamp_magnitude=4.0,
        reference=zeros(Float32,277),settling=(;kind="discard_exposures",frames=1),
        adc_upper_rail=16383,request_timeout_ns=30_000_000_000,stage_timeout_seconds=120))
    json_write(joinpath(output,"recipe.json"),recipe)
    detector = (;rows=64,columns=64,bits=14,rng_seed=recipe["seeds"][stage],exposure_duration_s=.002)
    mapping = (;opaque_domain=1,complete_domain=collect(1:16))
    settings = (;detector_config=detector,graph_sha256="a"^64,wfs_active_sha256=nothing)
    sha_settings = bytes2hex(sha256(JSON3.write(settings)))
    startup = (;version=1,profile="copper",backend="cpu",calibration_stage=stage,
        failure=nothing,illumination=stage=="dark" ? "dark" : "lamp",
        command_transport_units="micrometre OPD",plant_command_units="metre OPD",
        detector_config=detector,acquisition_domain_mapping=mapping,acquisition_generation=1,
        graph_sha256=settings.graph_sha256,capture_settings_sha256=sha_settings,
        wfs_active=nothing,wfs_active_sha256=nothing,capture_max_bytes=count*22596,
        sequence=0,cursor_model_ns=0)
    cur(sequence,model_ns) = (;domain=1,generation=1,sequence,model_ns)
    after = cur(1,2_000_000)
    frames = []
    raw_expected = zeros(UInt16,64,64,count)
    pixels_expected = zeros(Float32,3600,count)
    for i in 1:count
        frame_root = joinpath(evidence,"captured","4",string(i)); mkpath(frame_root)
        raw = UInt16[100*r+c+2i for r in 1:64,c in 1:64]
        pixels = Float32[j/16+2i for j in 1:3600]
        raw_expected[:,:,i] .= raw
        pixels_expected[:,i] .= pixels
        files = Dict()
        for (c, values) in zip(CRA.CHANNELS,(vec(permutedims(raw)),pixels,Float32[i+4]))
            path = joinpath(frame_root,c.filename)
            write(path,CRA.packed(values))
            files[c.name] = (;path=c.filename,element_type=c.element,shape=c.shape,
                layout="ROW_MAJOR",bytes=c.bytes,sha256=CRA.digest(path))
        end
        push!(frames,(;domain=1,generation=1,sequence=i+1,start_model_ns=i*100_000_000,
            duration_ns=2_000_000,valid=true,directory=string(i),files))
    end
    manifest = (;version=1,run=1,serial=4,probe=0,stage,profile="copper",
        illumination=startup.illumination,settings,settings_sha256=sha_settings,
        acquisition_domain_mapping=mapping,frames=count,bytes=count*22596,exposures=frames)
    manifest_path=joinpath(evidence,"captured","4","manifest.json");json_write(manifest_path,manifest)
    capture=(;kind="captured",cursor=cur(count+1,count*100_000_000+2_000_000),
        manifest="4/manifest.json",sha256=CRA.digest(manifest_path),frames=count,
        bytes=count*22596,metadata_bytes=filesize(manifest_path))
    actions=((;kind="hold"),(;kind="adopt",probe=0,figure=recipe["reference"]),
        (;kind="settle",probe=0,after=cur(0,0),rule=recipe["settling"]),
        (;kind="capture",probe=0,after,frames=count),
        (;kind="restore",figure=recipe["reference"],rule=recipe["settling"]),(;kind="release"))
    replies=((;kind="held",cursor=cur(0,0)),
        (;kind="adopted",cursor=cur(0,0),figure=recipe["reference"],clipped=false),
        (;kind="settled",cursor=after),capture,
        (;kind="restored",figure=recipe["reference"],clipped=false),(;kind="released"))
    requests=[(;request=(;version=1,run=1,serial=i,timeout_ns=recipe["request_timeout_ns"],action=actions[i]),
        reply=(;version=1,run=1,serial=i,result=replies[i])) for i in 1:6]
    stage_result=(;stage,restoration_confirmed=true,release_confirmed=true,shutdown_confirmed=true,
        launcher_exit=0,final=(;phase="stopped",error=nothing,
            source=(;operation="pause",state="paused",completed=true,ok=true,error=nothing,sequence=count+2)),
        startup_report=startup,requests,capture)
    json_write(joinpath(evidence,"stage-result.json"),stage_result)
    return (;output,evidence,raw_expected,pixels_expected)
end
function change_stage(f, fn)
    path=joinpath(f.evidence,"stage-result.json");value=json_read(path)
    fn(value);json_write(path,value)
end
function change_manifest(f, fn)
    path=joinpath(f.evidence,"captured","4","manifest.json");value=json_read(path)
    fn(value);json_write(path,value)
    change_stage(f) do d
        d["capture"]["sha256"]=CRA.digest(path);d["capture"]["metadata_bytes"]=filesize(path)
        d["requests"][4]["reply"]["result"]=deepcopy(d["capture"])
    end
end
function change_payload(f, name, values; update_hash=true)
    channel=only(filter(c -> c.name==name,CRA.CHANNELS))
    path=joinpath(f.evidence,"captured","4","1",channel.filename)
    write(path,CRA.packed(values))
    if update_hash
        change_manifest(f) do d
            d["exposures"][1]["files"][name]["sha256"]=CRA.digest(path)
        end
    end
end
# Support Julia's function-first do syntax without changing production interfaces.
change_stage(fn::Function,f)=change_stage(f,fn)
change_manifest(fn::Function,f)=change_manifest(f,fn)
function rejects(modify;stage="training")
    mktempdir() do root
        f=fixture(root;stage);modify(f)
        @test_throws Exception CRA.main(stage,f.output,f.evidence)
        @test !ispath(joinpath(f.evidence,"analysis.json"))
        @test !ispath(joinpath(f.output,stage=="dark" ? "measured-background.f32le" : "measured-reference-pixels.f32le"))
    end
end
function bind_training(f, values)
    training=fixture(joinpath(dirname(f.output),"prior-training");count=size(f.pixels_expected,2))
    recipe=json_read(joinpath(f.output,"recipe.json"))
    cp(joinpath(f.output,"recipe.json"),joinpath(training.output,"recipe.json");force=true)
    change_stage(training) do d
        d["requests"][3]["request"]["action"]["rule"]=recipe["settling"]
        d["requests"][5]["request"]["action"]["rule"]=recipe["settling"]
    end
    for i in axes(training.pixels_expected,2)
        write(joinpath(training.evidence,"captured","4",string(i),"pixels.f32le"),CRA.packed(values))
    end
    change_manifest(training) do manifest
        for (i,exposure) in enumerate(manifest["exposures"])
            exposure["files"]["pixels"]["sha256"]=CRA.digest(joinpath(training.evidence,"captured","4",string(i),"pixels.f32le"))
        end
    end
    CRA.main("training",training.output,training.evidence)
    cp(training.evidence,joinpath(f.output,"training-evidence"))
    cp(joinpath(training.output,"measured-reference-pixels.f32le"),joinpath(f.output,"measured-reference-pixels.f32le"))
end
@testset "Frozen training artifact identity precedes qualification publication" begin
    for modify in (
        (f,d) -> write(joinpath(f.output,"measured-reference-pixels.f32le"),CRA.packed(zeros(Float32,3600))),
        (f,d) -> d["stage"]="dark",
        (f,d) -> d["profile"]="classic",
        (f,d) -> d["status"]="invalid",
        (f,d) -> d["public_method"]="ReferenceFrames.DarkFrameMoments",
        (f,d) -> d["public_status"]="ResponseMomentsNonFiniteInput",
        (f,d) -> d["samples"]=2,
        (f,d) -> d["input_identities"]["recipe_sha256"]="e"^64,
        (f,d) -> d["analysis_source_sha256"]="f"^64,
        (f,d) -> d["qualification"]="accepted correction",
        (f,d) -> d["artifacts"][1]["shape"]=[4,900],
        (f,d) -> d["artifacts"][1]["element_type"]="F64_LE",
        (f,d) -> d["artifacts"][1]["layout"]="COLUMN_MAJOR",
        (f,d) -> d["artifacts"][1]["units"]="ADC",
        (f,d) -> push!(d["artifacts"],deepcopy(d["artifacts"][1])),
    )
        mktempdir() do root
            f=fixture(root;stage="qualification")
            bind_training(f,Float32.(vec(sum(f.pixels_expected;dims=2)./3)))
            path=joinpath(f.output,"training-evidence","analysis.json")
            report=json_read(path);modify(f,report);json_write(path,report)
            @test_throws ArgumentError CRA.main("qualification",f.output,f.evidence)
            @test !ispath(joinpath(f.output,"qualification-mean.f64le"))
            @test !ispath(joinpath(f.evidence,"analysis.json"))
        end
    end
    mktempdir() do root
        f=fixture(root;stage="qualification")
        write(joinpath(f.output,"measured-reference-pixels.f32le"),CRA.packed(zeros(Float32,3600)))
        @test_throws ArgumentError CRA.main("qualification",f.output,f.evidence)
        @test !ispath(joinpath(f.output,"qualification-mean.f64le"))
    end
end

@testset "Copper public dark moments and asymmetric ROW_MAJOR" begin
    mktempdir() do root
        f=fixture(root;stage="dark")
        change_manifest(f) do d;d["exposures"][1]["valid"]=false;end
        report=CRA.main("dark",f.output,f.evidence)
        public=AdaptiveOpticsCalibration
        expected=public.process(public.prepare(public.ReferenceFrames.DarkFrameMoments(),
            public.ReferenceFrames.DarkFrameSpecification(64,64,3)),f.raw_expected)
        background=CRA.read_packed(joinpath(f.output,"measured-background.f32le"),Float32,4096)
        variance=CRA.read_packed(joinpath(f.output,"measured-dark-variance.f64le"),Float64,4096)
        @test background==vec(permutedims(Float32.(expected.mean)))
        @test variance==vec(permutedims(expected.variance))
        @test background[2]==106f0 # row1,col2, mean increment4
        @test background[65]==205f0
        @test all(==(4.0),variance)
        @test report.intrinsic_valid==[false,true,true]
        @test report.samples==3
        @test report.public_method=="ReferenceFrames.DarkFrameMoments"
        @test_throws ArgumentError CRA.main("dark",f.output,f.evidence)
    end
end
@testset "Positive model-time settling and independent residual units" begin
    mktempdir() do root
        f=fixture(root;stage="qualification",count=2)
        recipe_path=joinpath(f.output,"recipe.json")
        recipe=json_read(recipe_path)
        recipe["settling"]=Dict("kind"=>"model_time","duration_ns"=>1_000_000)
        json_write(recipe_path,recipe)
        change_stage(f) do d
            d["requests"][3]["request"]["action"]["rule"]=recipe["settling"]
            d["requests"][5]["request"]["action"]["rule"]=recipe["settling"]
        end
        frozen=Float32.(vec(sum(f.pixels_expected;dims=2)./2) .-1)
        bind_training(f,frozen)
        report=CRA.main("qualification",f.output,f.evidence)
        @test report.comparison.max_abs==1
        @test report.comparison.rms==1
        @test report.comparison.relative_norm≈sqrt(3600)/CRA.norm(Float64.(frozen))
        @test report.current_intensity_mean==5.5
    end
    mktempdir() do root
        f=fixture(root;stage="qualification")
        bind_training(f,zeros(Float32,3600))
        report=CRA.main("qualification",f.output,f.evidence)
        @test report.comparison.relative_norm===nothing
        @test isfinite(report.comparison.rms)
    end
    mktempdir() do root
        f=fixture(root;stage="qualification")
        # Every input is finite; a Float32 norm would overflow for this vector.
        bind_training(f,fill(floatmax(Float32),3600))
        report=CRA.main("qualification",f.output,f.evidence)
        @test report.comparison.relative_norm≈1
        @test isfinite(report.comparison.rms)
    end
    rejects(f -> begin
        p=joinpath(f.output,"recipe.json");d=json_read(p)
        d["settling"]=Dict("kind"=>"model_time","duration_ns"=>3_000_000);json_write(p,d)
        change_stage(f) do s
            s["requests"][3]["request"]["action"]["rule"]=d["settling"]
            s["requests"][5]["request"]["action"]["rule"]=d["settling"]
        end
    end)
end
@testset "Maximum admitted window and CLI entry" begin
    mktempdir() do root
        f=fixture(root;stage="dark",count=64)
        recipe=CRA.validate_recipe(JSON3.read(read(joinpath(f.output,"recipe.json"),String)))
        window=CRA.read_window("dark",f.output,f.evidence,recipe)
        @test size(window.raw)==(64,64,64)
        @test size(window.pixels)==(3600,64)
    end
    mktempdir() do root
        f=fixture(root;stage="dark")
        script=joinpath(@__DIR__,"calibration_reference_analysis.jl")
        command=`$(Base.julia_cmd()) --startup-file=no --threads=1,0 --check-bounds=yes --depwarn=error --project=$(dirname(Base.active_project())) $script dark $(f.output) $(f.evidence)`
        stdout=read(command,String)
        @test JSON3.read(stdout)["samples"]==3
        @test isfile(joinpath(f.evidence,"analysis.json"))
    end
end
@testset "Normalized per-frame response moments, frozen comparison" begin
    mktempdir() do root
        training=fixture(root)
        report=CRA.main("training",training.output,training.evidence)
        public=AdaptiveOpticsCalibration
        expected=public.process(public.prepare(public.Diagnostics.RepeatedResponseMoments(),
            public.Diagnostics.RepeatedResponseSpecification(3600,3)),training.pixels_expected)
        reference=CRA.read_packed(joinpath(training.output,"measured-reference-pixels.f32le"),Float32,3600)
        variance=CRA.read_packed(joinpath(training.output,"measured-reference-variance.f64le"),Float64,3600)
        @test reference==Float32.(expected.mean)
        @test variance==expected.sample_variance
        @test reference[[1,900,901,1801,2701,3600]]==Float32.([1,900,901,1801,2701,3600]./16 .+4)
        @test all(==(4.0),variance)
        @test !hasproperty(report,:mean_standard_error)
        qualification=fixture(joinpath(root,"qualification");stage="qualification")
        cp(joinpath(training.output,"measured-reference-pixels.f32le"),joinpath(qualification.output,"measured-reference-pixels.f32le"))
        cp(training.evidence,joinpath(qualification.output,"training-evidence"))
        qreport=CRA.main("qualification",qualification.output,qualification.evidence)
        @test qreport.comparison.max_abs==0
        @test qreport.comparison.rms==0
        @test qreport.comparison.relative_norm==0
        @test CRA.read_packed(joinpath(qualification.output,"qualification-mean.f64le"),Float64,3600)==expected.mean
    end
end
@testset "Admission failures before candidate publication" begin
    for field in ("restoration_confirmed","release_confirmed","shutdown_confirmed")
        rejects(f -> change_stage(f,d -> d[field]=false))
    end
    for modify in (
        d -> d["launcher_exit"]=true,
        d -> d["launcher_exit"]=1,
        d -> d["final"]["phase"]="running",
        d -> d["startup_report"]["profile"]="classic",
        d -> d["startup_report"]["detector_config"]["bits"]=16,
        d -> d["startup_report"]["detector_config"]["rng_seed"]=7,
        d -> d["startup_report"]["acquisition_domain_mapping"]["complete_domain"]=zeros(Int,16),
        d -> d["requests"][3]["reply"]["result"]["cursor"]["sequence"]=0,
        d -> d["requests"][2]["reply"]["result"]["clipped"]=true,
        d -> d["requests"][2]["reply"]["result"]["figure"][1]=1.0,
        d -> d["requests"][5]["reply"]["result"]["figure"][1]=1.0,
        d -> d["requests"][4]["request"]["action"]["frames"]=2,
        d -> d["requests"][6]["reply"]["serial"]=5,
        d -> d["final"]["source"]["sequence"]=4,
    )
        rejects(f -> change_stage(f,modify))
    end
    for modify in (
        d -> d["profile"]="classic",
        d -> d["stage"]="dark",
        d -> delete!(d["exposures"][1]["files"],"intensity"),
        d -> d["exposures"][1]["files"]["pixels"]["shape"]=[900,4],
        d -> d["exposures"][1]["files"]["raw"]["layout"]="COLUMN_MAJOR",
        d -> d["exposures"][1]["files"]["raw"]["sha256"]="b"^64,
        d -> d["exposures"][2]["sequence"]=2,
        d -> d["exposures"][2]["generation"]=2,
        d -> d["exposures"][2]["start_model_ns"]=1,
        d -> d["exposures"][1]["duration_ns"]=1,
        d -> d["exposures"][1]["valid"]=1,
        d -> d["settings"]["graph_sha256"]="c"^64,
        d -> d["settings_sha256"]="d"^64,
        d -> pop!(d["exposures"]),
    )
        rejects(f -> change_manifest(f,modify))
    end
    rejects(f -> change_manifest(f,d -> d["exposures"][1]["valid"]=false))
    rejects(f -> change_payload(f,"intensity",Float32[0]))
    rejects(f -> change_payload(f,"intensity",Float32[Inf]))
    rejects(f -> change_payload(f,"pixels",fill(Float32(NaN),3600)))
    rejects(f -> change_payload(f,"raw",fill(UInt16(16383),4096)))
    rejects(f -> change_payload(f,"raw",fill(UInt16(16383),4096));stage="dark")
    rejects(f -> change_payload(f,"pixels",zeros(Float32,3599);update_hash=false))
end
@testset "Strict recipe and publication paths" begin
    for modify in (
        d -> d["training_frames"]=1,
        d -> d["dark_frames"]=65,
        d -> d["seeds"]["dark"]=d["seeds"]["training"],
        d -> d["seeds"]["dark"]=true,
        d -> d["reference"]=zeros(276),
        d -> d["reference"][1]=1e100,
        d -> d["reference"][1]=1e-100,
        d -> d["settling"]=Dict("kind"=>"immediate"),
        d -> d["adc_upper_rail"]=16384,
        d -> d["extra"]=1,
    )
        rejects(f -> begin
            path=joinpath(f.output,"recipe.json");d=json_read(path);modify(d);json_write(path,d)
        end)
    end
    mktempdir() do root
        f=fixture(root)
        symlink(joinpath(root,"missing"),joinpath(f.output,"measured-reference-pixels.f32le"))
        @test_throws ArgumentError CRA.main("training",f.output,f.evidence)
        @test !ispath(joinpath(f.output,"measured-reference-variance.f64le"))
    end
    mktempdir() do root
        f=fixture(root);alias=joinpath(root,"alias");symlink(f.output,alias)
        @test_throws ArgumentError CRA.main("training",alias,f.evidence)
        @test !ispath(joinpath(f.output,"measured-reference-pixels.f32le"))
        @test CRA.main("training",f.output,f.evidence).samples==3
    end
    rejects(f -> begin
        path=joinpath(f.evidence,"captured","4","1","raw.u16le")
        mv(path,path*".source");symlink(path*".source",path)
    end)
end
