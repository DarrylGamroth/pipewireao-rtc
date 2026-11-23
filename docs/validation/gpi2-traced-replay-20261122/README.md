# GPI2 traced and untraced replay at 500 µs

The two untraced windows missed 125 of 240,000 slots. The two traced
windows missed 1,854 of 240,000. Every accepted frame returned all three
commands. In 1,112 of 1,750 late traced completions, the largest excess
over that run's segment median occurred before callback entry. Different
workloads shared the workstation across the four windows, so the observed
mode differences do not isolate the cost of tracing.

## Replay and measurements

The workload uses the same 1,062 retained, column-major 242 × 240 UInt16
detector frames, 33 verified calibration parameters, Float32 captured
controller graph and three non-actuating command sinks as the previous
released-cohort replay. The independent native timer offers one frame
every 500 µs at 2,000 offers/s and records all nominal release slots,
including slots that cannot obtain a source reservation. Each invocation
uses a fresh private core, owner and replay client, one priming offer
and 8,000 warmup offers before the 120,000 measured offers. The four
60-second measured windows run in the order untraced, traced, untraced,
traced. The native core and graph transport use the published AVX2
PipeWireAO 4.0.8+0 artifact with PipeWireAO.jl 0.9.6. The registered
environment includes RTC 0.7.28, FilterGraphPipeWire 0.5.10, FilterGraphs
0.10.6, FilterGraphAlgorithms 0.12.12, CUDA 6.5.1, KernelAbstractions 0.10.7
and Julia 1.13.3. The timed path is the directly linked captured graph
and native client. [Released-cohort workload and sources](../rtc-0728-running/replay.md)

The three sinks verify negotiated formats, finite commands, sequence and
propagated PTS. Before enabling the optional probes, each owner checks 32
consecutive CPU versus CUDA command triples with a maximum absolute
difference limit of 10⁻⁹ m. The source allows two pending reservations.
Late means the last receipt comes more than 500 µs after the nominal
release. A rejected source offer or any accepted offer without three
valid command receipts also misses its slot. Timing quantiles use
nearest rank over complete command sets, including late sets.

The traced launcher uses the released PipeWire graph callback metrics at
entry and exit of its callback body. The CUDA stage probe records host
clock reads around the existing graph launch, readback enqueues and
blocking stream completion. It executes the same launch, copies and wait
as the released path. It uses the open callback record's index and Header
sequence to join stages to the release ledger. The arrays are allocated
before streaming with room for 131,072 callbacks. Probe export happens
after native node close. A short traced preflight verified all 5,001
records, sequence joins and clocks before the paired experiment. The
allocation and GC probe uses the stock Julia 1.13.3 C ABI from the
earlier investigation. [Earlier probe sources](../gpi2-deadline-misses-20261109/README.md)

The measured segments are scheduled release to source offer, offer to
publication, publication to callback entry, callback entry to CUDA
launch, CUDA launch call, status and output readback enqueue, completion
wait, wait return to callback exit, callback exit to first receipt, and
first to last receipt. A CUDA wait timestamp is a host observation of
the existing blocking call. Its duration includes any work still queued
on the stream, host driver activity, and the host thread's return from
the wait. The probe retains the original synchronization and records
host timestamps only.

## Delivery and latency

All four runs reproduced the same 32-frame CPU/CUDA maximum differences
of 1.158 × 10⁻¹² m for woofer, 2.586 × 10⁻¹² m for tweeter and
1.248 × 10⁻¹³ m for tip/tilt. The 480,000 measured nominal release
timestamps are complete at exactly 500 µs intervals. All 479,876
publications returned complete, ordered command sets. Across the four
measurement windows, 124 offers were rejected at the source. The
measured samples contain zero accepted but unpublished frames, incomplete
published frames, duplicate receipts or out-of-order receipts.

