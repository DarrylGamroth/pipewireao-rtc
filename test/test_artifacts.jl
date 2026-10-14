using Test
using FITSIO
using SHA
using PipeWireAORTC.Artifacts

@testset "FITS artifact selection and owned logical arrays" begin
    @test_throws ArgumentError FITSArtifact("")
    @test_throws ArgumentError FITSArtifact("bad\0path")
    for hdu in (0, -1, true, 1.5)
        @test_throws ArgumentError FITSArtifact("unused.fits"; hdu)
    end
    for axes in ((), (1, 1), (2,), (0, 1), (true,), (1.0,), "1,2")
        @test_throws ArgumentError FITSArtifact("unused.fits"; axes)
    end
    mktempdir() do directory
        path = joinpath(directory, "calibration[1].fits")
        source = Int16[1 2 3; 4 5 6]
        FITS(path, "w"; extendedparser=false) do fits
            write(fits, source)
            write(fits, Int16[9, 10])
        end
        original = read(path)
        files = readdir(directory)
        selected = FITSArtifact(path; axes=(2, 1))
        artifact = prepare(selected, Float32, (3, 2))
        @test artifact isa PreparedArtifact{Float32,2}
        @test artifact.data isa Matrix{Float32}
        @test artifact.data == Float32[1 4; 2 5; 3 6]
        @test artifact.provenance["original_sha256"] == bytes2hex(SHA.sha256(original))
        @test artifact.provenance["sha256"] == bytes2hex(SHA.sha256(pack(artifact)))
        @test artifact.provenance["axes"] == [2, 1]
        @test artifact.provenance["source_shape"] == [2, 3]
        @test artifact.provenance["target_shape"] == [3, 2]
        @test artifact.provenance["hdu"] == 1
        @test pack(artifact) == UInt8[
            0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x80, 0x40,
            0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0xa0, 0x40,
            0x00, 0x00, 0x40, 0x40, 0x00, 0x00, 0xc0, 0x40]
        identity = prepare(FITSArtifact(path; axes=[1, 2]), UInt16, [2, 3])
        @test identity.data == source
        @test pack(identity) == UInt8[1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0]
        second = prepare(FITSArtifact(path; hdu=2), UInt8, (2,))
        @test second.data == UInt8[9, 10]
        @test second.provenance["axes"] == [1]
        @test_throws ArgumentError prepare(FITSArtifact(path), Float32, (2, 3))
        @test_throws ArgumentError prepare(FITSArtifact(path; axes=(1,)), Float32, (2, 3))
        @test_throws ArgumentError prepare(FITSArtifact(path; hdu=3), UInt8, (2,))
        @test_throws DimensionMismatch prepare(selected, Float32, (2, 3))
        @test_throws DimensionMismatch prepare(selected, Float32, (6,))
        another = prepare(selected, Float32, (3, 2))
        artifact.data[1, 1] = -100
        @test another.data[1, 1] == 1
        @test read(path) == original
        @test readdir(directory) == files
        rm(path)
        @test another.data == Float32[1 4; 2 5; 3 6]
    end
    mktempdir() do directory
        path = joinpath(directory, "cube.fits")
        source = reshape(Int16.(1:24), 2, 3, 4)
        FITS(path, "w"; extendedparser=false) do fits
            write(fits, source)
        end
        artifact = prepare(FITSArtifact(path; axes=(3, 1, 2)), UInt32, (4, 2, 3))
        for logical in CartesianIndices(artifact.data)
            @test artifact.data[logical] == source[logical[2], logical[3], logical[1]]
        end
        square = joinpath(directory, "square.fits")
        FITS(square, "w"; extendedparser=false) do fits
            write(fits, Int16[1 2; 3 4])
        end
        @test_throws ArgumentError prepare(FITSArtifact(square), UInt8, (2, 2))
    end
end

@testset "FITS artifact cancellation and captured byte ownership" begin
    mktempdir() do directory
        path = joinpath(directory, "cancelled.fits")
        FITS(path, "w"; extendedparser=false) do fits
            write(fits, fill(UInt8(1), 1024 * 1024 + 17))
        end
        original = read(path)
        files = readdir(directory)
        selected = FITSArtifact(path)
        calls = Ref(0)
        prepared = prepare(selected, UInt8, (1024 * 1024 + 17,); check=()->(calls[] += 1))
        @test all(isone, prepared.data)
        for phase in (1, 4, calls[])
            attempts = Ref(0)
            cancellation = ErrorException("owner cancelled artifact preparation")
            published = Ref{Any}(nothing)
            caught = try
                published[] = prepare(selected, UInt8, (1024 * 1024 + 17,); check=()->begin
                    attempts[] += 1
                    attempts[] == phase && throw(cancellation)
                end)
                nothing
            catch exception
                exception
            end
            @test caught === cancellation
            @test published[] === nothing
            @test read(path) == original
            @test readdir(directory) == files
        end
        # Change the source only after snapshot capture. Decoding and its original
        # hash must still describe the captured image, rather than reopening it.
        checks = Ref(0)
        captured = prepare(selected, UInt8, (1024 * 1024 + 17,); check=()->begin
            checks[] += 1
            if checks[] == 6
                FITS(path, "w"; extendedparser=false) do fits
                    write(fits, UInt8[9])
                end
            end
        end)
        @test all(isone, captured.data)
        @test captured.provenance["original_sha256"] == bytes2hex(SHA.sha256(original))
        @test read(path) != original
        @test readdir(directory) == files
    end
