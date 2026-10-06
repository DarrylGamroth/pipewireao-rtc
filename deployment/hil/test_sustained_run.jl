using Test
include("owner_protocol.jl")
include("correction_truth.jl")
include("sustained_metrics.jl")
include("sustained_run.jl")

const SR_PERIOD_NS = UInt64(2_000_000)

function sustained_arguments(root; extra=String[])
    return [
        "--profile", "classic", "--graph", joinpath(root, "plant.toml"),
        "--rate", "500", "--exposure-ns", "1896000", "--remote", joinpath(root,"mock-core"),
        "--prepared-event", joinpath(root, "prepared"),
        "--connect-request", joinpath(root, "connect-request"),
        "--connect-reply", joinpath(root, "connect-reply"),
        "--quit-request", joinpath(root, "quit"),
        "--control-request", joinpath(root, "control-request"),
        "--control-reply", joinpath(root, "control-reply"),
        "--output", joinpath(root, "report.json"), extra...,
    ]
end

@testset "sustained owner CLI preserves model time" begin
    mktempdir() do root
        parse(extra=String[]) = HILOwnerProtocol.parse_options(sustained_arguments(root; extra))
        ordinary = parse()
        @test ordinary.total_exchanges == ordinary.frames == 16
        @test ordinary.wall_rate == ordinary.rate == 500
        @test ordinary.wall_period_ns == ordinary.period_ns == SR_PERIOD_NS
        @test !ordinary.sustained
        @test parse(["--total-exchanges", "0"]).total_exchanges == 16
        prefix = ["--frames", "256", "--total-exchanges", "1024"]
        paced = parse(prefix)
        @test paced.sustained && paced.frames == 256 && paced.total_exchanges == 1024
        @test paced.wall_rate == 500 && paced.wall_period_ns == SR_PERIOD_NS
        unpaced = parse([prefix; "--wall-rate"; "unpaced"])
        @test unpaced.sustained && unpaced.wall_rate == unpaced.wall_period_ns == 0
        @test unpaced.period_ns == SR_PERIOD_NS && unpaced.exposure_ns == 1_896_000
        slower = parse([prefix; "--wall-rate"; "100"])
        @test slower.wall_rate == 100 && slower.wall_period_ns == 10_000_000
        @test slower.period_ns == SR_PERIOD_NS
        @test parse([prefix; "--wall-rate"; "default"]).wall_rate == 500
        @test parse(["--total-exchanges", "65536"]).total_exchanges == 65536
        @test !parse(["--frames", "256", "--total-exchanges", "256"]).sustained
        for invalid in ("-1", "65537", "1.5", "true", string(big(2)^100))
            @test_throws ArgumentError parse(["--total-exchanges", invalid])
        end
        @test_throws ArgumentError parse(["--frames", "256", "--total-exchanges", "255"])
        @test_throws ArgumentError parse(["--frames", "257", "--total-exchanges", "1024"])
        for invalid in ("0", "501", "-1", "100.5", "fast")
            @test_throws ArgumentError parse([prefix; "--wall-rate"; invalid])
        end
        @test_throws ArgumentError parse(["--wall-rate", "unpaced"])
        @test_throws ArgumentError parse(["--wall-rate", "100"])
        heart = ["--transport", "heart", "--controller-node", "fixture.heart",
            "--controller-pid", "123", "--controller-instance", "17"]
        @test !parse(heart).sustained
        @test_throws ArgumentError parse([heart; prefix])
        @test_throws ArgumentError parse([heart; prefix; "--wall-rate"; "unpaced"])
    end
end

function mock_sustained_run(; total=1024, profile=:classic, truth=true)
    config = (; resolution=4, diameter=1.0, central_obstruction=0.0,
        pupil_reflectivity=1.0, revision=1, exposure_seconds=0.001896)
    mask = Bool[true true false false; true true false false;
        false false true true; false false true true]
    witness = truth ? CorrectionTruth.Witness(config, mask, 256) : nothing
    options = (; profile, total_exchanges=total, frames=256, wall_period_ns=UInt64(0))
    return SustainedRun.Run(options, witness)
end

function sr_timing(sequence)
    source = Int64(sequence) * Int64(SR_PERIOD_NS)
    return (; sequence=UInt64(sequence), source_published_nanoseconds=source,
        command_received_nanoseconds=source + 100_000,
        end_to_end_latency_nanoseconds=UInt64(100_000))
end

function sr_observe!(run, command, frame, sequence=run.metrics.count + 1)
    return SustainedRun.observe!(run, UInt64(sequence), Int64(sequence - 1) * Int64(SR_PERIOD_NS),
        SR_PERIOD_NS, sr_timing(sequence), UInt64(200_000), command, frame)
end

function observe_allocation(run, command, frame)
    sequence = run.metrics.count + 1
    timestamp = Int64(sequence - 1) * Int64(SR_PERIOD_NS)
    timing = sr_timing(sequence)
    return @allocated SustainedRun.observe!(run, UInt64(sequence), timestamp, SR_PERIOD_NS,
        timing, UInt64(200_000), command, frame)
end

