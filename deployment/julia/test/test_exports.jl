using Test

# Keep these portable checks independent of an installed PipeWireAO prefix.
module ExportFixture
using PipeWireAODeployment: package_root, resource_root, source_relative_path
using PipeWireAODeployment
const Common = PipeWireAODeployment.Common
module Deployment
using ..Common
native_source(owner) = get(owner, "control-protocol", nothing) == "pipewireao.source-control/1"
decode(path,prefix) = Common.read_json(path)
profile(path,prefix) = Common.read_json(path)
end

module HeartConfiguration end
include(joinpath(package_root(), "src", "science_export.jl"))
include(joinpath(package_root(), "src", "hil_export.jl"))
include(joinpath(package_root(), "src", "calibration_export.jl"))
include(joinpath(package_root(), "src", "calibration_campaign.jl"))
include(joinpath(package_root(), "src", "heart_export.jl"))
end

const Science = ExportFixture.ScienceExport
const HIL = ExportFixture.HILExport
const Calibration = ExportFixture.CalibrationExport
const Heart = ExportFixture.HeartExport

@testset "native SPA config writer preserves data and separates object arrays" begin
    mktempdir() do root
        modules = [Dict("name"=>"libpipewire-module-rt", "args"=>Dict("rt.prio"=>83)),
                   Dict("name"=>"libpipewire-module-protocol-native")]
        value = Dict{String,Any}("context.modules"=>modules,
            "context.properties"=>Dict("core.name"=>"@REMOTE@", "core.daemon"=>true))
        path = joinpath(root,"core.conf.in")
        @test Science.write_spa_config(path,value) == path
        payload = read(path,String)
        @test occursin(r"(?s)\}\s*,\s*\n\s*\{",payload)
        @test endswith(payload,"\n")
        @test ExportFixture.Common.read_json(path) == value
        value["nonfinite"] = NaN
        @test_throws ArgumentError Science.write_spa_config(path,value)
    end
end

@testset "staged HIL package replaces embedded local dependency" begin
    mktempdir() do root
        base=joinpath(root,"sealed-base")
        embedded=joinpath(base,"hil","packages","AdaptiveOpticsCalibration")
        mkpath(joinpath(embedded,"src"))
        write(joinpath(embedded,"Project.toml"),"name = \"AdaptiveOpticsCalibration\"\n")
        write(joinpath(embedded,"src","old.jl"),"old source\n")
        selected=joinpath(root,"selected-aoc")
        mkpath(joinpath(selected,"src"))
        write(joinpath(selected,"Project.toml"),"name = \"AdaptiveOpticsCalibration\"\n")
        write(joinpath(selected,"src","new.jl"),"selected source\n")
        original=Dict(relpath(path,base)=>ExportFixture.Common.sha256_file(path)
            for (directory,_,files) in walkdir(base) for name in files
            for path in (joinpath(directory,name),))
        selected_hash=ExportFixture.Common.sha256_file(joinpath(selected,"src","new.jl"))
        package=joinpath(root,"stage","package")
        Science.copy_tree(base,package)
        invalid=joinpath(root,"invalid-source");mkdir(invalid)
        @test_throws ArgumentError HIL.replace_staged_package(invalid,package,"AdaptiveOpticsCalibration")
        @test isfile(joinpath(package,"hil","packages","AdaptiveOpticsCalibration","src","old.jl"))
        HIL.replace_staged_package(selected,package,"AdaptiveOpticsCalibration")
        installed=joinpath(package,"hil","packages","AdaptiveOpticsCalibration")
        @test !ispath(joinpath(installed,"src","old.jl"))
        @test ExportFixture.Common.sha256_file(joinpath(installed,"src","new.jl"))==selected_hash
        @test Dict(relpath(path,base)=>ExportFixture.Common.sha256_file(path)
            for (directory,_,files) in walkdir(base) for name in files
            for path in (joinpath(directory,name),))==original
        @test ExportFixture.Common.sha256_file(joinpath(selected,"src","new.jl"))==selected_hash
    end
end

