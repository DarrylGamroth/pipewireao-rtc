using Test
include("sustained_metrics.jl")
using .SustainedMetrics

const MODEL_PERIOD_NS = Int64(2_000_000)

function timing(sequence; published=Int64(sequence * MODEL_PERIOD_NS), latency=UInt64(100_000))
    return (; sequence=UInt64(sequence), end_to_end_latency_nanoseconds=latency,
        source_published_nanoseconds=published,
        command_received_nanoseconds=published + Int64(latency))
end

function add!(metrics, command, sequence=metrics.count + 1; t=timing(sequence),
              timestamp=Int64(sequence - 1) * MODEL_PERIOD_NS, duration=UInt64(200_000))
    return observe!(metrics, UInt64(sequence), timestamp, MODEL_PERIOD_NS, t, duration, command)
end

function fill_warmup!(metrics, command)
    for sequence in 1:256
        add!(metrics, command, sequence)
    end
    return nothing
end

@testset "bounded construction and reset" begin
    @test_throws ArgumentError Metrics(0)
    @test_throws ArgumentError Metrics(65537)
    @test_throws ArgumentError Metrics(true)
    @test_throws ArgumentError Metrics(1; warmup=-1)
    @test_throws ArgumentError Metrics(1; command_scale_to_um=Inf)
    @test_throws ArgumentError Metrics(1; command_scale_to_um=true)
    @test_throws ArgumentError Metrics(1; wall_period_ns=-1)
    @test Base.summarysize(Metrics(1024)) == Base.summarysize(Metrics(65536))
    shortest = Metrics(1)
    add!(shortest, zeros(Float32, 277))
    @test report(shortest).completed && report(shortest).measured_count == 0
    @test report(shortest).warmup_count == 1
    metrics = Metrics(2; warmup=0)
    command = zeros(Float32, 277)
    command[1] = 0.8f-6
    command[2] = -0.2f-6
    add!(metrics, command)
    command .= 0
    add!(metrics, command)
    result = report(metrics)
    @test result.completed && result.count == result.measured_count == 2
    @test result.command.value_count == 554
    @test result.command.nonzero_value_count == 2
    @test result.command.nonzero_exchange_count == 1
    @test result.command.rail_value_count == result.command.rail_exchange_count == 1
    @test result.command.maximum_absolute ≈ 0.8 atol=1e-7
    @test result.whole_span_nanoseconds == result.measurement_span_nanoseconds == 2_100_000
    @test result.maximum_source_gap_nanoseconds == 2_000_000
    @test result.source_interval.count == 1
    @test_throws ArgumentError add!(metrics, command)
    @test metrics.count == 2
    @test reset!(metrics) === nothing
    empty = report(metrics)
    @test empty.count == empty.measured_count == empty.command.value_count == 0
    @test empty.command.maximum_absolute == 0
    @test empty.command.nonzero_value_count == empty.command.rail_value_count == 0
    @test empty.maximum_source_gap_nanoseconds == empty.measurement_span_nanoseconds == 0
    @test empty.source_interval.count == empty.source_to_command.count == empty.exchange.count == 0
    @test empty.source_to_command.quantiles.p50 === nothing
    @test all(iszero, metrics.source_to_command.bins)
    @test add!(metrics, command) === nothing
end

@testset "every exchange is validated after the 256-frame prefix" begin
    metrics = Metrics(1024)
    command = zeros(Float32, 277)
    command[1] = 0.1f-6
    fill_warmup!(metrics, command)
    before = report(metrics)
    @test before.count == 256 && before.measured_count == 0
    @test before.command.nonzero_value_count == 256
    @test_throws ArgumentError add!(metrics, command, 258)
    @test_throws ArgumentError add!(metrics, command; timestamp=Int64(1))
    @test_throws ArgumentError add!(metrics, command; t=merge(timing(257), (; sequence=UInt64(258))))
    @test_throws ArgumentError add!(metrics, command; t=merge(timing(257), (; end_to_end_latency_nanoseconds=UInt64(1))))
    @test_throws ArgumentError add!(metrics, command; t=timing(257; published=Int64(256 * MODEL_PERIOD_NS)))
    @test_throws ArgumentError add!(metrics, command; t=merge(timing(257), (; command_received_nanoseconds=Int64(0))))
    @test_throws ArgumentError add!(metrics, command; duration=-1)
    @test_throws ArgumentError observe!(metrics, UInt64(257), Int64(256) * MODEL_PERIOD_NS,
        MODEL_PERIOD_NS + 1, timing(257), UInt64(200_000), command)
    @test_throws ArgumentError add!(metrics, command; t=merge(timing(257), (; end_to_end_latency_nanoseconds=-1)))
    @test_throws DimensionMismatch add!(metrics, zeros(Float32, 276))
    for invalid in (NaN32, Inf32, -Inf32, 0.9f-6)
        command[277] = invalid
        @test_throws ArgumentError add!(metrics, command)
        @test report(metrics) == before
    end
    command[277] = 0
    @test report(metrics) == before
    add!(metrics, command)
    @test metrics.count == 257 && metrics.measured_count == 1
    @test metrics.command_value_count == 277 * 257
    @test metrics.nonzero_command_value_count == 257
    @test metrics.source_interval.count == 0
    add!(metrics, command)
    @test metrics.source_interval.count == 1
    @test metrics.source_to_command.count == metrics.exchange.count == 2
end

