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
