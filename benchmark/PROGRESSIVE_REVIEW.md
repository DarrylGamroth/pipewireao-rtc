# Progressive Copper delivery review

Review date: 2026-09-30. Status: confirmed HEART delivery failure retained;
successful repeats do not establish a repair or repeatable loss-free delivery.
This is software benchmark analysis, not a physical-loop or real-time claim.

## Scope and provenance

The requested contract requires every offered frame to produce exactly one
ordered physical DM command, followed by numerical and packet-ingress-to-DM
latency comparison of the complete HEART, FGN, and JFG chains. Startup frames
are included. The workload is 474 Hz, nominal 2,000 µs readout, and two 32-row
datagrams per 64 × 64 WFS frame. The measured packet gap is approximately
1,000 µs; nominal readout must not be substituted for measured arrival times.

The user explicitly requested that HEART remain unchanged. This review used
existing artifacts, source inspection, and read-only inspection of executable
symbols and disassembly. It made no HEART changes, ran no builds or live
experiments, and did not change the qualification criteria.

- Review worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-progressive-requal`.
- Review branch: `copper-progressive-requal-20260929`; starting commit
  `5f7e37e9dd5995d613da6858e096acb5162346f9`.
- HEART source: `/home/dgamroth/workspaces/codex/heart/heart-copper-comparison`,
  revision `6a5c06b11a8b934effeb6328a73a70895b2af94a`.
- Existing RTC worktree changes at review creation:
  `benchmark/run_copper_baseline.py`, `benchmark/test_run_copper_baseline.py`,
  `benchmark/PROGRESSIVE.md`,
  `benchmark/data/copper_progressive_short_20260930.json`, and
  `benchmark/data/pipewireao_jll_ready_retry_release_20260929.json`.
  This assignment owns only this review file.

The [comparison plan](PROGRESSIVE.md) states acceptance. Source references below
are relative to this workspace; capture references are local evidence paths.

## Evidence ledger

| Artifact | Observed result | Interpretation |
| --- | --- | --- |
| [First short run qualification](/home/dgamroth/.cache/rtc-copper-progressive-ready-short-20260930/run-001/heart/qualification.json) | 32 WFS frames, all 64 packets, zero payload mismatches; 31 DM commands with IDs `[1, 1, 4…32]` | Failed exact delivery; retained evidence |
| [Second short run qualification](/home/dgamroth/.cache/rtc-copper-progressive-ready-short-r2-20260930/run-001/heart/qualification.json) | 32 ordered HEART DM commands, all 64 WFS packets | HEART repeat passed; parent reports the overall attempt stopped at the FGN plugin-hash guard before FGN ingress |
| [Third short run manifest](/home/dgamroth/.cache/rtc-copper-progressive-ready-short-r3-20260930/manifest.json) | Three-way 32-frame row replay qualified | A successful finite trial, not a correction of the first failure |
| [Normal progressive series](/home/dgamroth/.cache/rtc-copper-progressive-ready-1024x3-20260930/manifest.json) | All nine 1,024-frame replays qualified across three trials and three implementations | Repeated finite delivery and numerical passes; no HEART remediation occurred |
| [Traced short HEART qualification](/home/dgamroth/.cache/rtc-copper-progressive-heart-trace-32-20260930/qualification.json) | All 64 correct WFS packets; 31 commands with IDs `[1, 1, 4…32]` | Independent diagnostic reproduction of the first failure |
| [Historical full-frame manifest](/home/dgamroth/.cache/rtc-copper-fullframe-merged-ready-resolved-1024x3-20260929/manifest.json) | Three 1,024-frame trials; HEART selected `--ingress-mode deferred` | Comparison scope includes the synchronization described in PR-02 |

The successful normal series and both failed short attempts remain part of the
evidence. No claim of failure-free delivery across attempts or an actual HEART
fix follows from selecting the successful series.

## PR-01 — Latest prepared bucket can diverge from the frame trigger

Severity: **High** for exact delivery. Confidence: **High** in the observed
failure path and source mechanism; the cause of the initial delay is separate
(PR-03). Disposition: **Confirmed; retained without HEART remediation**, per the
user's instruction. No actual HEART fix is established.

**Observed.** The [failed scao log](/home/dgamroth/.cache/rtc-copper-progressive-ready-short-20260930/run-001/heart/scao.log)
records `local_setReaderMostRecent` jumping from read counter 0 to 2 at
`00:00:41.583606`, followed by WFS processor output invalidation, reconstructor
input rejection, and later a same-read-counter error. The first two DM commands
have the same frame ID and identical command payloads.

The [WFS capture](/home/dgamroth/.cache/rtc-copper-progressive-ready-short-20260930/run-001/heart/std-wfs-packets.tsv)
and log place events as follows, relative to the first captured WFS packet:

| Event | Elapsed time |
| --- | ---: |
| Wire frame 0 terminal packet | 957.720 µs |
| Wire frame 1 first packet | 1,571.488 µs |
| Wire frame 1 terminal packet | 2,565.906 µs |
| Processor reports bucket jump 0 → 2 | approximately 2,717 µs |
| Wire frame 2 first packet | 3,679.158 µs |

Wire frame IDs are zero-based; the expected HEART DM IDs are one-based.

**Source mechanism.** The producer increments its internal frame ID and calls
`hrtWfsInputBlock_handlerParamsUpdate` before reading the next frame
([hrtWfsInputBlock.c](../../../heart/heart-copper-comparison/source/blocks/src/hrtWfsInputBlock.c)).
Relevant locations are `hrtWfsInputBlock_process`, lines 2629–2641, and
`handlerParamsUpdate`, lines 1843 and 1939.
`hrtCB_initBucketProgress`, lines 1988–2008, sets progress to zero and marks that
next bucket `updating`. `local_setReaderMostRecent`, lines 896–964, selects the
current nonempty write bucket, including an updating bucket
([hrtCircBuffer.c](../../../heart/heart-copper-comparison/source/util/src/hrtCircBuffer.c)).

`hrtBlock_rawTriggerDownstream`, lines 3666–3691, posts a semaphore without
carrying `cbFrame`; `hrtBlock_worker` consumes that semaphore at line 1867
([hrtBlock.c](../../../heart/heart-copper-comparison/source/blocks/src/hrtBlock.c)).
The processor therefore selects its input independently of the frame that
caused the pending trigger. `hrtWfsProcBlock_getBuckets` treats the read-counter
jump as failure at lines 3757–3759. Error handling invalidates the output and
forces downstream processing at lines 4602–4629
([hrtWfsProcBlock.c](../../../heart/heart-copper-comparison/source/blocks/src/hrtWfsProcBlock.c)).

**Derived.** The reported jump to bucket 2 preceded the first packet of wire
frame 2. The source permits exactly this selection of a prepared future bucket.
The evidence supports a frame-selection hazard during catch-up; it does not
require packet loss or circular-buffer capacity exhaustion. Increasing buffer
capacity alone does not change latest-bucket selection. CORE/JLL repairs do not
repair this direct HEART path.

**Recorded diagnostic reproduction.** The existing
[progress trace](/home/dgamroth/.cache/rtc-copper-progressive-heart-trace-32-20260930/runtime/progress-trace.csv)
contains zero lost events on each of five recorded threads and zero untraced
threads. Times below use one monotonic clock, relative to first WFS receive
`1520404012153578 ns`. A DM event's `frame` is the one-based command ID;
its `sync` field is zero, so it must not be grouped as a WFS sync-zero frame.

| Event | Frame / sync | Elapsed time |
| --- | --- | ---: |
| First 32 rows published | 0 / 1 | 32.460 µs |
| Processor completes first 32 rows | 0 / 1 | 157.354 µs |
| MVM completes first 1,800 columns | 0 / 1 | 431.837 µs |
| Terminal WFS packet received | 0 / 1 | 835.241 µs |
| Final 32 rows published | 0 / 1 | 837.616 µs |
| Next frame first packet received | 1 / 2 | 1,502.068 µs |
| Next frame input complete | 1 / 2 | 2,499.623 µs |
| Processor observes frame 0 final rows | 0 / 1 | 2,509.421 µs |
| Processor completes frame 0 final rows | 0 / 1 | 2,515.222 µs |
| MVM complete | 0 / 1 | 2,614.067 µs |
| First DM send completes | DM ID 1 | 3,002.693 µs |
| Frame 2 first packet received | 2 / 3 | 4,593.357 µs |
| Repeated DM send completes | DM ID 1 | 4,987.424 µs |
| Processor resumes valid first-half work | 3 / 4 | 5,753.586 µs |

There are no processor or reconstruction progress events for sync 2 or 3.
The [diagnostic scao log](/home/dgamroth/.cache/rtc-copper-progressive-heart-trace-32-20260930/scao.log)
records the same 0 → 2 jump at `00:14:53.888241`, then the same-counter error
for bucket 2 at `00:14:53.890354`. The
[packet timestamps](/home/dgamroth/.cache/rtc-copper-progressive-heart-trace-32-20260930/std-wfs-packets.tsv)
place the first error after frame 1 terminal arrival (`.888179442`) and before
frame 2 first arrival (`.890272986`) on the log/capture wall-clock timeline.
These observations independently reproduce the prepared-future-bucket ordering.

The trace confirms two sends of DM ID 1 during replay. Downstream logs record
invalid input and skipped integration. This is consistent with the existing
CLWC behavior: integration is skipped for an invalid input, while command
construction uses retained integrator state and the selected input sync ID
(`hrtClwcBlock.c`, lines 2274–2305, 3234–3235, and 3463–3501;
[source](../../../heart/heart-copper-comparison/source/blocks/src/hrtClwcBlock.c)).
The trace does not record every TFC/CLWC intermediate bucket, so the exact
downstream invalid-bucket selection is not independently timed.

**Required validation.** The trace establishes the failure ordering and
localizes the processing delay as described in PR-03. Preserve all attempts.
Any future remediation would require separate authorization and a regression
that reproduces this ordering before the change and passes after it.

## PR-02 — Deferred ingress adds synchronization to the comparison

Severity: **Medium** for causal performance claims. Confidence: **High**.
Disposition: **Accepted comparison limitation; no HEART change requested**.

**Observed.** The historical manifest selects `--ingress-mode deferred`; the
progressive runs select progressive ingress. The runner sets
`HRT_DEFER_WFS_INGRESS` accordingly at lines 203–205 of
[run_copper_aos_matched.sh](../../JuliaFilterGraph-progressive-requal/benchmark/heart/run_copper_aos_matched.sh).
The YAML files are identical because this mode is selected through the
environment.

**Source and executable evidence.** `hrtStdWfs_start` reads the environment at
lines 318–350 under `HRT_DEFER_WFS_INGRESS_BUILD`. In the deferred branch at
lines 672–747, the handler receives both datagrams, releases the first 32 rows,
waits for the WFS processor to snapshot 32 rows, and waits for recon to snapshot
1,800 inputs before releasing the second 32 rows
([hrtStdWfsHandler.c](../../../heart/heart-copper-comparison/source/device/src/hrtStdWfsHandler.c)).
These waits are independent of `HRT_PROGRESS_TRACE`; that separate guard wraps
the timing instrumentation around the recon wait. Read-only executable
inspection found the environment lookup and value comparison in
`hrtStdWfs_start`, plus the deferred-wait functions and associated diagnostics.

**Derived.** The deferred mode changes both the availability timeline and
producer/consumer synchronization. Its handshake can prevent advancement
before downstream stages take their snapshots. The historical pass therefore
does not isolate progressive overlap as the sole cause of a latency or delivery
difference.

**Required validation.** Report latency as a comparison of these configured
complete chains. Preserve the ingress mode, binary provenance, and measured
packet spacing. Do not label the entire latency difference an isolated
progressive-computation benefit. A trace can show how much time is spent in the
deferred waits without changing HEART source.

## PR-03 — Cold calibration confirmed; original delay attribution remains open

Severity: **Medium** investigation gap. Confidence: **High** for the observed
cold-calibration call path; attribution of the original delay remains incomplete.
Disposition: **Confirmed first-use work, open causal attribution; measurement
only**. No startup configuration fix has been demonstrated.

**Observed.** The failed run's first DM packet arrived 3,113.901 µs after the
first WFS packet. In the successful second run it arrived after 2,396.269 µs.
The second frame's first packet arrived after 1,571.488 µs in the failed run
and 2,024.825 µs in the successful run. See the failed capture above and the
[successful WFS capture](/home/dgamroth/.cache/rtc-copper-progressive-ready-short-r2-20260930/run-001/heart/std-wfs-packets.tsv)
and [successful DM capture](/home/dgamroth/.cache/rtc-copper-progressive-ready-short-r2-20260930/run-001/heart/std-dm-packets.tsv).
Arrival timing is variable despite the shared nominal rate. The second run
also contains later compressed intervals while retaining exact delivery.

**Derived from the diagnostic trace.** Frame 0's final-row publication to
processor observation takes **1,671.805 µs**. After observation, the processor
records completion only **5.801 µs** later. This localizes the large first-frame
gap before the processor's second availability observation, rather than to
terminal PWFS execution or the subsequent MVM. It does not establish what the
processor thread was doing during that gap. Producer trace events are recorded
after publication, so sub-microsecond differences between producer and consumer
records should not be interpreted as precise queue residence times.

**Source mechanism.** One concrete first-use cost is
`daoRT_pauseUsecFraction`: the processor calls it while waiting for more rows
(`hrtWfsProcBlock.c`, line 4265). If `daoRT_pausePerMicrosecond` is zero, it calls
`daoRT_pauseCalibrate(0)` (`daoRealtime.c`, lines 1953–1957). Calibration executes
ten pause loops per batch until the minimum loop duration is at least 100 µs;
the final batch therefore takes at least 1 ms (`daoRealtime.c`, lines
1834–1865;
[source](../../../heart/daoinsw-heart-comparison/source/util/src/daoRealtime.c)).
The original trace alone does not establish whether calibration occurred in that
interval. Some executor setup paths pre-calibrate it. Duration similarity alone
is not proof of causal attribution.

**Observed in the subsequent debugger probe.** The retained
[GDB log](/home/dgamroth/.cache/rtc-copper-heart-calibration-probe-20260930.gdb.log)
shows `daoRT_pausePerMicrosecond = 0` at attachment before ingress and again at
the calibration breakpoint. Thread `HOP0.proc.w`, LWP 3172405, entered
`daoRT_pauseCalibrate(calibrate=0)`. Its stack is
`daoRT_pauseUsecFraction(0.0500000007)` →
`hrtWfsProcBlock_processPixelStream:4265` → `hrtWfsProcBlock_process:3450` →
`hrtBlock_worker`. Lazy initialization in the row-processing wait is therefore
confirmed for this execution, rather than inferred from matching durations.

The debugger recorded `CALIBRATION_ENTRY_MONOTONIC_NS=1521981431343809`.
The associated
[progress trace](/home/dgamroth/.cache/rtc-copper-heart-calibration-probe-20260930/runtime/progress-trace.csv)
records frame 0's first 32-row processor publication at 1521981428607967 ns
and final-row producer publication at 1521981429466936 ns, before that debugger
record. These are ordered observations in one monotonic clock domain, not a
calibration duration: the timestamp is sampled by GDB while handling the stop,
and the probe has no matched calibration-return timestamp. The all-stop debugger
changes scheduling and producer/consumer timing. The
[command record](/home/dgamroth/.cache/rtc-copper-heart-calibration-probe-20260930-command.json)
explicitly labels the experiment intrusive and latency invalid; its runner exit
status is 1. This diagnostic execution is not a delivery or latency pass.

**Residual hypotheses.** The probe establishes a real cold work item in this
path; it does not quantify its share of the original uninstrumented 1,671.805 µs
gap or exclude descheduling, faults, or other transient work. Calibration has not
been established as the sole cause of the original stall or delivery failure.
Longer pre-ingress sleep,
changed priorities, eager symbol binding, or warmup would be experiments, not
justified fixes from this evidence. Discarding initial frames would also change
the stated acceptance contract.

**Next measurement.** The progress trace answered the stage-ordering question,
and GDB confirmed entry into lazy calibration. A subsequent diagnostic run can
use a non-stopping targeted entry/return probe on `daoRT_pauseCalibrate`, plus scheduler events and
page-fault events for the processor thread. This can distinguish calibration
from descheduling or faults without changing HEART source. Correlate these
events with the existing monotonic progress records; do not subtract packet
wall-clock timestamps from monotonic timestamps. Keep diagnostic runs separate
from normal latency trials, without concurrent builds or experiments. Preserve
the capture boundary: the trace also records a shutdown-time DM send after the
single shutdown marker, outside the replay/capture interval; this must not be
counted as an additional delivered replay command.

## Existing function profiling and candidate CPU costs

**Observed build limitation.** Function profiling is compiled and active in
the measured HEART executable. The utility and block
[Makefile](../../../heart/heart-copper-comparison/source/util/src/Makefile)
and [Makefile](../../../heart/heart-copper-comparison/source/blocks/src/Makefile)
include `-pg` at lines 59 and 65 respectively; the
[template link](../../../heart/heart-copper-comparison/source/template/src/Makefile)
uses `-pg` at line 63. The executable imports `mcount` and `__monstartup`,
exports `__gmon_start__`, and disassembly shows an `mcount` call at entry to
the hot polling function `hrtCB_getNewBucketProgress2`. Existing `gmon.out`
files contain samples and call records readable with `gprof`. This is active
instrumentation, not merely an unused linker symbol or stale filename.

Reading the normal series' first HEART
[profile](/home/dgamroth/.cache/rtc-copper-progressive-ready-1024x3-20260930/run-001/heart/runtime/gmon.out)
with `gprof -b -p` gives the following candidate CPU costs:

| Function | Reported self time | Share of sampled self time |
| --- | ---: | ---: |
| `daoRT_pause` | 0.78 s | 46.43% |
| `daoRT_pauseUsecFraction` | 0.34 s | 20.24% |
| `hrtVec_acc_ax` | 0.18 s | 10.71% |
| `hrtVec_dot` | 0.10 s | 5.95% |
| `hrtCB_getNewBucketProgress2` | 0.07 s | 4.17% |
| `hrtHoReconBlock_mvmPipeline` | 0.06 s | 3.57% |

These are whole-process, coarse 10 ms samples, including startup and deliberate
polling. They are candidates for focused CPU profiling, not first-frame latency
attribution or accurate per-thread call counts. The short diagnostic profile
contains only four sampled ticks and cannot support ranking small costs.
Multithread call-count output is visibly unsuitable for exact frame accounting:
for example, it reports 985 `hrtHoReconBlock_mvmPipeline` calls in a qualified
1,024-command normal replay. Packet and lineage accounting remain authoritative.

The deployed comparison therefore characterizes this profiled HEART build.
Profiling overhead is a comparison limitation and a possible contributor to
CPU cost; there is no measurement isolating its contribution to latency or the
first-frame failure. No rebuild or removal of profiling is authorized or
performed in this review.

## Review completion

This artifact records findings and proposed measurements only. HEART remains
unchanged. Local links, trailing whitespace, final newline, and unique finding
IDs were checked. No implementation tests, builds, live benchmarks, or hardware
validation were performed by this review assignment.
