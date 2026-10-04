using Test
include("simulator.jl")
const CT = CorrectionTruth

@testset "shared pupil arithmetic and payload convention" begin
    mask = Bool[true true; false false]
    values = [1.0 3.0; 100.0 200.0]
    @test CT.pupil_variance(values, mask) == 1.0
    @test CT.pupil_variance(values .+ 1000, mask) == 1.0
    @test CT.pupil_variance(values .* 1e-6, mask) ≈ 1e-12
    @test CT.pupil_variance(fill(floatmax(Float64), 2, 2), mask) == 0
    @test CT.pupil_variance([1e16 + 2 1e16; 1e16 1e16], trues(2, 2)) == 0.75
    @test_throws ArgumentError CT.pupil_variance(values, trues(1, 2))
    @test_throws ArgumentError CT.pupil_variance(values, falses(2, 2))
    @test_throws ArgumentError CT.pupil_variance([NaN 0.0; 0.0 0.0], mask)
    @test_throws ArgumentError CT.pupil_variance([floatmax(Float64) -floatmax(Float64); 0.0 0.0], mask)
    expected = UInt32[htol(reinterpret(UInt32, x)) for x in Float32[1, 3, 100, 200]]
    @test CT.opd_hash(Float32.(values)) == bytes2hex(sha256(reinterpret(UInt8, expected)))
end

@testset "bounded frame witness and reset" begin
    config = (; resolution=2, diameter=1.0, central_obstruction=0.0,
        pupil_reflectivity=1.0, revision=1, exposure_seconds=0.001896)
    mask = Bool[true true; false false]
    @test_throws ArgumentError CT.Witness(config, mask, 0)
    @test_throws ArgumentError CT.Witness(config, mask, 257)
    @test_throws ArgumentError CT.Witness(config, falses(2, 2), 2)
    witness = CT.Witness(config, mask, 2)
    atmosphere = Float32[1 3; 100 200]
    pupil = atmosphere .* 0.5f0
    surface = atmosphere - pupil
    original = (copy(atmosphere), copy(pupil), copy(surface))
    @test CT.record!(witness, atmosphere, pupil, surface, UInt64(1), Int64(0)) === nothing
    bounded = CT.Witness(config, mask, 256)
    for n in 1:256
        CT.record!(bounded, atmosphere, pupil, surface, UInt64(n), Int64(n - 1))
    end
    bounded_report = CT.report(bounded; graph_sha256="a"^64, frame_sha256="b"^64,
        command_sha256="c"^64, simulator_sha256="d"^64, completed_frames=256)
    @test bounded_report.observed_frames == length(bounded_report.per_frame) == 256
    @test ncodeunits(Protocol.JSON3.write(bounded_report)) < 200 * 1024
    @test (atmosphere, pupil, surface) == original
    @test CT.stage!(witness, atmosphere, pupil, surface) === witness.staging
    @test witness.staging == original
    @test_throws ArgumentError CT.stage!(witness, zeros(Float32, 1, 2), pupil, surface)
    @test witness.atmosphere_variance_m2[1] == 1.0
    @test witness.residual_variance_m2[1] == 0.25
    @test_throws ArgumentError CT.record!(witness, atmosphere, pupil, surface, UInt64(1), Int64(1))
    @test_throws ArgumentError CT.record!(witness, atmosphere, pupil, surface, UInt64(2), Int64(0))
    @test_throws ArgumentError CT.record!(witness, atmosphere, pupil, fill(Float32(NaN), 2, 2), UInt64(2), Int64(1))
    @test witness.count == 1
    @test CT.record!(witness, atmosphere, pupil, surface, UInt64(2), Int64(100)) === nothing
    @test_throws ArgumentError CT.record!(witness, atmosphere, pupil, surface, UInt64(3), Int64(200))
    report = CT.report(witness; graph_sha256="graph", frame_sha256="frame", command_sha256="command",
        simulator_sha256="owner", completed_frames=2)
    @test report.complete_prefix && report.observed_frames == 2
    @test report.graph_sha256 == "graph" && report.frame_sha256 == "frame" && report.command_sha256 == "command"
    @test report.per_frame[1].sequence == 1 && report.per_frame[2].model_timestamp_ns == 100
    @test report.opd.units == "metre OPD" && report.opd.layout == "ROW_MAJOR"
    @test report.pupil.mask_sha256 == bytes2hex(sha256(UInt8[1, 1, 0, 0]))
    @test !hasproperty(report, :verified) && !hasproperty(report, :baseline_verified)
    @test !hasproperty(report, :clipped) && !hasproperty(report, :correction_accepted)
    @test !hasproperty(report.per_frame[1], :residual_to_atmosphere_variance_ratio)
    @test CT.reset!(witness) === nothing
    @test witness.count == 0 && all(iszero, witness.sequences) && all(isempty, witness.pupil_sha256)
    @test CT.record!(witness, atmosphere, pupil, surface, UInt64(1), Int64(0)) === nothing
end

