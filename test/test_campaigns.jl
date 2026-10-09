using Test, JSON3

using PipeWireAODeployment
const CampaignTestModules=PipeWireAODeployment
const A=CampaignTestModules.CalibrationCampaign
const M=CampaignTestModules.CalibrationMethod
const C=CampaignTestModules.Common
const W=CampaignTestModules.WirePlumberSessionRuntime

@testset "Native Quit attempt and completion ordering" begin
    handle=W.Handle("pipewireao-session@test.service", "/unused", "a"^32,
        1, UInt64(1), "/unused", false, false, false, nothing)
    events=Symbol[]
    W._native_quit!(handle) do mark_attempt!
        push!(events, :before)
        @test !handle.shutdown_attempted
        mark_attempt!()
        push!(events, :submitted)
        @test handle.shutdown_attempted && !handle.shutdown_accepted
        Dict("ok"=>true,"state"=>"Offline","result"=>Dict("shutdown"=>true))
    end
    @test events==[:before,:submitted]
    @test handle.shutdown_accepted
    @test_throws ArgumentError W._native_quit!(handle) do mark_attempt!
        error("native Quit must never be sent twice")
    end
    uncertain=W.Handle("pipewireao-session@test.service", "/unused", "b"^32,
        1, UInt64(1), "/unused", false, false, false, nothing)
    @test_throws ErrorException W._native_quit!(uncertain) do mark_attempt!
        mark_attempt!()
        error("reply lost after submission")
    end
    @test uncertain.shutdown_attempted && !uncertain.shutdown_accepted
    @test_throws ArgumentError W._native_quit!(uncertain) do mark_attempt!
        error("native Quit must never be retried")
    end
end

classic_recipe()=Dict{String,Any}(
    "version"=>1,"dark_frames"=>8,"training_frames"=>8,"qualification_frames"=>8,
    "seeds"=>Dict("dark"=>11,"training"=>22,"qualification"=>33,"interaction"=>44),
    "lamp_magnitude"=>5.7,"candidate_mask"=>trues(188),"minimum_flux"=>fill(100.0,188),
    "adc_upper_rail"=>4095,"maximum_reference_residual"=>0.1,
    "reference"=>zeros(277),"amplitudes"=>fill(0.02,277),"frames_per_probe"=>2,
    "settling"=>Dict("kind"=>"discard_exposures","frames"=>1),
    "request_timeout_ns"=>30_000_000_000,"stage_timeout_seconds"=>300)

function capture_fixture(root;profile="classic")
    channels,payload=A.capture_contract(profile)
    after=Dict("domain"=>1,"generation"=>1,"sequence"=>1,"model_ns"=>10)
    settings=Dict("detector_config"=>Dict("bits"=>12,"exposure_duration_s"=>5e-9),
                  "graph_sha256"=>"graph","wfs_active_sha256"=>"mask")
    mapping=Dict("opaque_domain"=>1,"complete_domain"=>ones(Int,16))
    startup=merge(settings,Dict("profile"=>profile,"illumination"=>"dark",
        "acquisition_domain_mapping"=>mapping,"capture_settings_sha256"=>"settings",
        "acquisition_generation"=>1))
    exposures=Any[]
    for index in 1:2
        directory=joinpath(root,"4",string(index))
        mkpath(directory)
        files=Dict{String,Any}()
        for (name,(element,shape,size,filename)) in channels
            path=joinpath(directory,filename)
            write(path,zeros(UInt8,size))
            files[name]=Dict("path"=>filename,"element_type"=>element,"shape"=>shape,
                "layout"=>"ROW_MAJOR","bytes"=>size,"sha256"=>C.sha256_file(path))
        end
        push!(exposures,Dict("directory"=>string(index),"domain"=>1,"generation"=>1,
            "sequence"=>index+1,"start_model_ns"=>index*10,"duration_ns"=>5,
            "valid"=>false,"files"=>files))
    end
    manifest=Dict("version"=>1,"run"=>1,"serial"=>4,"probe"=>0,"stage"=>"dark",
        "profile"=>profile,"illumination"=>"dark","settings"=>settings,
        "settings_sha256"=>"settings","acquisition_domain_mapping"=>mapping,
        "frames"=>2,"bytes"=>2*payload,"exposures"=>exposures)
    path=joinpath(root,"4","manifest.json")
    C.write_json(path,manifest)
    completion=Dict("manifest"=>"4/manifest.json","sha256"=>C.sha256_file(path),
        "frames"=>2,"bytes"=>2*payload,"metadata_bytes"=>filesize(path),
        "cursor"=>Dict("domain"=>1,"generation"=>1,"sequence"=>3,"model_ns"=>25))
    return manifest,completion,after,startup
end

