# Recorded RTC benchmarks

This directory retains measured data, reports and the Julia latency reporter.
The Python Classic/Copper runners and analyzers have been removed. Their
[original source and run instructions](https://github.com/DarrylGamroth/pipewireao-rtc/tree/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark)
remain in Git history. Recorded results retain their original revisions,
measurement boundaries, placement and qualification limits.

The old `run_revolt_latency.jl` launcher was removed because its
`live_private_core` Rust integration-test target is retired. This directory does
not currently provide a replacement live benchmark runner. Current sessions
use the [WirePlumber-owned runtime](../README.md#launch-a-sealed-session-package).

## Report existing latency observations

```sh
julia --startup-file=no --project=benchmark -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=benchmark benchmark/report_revolt_latency.jl \
  --input=/absolute/run-1.csv --input=/absolute/run-2.csv \
  --output=/absolute/combined.json
```

The reporter accepts the original completion-paced REVOLT CSV contract, excludes
warmup observations and records histogram counts and quantiles. It does not
convert packet-ingress benchmarks to that contract or infer fixed-arrival
latency, deadline compliance, detector-readout overlap or camera-to-DM timing.
Completion pacing reduces offered load during stalls; those results retain that
limitation. Keep the original source, command, configuration and placement with
any reprocessed report.

Platform-access files and host placement profiles remain development resources;
this cleanup changes no scheduling or power policy.