@testset "command tolerance and timing input boundaries" begin
    metrics = Metrics(3; warmup=0, command_scale_to_um=1)
    command = zeros(Float64, 277)
    command[1] = 0.8 + SustainedMetrics.COMMAND_TOLERANCE_UM
    @test add!(metrics, command) === nothing
    command[1] = nextfloat(command[1])
    @test_throws ArgumentError add!(metrics, command)
    @test metrics.count == 1
    command[1] = -(0.8 - SustainedMetrics.COMMAND_TOLERANCE_UM)
    add!(metrics, command)
    @test metrics.rail_command_value_count == 2
    command[1] = prevfloat(abs(command[1]))
    add!(metrics, command)
    @test metrics.rail_command_value_count == 2
    fresh = Metrics(1; warmup=0)
    zero_command = zeros(Float32, 277)
    @test_throws ArgumentError observe!(fresh, 1, 0, typemax(UInt64), timing(1), 1, zero_command)
    @test_throws ArgumentError observe!(fresh, 1, 0, MODEL_PERIOD_NS, nothing, 1, zero_command)
    @test_throws ArgumentError observe!(fresh, 1, 0, MODEL_PERIOD_NS,
        merge(timing(1), (; source_published_nanoseconds=-1)), 1, zero_command)
    @test fresh.count == 0
    @test observe!(fresh, 1, 0, MODEL_PERIOD_NS, timing(1; published=0, latency=0), 0, zero_command) === nothing
end

@testset "histogram precision, overflow and separate wall period" begin
    metrics = Metrics(5; warmup=0, wall_period_ns=10_000)
    command = zeros(Float32, 277)
    durations = (UInt64(0), UInt64(9_999), UInt64(10_000), UInt64(1_000_000_000), UInt64(1_000_000_001))
    for (sequence, duration) in enumerate(durations)
        add!(metrics, command, sequence; t=timing(sequence; published=Int64(sequence * 20_000), latency=duration), duration)
    end
    result = report(metrics)
    histogram = result.source_to_command
    @test histogram.count == 5 && histogram.overflow_count == 1
    @test histogram.minimum_nanoseconds == 0
    @test histogram.maximum_nanoseconds == 1_000_000_001
    @test histogram.above_comparison_period_count == 2
    @test histogram.quantiles.p50 == (; lower_nanoseconds=UInt64(10_000), upper_nanoseconds=UInt64(19_999))
    @test histogram.quantiles.p99 == (; lower_nanoseconds=UInt64(1_000_000_001), upper_nanoseconds=nothing)
    @test SustainedMetrics.quantile_bounds(metrics.source_to_command, 4, 5) ==
        (; lower_nanoseconds=UInt64(1_000_000_000), upper_nanoseconds=UInt64(1_000_000_000))
    @test result.source_interval.count == 4 && result.source_interval.above_comparison_period_count == 4
    @test result.source_interval_extra_periods == 4
    @test result.wall_period_nanoseconds == 10_000
    @test result.comparison_period_nanoseconds == 10_000
    @test result.comparison_scope == "configured wall-period comparison"
    @test result.model_period_nanoseconds == MODEL_PERIOD_NS
end

@testset "unpaced reports preserve absent wall schedule" begin
    metrics = Metrics(2; warmup=0, wall_period_ns=0)
    command = zeros(Float32, 277)
    for sequence in 1:2
        add!(metrics, command, sequence;
            t=timing(sequence; published=Int64(sequence * 4_000_000), latency=UInt64(3_000_000)),
            duration=UInt64(5_000_000))
    end
    result = report(metrics)
    @test result.wall_period_nanoseconds == 0
    @test result.comparison_period_nanoseconds == result.model_period_nanoseconds == MODEL_PERIOD_NS
    @test result.comparison_scope == "model-period budget only; no wall schedule"
    @test result.source_to_command.above_comparison_period_count == 2
    @test result.exchange.above_comparison_period_count == 2
    @test result.source_interval.above_comparison_period_count == 1
    @test result.source_interval_extra_periods == 1
    @test occursin("comparison period", result.source_interval_extra_periods_definition)
    @test !hasproperty(result.source_to_command, :above_wall_period_count)
end

function hot_path_bytes(metrics, command)
    sequence = metrics.count + 1
    t = timing(sequence)
    timestamp = Int64(sequence - 1) * MODEL_PERIOD_NS
    return @allocated observe!(metrics, UInt64(sequence), timestamp, MODEL_PERIOD_NS,
        t, UInt64(200_000), command)
end

@testset "zero allocation successful hot path" begin
    metrics = Metrics(65536)
    command = fill(0.1f-6, 277)
    fill_warmup!(metrics, command)
    hot_path_bytes(metrics, command) # Warm the exact measured signature and function barrier.
    @test hot_path_bytes(metrics, command) == 0
    @test hot_path_bytes(metrics, command) == 0
    @test metrics.count == 259
    @test metrics.command_value_count == 277 * 259
    for sequence in 260:65536
        add!(metrics, command, sequence)
    end
    @test metrics.count == 65536 && metrics.measured_count == 65536 - 256
    @test metrics.command_value_count == metrics.nonzero_command_value_count == 277 * 65536
    @test metrics.source_to_command.count == metrics.exchange.count == 65536 - 256
    @test metrics.source_interval.count == 65536 - 257
    @test_throws ArgumentError add!(metrics, command)
    @test metrics.count == 65536
end
