# Cold node construction only; no FFT preparation, GPU, core or services.
using Test, AdaptiveOpticsSim
const AG = AdaptiveOpticsSim.AlgorithmGraphs

@testset "omitted routine values preserve scientific node configurations" begin
    detector = (;rows=8, columns=8, exposure_duration_s=0.002,
        wavelength_m=7.5e-7, quantum_efficiency=0.9, rng_seed=2,
        photon_rate_schema="example.rate/1", frame_schema="example.electrons/1")
    for (factory, config, defaults) in (
            (AG._cmos_detector_acquisition_f32_node,
                merge(detector, (;pixel_scale_arcsec=0.7)),
                (;binning=1, column_readout_noise_e=0.0, row_readout_noise_e=0.0, photon_noise=true)),
            (AG._emccd_detector_acquisition_f32_node,
                merge(detector, (;normalized_pupil_sampling=1/4)),
                (;photon_noise=true, dark_current_e_per_pixel_s=0)),
            (AG._pyramid_rate_f32_node,
                (;resolution=8, telescope_diameter_m=7.77, pupil_samples=4,
                    source_wavelength_m=7.5e-7, source_band="I", source_magnitude=8,
                    opd_schema="example.opd/1", photon_rate_schema="example.rate/1"),
                (;modulation_propagation_strategy="pupil_tilt",
                    pupil_shift_x_pixels=(0, 0, 0, 0), pupil_shift_y_pixels=(0, 0, 0, 0))))
        omitted = factory(:node, config, (;)).config
        explicit = factory(:node, merge(config, defaults), (;)).config
        @test typeof(omitted) === typeof(explicit)
        for key in fieldnames(typeof(omitted))
            @test isequal(getfield(omitted, key), getfield(explicit, key))
        end
        for key in keys(defaults)
            @test_throws AG.AlgorithmGraphError factory(:node, merge(config, NamedTuple{(key,)}((nothing,))), (;))
        end
    end
    @test all(id -> id.name ∉ ("CUDA", "AMDGPU"), keys(Base.loaded_modules))
end
