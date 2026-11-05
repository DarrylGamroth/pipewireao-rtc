using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, Proper
import AdaptiveOpticsSim.AlgorithmGraphs as AOG

struct OpticalPathFactoryProbe end
(::OpticalPathFactoryProbe)(name, config, props, bindings) =
    (; name, config, props, bindings)
AOG.graph_node_bindings(::OpticalPathFactoryProbe, config::NamedTuple) =
    (Symbol(config.reference),)

@testset "Instrument model paths resolve at construction, retaining portable graph identity" begin
    extension=Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
    mktempdir() do directory
        write(joinpath(directory, "model.yaml"), "schema_version: 1\n")
        factory=extension.InstrumentOpticalPathsFactory(
            OpticalPathFactoryProbe(),
            directory,
        )
        config=(; model_path = "model.yaml")
        result=factory(:optics, config, NamedTuple(), (; reference = ones(Float32, 2, 2)))
        @test result.config.model_path==joinpath(realpath(directory), "model.yaml")
        @test config.model_path=="model.yaml"
        @test AOG.graph_node_bindings(
            factory,
            (; model_path = "model.yaml", reference = "pupil_amplitude"),
        )==(:pupil_amplitude,)
        @test_throws ArgumentError factory(
            :optics,
            (; model_path = joinpath(directory, "model.yaml")),
            NamedTuple(),
        )
        resolved=AOG.graph_node_configuration(
            factory,
            config,
            (; reference = "pupil_amplitude"),
        )
        @test resolved.model_path==config.model_path &&
              resolved.reference=="pupil_amplitude"
    end
end
