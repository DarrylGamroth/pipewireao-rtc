using Test, FITSIO, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

function two_command_description()
    positions = ((1, 1), (3, 3))
    return (; schema_version=1, id="generic-influence-test",
        manufacturer="Example Instruments", model="Test mirror",
        layout=(; schema_version=1, name="Generic influence test", grid_shape=(3, 3),
            axis_labels=("source column", "source row"), command_positions=positions,
            command_order="listed physical command order", provenance="synthetic test data"))
end

@testset "measured influence preparation" begin
    description = two_command_description()
    spec = (; path="unused", hdu=1, axes=(2, 1, 3), command_indices=(2, 1),
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
        result = IC._load_influence_functions(merge(spec, (; path)), description, 2,
            (; actuator_pitch_pupil_radius=1.0))
        @test size(result.modes) == (4, 2)
        @test result.modes[1, 2] == 2f0 * 10f0 * (2.5f0 + 3f0 * 1.5f0)
        @test result.modes[1, 1] == 2f0 * 20f0 * (2.5f0 + 3f0 * 1.5f0)
        @test result.provenance.command_indices == (2, 1)
        @test result.provenance.axes == (2, 1, 3)
        @test result.provenance.spatial_shape == (3, 3)
        @test result.provenance.interpolation == "bilinear"

        for invalid in (
            merge(spec, (; axes=(1, 1, 3))),
            merge(spec, (; command_indices=(1, 1))),
            merge(spec, (; sample_pitch=(1.0, 0.0))),
            merge(spec, (; opd_scale_m=0.0)),
            merge(spec, (; reference_command_m=0.0)),
            merge(spec, (; hdu=true)),
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
    end
end
