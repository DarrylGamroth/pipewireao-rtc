# Classic scheduler and idle-state investigation

Tool provenance: the Python scripts and retired Julia launcher referenced here
were removed from the current checkout on 2026-10-08. Commands describe the
[recorded source revision](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/CLASSIC_PLATFORM.md);
these commands are not runnable in this checkout. Results and design claims
retain their original scope. See the [current benchmark index](README.md) for retained tooling.

## Question

The corrected-source Classic baseline has substantially larger FGN/JFG row
latencies at 100 Hz than at 250 Hz despite the same scientific work and nominal
2 ms readout. Captured readout differs by tens of microseconds while residual
latency differs by hundreds. This motivates scheduler/idle measurements; it
does not establish a power-management or scheduler defect.

This laboratory experiment leaves the developed graphs, fixtures, integrator
state, clipping feedback, HEART executable and wfsSimulator unchanged. It
changes no persistent power policy, governor, IRQ placement, or SMT setting.

The earlier cyclictest command included `--default-system`, documented by the
installed program as leaving power management unsuppressed. Periodic wakeups
are a possible explanation for its influence. CPU latency QoS is a separate
intervention to test.

## Matrix and acceptance

The platform campaign counterbalances path, rate, and request order:

| Axis | Values |
| --- | --- |
| RTC | unchanged HEART, FGN row, JFG row |
| Source | unchanged wfsSimulator, common repeated Classic FITS data |
| Rate | 100 Hz, 250 Hz |
| Readout | nominal 2,000 µs, 32 packets per frame |
| CPU latency request | none; session-owned 0 µs |
| Normal windows | 1,029 frames; three repetitions per combination |
| Diagnostic windows | 252 frames; one repetition per combination |

HEART/off is excluded: unchanged `hrtTemplate.c:349` unconditionally calls
`daoRT_setCstateLatencyUsec(0)`. Recorded effective QoS is already zero before
ingress once the existing rtc group makes the device accessible. The matched
comparison is HEART versus FGN/JFG at zero; FGN/JFG also have an off condition.
This does not retrospectively establish QoS in earlier measurements without
device readback.

The shorter corpus repeats the same original seven images 36 times and has
matching continued HEART references. The normal corpus repeats them 147 times.
Controller state is continuous within a window. Diagnostic windows stay inside
existing native trace capacities. Instrumented distributions do not replace
normal performance distributions. All-frame results are retained, alongside
a separate after-first-100 distribution; preparation does not prove warmed
science callbacks.

Each case must pass exact delivery, numerical acceptance, normal child exit,
functional checks, source rate within 1%, and no harness errors. Failed cases
remain evidence and are excluded from accepted comparisons. No latency samples
are substituted for missing commands.

## Capture and resource ownership

An optional laboratory barrier waits after receiver/capture preparation and
before source launch. The parent verifies QoS, enables perf with an acknowledged
control command, and releases ingress. A completion marker ends instrumentation
after wire capture closes and before validation/report writing. These markers
operate outside frame processing. A failed admission keeps ingress closed.
Each case has its own process group for bounded cleanup.

The owned request descriptor is not inherited by children and closes on normal
or exceptional exit. Its scope is prepared receiver through capture completion.
Effective values before, during and after release are recorded. The request is
host-wide while held and can increase power use. Frequency, temperature, idle
residency counters, interrupts, RT allowance, topology, process placement,
configuration/binary hashes, revisions, captures and raw intervals are retained.

The existing rtc group permits `/dev/cpu_dma_latency` through a udev rule and
selected perf metadata through a root oneshot service. Tracing controls remain
root-owned. Current-session measurements use `sg rtc`; future logins inherit
membership. The permission helper now includes `events/header_page` and
`events/header_event`, needed in addition to event `id` and `format`. Those
two files were granted group access manually for this session; the installed
helper still needs updating to persist that addition after reboot.

Example normal campaign from this repository:

```sh
sg rtc -c 'taskset -c 14 python3 benchmark/run_classic_platform_campaign.py --output /path/to/new-results'
```

The orchestrator uses housekeeping CPU 14; receiver admission starts with the
Ryzen host CPU envelope before existing role-specific placement. User units
remain a future deployment option; the host must grant the user manager its RT,
memory-lock and cgroup permissions. This experiment adds no deployment units.

## Diagnostic interpretation

Perf records scheduler switches, wakeups and migrations across all CPUs using
CLOCK_MONOTONIC. Idle transitions are filtered to CPUs 0, 2 and 4 (WFS/filter,
science and adapter/reconstructor roles), avoiding excessive unrelated poll-idle
events. Full-machine idle residency counters still accompany each run.
Existing compile-time private records cover receive/publication, native filter
dequeue/callback/recycle, FGN processing, JFG callback boundaries and HEART
stages. No diagnostic binaries are deployed globally.

