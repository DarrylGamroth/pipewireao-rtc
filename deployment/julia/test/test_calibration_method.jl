using Test, TOML, PipeWireAODeployment

@testset "completed owner and Copper ADC evidence" begin
    campaign=PipeWireAODeployment.CalibrationCampaign
    method=PipeWireAODeployment.CalibrationMethod
    common=PipeWireAODeployment.Common
    lifecycle=PipeWireAODeployment.NativeAcquisitionLifecycleCodec
    current=lifecycle.AcquisitionCursor(UInt64(1),UInt64(2),UInt64(35),UInt64(70))
    source=Dict{String,Any}("ok"=>true,"operation"=>"status","id"=>21,"native_token"=>21,
        "endpoint_instance"=>100,"lifecycle"=>"Connected","state"=>"paused",
        "held"=>false,"restored"=>true,"phase"=>"released","completed"=>true,
        "cursor"=>current,"report_cursor"=>current)
    report=Dict{String,Any}("version"=>1,"profile"=>"copper","backend"=>"cpu",
        "graph_sha256"=>"graph","state"=>"paused","sequence"=>35,"completed"=>true,
        "phase"=>"released","acquisition_generation"=>2,"cursor_model_ns"=>70,
        "acquisition_domain_mapping"=>Dict("opaque_domain"=>1,"complete_domain"=>ones(Int,16)),
        "ownership_held"=>false,"restoration_confirmed"=>true,"failure"=>nothing,
        "detector_diagnostics"=>Dict{String,Any}("raw_available"=>true,"adc_upper_rail"=>16383,
            "frames"=>35,"upper_rail_pixels"=>0,"upper_rail_frames"=>0))
    mktempdir() do directory
        path=joinpath(directory,"report.json")
        common.write_json(path,report)
        @test campaign.completed_report_cursor(source)==(UInt64(1),UInt64(2),UInt64(35),UInt64(70))
        @test campaign.completed_owner_report(path,source,report)==report
        # Identical sequence alone must never accept another generation.
        for (field,value) in (("acquisition_generation",1),("cursor_model_ns",69),
                ("sequence",34),("version",true),("acquisition_generation",true),
                ("profile","classic"),("backend","cuda"),("graph_sha256","other"),
                ("ownership_held",true),("restoration_confirmed",false),
                ("failure","unknown outcome"))
            invalid=deepcopy(report);invalid[field]=value;common.write_json(path,invalid)
            @test_throws ArgumentError campaign.completed_owner_report(path,source,report)
        end
        common.write_json(path,report)
        for (field,value) in (("ok",false),("operation","pause"),("id",22),
                ("native_token",true),("endpoint_instance",0),("lifecycle","Prepared"),
                ("state","running"),("held",true),("restored",false),("phase","fault"),
                ("cursor",Dict("domain"=>1,"generation"=>2,"sequence"=>35,"model_ns"=>70)))
            invalid=deepcopy(source);invalid[field]=value
            @test_throws ArgumentError campaign.completed_report_cursor(invalid)
        end
        pending=deepcopy(source);pending["completed"]=false
        unpublished=deepcopy(source);unpublished["report_cursor"]=nothing
        older=deepcopy(source);older["report_cursor"]=lifecycle.AcquisitionCursor(1,1,35,70)
        @test campaign.completed_report_cursor(pending)===nothing
        @test campaign.completed_report_cursor(unpublished)===nothing
        @test campaign.completed_report_cursor(older)===nothing
        ready=Dict("source_endpoint"=>Dict("profile"=>"pipewireao.rtc.calibration-lifecycle/1"))
        calls=Float64[];responses=[pending,older,source];limit=time_ns()/1e9+5
        selected=campaign.wait_completed_source(ready,"classic";deadline=limit,query=(record,kind,deadline)->begin
            @test record===ready && kind=="classic";push!(calls,deadline)
            responses[length(calls)]
        end)
        @test selected===source && calls==fill(limit,3)
        invoked=Ref(0)
        @test_throws ArgumentError campaign.wait_completed_source(ready,"classic";deadline=time_ns()/1e9-1,
            query=(args...)->(invoked[]+=1))
        @test invoked[]==0
        @test_throws ErrorException campaign.wait_completed_source(ready,"classic";deadline=time_ns()/1e9+5,
            query=(args...)->begin invoked[]+=1;error("native outcome unknown") end)
        @test invoked[]==1 # no automatic retry or saved-file fallback
        @test_throws ArgumentError campaign.wait_completed_source(
            Dict("source_endpoint"=>Dict("profile"=>"standalone")),"classic";
            deadline=time_ns()/1e9+5,query=(args...)->source)
    end
    @test method.validate_detector_completion(Dict("completed_report"=>report))==report["detector_diagnostics"]
    @test_throws ArgumentError method.validate_detector_completion(Dict())
    for (field,value) in (("raw_available",false),("adc_upper_rail",65535),("frames",0),
        ("frames",true),("upper_rail_pixels",1),("upper_rail_frames",1))
        invalid=deepcopy(report);invalid["detector_diagnostics"][field]=value
        @test_throws ArgumentError method.validate_detector_completion(Dict("completed_report"=>invalid))
    end
