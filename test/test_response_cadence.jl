# Optional AOS/HIL contract selector: no optical preparation or native core.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
const AG=AdaptiveOpticsSim.AlgorithmGraphs
const X=Base.get_extension(PipeWireAORTC,:PipeWireAORTCAOSExt)
@testset "response cadence admission" begin
    config=AG.second_order_response_node(:response;natural_frequency_hz=250,
        damping_ratio=0.7,sample_period_s=0.0005,count=2,schema="test/stage-opd-f32/1").config
    @test X.validate_sample_period(config,0.0005)===nothing
    @test_throws ArgumentError X.validate_sample_period(config,0.001)
    @test X.validate_node_timing(config,(;period_ns=500000))===nothing
    @test_throws ArgumentError X.validate_node_timing(config,(;period_ns=1000000))
end

@testset "configured response precedes its optical consumer" begin
    K=PipeWireAORTC.InstrumentConfiguration
    schema="test/stage-opd-f32/1"
    node=Dict("name"=>"stage","type"=>"modal_opd_expansion_f32","config"=>Dict(
        "pupil_rows"=>2,"pupil_columns"=>2,"mode_count"=>2,
        "coefficients_schema"=>schema,"opd_schema"=>"test/opd-f32/1",
        "basis_schema"=>"test/basis-f32/1","pupil_support_schema"=>"test/support/1"))
    document=Dict("responses"=>Dict("command"=>Dict("kind"=>"second_order",
        "natural_frequency_hz"=>250,"damping_ratio"=>0.7,"schema"=>schema)),
        "frame_period_s"=>0.0005,"bindings"=>Dict("command"=>Dict(
            "kind"=>"zeros","type"=>"Float32","shape"=>[2])))
    instrument=(;document=Dict("deformable_mirrors"=>Dict(),"wavefront_sensors"=>Dict()),directory=".")
    declaration=(;document,instrument)
    graph=Dict{String,Any}("schema_version"=>1,"name"=>"response_optics","nodes"=>[node],
        "inputs"=>[Dict("name"=>"command","binding"=>"command","destination"=>"stage.coefficients")],
        "parameters"=>[Dict("binding"=>"basis","destination"=>"stage.basis"),
            Dict("binding"=>"pupil","destination"=>"stage.pupil_support")],
        "outputs"=>[Dict("name"=>"frame","source"=>"stage.opd")])
    K.apply_responses!(graph,declaration,Dict{String,Any}())
    @test [n["name"] for n in graph["nodes"]]==["command_response","stage"]
    input=Float32[1e-6,-0.5e-6]
    basis=reshape(Float32.(1:8),2,2,2)
    prepared=AG.prepare_algorithm_graph(AG.load_algorithm_graph(graph;
        bindings=(command=input,basis,pupil=fill(true,2,2))))
    AG.step_graph!(prepared)
    response=AG.prepared_graph_node(prepared,:command_response).prepared
    optical=AG.prepared_graph_node(prepared,:stage)
    @test optical.coefficients === response.output
    @test AG.graph_output(prepared,:frame) ≈
        basis[:,:,1].*response.output[1].+basis[:,:,2].*response.output[2]
    AG.reset_graph!(prepared)
    @test all(iszero,response.state.position) && all(iszero,response.state.velocity)
end
