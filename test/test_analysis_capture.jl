using Test, PipeWireAORTC
using PipeWireAORTC.Artifacts: FITS

const A = PipeWireAORTC.Analysis
const CS = PipeWireAORTC.ConfigurationStore

function declaration()
    Dict("label"=>"Reference gradients", "scope"=>Dict("session_label"=>"test", "graph"=>"control", "parameter"=>"reference-slopes"),
        "products"=>Dict("mean"=>"mean", "variance"=>"variance", "stddev"=>"stddev"),
        "units"=>Dict("mean"=>"pixel", "variance"=>"pixel^2", "stddev"=>"pixel"),
        "sample-count"=>"sample-count", "complete"=>"complete", "variance-valid"=>"variance-valid")
end
function formats()
    image(schema) = (;element_type=Float32, shape=(2,3), schema)
    status(type) = (;element_type=type, shape=(1,), schema="status")
    (;mean=image("reference"), variance=image("variance"), stddev=image("stddev"),
        var"sample-count"=status(UInt64), complete=status(Bool), var"variance-valid"=status(Bool))
end
function graph_document(;mode="finite")
    Dict("filter.graph"=>Dict("nodes"=>[Dict("name"=>"statistics","label"=>"array-statistics-f32",
        "config"=>Dict("mode"=>mode,"window_samples"=>3))],
        "outputs"=>Any["statistics:"*name for name in ("mean","variance","stddev","sample-count","complete","variance-valid")]))
end
configuration() = A.capture_contract(A.capture_configuration(declaration()),graph_document())
function frame(count, sequence; complete=count==3, identity=true, generation=UInt64(1),
        domain=ntuple(_->UInt8(1),16), corrupted=false, discontinuity=false)
    output = (;mean=fill(2f0,2,3),variance=fill(1f0,2,3),stddev=fill(1f0,2,3),
        var"sample-count"=UInt64[count], complete=Bool[complete], var"variance-valid"=Bool[count>=2])
    header = (;sequence=UInt64(sequence), offset=UInt32(0), corrupted, discontinuity,
        has_acquisition_identity=identity, acquisition_identity=(;domain,generation))
    return output, map(_ -> (;present=true,value=header), output)
end
function completed()
    capture = A.prepare_capture(configuration(), formats())
    for (n,s) in ((1,10),(2,12),(3,14))
        capture(Val(:frame), frame(n,s)...)
    end
    capture
end

@testset "finite analysis capture configuration" begin
    config = configuration()
    @test config.count === Symbol("sample-count")
    @test config.window_samples == 3
    @test_throws ArgumentError A.prepare_capture(A.capture_configuration(declaration()),formats())
    for mode in ("sliding","exponential")
        @test_throws ArgumentError A.capture_contract(config,graph_document(;mode))
    end
    for endpoint in ("other:complete", "statistics:variance-valid")
        graph=graph_document();graph["filter.graph"]["outputs"][5]=Dict("name"=>"complete","endpoint"=>endpoint)
        @test_throws ArgumentError A.capture_contract(config,graph)
    end
    for invalid in (merge(declaration(), Dict("extra"=>1)),
        merge(declaration(), Dict("products"=>Dict("mean"=>"complete"))),
        merge(declaration(), Dict("units"=>Dict("mean"=>"pixel"))),
        merge(declaration(), Dict("scope"=>Dict("parameter"=>12))),
        merge(declaration(), Dict("label"=>"invalid\n")))
        @test_throws ArgumentError A.capture_configuration(invalid)
    end
    @test_throws ArgumentError A.prepare_capture(config, (;mean=formats().mean))
    @test_throws ArgumentError A.prepare_capture(config, merge(formats(), (;mean=(;element_type=Float64,shape=(2,3),schema="reference"))))
    @test_throws DimensionMismatch A.prepare_capture(config, merge(formats(), (;mean=(;element_type=Float32,shape=(3,2),schema="reference"))))
end

