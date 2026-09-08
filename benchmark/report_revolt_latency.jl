#!/usr/bin/env julia

using HdrHistogram
using JSON3
using Pkg
using TOML

const HEADER =
    "implementation,phase,observation,sequence,source_published_ns,command_received_ns,latency_ns"
const MAX_LATENCY_NS = 10_000_000_000
const SIGNIFICANT_FIGURES = 3
const PERCENTILES = Float64[50.0, 90.0, 99.0, 99.9]

function parse_arguments(arguments)
    inputs = String[]
    output = nothing
    for argument in arguments
        if startswith(argument, "--input=")
            push!(inputs, split(argument, '='; limit=2)[2])
        elseif startswith(argument, "--output=")
            output = split(argument, '='; limit=2)[2]
        else
            throw(ArgumentError("unknown argument: $argument"))
        end
    end
    isempty(inputs) && throw(ArgumentError("at least one --input=CSV is required"))
    isnothing(output) && throw(ArgumentError("--output=JSON is required"))
    return (; inputs, output)
end

function parse_latency_csv(path::String, run::Int)
    lines = readlines(path)
    isempty(lines) && error("$path is empty")
    first(lines) == HEADER || error("$path has an unexpected header")
    observations = NamedTuple[]
    prior_sequence = Dict{String,UInt64}()
    expected_observation = Dict{String,Int}()
    counters = Dict{String,Dict{String,Int}}()
    for (record_index, line) in enumerate(lines[2:end])
        line_number = record_index + 1
        fields = split(line, ','; keepempty=true)
        length(fields) == 7 || error("$path:$line_number has $(length(fields)) fields")
        implementation, phase = fields[1], fields[2]
        implementation in ("native", "julia") ||
            error("$path:$line_number has unknown implementation $implementation")
        phase in ("warmup", "measurement") ||
            error("$path:$line_number has unknown phase $phase")
        observation = parse(Int, fields[3])
        sequence = parse(UInt64, fields[4])
        source = parse(Int64, fields[5])
        received = parse(Int64, fields[6])
        latency = parse(UInt64, fields[7])
        source >= 0 || error("$path:$line_number has a negative source timestamp")
        received >= source || error("$path:$line_number command receipt precedes publication")
        latency == UInt64(received - source) ||
            error("$path:$line_number latency does not equal receipt minus publication")
        expected = get(expected_observation, implementation, 1)
        observation == expected ||
            error("$path:$line_number has non-contiguous $implementation observation index")
        haskey(prior_sequence, implementation) && sequence <= prior_sequence[implementation] &&
            error("$path:$line_number has non-increasing $implementation sequence")
        prior_sequence[implementation] = sequence
        expected_observation[implementation] = expected + 1
        implementation_counters = get!(counters, implementation) do
            Dict("warmup" => 0, "measurement" => 0)
        end
        implementation_counters[phase] += 1
        push!(observations, (; run, implementation, phase, observation, sequence, source, received, latency))
    end
    return observations, counters
end

function histogram_summary(observations)
    histogram = HdrHistogram.Histogram(1, MAX_LATENCY_NS, SIGNIFICANT_FIGURES)
    for observation in observations
        HdrHistogram.record_value!(histogram, Int64(observation.latency))
    end
    values = zeros(Int64, length(PERCENTILES))
    HdrHistogram.value_at_percentile(histogram, PERCENTILES, values)
    buckets = [
        Dict(
            "value_ns" => value.value_iterated_to,
            "count" => value.count_at_value_iterated_to,
        ) for value in HdrHistogram.RecordedValuesIterator(histogram)
    ]
    return Dict(
        "samples" => length(observations),
        "p50_ns" => values[1],
        "p90_ns" => length(observations) >= 10 ? values[2] : nothing,
        "p99_ns" => length(observations) >= 100 ? values[3] : nothing,
        "p99_9_ns" => length(observations) >= 1_000 ? values[4] : nothing,
        "max_ns" => max(histogram),
        "mean_ns" => HdrHistogram.mean(histogram),
        "histogram" => Dict(
            "lowest_discernible_value_ns" => 1,
            "highest_trackable_value_ns" => MAX_LATENCY_NS,
            "significant_figures" => SIGNIFICANT_FIGURES,
            "recorded_buckets" => buckets,
        ),
    )
end

function git_record(repository)
    try
        return Dict(
            "revision" => readchomp(Cmd(`git rev-parse HEAD`; dir=repository)),
            "dirty" => !isempty(read(Cmd(`git status --porcelain`; dir=repository), String)),
        )
    catch
        return Dict("revision" => "unavailable", "dirty" => nothing)
    end