@testset "Classic recipe and method admission" begin
    original=classic_recipe()
    converted=A.validate_recipe(original)
    @test converted["reference"]!==original["reference"]
    @test A.same_figure(converted["amplitudes"],fill(0.02,277))
    source=A.orchestration_sources()
    @test haskey(source,abspath(joinpath(PipeWireAODeployment.resource_root(),"hil","calibration_campaign_analysis.jl")))
    @test haskey(source,abspath(joinpath(PipeWireAODeployment.resource_root(),"hil","calibration_method_analysis.jl")))
    @test haskey(source,abspath(joinpath(PipeWireAODeployment.resource_root(),"templates","client-simulator.conf.in")))
    @test haskey(source,abspath(joinpath(PipeWireAODeployment.resource_root(),"pipewireao-session@.service.in")))
    @test haskey(source,abspath(joinpath(PipeWireAODeployment.package_root(),"assets","ryzen-6800h-classic.cpu")))
    @test haskey(source,abspath(joinpath(PipeWireAODeployment.package_root(),"assets","ryzen-6800h-classic.threads")))
    service=read(joinpath(PipeWireAODeployment.resource_root(),"pipewireao-session@.service.in"),String)
    @test occursin(r"(?m)^TimeoutStopSec=300$",service)
    mktempdir() do root
        copied=joinpath(root,"orchestration-sources")
        mkdir(copied)
        for path in keys(source)
            target=joinpath(copied,PipeWireAODeployment.source_relative_path(path))
            mkpath(dirname(target))
            cp(path,target)
        end
        retained=A.file_identity(copied)
        @test haskey(retained,joinpath("julia","Project.toml"))
        @test haskey(retained,joinpath("hil","Project.toml"))
    end
    for mutation in (
        r->(r["version"]=true), r->(r["training_frames"]=1),
        r->(r["candidate_mask"]=falses(188)),
        r->(r["amplitudes"]=fill(1e-100,277)),
        r->(r["settling"]=Dict("kind"=>"bad")),
        r->(r["seeds"]["interaction"]=r["seeds"]["training"]))
        bad=classic_recipe();mutation(bad)
        @test_throws ArgumentError A.validate_recipe(bad)
    end
    @test M.validate_method(Dict("version"=>1,"run"=>1,"order"=>"forward"))["order"]=="forward"
    for bad in (Dict("version"=>true,"run"=>1,"order"=>"forward"),
                Dict("version"=>1,"run"=>0,"order"=>"forward"),
                Dict("version"=>1,"run"=>1,"order"=>"bad"),
                Dict("version"=>1,"run"=>1,"order"=>"forward","probe_basis"=>Dict("kind"=>"modal")))
        @test_throws ArgumentError M.validate_method(bad)
    end
end

@testset "Batch admission precedes stage output" begin
    valid=Dict("figure"=>zeros(277),"frames"=>2)
    @test length(A.validate_batches([valid]))==1
    @test_throws ErrorException A.stage_remaining(Int128(time_ns())-1,30)
    for bad in (Any[],[Dict("figure"=>zeros(276),"frames"=>2)],
                [Dict("figure"=>zeros(277),"frames"=>1)],
                [Dict("figure"=>fill(true,277),"frames"=>2)],
                [Dict("figure"=>fill(Inf,277),"frames"=>2)],
                fill(valid,33))
        @test_throws ArgumentError A.validate_batches(bad)
    end
    mktempdir() do root
        package=joinpath(root,"package");mkdir(package)
        C.write_json(joinpath(package,"provenance.json"),Dict("profile"=>"copper",
            "capture_max_payload_bytes"=>45192))
        output=joinpath(root,"evidence")
        @test_throws ArgumentError A.run_stage(package,output,joinpath(root,"runtime"),
            Dict("stage_timeout_seconds"=>300),"training";batches=[valid,valid])
        @test !ispath(output)
    end
end

