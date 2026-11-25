# GPI2 captured CUDA replay at 500 µs

On 2026-11-22 the released cohort delivered complete woofer, tweeter and
tip/tilt commands for all 240,000 measured offers. The first FIFO run met
every 500 µs deadline. The repeat missed four deadlines, for a combined
239,996 on-time command sets and four late sets.

## Workload and cohort

The fixed-rate replay reproduces the commands-only GPI2 workload from the
[November 9 campaign](../gpi2-connected-20261109/README.md). It cycles the
same 1,062 retained 242 × 240 UInt16 detector frames in corpus order and uses
the same graph, calibration receipt and parameter assets. The loader checks
the corpus, graph, parameter configuration and every parameter against their
retained SHA-256 values. The captured CUDA graph keeps delayed constraint
feedback on the device. It publishes the woofer, tweeter and tip/tilt
commands to non-actuating native sinks.

The exact registered environment resolves PipeWireAORTC 0.7.28, PipeWireAO
0.9.6, PipeWireAO_jll 4.0.8+0, FilterGraphPipeWire 0.5.10, FilterGraphs 0.10.6
and FilterGraphAlgorithms 0.12.12. The native client, graph owner and core
all map the published AVX2 SDK with artifact tree
`77da251765f3124df77322c562e67a7c7742ab1d`. The launcher uses Julia 1.13.3,
CUDA 6.5.1 and KernelAbstractions 0.10.7. The private core connects the
source, released graph owner and sinks directly. The RTC release is pinned
in the environment. The measured path covers the owner and
transport. The [managed profile results](README.md) cover RTC lifecycle
through MediaSession and systemd.

## Measurement

The source's absolute monotonic timer accounts for every 500 µs release
independently of command completion. It accounts for every scheduled release
when a timer callback wakes late. The source reserves up to two pending
frames. Each run starts fresh processes on a unique socket. There is one
priming release, 8,000 warmup releases and 120,000 measured releases. A
measured window covers 60 seconds. The callback sampler is disabled.

End-to-end latency is elapsed monotonic time from the scheduled release to
the last receipt of the three commands. Publication latency starts just
before the source queues the complete detector buffer. The sinks check the
rate, dtype, shape, layout, terminal Header, sequence, propagated PTS and
finite payloads. The offline analyzer checks ordered per-sink receipts and
reconciles the three timestamps with each completed command set. A source
rejection, an accepted offer without all three commands, or receipt after
500 µs counts as an unsuccessful slot. The deadline counts use every
offered release as the denominator. Percentiles use nearest rank over
complete three-command sets, including late completions.

The graph, source and command data loops use FIFO priority 15 on CPUs 4,
8 and 10, respectively. The private core uses ordinary scheduling on CPU 2.
The four CPU IDs are on distinct physical cores. The launcher inspects the
kernel's effective affinity, policy and priority before ingress, late in
warmup and after the sampling window. The environment lets existing host
workloads continue and uses the shared workstation benchmark lock. The
archive records co-resident thread affinities and GPU compute processes
before and after sampling.

Before connecting, each graph owner compared its first 32 captured CUDA
command sets with the CPU reference using a 10⁻⁹ m maximum absolute
difference limit. The differences were 1.158 × 10⁻¹² m for woofer,
2.586 × 10⁻¹² m for tweeter, and 1.248 × 10⁻¹³ m for tip/tilt in both runs.
Each fixture load matched all 33 parameter hashes. The live receipt
ledger verified all three command identities and ordered receipts.

## Results

The November 9 column is the archived 120,000-slot FIFO run with the
sampler disabled. All timing rows are in µs. Cadence error is the absolute
deviation of the detector publication interval from 500 µs.

| Measured result | November 9 | November 22 run 1 | November 22 run 2 |
| --- | ---: | ---: | ---: |
| Offered slots at 2,000/s | 120,000 | 120,000 | 120,000 |
| Source rejections | 0 | 0 | 0 |
| Accepted but unpublished | 0 | 0 | 0 |
| Published without all three commands | 0 | 0 | 0 |
| Complete command sets | 120,000 | 120,000 | 120,000 |
| Completed after 500 µs | 0 | 0 | 4 |
| Slots without an on-time command | 0 | 0 | 4 (0.0033%) |
| Scheduled release to last command, p50 | 359.641 | 363.084 | 378.074 |
| Scheduled release to last command, p99 | 377.834 | 383.078 | 410.717 |
| Scheduled release to last command, p99.9 | 395.885 | 396.732 | 430.600 |
| Scheduled release to last command, worst | 435.904 | 475.727 | 856.069 |
| Publication to last command, p50 | 346.138 | 349.495 | 364.363 |
| Publication to last command, p99 | 362.068 | 367.669 | 395.331 |
| Publication to last command, p99.9 | 378.479 | 377.568 | 413.194 |
| Publication to last command, worst | 416.450 | 462.206 | 825.186 |
| Timer lateness, p99 | 8.352 | 8.137 | 8.028 |
| Timer lateness, worst | 28.052 | 24.518 | 319.290 |
| Absolute publication cadence error, p99 | 6.288 | 8.533 | 7.461 |