| Measurement | Untraced 1 | Traced 1 | Untraced 2 | Traced 2 |
| --- | ---: | ---: | ---: | ---: |
| Offered at 2,000/s | 120,000 | 120,000 | 120,000 | 120,000 |
| Source rejected | 20 | 55 | 0 | 49 |
| Complete command sets | 119,980 | 119,945 | 120,000 | 119,951 |
| Complete after 500 µs | 73 | 1,570 | 32 | 180 |
| Missed slots | 93 (0.0775%) | 1,625 (1.3542%) | 32 (0.0267%) | 229 (0.1908%) |
| Release to last receipt, p50 | 369.138 µs | 439.745 µs | 376.558 µs | 377.495 µs |
| Release to last receipt, p99 | 415.469 µs | 511.891 µs | 427.419 µs | 432.082 µs |
| Release to last receipt, p99.9 | 468.517 µs | 886.109 µs | 460.502 µs | 592.533 µs |
| Release to last receipt, worst | 8.087 ms | 8.436 ms | 843.786 µs | 6.137 ms |
| Publication to last receipt, p99 | 394.910 µs | 469.048 µs | 406.942 µs | 410.218 µs |
| Publication to last receipt, p99.9 | 427.190 µs | 718.265 µs | 434.744 µs | 499.365 µs |
| Publication to last receipt, worst | 5.608 ms | 5.551 ms | 823.883 µs | 4.955 ms |

Warmup late completions were 5, 199, 37 and 2 in run order. The
second untraced run rejected 40 warmup offers. The other warmups
rejected zero. The source reached two pending reservations in each run
across priming, warmup and measurement. All owned cores, clients and
owners exited with status zero. The latency quantiles describe the
completed sets of each experiment. Source rejections remain in the
deadline denominator.

## Traced deadline misses

Each of the 239,896 measured traced publications has exactly one
callback and CUDA stage record. The probe omitted zero records. The
Julia allocation counts were valid for every recorded callback. Each
timed trace recorded six 64 B samples and all other measured callbacks
recorded zero Julia heap allocation. One of those 12 callbacks finished
late. There were zero recorded GC hook spans during measurement.

| Segment | Traced 1 p50 / p99.9 / worst in µs | Traced 2 p50 / p99.9 / worst in µs |
| --- | ---: | ---: |
| Scheduled release to offer | 8.137 / 102.231 / 2,976.649 | 6.702 / 23.226 / 3,030.847 |
| Offer to detector publication | 13.616 / 50.214 / 5,018.101 | 10.770 / 33.383 / 4,013.286 |
| Publication to callback entry | 17.383 / 279.755 / 5,021.927 | 10.149 / 67.717 / 2,529.428 |
| Callback entry to CUDA launch | 66.114 / 96.661 / 217.137 | 31.248 / 73.117 / 765.744 |
| CUDA launch call | 20.067 / 36.148 / 110.537 | 9.177 / 28.163 / 575.378 |
| Status and readback enqueue | 20.689 / 37.290 / 93.765 | 10.270 / 25.518 / 417.172 |
| CUDA completion wait | 263.383 / 293.009 / 313.868 | 280.916 / 293.370 / 856.845 |
| Wait return to callback exit | 5.841 / 10.900 / 31.339 | 2.936 / 10.339 / 240.400 |
| Callback exit to first sink | 15.368 / 95.128 / 5,048.217 | 7.875 / 45.275 / 2,614.948 |
| First to last sink | 7.033 / 34.174 / 133.230 | 5.119 / 17.132 / 261.620 |

For each late traced completion, the analysis compares each segment
with its median over complete frames in the same run. The largest
excess was before callback entry on 1,112 frames, after callback exit
on 380, from callback entry to launch on 222, and inside the CUDA
completion wait on 8. The other 28 had the largest excess in launch,
readback enqueue or between wait return and callback exit. Each
comparison describes time spent on that frame. Intervals can lengthen
together and the ranking does not identify the event that caused a miss.

The 8.436 ms frame in traced run 1 spent 5.996 ms from scheduled release
to publication and 1.905 ms from publication to callback entry. Its
CUDA wait took 215.033 µs. The 6.137 ms frame in traced run 2 spent
5.657 ms before publication and 45.636 µs from publication to callback
entry. Its CUDA wait took 247.303 µs. Another frame in traced run 2
took 1.735 ms, including 765.744 µs before CUDA launch within the callback
and 856.845 µs in the blocking wait. These long intervals occur in
different parts of the observed path.

