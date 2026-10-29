# Opt-in native selector. Owns one private core and ordinary clients; never opens
# installed services or the desktop core. Run with --threads=3 and a compatible
# PIPEWIREAO_PREFIX when the packaged SDK is not the selected native target.
module AnalysisCapturePrivateCoreTests
using Test, PipeWireAORTC, PipeWireAO
using FilterGraphAlgorithms, JuliaFilterGraph, FilterGraphIsland, FilterGraphPipeWire
include("native_control_private_core.jl")
const C=PipeWireAORTC.Common
const CS=PipeWireAORTC.ConfigurationStore
const OUTPUTS=("mean","variance","stddev","sample-count","complete","variance-valid")

function configuration(directory,name; explicit_mean=false)
    graph=Dict("filter.graph"=>Dict("nodes"=>[Dict("type"=>"ndarray","name"=>"statistics",
        "label"=>"array-statistics-f32","config"=>Dict("size"=>[2,2],"mode"=>"finite","window_samples"=>8,
            "input_schema"=>"test/analysis-samples-f32/1","mean_schema"=>"test/analysis-mean-f32/1",
            "variance_schema"=>"test/analysis-variance-f32/1","stddev_schema"=>"test/analysis-stddev-f32/1"))],
        "inputs"=>["statistics:sample"],"outputs"=>["statistics:"*port for port in OUTPUTS],"links"=>[]))
    PipeWireAORTC.ScienceExport.write_spa_config(joinpath(directory,"graph.conf"),graph)
    links=[Dict("output"=>"analysis-test-source:output_1","input"=>name*":sample")]
    explicit_mean && push!(links,Dict("output"=>name*":mean","input"=>"analysis-explicit-mean:in"))
    config=Dict("name"=>name,"graph"=>"graph.conf","rate"=>"1000/1","links"=>links,
        "capture"=>Dict("label"=>"Native finite capture","scope"=>Dict("session_label"=>"native-test",
            "graph"=>"controller","parameter"=>"reference"),
            "products"=>Dict(port=>port for port in ("mean","variance","stddev")),
            "units"=>Dict("mean"=>"adu","variance"=>"adu^2","stddev"=>"adu"),
            "sample-count"=>"sample-count","complete"=>"complete","variance-valid"=>"variance-valid"))
    path=joinpath(directory,"analysis.conf")
    PipeWireAORTC.ScienceExport.write_spa_config(path,config)
    return path
end

function nodes(registry,name; prefix=false)
    filter(find_globals(registry;interface="PipeWire:Interface:Node")) do item
        value=get(item.properties,"node.name","")
        prefix ? startswith(value,name) : value==name
    end
end

function node_properties(loop,registry,original)
    snapshot=Ref{Union{Nothing,NodeInfo}}(nothing)
    node=with_thread_loop_lock(loop) do _
        bind(registry,original,Node;on_info=(_,info)->begin
            (info.change_mask & NODE_CHANGE_PROPERTIES)==0 || (snapshot[]=info)
            nothing
        end)
    end
    try
        wait_proof(10,"copied node properties") do
            with_thread_loop_lock(_ -> snapshot[]!==nothing,loop)
        end
        return with_thread_loop_lock(loop) do _
            info=something(snapshot[])
            info.id==original.id && info.properties["object.serial"]==original.properties["object.serial"] ||
                error("test node identity changed")
            copy(info.properties)
        end
    finally
        with_thread_loop_lock(_ -> close(node),loop)
    end
end