@testset "export payload and path contracts" begin
    mktempdir() do root
        write(joinpath(root,"active.u8"),UInt8[0,1,1])
        write(joinpath(root,"empty.f32le"),UInt8[])
        @test_throws ArgumentError Science.validate_parameter(root,Science.Parameter("empty","node:empty","F32_LE",[1<<62],"empty.f32le"))
        @test_throws ArgumentError HIL.finite_payload(joinpath(root,"empty.f32le"),"F32_LE",[1<<62])
        @test_throws ArgumentError Science.payload_bytes([-1],4)
        @test Science.payload_bytes([2,3],4) == 24
        @test HIL.finite_payload(joinpath(root,"active.u8"),"Bool",[3]) == UInt8[0,1,1]
        @test_throws ArgumentError HIL.finite_payload(joinpath(root,"active.u8"),"Bool",[4])
        write(joinpath(root,"active.u8"),UInt8[0,2,1])
        @test_throws ArgumentError HIL.finite_payload(joinpath(root,"active.u8"),"Bool",[3])
        write(joinpath(root,"float.f32le"),reinterpret(UInt8,Float32[1,NaN]))
        @test_throws ArgumentError HIL.finite_payload(joinpath(root,"float.f32le"),"F32_LE",[2])
        @test_throws ArgumentError Science.validate_parameter(root,Science.Parameter("float","node:float","F32_LE",[2],"float.f32le"))
        write(joinpath(root,"ok.json"),"{\"value\":1}\n")
        @test HIL.campaign_json(root,"ok.json")["value"] == 1
        write(joinpath(root,"duplicate.json"),"{\"value\":1,\"v\\u0061lue\":2}\n")
        @test_throws ArgumentError HIL.campaign_json(root,"duplicate.json")
        write(joinpath(root,"nested-duplicate.json"),"{\"outer\":[{\"a\":1,\"a\":2}]}\n")
        @test_throws ArgumentError HIL.campaign_json(root,"nested-duplicate.json")
        @test_throws ArgumentError HIL.campaign_file(root,"../ok.json",100)
        symlink(joinpath(root,"ok.json"),joinpath(root,"linked.json"))
        @test_throws ArgumentError HIL.campaign_file(root,"linked.json",100)
        @test_throws ArgumentError HIL.campaign_file(root,"ok.json",2)
    end
end

function fixture_graph(profile="classic"; engine="fgn")
    extent = profile == "classic" ? 352 : 64
    wfs_label = profile == "classic" ? "shack-hartmann-image-f32" :
                engine == "fgn" ? "pyramid-pixel-image-f32" : "pyramid-pupil-image-f32"
    wfs_config = Dict{String,Any}("image_rows"=>extent,"image_columns"=>extent)
    merge!(wfs_config,profile == "classic" ? Dict("subaperture_count"=>188,"subaperture_rows"=>22,"subaperture_columns"=>22) :
                                           Dict("pupil_rows"=>30,"pupil_columns"=>30))
    profile == "classic" && (wfs_config["active"] = fill(true,188))
    pixel = Dict("name"=>"pixel-calibration","label"=>"pixel-calibration-u16-f32",
                 "config"=>Dict("image_rows"=>extent,"image_columns"=>extent))
    wfs = Dict("name"=>"wfs","label"=>wfs_label,"config"=>wfs_config)
    command = Dict("name"=>"pdm-command","label"=>"pdm-command-f32","config"=>Dict("actuator_count"=>277))
    return Dict{String,Any}("node.name"=>"old","pipewireao.feedback.x"=>"delay",
        "filter.graph"=>Dict{String,Any}("nodes"=>[pixel,wfs,command],
            "links"=>[Dict("output"=>"pixel-calibration:calibrated","input"=>"wfs:image")],
            "inputs"=>["pixel-calibration:raw","pdm-command:requested"],"outputs"=>["pdm-command:demanded"]))
end