@testset "optional preparation and public annular pupil" begin
    @test prepare_correction_truth((;), nothing) === nothing
    @test record_correction_truth!((; truth=nothing), nothing, UInt64(1), Int64(0)) === nothing
    for options in ((; profile=:unknown, backend=:cpu, correction_diagnostics=true),
                    (; profile=:classic, backend=:unknown, correction_diagnostics=true),
                    (; profile=:classic, backend=:cpu, transport=:unknown, correction_diagnostics=true))
        @test_throws ArgumentError prepare_correction_truth(options, nothing)
    end
    mktempdir() do root
        graph = joinpath(root, "fixture.toml")
        text = join(["""
            [[nodes]]
            name = "$name"
            [nodes.config]
            resolution = 8
            telescope_diameter_m = 1.0
            central_obstruction_ratio = 0.3
            pupil_reflectivity = 0.8
            aperture_revision = 1
            """ for name in ("atmosphere", "pdm", "shwfs")]) * """
            [[nodes]]
            name = "detector"
            [nodes.config]
            exposure_duration_s = 0.001896
            """
        write(graph, text)
        target = load_target(:cpu)
        witness = CT.prepare_witness(graph, AdaptiveOpticsSim.Optics, target, 2)
        cfg = CT.telescope_config(graph)
        optics = AdaptiveOpticsSim.Optics
        telescope = optics.prepare_telescope(optics.TelescopeDefinition(;
            resolution=cfg.resolution, diameter=cfg.diameter, central_obstruction=cfg.central_obstruction,
            pupil_reflectivity=cfg.pupil_reflectivity, revision=cfg.revision, T=Float32), target)
        @test witness.mask == optics.pupil_mask(telescope)
        @test 0 < count(witness.mask) < 64
        write(graph, replace(text, "name = \"shwfs\"" => "name = \"pwfs\""))
        @test CT.telescope_config(graph) == cfg
        write(graph, replace(text, "name = \"shwfs\"" => "name = \"unknown\""))
        @test_throws ArgumentError CT.telescope_config(graph)
        write(graph, replace(text, "resolution = 8" => "resolution = 9"; count=1))
        @test_throws ArgumentError CT.telescope_config(graph)
    end
end

@testset "completed public model frame survives next-command adoption" begin
    plant = load_plant(:classic)
    mktempdir() do root
        options = (; profile=:classic, backend=:cpu, correction_diagnostics=true,
            graph=Base.invokelatest(plant.graph_path, :grid_gaussian), frames=2,
            rate=500, period_ns=UInt64(2_000_000), exposure_ns=UInt64(1_896_000),
            remote="no-pipewire-connection", output=joinpath(root, "report.json"))
        science = Base.invokelatest(prepare_science, options, plant, load_target(:cpu))
        recorder = Recorder(options, science.boundary; truth=prepare_correction_truth(options, science))
        @test isconcretetype(typeof(recorder)) && fieldtype(typeof(recorder), :truth) == typeof(recorder.truth)
        state = Protocol.OwnerState()
        @test warm_report_writer!(options, science, recorder, state) === nothing
        empty_report = Protocol.JSON3.read(read(options.output, String))
        @test empty_report.correction_truth.observed_frames == 0 && empty_report.completed_frames == 0
        step = step_hil_frame_at!(science.boundary, science.driver)
        hashes = (CT.opd_hash(graph_output(science.graph, :atmosphere_opd)),
                  CT.opd_hash(graph_output(science.graph, :pupil_opd)), CT.opd_hash(graph_output(science.graph, :pdm_surface_opd)))
        fill!(hil_command_buffer(science.boundary), 0.1f-6)
        adopt_hil_command!(science.boundary, step.sequence)
        timestamp = model_nanoseconds(step.timestamp)
        timing = (; sequence=step.sequence, end_to_end_latency_nanoseconds=UInt64(1),
            source_published_nanoseconds=Int64(1), command_received_nanoseconds=Int64(2))
        record!(recorder, science.boundary, step.sequence, science.driver, timestamp, timing, UInt64(1), UInt64(1), UInt64(2))
        @test record_correction_truth!(recorder, science, step.sequence, timestamp) === nothing
        @test (recorder.truth.atmosphere_sha256[1], recorder.truth.pupil_sha256[1], recorder.truth.surface_sha256[1]) == hashes
        @test all(==(0.1f-6), hil_command_buffer(science.boundary))
        state.sequence = step.sequence
        write_report(options, science, recorder, state)
        report = Protocol.JSON3.read(read(options.output, String))
        @test report.correction_truth.complete_prefix
        @test report.correction_truth.graph_sha256 == report.graph_sha256
        @test report.correction_truth.frame_sha256 == report.frame.sha256
        @test report.correction_truth.command_sha256 == report.command.sha256
        @test report.correction_truth.per_frame[1].model_timestamp_ns == report.model_timestamps_ns[1]
        @test report.correction_truth.helper_sha256 == bytes2hex(open(sha256, joinpath(@__DIR__, "correction_truth.jl")))
        reset_recorder!(recorder)
        @test recorder.count == recorder.truth.count == 0
        @test all(iszero, recorder.truth.model_timestamps_ns) && all(isempty, recorder.truth.surface_sha256)
        disabled = Recorder(options, science.boundary)
        @test fieldtype(typeof(disabled), :truth) === Nothing
        write_report(options, science, disabled, Protocol.OwnerState())
        @test !haskey(Protocol.JSON3.read(read(options.output, String)), :correction_truth)
    end
end