@testset "Capture association and payload integrity" begin
    for profile in ("classic","copper")
        mktempdir() do root
            manifest,completion,after,startup=capture_fixture(root;profile)
            kw=(;run=1,serial=4,stage="dark",frames=2,after,startup,profile)
            @test A.verify_capture(root,completion;kw...)["profile"]==profile
            @test_throws ArgumentError A.verify_capture(root,completion;kw...,probe=true)
            manifest["probe"]=1
            path=joinpath(root,"4","manifest.json")
            C.write_json(path,manifest)
            completion["sha256"]=C.sha256_file(path)
            completion["metadata_bytes"]=filesize(path)
            @test_throws ArgumentError A.verify_capture(root,completion;kw...)
            @test A.verify_capture(root,completion;kw...,probe=1)["probe"]==1
            original=deepcopy(manifest)
            for mutate in (m->(m["exposures"][1]["files"]["raw"]["layout"]="COLUMN_MAJOR"),
                           m->(m["exposures"][1]["sequence"]=5),
                           m->(m["settings"]["graph_sha256"]="different"),
                           m->(m["bytes"]+=1))
                bad=deepcopy(original);mutate(bad)
                C.write_json(path,bad)
                completion["sha256"]=C.sha256_file(path)
                completion["metadata_bytes"]=filesize(path)
                @test_throws ArgumentError A.verify_capture(root,completion;kw...,probe=1)
            end
            C.write_json(path,original)
            completion["sha256"]=C.sha256_file(path)
            completion["metadata_bytes"]=filesize(path)
            wrapped=deepcopy(original)
            wrapped["exposures"][1]["start_model_ns"]=typemax(UInt64)-4095
            wrapped["exposures"][1]["duration_ns"]=5000
            wrapped["exposures"][2]["start_model_ns"]=0
            wrapped["exposures"][2]["duration_ns"]=5000
            wrapped["settings"]["detector_config"]["exposure_duration_s"]=5e-6
            startup["detector_config"]["exposure_duration_s"]=5e-6
            completion["cursor"]["model_ns"]=5000
            C.write_json(path,wrapped)
            completion["sha256"]=C.sha256_file(path)
            completion["metadata_bytes"]=filesize(path)
            @test_throws ArgumentError A.verify_capture(root,completion;kw...,probe=1)
            wrapped["exposures"][1]["start_model_ns"]=20
            wrapped["exposures"][2]["start_model_ns"]=typemax(UInt64)-1000
            C.write_json(path,wrapped)
            completion["sha256"]=C.sha256_file(path)
            completion["metadata_bytes"]=filesize(path)
            @test_throws ArgumentError A.verify_capture(root,completion;kw...,probe=1)
            startup["detector_config"]["exposure_duration_s"]=5e-9
            completion["cursor"]["model_ns"]=25
            C.write_json(path,original)
            completion["sha256"]=C.sha256_file(path)
            completion["metadata_bytes"]=filesize(path)
            filename=A.capture_contract(profile)[1]["raw"][4]
            write(joinpath(root,"4","1",filename),"altered")
            @test_throws ArgumentError A.verify_capture(root,completion;kw...,probe=1)
        end
    end
end

@testset "Campaign requires an explicit native action binding" begin
    ready=Dict("source_endpoint"=>Dict("node"=>"owner","instance"=>Int64(42)),
        "source-owner"=>"simulator", "control_locator"=>"/tmp/private/control.json",
        "private_runtime"=>"/tmp/private/run", "observation_remote"=>"/tmp/private/run/pw",
        "remote"=>"pw", "processes"=>Dict("simulator"=>Dict("pid"=>UInt32(17))))
    binding=A.endpoint_binding(ready)
    @test binding.remote=="/tmp/private/run/pw"
    @test binding.remote != joinpath(dirname(ready["control_locator"]),ready["remote"])
    unverified=copy(ready);delete!(unverified,"observation_remote")
    @test_throws KeyError A.endpoint_binding(unverified)
    @test binding.node=="owner.actions"
    @test binding.owner_pid==17 && binding.instance==42
    @test_throws ArgumentError A.endpoint_connect("/tmp/legacy.sock",1,1_000_000_000)
end

@testset "Interaction result output bound follows the sealed plan" begin
    mktempdir() do root
        classic=Dict("version"=>1,"run"=>1,"measurements"=>376,"frames_per_probe"=>16,
            "probes"=>[zeros(277) for _ in 1:554])
        classic_path=joinpath(root,"classic-plan.json")
        C.write_json(classic_path,classic)
        classic_limit=A.interaction_result_output_limit_bytes(classic_path)
        @test classic_limit>0
        @test classic_limit<16*1024*1024

        copper=Dict("version"=>1,"run"=>2,"measurements"=>3600,"frames_per_probe"=>64,
            "probes"=>[zeros(277) for _ in 1:1024])
        copper_path=joinpath(root,"copper-plan.json")
        C.write_json(copper_path,copper)
        copper_limit=A.interaction_result_output_limit_bytes(copper_path)
        @test copper_limit>16*1024*1024
        @test copper_limit<=512*1024*1024
        @test copper_limit>classic_limit

        malformed=deepcopy(classic)
        delete!(malformed,"frames_per_probe")
        malformed_path=joinpath(root,"malformed-plan.json")
        C.write_json(malformed_path,malformed)
        @test_throws ArgumentError A.interaction_result_output_limit_bytes(malformed_path)
    end
    @test_throws ArgumentError A.interaction_result_output_limit_bytes(1,17_000_000,1)
    @test_throws ArgumentError A.interaction_result_output_limit_bytes(typemax(Int),1,1)
end
