# Latest/hold characterization protocol

The first retained host result is in
[`LATEST_HOLD_RESULTS_20260929.md`](LATEST_HOLD_RESULTS_20260929.md).

## Question and boundary

RTC-DEV-018 needs a measured steady-state allocation and latency record for
the maintained 100 Hz input → 1000 Hz output transition. This fixture uses a
two-element Float32 vector and a ten-cycle hold bound. It characterizes the
development transport path; it does not represent camera readout or DM egress.

Measure two observable intervals with `CLOCK_MONOTONIC_RAW` in the existing
external fixture process:

1. From immediately before the slow source queues identity `n` to the first
   observer callback that receives held identity `n`.
2. From immediately before the primary source queues identity `m` to the
   command sink callback that receives identity `m`.

The first interval includes PipeWire transport, latest/hold admission and
publication, and sink delivery. The second includes the two-input graph and
command transport. The queue timestamp precedes `pw_stream_queue_buffer`;
receipt is stamped after initial metadata checks in the sink callback. Record
raw paired timestamps and identities; compute
histograms after callbacks stop. An in-callback clock read perturbs the path,
so measure the cost of two clock reads separately and retain it in the report.

## Load and correctness

The current private core uses one 1000 Hz Dummy Driver. It calls both sources
at driver cadence; the slow source offers one buffer every ten cycles and
leaves the other callbacks without a buffer. This is **driver-paced** load.
If the driver stalls, callbacks are late rather than queued by an independent
arrival clock. Report achieved callback and offer intervals, and do not call
its latency distribution a fixed-arrival result.

Use 500 slow identities for warmup, then at least 2,000 measured identities
(20,000 fast cycles, about 20 seconds) per independent run. Require three
runs for each graph owner. Preserve the initial, warm, and recovery intervals
separately. A sample enters a latency distribution only when its source and
sink identities pair exactly. Reject a run with any missing, repeated, or
out-of-order measured identity, source pool starvation, hold output
starvation, protocol error, or unexplained command gap. Record the source
callback count, source queue time, first held receipt, primary queue time,
and command receipt per identity. Retain all raw observations, not only percentiles.
The callback count is not an independent driver-position reading; timestamps
show elapsed cadence, including any driver stall.

The fixture must preallocate timestamp storage before ingress and write CSV
only after its streams are stopped. Failed runs must retain partial raw records
with an invalid status. Its timing mode should be compiled or
enabled separately from the short functional recovery test. The existing
stop/reset/pool-replacement assertions remain the correctness gate; the
timing run must also check exact Acquisition, Header, payload, and command
ordering for every measured identity.

## Allocation and profile passes

Measure allocation in a separate run from latency timing. Launch the private
PipeWireAO core under an allocation profiler and retain allocation stacks
for the warm window. Report daemon-wide allocations and those attributed to
the latest/hold process path separately; process-wide allocation counts alone
cannot prove the node callback is allocation-free. Use the same steady input
schedule and exact-delivery checks as the latency run. Profile CPU samples
and scheduler events in further separate runs if a latency tail appears; do
not add profiling hooks to the production callback for this characterization.

Record CPU model, kernel, PipeWireAO and plugin commits, compiler flags,
installed library paths, process/thread affinity and scheduler state, power
policy, page backing, locked memory, competing load, source revisions, and
exact build/run commands. Retain raw samples and profiler output for every
run. The first result is characterization; no deadline or physical-loop
claim follows from it.

## Experiment order

1. Complete the default short native and Julia recovery fixtures with exact
   identity delivery.
2. Implement the preallocated timing mode and prove its counter/timestamp
   pairing with a short run before collecting long data.
3. Run three independent long native and Julia passes at the selected host
   placement; report achieved offered rate, p50/p90/p99 and maximum with
   sample counts, plus source and driver interval distributions.
4. Run separate allocation and CPU profiles under the same input schedule.
5. Repeat after stopped-state endpoint pool replacement, with an explicit
   post-restart warm interval. Keep the earlier intermittent pool recovery
   observation in the record even if later runs pass.

RTC-DEV-019's Copper WFS-packet → Standard-DM-packet comparison has a different
input, processing graph, output boundary, and arrival model. Its results must
not be pooled with this synthetic latest/hold fixture.