function acquire(core,registry,loop,source,remote,directory,name;explicit_mean=false,reject=false)
    stage=joinpath(directory,name);mkpath(stage)
    path=configuration(stage,name;explicit_mean)
    log_path=joinpath(stage,"analysis.log")
    receipt_path=joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"],name*"-capture.json")
    state=joinpath(stage,"state")
    log=open(log_path,"w+")
    child=nothing
    explicit=nothing
    try
        if explicit_mean
            explicit=with_thread_loop_lock(loop) do _
                create_object(core,"spa-node-factory",Node;properties=Dict("factory.name"=>"api.pipewireao.discard",
                    "node.name"=>"analysis-explicit-mean","node.virtual"=>"true","node.want-driver"=>"true","object.linger"=>"false"))
            end
        end
        command=`$(Base.julia_cmd()) --startup-file=no --threads=3 --project=$(dirname(Base.active_project())) -e 'using PipeWireAORTC; exit(PipeWireAORTC.Analysis.main(ARGS))' -- --config $path --remote $remote`
        child=run(pipeline(addenv(command,"XDG_STATE_HOME"=>state);stdout=log,stderr=log);wait=false)
        wait_proof(180,"finite analysis readiness";check=()->begin
            Base.process_exited(child) && error("analysis exited before input")
        end) do
            occursin("PIPEWIREAO_ANALYSIS_READY",read(log_path,String))
        end
        roundtrip(registry)
        consumers=nodes(registry,name*".discard.";prefix=true)
        @test length(consumers)==(explicit_mean ? 5 : 6)
        @test node_properties(loop,registry,only(nodes(registry,"analysis-test-source")))["node.loop.name"]=="telemetry-loop"
        @test all(item->get(node_properties(loop,registry,item),"node.loop.name",nothing)=="telemetry-loop",consumers)
        @test length(nodes(registry,name))==1
        # Constant input makes the accepted-frame mean known even if ordinary
        # native scheduling drops input exposures. Deliberately invalid Header
        # metadata exercises rejection and automatic exit without registration.
        sequence=UInt64(0)
        while !isfile(receipt_path) && !Base.process_exited(child) && sequence<80
            sequence+=1
            flags=reject ? SPA.META_HEADER_FLAG_DISCONT : UInt32(0)
            header=BufferHeader(flags,UInt32(0),Int64(sequence*1_000_000),Int64(0),sequence)
            token=submit_array!(source,fill(7f0,4),header)
            try
                wait_array_source!(source,token;timeout_ns=2_000_000_000)
            catch
                # The consumer closes as soon as its window ends. A publication
                # racing that close need not complete, but the acquisition must.
                wait_proof(() -> Base.process_exited(child),10,"analysis exit after source withdrawal")
                break
            end
            sleep(0.02)
        end
        wait_proof(() -> Base.process_exited(child),30,"finite analysis completion")
        wait(child)
        @test success(child)
        @test isfile(receipt_path)
        receipt=C.read_json(receipt_path)
        @test receipt["state"]==(reject ? "rejected" : "registered")
        roundtrip(registry)
        @test isempty(nodes(registry,name*".discard.";prefix=true))
        @test isempty(nodes(registry,name))
        if explicit_mean
            @test length(nodes(registry,"analysis-explicit-mean"))==1
            @test get(node_properties(loop,registry,only(nodes(registry,"analysis-explicit-mean"))),"node.loop.name",nothing)!="telemetry-loop"
        end
        if reject
            @test receipt["reason"]=="invalid_metadata"
            @test !haskey(receipt,"artifacts")
        else
            mean=receipt["artifacts"]["mean"]
            @test mean["manifest"]["metadata"]["sample_count"]==8
            @test mean["manifest"]["preparation"]["BUNIT"]=="adu"
            store=CS.Store(joinpath(state,"pipewireao/configuration"))
            PipeWireAORTC.Artifacts.FITS(CS.read_artifact(store,mean["id"])) do fits
                @test read(fits[1])==fill(7f0,2,2)
            end
            @test isempty(CS.history(store)["items"])
        end
    catch
        flush(log)
        for line in last(split(read(log_path,String),'\n'),30)
            println(stderr,first(line,min(length(line),400)))
        end
        rethrow()
    finally
        child===nothing || stop_proof_child!(child,"finite analysis child")
        explicit===nothing || with_thread_loop_lock(_ -> close(explicit),loop)
        close(log)
    end
end