Installed perf 6.12 acknowledges with five bytes `ack\n\0` and re-raises SIGINT
after writing the trailer. Decoding must succeed; a capture banner is insufficient.
Event loss and native omissions must be checked before drawing conclusions.
Source publication to callback delay, wakeup to running delay, and callback
wall duration are different quantities. Intersect callback brackets with
off-CPU intervals to distinguish execution from descheduling. A controlled
request can demonstrate a benefit from avoiding idle states without proving
that every tail originates in idle-state exit.

## Retained preflights

The controlled scheduler/idle capture records and decodes successfully. The
63-frame FGN diagnostic smoke delivered all 2,016 WFS packets and 63 DM commands,
passed science checks and exited normally. Two earlier startup attempts failed
before ingress (optional temperature probe, corpus extent); another HEART
attempt failed its affinity admission before ingress. These are harness setup
failures, not RTC delivery failures.

The first 252-frame diagnostic campaign retained a HEART/off window labelled
invalid because of its intrinsic request, plus a successful HEART/zero window.
Its broad idle recording continued into validation, exhausted disk space, and
interrupted finalization of the next FGN case. Captures were compressed with
hashes retained; completed compilation caches were removed. Retry windows use
the completion marker and filtered idle event. These failed attempts remain
excluded from the completed matrices below.

## Completed normal results

All 30 normal windows passed the specified gates: 987,840 WFS packets and
30,870 ordered DM commands, with no observed frame-period deadline misses.
Each window contains 1,029 frames; the table excludes its first 100 and reports
the range of three separate window percentiles. These are not pooled
percentiles or confidence intervals. All-frame distributions remain in
[the compact evidence](data/classic_platform_20260930.json).

Terminal captured WFS packet → captured UDP DM command, µs:

| RTC | Rate | Off p50 | Off p99 | Zero request p50 | Zero request p99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| FGN row | 100 Hz | 411.1–480.9 | 1,290.7–1,412.2 | 62.4–63.3 | 72.2–80.4 |
| FGN row | 250 Hz | 55.2–213.6 | 143.2–999.2 | 61.9–63.7 | 66.9–76.2 |
| JFG row | 100 Hz | 571.9–581.2 | 1,092.4–1,158.5 | 80.3–87.5 | 103.3–189.7 |
| JFG row | 250 Hz | 104.1–149.2 | 499.2–738.3 | 79.9–85.9 | 121.9–149.3 |
| HEART | 100 Hz | Excluded | Excluded | 85.4–86.2 | 101.0–109.2 |
| HEART | 250 Hz | Excluded | Excluded | 84.2–84.8 | 92.0–141.6 |

The repeated intervention substantially reduces the FGN/JFG tails and rate
dependence. FGN has lower typical and p99 latency than HEART in these matched
zero-request windows; Julia has comparable typical latency and a larger p99
range. One FGN 250 Hz off median is lower than the zero-request medians: the
evidence does not show every quantile improving in every window.

The unchanged HEART source always requests zero through DAO's
`daoRT_setCstateLatencyUsec`. An earlier baseline log records failure to open
`/dev/cpu_dma_latency`. Enabling existing group access changes whether this
existing request succeeds; it is not a HEART algorithm or binary change. Old
results without effective-QoS readback cannot be silently relabelled.

The normal manifest is
`~/.cache/rtc-classic-platform-normal1029-20260930/manifest.json`, SHA-256
`6d8ab496a5e61591bf91373aa98220653806912113ae654187bede6faf15f44a`.
Six archived executed harness files match the recorded hashes. The original
normal campaign predates the cleanup/admission corrections described in
[the independent review](../docs/CLASSIC_PLATFORM_REVIEW.md); all its groups
were separately checked absent. The original executed source is preserved.
All endpoint QoS readings match the intended conditions, and all after-run
readings return to 2,000,000,000 µs. The 13 FGN/JFG parameter-file hashes match
across their windows. Raw captures, per-frame intervals, readout/pacing
distributions, placements, and failed attempts remain local evidence.

## Completed diagnostic results

All ten fresh 252-frame cases passed delivery, numerical and pacing gates.
Their scheduler traces decoded without reported loss or parsing errors. All
eight FGN/JFG cases matched 8,064 ordered receive, publication and science
callback records and 252 command brackets, with no omitted native records.
HEART has no JFG/FGN callback CSV and therefore does not receive that callback
qualification flag; its scheduler trace still qualifies.

The retained directory is
`~/.cache/rtc-classic-platform-diagnostic252-final-20260930`. Scheduler,
handoff and completed-prefix analyses retain input hashes. Private diagnostic
libraries were used only for these runs. Their measurements include tracing
overhead and do not replace the normal latency table.

For the terminal row, post-`recv` observation R → publication P p99, µs:

| RTC | Rate | Off | Zero request |
| --- | ---: | ---: | ---: |
| FGN row | 100 Hz | 1,394.6 | 14.9 |
| FGN row | 250 Hz | 754.6 | 14.6 |
| JFG row | 100 Hz | 1,310.4 | 18.4 |
| JFG row | 250 Hz | 735.9 | 21.3 |

