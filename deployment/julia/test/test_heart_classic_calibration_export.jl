using Test, TOML, PipeWireAODeployment
const Export = PipeWireAODeployment.HeartCalibrationExport
const Common = PipeWireAODeployment.Common

function classic_plan()
    Dict("version"=>1,"run"=>98,"reference"=>zeros(277),"probes"=>[zeros(277) for _ in 1:24],
        "measurements"=>376,"frames_per_probe"=>64,"settling"=>Dict("kind"=>"discard_exposures","frames"=>1),
        "timeouts_ns"=>Dict(name=>20_000_000_000 for name in ("ownership","adoption","settling","collection","restoration")))
end
@testset "explicit Classic profile retains Copper default rejection" begin
    plan = classic_plan()
    @test_throws ArgumentError Export.plan_limits(plan) # prior Copper-only gate
    original=deepcopy(plan)
    bounds=Export.plan_limits(plan;profile="classic")
    @test plan==original
    @test bounds["completed_exposures"]==1561
    @test bounds["native_dm_records"]==25
    @test bounds["capture_max_payload_bytes"]==1536*250252
    @test bounds["native_file_bytes"]==Dict("cbHoPixelsRaw0"=>1024+1561*247872,
        "cbHoPixelsCalib0"=>1024+1561*495680,"cbHoGrad0"=>1024+1561*3072,"cbDmCmd0"=>1024+25*1216)
    for change in (p->p["measurements"]=3600,p->p["frames_per_probe"]=true,
        p->p["probes"][1]=zeros(221),p->p["settling"]["frames"]=0)
        bad=deepcopy(plan);change(bad)
        @test_throws ArgumentError Export.plan_limits(bad;profile="classic")
    end
    @test_throws ArgumentError Export.plan_limits(plan;profile="other")
    @test only(Export.calibration_session(500;profile="classic")["sources"][1]["ports"])["shape"]==[352,352]
    argv=["julia","@PACKAGE@/hil/simulator.jl"]
    selected=Export.owner_arguments(argv;stage="classictransfer",illumination="lamp",capture_max_bytes=1000,
        telemetry_max_bytes=1024,evidence_directory="/fresh",profile="classic")
    for (key,value) in (("--wfs-active","@PACKAGE@/heart/classic-active.u8"),
        ("--heart-classic-order","@PACKAGE@/heart/classic-order.u32le"),("--heart-slope-scale-x","1.0"),("--heart-slope-scale-y","1.0"))
        @test selected[findfirst(==(key),selected)+1]==value
    end
    @test argv==["julia","@PACKAGE@/hil/simulator.jl"]
end

@testset "Classic ordinary ingress does not admit the Copper deferred fixture" begin
    mktempdir() do directory
        binary=joinpath(directory,"native");write(binary,"fixture")
        properties=Dict("api.heart.std-wfs.width"=>352,"api.heart.std-wfs.height"=>352,
            "api.heart.std-wfs.pixels-per-datagram"=>3872,"api.heart.std-wfs.rows-per-datagram"=>true)
        check(mode="streaming",props=properties)=Export.ingress_contract(mode,"classic",props,binary;source_revision="fixture")
        record=check()
        @test record["environment_value"]=="0" && record["shape"]==[352,352]
        @test record["packet_rows"]==11 && record["datagrams_per_frame"]==32
        @test_throws ArgumentError check("deferred")
        bad=copy(properties);bad["api.heart.std-wfs.pixels-per-datagram"]=2048
        @test_throws ArgumentError check("streaming",bad)
    end
end

@testset "Classic lamp changes exactly magnitude and detector seed" begin
    mktempdir() do directory
        path=joinpath(directory,"plant.toml")
        graph=Dict("nodes"=>[Dict("name"=>"shwfs","type"=>"shack_hartmann_rate_f32","config"=>Dict("source_magnitude"=>2.0)),
            Dict("name"=>"detector","type"=>"cmos_detector_acquisition_f32","config"=>Dict("rng_seed"=>1,
                "photon_noise"=>true,"readout_noise"=>true,"bits"=>12)),
            Dict("name"=>"atmosphere","type"=>"normal","config"=>Dict("rng_seed"=>1,"r0"=>0.15))])
        open(io->TOML.print(io,graph),path,"w")
        @test_throws ArgumentError Export.freeze_detector!(path;seed=98) # original Copper guard
        report=Export.freeze_detector!(path;profile="classic",seed=98)
        expected=deepcopy(graph);expected["nodes"][1]["config"]["source_magnitude"]=0.5;expected["nodes"][2]["config"]["rng_seed"]=98
        @test TOML.parsefile(path)==expected
        @test report["graph_sha256"]==Common.sha256_file(path)
        @test_throws ArgumentError Export.freeze_detector!(path;profile="classic",seed=99)
        for (key,value) in (("bits",14),("photon_noise",false),("readout_noise",false))
            bad=deepcopy(expected);bad["nodes"][2]["config"][key]=value
            open(io->TOML.print(io,bad),path,"w")
            @test_throws ArgumentError Export.freeze_detector!(path;profile="classic",seed=98)
        end
    end
end

