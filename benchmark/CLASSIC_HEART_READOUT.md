# HEART work during Classic readout

## Measurement and claim boundary

This diagnostic enables existing `HRT_PROGRESS_TRACE_FILE` support in the
unchanged `scaoTemplate` executable. It does not modify or rebuild HEART.
`run_classic_heart_trace.py` uses the current campaign command and validated
63-frame repeated Classic corpus, 100 Hz and 2 ms requested readout. Two fresh
runs support the separate functional check of immediate public-telemetry
listener relaunch after the TCP port-guard fix. Original failed attempts remain
in the baseline manifest. Instrumented traces are excluded from capacity and
uninstrumented timing qualification.

The helper retains raw CSV, launcher log, usual runner artifacts, live `/proc`
mappings, executable SHA-256 before and after, hashes of mapped files and the
relevant HEART source files. Mapping capture is from descendants of this
specific harness process. Mapped-library hashes are taken after replay; no
concurrent deployment may occur if they are to identify loaded bytes exactly.
An executable hash does not by itself prove source/build equivalence; the
recorded source revision/status and baseline binary provenance remain relevant.

Public circular-buffer telemetry is useful for complete-frame values and
headers. It cannot by itself distinguish completed partial SH/MVM computation
from whole-frame work. Stable symbols `hrtWfsProcSH_singleSaGradCalc` and
`hrtVec_acc_ax_by` allow a more intrusive return-probe alternative. Existing
bounded progress instrumentation is the cheaper discriminating measurement.

## Event semantics and units

All event timestamps come from the same `CLOCK_MONOTONIC` clock in nanoseconds.
The terminal boundary is kind 1 `wfsReceive`, packet 32 of 32, stamped immediately
after `daoUdp_recv` returns. It is not NIC arrival time or kind3 `wfsFrameDone`.
SH and MVM observations must precede this timestamp strictly. Thus the claim
concerns work before the recorded final receive observation in the WFS handler.
The network may already have queued that datagram. A preemption between receive
return and its clock sample is not separately measured; the trace does not bound
that gap or establish precedence against the exact syscall-return instant.

| Event | What has completed at its timestamp |
| --- | --- |
| kind5 `wfsProcDone` | `aux` subaperture SH calculations; event follows `hrtWfsProcSH_grad`; `progress` counts detector rows, total 352 |
| kind7 `mvmAvailable` | `progress − aux` prior subaperture iterations; `aux` is a newly available batch whose computation has **not** yet happened |
| kind8 `mvmColumnDone` | Explicit completed iteration count; for 188 subapertures, the existing every900/end trace normally emits only at completion |
| kind10 `mvmComplete` | Full MVM routine has returned |

For the unpartitioned Classic SH reconstructor, each active subaperture invokes
one synchronous `hrtVec_acc_ax_by` over 277 padded actuator rows. It uses two
adjacent matrix columns, x then y. Therefore one completed subaperture iteration
is one x/y pair, two matrix columns and two slope values. The188 subapertures
correspond to 376 columns. These column units differ from 277 physical/padded
actuator rows and 221 controlled actuator coordinates. SH also computes flux;
its188-completed-subaperture count is not376 subapertures.

At each frame, the analyzer takes maxima over observations strictly before
final receive. MVM `progress − aux` is a **derived lower bound** on completed
arithmetic, conditional on all subapertures active and synchronous unpartitioned
reconstruction. More iterations may finish between the last event and final
receive. Newly available gradients alone do not count as completed MVM work.
No claim of exact intermediate call count follows.

## Required assumptions and validation

The Classic fixture's active mask is exactly 188 ones. The existing numerical
acceptance evaluator checks this and verifies all seven source images retain
positive flux margins above the deactivation threshold. The same images repeat
through the validated corpus. The generated YAML omits partition, streaming
MVM and flux-column options; `hrtConfig.c` defaults both partition counts,
`CONTROL_MAT_MVM_STREAMING_INPUT` and `INCL_FLUX_IN_RECON` to zero.
`hrtHoPipe.c` copies these values to reconstructor configuration. The
`numPartitions <= 1` scalar pair path therefore applies. This is progressive
input processing; “non-streaming MVM” here names the separate `hrtMvmSP` backend,
not the WFS arrival schedule.

`--all-subapertures-active` explicitly attests these reviewed assumptions.
Without it the analyzer reports traversed subapertures, and MVM arithmetic
counts remain null. It rejects loss/untraced-thread counters, incomplete or
unordered packet identities, ambiguous receive/stage synchronization, multiple
stage workers, unexpected dimensions, nonsequential MVM batches and explicit
streaming-input submissions. It retains producer bucket counters separately
from wire-frame identity and matches stages by shared sync identity.