This locates most of the millisecond delay before publication. R → P includes
assembly, validation, admission and queue residence; downstream availability
can affect it. It is not isolated source execution, socket-arrival latency, or
proof of a particular idle-state mechanism. P → science-body start p99 is
2.9–7.0 µs for FGN and 8.5–15.8 µs for Julia. Julia's native input-ready
observation → body start terminal p99 is 0.370–0.591 µs, with a largest
maximum of 1.333 µs. This native G observation follows buffer collection,
projection and region validation; it measures only the final callback entry
segment. The sink C bracket contains metadata bookkeeping and
`transmit_command`, rather than isolating the send syscall.

Intersecting terminal R → P with the attested CPU 0 source-loop scheduler
intervals gives exact overlaps for all 2,016 terminal records. Without the
request, off-CPU time accounts for 67% and 64% of aggregate Julia R → P wall
time at 100 and 250 Hz respectively; the FGN fractions are 21% and 17%.
FGN still has R → P wall-minus-off-CPU p99 of 1,016 and 636 µs. That remainder
includes assembly, other queued processing, kernel/interrupt work and tracing,
so it is not pure source self time. With the zero request, no FGN terminal
R → P interval is descheduled; Julia has two such frames at 100 Hz and one
at 250 Hz, principally the cold first frame. This supports source-loop
scheduling as part of the problem while leaving the FGN remainder unresolved.

Science callback off-CPU overlap is zero throughout all four FGN cases and
all Julia cases except one 6.913 µs interruption at 250 Hz/off. Wakeup → running
p99 is generally 2–9 µs. These observations exclude ordinary descheduling
inside the science body as the explanation for most of the large residual;
idle exit and other work before the wakeup tracepoint remain possible.
Terminal body wall p99 is 26–53 µs for FGN and 77–107 µs for Julia across these
instrumented cases. The wall interval also includes interrupts and tracing.
All four Julia cases show zero changes in process-wide GC pause, GC-time and
allocation counters inside every body. This is a measured counter boundary,
not proof of zero allocation in all native transport or lifecycle work.

Under the existing fixed-graph and endpoint clock-envelope assumptions,
FGN with the zero request completes at least 184 of 188 subapertures and 368
of 376 MVM columns before the terminal captured packet in every diagnostic
frame. Julia completes at least 166–184 subapertures and 332–368 columns.
These are source-derived completed prefixes, not individual kernel timing.
With no request, ten FGN 100 Hz frames and one Julia 100 Hz frame have no
provable positive prefix before that boundary. Exact final delivery still
passes. Thus delivery success alone does not establish readout overlap.

## Changes and remaining deployment work

This increment adds the session-owned latency request, laboratory ingress
barrier, bounded perf capture, effective-QoS admission, process-group cleanup,
offline analyzers and qualified summary selection. It changes no science
algorithm, calibration or globally installed diagnostic binary. Cleanup of a
child surviving its exited parent has retained fail-before/pass-after process
evidence; a conflicting off request now prevents ingress in its regression.

Systemd user units can supervise a future session and apply initial affinity.
Per-thread role placement must still be applied by the existing runtimes.
On this host the user manager has `LimitRTPRIO=0`, `LimitMEMLOCK=8388608` and
delegated `cpu memory pids` controllers, without cpuset delegation. Host
provisioning must establish suitable limits and CPU-controller permissions
before user units can reproduce this placement; merely moving the launcher
into a user unit does not isolate cores. The existing privileged permission
service grants metadata access only. No operational service or cgroup policy
is implemented in this laboratory increment.

Three finite windows per condition establish the observed comparison, not a
rare-tail guarantee, maximum capacity, hard deadline bound, physical-loop
validation, or a universal host tuning prescription. The subsequent [terminal projection investigation](CLASSIC_PROJECTIONS.md)
profiles and improves the Julia science body under the matched zero request. Further
source investigation should attribute the remaining FGN R → P elapsed time
before changing transport behavior.

## Verification

The final 216 Classic Python tests pass, including descriptor cleanup,
barrier admission, process-group escalation, compressed evidence, perf
acknowledgement, scheduler censoring/loss, ordered native handoffs, GC-counter
parsing and qualified summary selection. Permission scripts pass `sh -n`;
the final diff passes whitespace checks. Changed documentation has valid local
links and final newlines; the roadmap Mermaid diagram renders successfully.
The independent review verifies the completed matrices and the source-loop
intersections, with its claim limits preserved.

Completed private compilation caches and ignored Rust build intermediates
were removed to recover disk space. Their retained cleanup manifest lists
the paths and bytes removed; sources, installed libraries, private tracing
libraries and captured evidence were preserved. Cleanup occurred between
normal timed capture windows. The earlier disk-full attempt remains a failed
harness attempt rather than an accepted RTC window.