The worst untraced frame took 8.087 ms. It spent 2.533 ms from release to
publication, 5.545 ms from publication to the first command, and
9.478 µs between first and last command. The untraced receipts only
observe those boundaries, so that late frame cannot be assigned to an
individual controller or transport stage from this record.

## Workstation and probe comparison

The Ryzen 7 6800H and RTX 3080 ran Linux 6.12.117 and NVIDIA driver
620.70.06. The graph, source and sink data loops held SCHED_FIFO priority
15 on CPUs 4, 8 and 10. The core used ordinary scheduling on CPU 2.
Placement checks covered the start, late warmup and end of each run.
Both traced records identified the same native graph data thread as
the placement snapshots. Each invocation held the shared workstation
lock and used a unique socket. The GPU temperature before owner startup
was 33.3, 50.4, 49.3 and 51.7 °C in run order.

Existing SPIDERS services remained active in all windows. The simulator's
main thread used CPU 12. The SPIDERS session and parameter service kept
affinity to CPU 5, the graph CPU's SMT sibling. The differential owner
kept threads on the sink's CPU 10 and its sibling CPU 11. The existing
FilterGraphPipeWire test process was present around the first untraced
window, with affinity to all 16 logical CPUs and 51.19 CPU seconds on
its main thread between snapshots. Cargo and Rust compiler processes
with broad affinity were present before the first traced window and
absent in its end snapshot. Other Julia work with broad affinity was
recorded around the latter two windows. No other compute process
appears in the NVIDIA snapshots around the measured windows. These
snapshots establish observed overlap and affinity. They sample the
window boundaries and contain no per-frame scheduler or GPU state.

The observed traced p50 was 70.607 µs above the preceding untraced run
in the first pair and 0.937 µs above in the second. Both traced cases
had more late completions and source rejections. The low-level probes
add host clock reads, callback buffer writes and a C allocation sampler.
The observed latency changes include the activity of the shared host,
which varied between paired cases. A device-only timeline and controlled
host load would be needed to further attribute individual delays and
quantify the tracing cost. The experiment covers the released direct
commands path at the workstation's two-kilohertz offer rate.

## Evidence and reproduction

The archive contains the complete release ledgers, callback and stage
records, GC hook records, environment, placement, and co-resident
snapshots, summaries, and the launcher and analysis changes.
[Evidence archive](evidence.tar.zst) · [SHA-256](evidence.tar.zst.sha256)

From this report's directory, extract the new archive along with the
unchanged files from the released replay and earlier trace archive.

```sh
record="$PWD"
scratch="$(mktemp -d)"
sha256sum -c evidence.tar.zst.sha256
tar --zstd -xf "$record/../rtc-0728-running/replay-evidence.tar.zst" -C "$scratch" \
    build.sh replay.c core.conf client.conf client-rt.conf replay.conf replay-rt.conf \
    env tools/analyze.py tools/fixture.jl
tar --zstd -xf "$record/evidence.tar.zst" -C "$scratch"
tar -xOzf "$record/../gpi2-deadline-misses-20261109/evidence.tar.gz" ./tools/gpi2_metrics.c \
    > "$scratch/tools/gpi2_metrics.c"
cd "$scratch"
for run in bare-1-rt trace-1-rt bare-2-rt trace-2-rt; do
    python3 tools/analyze.py "$run"
    python3 tools/analyze_stages.py "$run"
done
python3 characterize.py bare-1-rt trace-1-rt bare-2-rt trace-2-rt
```

For another replay on the same topology, use the original detector and
calibration paths described in the released replay record. Build against
the registered SDK selected by the archived environment. The probe build
uses headers and libraries from Julia 1.13.3.

```sh
julia +1.13.3 --startup-file=no --project=env -e 'using Pkg; Pkg.instantiate()'
export PIPEWIREAO_PREFIX="$(julia +1.13.3 --startup-file=no --project=env -e 'using PipeWireAO_jll; print(PipeWireAO_jll.artifact_dir)')"
bash build.sh
bash build-probe.sh
bash run.sh repeat-bare-1-rt 120000 8000 bare
bash run.sh repeat-trace-1-rt 120000 8000 trace
bash run.sh repeat-bare-2-rt 120000 8000 bare
bash run.sh repeat-trace-2-rt 120000 8000 trace
```
