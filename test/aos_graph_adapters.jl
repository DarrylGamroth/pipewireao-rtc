# Optional CPU integration: RTC composes the AOS builtins without implementing them.
using Test, PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs

@testset "RTC delegates detector layout to the AOS builtin factory" begin
    extension = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt)
    builtin = builtin_graph_node_types()
    registry = extension.configured_graph_node_types()
    @test keys(registry) == keys(builtin)
    @test registry.detector_frame_layout_f32 === builtin.detector_frame_layout_f32
    mktempdir() do directory
        configured = extension.configured_graph_node_types(directory)
        @test configured.detector_frame_layout_f32 === builtin.detector_frame_layout_f32
        @test configured.compiled_optical_paths_f32.directory == directory
    end
    input = reshape(Float32.(1:6), 2, 3)
    document = Dict(
        "schema_version" => 1,
        "name" => "detector_layout",
        "nodes" => [
            Dict(
                "name" => "layout",
                "type" => "detector_frame_layout_f32",
                "config" => Dict(
                    "input_size" => [2, 3],
                    "output_size" => [5, 7],
                    "origin" => [1, 2],
                    "scale" => 2,
                    "bias" => 0.5,
                    "range" => [0, 16383],
                    "rounding" => "nearest_even",
                    "output_element_type" => "uint16",
                    "input_schema" => "test.detector-electrons.f32/1",
                    "output_schema" => "test.detector-adc.u16/1",
                ),
            ),
        ],
        "inputs" => [
            Dict(
                "name" => "detector_frame",
                "binding" => "input",
                "destination" => "layout.detector_frame",
            ),
        ],
        "outputs" => [Dict("name" => "frame", "source" => "layout.frame")],
    )
    definition = load_algorithm_graph(document; node_types = registry, bindings = (; input))
    graph = prepare_algorithm_graph(
        definition; target = AdaptiveOpticsSim.Backends.HostComputeDevice()
    )
    step_graph!(graph)
    expected = zeros(UInt16, 5, 7)
    expected[2:3, 3:5] .= round.(UInt16, 2.0f0 .* input .+ 0.5f0)
    @test graph_output(graph, :frame) == expected
end