@testset "immutable completed snapshot and shared artifact roundtrip" begin
    capture = completed()
    @test capture.ready[] == 1
    @test capture.count == 3
    @test capture.sequence_gaps == 2
    @test capture.first_sequence == 10
    @test capture.last_sequence == 14
    output, metadata = frame(4,15)
    fill!(output.mean, 17)
    capture(Val(:frame), output, metadata)
    capture(Val(:reset))
    @test all(==(2),capture.buffers.mean)
    @test capture.count == 3
    mktempdir() do root
        store = CS.Store(joinpath(root,"store"))
        records = A.register_capture!(store,capture;source=[Dict("node"=>"wfs","port"=>"slopes")],graph_sha256="measured-graph")
        @test Set(keys(records)) == Set(["mean","variance","stddev"])
        @test length(CS.list_artifacts(store)["items"]) == 3
        for product in keys(capture.buffers)
            record = records[String(product)]
            manifest = record["manifest"]
            @test manifest["metadata"]["sample_count"] == 3
            @test manifest["metadata"]["source_sequence_gaps"] == 2
            @test manifest["metadata"]["acquisition_generation"] == 1
            @test manifest["schema"] == getproperty(capture.schemas,product)
            @test manifest["scope"]["parameter"] == "reference-slopes"
            @test manifest["preparation"]["BUNIT"] == capture.configuration.units[product]
            FITS(CS.read_artifact(store,record["id"])) do fits
                @test read(fits[1]) == getproperty(capture.buffers,product)
                @test size(read(fits[1])) == (2,3)
            end
        end
        # The catalog registration has no scientific application side effect.
        @test isempty(CS.history(store)["items"])
        boundary=CS.register!(store,Float32[1];label="Exact BUNIT boundary",scope="test",units=repeat("x",68))
        @test boundary["manifest"]["preparation"]["BUNIT"] == repeat("x",68)
        for units in ("", "bad\nunit", "µm", repeat("x",69), "pixel ", " pixel", repeat("x",67)*"'", 1)
            @test_throws ArgumentError CS.register!(store,Float32[1];label="Invalid units",scope="test",units)
        end
    end
    mktempdir() do root
        store=CS.Store(root)
        records=Dict{String,Any}()
        attempts=Ref(0)
        check() = (attempts[]+=1; attempts[]>1 && error("cancelled between registrations"))
        @test_throws ErrorException A.register_capture!(store,capture;
            source="wfs",graph_sha256="graph",records,check)
        @test Set(keys(records)) == Set(["mean"])
        @test length(CS.list_artifacts(store)["items"]) == 1
    end
end

@testset "incomplete and mixed acquisitions never become artifacts" begin
    config = configuration()
    for bad in (:generation,:domain,:identity,:sequence,:count,:reset,:invalidated,:corrupted,:discontinuity,:absent,:unmatched,:nonfinite,:premature)
        capture = A.prepare_capture(config,formats())
        capture(Val(:frame),frame(1,10)...)
        if bad in (:reset,:invalidated)
            capture(Val(bad))
        else
            output, metadata = bad === :generation ? frame(2,11;generation=UInt64(2)) :
                bad === :domain ? frame(2,11;domain=ntuple(_->UInt8(2),16)) :
                bad === :identity ? frame(2,11;identity=false) :
                bad === :sequence ? frame(2,10) :
                bad === :count ? frame(3,11) :
                bad === :corrupted ? frame(2,11;corrupted=true) :
                bad === :discontinuity ? frame(2,11;discontinuity=true) : frame(2,11;complete=true)
            bad === :absent && (metadata=merge(metadata,(;var"sample-count"=(;present=false,value=metadata.mean.value))))
            bad === :unmatched && (metadata=merge(metadata,(;mean=frame(2,12)[2].mean)))
            if bad === :nonfinite
                output, metadata = frame(2,11;complete=false)
                capture(Val(:frame),output,metadata)
                output,metadata=frame(3,12)
                output.mean[1]=NaN32
            end
            capture(Val(:frame),output,metadata)
        end
        @test capture.ready[] == 2
        mktempdir() do root
            store = CS.Store(root)
            @test_throws ArgumentError A.register_capture!(store,capture;source="wfs",graph_sha256="graph")
            @test isempty(CS.list_artifacts(store)["items"])
        end
    end
    capture = A.prepare_capture(config,formats())
    capture(Val(:reset)) # Startup reset before any frames is allowed.
    @test capture.ready[] == 0
    mktempdir() do root
        path=joinpath(root,"graph.conf");write(path,"test graph")
        run=A.Config(path,"capture",1//1,A.LinkSpec[],Dict{String,Dict{String,String}}(),config)
        report=A.capture_artifacts(run,capture,Ref(true);root=joinpath(root,"store"),runtime=root)
        @test report["state"] == "incomplete"
        @test !ispath(joinpath(root,"store"))
        @test isfile(joinpath(root,"capture-capture.json"))
    end
end