end

# Portable preparation checks use ordinary JSON fixtures; science and package
# copy helpers are the production implementations. No deployment is launched.
module MethodFixture
using PipeWireAODeployment: package_root
using PipeWireAODeployment
const Common=PipeWireAODeployment.Common
const CalibrationExport=PipeWireAODeployment.CalibrationExport
const NativeCalibrationActionClient=PipeWireAODeployment.NativeCalibrationActionClient
const NativeAcquisitionLifecycleCodec=PipeWireAODeployment.NativeAcquisitionLifecycleCodec
const NativeControlClient=PipeWireAODeployment.NativeControlClient
const NativeOwnerBootstrapCodec=PipeWireAODeployment.NativeOwnerBootstrapCodec
const ScienceExport=PipeWireAODeployment.ScienceExport
const WirePlumberSessionRuntime=PipeWireAODeployment.WirePlumberSessionRuntime
const SystemdOwners=PipeWireAODeployment.SystemdOwners
const RunnerCommands=PipeWireAODeployment.RunnerCommands
module DeploymentConfiguration
using ..Common
profile(path,prefix)=Common.read_json(path)
decode(path,prefix)=Common.read_json(path)
end
include(joinpath(package_root(),"src","hil_export.jl"))
include(joinpath(package_root(),"src","calibration_campaign.jl"))
include(joinpath(package_root(),"src","copper_reference.jl"))
include(joinpath(package_root(),"src","calibration_method.jl"))
end
const M=MethodFixture.CalibrationMethod
const R=MethodFixture.CopperReference
const A=MethodFixture.CalibrationCampaign
const C=MethodFixture.Common

method_recipe()=Dict{String,Any}("version"=>1,"reference"=>zeros(277),"amplitudes"=>fill(0.02,277),
    "frames_per_probe"=>2,"lamp_magnitude"=>5.7,"seeds"=>Dict{String,Any}("interaction"=>444),
    "settling"=>Dict("kind"=>"discard_exposures","frames"=>1),"adc_upper_rail"=>16383,
    "request_timeout_ns"=>30_000_000_000,"stage_timeout_seconds"=>300)

