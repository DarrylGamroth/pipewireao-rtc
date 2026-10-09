module SustainedMetrics

export Metrics, observe!, reset!, report

const BIN_WIDTH_NS = UInt64(10_000)
const HISTOGRAM_LIMIT_NS = UInt64(1_000_000_000)
const BIN_COUNT = Int(HISTOGRAM_LIMIT_NS ÷ BIN_WIDTH_NS) + 1
const COMMAND_LIMIT_UM = 0.8
const COMMAND_TOLERANCE_UM = Float64(8eps(0.8f0))

mutable struct Histogram
    bins::Vector{UInt64}
    count::UInt64
    overflow::UInt64
    minimum::UInt64
    maximum::UInt64
    above_comparison_period::UInt64
end

Histogram() = Histogram(zeros(UInt64, BIN_COUNT), 0, 0, typemax(UInt64), 0, 0)

function reset!(histogram::Histogram)
    fill!(histogram.bins, 0)
    histogram.count = histogram.overflow = histogram.maximum = histogram.above_comparison_period = 0
    histogram.minimum = typemax(UInt64)
    return nothing
end

function observe!(histogram::Histogram, duration::UInt64, comparison_period::UInt64)
    if duration > HISTOGRAM_LIMIT_NS
        histogram.overflow += 1
    else
        histogram.bins[Int(duration ÷ BIN_WIDTH_NS) + 1] += 1
    end
    histogram.count += 1
    histogram.minimum = min(histogram.minimum, duration)
    histogram.maximum = max(histogram.maximum, duration)
    histogram.above_comparison_period += duration > comparison_period
    return nothing
end

"""Process-local metrics for 1–65536 adopted exchanges, with constant storage.

Commands are the 277-element plant buffer in metre OPD by default. Successful
`observe!` calls allocate no heap storage after specialization is warmed. Report
construction and rejection paths are cold operations. Histograms exclude the
first `warmup` exchanges; command validation and whole-run statistics never do.
The optional wall period is independent of the model period passed to observe!.
A zero wall period means unpaced operation. Timing comparisons then use only
the model-period budget and do not establish a wall schedule.
"""
mutable struct Metrics
    total::Int
    warmup::Int
    command_scale_to_um::Float64
    wall_period_ns::UInt64
    model_period_ns::Int64
    count::Int
    measured_count::Int
    command_value_count::UInt64
    nonzero_command_value_count::UInt64
    nonzero_command_count::UInt64
    rail_command_value_count::UInt64
    rail_command_count::UInt64
    command_max_abs_um::Float64
    first_source_ns::Int64
    last_source_ns::Int64
    last_command_ns::Int64
    measured_first_source_ns::Int64
    measured_last_command_ns::Int64
    maximum_source_gap_ns::UInt64
    measured_maximum_source_gap_ns::UInt64
    source_interval_extra_periods::UInt64
    source_to_command::Histogram
    source_interval::Histogram
    exchange::Histogram
end

function Metrics(total::Integer; warmup::Integer=256, command_scale_to_um::Real=1e6,
                 wall_period_ns::Integer=0)
    !(total isa Bool) && 1 <= total <= 65536 || throw(ArgumentError("exchange total must be 1–65536"))
    !(warmup isa Bool) && 0 <= warmup <= 65536 || throw(ArgumentError("warmup must be 0–65536"))
    !(wall_period_ns isa Bool) && 0 <= wall_period_ns <= typemax(Int64) ||
        throw(ArgumentError("wall period must be a nonnegative Int64 nanosecond duration"))
    command_scale_to_um isa Bool && throw(ArgumentError("command scale must be a numeric unit conversion"))
    scale = Float64(command_scale_to_um)
    isfinite(scale) && scale > 0 || throw(ArgumentError("command scale must be finite and positive"))
    return Metrics(Int(total), Int(warmup), scale, UInt64(wall_period_ns), 0, 0, 0,
        0, 0, 0, 0, 0, 0.0, 0, 0, 0, 0, 0, 0, 0, 0,
        Histogram(), Histogram(), Histogram())
end

function reset!(metrics::Metrics)
    metrics.model_period_ns = metrics.count = metrics.measured_count = 0
    metrics.command_value_count = metrics.nonzero_command_value_count = metrics.nonzero_command_count = 0
    metrics.rail_command_value_count = metrics.rail_command_count = 0
    metrics.command_max_abs_um = 0.0
    metrics.first_source_ns = metrics.last_source_ns = metrics.last_command_ns = 0
    metrics.measured_first_source_ns = metrics.measured_last_command_ns = 0
    metrics.maximum_source_gap_ns = metrics.measured_maximum_source_gap_ns = 0
    metrics.source_interval_extra_periods = 0
    reset!(metrics.source_to_command)
    reset!(metrics.source_interval)
    reset!(metrics.exchange)
    return nothing
