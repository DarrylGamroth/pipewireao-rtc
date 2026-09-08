# REVOLT Classic latency characterization

This optional harness characterizes the complete-frame REVOLT Classic
development graph at its public application boundary. The measured interval is
the monotonic Header PTS written when the HIL WFS source publishes a frame
through receipt of the same-sequence correction command in the HIL command
callback. The HIL adapter owns both timestamps; this repository owns the
fixture lifecycle, raw observations, counters, and reporting.

The exchange is deliberately **completion-paced**: it permits one WFS frame
and one command in flight, and the next simulated frame is not issued until the
previous command has arrived and passed the existing numerical oracle. It is
not a fixed-rate, open-loop, detector-readout-overlap, camera-to-DM, PTP, or
hard-real-time measurement. A stall reduces the offered rate, so these
histograms must not be used to claim fixed-arrival latency or deadline
compliance.

The normal eight-frame native/Julia numerical equivalence and property/parameter
update checks run before collection. Each warmup and measurement observation is
also sequence-correlated, has a non-negative monotonic source timestamp, a
later command-receipt timestamp, and a controller command checked against the
direct reference. Raw CSV retains warmup records; the report excludes them.

## Run

First prepare the same private-core prerequisites as the [maintained live
fixture](../README.md#run-the-development-fixture). Create an output directory
outside the repository so generated evidence is not accidentally committed.

```sh
results=$(mktemp -d)
julia --startup-file=no --project=benchmark -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=benchmark benchmark/run_revolt_latency.jl \
  --repetitions=3 --warmup=100 --samples=10000 \
  --output-directory="$results"
```

The launcher invokes `cargo test --features live --test live_private_core --
--ignored --nocapture` once per repetition with the REVOLT-only scope. It
inherits the private-core prerequisite variables from the parent shell, forces
the optional latency variables, creates one raw CSV per repetition, records
the exact command, captures resolved REVOLT-HIL and JuliaFilterGraph deployment
package statuses when those project paths are provided, and runs the reporter.

The CSV contains one record per completed frame for `native` and `julia`, with
the phase, observation index, sequence, both timestamps, and their exact
difference. The JSON contains per-run and merged HdrHistogram bucket data,
p50/p90/p99/p99.9/max summaries, warmup/measurement counters, and a limited
Julia/host/environment record. To report existing raw files without rerunning
the live fixture, pass each file as another `--input`:

The reporter suppresses p90, p99, and p99.9 respectively below 10, 100, and
1,000 measurement observations rather than presenting unsupported tails.

```sh
julia --startup-file=no --project=benchmark benchmark/report_revolt_latency.jl \
  --input="$results/run-1.csv" --input="$results/run-2.csv" \
  --input="$results/run-3.csv" --output="$results/combined.json"
```

Record the PipeWireAO, HIL-package, JuliaFilterGraph, and REVOLT revisions,
exact command, core configuration, CPU topology, affinity, power policy, and
competing load alongside the JSON. The report intentionally does not infer
physical-loop behavior from the private-core simulation.

## HEART comparison

A fair HEART comparison belongs at this RTC application boundary, not in
`JuliaFilterGraph.jl`. Use the same REVOLT workload, controller parameters,
source-to-command boundary, host placement, and arrival model. Keep the
completion-paced results separate from a future schedule-preserving,
fixed-arrival experiment; only the latter can compare deadline pressure and
queueing behavior.
