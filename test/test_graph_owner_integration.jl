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
        background = reshape(Float32.(1:48), 8, 6)
        path = joinpath(directory, "background.fits")
        PipeWireAORTC.Artifacts.FITS(path, "w") do fits
            PipeWireAORTC.Artifacts.write(fits, permutedims(background))
        end
        manifest = joinpath(directory, "bindings.conf")
        write(manifest, """
            parameters = [
                { port = background path = background.fits hdu = 1
                  axes = [ 2 1 ] }
            ]
            """)
        entries = PipeWireAORTC.GraphOwner.bindings(manifest)
        graph_path = joinpath(directory, "graph.conf")
        write(graph_path, """
            filter.graph = {
                nodes = [ { type = ndarray name = calibrate
                    label = pixel-calibration-row-u16-f32
                    config = { image_size = [ 8 6 ] row_block_rows = 2
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
                @test JuliaFilterGraph.parameter_formats(graph).background.shape == (8,6)
                outputs = (; calibrated=zeros(Float32, 2, 6))
                inputs = (; raw=fill(UInt16(100), 2, 6))
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
        @test PipeWireAORTC.GraphOwner.read_bindings(graph_path, manifest)[:background] == background
        options = FilterGraphIsland.parse_arguments(["--graph", graph_path, "--check"])
        for (array, axes) in ((zeros(Float32, 8, 5), (2,1)),
                (background, (1,2)), (fill(Inf32, 8, 6), (2,1)))
            PipeWireAORTC.InstrumentCalibration.write_fits(path, array)
            source = PipeWireAORTC.Artifacts.FITSArtifact(path; axes)
            invalid = [PipeWireAORTC.GraphOwner.FITSBinding(:background, source)]
            expected = all(isfinite, array) ? DimensionMismatch : ArgumentError
            @test_throws expected FilterGraphIsland.prepare_service_graph(options;
                initial_parameters=formats -> PipeWireAORTC.GraphOwner.prepare_bindings(invalid, formats))
        end
        @test sort(readdir(directory)) == ["background.fits", "bindings.conf", "graph.conf"]
    end
end

@testset "typed Boolean and integer FITS initialization" begin
    mktempdir() do directory
        graph_path = joinpath(directory, "graph.conf")
        write(graph_path, """
            filter.graph = {
                nodes = [
                    { type = ndarray name = select label = pixel-selection-f32
                      config = { image_size = [ 2 3 ]
                        mask = [ true false true false true false ]
                        input_schema = pipewireao/calibrated-pixels-f32/1
                        output_schema = pipewireao/test.selected-pixels/1 } }
                    { type = ndarray name = extract label = region-extraction-f32
                      config = { image_size = [ 2 3 ] region_size = [ 1 1 ]
                        origins = [ [ 0 0 ] ] } }
                ]
                links = []
                inputs = [ "select:image" "select:mask" "extract:calibrated" "extract:origins" ]
                outputs = [ "select:selected-pixels" "extract:regions" ]
            }
            """)
        manifest = joinpath(directory, "parameters.conf")
        write(manifest, """
            parameters = [
                { port = mask path = mask.fits axes = [ 2 1 ] }
                { port = origins path = origins.fits axes = [ 2 1 ] }
            ]
            """)
        entries = PipeWireAORTC.GraphOwner.bindings(manifest)
        mask = Bool[false true false; true false true]
        mask_path = joinpath(directory, "mask.fits")
        origins_path = joinpath(directory, "origins.fits")
        write_fits = PipeWireAORTC.InstrumentCalibration.write_fits
        write_fits(mask_path, mask)
        write_fits(origins_path, UInt32[0 0])
        options = FilterGraphIsland.parse_arguments(["--graph", graph_path, "--check"])
        prepare() = FilterGraphIsland.prepare_service_graph(options;
            initial_parameters=formats -> PipeWireAORTC.GraphOwner.prepare_bindings(entries, formats))
        graph = prepare()
        try
            image = Float32[1 2 3; 4 5 6]
            selected = zeros(Float32, 3)
            regions = zeros(Float32, 1, 1, 1)
            outputs = NamedTuple{(Symbol("selected-pixels"), :regions)}((selected, regions))
            @test all(values(JuliaFilterGraph.process!(outputs, graph, (; image, calibrated=image))))
            @test selected == Float32[2, 4, 6]
            @test regions == ones(Float32, 1, 1, 1)
        finally
            FilterGraphIsland.close_execution(graph)
        end
        @test eltype(PipeWireAORTC.GraphOwner.read_bindings(graph_path, manifest)[:mask]) === Bool
        write_fits(mask_path, UInt8[0 2 0; 1 0 1])
        @test_throws ArgumentError prepare()
        write_fits(mask_path, mask)
        write_fits(origins_path, Float32[0.5 0])
        @test_throws ArgumentError prepare()
    end
end