@testset "calibration package export" begin
    mktempdir() do root
        base = joinpath(root,"base")
        mkpath(joinpath(base,"lib")); mkpath(joinpath(base,"hil"))
        write(joinpath(base,"lib","graph.so"),"fixture")
        write(joinpath(base,"hil","calibration_acquisition.jl"),"module CalibrationAcquisition end\n")
        mkpath(joinpath(base,"graphs"))
        ExportFixture.Common.write_json(joinpath(base,"graphs/graph.conf.in"),fixture_graph())
        ExportFixture.Common.write_json(joinpath(base,"session.conf.in"),Dict("execution"=>"complete-frame","rate"=>"10/1"))
        provenance = Dict("profile"=>"classic","engine"=>"fgn","mode"=>"frame","parameters"=>Any[])
        ExportFixture.Common.write_json(joinpath(base,"provenance.json"),provenance)
        owner = Dict("role"=>"simulator","argv"=>["julia","@PACKAGE@/hil/simulator.jl"],
            "environment"=>Dict(),"prepared"=>"simulator.prepared","connect"=>"simulator.connect",
            "connected"=>"simulator.connected","quit"=>"simulator.quit",
            "control-request"=>"simulator.control.request","control-reply"=>"simulator.control.reply")
        placement = Dict("cpus"=>[1],"leader-cpu"=>1,"rt-priority"=>0,"threads"=>Any[],"locked-bytes"=>0)
        specification = Dict{String,Any}("name"=>"fixture","session"=>"session.conf.in","core"=>"core.conf.in",
            "client"=>Dict("core"=>"client-simulator.conf.in","rtc"=>"client-simulator.conf.in","simulator"=>"client-simulator.conf.in"),
            "placement"=>Dict("core"=>deepcopy(placement),"rtc"=>deepcopy(placement),"simulator"=>deepcopy(placement)),
            "owners"=>[owner],"source-owner"=>"simulator","environment"=>Dict(),"artifacts"=>Dict(),"cpu-latency-us"=>nothing)
        ExportFixture.Common.write_json(joinpath(base,"deployment.conf"),specification)
        write(joinpath(base,"client-simulator.conf.in"),"{}\n")
        write(joinpath(base,"core.conf.in"),"{}\n")
        graph_only = joinpath(root,"graph-only")
        result = Calibration.export_package((;base_package=base,output=graph_only,pipewire_prefix="/unused",deployment=false))
        @test result == joinpath(graph_only,"provenance.json")
        @test isfile(joinpath(graph_only,"graphs/wfs.conf.in"))
        @test !isfile(joinpath(graph_only,"deployment.conf"))
        @test_throws ArgumentError Calibration.export_package((;base_package=base,output=graph_only,pipewire_prefix="/unused",deployment=false))
        binary = joinpath(root,"runner"); write(binary,"runner")
        deployed = joinpath(root,"deployed")
        result = Calibration.export_package((;base_package=base,output=deployed,pipewire_prefix="/unused",deployment=true,
            rtc_binary=binary,calibration_binary=binary,illumination="lamp",calibration_stage="interaction"))
        @test result == joinpath(deployed,"provenance.json")
        @test isfile(joinpath(deployed,"deployment.conf"))
        @test isfile(joinpath(deployed,"julia/Manifest.toml"))
        @test isfile(joinpath(deployed,"julia/src/PipeWireAODeployment.jl"))
        @test isfile(joinpath(deployed,"pipewireao-rtc@.service.in"))
        @test isfile(joinpath(deployed,"julia/assets/deployment/templates/client-simulator.conf.in"))
        @test isfile(joinpath(deployed,"julia/assets/deployment/hil/calibration_campaign_analysis.jl"))
        @test isfile(joinpath(deployed,"julia/assets/deployment/hil/Project.toml"))
        @test isfile(joinpath(deployed,"julia/assets/ryzen-6800h-classic.cpu"))
        @test length(read(joinpath(deployed,"calibration/wfs-active.u8"))) == 188
        @test !occursin(".py",join(ExportFixture.Common.read_json(joinpath(deployed,"deployment.conf"))["owners"][1]["argv"]))
    end
end

@testset "calibration graph split" begin
    source = fixture_graph()
    result = Calibration.split_graph(source,"classic","fgn","calibration")
    @test Set(keys(result)) == Set(["wfs","command"])
    @test length(result["wfs"]["filter.graph"]["nodes"]) == 2
    @test result["command"]["filter.graph"]["inputs"] == ["pdm-command:requested"]
    @test !haskey(result["wfs"],"pipewireao.feedback.x")
    @test source["node.name"] == "old"
    @test result["wfs"]["node.name"] == "calibration-wfs"
    records = [Dict("role"=>role,"node.name"=>graph["node.name"],
                    "ports"=>Calibration.boundary_contract(graph,"classic",role,"fgn")) for (role,graph) in result]
    session = Calibration.calibration_session(records,"classic","fgn","10/1")
    @test length(session["links"]) == 8
    @test session["execution"] == "complete-frame"
    @test session["sinks"][end]["node.name"] == "calibration-raw"
    bad = fixture_graph()
    push!(bad["filter.graph"]["nodes"],deepcopy(bad["filter.graph"]["nodes"][2]))
    @test_throws ArgumentError Calibration.split_graph(bad,"classic","fgn","bad")
    @test_throws ArgumentError Calibration.validate_capture_budget("classic",0,true)
    @test_throws ArgumentError Calibration.validate_capture_budget("classic",250252,false)
    @test Calibration.validate_capture_budget("classic",250252,true) === nothing
    @test occursin("filter.graph",Calibration.spa_json(result["wfs"]))
