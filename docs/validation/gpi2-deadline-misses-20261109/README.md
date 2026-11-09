# GPI2 deadline miss investigation — 2026-11-09

## Original 53 misses

The [matched replay](../gpi2-matched-20261109/README.md) delivered every CUDA
command set and recorded 53 releases past the 500 µs slot. The first was at
0.777 s. Its detector publication used 68 µs of the budget and command
receipt took another 441 µs. The other 52 fell between 8.1240 and 8.4755 s,
among 704 offers. The same 52 detector frames appeared another 1,887 times
outside the burst. All of those offers met the deadline.

For the 53 late slots, the median detector publication was 18.271 µs after
its release. Median publication to the first command sink was 507.950 µs.
First to last command took a median of 5.580 µs and at most 11.100 µs.
Thirty-five misses took more than an entire slot after publication.
The original ledger localizes the excess largely to the shared path before
the first command. It has no timestamps inside the graph owner or on the GPU.
The host process snapshots have no coverage within the 351.5 ms burst.

## Instrumented repeats

The repeats use the same registered cohort, calibrated captured graph,
detector corpus, timing boundary, private-core topology and FIFO priority 15
on the same source, graph and command data threads. Each repeat offers one
priming frame, 4,000 warmup frames and 40,000 measured frames at 2 kHz.
The command oracle compares 400 CPU and CUDA output triples. The largest
difference in the traced owner was 0.0070 nm.

A temporary probe records graph launch, output enqueuing and the existing
blocking CUDA completion call inside the existing callback time interval.
The probe uses a preallocated record per invocation. It joins records to
callback timestamps and frame sequence, and excludes a graph preparation
invocation before the first measured callback. The callback probe also
records Julia GC intervals and per-thread allocations.

| Replay | Measured offers | Late receipts | Source rejections | Release to receipt p99 | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: |
| Light probes, no injected load | 40,000 | 0 | 0 | 389.832 µs | 430.630 µs |
| Light probes, CPU load bursts | 40,000 | 72 | 3 | 432.750 µs | 2,123.629 µs |
| Nsight CUDA timeline, same CPU load bursts | 40,000 | 23 | 0 | 417.658 µs | 1,175.608 µs |

All three repeats had zero measured GC intervals. Each had two 64-byte
callback samples. Every late callback in the two repeats with misses
recorded zero allocated bytes.

The CPU load worker repeatedly reads and writes a prefaulted 32 MiB array
for about 352 ms. It runs twice on CPU 5, the graph thread's SMT sibling,
and twice on CPU 15 as a separate-core comparison. The lighter trace recorded
12 misses during the four bursts and 63 outside. The bursts alone cannot
explain that repeat's tail. Median publication to callback start rose from
7.133 µs in the first repeat to 102.331 µs on the 72 late completions.
The CUDA completion wait on those frames had a median of 272.880 µs and a
maximum of 290.674 µs. The worst slot accumulated 1,018.812 µs before
publication, 455.412 µs before the callback started, and 287.929 µs after
the callback ended. The graph waited for CUDA completion for 270.686 µs.
This establishes host-side delay in the lighter repeat. It does not assign
the original cluster to the injected load or to a particular process.

The Nsight trace joined all 40,000 measured frames to a device graph
activity record, four device-to-host copy records, and the blocking
stream wait. The graph took 238.529 µs at the median and at most
240.577 µs on a late frame. The median from graph end to first readback
was 7.648 µs. Seven late frames waited 139–758 µs for the first readback.
Every long gap overlapped a CUPTI buffer flush, and the copies then took
about 16–17 µs in total. The profiler's cadence explains these traced
readback spikes and the backlog they can cause. CPU context-switch
collection was unavailable with the host's existing perf permissions.
The profiler reported a driver-version warning and potentially incomplete
CUDA events. The four copies, graph activity and wait were present for
every frame used in this comparison.

The original 53 misses occurred without Nsight. The original cause of
the 351.5 ms cluster remains unresolved. The retrospective ledger excludes
late collection across the three sinks as the dominant interval. The
repeats separate ordinary host scheduling and publication delays from
the periodic profiler-induced readback delays. The exact original trigger
requires an instrumented recurrence.

## Evidence

The [archive](evidence.tar.gz) contains the original-ledger analysis,
repeat ledgers, stage and GC records, frame-correlated device timestamps,
profiler overhead records, and the analysis and launch scripts.
[Archive SHA-256](evidence.tar.gz.sha256)

Use the original CUDA ledger from the matched archive for the first command
below. Each repeat's summaries can also be generated offline.

```sh
sha256sum -c SHA256SUMS
python3 tools/original.py /path/to/matched/cuda-2khz-rt/arrivals.csv
python3 tools/decompose.py contention-rt
python3 tools/profile-report.py timeline-retry-rt
```

The full Nsight report stays with the investigative run. Its per-frame
exports and profiler warnings are retained in the evidence archive.