function method_base(root;engine="fgn",backend="cpu")
    base=joinpath(root,"base")
    mkpath(joinpath(base,"graphs"));mkpath(joinpath(base,"calibration"))
    mkpath(joinpath(base,"hil","packages","AdaptiveOpticsCalibration","src"))
    background=collect(reinterpret(UInt8,fill(0.75f0,4096)))
    write(joinpath(base,"calibration","background.f32le"),background)
    write(joinpath(base,"calibration","selected-array.f32le"),Float32[1,2,3])
    binding=Dict("name"=>"background","endpoint"=>"pixel:background","element_type"=>"F32_LE",
        "shape"=>[64,64],"file"=>"background.f32le","sha256"=>C.sha256_file(joinpath(base,"calibration","background.f32le")))
    other=Dict("name"=>"selected-array","endpoint"=>"wfs:selected-array","element_type"=>"F32_LE",
        "shape"=>[3],"file"=>"selected-array.f32le")
    provenance=Dict("profile"=>"copper","engine"=>engine,"mode"=>"frame","hil"=>Dict("backend"=>backend),
        "parameters"=>[binding,other])
    C.write_json(joinpath(base,"provenance.json"),provenance)
    pixel=Dict("name"=>"pixel","label"=>"pixel-calibration-u16-f32","config"=>Dict("image_rows"=>64,"image_columns"=>64))
    wfs=Dict("name"=>"wfs","label"=>engine=="fgn" ? "pyramid-pixel-image-f32" : "pyramid-pupil-image-f32",
        "config"=>Dict("image_rows"=>64,"image_columns"=>64,"pupil_rows"=>30,"pupil_columns"=>30,"pupil_mask"=>trues(900)))
    command=Dict("name"=>"pdm","label"=>"pdm-command-f32","config"=>Dict("actuator_count"=>277))
    graph=Dict{String,Any}("node.name"=>"selected","filter.graph"=>Dict("nodes"=>[pixel,wfs,command],
        "links"=>[Dict("output"=>"pixel:calibrated","input"=>"wfs:image")],
        "inputs"=>["pixel:raw","pixel:background","pdm:requested"],"outputs"=>["pdm:demanded"]))
    engine=="fgn" && (graph["pipewireao.startup-parameter.pixel:background"]="@PACKAGE@/calibration/background.f32le")
    C.write_json(joinpath(base,"graphs","graph.conf.in"),graph)
    owners=Any[Dict("role"=>"simulator","argv"=>["julia","--backend",backend])]
    engine=="jfg" && push!(owners,Dict("role"=>"julia","argv"=>["julia","--parameter","background","Float32","64,64","@PACKAGE@/calibration/background.f32le"]))
    descriptor=Dict("source-owner"=>"simulator","owners"=>owners,"artifacts"=>Dict())
    C.write_json(joinpath(base,"deployment.conf"),descriptor)
    dependencies=backend=="cuda" ? "[deps]\nCUDA = \"052768ef-5323-5732-b1bb-66c8b64840ba\"\n" :
        backend=="amdgpu" ? "[deps]\nAMDGPU = \"21141c5a-9bdb-4563-92ae-f87d6854732e\"\n" : ""
    write(joinpath(base,"hil","Project.toml"),dependencies*"[sources]\nAdaptiveOpticsCalibration = {path = \"packages/AdaptiveOpticsCalibration\"}\n")
    write(joinpath(base,"hil","plant.toml"),"[[nodes]]\nname = \"pwfs\"\n[nodes.config]\nsource_magnitude = 7.0\n[[nodes]]\nname = \"detector\"\n[nodes.config]\nbits = 14\nrng_seed = 0\n")
    write(joinpath(base,"hil","packages","AdaptiveOpticsCalibration","Project.toml"),"name = \"AdaptiveOpticsCalibration\"\n")
    aoc=joinpath(root,"aoc");mkpath(joinpath(aoc,"src"))
    write(joinpath(aoc,"Project.toml"),"name = \"AdaptiveOpticsCalibration\"\n")
    write(joinpath(aoc,"src","selected.jl"),"# selected AOC source\n")
    return (;base,aoc,background,provenance,graph,descriptor)
end

@testset "Copper method recipe requires only Copper conditions" begin
    original=method_recipe();accepted=M.validate_profile_recipe(original,"copper")
    @test A.same_figure(accepted["amplitudes"],original["amplitudes"])
    accepted["reference"][1]=1
    @test original["reference"][1]==0
    four=method_recipe();four["seeds"]=Dict("dark"=>111,"training"=>222,"qualification"=>333,"interaction"=>444)
    @test M.validate_profile_recipe(four,"copper")["seeds"]["interaction"]==444
    for mutation in (r->(r["adc_upper_rail"]=4095),r->(r["adc_upper_rail"]=16383.0),
            r->(r["settling"]=Dict("kind"=>"immediate")),
            r->(r["settling"]=Dict("kind"=>"model_time","duration_ns"=>1)),
            r->(r["settling"]["frames"]=0),r->(r["settling"]["frames"]=true),
            r->(r["amplitudes"]=fill(1e-100,277)),r->(r["reference"]=zeros(276)),
            r->(r["seeds"]=Dict("training"=>444)),r->(r["seeds"]["interaction"]=true),
            r->(r["version"]=true),r->(r["candidate_mask"]=trues(188)))
        bad=method_recipe();mutation(bad)
        @test_throws ArgumentError M.validate_profile_recipe(bad,"copper")
    end
    @test_throws ArgumentError M.validate_profile_recipe(method_recipe(),"unknown")
