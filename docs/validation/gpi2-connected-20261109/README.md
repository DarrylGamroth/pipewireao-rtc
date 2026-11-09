# GPI2 captured controller through PipeWire — 2026-11-09

## Workload

The source replays 1,062 retained 242 × 240 UInt16 GPI2 detector frames, including
noise, flux steps and optical cases, in their retained order. The existing
GPI2 fixture loader verifies the graph, calibration receipt, every parameter
and the input corpus against their recorded hashes. The Float32 captured CUDA
controller keeps delayed constraint feedback on the device and publishes the
three command Ports. The CPU and CUDA reference paths passed a 32-frame
command comparison before live connection. Maximum difference across all
three commands was 2.59 × 10⁻¹² m. This oracle uses the checked saved-frame
inputs and the same prepared graph state. Live sinks check frame identity,
propagated Header timestamps, negotiated formats and finite command values.

This is the commands-only captured graph using the released FilterGraphPipeWire
owner. The connected profile uses column-major detector buffers, Header
metadata, fixed calibration and a direct private-core topology. The prior CPU
HIL profile includes row-major input, telemetry, supervision and live control.
The separate RTC session manager and optical simulation are outside the
measured path.

The native source's absolute monotonic timer accounts for each 500 µs release
independently of command completion. On a delayed timer callback it records
every elapsed nominal release. Two pending frames are allowed by the source
queue. A rejection, incomplete command set or a last command after 500 µs
counts as a missed slot. Timing ends on receipt of the last complete woofer,
tweeter and tip/tilt command in the same native client. Publication latency
starts immediately before the source queues the complete detector buffer.
Percentiles describe completed frames. The miss denominator includes all
offered frames.

The workstation was an AMD Ryzen 7 6800H, NVIDIA GeForce RTX 3080, Linux
6.12.113 and Julia 1.13.3. The graph's PipeWire data loop used CPU 4, the
source loop CPU 8, the sink loop CPU 10 and the core CPU 2. These are distinct
physical cores. The pilot initially shared CPU 4 between replay and graph
because the client configuration overrode the replay's data loops. It is
retained separately. The longer runs use distinct replay and owner client
configurations and verify the actual placement through procfs.

The registered cohort includes FilterGraphs 0.10.2, FilterGraphAlgorithms
0.12.2, FilterGraphPipeWire 0.5.3, PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2+0,
CUDA 6.5.1 and KernelAbstractions 0.10.7. The trace attaches the released
per-thread sampler to the captured callback body in the temporary launcher.
GC hooks and allocation epochs use the same Julia 1.13.3 method as the
[CPU timing campaign](../gpi2-data-thread-20261109/README.md). The traced
boundary includes staged copies, CUDA graph launch and completion, and
output data/metadata marking. Native heap allocation, GC time-to-safepoint
and individual thread stall durations remain outside the measured scope.

## Ordinary scheduling

Each fresh run offers 8,000 warmup releases and 40,000 measured releases,
plus one priming frame. All published measured frames in both runs produced
all three commands. Rejections occurred at the bounded source.

| Measured result | Traced | Sampler disabled |
| --- | ---: | ---: |
| Offered slots | 40,000 | 40,000 |
| Source rejections | 406 | 2,149 |
| Completed after 500 µs | 1,327 | 8,412 |
| Slots without an on-time command | 1,733 (4.33%) | 10,561 (26.40%) |
| Release to all commands, p50 | 379 µs | 397 µs |
| Release to all commands, p99 | 1.259 ms | 3.817 ms |
| Release to all commands, p99.9 | 4.897 ms | 6.930 ms |
| Release to all commands, maximum | 8.163 ms | 10.878 ms |
| Detector publication to all commands, p50 | 354 µs | 367 µs |
| Detector publication to all commands, p99 | 653 µs | 1.880 ms |
| Timer lateness, p99 | 236 µs | 1.792 ms |

The two runs establish a sub-500 µs median and variable tails on this
workstation. The sampler-disabled run had worse misses. With one run in
each condition the difference cannot establish the sampler's timing cost.

In the traced run, 39,592 of 39,594 measured callbacks allocated zero Julia
heap bytes. Two allocated 64 bytes each. The same size appeared once in
warmup. The three events are approximately 10 seconds apart. Their source
was not determined. All allocation intervals were valid. There were no GC
hook intervals during the measured window and no callback epoch crossings.
The two recorded premeasurement GC spans were 53.16 and 101.92 ms.
The graph callback had 331 µs p50, 375 µs p99, and a 612 µs maximum.
Five callback bodies exceeded 500 µs. The p99 publication-to-callback-start
delay was 267 µs. The p99 absolute cadence error between consecutive
published frames was 254 µs. Those timing components are measured at
different boundaries and their percentiles must be read separately.

## FIFO scheduling

The private client configurations request SCHED_FIFO priority 15 for the
controller, source and command data loops. The launcher verifies the actual
policies and separate cores before the first offer. An earlier attempt to
change an already running loop with chrt was refused and produced no timing
samples. The daemon and process leaders use ordinary scheduling in the
accepted runs.

