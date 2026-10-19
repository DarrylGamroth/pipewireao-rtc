# Optional science boundary check; run in an environment containing the JFG stack.
using Test
using PipeWireAORTC

@test !any(id -> id.name in ("FilterGraphIsland", "JuliaFilterGraph", "FilterGraphPipeWire", "CUDA"), keys(Base.loaded_modules))

using FilterGraphIsland
using JuliaFilterGraph
using FilterGraphPipeWire
using FilterGraphAlgorithms

@test Base.get_extension(PipeWireAORTC, :PipeWireAORTCGraphExt) !== nothing
@test hasmethod(PipeWireAORTC.GraphOwner.run_owner, Tuple{Module, Any, Any, Any})

@testset "FITS graph initial parameters adopt before node publication" begin
    mktempdir() do directory
        background = reshape(Float32.(1:64), 8, 8)
        path = joinpath(directory, "background.fits")
        PipeWireAORTC.Artifacts.FITS(path, "w") do fits
            PipeWireAORTC.Artifacts.write(fits, permutedims(background))
        end
        manifest = joinpath(directory, "bindings.conf")
        write(manifest, """
            parameters = [
                { port = background path = background.fits hdu = 1
                  axes = [ 2 1 ] type = Float32 shape = [ 8 8 ] }
            ]
            """)
        entries = PipeWireAORTC.GraphOwner.bindings(manifest)
        graph_path = joinpath(directory, "graph.conf")
        write(graph_path, """
            filter.graph = {
                nodes = [ { type = ndarray name = calibrate
                    label = pixel-calibration-row-u16-f32
                    config = { image_rows = 8 image_columns = 8 row_block_rows = 2
                        initial_flat = null initial_background = null } } ]
                links = []
                inputs = [ "calibrate:raw" "calibrate:background" "calibrate:flat" ]
                outputs = [ "calibrate:calibrated" ]
            }
            """)
        for execution in ("complete-frame", "row-block")
            options = FilterGraphIsland.parse_arguments([
                "--graph", graph_path, "--check", "--execution", execution])
            arrays = Ref{Any}(nothing)
            graph = FilterGraphIsland.prepare_service_graph(options;
                initial_parameters=formats -> begin
                    arrays[] = PipeWireAORTC.GraphOwner.prepare_bindings(entries, formats)
                    arrays[]
                end)
            try
                checked = execution == "row-block" ? graph.graph : graph
                @test checked.nodes[1].prepared.plan.background == background
                last(only(arrays[]))[1] = -1
                @test checked.nodes[1].prepared.plan.background[1] == 1
                @test JuliaFilterGraph.parameter_formats(graph).background.shape == (8,8)
                outputs = (; calibrated=zeros(Float32, 2, 8))
                inputs = (; raw=fill(UInt16(100), 2, 8))
                for block in 0:3
                    metadata = (; raw=FilterGraphAlgorithms.SampleMetadata(0, 2block;
                        terminal=block == 3))
                    JuliaFilterGraph.process!(outputs, graph, inputs, metadata)
                    @test outputs.calibrated == 100f0 .- background[(2block+1):(2block+2), :]
                end
            finally
                FilterGraphIsland.close_execution(graph)
            end
        end
        @test sort(readdir(directory)) == ["background.fits", "bindings.conf", "graph.conf"]
    end
end
