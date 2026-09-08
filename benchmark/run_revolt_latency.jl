#!/usr/bin/env julia

"""
Run the existing ignored REVOLT private-core fixture repeatedly with optional
completion-paced latency collection, then produce a merged report. The caller
provides the normal private-core build/package environment documented by the
live fixture; this script does not select a PipeWire installation or change
thread, affinity, or scheduling policy.
"""
function parse_arguments(arguments)
    repetitions = 3
    warmup = 100
    samples = 10_000
    output = nothing
    for argument in arguments
        if startswith(argument, "--repetitions=")
            repetitions = parse(Int, split(argument, '='; limit=2)[2])
        elseif startswith(argument, "--warmup=")
            warmup = parse(Int, split(argument, '='; limit=2)[2])
        elseif startswith(argument, "--samples=")
            samples = parse(Int, split(argument, '='; limit=2)[2])
        elseif startswith(argument, "--output-directory=")
            output = split(argument, '='; limit=2)[2]
        else
            throw(ArgumentError("unknown argument: $argument"))
        end
    end
    repetitions > 0 || throw(ArgumentError("repetitions must be positive"))
    warmup >= 0 || throw(ArgumentError("warmup must be non-negative"))
    samples > 0 || throw(ArgumentError("samples must be positive"))
    isnothing(output) && throw(ArgumentError("--output-directory=PATH is required"))
    return (; repetitions, warmup, samples, output)
end

function run_and_capture(command::Cmd, path::String)
    open(path, "w") do io
        run(pipeline(command; stdout=io, stderr=io))
    end
    return nothing
end

function package_statuses(output::String)
    projects = Dict(
        "pipewireao-julia" => get(ENV, "PIPEWIREAO_RTC_PIPEWIREAO_JULIA", nothing),
        "revolt-hil" => get(ENV, "PIPEWIREAO_RTC_REVOLT_HIL_PACKAGE", nothing),
        "julia-filter-graph-deployment" => let root =
            get(ENV, "PIPEWIREAO_RTC_JULIA_FILTER_GRAPH", nothing)
            isnothing(root) ? nothing : joinpath(root, "deployment")
        end,
    )
    for (label, project) in projects
        isnothing(project) && continue
        isfile(joinpath(project, "Project.toml")) || continue
        run_and_capture(
            `$(Base.julia_cmd()) --startup-file=no --project=$project -e "using Pkg; Pkg.status(; mode=Pkg.PKGMODE_MANIFEST)"`,
            joinpath(output, "package-status-$label.txt"),
        )
    end
    return nothing
end

function main(arguments)
    options = parse_arguments(arguments)
    output = abspath(options.output)
    mkpath(output)
    package_statuses(output)
    environment = copy(ENV)
    environment["PIPEWIREAO_RTC_LIVE_SCOPE"] = "revolt"
    environment["PIPEWIREAO_RTC_REVOLT_LATENCY_WARMUP"] = string(options.warmup)
    environment["PIPEWIREAO_RTC_REVOLT_LATENCY_SAMPLES"] = string(options.samples)
    inputs = String[]
    repository = normpath(joinpath(@__DIR__, ".."))
    for repetition in 1:options.repetitions
        csv = joinpath(output, "revolt-latency-run-$repetition.csv")
        environment["PIPEWIREAO_RTC_REVOLT_LATENCY_CSV"] = csv
        command = setenv(
            Cmd(
                `cargo test --features live --test live_private_core -- --ignored --nocapture`;
                dir=repository,
            ),
            environment,
        )
        println("run $repetition/$(options.repetitions): ", command)
        run(command)
        isfile(csv) || error("run $repetition did not create $csv")
        push!(inputs, csv)
    end
    report = joinpath(@__DIR__, "report_revolt_latency.jl")
    report_command = `$(Base.julia_cmd()) --startup-file=no --project=$(@__DIR__) $report $(map(input -> "--input=$input", inputs)) --output=$(joinpath(output, "revolt-latency.json"))`
    run(setenv(report_command, environment))
    open(joinpath(output, "command.txt"), "w") do io
        println(io, "completion-paced REVOLT graph-path latency characterization")
        println(io, "warmup=", options.warmup)
        println(io, "samples_per_implementation=", options.samples)
        println(io, "repetitions=", options.repetitions)
        println(io, "live_test=cargo test --features live --test live_private_core -- --ignored --nocapture")
        println(io, "report=", report_command)
    end
    return nothing
end

main(ARGS)