function policy_fixture(directory)
    source=joinpath(directory,"source");prepared=joinpath(directory,"prepared");mkdir(source);mkdir(prepared)
    plan=classic_plan()
    labels=[Dict("direction"=>direction,"slot"=>slot,"kind"=>"fixture") for direction in (1,8,9,16) for slot in 1:6]
    directions=[Dict("direction"=>direction,"figure"=>zeros(277)) for direction in (1,8,9,16)]
    recipe=Dict("seeds"=>Dict("interaction"=>98),"lamp_magnitude"=>0.5,"adc_upper_rail"=>4095,
        "frames_per_probe"=>64,"settling"=>plan["settling"],"reference"=>plan["reference"])
    for (name,value) in (("interaction-plan.json",plan),("probe-labels.json",labels),("directions.json",directions),("policy.json",Dict("fixture"=>true)))
        Common.write_json(joinpath(source,name),value)
    end
    for (name,value) in (("interaction-plan.json",plan),("probe-labels.json",labels),("directions.json",directions),("recipe.json",recipe))
        Common.write_json(joinpath(prepared,name),value)
    end
    policy=Dict("version"=>1,"selected_direction_ids"=>[1,8,9,16],"groups"=>Dict("sparse"=>[1,8],"mixed"=>[9,16]),
        "accepted_inverse_sha256"=>Export.CLASSIC_ACCEPTED_INVERSE_SHA256,"source_corpus"=>source,
        "detector_seed"=>98,"lamp_magnitude"=>0.5,"scope"=>"synthetic unit fixture; not science admission",
        "source_files"=>Dict(name=>Common.sha256_file(joinpath(source,name)) for name in ("interaction-plan.json","probe-labels.json","directions.json","policy.json")),
        "prepared_files"=>Dict(name=>Common.sha256_file(joinpath(prepared,name)) for name in ("interaction-plan.json","probe-labels.json","directions.json","recipe.json")))
    Common.write_json(joinpath(prepared,"policy.json"),policy)
    return prepared,policy
end
@testset "Classic corpus requires externally bound policy and literal original chronology" begin
    mktempdir() do directory
        prepared,policy=policy_fixture(directory)
        path=joinpath(prepared,"policy.json");plan=joinpath(prepared,"interaction-plan.json")
        hash=Common.sha256_file(path)
        @test Export.classic_transfer_policy(prepared,hash,plan,98)==policy
        @test_throws ArgumentError Export.classic_transfer_policy(prepared,nothing,plan,98)
        @test_throws ArgumentError Export.classic_transfer_policy(prepared,"0"^64,plan,98)
        @test_throws ArgumentError Export.classic_transfer_policy(prepared,hash,plan,99)
        @test_throws ArgumentError Export.classic_transfer_policy(prepared,hash,nothing,98)
        for change in (p->p["accepted_inverse_sha256"]="0"^64,p->p["selected_direction_ids"]=[1,2,3,4],p->p["lamp_magnitude"]=2.0)
            bad=deepcopy(policy);change(bad);Common.write_json(path,bad)
            @test_throws ArgumentError Export.classic_transfer_policy(prepared,Common.sha256_file(path),plan,98)
        end
        Common.write_json(path,policy)
        changed=Common.read_json(plan);changed["probes"][1][1]=0.04
        Common.write_json(plan,changed)
        policy["prepared_files"]["interaction-plan.json"]=Common.sha256_file(plan)
        Common.write_json(path,policy)
        @test_throws ArgumentError Export.classic_transfer_policy(prepared,Common.sha256_file(path),plan,98) # hashes cannot authorize rewritten probes
    end
end

@testset "Classic generated name preserves the public40-character bound" begin
    D=PipeWireAODeployment.Deployment
    mktempdir() do directory
        for name in ("session.conf.in","core.conf.in","client.conf.in")
            write(joinpath(directory,name),"{}\n")
        end
        contract=Dict("cpus"=>[2],"leader-cpu"=>2,"rt-priority"=>0,"threads"=>Any[],"locked-bytes"=>0)
        spec=Dict("version"=>1,"name"=>"revolt-classic-heart-hil-cuda-calibration","session"=>"session.conf.in",
            "core"=>"core.conf.in","client"=>Dict("core"=>"client.conf.in","rtc"=>"client.conf.in"),
            "placement"=>Dict("core"=>deepcopy(contract),"rtc"=>deepcopy(contract)),"owners"=>Any[],
            "environment"=>Dict{String,String}(),"cpu-latency-us"=>nothing,
            "artifacts"=>Dict("session.conf.in"=>D.digest(joinpath(directory,"session.conf.in"))))
        path=joinpath(directory,"deployment.conf");Common.write_json(path,spec)
        @test length(spec["name"])==41
        @test_throws D.DeploymentError D.profile(path,"/unused")
        original=deepcopy(spec)
        spec["name"]=Export.calibration_name("revolt-classic-heart-hil-cuda","classic")
        Common.write_json(path,spec)
        @test D.profile(path,"/unused")==spec
        original["name"]=spec["name"]
        @test original==spec
        @test Export.calibration_name("revolt-copper-heart-hil-cuda","copper")=="revolt-copper-heart-hil-cuda-calibration"
        @test length(Export.calibration_name("revolt-copper-heart-hil-cuda","copper"))==40
    end
end