end

nanoseconds(value) = value isa Integer && !(value isa Bool) && 0 <= value <= typemax(Int64)
duration_nanoseconds(value) = value isa Integer && !(value isa Bool) && 0 <= value <= typemax(UInt64)

"""Validate the entire exchange before changing any counters or histogram bins.

Timing describes source publication to command reception only. Exchange timing
is measured by the owner around its complete exchange, including plant work.
No frame or command payload is retained or copied.
"""
function observe!(metrics::Metrics, sequence, model_timestamp_ns, period_ns, timing,
                  exchange_ns, command::AbstractVector{<:Real})
    next = metrics.count + 1
    next <= metrics.total || throw(ArgumentError("exchange exceeds bounded total"))
    sequence isa Integer && !(sequence isa Bool) && sequence == next ||
        throw(ArgumentError("exchange sequence must be the next count"))
    nanoseconds(period_ns) && period_ns > 0 && period_ns <= typemax(Int64) ÷ metrics.total ||
        throw(ArgumentError("invalid or overflowing model period"))
    metrics.count == 0 || period_ns == metrics.model_period_ns ||
        throw(ArgumentError("model period changed during run"))
    nanoseconds(model_timestamp_ns) && model_timestamp_ns == (next - 1) * Int64(period_ns) ||
        throw(ArgumentError("model timestamp does not match exchange sequence"))
    timing === nothing && throw(ArgumentError("exchange timing is missing"))
    timing.sequence isa Integer && !(timing.sequence isa Bool) && timing.sequence == sequence ||
        throw(ArgumentError("timing sequence does not match exchange"))
    published = timing.source_published_nanoseconds
    received = timing.command_received_nanoseconds
    latency = timing.end_to_end_latency_nanoseconds
    nanoseconds(published) && nanoseconds(received) && received >= published ||
        throw(ArgumentError("invalid source/command timing"))
    duration_nanoseconds(latency) && UInt64(Int64(received) - Int64(published)) == latency ||
        throw(ArgumentError("source/command latency disagrees with timestamps"))
    metrics.count == 0 || published > metrics.last_source_ns ||
        throw(ArgumentError("source publication timestamps must increase"))
    duration_nanoseconds(exchange_ns) || throw(ArgumentError("invalid exchange duration"))
    length(command) == 277 || throw(DimensionMismatch("requires 277 adopted commands"))
    maximum = 0.0
    nonzero = UInt64(0)
    rails = UInt64(0)
    for index in eachindex(command)
        value = command[index]
        isfinite(value) || throw(ArgumentError("adopted command is not finite"))
        absolute_um = abs(Float64(value)) * metrics.command_scale_to_um
        absolute_um <= COMMAND_LIMIT_UM + COMMAND_TOLERANCE_UM ||
            throw(ArgumentError("adopted command exceeds 0.8 micrometre limit"))
        maximum = max(maximum, absolute_um)
        nonzero += !iszero(value)
        rails += absolute_um >= COMMAND_LIMIT_UM - COMMAND_TOLERANCE_UM
    end

    # All possible input failures precede the first mutation.
    comparison_period = metrics.wall_period_ns == 0 ? UInt64(period_ns) : metrics.wall_period_ns
    gap = metrics.count == 0 ? UInt64(0) : UInt64(Int64(published) - metrics.last_source_ns)
    metrics.model_period_ns = Int64(period_ns)
    metrics.command_value_count += 277
    metrics.nonzero_command_value_count += nonzero
    metrics.nonzero_command_count += nonzero > 0
    metrics.rail_command_value_count += rails
    metrics.rail_command_count += rails > 0
    metrics.command_max_abs_um = max(metrics.command_max_abs_um, maximum)
    metrics.maximum_source_gap_ns = max(metrics.maximum_source_gap_ns, gap)
    next == 1 && (metrics.first_source_ns = Int64(published))
    metrics.last_source_ns = Int64(published)
    metrics.last_command_ns = Int64(received)
    if next > metrics.warmup
        metrics.measured_count += 1
        metrics.measured_count == 1 && (metrics.measured_first_source_ns = Int64(published))
        metrics.measured_last_command_ns = Int64(received)
        observe!(metrics.source_to_command, UInt64(latency), comparison_period)
        observe!(metrics.exchange, UInt64(exchange_ns), comparison_period)
        # Intervals require both endpoints to be in the measured population.
        if metrics.measured_count > 1
            observe!(metrics.source_interval, gap, comparison_period)
            metrics.measured_maximum_source_gap_ns = max(metrics.measured_maximum_source_gap_ns, gap)
            metrics.source_interval_extra_periods += gap > comparison_period ? gap ÷ comparison_period - 1 : 0
        end
    end
    metrics.count = next
    return nothing
