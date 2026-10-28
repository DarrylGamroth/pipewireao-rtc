# Cold, generic graph relationships; no instrument names or live services.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper
const RELAY_EXT = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
function relay_preparation_fixture()
    source = Dict("name"=>"optics", "type"=>"proper_optical_train_f32", "config"=>Dict(
        "resolution"=>16, "pupil_resolution"=>8, "diameter_m"=>0.04,
        "wavelength_um"=>0.75, "steps"=>[], "output_quantity"=>"electric_field",
        "output_schema"=>"test.relative-field/1"))
    receiver = Dict("name"=>"sensor", "type"=>"pyramid_rate_f32", "config"=>Dict(
        "resolution"=>8, "telescope_diameter_m"=>8.0, "source_wavelength_m"=>750e-9,
        "input_quantity"=>"electric_field", "field_schema"=>"test.receiving-field/1"))
    relay = Dict("name"=>"relay", "type"=>"ideal_pupil_relay_f32", "config"=>Dict("axes"=>[2,1]),
        "preparation"=>Dict("kind"=>"ideal_pupil_relay", "source"=>"optics", "destination"=>"sensor"))
    return Dict("nodes"=>[source,relay,receiver], "links"=>[
        Dict("source"=>"optics.output", "destination"=>"relay.input"),
        Dict("source"=>"relay.output", "destination"=>"sensor.electric_field")])
end
@testset "Ideal pupil relay derives grids from connected declarations" begin
    graph = relay_preparation_fixture()
    relay = graph["nodes"][2]
    RELAY_EXT.prepare_ideal_pupil_relay!(relay,graph)
    @test !haskey(relay,"preparation")
    @test relay["config"]["input_size"] == [16,16]
    @test relay["config"]["output_size"] == [8,8]
    @test relay["config"]["input_sampling_m"] ≈ [0.005,0.005]
    @test relay["config"]["output_sampling_m"] == [1.0,1.0]
    @test relay["config"]["wavelength_m"] ≈ 750e-9
    @test relay["config"]["input_schema"] == "test.relative-field/1"
    @test relay["config"]["output_schema"] == "test.receiving-field/1"
    default_schema = relay_preparation_fixture()
    delete!(default_schema["nodes"][1]["config"], "output_schema")
    RELAY_EXT.prepare_ideal_pupil_relay!(default_schema["nodes"][2],default_schema)
    @test default_schema["nodes"][2]["config"]["input_schema"] ==
        "org.adaptiveopticssim.electric-field/1"
    for change in (
        g->(g["nodes"][3]["config"]["source_wavelength_m"]=800e-9),
        g->empty!(g["links"]),
        g->(g["nodes"][1]["config"]["output_quantity"]="intensity"),
        g->(g["nodes"][2]["type"]="ideal_pupil_relay_f64"),
        g->(g["nodes"][2]["config"]["input_size"]=[16,16]))
        invalid = relay_preparation_fixture()
        change(invalid)
        @test_throws ArgumentError RELAY_EXT.prepare_ideal_pupil_relay!(invalid["nodes"][2],invalid)
    end
end