end

@testset "owner argument safety" begin
    @test Calibration.julia_pin_cpu_arguments(["julia","--pin-cpus","14,10"]) == ["--pin-cpus","14,10"]
    @test_throws ArgumentError Calibration.julia_pin_cpu_arguments(["julia","--pin-cpus","14","--pin-cpus=10"])
    @test_throws ArgumentError Calibration.julia_pin_cpu_arguments(["julia","--pin-cpus"])
end

@testset "HEART bridge contracts" begin
    @test Heart.readout_interval("classic",nothing,10) == 0
    @test Heart.readout_interval("copper",nothing,10) == 2000
    @test_throws ArgumentError Heart.readout_interval("copper",95_000,10)
    @test_throws ArgumentError Heart.readout_interval("copper",1<<62,4)
    @test_throws ArgumentError Heart.readout_interval("copper",-1,4)
    session = Heart.bridge_session("classic",10)
    @test session["execution"] == "external-rtc"
    @test isempty(session["graphs"])
    @test session["sources"][1]["ports"][1]["shape"] == [352,352]
    @test session["sources"][2]["ports"][1]["shape"] == [277]
    @test session["links"][2]["output"] == "heart-dm-source:command"
    source = read(joinpath(ExportFixture.package_root(),"assets/ryzen-6800h-classic.cpu"),String)
    mapped = Heart._cpu_map(source)
    @test occursin("HOP0.wfs.w = { 4 }",mapped)
    @test occursin("WCC.dm0.w = { 14 }",mapped)
    @test_throws ArgumentError Heart._cpu_map("HOP0.wfs.w = { 4 }\n")
end

# These portable fixture methods replace external dependency installation and
# scientific calibration only. Export validation, argument construction,
# package copying, model-period conversion and provenance writing stay real.
function HIL._checked(argv::Vector{String}; timeout=1800)
    return (; returncode=0, stdout="fixture dependency preparation", stderr="")
end
function HIL.simulated_calibration(package::String, specification::AbstractDict,
        provenance::AbstractDict, prefix::String, executable::String, dark_frames::Int)
    return Dict("fixture"=>true, "dark_frames"=>dark_frames)
end