end

@testset "Copper retained background and interaction preparation" begin
    for engine in ("fgn","jfg")
        mktempdir() do root
            f=method_base(root;engine)
            recipe=M.validate_profile_recipe(method_recipe(),"copper")
            before=A.file_identity(f.base)
            retained=M.retained_startup(f.base,"/opt/pipewireao";recipe)
            @test retained[1]==f.background
            @test retained[2]===nothing && retained[3]===nothing
            @test retained[4]["background_sha256"]==f.provenance["parameters"][1]["sha256"]
            prepared=R.stage_base(f.base,joinpath(root,"stage"),recipe,"interaction",retained[1],f.aoc,"/opt/pipewireao")
            @test A.file_identity(f.base)==before
            @test read(joinpath(prepared,"graphs","graph.conf.in"))==read(joinpath(f.base,"graphs","graph.conf.in"))
            @test read(joinpath(prepared,"calibration","selected-array.f32le"))==read(joinpath(f.base,"calibration","selected-array.f32le"))
            @test read(joinpath(prepared,"calibration","background.f32le"))==f.background
            model=TOML.parsefile(joinpath(prepared,"hil","plant.toml"))
            @test only(filter(n->n["name"]=="detector",model["nodes"]))["config"]["rng_seed"]==444
            @test only(filter(n->n["name"]=="pwfs",model["nodes"]))["config"]["source_magnitude"]==5.7
            provenance=C.read_json(joinpath(prepared,"provenance.json"))
            @test provenance["reference_campaign_inputs"]["stage"]=="interaction"
            @test provenance["parameters"]==f.provenance["parameters"]
            @test isfile(joinpath(prepared,"hil","packages","AdaptiveOpticsCalibration","src","selected.jl"))
            @test_throws ArgumentError M.retained_startup(f.base,"/opt/pipewireao")
            bad=deepcopy(f.provenance);delete!(bad["parameters"][1],"sha256")
            C.write_json(joinpath(f.base,"provenance.json"),bad)
            @test_throws ArgumentError M.retained_startup(f.base,"/opt/pipewireao";recipe)
            C.write_json(joinpath(f.base,"provenance.json"),f.provenance)
            if engine=="fgn"
                invalid=deepcopy(f.graph)
                invalid["pipewireao.startup-parameter.pixel:background"]="@PACKAGE@/calibration/selected-array.f32le"
                C.write_json(joinpath(f.base,"graphs","graph.conf.in"),invalid)
            else
                invalid=deepcopy(f.descriptor)
                invalid["owners"][2]["argv"][end-1]="63,64"
                C.write_json(joinpath(f.base,"deployment.conf"),invalid)
            end
            @test_throws ArgumentError M.retained_startup(f.base,"/opt/pipewireao";recipe)
            C.write_json(joinpath(f.base,"graphs","graph.conf.in"),f.graph)
            C.write_json(joinpath(f.base,"deployment.conf"),f.descriptor)
            write(joinpath(f.base,"calibration","background.f32le"),zeros(UInt8,16384))
            @test_throws ArgumentError M.retained_startup(f.base,"/opt/pipewireao";recipe)
        end
    end
end

@testset "explicit simulator backend method admission" begin
    for engine in ("fgn","jfg"), backend in ("cuda","amdgpu","cpu")
        mktempdir() do root
            f=method_base(root;engine,backend)
            recipe=M.validate_profile_recipe(method_recipe(),"copper")
            retained=M.retained_startup(f.base,"/opt/pipewireao";recipe)
            @test retained[1]==f.background
            @test retained[4]["backend"]==backend
            stage=R.stage_base(f.base,joinpath(root,"stage"),recipe,"interaction",f.background,f.aoc,
                "/opt/pipewireao";allowed_backends=("cpu","cuda","amdgpu"))
            @test C.read_json(joinpath(stage,"provenance.json"))["hil"]["backend"]==backend
            @test read(joinpath(stage,"hil","Project.toml"))==read(joinpath(f.base,"hil","Project.toml"))
            if backend!="cpu"
                @test_throws ArgumentError R.validate_base(f.base,"/opt/pipewireao",recipe)
                write(joinpath(f.base,"hil","Project.toml"),"[sources]\nAdaptiveOpticsCalibration = {path = \"packages/AdaptiveOpticsCalibration\"}\n")
                @test_throws ArgumentError M.retained_startup(f.base,"/opt/pipewireao";recipe)
            end
        end
    end
    for frames in (1,64)
        recipe=method_recipe();recipe["frames_per_probe"]=frames
        @test M.validate_profile_recipe(recipe,"copper")["frames_per_probe"]==frames
    end
    for frames in (0,65,true)
        recipe=method_recipe();recipe["frames_per_probe"]=frames
        @test_throws ArgumentError M.validate_profile_recipe(recipe,"copper")
    end
