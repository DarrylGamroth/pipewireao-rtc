using Test, PipeWireAORTC, FITSIO, JSON, SHA

const Parameters = PipeWireAORTC.NativeParameterSource

@testset "FITS sparse parameter preload and legacy compatibility" begin
    mktempdir() do directory
        data = Float32[1 2 3; 4 5 6]
        artifact = joinpath(directory, "reconstructor.fits")
        FITS(artifact, "w") do fits
            write(fits, permutedims(data))
        end
        row = Dict{String,Any}("node_name" => "rtc.reconstructor", "graph" => "controller",
            "inlet" => "reconstructor", "element_type" => "F32_LE", "shape" => [2, 3],
            "layout" => "row-major", "schema" => "test.reconstructor/1",
            "initial_artifact" => Dict("path" => basename(artifact), "hdu" => 1, "axes" => [2, 1]))
        config = joinpath(directory, "parameters.json")
        save(version, rows) = write(config, JSON.json(Dict("version" => version, "sources" => rows)))
        initial_files = sort(readdir(directory))
        for layout in ("row-major", "column-major")
            row["layout"] = layout
            save(2, [row])
            source = only(Parameters.read_declarations(config, Base.Event()))
            expected = layout == "row-major" ? Float32[1, 2, 3, 4, 5, 6] : vec(data)
            @test reinterpret(Float32, source.bytes) == expected
            @test source.initial
            @test source.sequence == 0
            @test source.stream === nothing
            @test source.initial_provenance["original_sha256"] == bytes2hex(sha256(read(artifact)))
            @test source.initial_provenance["publication_storage_order"] == layout
            @test source.initial_provenance["publication_sha256"] == bytes2hex(sha256(source.bytes))
            @test sort(readdir(directory)) == sort([initial_files; "parameters.json"])
        end
        @test_throws InterruptException Parameters.read_declarations(config, Base.Event();
            check=()->throw(InterruptException()))

        for version in (0, 3, true, 2.0)
            save(version, [row])
            @test_throws ArgumentError Parameters.read_declarations(config, Base.Event())
        end
        save(1, [row])
        @test_throws ArgumentError Parameters.read_declarations(config, Base.Event())
        for selection in (Dict("path" => basename(artifact)),
                          Dict("path" => basename(artifact), "axes" => [1]),
                          Dict("path" => basename(artifact), "axes" => [1, 1]),
                          Dict("path" => basename(artifact), "axes" => [2, 1], "ignored" => true))
            invalid = merge(row, Dict("initial_artifact" => selection))
            save(2, [invalid])
            @test_throws ArgumentError Parameters.read_declarations(config, Base.Event())
        end
        idle = copy(row)
        delete!(idle, "initial_artifact")
        save(2, [idle])
        source = only(Parameters.read_declarations(config, Base.Event()))
        @test !source.initial
        @test source.initial_provenance === nothing

        # An invalid later declaration fails before the first artifact is opened.
        missing = merge(row, Dict("initial_artifact" => Dict("path" => "missing.fits", "axes" => [2, 1])))
        invalid = merge(row, Dict("node_name" => "rtc.other", "inlet" => "other", "element_type" => "U8"))
        save(2, [missing, invalid])
        failure = try
            Parameters.read_declarations(config, Base.Event())
            nothing
        catch error
            error
        end
        @test failure isa ArgumentError
        @test occursin("parameter source supports only F32_LE", sprint(showerror, failure))

        legacy = merge(idle, Dict("initial_payload_path" => joinpath(directory, "legacy-payload")))
        write(legacy["initial_payload_path"], vec(data))
        save(2, [legacy])
        @test_throws ArgumentError Parameters.read_declarations(config, Base.Event())
        save(1, [legacy])
        source = only(Parameters.read_declarations(config, Base.Event()))
        @test reinterpret(Float32, source.bytes) == vec(data)
        @test source.initial_provenance === nothing
    end
end
