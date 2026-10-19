using Test
using FITSIO
using PipeWireAORTC

const GraphOwner = PipeWireAORTC.GraphOwner

module GraphOwnerIsland
parse_arguments(args) = (; args)
end

@testset "native graph bootstrap arguments and cold load order" begin
    argv = ["--bootstrap-node", "rtc.bootstrap.graph", "--bootstrap-instance=7",
        "--remote", "/tmp/rtc-private", "--graph", "graph.conf", "--session-run-control",
        "--fits-bindings", "bindings.conf"]
    binding, graph, fits = GraphOwner.arguments(argv)
    @test binding == (; remote="/tmp/rtc-private", bootstrap_node="rtc.bootstrap.graph", bootstrap_instance=7)
    @test graph == ["--remote", "/tmp/rtc-private", "--graph", "graph.conf", "--session-run-control"]
    @test fits == "bindings.conf"
    for extra in (["--check"], ["--remote", "/tmp/other"], ["--bootstrap-instance", "8"], ["--fits-bindings", "other"])
        @test_throws ArgumentError GraphOwner.arguments([argv; extra])
    end
    for flags in (["--bootstrap-node", "bad/name"], ["--bootstrap-instance", "0"], ["--remote", "relative"])
        @test_throws ArgumentError GraphOwner.arguments(flags)
    end
    events = Symbol[]
    fake_owner = function (f, options)
        push!(events, :preparing)
        try
            f(merge(options, (; owner_check=() -> push!(events, :check), bootstrap_runtime=:runtime)))
        finally
            push!(events, :cleanup)
        end
    end
    without_fits = argv[1:end-2]
    @test GraphOwner._main(without_fits; with_owner=fake_owner,
        load_science=() -> (push!(events, :load_science); GraphOwnerIsland),
        run=(island, options, runtime, entries) -> begin
            @test runtime === :runtime
            @test isempty(entries)
            push!(events, :run)
        end) == 0
    @test events == [:preparing, :check, :load_science, :check, :check, :run, :cleanup]
    empty!(events)
    cancelled = function (f, options)
        push!(events, :preparing)
        try
            f(merge(options, (; owner_check=() -> throw(InterruptException()), bootstrap_runtime=:runtime)))
        finally
            push!(events, :cleanup)
        end
    end
    @test_throws InterruptException GraphOwner._main(without_fits; with_owner=cancelled,
        load_science=() -> push!(events, :load_science))
    @test events == [:preparing, :cleanup]
    @test !any(id -> id.name in ("FilterGraphIsland", "JuliaFilterGraph", "FilterGraphPipeWire", "CUDA"), keys(Base.loaded_modules))
end

@testset "FITS graph declarations, logical ordering and cancellation" begin
    mktempdir() do directory
        path = joinpath(directory, "reference.fits")
        values = Float32[1 2 3; 4 5 6]
        FITS(path, "w") do fits
            write(fits, values)
        end
        manifest = joinpath(directory, "bindings.json")
        write(manifest, """{"parameters":[{"port":"reference","path":"reference.fits","hdu":1,"axes":[2,1],"type":"Float32","shape":[3,2]}]}""")
        entries = GraphOwner.bindings(manifest)
        relaxed = joinpath(directory, "bindings.conf")
        write(relaxed, """
            # Standard relaxed SPA JSON; paths remain manifest-relative.
            parameters = [
                { port = reference path = reference.fits hdu = 1
                  axes = [ 2 1 ] type = Float32 shape = [ 3 2 ] }
            ]
            """)
        @test only(GraphOwner.bindings(relaxed)).shape == (3, 2)
        formats = (; reference=(; element_type=Float32, shape=(3, 2)))
        updates = GraphOwner.prepare_bindings(entries, formats)
        @test only(updates).first === :reference
        @test only(updates).second == permutedims(values)
        @test only(updates).second isa Matrix{Float32}
        @test sort(readdir(directory)) == ["bindings.conf", "bindings.json", "reference.fits"]
        rm(path)
        # Declaration mismatches precede any attempt to open a source.
        @test_throws ArgumentError GraphOwner.prepare_bindings(entries, (;))
        @test_throws ArgumentError GraphOwner.prepare_bindings(entries,
            (; reference=(; element_type=UInt32, shape=(3,2))))
        @test_throws DimensionMismatch GraphOwner.prepare_bindings(entries,
            (; reference=(; element_type=Float32, shape=(2,3))))
        second = GraphOwner.FITSBinding(:second, only(entries).source, Float32, (3, 2))
        @test_throws DimensionMismatch GraphOwner.prepare_bindings([entries; second],
            (; reference=(; element_type=Float32, shape=(3,2)),
                second=(; element_type=Float32, shape=(2,3))))
        @test_throws InterruptException GraphOwner.prepare_bindings(entries, formats;
            check=() -> throw(InterruptException()))
        for invalid in (
            """{"parameters":[{"port":"r","path":"x","type":"Float32","shape":[2,2]}]}""",
            """{"parameters":[{"port":"r","path":"x","type":"UInt64","shape":[2]}]}""",
            """{"parameters":[{"port":"r","path":"x","type":"Float32","shape":[0]}]}""",
            """{"parameters":[],"extra":true}""",
            """{"parameters":[{"port":"r","path":"x","type":"Float32","shape":[1]},{"port":"r","path":"y","type":"Float32","shape":[1]}]}""",
            """{"parameters":[{"port":"r","path":"x","type":"Float32","shape":[67108864]},{"port":"s","path":"y","type":"Float32","shape":[67108864]},{"port":"t","path":"z","type":"Float32","shape":[1]}]}""",
        )
            write(manifest, invalid)
            @test_throws ArgumentError GraphOwner.bindings(manifest)
        end
    end
end