end

function quantile_bounds(histogram::Histogram, numerator::Int, denominator::Int)
    histogram.count == 0 && return nothing
    rank = cld(histogram.count * UInt64(numerator), UInt64(denominator))
    cumulative = UInt64(0)
    for index in eachindex(histogram.bins)
        cumulative += histogram.bins[index]
        if cumulative >= rank
            lower = UInt64(index - 1) * BIN_WIDTH_NS
            upper = min(lower + BIN_WIDTH_NS - 1, HISTOGRAM_LIMIT_NS)
            return (; lower_nanoseconds=lower, upper_nanoseconds=upper)
        end
    end
    return (; lower_nanoseconds=HISTOGRAM_LIMIT_NS + 1, upper_nanoseconds=nothing)
end

function histogram_report(histogram::Histogram)
    return (; count=histogram.count, overflow_count=histogram.overflow,
        bin_width_nanoseconds=BIN_WIDTH_NS, inclusive_limit_nanoseconds=HISTOGRAM_LIMIT_NS,
        above_comparison_period_count=histogram.above_comparison_period,
        minimum_nanoseconds=histogram.count == 0 ? nothing : histogram.minimum,
        maximum_nanoseconds=histogram.count == 0 ? nothing : histogram.maximum,
        quantiles=(; p50=quantile_bounds(histogram, 50, 100), p90=quantile_bounds(histogram, 90, 100),
            p95=quantile_bounds(histogram, 95, 100), p99=quantile_bounds(histogram, 99, 100),
            p999=quantile_bounds(histogram, 999, 1000)))
end

"""Build a JSON-friendly report; this cold operation intentionally allocates."""
function report(metrics::Metrics)
    return (; total=metrics.total, count=metrics.count, completed=metrics.count == metrics.total,
        warmup_count=min(metrics.count, metrics.warmup), configured_warmup_count=metrics.warmup,
        measured_count=metrics.measured_count, model_period_nanoseconds=metrics.model_period_ns,
        wall_period_nanoseconds=metrics.wall_period_ns,
        comparison_period_nanoseconds=metrics.wall_period_ns == 0 ? UInt64(metrics.model_period_ns) : metrics.wall_period_ns,
        comparison_scope=metrics.wall_period_ns == 0 ? "model-period budget only; no wall schedule" : "configured wall-period comparison",
        timing_scope="process-local observations; preparation and configured warmup excluded from histograms",
        source_to_command_scope="source publication to adopted command reception; excludes plant simulation",
        exchange_scope="owner complete exchange including plant work",
        whole_span_nanoseconds=metrics.count == 0 ? UInt64(0) : UInt64(metrics.last_command_ns - metrics.first_source_ns),
        measurement_span_nanoseconds=metrics.measured_count == 0 ? UInt64(0) :
            UInt64(metrics.measured_last_command_ns - metrics.measured_first_source_ns),
        first_source_published_nanoseconds=metrics.count == 0 ? nothing : metrics.first_source_ns,
        last_command_received_nanoseconds=metrics.count == 0 ? nothing : metrics.last_command_ns,
        maximum_source_gap_nanoseconds=metrics.maximum_source_gap_ns,
        measured_maximum_source_gap_nanoseconds=metrics.measured_maximum_source_gap_ns,
        source_interval_extra_periods=metrics.source_interval_extra_periods,
        source_interval_extra_periods_definition="derived sum(max(floor(source interval / comparison period) - 1, 0)) over measured intervals; budget comparison only, not scheduler deadline misses",
        command=(; units="micrometre OPD", limit=COMMAND_LIMIT_UM, tolerance=COMMAND_TOLERANCE_UM,
            value_count=metrics.command_value_count, nonzero_value_count=metrics.nonzero_command_value_count,
            nonzero_exchange_count=metrics.nonzero_command_count, rail_value_count=metrics.rail_command_value_count,
            rail_exchange_count=metrics.rail_command_count, maximum_absolute=metrics.command_max_abs_um),
        source_to_command=histogram_report(metrics.source_to_command),
        source_interval=histogram_report(metrics.source_interval), exchange=histogram_report(metrics.exchange))
end

end # module
