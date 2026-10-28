# Optional scientific selector: actual JFG statistics through the shared artifact interface.
using Test, PipeWireAORTC, FilterGraphAlgorithms, JuliaFilterGraph, PipeWireAO
using FilterGraphIsland, FilterGraphPipeWire
import FilterGraphAlgorithms: process!
using PipeWireAORTC.Common: JSON
using PipeWireAORTC.Artifacts: FITS

const A = PipeWireAORTC.Analysis
const CS = PipeWireAORTC.ConfigurationStore
const OUTPUTS = (:mean,:variance,:stddev,Symbol("sample-count"),:complete,Symbol("variance-valid"))

function graph_document(mode="finite")
    Dict("filter.graph"=>Dict("nodes"=>[Dict("type"=>"ndarray","label"=>"array-statistics-f32","name"=>"statistics",
        "config"=>Dict("size"=>[2,3],"mode"=>mode,"window_samples"=>3,
            "input_schema"=>"test/samples-f32/1","mean_schema"=>"test/reference-f32/1",
            "variance_schema"=>"test/variance-f32/1","stddev_schema"=>"test/stddev-f32/1"))],
        "links"=>[],"inputs"=>["statistics:sample"],"outputs"=>["statistics:"*String(name) for name in OUTPUTS]))
end
function capture_document()
    Dict("label"=>"Measured reference", "scope"=>Dict("session_label"=>"test", "graph"=>"controller","parameter"=>"reference-slopes"),
        "products"=>Dict("mean"=>"mean","variance"=>"variance","stddev"=>"stddev"),
        "units"=>Dict("mean"=>"pixel","variance"=>"pixel^2","stddev"=>"pixel"),
        "sample-count"=>"sample-count","complete"=>"complete","variance-valid"=>"variance-valid")
end

observer_bytes(capture, outputs, metadata) = @allocated capture(Val(:frame),outputs,metadata)

