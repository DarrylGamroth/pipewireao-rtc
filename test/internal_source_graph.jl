# Optional cold selector; instrument data is separate from the shared package.
module InternalSourceGraphTests
using Test, SHA, PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration

@testset "Classic internal source preserves production detector and RTC inputs" begin
    root = ENV["PIPEWIREAORTC_INTERNAL_SOURCE_INSTRUMENT"]
    files = [joinpath(root,"rtc","graph-template.conf"),
        joinpath(root,"simulation","definition.yaml"),
        joinpath(root,"simulation","internal-source.yaml")]
    before = map(path -> sha256(read(path)),files)
    declaration = IC.load_simulation(joinpath(root,"simulation","definition.yaml"))
    settings = IC.settings(declaration,Dict("pupil_resolution"=>480))
    production = IC.graph_document(declaration,settings)
    internal = IC.graph_document(declaration,settings;simulation_graph="internal-source")
    ideal = IC.graph_document(declaration,settings;calibration=true)
    detector(graph) = only(node for node in graph["nodes"] if node["name"] == "detector")
    @test detector(internal) == detector(production)
    @test detector(internal)["config"]["photon_noise"]
    @test detector(internal)["config"]["readout_noise"]
    @test detector(internal)["config"]["bits"] == 12
    @test detector(ideal)["config"]["photon_noise"] === false
    @test any(node -> node["name"] == "atmosphere",production["nodes"])
    @test all(node -> node["name"] != "atmosphere",internal["nodes"])
    @test any(input -> input["binding"] == "uncompensated_opd" &&
        input["destination"] == "pupil_opd_composition.uncompensated_opd",internal["inputs"])
    @test declaration.document["bindings"]["uncompensated_opd"]["kind"] == "zeros"
    @test declaration.document["bindings"]["uncompensated_opd"]["type"] == "Float32"
    @test declaration.document["sources"]["guide"]["source_magnitude"] == 2
    @test declaration.document["sources"]["guide"]["source_wavelength_m"] == 8e-7
    @test_throws ArgumentError IC.graph_document(declaration,settings;simulation_graph="absent")
    @test_throws ArgumentError IC.graph_document(declaration,settings;simulation_graph=1)
    @test_throws ArgumentError IC.graph_document(declaration,settings;calibration=true,simulation_graph="internal-source")
    @test map(path -> sha256(read(path)),files) == before
    @test !any(id.name in ("CUDA","AMDGPU") for id in keys(Base.loaded_modules))
end
end
