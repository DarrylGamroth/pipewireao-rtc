# Real CPU WFS/Node constructor regression; no core, service or device is opened.
using Test, PipeWireAORTC, PipeWireAO
using FilterGraphAlgorithms, JuliaFilterGraph, FilterGraphIsland, FilterGraphPipeWire

const E = Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt)

@testset "ordinary WFS analysis reaches native connection with synchronized inputs" begin
    mktempdir() do directory
        path = joinpath(directory, "graph.conf")
        write(
            path,
            """
    filter.graph = {
        nodes = [ { type = ndarray name = wfs label = shack-hartmann-summary-f32
                    config = { subaperture_count = 2 } } ]
        inputs = [ "wfs:slopes" "wfs:flux" "wfs:validity" ]
        outputs = [ "wfs:summary" ]
    }
    """,
        )
        options = FilterGraphIsland.parse_arguments(["--graph", path, "--check"])
        graph = FilterGraphIsland.prepare_service_graph(
            options; declarations = FilterGraphIsland.algorithm_declarations(options)
        )
        try
            owner = E.analysis_input_owner(graph)
            @test owner isa JuliaFilterGraph.PreparedSynchronizedInputs
            @test length(JuliaFilterGraph.input_formats(graph)) == 3
            config = (;
                name = "wfs-analysis-constructor-test",
                capture = nothing,
                rate = 500//1,
                channel_units = NamedTuple(),
            )
            # The absent private socket bounds the production path at connect!.
            # A native connection error proves the actual synchronized Node was
            # constructed; the old keyword dispatch fails before that boundary.
            failure = try
                E.run_analysis_graph(
                    config,
                    joinpath(directory, "absent.sock"),
                    graph,
                    options.boundary_layout,
                    "unused-graph-digest",
                )
                nothing
            catch error
                error
            end
            @test failure isa PipeWireAO.PipeWireError &&
                failure.operation == :pw_ndarray_filter_connect
        finally
            FilterGraphIsland.close_execution(graph)
        end
    end
end
