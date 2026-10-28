# Cold selector checks only: no accepted calibration substitutes or live core.
using Test, PipeWireAO, PipeWireAORTC
include("managed_session_cal2.jl")
const CAL2=ManagedSessionCAL2

@testset "CAL2 startup checks authored and native correction properties" begin
    graph=Dict("node.name"=>"controller","filter.graph"=>Dict("nodes"=>[
        Dict("name"=>"correction","config"=>Dict("extent"=>8),"props"=>Dict("closed"=>false))]))
    control=CAL2.correction_control(graph,"correction:closed")
    @test control==(graph="controller",node="correction",property="correction:closed")
    graph["filter.graph"]["nodes"][1]["config"]["closed"]=false
    graph["filter.graph"]["nodes"][1]["props"]["closed"]=true
    @test_throws ArgumentError CAL2.correction_control(graph,"correction:closed")
    properties=Dict("result"=>Dict("graph"=>"controller","properties"=>Dict("correction:closed"=>Dict("type"=>"bool","value"=>false))))
    generation=Dict("result"=>Dict("graph"=>"controller","node"=>"correction","requested"=>3,"active"=>3))
    @test CAL2.require_open_snapshot(control,properties,generation)===nothing
    generation["result"]["requested"]=4
    @test_throws ArgumentError CAL2.require_open_snapshot(control,properties,generation)
    generation["result"]["requested"]=3
    properties["result"]["properties"]["correction:closed"]["value"]=true
    @test_throws ArgumentError CAL2.require_open_snapshot(control,properties,generation)
end

@testset "return admission binds native, session and receiving schemas" begin
    native=Dict("schema"=>PipeWireAORTC.Schemas.identifier("requested_pdm_command"))
    declared=deepcopy(native)
    receiver=Dict("schema"=>"pipewireao/requested-pdm-command-opd-m-f32/1")
    @test_throws ArgumentError CAL2.require_return_schema(native,declared,receiver)
    receiver["schema"]=native["schema"]
    @test CAL2.require_return_schema(native,declared,receiver)===nothing
    declared["schema"]="pipewireao/requested-pdm-command-opd-m-f32/1"
    @test_throws ArgumentError CAL2.require_return_schema(native,declared,receiver)
    delete!(native,"schema")
    @test_throws ArgumentError CAL2.require_return_schema(native,receiver,receiver)
end

@testset "reference captures follow prepared endpoints and keep source latency separate" begin
    graph=Dict("node.name"=>"gpi","filter.graph"=>Dict("links"=>[
        Dict("input"=>"reference:reconstructed-residual","output"=>"reconstruction:reconstructed")],
        "outputs"=>[Dict("name"=>name,"endpoint"=>endpoint) for (name,endpoint) in
            (("offset","reference:physical-offset"),("raw","reconstruction:reconstructed"),("compensated","reference:compensated-residual"))]))
    ports=Dict(name=>Dict("element-type"=>"F32_LE","shape"=>[2],"schema"=>"test/residual/1") for name in ("offset","raw","compensated"))
    products=Any[];missing=String[]
    CAL2.reference_products!(products,missing,graph,Dict("outputs"=>ports),Dict("algorithm"=>"reference"),10,Dict("gpi"=>"julia"))
    @test [p.name for p in products]==["adopted-offset","reference-before","reference-after"]
    @test [p.port for p in products]==["offset","raw","compensated"]
    @test isempty(missing)
    pop!(graph["filter.graph"]["outputs"])
    CAL2.reference_products!(Any[],missing,graph,Dict("outputs"=>ports),Dict("algorithm"=>"reference"),10,Dict("gpi"=>"julia"))
    @test length(missing)==1 && occursin("reference:compensated-residual",only(missing))
end

