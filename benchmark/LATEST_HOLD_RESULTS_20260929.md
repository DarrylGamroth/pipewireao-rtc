# Latest/hold development characterization, 2026-09-29

## Scope and evidence

This measures the two-element Float32 latest/hold fixture on an AMD Ryzen 7
6800H host. One PipeWire Dummy Driver paces a 1000 Hz primary source and a slow
offer every ten callbacks. The native FGN and Julia graph each pass the primary
value through a two-input graph while consuming the held value. The output
checks every Header, Acquisition identity, and payload. It does not perform
REVOLT Classic or Copper image processing, camera transport, or DM output.

The raw paired CSVs, source logs, CFS failure trace, allocation trace, and CPU
samples are in [`data/latest_hold_20260929_raw.tar.zst`](data/latest_hold_20260929_raw.tar.zst)
(SHA-256 `10aaf8d4e40b8ef32b5c729174af5a39c614e29c178ed47508a2f01b8482f41e`).
[`data/latest_hold_20260929.json`](data/latest_hold_20260929.json) gives
per-run statistics and raw CSV hashes. The host and source revisions are in
[`data/latest_hold_environment_20260929.json`](data/latest_hold_environment_20260929.json).
These artifacts record a dirty SPA plugin checkout and the exact installed
build tree; its revision alone cannot reproduce that plugin binary.
The environment record preserves the harness source hash captured during the
run series and records the later cleanup/test source hash separately. The
RTC-owned node and measured C callback source hashes did not change.
The [run commands](RUN_COMMANDS_20260929.md) identify the timing and
pool-replacement launches. The archive also retains the fail-before stale
Props assertion, all successful source logs, and the ordinary-scheduling
failure's partial source records.

Each successful run offered 2,500 slow identities and 25,000 primary
identities. The first 500 slow and 5,000 primary identities were excluded as
warmup, leaving 2,000 and 20,000 measured intervals per graph owner. Three
independent baseline runs and one stopped-state endpoint-pool replacement run
passed exact delivery. No sample with a missing identity enters a latency
distribution. All reported latency intervals use `CLOCK_MONOTONIC_RAW` in the
fixture process. The queue timestamp precedes `pw_stream_queue_buffer`; the
receipt timestamp follows the callback's metadata checks. The local callback
count is not an independent PipeWire driver-position reading.

The three baseline runs used `chrt -f 70` for the test process tree. The
sampled private core in an earlier same-setup successful run and its data loop
ran at FIFO 70; the source data loop
ran at FIFO 83. Their affinity mask covered CPUs 0–15, so this is not an
isolated-core result. The governor was `powersave`; transparent huge pages
were enabled but neither sampled process showed resident anonymous huge pages.
Achieved offer rates were approximately 100.000 and 1000.000 Hz. The
post-shutdown two-clock-read overhead p99 was 30–31 ns.

## Latency observations

All values below are microseconds. Ranges span the three independent baseline
runs; each run's exact values and maximum are in the JSON report.

| Graph owner | Boundary | p50 range | p99 range | Worst observed |
| --- | --- | ---: | ---: | ---: |
| Native FGN | Slow queue → first held observer receipt | 16.7–17.0 | 29.4–30.6 | 94.9 |
| Julia | Slow queue → first held observer receipt | 16.2–19.1 | 28.1–30.9 | 38.7 |
| Native FGN | Primary queue → command sink receipt | 22.3–26.0 | 34.8–128.6 | 246.5 |
| Julia | Primary queue → command sink receipt | 21.7–22.7 | 34.8–36.9 | 155.0 |

After stopped-state source and observer pool replacement, both owners again
delivered every identity. Slow queue → held receipt p99 was 29.9 µs native
and 31.1 µs Julia; primary queue → command receipt p99 was 33.8 µs native
and 34.9 µs Julia. The RTC's owned latest/hold node sets
`node.cache-params=false` internally. Fail-before evidence showed that a broad
PipeWire parameter enumeration otherwise cached an old live Props counter:
2,500 new identities were delivered but the later query still returned 12
accepted updates. Disabling that cache restored the expected live counter in
the short and long pool-replacement runs.

The primary-to-command p99 varies substantially between runs even with exact
delivery. This sample does not establish a deadline or explain that tail.
The load is driver-paced: a late driver changes callback arrival times rather
than building a fixed-arrival queue.

## Failed ordinary-scheduling run

The long run without `chrt` failed the exact-delivery gate. Its partial CSV
contains contiguous primary source callbacks through identity 1,976, but the
interval from callback 1,972 to 1,973 was 4.004931 ms. Callbacks 1,974 and
1,975 followed after about 40 and 32 µs. The command sink received 1,972
then 1,976; the held observer also reported a Header gap. This demonstrates
the source-callback pause and later burst at the same failed interval. It
does not by itself distinguish a scheduler delay from every other source of
late driver execution. Two earlier ordinary-scheduling runs also failed at
different cycles. No failed run was included in the successful latency
distributions.

## Separate profiles and limits

A separate FIFO run with heaptrack passed the same exact-delivery gate. Its
private-core trace records 12,070 process-wide allocations across startup,
both graph-owner sessions, and shutdown. The allocation backtraces containing
`latest_hold` were in port-parameter negotiation and setup; the profile did
not show an allocation backtrace through `LatestHoldNode::process`. This is
evidence about the observed run, not a proof of zero callback allocations.
The external native FGN and Julia provider processes were outside that
private-core allocation trace.

A separate `perf` capture sampled the private core during the Julia phase
(1,408 cycle samples, zero lost samples). Samples in the latest/hold data-loop
path include Acquisition validation, buffer access, and port bookkeeping.
The sample is too small to assign stable percentages to individual functions.
The profile process ended when the core exited, so its `perf record` command
reported status 143 even though the RTC exact-delivery test passed. No CPU
profile in this artifact covers a Copper or Classic reconstructor.

The short recovery tests, three baseline timing runs, pool-replacement timing
run, allocation pass, and CPU-profile pass are software experiments on this
host. RTC-DEV-019's pre-ingress laboratory placement and Copper
WFS-packet → Standard-DM-packet comparison remain separate work.