All warmup offers completed in both November 22 trials. Six and eight
warmup sets finished after 500 µs, respectively. Each priming frame also
finished late. The scheduler recorded no batched timer expirations. The
source used at most one of its two pending reservations and had no buffer
dequeue failures. The graph, replay client and private core exited with
status zero in both measured runs.

Three of the repeat's late sets occurred on consecutive scheduled
releases. The worst set took 856.069 µs from release to the last command.
Its timer wake was 6.557 µs after release and detector publication was
30.883 µs after release. The remaining 825.186 µs elapsed after publication.
The next release's timer woke 319.290 µs late and its publication-to-command
interval was 394.539 µs. The receipt timestamps show where the elapsed
time accumulated. Attribution to individual callbacks, scheduler events
or GPU activity would need a trace.

## Workstation conditions

The workstation uses the same Ryzen 7 6800H and RTX 3080 as the November 9
campaign. The host kernel changed from 6.12.113 to 6.12.117 and the NVIDIA
driver from 615.71.10 to 620.70.06. The launch used Julia 1.13.3,
GPUCompiler 2.22.0 and the archived CUDA runtime, compiler and driver
package versions. The graph and native transport releases changed. The
CPU governor was `powersave` with the `performance` energy preference on
the benchmark CPUs. The old run did not record the same co-resident
workload observations. Differences between the two dates describe the
tested cohorts and host conditions.

The existing SPIDERS services continued throughout both runs. Ordinary
SPIDERS differential-owner threads shared CPU 10 with the command sink.
Other threads from that owner had affinity to sibling CPU 11. The SPIDERS
session and parameter service used CPU 5, the graph loop's SMT sibling. The preview service had affinity to
all CPUs. The snapshots recorded CPU time advancing on CPU 10 for the
SPIDERS differential owner and on CPU 5 for the SPIDERS session and
parameter service. Both GPU snapshots around each measurement listed only
the replay's CUDA graph owner. Thread-policy snapshots confirmed FIFO
priority 15 and the requested CPUs before ingress, in late warmup, and
after sampling. The graph and replay processes each reported 3,804 kB of
locked virtual memory and anonymous transparent huge pages. The core
reported zero locked memory and zero huge-page backing.

An initial launch stopped at the pre-ingress placement check with the
correct FIFO priority and masks. The kernel policy also carried
`SCHED_RESET_ON_FORK`. The launcher now records that flag separately from
the FIFO class. That attempt offered zero frames and is retained as
preflight evidence.

## Evidence and reproduction

The archive contains both complete per-offer ledgers with all three
receipt timestamps, the analyzed summaries, live placement and
co-resident snapshots, logs, registered package identities and manifest,
and the exact launcher, analysis and client sources. The external corpus
and calibration assets are identified by hashes.
[Evidence archive](replay-evidence.tar.zst) ·
[SHA-256](replay-evidence.tar.zst.sha256)

From this report's directory, verify the archive and regenerate the
summaries.

```sh
sha256sum -c replay-evidence.tar.zst.sha256
mkdir replay-evidence
tar --zstd -xf replay-evidence.tar.zst -C replay-evidence
cd replay-evidence
python3 tools/analyze.py fifo-1-rt
python3 tools/analyze.py fifo-2-rt
```

To repeat on the recorded workstation, instantiate the included manifest,
build the native client against its JLL SDK and start a new run. Use
`GPI2_APPLICATION` and `GPI2_INPUTS` to point to the original checked GPI2
calibration and detector corpus if they are outside the workstation
default paths. The launcher checks the recorded CPU topology and live FIFO
placement before accepting frames. It uses the shared workstation
benchmark lock and creates its own temporary PipeWire socket.

```sh
julia +1.13.3 --startup-file=no --project=env -e 'using Pkg; Pkg.instantiate()'
export PIPEWIREAO_PREFIX="$(julia +1.13.3 --startup-file=no --project=env -e 'using PipeWireAO_jll; print(PipeWireAO_jll.artifact_dir)')"
bash build.sh
bash run.sh repeat-rt 120000 8000
```