end

function environment_record()
    repository = normpath(joinpath(@__DIR__, ".."))
    dependencies = Dict{String,String}()
    for dependency in values(Pkg.dependencies())
        isnothing(dependency.version) && continue
        dependency.name in ("HdrHistogram", "JSON3") || continue
        dependencies[dependency.name] = string(dependency.version)
    end
    return Dict(
        "git" => git_record(repository),
        "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(),
        "julia_cpu_target" => get(ENV, "JULIA_CPU_TARGET", "default"),
        "kernel" => strip(read(`uname -srvmo`, String)),
        "active_project" => Base.active_project(),
        "packages" => dependencies,
        "component_projects" => component_projects(),
        "component_builds" => component_builds(),
    )
end

function component_builds()
    builds = Dict{String,Any}()
    for variable in ("PIPEWIREAO_RTC_PIPEWIRE_BUILD", "PIPEWIREAO_SPA_PLUGINS_BUILD")
        path = get(ENV, variable, nothing)
        isnothing(path) && continue
        builds[variable] = Dict(
            "path" => abspath(path),
            "git" => git_record(dirname(path)),
        )
    end
    return builds
end

function component_projects()
    projects = Dict{String,Any}()
    for variable in (
        "PIPEWIREAO_RTC_PIPEWIREAO_JULIA",
        "PIPEWIREAO_RTC_JULIA_FILTER_GRAPH",
        "PIPEWIREAO_RTC_REVOLT_HIL_PACKAGE",
        "PIPEWIREAO_RTC_AOS_HIL_PACKAGE",
    )
        path = get(ENV, variable, nothing)
        isnothing(path) && continue
        project = joinpath(path, "Project.toml")
        isfile(project) || continue
        parsed = TOML.parsefile(project)
        projects[variable] = Dict(
            "path" => abspath(path),
            "name" => get(parsed, "name", "unknown"),
            "version" => get(parsed, "version", "unknown"),
            "git" => git_record(path),
        )
    end
    return projects
end

function main(arguments)
    options = parse_arguments(arguments)
    all_observations = NamedTuple[]
    counters = Dict{String,Vector{Dict{String,Int}}}("native" => [], "julia" => [])
    for (run, input) in enumerate(options.inputs)
        observations, run_counters = parse_latency_csv(input, run)
        append!(all_observations, observations)
        for implementation in keys(counters)
            haskey(run_counters, implementation) ||
                error("$input has no $implementation latency records")
            push!(counters[implementation], run_counters[implementation])
        end
    end
    runs = Dict{String,Any}()
    combined = Dict{String,Any}()
    for implementation in ("native", "julia")
        implementation_observations = filter(
            observation -> observation.implementation == implementation,
            all_observations,
        )
        measurement_observations = filter(
            observation -> observation.phase == "measurement",
            implementation_observations,
        )
        isempty(measurement_observations) && error("no $implementation measurement records")
        runs[implementation] = [
            histogram_summary(filter(
                observation ->
                    observation.implementation == implementation &&
                    observation.phase == "measurement" && observation.run == run,
                all_observations,
            )) for run in eachindex(options.inputs)
        ]
        combined[implementation] = histogram_summary(measurement_observations)
    end
    result = Dict(
        "format_version" => 1,
        "operation_boundary" =>
            "same-process monotonic Header-PTS at WFS frame publication through receipt of the matching correction command callback",
        "load_model" =>
            "single-frame completion-paced simulated HIL exchange; not a fixed-arrival-rate, open-loop, or physical-device measurement",
        "warmup_policy" => "raw warmup records retained and excluded from histograms",
        "repetitions" => length(options.inputs),
        "raw_csv" => abspath.(options.inputs),
        "environment" => environment_record(),
        "counters" => counters,
        "per_run_measurements" => runs,
        "combined_measurements" => combined,
    )
    for implementation in ("native", "julia")
        summary = combined[implementation]
        println(
            implementation,
            " samples=", summary["samples"],
            " p50_ns=", summary["p50_ns"],
            " p99_ns=", summary["p99_ns"],
            " p99_9_ns=", summary["p99_9_ns"],
            " max_ns=", summary["max_ns"],
        )
    end
    open(options.output, "w") do io
        JSON3.pretty(io, result)
        println(io)
    end
    println("wrote ", abspath(options.output))
    return nothing
end

main(ARGS)
