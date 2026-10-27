# Disconnected CPU selector; use an environment with the optional AOS/HIL packages.
module WavefrontPresentationTests
using Test, Statistics
using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
const Observation = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).OpticalObservation

presentation_allocation(image, opd, mask) = @allocated Observation.form_wavefront!(image, opd, mask)
focal_allocation(image, intensity) = @allocated Observation.form_focal_image!(image, intensity)

@testset "Physical pupil axes to diagnostic image rows and columns" begin
    mask = Bool[0 1 1; 1 0 1]
    opd = Float32[Inf 25e-9 75e-9; -25e-9 NaN -75e-9]
    original = copy(opd)
    image = zeros(Float32, reverse(size(opd)))
    display_mask = Bool[1 1; 1 0; 0 1]
    expected = Float32[75 -75; 25 NaN; NaN -25]
    @test Observation.form_wavefront!(image, opd, mask) === image
    @test image[display_mask] ≈ expected[display_mask] atol=1e-5
    @test all(isnan, image[.!display_mask])
    @test isequal(opd, original)
    @test sqrt(mean(abs2, image[display_mask])) ≈ std(Float64.(opd[mask]); corrected=false) * 1e9 rtol=1e-6
    @test Observation.pupil_rms_nm(opd, mask) ≈ sqrt(mean(abs2, image[display_mask])) rtol=1e-6
    @test Observation.pupil_rms_nm(fill(2f-3, size(opd)), mask) == 0
    @test_throws DimensionMismatch Observation.pupil_rms_nm(zeros(3, 2), mask)
    @test_throws ArgumentError Observation.pupil_rms_nm(opd, falses(size(mask)))
    shifted_image = similar(image)
    Observation.form_wavefront!(shifted_image, opd .+ 1f-6, mask)
    @test shifted_image[display_mask] ≈ image[display_mask] atol=1e-4
    @test_throws DimensionMismatch Observation.form_wavefront!(zeros(2, 3), opd, mask)
    @test_throws DimensionMismatch Observation.form_wavefront!(image, opd, falses(3, 2))
    @test_throws DimensionMismatch Observation.form_wavefront!(zeros(6), vec(opd), vec(mask))
    @test_throws ArgumentError Observation.form_wavefront!(image, opd, falses(size(mask)))
    invalid = copy(opd); invalid[1, 2] = NaN32
    @test_throws ArgumentError Observation.form_wavefront!(image, invalid, mask)
    @test_throws ArgumentError Observation.pupil_rms_nm(invalid, mask)

    # IdentityUnitRange retains non-one-based axes without another test dependency.
    opd_storage = zeros(Float32, 6, 8)
    pupil_storage = falses(6, 8)
    opd_storage[2:3, 4:6] .= opd
    pupil_storage[2:3, 4:6] .= mask
    offset_opd = view(opd_storage, Base.IdentityUnitRange(2:3), Base.IdentityUnitRange(4:6))
    offset_pupil = view(pupil_storage, Base.IdentityUnitRange(2:3), Base.IdentityUnitRange(4:6))
    offset_image = view(zeros(Float32, 8, 6), Base.IdentityUnitRange(4:6), Base.IdentityUnitRange(2:3))
    @test Observation.form_wavefront!(offset_image, offset_opd, offset_pupil) === offset_image
    @test axes(offset_image) == reverse(axes(offset_opd))
    @test all(isequal(offset_image[destination_index], image[index]) for (destination_index, index) in zip(CartesianIndices(offset_image), CartesianIndices(image)))
    @test_throws DimensionMismatch Observation.form_wavefront!(image, offset_opd, offset_pupil)
    @test_throws DimensionMismatch Observation.form_wavefront!(offset_image, offset_opd, mask)

    strided_image = view(zeros(Float32, 6, 4), 1:2:5, 2:2:4)
    @test Observation.form_wavefront!(strided_image, opd, mask) === strided_image
    @test isequal(strided_image, image)
    square_opd = zeros(Float32, 2, 2)
    @test_throws ArgumentError Observation.form_wavefront!(square_opd, square_opd, trues(2, 2))
    presentation_allocation(image, opd, mask)
    @test presentation_allocation(image, opd, mask) == 0
end

@testset "Focal image presentation preserves intensity and physical axes" begin
    intensity = Float32[11 12 13; 21 22 23]
    original = copy(intensity)
    image = zeros(Float32, 3, 2)
    @test Observation.form_focal_image!(image, intensity) === image
    @test image == Float32[13 23; 12 22; 11 21]
    @test intensity == original
    @test_throws DimensionMismatch Observation.form_focal_image!(zeros(2, 3), intensity)
    @test_throws DimensionMismatch Observation.form_focal_image!(zeros(6), vec(intensity))
    square = zeros(Float32, 2, 2)
    @test_throws ArgumentError Observation.form_focal_image!(square, square)
    focal_allocation(image, intensity)
    @test focal_allocation(image, intensity) == 0

    optics = AdaptiveOpticsSim.Optics
    telescope = optics.prepare_telescope(optics.TelescopeDefinition(
        resolution=16, diameter=7.77, revision=1, T=Float32),
        AdaptiveOpticsSim.Backends.HostComputeDevice())
    pupil = optics.PupilFunction(telescope)
    source = optics.Source(band=:H, magnitude=2, wavelength=1.65e-6, T=Float32)
    on_axis = optics.prepare_direct_imaging(pupil, source; zero_padding=2)
    output = optics.form_direct_image!(on_axis)
    raw = copy(optics.intensity_values(output))
    @test output.metadata.orientation == optics.PlaneAxisOrientation((:x, :y), (1, 1))
    reference = similar(raw)
    Observation.form_focal_image!(reference, raw)
    scale = optics.focal_plane_pixel_scale_arcsec(output)
    for (angle, raw_shift, image_shift) in ((0, (1, 0), (0, 1)), (90, (0, 1), (-1, 0)))
        shifted_source = optics.Source(band=:H, magnitude=2, wavelength=1.65e-6,
            separation_arcsec=scale, position_angle_deg=angle, T=Float32)
        shifted = optics.prepare_direct_imaging(pupil, shifted_source; zero_padding=2)
        values = optics.intensity_values(optics.form_direct_image!(shifted))
        @test shifted.plan.shift_samples == raw_shift
        @test values == circshift(raw, raw_shift)
        display = similar(reference)
        Observation.form_focal_image!(display, values)
        @test display == circshift(reference, image_shift)
    end
end
end