@testset "CAL2 modal captures follow the actual correction input" begin
    graph=Dict("node.name"=>"ll-controller","filter.graph"=>Dict("links"=>[
        Dict("input"=>"correction:input","output"=>"modal-reference:output")],
        "outputs"=>[Dict("name"=>"modal-residual","endpoint"=>"modal-reference:output")]))
    contracts=Dict("outputs"=>Dict("modal-residual"=>Dict("element-type"=>"F32_LE","shape"=>[8],"schema"=>"test/modal-residual/1")))
    products=Any[];missing=String[]
    control=(;node="correction")
    CAL2.modal_product!(products,missing,"llowfs",graph,contracts,control,20,Dict("ll-controller"=>"cal2-llowfs"))
    @test only(products).name=="llowfs-modal-residual" && only(products).shape==(8,)
    @test only(products).port=="modal-residual" && only(products).duration==20
    @test isempty(missing)
    delete!(contracts["outputs"]["modal-residual"],"schema")
    unschematized=Any[]
    CAL2.modal_product!(unschematized,missing,"llowfs",graph,contracts,control,20,Dict("ll-controller"=>"cal2-llowfs"))
    @test isempty(unschematized) && length(missing)==1 && occursin("schema",only(missing))
    @test_throws ArgumentError CAL2.product("required","ll-controller:modal-residual",contracts["outputs"]["modal-residual"],20,Dict("ll-controller"=>"cal2-llowfs"))
    empty!(missing)
    empty!(graph["filter.graph"]["outputs"])
    CAL2.modal_product!(Any[],missing,"llowfs",graph,contracts,control,20,Dict("ll-controller"=>"cal2-llowfs"))
    @test length(missing)==1 && occursin("modal-reference:output",only(missing))
end

@testset "capture schema comes from the prepared native graph output" begin
    mktempdir() do directory
        schema=PipeWireAORTC.Schemas.identifier("controller_residual_error")
        graph=Dict("node.name"=>"controller","filter.graph"=>Dict("nodes"=>[
            Dict("type"=>"ndarray","name"=>"reference","label"=>"vector-offset-f32",
                "config"=>Dict("extent"=>8,"schema"=>schema))],
            "inputs"=>[Dict("name"=>"residual","endpoint"=>"reference:requested"),
                Dict("name"=>"flat","endpoint"=>"reference:offset")],
            "outputs"=>[Dict("name"=>"modal-residual","endpoint"=>"reference:output")]))
        path=joinpath(directory,"graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path,graph)
        contracts=CAL2.graph_output_contracts(path)
        contract=contracts["outputs"]["modal-residual"]
        @test contract["schema"]==schema && contract["shape"]==[8]
        prepared=CAL2.product("modal","controller:modal-residual",contract,20,Dict("controller"=>"owner"))
        @test prepared.schema==schema
        shape_only=Base.invokelatest(CAL2.E.graph_port_contracts,path)["outputs"]["modal-residual"]
        @test !haskey(shape_only,"schema")
        @test_throws ArgumentError CAL2.product("required","controller:modal-residual",shape_only,20,Dict("controller"=>"owner"))
    end
end

@testset "covered vector payloads share receiving frames without claiming nonzero adoption" begin
    names=("physical","adopted-offset","reference-before","reference-after")
    products=map(name->(;name,shape=(2,)),names)
    samples=map(product->CAL2.Samples(product,2),products)
    domain=AcquisitionDomain(ntuple(i->UInt8(i),16))
    before=Float32[1e-6,1e-8]
    for sequence in 1:2
        receipt=(;identity=AcquisitionIdentity(domain,UInt64(1),UInt64(sequence)),pts=10*(sequence-1),duration=10,lost_samples=0,trigger_state=PipeWireAO.ACQUISITION_TRIGGER_ABSENT)
        for (sample,payload) in zip(samples,(Float32[1,2],zeros(Float32,2),before,before))
            CAL2.record!(sample,payload,receipt,10)
        end
    end
    proof=CAL2.zero_reference_proof(products,samples,20)
    @test proof["available"] && proof["receiving_frames"]==2
    @test proof["maximum_absolute_reference_difference"]==0 && !proof["nonzero_adoption_observed"]
    @test occursin("CAL2 exposure/input latency is separate",proof["frame_reference"])
    before.=0
    @test samples[3].history[1]==Float32[1e-6,1e-8]
    samples[4].history[2][1]=nextfloat(samples[3].history[2][1])
    @test_throws ArgumentError CAL2.zero_reference_proof(products,samples,20)
    samples[4].history[2].=samples[3].history[2]
    samples[4].records[2]["sequence"]=3
    @test_throws ArgumentError CAL2.zero_reference_proof(products,samples,20)
    @test !CAL2.zero_reference_proof(products[1:2],samples[1:2],20)["available"]
    receipt=(;identity=AcquisitionIdentity(domain,UInt64(1),UInt64(3)),pts=20,duration=10,lost_samples=0,trigger_state=PipeWireAO.ACQUISITION_TRIGGER_ABSENT)
    @test_throws ArgumentError CAL2.record!(samples[1],zeros(Float32,2),receipt,10)
    image=CAL2.Samples((;shape=(2,2)),2)
    @test image.history===nothing
    @test !any(id->id.name in ("CUDA","AMDGPU","AdaptiveOpticsSim"),keys(Base.loaded_modules))
end