@testset "headless finite Graph result becomes a catalog artifact" begin
    mktempdir() do root
        graph_path=joinpath(root,"graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(graph_path,graph_document())
        config_path=joinpath(root,"analysis.conf")
        document=Dict("graph"=>"graph.conf","name"=>"statistics-analysis","rate"=>"500/1",
            "links"=>[Dict("output"=>"slopes-observation:capture_1","input"=>"statistics-analysis:sample")],
            "capture"=>capture_document())
        PipeWireAORTC.Common.write_json(config_path,document)
        prefix=String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
        config=A.configuration(config_path,prefix)
        @test config.capture.window_samples == 3
        graph=prepare_graph(graph_path;algorithms=algorithms())
        capture=A.prepare_capture(config.capture,JuliaFilterGraph.output_formats(graph))
        output=map(format->zeros(format.element_type,format.shape),JuliaFilterGraph.output_formats(graph))
        input=(;sample=zeros(Float32,2,3))
        for (i,seq) in enumerate((8,10,14))
            input.sample .= i
            header=SampleMetadata(seq,0;terminal=true,timestamp_nanoseconds=seq*1_000_000)
            @test process!(output,graph,input,(;sample=header)) == map(_->true,output)
            metadata=JuliaFilterGraph.output_metadata(graph)
            capture(Val(:frame),output,metadata)
        end
        @test capture.ready[] == 1
        @test capture.buffers.mean == fill(2f0,2,3)
        @test capture.buffers.variance == ones(Float32,2,3)
        @test capture.sequence_gaps == 4
        store_path=joinpath(root,"store")
        result=A.capture_artifacts(config,capture,Ref(false);root=store_path,runtime=root)
        @test result["state"] == "registered"
        @test isfile(joinpath(root,"statistics-analysis-capture.json"))
        # Same JSON-lines management interface consumed by the GUI helper.
        request=Dict("protocol"=>CS.PROTOCOL,"op"=>"list","root"=>store_path)
        catalog=PipeWireAORTC.ConfigurationStoreCLI.respond(JSON.json(request))
        @test catalog["ok"]
        @test length(catalog["result"]["items"]) == 3
        record=result["artifacts"]["mean"]
        @test record["manifest"]["schema"] == "test/reference-f32/1"
        @test record["manifest"]["scope"] == Dict("session_label"=>"test","graph"=>"controller","parameter"=>"reference-slopes")
        @test record["manifest"]["preparation"]["BUNIT"] == "pixel"
        @test record["manifest"]["metadata"]["sample_count"] == 3
        @test record["manifest"]["metadata"]["source_sequence_gaps"] == 4
        request=Dict("protocol"=>CS.PROTOCOL,"op"=>"get","root"=>store_path,
            "arguments"=>Dict("id"=>record["id"]))
        fetched=PipeWireAORTC.ConfigurationStoreCLI.respond(JSON.json(request))
        @test fetched["ok"]
        @test fetched["result"]["shape"] == [2,3]
        FITS(CS.read_artifact(CS.Store(store_path),record["id"])) do fits
            @test read(fits[1]) == fill(2f0,2,3)
        end
        @test isempty(CS.history(CS.Store(store_path))["items"])
        for mode in ("sliding","exponential")
            PipeWireAORTC.ScienceExport.write_spa_config(graph_path,graph_document(mode))
            @test_throws ArgumentError A.configuration(config_path,prefix)
        end
    end
end

@testset "frame observer has no warmed heap allocation" begin
    config=A.capture_contract(A.capture_configuration(capture_document()),graph_document())
    formats=map(name -> name in (:mean,:variance,:stddev) ? (;element_type=Float32,shape=(2,3),schema="test") :
        (;element_type=name===Symbol("sample-count") ? UInt64 : Bool,shape=(1,),schema="status"), NamedTuple{OUTPUTS}(OUTPUTS))
    output=map(format->zeros(format.element_type,format.shape),formats)
    captures=ntuple(_ -> A.prepare_capture(config,formats),3)
    for i in 1:3
        output[4][1]=i;output.complete[1]=i==3;output[6][1]=i>=2
        header=SampleMetadata(i,0;terminal=true)
        metadata=map(_ -> header,output)
        for capture in captures
            observer_bytes(capture,output,metadata) # Compile identical signatures on other capture owners.
        end
    end
    capture=A.prepare_capture(config,formats)
    for i in 1:3
        output[4][1]=i;output.complete[1]=i==3;output[6][1]=i>=2
        header=SampleMetadata(i,0;terminal=true)
        metadata=map(_ -> header,output)
        @test observer_bytes(capture,output,metadata) == 0
    end
end

@testset "analysis loads typed FITS calibration before Graph execution" begin
    # Exercise the exact preparation entrypoint used by Analysis.run_graph.
    mktempdir() do root
        graph_path = joinpath(root,"graph.conf")
        document = graph_document()
        graph = document["filter.graph"]
        pushfirst!(graph["nodes"],Dict("type"=>"ndarray","name"=>"pixels",
            "label"=>"pixel-calibration-u16-f32","config"=>Dict("image_size"=>[2,3],
                "initial_flat"=>nothing,"initial_background"=>nothing)))
        graph["nodes"][2]["config"]["input_schema"] = PipeWireAORTC.Schemas.CATALOG["calibrated_pixels"]["id"]
        graph["inputs"] = ["pixels:raw","pixels:background","pixels:flat"]
        graph["links"] = [Dict("output"=>"pixels:calibrated","input"=>"statistics:sample")]
        PipeWireAORTC.ScienceExport.write_spa_config(graph_path,document)
        background = Float32[1 3 5; 2 4 6]
        flat = fill(2f0,2,3)
        for (name,array) in (("background",background),("flat",flat))
            PipeWireAORTC.InstrumentCalibration.write_fits(joinpath(root,name*".fits"),array)
        end
        C = PipeWireAORTC.Common
        C.write_json(joinpath(root,"parameters.conf"),Dict("parameters"=>[
            Dict("port"=>name,"path"=>name*".fits","axes"=>[2,1]) for name in ("background","flat")]))
        config_path=joinpath(root,"analysis.conf")
        C.write_json(config_path,Dict("graph"=>"graph.conf","fits-bindings"=>"parameters.conf",
            "name"=>"calibrated-analysis","rate"=>"500/1","links"=>[]))
        config=A.configuration(config_path,String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir))
        prepared=A.prepare_graph(config,"/tmp/unused-private-socket")
        try
            outputs=map(f->zeros(f.element_type,f.shape),JuliaFilterGraph.output_formats(prepared.graph))
            @test JuliaFilterGraph.input_formats(prepared.graph).raw.element_type === UInt16
            @test all(values(process!(outputs,prepared.graph,(raw=fill(UInt16(10),2,3),))))
            @test outputs.mean == 2f0 .* (10f0 .- background)
        finally
            FilterGraphIsland.close_execution(prepared.graph)
        end
        PipeWireAORTC.InstrumentCalibration.write_fits(joinpath(root,"flat.fits"),ones(Float32,3,2))
        @test_throws DimensionMismatch A.prepare_graph(config,"/tmp/unused-private-socket")
    end
end