end

@testset "backend identity rejects missing, ambiguous and mismatched selection" begin
    for engine in ("fgn","jfg")
        mktempdir() do root
            f=method_base(root;engine)
            recipe=M.validate_profile_recipe(method_recipe(),"copper")
            for argv in (["julia"], ["julia","--backend"],
                    ["julia","--backend","cuda"], ["julia","--backend","unknown"],
                    ["julia","--backend","cpu","--backend","cpu"],
                    ["julia","--backend=cpu"], ["julia","--backend","cpu","--backend=cuda"])
                descriptor=deepcopy(f.descriptor)
                descriptor["owners"][1]["argv"]=argv
                C.write_json(joinpath(f.base,"deployment.conf"),descriptor)
                @test_throws ArgumentError M.retained_startup(f.base,"/opt/pipewireao";recipe)
            end
            C.write_json(joinpath(f.base,"deployment.conf"),f.descriptor)
            provenance=deepcopy(f.provenance);provenance["hil"]["backend"]="unknown"
            C.write_json(joinpath(f.base,"provenance.json"),provenance)
            @test_throws ArgumentError M.retained_startup(f.base,"/opt/pipewireao";recipe)
        end
    end
    for backend in ("cuda","amdgpu")
        mktempdir() do root
            f=method_base(root;backend)
            project=joinpath(f.base,"hil","Project.toml")
            original=read(project,String)
            package=backend=="cuda" ? "CUDA" : "AMDGPU"
            invalid=TOML.parse(original)
            invalid["deps"][package]="00000000-0000-0000-0000-000000000000"
            open(project,"w") do io
                TOML.print(io,invalid)
            end
            recipe=M.validate_profile_recipe(method_recipe(),"copper")
            @test_throws ArgumentError M.retained_startup(f.base,"/opt/pipewireao";recipe)
        end
    end
end

function classic_method_recipe()
    return Dict{String,Any}("version"=>1,"dark_frames"=>2,"training_frames"=>2,"qualification_frames"=>2,
        "seeds"=>Dict("dark"=>111,"training"=>222,"qualification"=>333,"interaction"=>444),
        "lamp_magnitude"=>5.7,"candidate_mask"=>trues(188),"minimum_flux"=>fill(100.0,188),
        "adc_upper_rail"=>4095,"maximum_reference_residual"=>0.1,"reference"=>zeros(277),
        "amplitudes"=>fill(0.02,277),"frames_per_probe"=>2,
        "settling"=>Dict("kind"=>"discard_exposures","frames"=>1),
        "request_timeout_ns"=>30_000_000_000,"stage_timeout_seconds"=>300)
end