The 40,000-slot traced run delivered every command set. One release-to-command
deadline was missed, at 505.661 µs. Its detector publication was 20.332 µs
after the scheduled release, its publication-to-callback-start interval was
143.730 µs, the callback took 328.404 µs, and the last sink took 13.195 µs
after callback end. The data establish those measured intervals. They
cannot assign the 143.730 µs to a particular kernel or scheduler event.

| Measurement | p50 | p99 | p99.9 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Release to all commands | 368.1 µs | 395.3 µs | 411.4 µs | 505.7 µs |
| Detector publication to all commands | 351.9 µs | 377.9 µs | 391.8 µs | 485.3 µs |
| Detector publication to callback start | 6.7 µs | 13.0 µs | 18.7 µs | 143.7 µs |
| Controller callback body | 332.6 µs | 352.5 µs | 360.7 µs | 383.7 µs |
| Timer lateness | 6.0 µs | 10.4 µs | 14.7 µs | 61.3 µs |
| Absolute publication cadence error | 0.6 µs | 8.1 µs | 14.5 µs | 55.2 µs |

All 40,000 allocation intervals were valid. There were 39,998 zero-byte
callbacks and two 64-byte samples about 10 seconds apart. The graph process
recorded two hook spans before measurement, 38.42 and 45.06 ms. There were
no measured GC spans, epoch crossings or trace omissions. FIFO timing
improved the tail while the median changed by 11–29 µs relative to the
ordinary-scheduling trials. Each 40,000-frame interval covers 20 seconds.

The independent 60-second FIFO repeat disabled the sampler. All 120,000
measured releases produced all three commands within 500 µs. Release to last
command was 359.6 µs p50, 377.8 µs p99, 395.9 µs p99.9 and 435.9 µs maximum.
Detector publication to last command was 346.1 µs p50 and 362.1 µs p99.
Timer lateness was 8.4 µs p99 and absolute publication cadence error was
6.3 µs p99. The source rejected one warmup release. Warmup and measured
offers have separate accounting.

These workstation results show the importance of host scheduling for the
captured graph. They cover the tested command-only profile and finite
windows. Full instrument telemetry, device timing, target hardware and
long-duration qualification remain separate.

## Workstation HEART GPI2 comparison

The comparison builds the GPI2 `gpiTemplate` executable from `a59a403`
with the pinned HEART source `50de9affa` and the workstation's existing
DAO library and tooling at `65f05a5`. It compiles without hardware drivers.
The application, three simulated command devices and UDP replay run in an
isolated loopback network and shared-memory namespace. The standard WFS
profile uses the pinned receiver's zero-checksum convention. The
workstation launcher reuses the existing test shim for the kernel's
unsupported busy-poll setting. INIT, RUN, CORRECT and SHUTDOWN returned
success in the final two runs.

The final workstation profile uses dedicated WFS, pixel-processing,
reconstruction and command cores, a single matrix partition and normal
pages. The four-partition attempts failed to sustain frame delivery,
including a 100 Hz control. The single-partition profile completed all 500
measured frames at 100 Hz, providing a working low-load check. At 2 kHz
every one of the 8,000 measured UDP frame sends completed, but the receiver
produced only 586 complete three-command sets during the replay and its
drain. The capture reported zero dropped or invalid packets. Duplicate
complete command packets are counted separately and cannot create a
second successful response for a frame. Logs show input circular-buffer
jumps and overwritten buckets at target load.

| Workstation HEART result | 100 Hz control | 2 kHz target |
| --- | ---: | ---: |
| Offered frames | 500 | 8,000 |
| Complete three-command sets | 500 | 586 |
| Slots without an on-time command | 0 at 10 ms | 8,000 at 500 µs |
| Release to all commands, p50 | 4.599 ms | 6.542 ms |
| Release to all commands, p99 | 5.966 ms | 11.140 ms |
| Release to all commands, maximum | 7.381 ms | 56.800 ms |

The HEART test uses the same retained UInt16 detector corpus. It uses
the GPI2 quickstart's geometry and 1,810 × 11,300 synthetic reconstructor
instead of the Julia controller's calibrated 1,509 × 11,104 reconstructor.
The receiver timestamps complete loopback UDP command packets. The Julia
comparison timestamps the consumer's PipeWire buffer receipt. The results
characterize these two workstation configurations. An algorithm or runtime
comparison needs matched calibration, command semantics and transport
boundaries.

The first HEART bring-up was blocked by the unavailable busy-poll socket
option. The next attempt exposed the receiver's required zero checksum.
Those attempts are excluded from the latency table. The successful
configuration does not require changing the vendor sources.

## Evidence

The [archive](evidence.tar.gz) retains the full release ledgers, three receipt
timestamps per frame, controller callback and GC records, runner and
configuration sources, and workstation comparison logs.
[Archive SHA-256](evidence.tar.gz.sha256)

The summaries can be reproduced without a live core:

```sh
sha256sum -c SHA256SUMS
python3 reproduction/analyze.py runs/native-rt
python3 reproduction/analyze.py runs/longer-bare-rt
python3 heart/analyze-heart.py heart/single-target/arrivals.csv
```