Five synthetic tests cover correct old-batch completion, pair/column units,
unknown activity, exact timestamp exclusion, malformed synchronization/batches,
streaming input and trace loss. Exact wire and science acceptance remain the
runner's independent gates; these trace checks cannot replace them. Initial
controller qualification and physical application accuracy remain separate.

## Commands

Run only while the shared controller UDP ports are reserved for this diagnostic.
The helper pins its observer to CPU14 after spawning the campaign runner. Do not
restrict the entire launcher to CPU14: the runner validates that its requested
RTC/source CPUs are available.

```sh
env OPENBLAS_NUM_THREADS=1 python3 benchmark/run_classic_heart_trace.py \
  --output /home/dgamroth/.cache/rtc-classic-heart-readout63-r2-20260930

taskset -c 14 python3 benchmark/analyze_classic_heart_progress.py \
  /home/dgamroth/.cache/rtc-classic-heart-readout63-r2-20260930/heart-progress.csv \
  --frames 63 --all-subapertures-active \
  --output /home/dgamroth/.cache/rtc-classic-heart-readout63-r2-20260930/progress-summary.json

taskset -c 14 python3 -m unittest discover -s benchmark -p test_analyze_classic_heart_progress.py
```

## Results

Two successful sequential runs are retained at:

- `/home/dgamroth/.cache/rtc-classic-heart-readout63-r2-20260930`
- `/home/dgamroth/.cache/rtc-classic-heart-readout63-r3-20260930`

The original r1 attempt is also retained. It failed before HEART startup because
an outer CPU14 affinity restricted the harness's allowed CPU set. The helper now
pins only its observer after launch. The two successful launches occurred within
the TCP TIME_WAIT interval; both independently connected public telemetry and
shut down with all three recorded child processes returning 0. This supports the
specific immediate-relaunch functional check, not a long-run lifecycle claim.

| Measurement before final receive observation | r2 | r3 |
| --- | --- | --- |
| Frames with observed completed SH work | 63/63 | 63/63 |
| Frames with positive MVM arithmetic lower bound | 62/63 | 62/63 |
| Frame 0 SH lower bound, subapertures | 22 | 12 |
| Frame 0 MVM lower bound, x/y pairs | 0 | 0 |
| Frames 1–62 SH lower-bound range, subapertures | 166–184 | 126–184 |
| Frames 1–62 MVM lower-bound range, x/y pairs | 94–176 | 34–176 |
| Frames 1–62 MVM lower-bound range, matrix columns | 188–352 | 68–352 |
| Lost events / untraced threads | 0 / 0 | 0 / 0 |

The first frame's zero MVM bound means **overlap unproven in that frame**. It
cannot establish absence of overlap. Later positive bounds demonstrate actual
previous MVM pair computations, conditional on the reviewed activity/configuration
assumptions; they do not merely count input-ready announcements. Both traces map
wire frame 0 to sync1 and SH/MVM bucket0, then advance uniquely through all 63 frames.

Both runs independently pass exact WFS/DM delivery, arithmetic consistency and
the exact HEART wire model (17,451 float32 commands per run). The original strict
gate remains failed: 22 values per run, maximum absolute discrepancy
1.3113021850585938 ×10⁻⁶ µm. Clipping decisions agree (1,614 saturated values;
zero classification mismatches). The conservative minimum flux-threshold margin
is 2,323,706.8821629593, supporting all 188 active-subaperture arithmetic iterations.
Effective flags are verified; the runner's full `qualified` remains false because
independent initial-state readback is unavailable. Application accuracy remains
unassessed. These trace runs provide functional overlap evidence only.

Provenance:

- HEART revision: `6a5c06b11a8b934effeb6328a73a70895b2af94a`;
  generated/untracked source files are listed in each provenance JSON.
- Executable SHA-256 before and after both runs:
  `1c0862686dc79d127033845a12d32a0d12ac4ccc24a28396f69d0233b16ef9d1`.
- r2 raw trace SHA-256:
  `397cd197510cd87be45ed139f3ab8798332c2e6e9b2fade3bacc9260ae03d17b`.
- r3 raw trace SHA-256:
  `be8215cd77cc831b5766d556001ea6c3900cbdad4798fdb9a7868ed53e90ac93`.
- Analyzer SHA-256 used for both reports:
  `633a281059ed81eb703076ef25092520abc89e6fbed77ca8082ae7ffd0df2d99`.

HRT functions are linked into this executable: no separate HRT DSO appears in
`DT_NEEDED` or observed maps. The provenance records all seven mapped loader/system
DSOs and their SHA-256 hashes (loader, libc, libm, libnuma, libpthread, librt and
libz). It separately records the mapped mutable GMS shared-memory file; that
post-run hash is not a library-identity assertion. Raw progress CSV, packet
captures, source hashes, maps and the usual wire/numerical/command evidence remain
available in the evidence directories. Timing and capacity claims must use
separate uninstrumented trials.