end

@testset "FITS artifact conversion rules and metadata" begin
    mktempdir() do directory
        path = joinpath(directory, "values.fits")
        function image(values)
            FITS(path, "w"; extendedparser=false) do fits
                write(fits, values)
            end
            return FITSArtifact(path)
        end
        artifact = prepare(image(UInt8[0, 1, 1]), Bool, (3,))
        @test artifact.data isa Vector{Bool}
        @test artifact.data == [false, true, true]
        @test pack(artifact) == UInt8[0, 1, 1]
        @test_throws ArgumentError prepare(image(UInt8[0, 2]), Bool, (2,))
        @test_throws ArgumentError prepare(image(Float64[0.0, 0.5]), Bool, (2,))
        @test_throws ArgumentError prepare(image(Float64[1, 1.5]), UInt32, (2,))
        @test_throws ArgumentError prepare(image(Int16[-1, 1]), UInt16, (2,))
        @test_throws ArgumentError prepare(image(Int16[255, 256]), UInt8, (2,))
        integer = prepare(image(Float64[0, 65535]), UInt16, (2,))
        @test integer.data == UInt16[0, 65535]
        for nonfinite in (NaN, Inf, -Inf), T in (Float32, Float64, UInt8, UInt16, UInt32, Bool)
            @test_throws ArgumentError prepare(image(Float64[nonfinite]), T, (1,))
        end
        @test_throws ArgumentError prepare(image(Float64[Float64(floatmax(Float32)) * 2]), Float32, (1,))
        rounded = prepare(image(Float64[1 / 3, -0.0]), Float32, (2,))
        @test rounded.data[1] === Float32(1 / 3)
        @test signbit(rounded.data[2])
        @test pack(rounded)[5:8] == UInt8[0, 0, 0, 0x80]
        wide = prepare(image(Float64[1.0]), Float64, (1,))
        @test pack(wide) == UInt8[0, 0, 0, 0, 0, 0, 0xf0, 0x3f]
        image(Int16[1, 2])
        FITS(path, "r+"; extendedparser=false) do fits
            write_key(fits[1], "BSCALE", 2.0)
            write_key(fits[1], "BZERO", 10.0)
            write_key(fits[1], "BUNIT", "adu")
        end
        scaled = prepare(FITSArtifact(path), Float64, (2,))
        @test scaled.data == [12.0, 14.0]
        @test scaled.provenance["BSCALE"] == 2.0
        @test scaled.provenance["BZERO"] == 10.0
        @test scaled.provenance["BUNIT"] == "adu"
        for key in ("BLANK", "ZIMAGE")
            image(Int16[1, 2])
            FITS(path, "r+"; extendedparser=false) do fits
                write_key(fits[1], key, key == "BLANK" ? -32768 : true)
            end
            @test_throws ArgumentError prepare(FITSArtifact(path), Float32, (2,))
        end
        image(Int16[1])
        FITS(path, "r+"; extendedparser=false) do fits
            write(fits, Dict("sample" => Int32[1, 2]))
        end
        @test_throws ArgumentError prepare(FITSArtifact(path; hdu=2), Float32, (2,))
    end
end

@testset "FITS artifact limits reject before image allocation" begin
    missing = FITSArtifact("missing-calibration.fits")
    for shape in ((), [], (0,), (-1,), (true,), (1.5,), (typemax(Int),),
        (typemax(UInt),), (1024, 1024, 1024), (1 << 26, 2))
        @test_throws ArgumentError prepare(missing, Float32, shape)
    end
    @test_throws ArgumentError prepare(missing, ComplexF32, (1,))
    @test_throws ArgumentError prepare(missing, Float32, (1,))
    mktempdir() do directory
        path = joinpath(directory, "oversized.fits")
        # Sparse file: exercise the input-size gate without allocating 512 MiB.
        open(path, "w") do io
            write(io, "SIMPLE  =")
            truncate(io, 512 * 1024 * 1024 + 1)
        end
        @test_throws ArgumentError prepare(FITSArtifact(path), UInt8, (1,))
        write(path, UInt8[0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0])
        @test_throws ArgumentError prepare(FITSArtifact(path), UInt8, (1,))
        link = joinpath(directory, "linked.fits")
        symlink(path, link)
        @test_throws ArgumentError prepare(FITSArtifact(link), UInt8, (1,))
        # A valid FITS header declaring a huge image must fail before data read.
        cards = ["SIMPLE  =                    T", "BITPIX  =                  -64",
            "NAXIS   =                    1", "NAXIS1  =            100000000", "END"]
        write(path, rpad(join(rpad.(cards, 80)), 2880))
        @test_throws ArgumentError prepare(FITSArtifact(path), UInt8, (1,))
        @test readdir(directory) == ["linked.fits", "oversized.fits"]
    end
end