function classic_method_base(root;engine="fgn",backend="cpu")
    f=method_base(root;engine,backend)
    origins=[[0,0] for _ in 1:188]
    active=UInt8[iseven(i) ? 1 : 0 for i in 1:188]
    parameters=Dict{String,Any}[]
    for parameter in PipeWireAODeployment.ScienceExport.classic_parameters()
        payload=parameter.name=="subaperture-origins" ?
            PipeWireAODeployment.HILExport._packed_origins(origins) :
            parameter.name=="active" ? active :
            collect(reinterpret(UInt8,fill(parameter.name=="background" ? 0.75f0 : 0.125f0,prod(parameter.shape))))
        path=joinpath(f.base,"calibration",parameter.file)
        write(path,payload)
        binding=PipeWireAODeployment.ScienceExport.parameter_dict(parameter)
        binding["sha256"]=C.sha256_file(path)
        push!(parameters,binding)
    end
    provenance=Dict("profile"=>"classic","engine"=>engine,"mode"=>"frame","hil"=>Dict("backend"=>backend),
        "prepared_profile"=>Dict("subaperture_origins"=>origins),"parameters"=>parameters)
    C.write_json(joinpath(f.base,"provenance.json"),provenance)
    pixel=Dict("name"=>"pixel-calibration","label"=>"pixel-calibration-u16-f32",
        "config"=>Dict("image_rows"=>352,"image_columns"=>352))
    wfs=Dict("name"=>"shack-hartmann","label"=>"shack-hartmann-image-f32",
        "config"=>Dict("image_rows"=>352,"image_columns"=>352,"subaperture_count"=>188,
            "subaperture_rows"=>22,"subaperture_columns"=>22,
            "initial_subaperture_origins"=>origins,"active"=>Bool.(active)))
    command=Dict("name"=>"pdm-command","label"=>"pdm-command-f32","config"=>Dict("actuator_count"=>277))
    graph=Dict{String,Any}("node.name"=>"selected","filter.graph"=>Dict("nodes"=>[pixel,wfs,command],
        "links"=>[Dict("output"=>"pixel-calibration:calibrated","input"=>"shack-hartmann:image")],
        "inputs"=>["pixel-calibration:raw","pdm-command:requested"],"outputs"=>["pdm-command:demanded"]))
    descriptor=deepcopy(f.descriptor)
    if engine=="fgn"
        for name in ("background","reference-slopes","coordinates","thresholds")
            binding=only(filter(p->p["name"]==name,parameters))
            graph["pipewireao.startup-parameter."*binding["endpoint"]]="@PACKAGE@/calibration/"*binding["file"]
        end
    else
        argv=String["julia"]
        for binding in parameters
            append!(argv,["--parameter",binding["name"],
                PipeWireAODeployment.ScienceExport.JULIA_TYPES[binding["element_type"]],
                join(binding["shape"],","),"@PACKAGE@/calibration/"*binding["file"]])
        end
        descriptor["owners"][2]["argv"]=argv
    end
    C.write_json(joinpath(f.base,"graphs","graph.conf.in"),graph)
    C.write_json(joinpath(f.base,"deployment.conf"),descriptor)
    model=read(joinpath(f.base,"hil","plant.toml"),String)
    model=replace(model,"pwfs"=>"shwfs","bits = 14"=>"bits = 12")
    write(joinpath(f.base,"hil","plant.toml"),model)
    return (;f.base,f.aoc,provenance,graph,descriptor,active,origins)
end

@testset "Classic method retains science across explicit simulator backends" begin
    for engine in ("fgn","jfg"), backend in ("cuda","amdgpu","cpu")
        mktempdir() do root
            f=classic_method_base(root;engine,backend)
            recipe=M.validate_profile_recipe(classic_method_recipe(),"classic")
            before=A.file_identity(f.base)
            background,references,active,snapshot=M.retained_startup(f.base,"/opt/pipewireao";recipe)
            @test active==f.active
            @test snapshot["subaperture_origins"]==f.origins
            prepared=A.stage_base(f.base,joinpath(root,"stage"),recipe,"interaction",background,references,
                active,f.aoc,"/opt/pipewireao";allowed_backends=("cpu","cuda","amdgpu"))
            @test A.file_identity(f.base)==before
            @test C.read_json(joinpath(prepared,"provenance.json"))["hil"]["backend"]==backend
            @test read(joinpath(prepared,"hil","Project.toml"))==read(joinpath(f.base,"hil","Project.toml"))
            @test read(joinpath(prepared,"calibration","background.f32le"))==background
            @test read(joinpath(prepared,"calibration","reference-slopes.f32le"))==references
            @test read(joinpath(prepared,"calibration","active-subapertures.u8"))==active
            for binding in f.provenance["parameters"]
                @test read(joinpath(prepared,"calibration",binding["file"]))==read(joinpath(f.base,"calibration",binding["file"]))
            end
            model=TOML.parsefile(joinpath(prepared,"hil","plant.toml"))
            @test only(filter(n->n["name"]=="detector",model["nodes"]))["config"]["rng_seed"]==444
            backend=="cpu" || @test_throws ArgumentError A.stage_base(f.base,joinpath(root,"default-stage"),recipe,
                "interaction",background,references,active,f.aoc,"/opt/pipewireao")
        end
    end
end