@testset "finite native capture owns unused outputs, exits and registers after run" begin
    prefix=get(ENV,"PIPEWIREAO_PREFIX",String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir))
    libdir=isdir(joinpath(prefix,"lib/x86_64-linux-gnu")) ? joinpath(prefix,"lib/x86_64-linux-gnu") : joinpath(prefix,"lib")
    isdir(joinpath(libdir,"spa-ao-0.2/discard")) ||
        error("native capture selector requires the discard plugin; set PIPEWIREAO_PREFIX to a compatible SDK")
    with_control_private_core(;prefix,telemetry_loop=true,modules="{ name = libpipewire-module-spa-node-factory }",
            spa_libraries="api.pipewireao.discard = discard/libspa-pipewireao-discard") do remote,directory,_
        loop=ThreadLoop("analysis.capture.test")
        context,core,registry=with_thread_loop_lock(loop) do _
            context=Context(loop)
            core=CoreConnection(context;properties=Dict("remote.name"=>remote))
            context,core,Registry(core)
        end
        start!(loop)
        source=nothing
        try
            format=NdArrayFormat(NdArray.F32_LE,(2,2);layout=NdArray.ROW_MAJOR,rate=SPA.Fraction(1000,1))
            for (name,explicit_mean,reject) in (("capture-unused",false,false),
                    ("capture-explicit",true,false),("capture-rejected",false,true))
                source=NdArraySource(core,"analysis-test-source",zeros(Float32,4),format;
                    schema="test/analysis-samples-f32/1",properties=Dict("node.loop.name"=>"telemetry-loop"))
                start!(source)
                try
                    acquire(core,registry,loop,source,remote,directory,name;explicit_mean,reject)
                finally
                    close(source)
                    source=nothing
                end
                roundtrip(registry)
            end
        finally
            source===nothing || close(source)
            with_thread_loop_lock(loop) do _
                close(registry);close(core);close(context)
            end
            close(loop)
        end
    end
    # The server intentionally has no discard factory mapping. This exercises
    # native creation failure, automatic quit and the incomplete receipt path,
    # rather than waiting 120s for nodes that cannot be constructed.
    with_control_private_core(;prefix,modules="{ name = libpipewire-module-spa-node-factory }") do remote,directory,_
        loop=ThreadLoop("analysis.capture.missing-factory")
        context,core=with_thread_loop_lock(loop) do _
            context=Context(loop)
            context,CoreConnection(context;properties=Dict("remote.name"=>remote))
        end
        start!(loop)
        format=NdArrayFormat(NdArray.F32_LE,(2,2);layout=NdArray.ROW_MAJOR,rate=SPA.Fraction(1000,1))
        source=NdArraySource(core,"analysis-test-source",zeros(Float32,4),format;schema="test/analysis-samples-f32/1")
        start!(source)
        name="capture-missing-factory"
        path=configuration(directory,name)
        log_path=joinpath(directory,"analysis.log")
        log=open(log_path,"w+")
        child=nothing
        state=joinpath(directory,"state")
        try
            command=`$(Base.julia_cmd()) --startup-file=no --threads=3 --project=$(dirname(Base.active_project())) -e 'using PipeWireAORTC; exit(PipeWireAORTC.Analysis.main(ARGS))' -- --config $path --remote $remote`
            child=run(pipeline(addenv(command,"XDG_STATE_HOME"=>state);stdout=log,stderr=log);wait=false)
            # Cold compilation is included in this bound; endpoint discovery's
            # unchanged 120s timeout cannot satisfy the required early failure.
            wait_proof(() -> Base.process_exited(child),90,"missing native discard factory failure")
            @test !success(child)
            text=read(log_path,String)
            @test occursin("pw_",text) && occursin("failed:",text)
            @test !occursin("endpoint discovery timed out",text)
            receipt=C.read_json(joinpath(ENV["PIPEWIREAO_RUNTIME_DIR"],name*"-capture.json"))
            @test receipt["state"]=="incomplete"
            @test !ispath(joinpath(state,"pipewireao/configuration"))
        finally
            child===nothing || stop_proof_child!(child,"missing-factory analysis child")
            close(log)
            close(source)
            with_thread_loop_lock(loop) do _
                close(core);close(context)
            end
            close(loop)
        end
    end
    @test !any(id->id.name in ("CUDA","AMDGPU","GPUCompiler"),keys(Base.loaded_modules))
end
end
