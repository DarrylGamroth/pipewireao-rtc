using Test, FITSIO, SHA, PipeWireAORTC

const IC = PipeWireAORTC.InstrumentConfiguration

@testset "measured influence admission remains independent of optional science" begin
    @test Base.get_extension(PipeWireAORTC, :PipeWireAORTCOpticsExt) === nothing
    spec = (;
        path = "unused",
        sha256 = repeat("0", 64),
        hdu = 1,
        axes = (1, 2, 3),
        type = "Float64",
        shape = (3, 3, 2),
        command_indices = (2, 1),
        sample_origin = (1.0, 1.0),
        sample_pitch = (1.0, 1.0),
        opd_scale_m = 2e-6,
        reference_command_m = 1e-6,
    )
    @test IC._influence_spec(spec, 2).command_indices == (2, 1)
    for invalid in (
        merge(spec, (; axes = (1, 1, 3))),
        merge(spec, (; command_indices = (1, 1))),
        merge(spec, (; sample_pitch = (1.0, 0.0))),
        merge(spec, (; opd_scale_m = 0.0)),
        merge(spec, (; reference_command_m = 0.0)),
        merge(spec, (; hdu = true)),
        merge(spec, (; sha256 = "ABC")),
        merge(spec, (; type = "Float16")),
        merge(spec, (; shape = (3, 3, 1))),
    )
        @test_throws ArgumentError IC._influence_spec(invalid, 2)
    end
    description = (; layout = (; grid_shape = (3, 3), command_positions = ((1, 1), (3, 3))))
    mktempdir() do directory
        path = joinpath(directory, "influences.fits")
        FITS(path, "w"; extendedparser = false) do file
            write(file, ones(Float64, 3, 3, 2))
        end
        admitted = merge(spec, (; path, sha256 = bytes2hex(sha256(read(path)))))
        load_influences(input, registration = (; actuator_pitch_pupil_radius = 1.0)) =
            IC._load_influence_functions(input, description, 2, registration)
        @test_throws r"requires loading AdaptiveOpticsSim" load_influences(admitted)
        @test_throws r"SHA-256" load_influences(
            merge(admitted, (; sha256 = repeat("0", 64)))
        )
        @test_throws r"nonidentity pupil registration" load_influences(
            admitted, (; actuator_pitch_pupil_radius = 1.0, flip_y = true)
        )
        @test_throws DimensionMismatch load_influences(
            merge(admitted, (; shape = (4, 3, 2)))
        )
    end
    @test !any(id -> id.name == "AdaptiveOpticsSim", keys(Base.loaded_modules))
end