@testset "sustained HIL exporter preserves effective pacing provenance" begin
    mktempdir() do root
        base = joinpath(root, "recorded-base")
        mkpath(joinpath(base, "graphs"))
        ExportFixture.Common.write_json(joinpath(base, "graphs/graph.conf.in"), fixture_graph())
        port(name) = Dict("name"=>name, "rate"=>"500/1")
        session = Dict("execution"=>"complete-frame", "rate"=>"500/1",
            "sources"=>[Dict("node.name"=>"recorded-source", "ports"=>[port("output")])],
            "graphs"=>[Dict("node.name"=>"science", "ports"=>[port("input"), port("output")])],
            "sinks"=>[Dict("node.name"=>"recorded-sink", "ports"=>[port("input")])],
            "links"=>[Dict("output"=>"recorded-source:output", "input"=>"science:input"),
                Dict("output"=>"science:output", "input"=>"recorded-sink:input")],
            "execution-groups"=>[Dict("nodes"=>["recorded-source", "science", "recorded-sink"])])
        ExportFixture.Common.write_json(joinpath(base, "session.conf.in"), session)
        ExportFixture.Common.write_json(joinpath(base, "provenance.json"),
            Dict("mode"=>"frame", "profile"=>"classic", "engine"=>"fgn", "parameters"=>Any[]))
        core = Dict("context.properties"=>Dict("context.data-loops"=>[
            Dict("loop.name"=>name) for name in ("rtc-data-loop", "source-loop", "sink-loop")]))
        ExportFixture.Common.write_json(joinpath(base, "core.conf.in"), core)
        specification = Dict("owners"=>Any[], "core"=>"core.conf.in",
            "placement"=>Dict{String,Any}(), "client"=>Dict{String,Any}())
        ExportFixture.Common.write_json(joinpath(base, "deployment.conf"), specification)
        packages = Dict{String,String}()
        for name in ("AdaptiveOpticsCalibration", "AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL",
                     "PipeWireAO", "FilterGraphAlgorithms", "REVOLTClassicSim")
            path = joinpath(root, "sources", name)
            mkpath(joinpath(path, "src"))
            write(joinpath(path, "Project.toml"), "name = \"$name\"\n")
            write(joinpath(path, "src", name * ".jl"), "module $name end\n")
            packages[name] = path
        end
        plant = packages["REVOLTClassicSim"]
        mkpath(joinpath(plant, "graphs"))
        write(joinpath(plant, "graphs/revolt_classic_hil_grid_gaussian.toml"), """
            [[nodes]]
            name = "atmosphere"
            [nodes.config]
            atmosphere_step = 0.002
            [[nodes]]
            name = "detector"
            [nodes.config]
            exposure_duration_s = 0.001896
            bits = 12
            """)
        arguments = (; base_package=base, output=joinpath(root, "candidate"), pipewire_prefix="/unused",
            backend="cpu", rate_hz=500, frames=256, dark_frames=1, total_exchanges=1024,
            aos_root=packages["AdaptiveOpticsSim"], aoc_root=packages["AdaptiveOpticsCalibration"],
            adapter_root=packages["AdaptiveOpticsSimPipeWireHIL"], pipewireao_jl_root=packages["PipeWireAO"],
            calibration_algorithms_root=packages["FilterGraphAlgorithms"], plant_root=plant)
        argument(argv, option) = argv[only(findall(==(option), argv)) + 1]
        for (wall_rate, effective) in (("default", 500), ("100", 100), ("unpaced", 0))
            output = joinpath(root, "export-" * wall_rate)
            @test HIL.export_package(merge(arguments, (; output, wall_rate))) == joinpath(output, "deployment.conf")
            metadata = ExportFixture.Common.read_json(joinpath(output, "provenance.json"))["hil"]
            deployment = ExportFixture.Common.read_json(joinpath(output, "deployment.conf"))
            owner = only(filter(owner -> owner["role"] == "simulator", deployment["owners"]))
            @test metadata["wall_rate_hz"] == effective
            @test metadata["model_rate_hz"] == 500 && metadata["model_period_ns"] == 2_000_000
            @test metadata["wall_rate"] == wall_rate
            @test metadata["frames"] == 256 && metadata["total_exchanges"] == 1024
            @test argument(owner["argv"], "--wall-rate") == wall_rate
            @test argument(owner["argv"], "--total-exchanges") == "1024"
            @test argument(owner["argv"], "--frames") == "256"
            @test argument(owner["argv"], "--rate") == "500"
            @test argument(owner["argv"], "--exposure-ns") == "1896000"
            @test HIL.TOML.parsefile(joinpath(output, "hil/plant.toml"))["nodes"][1]["config"]["atmosphere_step"] == 0.002
            @test ExportFixture.Common.read_json(joinpath(output, "session.conf.in"))["rate"] == "500/1"
        end
        # Finite defaults retain their prefix-only owner arguments.
        finite = joinpath(root, "finite")
        HIL.export_package(merge(arguments, (; output=finite, frames=16, total_exchanges=16)))
        metadata = ExportFixture.Common.read_json(joinpath(finite, "provenance.json"))["hil"]
        owner = only(ExportFixture.Common.read_json(joinpath(finite, "deployment.conf"))["owners"])
        @test metadata["wall_rate_hz"] == metadata["model_rate_hz"] == 500
        @test metadata["frames"] == metadata["total_exchanges"] == 16
        @test !("--total-exchanges" in owner["argv"]) && !("--wall-rate" in owner["argv"])
        for total in (0, 255, 65537, true, 1024.0)
            @test_throws ArgumentError HIL.export_package(merge(arguments, (; total_exchanges=total)))
        end
        for rate in ("0", "501", "-1", "100.5", "fast", "999999999999999999999999", 100, true)
            @test_throws ArgumentError HIL.export_package(merge(arguments, (; wall_rate=rate)))
        end
        @test_throws ArgumentError HIL.export_package(merge(arguments, (; total_exchanges=256, wall_rate="unpaced")))
        @test_throws ArgumentError HIL.export_package(merge(arguments, (; rate_hz=501)))
        @test !ispath(arguments.output)
    end
end