function sample_allocation(run, atmosphere, pupil, surface, sequence)
    timestamp = Int64(sequence - 1) * Int64(SR_PERIOD_NS)
    return @allocated SustainedRun.sample!(run, atmosphere, pupil, surface, UInt64(sequence), timestamp)
end

@testset "retained truth prefix and global sparse samples" begin
    run = mock_sustained_run()
    command = zeros(Float32, 277)
    frame = fill(100f0, 4, 4)
    frame[1] = 4095f0
    atmosphere = reshape(Float32.(1:16), 4, 4) .* 1f-6
    pupil = atmosphere .* 0.5f0
    surface = atmosphere - pupil
    originals = (copy(atmosphere), copy(pupil), copy(surface), copy(command), copy(frame))
    staging = run.truth.staging
    for sequence in 1:256
        sr_observe!(run, command, frame, sequence)
        staged = CorrectionTruth.stage!(run.truth, atmosphere, pupil, surface)
        CorrectionTruth.record!(run.truth, staged..., UInt64(sequence), Int64(sequence - 1) * Int64(SR_PERIOD_NS))
        SustainedRun.sample!(run, atmosphere, pupil, surface, UInt64(sequence), Int64(sequence - 1) * Int64(SR_PERIOD_NS))
    end
    @test run.truth.count == run.metrics.count == 256
    @test run.sample_count == 0 && run.metrics.measured_count == 0
    @test run.sample_stride == 128 && length(run.sample_sequences) == 8
    prefix = (copy(run.truth.sequences), copy(run.truth.model_timestamps_ns),
        copy(run.truth.atmosphere_sha256), copy(run.truth.pupil_sha256), copy(run.truth.surface_sha256))
    before = SustainedRun.report(run)
    for invalid in (NaN32, Inf32, -1f0, 4096f0)
        frame[16] = invalid
        @test_throws ArgumentError sr_observe!(run, command, frame)
        @test SustainedRun.report(run) == before
    end
    frame[16] = 100f0
    for invalid in (NaN32, Inf32, 0.9f-6)
        command[277] = invalid
        @test_throws ArgumentError sr_observe!(run, command, frame)
        @test SustainedRun.report(run) == before
    end
    command[277] = 0
    observe_allocation(run, command, frame) # Compile the measured wrapper.
    @test observe_allocation(run, command, frame) == 0
    @test run.metrics.count == 258
    for sequence in 259:1024
        sr_observe!(run, command, frame, sequence)
        SustainedRun.sample!(run, atmosphere, pupil, surface, UInt64(sequence), Int64(sequence - 1) * Int64(SR_PERIOD_NS))
    end
    result = SustainedRun.report(run)
    expected = UInt64[384, 512, 640, 768, 896, 1024]
    @test run.sample_count == 6
    @test run.sample_sequences[1:6] == expected
    @test run.sample_model_ns[1:6] == Int64.(expected .- 1) .* Int64(SR_PERIOD_NS)
    @test all(iszero, run.sample_sequences[7:end])
    @test getproperty.(result.truth.samples, :sequence) == expected
    @test getproperty.(result.truth.samples, :model_timestamp_ns) == run.sample_model_ns[1:6]
    @test all(==(CorrectionTruth.pupil_variance(atmosphere, run.truth.mask)), run.atmosphere_variance_m2[1:6])
    @test all(==(CorrectionTruth.pupil_variance(pupil, run.truth.mask)), run.residual_variance_m2[1:6])
    @test run.truth.count == 256
    @test (run.truth.sequences, run.truth.model_timestamps_ns, run.truth.atmosphere_sha256,
        run.truth.pupil_sha256, run.truth.surface_sha256) == prefix
    @test all(index -> run.truth.staging[index] === staging[index], 1:3)
    @test (atmosphere, pupil, surface, command, frame) == originals
    @test result.metrics.completed && result.metrics.count == 1024
    @test result.metrics.measured_count == 768 && result.metrics.source_interval.count == 767
    @test result.detector.maximum_adc == 4095
    @test result.detector.upper_rail_pixels == result.detector.upper_rail_frames == 1024
    @test result.allocation === nothing
    @test SustainedRun.reset!(run) === nothing
    @test run.metrics.count == run.sample_count == run.adc_maximum == run.adc_rail_pixels == run.adc_rail_frames == 0
    @test all(iszero, run.sample_sequences) && all(iszero, run.sample_model_ns)
    @test all(iszero, run.atmosphere_variance_m2) && all(iszero, run.residual_variance_m2)
    @test run.allocation_start === run.allocation_finish === nothing
    # Recorder reset owns the shared prefix witness; sustained reset owns its
    # counters and sparse samples. Exercise the same pair of owner resets.
    CorrectionTruth.reset!(run.truth)
    @test run.truth.count == 0
    @test sr_observe!(run, command, frame) === nothing
end

