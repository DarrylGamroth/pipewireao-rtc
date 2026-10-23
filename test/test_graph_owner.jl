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

@testset "FITS graph contracts, logical ordering and cancellation" begin
    mktempdir() do directory
        path = joinpath(directory, "reference.fits")
        values = Float32[1 2 3; 4 5 6]
        FITS(path, "w") do fits
            write(fits, values)
        end
        manifest = joinpath(directory, "bindings.json")
        write(manifest, """{"parameters":[{"port":"reference","path":"reference.fits","hdu":1,"axes":[2,1]}]}""")
        entries = GraphOwner.bindings(manifest)
        @test fieldnames(GraphOwner.FITSBinding) == (:port, :source)
        relaxed = joinpath(directory, "bindings.conf")
        write(relaxed, """
            # Standard relaxed SPA JSON; paths remain manifest-relative.
            parameters = [
                { port = reference path = reference.fits hdu = 1 axes = [ 2 1 ] }
            ]
            """)
        @test only(GraphOwner.bindings(relaxed)).source.axes == (2, 1)
        formats = (; reference=(; element_type=Float32, shape=(3, 2)))
        updates = GraphOwner.prepare_bindings(entries, formats)
        @test only(updates).first === :reference
        @test only(updates).second == permutedims(values)
        @test only(updates).second isa Matrix{Float32}
        @test sort(readdir(directory)) == ["bindings.conf", "bindings.json", "reference.fits"]
        @test_throws DimensionMismatch GraphOwner.prepare_bindings(entries,
            (; reference=(; element_type=Float32, shape=(2,3))))
        transposed = [GraphOwner.FITSBinding(:reference,
            PipeWireAORTC.Artifacts.FITSArtifact(path; axes=(1,2)))]
        @test_throws DimensionMismatch GraphOwner.prepare_bindings(transposed, formats)
        @test only(GraphOwner.prepare_bindings(entries,
            (; reference=(; element_type=Float64, shape=(3,2))))).second isa Matrix{Float64}
        rm(path)
        # All graph format checks precede opening even the first FITS source.
        @test_throws r"Graph has no external Parameter Port" GraphOwner.prepare_bindings(entries, (;))
        @test_throws r"unsupported FITS parameter type" GraphOwner.prepare_bindings(entries,
            (; reference=(; element_type=UInt64, shape=(3,2))))
        @test_throws r"artifact dimensions must be positive integers" GraphOwner.prepare_bindings(entries,
            (; reference=(; element_type=Float32, shape=(0,2))))
        @test_throws r"artifact dimensions must be positive integers" GraphOwner.prepare_bindings(entries,
            (; reference=(; element_type=Float32, shape=(true,2))))
        @test_throws r"decoded artifact exceeds 256 MiB" GraphOwner.prepare_bindings(entries,
            (; reference=(; element_type=Float32, shape=(67108865,1))))
        @test_throws DimensionMismatch GraphOwner.prepare_bindings(entries,
            (; reference=(; element_type=Float32, shape=(6,))))
        no_axes = [GraphOwner.FITSBinding(:reference,
            PipeWireAORTC.Artifacts.FITSArtifact(path))]
        @test_throws r"multidimensional FITS binding requires axes" GraphOwner.prepare_bindings(no_axes, formats)
        second = GraphOwner.FITSBinding(:second, only(entries).source)
        @test_throws r"artifact dimensions must be positive integers" GraphOwner.prepare_bindings([entries; second],
            (; reference=(; element_type=Float32, shape=(3,2)),
                second=(; element_type=Float32, shape=(-1,2))))
        third = GraphOwner.FITSBinding(:third, only(entries).source)
        @test_throws r"retained FITS parameters exceed 512 MiB" GraphOwner.prepare_bindings([entries; second; third],
            (; reference=(; element_type=Float32, shape=(67108864,1)),
                second=(; element_type=Float32, shape=(67108864,1)),
                third=(; element_type=Float32, shape=(1,1))))
        @test_throws r"duplicate FITS parameter" GraphOwner.prepare_bindings([entries; entries], formats)
        @test_throws InterruptException GraphOwner.prepare_bindings(entries, formats;
            check=() -> throw(InterruptException()))
        for invalid in (
            """{"parameters":[{"port":"r","path":"x","shape":[2,2]}]}""",
            """{"parameters":[{"port":"r","path":"x","type":"Float32"}]}""",
            """{"parameters":[{"port":"r","path":"x","axes":[1,1]}]}""",
            """{"parameters":[{"port":"r","path":"x","hdu":0}]}""",
            """{"parameters":[],"extra":true}""",
            """{"parameters":[{"port":"r","path":"x"},{"port":"r","path":"y"}]}""",
        )
            write(manifest, invalid)
            @test_throws ArgumentError GraphOwner.bindings(manifest)
        end
    end
end

@testset "FITS values conform to the graph parameter type" begin
    mktempdir() do directory
        path = joinpath(directory, "values.fits")
        entry = GraphOwner.FITSBinding(:values, PipeWireAORTC.Artifacts.FITSArtifact(path))
        for (values, T) in ((Float32[0, 0.5], UInt16), (UInt8[0, 2], Bool),
                (Float32[0, Inf], Float32), (Float32[0, NaN], Float64))
            isfile(path) && rm(path)
            FITS(path, "w") do fits
                write(fits, values)
            end
            @test_throws ArgumentError GraphOwner.prepare_bindings([entry],
                (; values=(; element_type=T, shape=(2,))))
        end
    end
end
