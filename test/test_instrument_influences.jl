using Test, FITSIO, SHA, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

function two_command_description()
    positions = ((1, 1), (3, 3))
    return (; schema_version=1, id="generic-influence-test",
        manufacturer="Example Instruments", model="Test mirror",
        layout=(; schema_version=1, name="Generic influence test", grid_shape=(3, 3),
            axis_labels=("source column", "source row"), command_positions=positions,
            command_order="listed physical command order"))
end

@testset "measured influence preparation" begin
    description = two_command_description()
    spec = (; path="unused", sha256=repeat("0", 64), hdu=1, axes=(2, 1, 3),
        type="Float64", shape=(3, 3, 2), command_indices=(2, 1),
        sample_origin=(1.0, 1.0), sample_pitch=(1.0, 1.0),
        opd_scale_m=2e-6, reference_command_m=1e-6)
    mktempdir() do directory
        path = joinpath(directory, "influences.fits")
        cube = Array{Float32}(undef, 3, 3, 2)
        for plane in 1:2, y in 1:3, x in 1:3
            cube[x, y, plane] = Float32(plane * 10 * (x + 3y))
        end
        FITS(path, "w"; extendedparser=false) do file
            write(file, cube)
        end
        spec = merge(spec, (; path, sha256=bytes2hex(sha256(read(path)))))
        result = IC._load_influence_functions(merge(spec, (; path)), description, 2,
            (; actuator_pitch_pupil_radius=1.0))
        @test size(result.modes) == (4, 2)
        @test result.modes[1, 2] == 2f0 * 10f0 * (2.5f0 + 3f0 * 1.5f0)
        @test result.modes[1, 1] == 2f0 * 20f0 * (2.5f0 + 3f0 * 1.5f0)
        @test result.provenance.command_indices == (2, 1)
        @test result.provenance.axes == (2, 1, 3)
        @test result.provenance.spatial_shape == (3, 3)
        @test result.provenance.interpolation == "bilinear"
        @test result.provenance.sha256 == spec.sha256
        @test result.provenance.artifact["original_sha256"] == spec.sha256
        @test result.provenance.artifact["target_type"] == "Float64"
        @test result.provenance.artifact["target_shape"] == [3, 3, 2]
        @test !haskey(result.provenance.artifact, "source")
        old_spec = (; (key => value for (key, value) in pairs(spec)
            if key ∉ (:sha256, :type, :shape))...)
        @test_throws ArgumentError IC._load_influence_functions(
            old_spec, description, 2, (; actuator_pitch_pupil_radius=1.0))

        for invalid in (
            merge(spec, (; axes=(1, 1, 3))),
            merge(spec, (; command_indices=(1, 1))),
            merge(spec, (; sample_pitch=(1.0, 0.0))),
            merge(spec, (; opd_scale_m=0.0)),
            merge(spec, (; reference_command_m=0.0)),
            merge(spec, (; hdu=true)),
            merge(spec, (; sha256="ABC")),
            merge(spec, (; type="Float16")),
            merge(spec, (; type="Int32")),
            merge(spec, (; shape=(3, 3))),
            merge(spec, (; shape=(3, 3, 1))),
        )
            @test_throws ArgumentError IC._load_influence_functions(
                merge(invalid, (; path)), description, 2, (; actuator_pitch_pupil_radius=1.0))
        end
        @test_throws ArgumentError IC._load_influence_functions(
            merge(spec, (; path=joinpath(directory, "missing.fits"))), description, 2,
            (; actuator_pitch_pupil_radius=1.0))
        @test_throws ArgumentError IC._load_influence_functions(
            merge(spec, (; path="")), description, 2, (; actuator_pitch_pupil_radius=1.0))

        malformed = joinpath(directory, "not-fits.fits")
        write(malformed, "not a FITS file")
        @test_throws ArgumentError IC._load_influence_functions(
            merge(spec, (; path=malformed)), description, 2, (; actuator_pitch_pupil_radius=1.0))

        # The path and dimensions remain valid, but the authored snapshot identity
        # must reject replacement calibration values before they are used.
        rm(path)
        FITS(path, "w"; extendedparser=false) do file
            write(file, 2 .* cube)
        end
        @test_throws r"SHA-256" IC._load_influence_functions(
            spec, description, 2, (; actuator_pitch_pupil_radius=1.0))
    end
end

@testset "influence logical shape and decoded precision" begin
    mktempdir() do directory
        path = joinpath(directory, "influences.fits")
        cube = [Float64(100plane + 10x + y) for plane in 1:2, x in 1:3, y in 1:4]
        FITS(path, "w"; extendedparser=false) do file
            write(file, cube)
        end
        spec = (; path, sha256=bytes2hex(sha256(read(path))), hdu=1,
            axes=(2, 3, 1), type="Float64", shape=(3, 4, 2), command_indices=(2, 1),
            sample_origin=(1.0, 1.0), sample_pitch=(1.0, 1.0),
            opd_scale_m=2e-6, reference_command_m=1e-6)
        load_influences(input) = IC._load_influence_functions(input, two_command_description(),
            2, (; actuator_pitch_pupil_radius=1.0))
        prepared = load_influences(spec)
        @test prepared.modes[1, 2] == 2f0 * (100f0 + 10f0 * 1.5f0 + 2.5f0)
        @test prepared.modes[1, 1] == 2f0 * (200f0 + 10f0 * 1.5f0 + 2.5f0)
        @test prepared.provenance.spatial_shape == (3, 4)
        @test_throws DimensionMismatch load_influences(merge(spec, (; shape=(4, 3, 2))))
        @test_throws DimensionMismatch load_influences(merge(spec, (; axes=(3, 2, 1))))

        rm(path)
        FITS(path, "w"; extendedparser=false) do file
            write(file, fill(1.0 + 2.0^-24, 2, 3, 4))
        end
        spec = merge(spec, (; sha256=bytes2hex(sha256(read(path))),
            opd_scale_m=3e-6, reference_command_m=1e-6))
        rounded = load_influences(merge(spec, (; type="Float32")))
        precise = load_influences(spec)
        @test all(==(3f0), rounded.modes)
        @test all(==(nextfloat(3f0)), precise.modes)
        @test rounded.provenance.artifact["source_type"] == "Float64"
        @test rounded.provenance.artifact["target_type"] == "Float32"
    end
end