@testset "sampling storage, diagnostic allocations and ADC quantization" begin
    @test Base.summarysize(mock_sustained_run(total=1024, truth=false).metrics) ==
        Base.summarysize(mock_sustained_run(total=65536, truth=false).metrics)
    @test length(mock_sustained_run(total=65536).sample_sequences) == 512
    run = mock_sustained_run(total=1030)
    atmosphere = reshape(Float32.(1:16), 4, 4)
    pupil = atmosphere .* 0.5f0
    surface = atmosphere - pupil
    sample_allocation(run, atmosphere, pupil, surface, 384)
    @test sample_allocation(run, atmosphere, pupil, surface, 512) == 0
    @test run.truth.count == 0 && all(isempty, run.truth.atmosphere_sha256)
    @test SustainedRun.sample!(run, atmosphere, pupil, surface, UInt64(1024), Int64(1023) * Int64(SR_PERIOD_NS)) === nothing
    @test SustainedRun.sample!(run, atmosphere, pupil, surface, UInt64(1030), Int64(1029) * Int64(SR_PERIOD_NS)) === nothing
    @test run.sample_sequences[1:4] == UInt64[384, 512, 1024, 1030]
    run.sample_count = length(run.sample_sequences)
    @test_throws ArgumentError SustainedRun.sample!(run, atmosphere, pupil, surface,
        UInt64(1030), Int64(1029) * Int64(SR_PERIOD_NS))
    @test run.sample_count == length(run.sample_sequences)
    no_truth = mock_sustained_run(truth=false)
    @test isempty(no_truth.sample_sequences)
    @test SustainedRun.sample!(no_truth, nothing, nothing, nothing, UInt64(384), Int64(0)) === nothing
    @test !SustainedRun.report(no_truth).truth.enabled
    copper = mock_sustained_run(profile=:copper, truth=false)
    command = zeros(Float32, 277)
    frame = Float32[16382.6 0; 0 0]
    sr_observe!(copper, command, frame)
    @test copper.detector_rail == copper.adc_maximum == 16383
    @test copper.adc_rail_pixels == copper.adc_rail_frames == 1
    frame[1] = 16384
    @test_throws ArgumentError sr_observe!(copper, command, frame)
    @test copper.metrics.count == copper.adc_rail_frames == 1
end

# The owner currently keeps scheduling inside run_owner. Evaluate its actual
# parsed scheduling block with an injected clock, without importing a plant or
# starting transport. This checks the owner policy, not a live driver.
function owner_scheduling_blocks!(blocks, expression)
    expression isa Expr || return blocks
    if expression.head === :if && expression.args[1] == :(wall_period == 0)
        push!(blocks, expression)
    end
    for argument in expression.args
        owner_scheduling_blocks!(blocks, argument)
    end
    return blocks
end

function schedule_clock(expression)
    expression isa Expr || return expression
    expression == :(time_ns()) && return :now_ns
    return Expr(expression.head, map(schedule_clock, expression.args)...)
end

module SustainedScheduleFixture
const Protocol = Main.HILOwnerProtocol
mutable struct PrefixCounter
    missed_wall_periods::UInt64
end
end

@testset "synthetic owner scheduler distinguishes prefix and tail misses" begin
    source = Meta.parseall(read(joinpath(@__DIR__, "simulator.jl"), String))
    blocks = owner_scheduling_blocks!(Expr[], source)
    @test length(blocks) == 1
    signature = :(account!(options, recorder, sustained_run, wall_period, state, sequence, now_ns))
    Core.eval(SustainedScheduleFixture, Expr(:function, signature, schedule_clock(only(blocks))))
    options = (; profile=:classic, total_exchanges=258, frames=256, wall_period_ns=SR_PERIOD_NS)
    run = SustainedRun.Run(options, nothing)
    prefix = SustainedScheduleFixture.PrefixCounter(UInt64(0))
    state = HILOwnerProtocol.OwnerState()
    command = zeros(Float32, 277)
    frame = zeros(Float32, 4, 4)
    for sequence in UInt64(1):UInt64(256)
        sr_observe!(run, command, frame, sequence)
        now = state.deadline_ns + SR_PERIOD_NS - UInt64(1)
        Base.invokelatest(SustainedScheduleFixture.account!, options, prefix, run,
            SR_PERIOD_NS, state, sequence, now)
    end
    @test prefix.missed_wall_periods == run.missed_wall_periods == 0
    @test run.metrics.count == 256
    for (sequence, elapsed_periods) in ((UInt64(257), UInt64(3)), (UInt64(258), UInt64(2)))
        sr_observe!(run, command, frame, sequence)
        now = state.deadline_ns + elapsed_periods * SR_PERIOD_NS
        Base.invokelatest(SustainedScheduleFixture.account!, options, prefix, run,
            SR_PERIOD_NS, state, sequence, now)
        @test state.deadline_ns > now
    end
    @test prefix.missed_wall_periods == 0
    @test run.missed_wall_periods == 5
    @test run.metrics.count == 258 && run.metrics.measured_count == 2
    state.deadline_ns = 100
    Base.invokelatest(SustainedScheduleFixture.account!, options, prefix, run,
        UInt64(0), state, UInt64(258), UInt64(typemax(UInt64)))
    @test state.deadline_ns == 0
    @test prefix.missed_wall_periods == 0 && run.missed_wall_periods == 5
    SustainedRun.reset!(run)
    @test run.missed_wall_periods == run.metrics.count == 0
end
