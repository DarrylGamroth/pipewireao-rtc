# Opt-in CPU diagnostics check. Run in a pinned instrument application environment:
# julia --project=/path/to/application test/aos_optical_observation.jl simulation.conf
using Test, Statistics, Libdl
using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: try_snapshot_graph_output!,
    poll_graph_output_snapshot!, snapshot_metadata, release_graph_output_snapshot!

const Observation = Base.get_extension(PipeWireAORTC, :PipeWireAORTCAOSExt).OpticalObservation

@testset "Piston-removed pupil OPD presentation" begin
    mask = Bool[0 1 1; 1 0 1]
    opd = Float32[Inf 25e-9 75e-9; -25e-9 NaN -75e-9]
    original = copy(opd)
    image = zeros(Float32, size(opd))
    @test Observation.form_wavefront!(image, opd, mask) === image
    @test image[mask] ≈ Float32[ -25, 25, 75, -75 ] atol=1e-5
    @test all(isnan, image[.!mask])
    @test isequal(opd, original)
    @test sqrt(mean(abs2, image[mask])) ≈ std(Float64.(opd[mask]); corrected=false) * 1e9 rtol=1e-6
    @test Observation.pupil_rms_nm(opd, mask) ≈ sqrt(mean(abs2, image[mask])) rtol=1e-6
    @test Observation.pupil_rms_nm(fill(2f-3, size(opd)), mask) == 0
    @test_throws DimensionMismatch Observation.pupil_rms_nm(zeros(3, 2), mask)
    @test_throws ArgumentError Observation.pupil_rms_nm(opd, falses(size(mask)))
    shifted = opd .+ 1f-6
    shifted_image = similar(image)
    Observation.form_wavefront!(shifted_image, shifted, mask)
    @test shifted_image[mask] ≈ image[mask] atol=1e-4
    @test_throws DimensionMismatch Observation.form_wavefront!(zeros(3, 2), opd, mask)
    @test_throws ArgumentError Observation.form_wavefront!(image, opd, falses(size(mask)))
    invalid = copy(opd); invalid[1, 2] = NaN32
    @test_throws ArgumentError Observation.form_wavefront!(image, invalid, mask)
    @test_throws ArgumentError Observation.pupil_rms_nm(invalid, mask)
    closed = Int[]
    @test_throws ErrorException Observation.finalize_snapshots!((1, 2)) do slot
        push!(closed, slot)
        slot == 1 && error("injected first close failure")
    end
    @test closed == [1, 2]
end

@testset "Shared optical observation CPU products" begin
    length(ARGS) == 1 || error("expected an instrument simulation.conf")
    owner = PipeWireAORTC.AOSOwner
    base = owner.configuration(abspath(only(ARGS)))
    instrument = owner.load_instrument(base.plant.package)
    options = merge(base, (; backend=:cpu, device=0, plant_module=instrument,
        remote="/tmp/unused-optical-observation", control_node="simulator-wfs"))
    science = owner.prepare_science(options)
    observation = Observation.prepare(science.definition, science.graph)
    try
        sources = Observation.source_options(observation)
        @test length(sources) == 3
        @test sources[1].schema == Observation.FOCAL_IMAGE_SCHEMA
        @test sources[2].schema == Observation.WAVEFRONT_SCHEMA
        @test sources[2].shape == size(observation.pupil)
        @test sources[2].shape == size(graph_output(science.graph, :pupil_opd))
        @test sources[3].schema == Observation.RMS_SCHEMA
        @test sources[3].shape == (1, 2)
        @test length(sources[3].channels) == 2
        @test getproperty.(sources[3].channels, :index) == (0, 1)
        @test getproperty.(sources[3].channels, :name) ==
            ("uncorrected_atmosphere_rms", "corrected_pupil_rms")
        @test getproperty.(sources[3].channels, :title) ==
            ("Uncorrected atmosphere RMS", "Corrected pupil RMS")
        @test getproperty.(sources[3].channels, :units) == ("nm OPD", "nm OPD")
        @test isempty(Observation.rms_source_options(nothing, Dict{String,String}()))
        for index in 1:4
            stamp = step_hil_frame_at!(science.boundary, science.driver)
            @test Observation.submit!(observation;
                generation=UInt64(3), pts=Int64(index * 2_000_000))
            @test !Observation.submit!(observation; generation=UInt64(3))
            @test Observation.poll!(observation)
            try
                metadata = snapshot_metadata(observation.snapshot)
                @test metadata.sequence == stamp.sequence == index
                @test metadata.generation == 3
                @test metadata.pts == index * 2_000_000
                @test snapshot_metadata(observation.atmosphere_snapshot) == metadata
                before = copy(graph_output(science.graph, :pupil_opd))
                Observation.form_products!(observation)
                @test graph_output(science.graph, :pupil_opd) == before
                @test all(isfinite, observation.values)
                @test all(isfinite, observation.wavefront[observation.pupil])
                @test all(isnan, observation.wavefront[.!observation.pupil])
                values = Float64.(before[observation.pupil])
                expected = std(values; corrected=false) * 1e9
                actual = sqrt(mean(abs2, Float64.(observation.wavefront[observation.pupil])))
                @test actual ≈ expected atol=1e-4
                @test observation.rms[1, 2] ≈ actual atol=1e-4
                @test observation.rms[1, 1] ≈ std(Float64.(graph_output(science.graph,
                    :atmosphere_opd)[observation.pupil]); corrected=false)*1e9 atol=1e-4
                @test abs(mean(Float64.(observation.wavefront[observation.pupil]))) < 1e-4
            finally
                Observation.release!(observation)
            end
            adopt_hil_command!(science.boundary, stamp.sequence)
        end
        # Force a partial admission through the public snapshot seam. Neither
        # member may be silently reused; cold drain must recover both slots.
        @test try_snapshot_graph_output!(observation.atmosphere_snapshot; generation=UInt64(3))
        @test_throws ArgumentError Observation.submit!(observation; generation=UInt64(3))
        @test observation.busy[]
        @test !try_snapshot_graph_output!(observation.snapshot; generation=UInt64(4))
        Observation.drain!(observation)
        @test !observation.busy[]
        @test Observation.submit!(observation; generation=UInt64(4))
        @test Observation.poll!(observation)
        @test snapshot_metadata(observation.snapshot) == snapshot_metadata(observation.atmosphere_snapshot)
        Observation.release!(observation)
        # The public calibration path has no atmosphere; ordinary optical
        # images still prepare, with no invented reference measurement.
        flat = instrument.prepare_calibration_system(; pupil_resolution=size(observation.pupil, 1))
        flat_observation = Observation.prepare(flat.definition, flat.graph)
        try
            @test flat_observation.atmosphere_snapshot === nothing
            flat_sources = Observation.source_options(flat_observation)
            @test length(flat_sources) == 2
            @test all(isempty(source.channels) for source in flat_sources)
            @test Observation.submit!(flat_observation; generation=UInt64(1))
            @test Observation.poll!(flat_observation)
            Observation.form_products!(flat_observation)
            Observation.release!(flat_observation)
        finally
            Observation.close!(flat_observation)
        end
    finally
        Observation.close!(observation)
    end
    @test !any(id -> id.name in ("CUDA", "AMDGPU", "GPUCompiler"), keys(Base.loaded_modules))
    @test isempty(filter(path -> occursin(r"(?i)(libcuda|libcudart|libcublas|libcufft|libamdhip|libhsa-runtime)", path), Libdl.dllist()))
end
