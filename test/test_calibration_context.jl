using Test, FITSIO, SHA, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

@testset "calibration FITS references preserve typed logical row-major values" begin
    mktempdir() do directory
        path = joinpath(directory, "pupil-mask.fits")
        image = UInt8[1 0 1; 0 1 0]
        FITS(path, "w") do fits
            write(fits, image)
            write(fits, Int16[4, 7])
        end
        original = read(path)
        reference = Dict{String,Any}("kind" => "fits", "path" => "pupil-mask.fits",
            "hdu" => 1, "axes" => [1, 2], "shape" => [2, 3], "type" => "Bool",
            "sha256" => bytes2hex(sha256(original)), "storage_order" => "row-major")
        document = Dict("pupil" => Dict("mask" => reference),
            "metadata" => Any["nm OPD", Dict("gain" => 0.25, "enabled" => true)],
            "optional" => nothing)
        authoring = deepcopy(document)
        context = IC.calibration_context(document, directory)
        @test context["pupil"]["mask"] isa Vector{Bool}
        @test context["pupil"]["mask"] == Bool[1, 0, 1, 0, 1, 0]
        @test context["metadata"] == document["metadata"]
        @test context["optional"] === nothing
        context["metadata"][2]["gain"] = 2.0
        context["pupil"]["mask"][1] = false
        @test document == authoring
        @test read(path) == original
        @test readdir(directory) == ["pupil-mask.fits"]

        float_reference = merge(reference, Dict("type" => "Float32", "axes" => [2, 1], "shape" => [3, 2]))
        values = IC.calibration_context(float_reference, directory)
        @test values isa Vector{Float32}
        @test values == Float32[1, 0, 0, 1, 1, 0]
        vector_reference = merge(reference, Dict("hdu" => 2, "axes" => [1], "shape" => [2], "type" => "Int32"))
        @test IC.calibration_context(vector_reference, directory) == Int32[4, 7]

        # Exercise the aggregate byte boundary with real small arrays: six Bool
        # bytes and two Int32 values, across nested mappings and a list.
        references = [Dict("mask" => reference), Dict("values" => vector_reference)]
        @test IC._calibration_context(references, directory, Ref(14)) ==
            [Dict("mask" => Bool[1, 0, 1, 0, 1, 0]), Dict("values" => Int32[4, 7])]
        @test_throws ArgumentError IC._calibration_context(references, directory, Ref(13))

        for key in keys(reference)
            missing = copy(reference)
            delete!(missing, key)
            # A map without kind is ordinary metadata, not a FITS reference.
            key == "kind" && continue
            @test_throws ArgumentError IC.calibration_context(missing, directory)
        end
        for replacement in (
                Dict("unknown" => true), Dict("storage_order" => "column-major"),
                Dict("type" => "Float16"), Dict("type" => 1),
                Dict("sha256" => "0"^64), Dict("sha256" => "sha256:" * reference["sha256"]),
                Dict("sha256" => "a"^65), Dict("sha256" => "z"^64),
                Dict("sha256" => nothing), Dict("axes" => nothing),
                Dict("axes" => [1, 1]), Dict("axes" => Any[true, 2]),
                Dict("hdu" => true), Dict("hdu" => 0), Dict("hdu" => 3),
                Dict("shape" => Any[true, 3]), Dict("shape" => [0, 3]),
                Dict("shape" => [typemax(Int), 3]), Dict("shape" => "2,3"))
            @test_throws ArgumentError IC.calibration_context(merge(reference, replacement), directory)
        end
        @test_throws DimensionMismatch IC.calibration_context(merge(reference, Dict("shape" => [3, 2])), directory)
        @test_throws ArgumentError IC.calibration_context(merge(reference, Dict("axes" => [1])), directory)
        @test_throws Base.IOError IC.calibration_context(
            merge(reference, Dict("path" => "absent.fits")), directory)
        @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError IC.calibration_context(
            merge(reference, Dict("path" => abspath(path))), directory)
        mktempdir() do outside
            escaped = joinpath(outside, "pupil-mask.fits")
            write(escaped, original)
            @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError IC.calibration_context(
                merge(reference, Dict("path" => relpath(escaped, directory))), directory)
            symlink(escaped, joinpath(directory, "outside.fits"))
            @test_throws PipeWireAORTC.DeploymentConfiguration.DeploymentError IC.calibration_context(
                merge(reference, Dict("path" => "outside.fits")), directory)
        end
        @test read(path) == original
    end
end

@testset "calibration Bool FITS values must be exactly zero or one" begin
    mktempdir() do directory
        path = joinpath(directory, "pupil-mask.fits")
        for invalid in (-1.0, 2.0, NaN, Inf)
            FITS(path, "w") do fits
                write(fits, [0.0 invalid; 1.0 0.0])
            end
            original = read(path)
            reference = Dict("kind" => "fits", "path" => "pupil-mask.fits",
                "hdu" => 1, "axes" => [1, 2], "shape" => [2, 2], "type" => "Bool",
                "sha256" => bytes2hex(sha256(original)), "storage_order" => "row-major")
            @test_throws ArgumentError IC.calibration_context(reference, directory)
            @test read(path) == original
        end
    end
end

@testset "calibration context preparation remains CPU-only" begin
    @test Base.ispublic(IC, :calibration_context)
    documentation = (@doc IC.calibration_context)
    @test !isnothing(documentation)
    @test !any(id -> id.name in ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end
