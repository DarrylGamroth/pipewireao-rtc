# Cold response configuration and graph compilation; no AOS/GPU or live core.
using Test, PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration

@testset "plant response declarations" begin
    response=Dict("kind"=>"second_order", "natural_frequency_hz"=>250,
        "damping_ratio"=>0.7, "schema"=>"test/stage-opd-f32/1")
    doc=Dict("responses"=>Dict("stage"=>response))
    @test IC.validate_responses(doc,Set(["stage"])) === nothing
    @test IC.validate_responses(Dict(),Set{String}()) === nothing
    @test_throws ArgumentError IC.validate_responses(doc,Set(["other"]))
    for name in ("natural_frequency_hz","damping_ratio"), value in (0,-1,NaN,Inf,true)
        bad=deepcopy(doc);bad["responses"]["stage"][name]=value
        @test_throws ArgumentError IC.validate_responses(bad,Set(["stage"]))
    end
    for (key,value) in (("unknown",1),("kind","unrecognised"),("schema",""))
        bad=deepcopy(doc);bad["responses"]["stage"][key]=value
        @test_throws ArgumentError IC.validate_responses(bad,Set(["stage"]))
    end
end

@testset "response compilation preserves boundary and static calibration" begin
    response=Dict("kind"=>"second_order", "natural_frequency_hz"=>250,
        "damping_ratio"=>0.7, "schema"=>"test/stage-opd-f32/1")
    document=Dict("responses"=>Dict("stage"=>response), "frame_period_s"=>0.0005,
        "bindings"=>Dict("stage"=>Dict("kind"=>"zeros","type"=>"Float32","shape"=>[2])),
        "profiles"=>Dict("test"=>Dict("nodes"=>[],"parameters"=>[])), "settings_bindings"=>[])
    graph=Dict{String,Any}("name"=>"optics", "nodes"=>[Dict{String,Any}("name"=>"mirror","type"=>"declared")],
        "inputs"=>[Dict("name"=>"stage","binding"=>"stage","destination"=>"mirror.command")],
        "links"=>[], "outputs"=>[Dict("name"=>"frame","source"=>"mirror.frame")])
    original=deepcopy(graph)
    instrument=(;document=Dict("deformable_mirrors"=>Dict(),"wavefront_sensors"=>Dict()),directory=".")
    declaration=(;document,instrument,graphs=Dict("production"=>graph,"calibration"=>graph))
    configured=Dict("profile"=>"test")
    compiled=IC.graph_document(declaration,configured)
    @test graph==original
    @test only(compiled["inputs"])["name"]=="stage"
    @test only(compiled["inputs"])["destination"]=="stage_response.input"
    @test only(compiled["links"])==Dict("source"=>"stage_response.output","destination"=>"mirror.command")
    node=only(n for n in compiled["nodes"] if n["name"]=="stage_response")
    @test node["type"]=="second_order_response_f32"
    @test node["config"]["count"]==2
    @test node["config"]["sample_period_s"]==document["frame_period_s"]
    @test node["config"]["schema"]==response["schema"]
    calibration=IC.graph_document(declaration,configured;calibration=true)
    @test calibration["nodes"]==original["nodes"]
    @test calibration["inputs"]==original["inputs"]
    @test isempty(calibration["links"])
    delete!(document,"responses")
    ideal=IC.graph_document(declaration,configured)
    @test ideal["nodes"]==original["nodes"]
    @test ideal["inputs"]==original["inputs"]
    document["responses"]=Dict("stage"=>response)
    document["bindings"]["stage"]["shape"]=[2,1]
    @test_throws ArgumentError IC.graph_document(declaration,configured)
    document["bindings"]["stage"]["shape"]=[2]
    push!(graph["nodes"],Dict("name"=>"stage_response","type"=>"declared"))
    @test_throws ArgumentError IC.graph_document(declaration,configured)
end
