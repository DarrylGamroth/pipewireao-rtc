# Sustained HIL independent review

Review opened: 2026-10-04. Latest evidence review: 2026-10-05. Starting commit:
`1d3f1b5cadab0bb222390d90311b4094c30a40c3`; branch
`work/sustained-hil-20261004`; worktree `pipewireao-rtc-sustained-hil`.
The reviewed implementation is an uncommitted extension of that revision.
Existing implementation changes belonged to the primary agent. The initial
review changed only this document and launched no jobs. A separately authorized
follow-up added the SR-06 broker fault tests in
`deployment/julia/test/test_deploy.jl` and ran only that focused testset; it made
no production changes and launched no PipeWire, simulator or GPU workload.

The authority is RTC-ARCH-021 and RTC-DEV-024 through RTC-DEV-027 in
[architecture](architecture.md) and [operations](operations.md). The selected
work is described in the [sustained plan](SUSTAINED_HIL_PLAN.md). HEART and host
policy changes are outside this review's implementation scope.

## Evidence and conclusion

Observed evidence resides under
`/home/dgamroth/.cache/rtc-sustained-hil-20261004`, abbreviated `E` below.
Inspection covered the simulator, protocol, sustained recorder/metrics,
coordinator, exporter, source-status coordination and supervisor cleanup.
The review also inspected tests and existing test logs; their reported passes
are not a claim that the reviewer reran them. The later SR-06 test execution is
identified explicitly below.

### Latest disposition, 2026-10-05

The earlier observations below are preserved investigation checkpoints. This
section states the latest independently inspected result. The final pass
reviewed the current RTC production diff and new sustained modules, the
committed adapter cycle/wait changes and AOS synchronization change, coordinator
reset mode, focused tests, full test logs and primary lifecycle records. It
launched no tests or workloads and changed only this document. No new confirmed
implementation defect was found.

SR-01 through SR-09 and SR-11 through SR-13 retain their recorded dispositions.
SR-10's ordinary continuous and tested paced CUDA allocation defect is corrected
in all four observed Classic/Copper FGN/JFG compositions. SR-14's sequence-2
delivery failure is remediated by serialized native cycles with bounded failure
handling; all four continuous and stopped-reset production cases complete.
The selected sustained frame-loop increment is complete within the measured
CUDA configuration. Midrun administrative allocation removal remains deferred.
These statements do not turn the native activation mechanism into a proved
detailed root-cause account.

| Observed production evidence | Delivery per run | Measured exchanges per run | Heap/GC result | Lifecycle result |
| --- | --- | --- | --- | --- |
| Classic FGN v14 and JFG v15 | 8192 | 7936 | All byte/count/GC fields zero | Public shutdown and complete cleanup |
| Copper FGN v16 and JFG v17 | 4096 | 3840 | All byte/count/GC fields zero | Public shutdown and complete cleanup |
| Classic FGN diagnostic v18 | 8192 | 7936 | All fields zero, 62 sparse truth samples | Public shutdown and complete cleanup |
| Copper FGN diagnostic v19 | 4096 | 3840 | All fields zero, 30 sparse truth samples | Public shutdown and complete cleanup |
| Classic FGN stopped-reset v20, two runs | 8192 | 7936 | All fields zero in both runs | Exact repeated prefix hashes and sparse truth; public shutdown and complete cleanup |
| Copper FGN stopped-reset v21, two runs | 4096 | 3840 | All fields zero in both runs | Exact repeated prefix hashes and sparse truth; public shutdown and complete cleanup |
| Classic JFG stopped-reset v22, two runs | 8192 | 7936 | All fields zero in both runs | Exact repeated prefix hashes and sparse truth; public shutdown and complete cleanup |
| Copper JFG stopped-reset v23, two runs | 4096 | 3840 | All fields zero in both runs | Exact repeated prefix hashes and sparse truth; public shutdown and complete cleanup |

These rows were checked against their individual `*-evidence.lifecycle.json`
records, not only `E/zero-allocation-continuous-results.json` and
`E/zero-allocation-reset-results.json`.
The measured intervals exclude the retained 256-frame prefix and final report
serialization. Stopped reset and control/report work between completed runs are
outside those intervals. Midrun administrative operations remain included if
they occur inside an interval; the allocating `lifecycle` cohort has no new
zero-allocation qualification.

The four paced records in `E/zero-allocation-paced-results.json` were also
checked against their primary lifecycle records. Each delivers every requested
exchange, records all allocation/GC fields zero and confirms public shutdown
and complete cleanup. The rates below are observed completed-exchange rates,
not evidence of meeting every scheduled deadline:

| Paced case | Requested Hz | Observed Hz | Whole-run skipped wall periods | Measured exchanges over wall budget |
| --- | --- | --- | --- | --- |
| Classic FGN v24 | 250 | 247.3733 | 105 | 72 over 4 ms |
| Classic JFG v25 | 250 | 248.0848 | 83 | 58 over 4 ms |
| Copper FGN v26 | 100 | 99.9965 | 7 | 0 over 10 ms |
| Copper JFG v27 | 100 | 99.9707 | 10 | 1 over 10 ms |

Whole-run missed-period counts include the retained prefix, while the measured
exchange histogram excludes it. They count different events and populations;
for example, zero over-budget measured exchanges does not imply zero scheduler
misses. No deadline acceptance threshold, hard real-time result or maximum
isolated RTC rate is inferred.

The ordinary JFG graph replays of captured FGN prefixes in
`E/classic-captured-graph-replay-v28/graph-replay.json` and the corresponding
Copper v29 report measure all 256 public `process!` calls at zero bytes.
Maximum command differences are 2.5579538487363607e-13 m for Classic and
4.9533710466675984e-12 m for Copper. These are numerical characterization
results, not exact graph equality or an instrument-precision acceptance claim.
Copper explicitly permits and reports 11 differing reconstructor coefficients,
maximum difference 9.5367431640625e-7 and relative Frobenius difference
3.592309806978162e-11; no acceptance tolerance is introduced.

The new `reset` coordinator mode performs two uninterrupted runs separated by
completed stop/reset/restart, independently applies the strict allocation gate
to each, and compares retained frame/command hashes and sparse truth. It does
not replace the separate midrun pause/resume evidence. The gate now checks
measured count against requested total minus retained frames as well as a
typed metric count; its regression rejects internally matching truncated
counts. The previously reported interval-validation gap is closed. Completed
nonzero-allocation v6/v12 cases also provide actual evidence of preserved
reports, failed qualification and complete public cleanup after gate rejection.

Both isolated CUDA exception reports,
`E/cuda-wait-exception-prepared.json` and `E/cuda-wait-exception-ordinary.json`,
record a verified valid warm launch followed by the same `KernelException`
category and rendered detail on the deliberately out-of-bounds runtime launch.
Inspection of the public-API fixture confirms that these are runtime kernel
exceptions rather than failed compilation. This closes the proposed Julia
kernel-error propagation check; it is not exhaustive testing of every possible
CUDA driver fault. The AOS wait remains qualified for CUDA's tested default
nonblocking synchronization policy, with ordinary GC enabled.

The reviewed adapter commit is `13e4b653e554e5058ed768491b1a91d51d6432d0`;
the initial AOS repair is `ed9a3f3`. The narrow AOS change is now also committed
as `7f2b3aa95c429169b7b0fb83fc8faa958808aba2` on the newer main baseline in the
clean `AdaptiveOpticsSim-captured-wait-current` worktree. This later revision
does not replace the source identities of earlier acquisitions. The RTC HIL
project now requires PipeWireAO 0.6.14.
The earlier positive run packages were acquired with their recorded local
repairs and the explicit `/opt/pipewireao` native override. A later release does
not change those historical acquisition identities. The fresh registered
PipeWireAO result below closes the separate released-dependency gate; it does
not retroactively relabel earlier packages.

Inspected full logs report PipeWireAO 1520/1520, private-core transport 133/133,
adapter 1272/1272 and RTC SDK 1293/1293. Focused final logs report owner 56/56,
truth 98/98, metrics 99/99, sustained run 101/101, graph replay 123/123 and
coordinator 124/124. The adapter now includes a pending-cycle allocation test
whose producer cannot complete before its synthetic health check executes;
this improves the earlier immediate-completion-only fixture. End-to-end live
process counters cover the actual stream-health-check integration. The CUDA
prepared-wait test remains 7/7, including a pending kernel and the ten-second
refresh boundary. These software/native-loop tests and CUDA simulator runs
are distinct evidence classes; none is physical hardware or hard real-time
qualification.

### Final campaign checks, 2026-10-05

The independently inspected
`E/classic-fgn-released-v32-evidence.lifecycle.json` reports success, public
shutdown and complete cleanup. Its primary sustained report delivers all 8192
frames and commands; all allocation and GC fields are zero over 7936 measured
exchanges. The installed manifest resolves registry PipeWireAO 0.6.14 at tree
`134bc7cd9e7055f42d22e526ad7de01e65f4e440`, without a path or repository override,
and PipeWireAO_jll 1.7.0+19. Independent recomputation matches all 138 non-PWA
manifest-record hashes and all 15 protected science-file hashes in
`E/classic-fgn-released-v32-validation-baseline.json`. This is one fresh
released-dependency Classic FGN live case; the four-composition matrix retains
its original acquisition identities. The explicit native-library override
remains relevant, so registry resolution does not establish JLL-native execution.

Copper clipping records
`E/copper-fgn-clipping-v30a-evidence.lifecycle.json` and
`E/copper-jfg-clipping-v31a-evidence.lifecycle.json` each confirm two completed
256-frame reset batches, exact repeated ADC/command/truth evidence and public
shutdown. All four primary batch reports have matching requested/completed
frame and command counts, no failure and maximum command magnitude 0.01 µm.
The clipping graph sets rails to ±0.01 µm. The inherited report field
`command_limit_um=0.8` is not the stress rail; its at-limit count must not be
used as a clipping statistic. These finite cases do not establish sustained
allocation or paced cadence results.

The corresponding ordinary graph replays,
`E/copper-captured-clipping-fgn-replay-v34/graph-replay.json` and
`E/copper-captured-clipping-jfg-replay-v35/graph-replay.json`, each measure 256
warmed public `process!` calls at zero bytes. Both have nonzero controller
feedback on 254/256 frames and an informative feedback-zero counterfactual:
43,446 and 43,445 command components respectively differ from the normal replay.
Both maximum counterfactual command differences are approximately 0.02 µm.
The normal replay's maximum command difference from recorded output is
2.483568906086475e-12 m for FGN and zero for JFG. The counterfactual reuses fixed
recorded ADC inputs; it is a recurrence sensitivity check, not a live closed-loop
plant trajectory or a numerical acceptance threshold.

`E/copper-stream-captured-wire-v33.json` supplies the previously missing actual
UInt16-wire comparison. Across 256 frames, 218 of 1,048,576 pixels differ between
Stream and Captured execution, spanning 142 frames, with maximum difference two
ADC counts. The comparison preserves the declared plant, seeds, fixed model
period and command trace. Captured execution is not bit-identical to Stream;
these measurements do not establish an instrument-precision tolerance. The
record's reset check covers its stated reset observation, not equality of every
subsequent trajectory.

These final saved-evidence checks and the bounded source-diff review found no
new confirmed production defect requiring remediation before the selected
increment is merged. They launched no workloads or tests. Historical failed
packages, allocation profiles and acquisition hashes retain their original
meaning; later passes do not replace failed-run evidence.

### Earlier finite and lifecycle evidence

`E/classic-fgn-diagnostic-evidence.lifecycle.json` records two completed CUDA
Classic FGN runs of 8192 exchanges each, 16384 in total. Both retain 256-frame
prefixes and 62 sparse truth samples. Fresh status replies with source request
IDs 5 and 6 show paused sequence 3459 before resumption. The record reports
successful public shutdown. Frame/command prefix hashes and every sparse truth
record match across stopped reset. Maximum adopted command magnitude is
0.6306125897026504 µm, with no components at the command rail. These are
simulation observations, not a clipping-feedback stress test or cadence result.

Independent file inspection verified all 467 manifest entries in
`E/classic-fgn-diagnostic`, its descriptor hash against the lifecycle record,
and the preserved frame/command payload hashes for both runs. All 15 protected
`calibration/`, `graphs/` and `hil/plant.toml` artifacts match the fresh finite
source package. The installed manifest resolves PipeWireAO 0.6.13 and
PipeWireAO_jll 1.7.0+19. Runtime library maps show the intentional `/opt/pipewireao`
native override; package resolution alone does not establish that the JLL's
native artifact executed.

The sustained prefix frame/command hashes and per-frame truth records also
match the finite recording named by `E/classic-fgn-finite-analysis.json`.
That independent finite analysis records `verified=true`,
`live_truth_verified=true` and `adc_exact=true`. This supports transfer of the
same finite-prefix observation, not replay verification of all 8192 frames.

The inspected Classic FGN lifecycle record predates GPU-memory telemetry.
Its memory boundaries contain host process memory only. It records 52 periodic
samples and admitted, completed-1, reset and completed-2 boundaries. No GPU
memory result is inferred from the newer coordinator implementation.

The subsequent `E/classic-jfg-diagnostic-evidence.lifecycle.json` was inspected
for completion and lifecycle fields: it records two successful 8192-exchange
runs, held sequence 3682, no source failure and confirmed public shutdown.
This follow-up inspection did not repeat the full FGN manifest/payload audit
for that JFG package.

The final source review inspected the completed finite analysis and diagnostic
lifecycle records for all four Classic/Copper FGN/JFG cases. All four finite
analyses record exact ADC agreement, verified live truth and verified correction
replay. Each Classic diagnostic case completed two 8192-exchange runs; each
Copper case completed two 4096-exchange runs. Each pair reports successful public
shutdown and exactly matching sparse truth after stopped reset. The Copper
records include four NVIDIA boundary samples per case, each 1033895936 bytes
(986 MiB). Copper JFG's Julia-owner RSS is 703844352 bytes at all four boundaries.
These observations show stable boundary values, not a bound on unobserved peaks.

For Copper samples with global sequence at least 2048, the ratio of summed pupil
variance to summed atmosphere variance is 0.6963171256782833 for FGN and
0.6963169809502475 for JFG. This is an observed sparse, late-run diagnostic;
neither pair of sparse samples replays all intervening exchanges.

## Findings and disposition

### SR-01 — Unpaced wall-period reporting

- Severity: medium. Confidence: high. Evidence: source inspection.
- The initial metrics substituted model period for an absent wall schedule.
- Disposition: corrected in `deployment/hil/sustained_metrics.jl`. Zero remains
  zero; comparisons explicitly use the model-period budget in unpaced mode.
- Validation: the inspected metrics log includes nine passing assertions for
  absent wall scheduling. Preserve this distinction in derived rate tables.

### SR-02 — Prefix scheduler misses included the sustained tail

- Severity: medium. Confidence: high. Evidence: source inspection.
- Disposition: corrected. The simulator increments separate whole-run and
  retained-prefix missed-period counters. Version-1 timing and counts describe
  only its retained prefix.
- Validation: the inspected `E/sr02-sustained-run-tests.log` records 11 passing
  synthetic-owner scheduler assertions distinguishing prefix and tail misses.
  This closes the accounting regression; actual paced cadence remains separate.

### SR-03 — Driver identity check ended at retention boundary

- Severity: medium. Confidence: high. Evidence: source inspection.
- Disposition: corrected. `run_owner` checks post-exchange model-driver sequence
  on every exchange before sustained metrics advance.
- Validation: metric tests cover malformed sequence/model timing after frame
  256. These tests do not independently exercise a corrupted live driver.

### SR-04 — Hard-coded detector rail

- Severity: medium. Confidence: high. Evidence: source inspection.
- Disposition: corrected. Sustained preparation reads installed detector bits,
  admits integer bits 1 through 16, and derives the UInt16 rail.
- Required validation: preserve the existing CPU and selected GPU detector
  contracts; do not infer a new detector-model acceptance from generic encoding.

### SR-05 — Copied-package pacing provenance remains contradictory

- Severity: medium. Confidence: high. Evidence: observed sealed artifact.
- The maintained exporter now records resolved wall rate separately from model
  rate. The earlier `E/prepare_sustained.jl` copied a finite package and changed
  owner arguments without updating `provenance.hil`.
  The historical Classic diagnostic packages therefore still declare
  `hil.wall_rate_hz=500`, while its owner arguments and measured summary declare
  unpaced operation (`wall_rate_hz=0`).
- Disposition: corrected for future preparation; historical limitation retained.
  Preserve the already measured sealed packages; explicitly identify the inherited
  field as stale and use the bound owner arguments and run report for this run.
- Validation: the current copied-package preparation records effective pacing,
  and both inspected Copper diagnostic packages declare model rate 500 Hz,
  unpaced wall rate zero and total 4096 consistently with their run reports.
  `E/sustained-export-tests.log` records 55 passing assertions for exporter
  effective pacing provenance. Keep source provenance distinct and do not
  rewrite measured packages merely to make metadata agree.

### SR-06 — Held-state evidence read a static report twice

- Severity: medium. Confidence: high. Evidence: source and recorded replies.
- Disposition: corrected. The coordinator obtains two newly acknowledged public
  status replies with source state and sequence. The inspected FGN record shows
  distinct source request IDs and the same paused sequence.
- `coordinate` is reached through the source-owner broker; native-only sessions
  retain their native socket path. A source-status timeout sets source failure,
  propagates through `serve_control`, and reaches supervisor cleanup. Cleanup
  revokes source/core ingress before consumer cleanup when pause is unconfirmed.
- Validation: the reviewer added and ran the focused Julia testset
  `Public source status failures revoke ingress and clean owned groups`:
  **40/40 assertions passed in 15.2 seconds**. A malformed acknowledgement and
  an absent acknowledgement traverse the actual public broker. The missing
  case uses the production eight-second acknowledgement timeout. Tests observe
  the public `control.outcome` error, persisted failed/non-admitted state,
  `source_failed`, and one source request without retry. Detached fake owners
  and a source descendant are removed; the native consumer fixture verifies
  source/core ingress and descendants are gone before its cleanup status/quit.
  Both cases use the supervisor's real cleanup entrypoint. This closes the
  focused software validation obligation, not physical endpoint validation.

### SR-07 — Memory sampling stopped after the first 64 observations

- Severity: medium. Confidence: high. Evidence: source inspection.
- Disposition: corrected by rolling retention, total sample count and explicit
  lifecycle boundary snapshots. The inspected successful run has all four host
  boundaries. Newly added NVIDIA telemetry is boundary-only and labels retained
  pools; it was not present in that run.
- Validation: `E/coordinator-final-tests.log` records eight passing ring-buffer
  assertions covering empty/partial/full retention, repeated wraparound, bounded
  capacity and chronological order. Explicit boundary snapshots remain separate
  from ring eviction. GPU snapshots establish boundary observations, not peaks.

### SR-08 — Completion publication preceded its prefix report

- Severity: medium. Confidence: high. Evidence: source inspection.
- Disposition: corrected. The simulator writes payloads and prefix report before
  publishing the companion completed summary. The coordinator checks the summary
  before preserving the prefix. This fixes the initial completion-read race.
- Validation: `E/sr08-simulator-tests.log` records 127 passing observer assertions
  for fresh prefix visibility before companion publication, alongside the
  existing count/extent/failure-report assertions. Initial sustained success and
  failure serialization are now warmed before the prepared event.

### SR-09 — Emergency launcher kill can preempt owned-group cleanup

- Severity: high. Confidence: high for the timing mismatch; descendant leakage
  is a derived risk, not an observed failure in the successful FGN run.
- Evidence: the earlier `deployment/qualify_sustained.jl` sent SIGINT after failed
  public shutdown, then SIGKILL after only 15 seconds. Owners are detached
  process groups. A single supervisor `_owned_wait(..., 8)` permits 8 seconds
  graceful wait plus 5 seconds each for TERM and KILL; multiple owners are
  processed serially. Killing only the supervisor can interrupt its cleanup
  before those detached groups are revoked/reaped.
- Disposition: corrected and independently inspected. The coordinator first
  permits 300 seconds for supervisor cleanup already in progress, then permits
  another 300 seconds after SIGINT before a last-resort launcher SIGKILL. Only
  the owned launcher handle is signalled. Detached groups are observed using
  initially confirmed parent/group/session/start-time identities. Unknown,
  changed or surviving groups cannot produce a successful qualification.
- Validation: the inspected coordinator log records 73 passing cleanup
  assertions, using lightweight fake owners and descendants. Cases cover cleanup
  already underway, delayed cleanup after interruption and ignored interruption.
  The final case deliberately leaves groups alive, reports unresolved cleanup
  and preserves failure; the test's separate owned cleanup then reaps them.
  A failed public shutdown never becomes a passing gate even if fallback cleanup
  completes. This closes the premature-kill/false-success defect; it does not
  guarantee recovery from an unresponsive supervisor or unkillable OS process.

### SR-10 — Simulator does not meet the subsequently required zero-allocation budget

- Severity: high against the newly explicit performance requirement. Confidence:
  high for nonzero totals and identified allocating operations; attribution of
  each measured byte or timing outlier remains unproven.
- Observed: `classic-fgn-capacity-repeat-evidence.lifecycle.json` reports
  338005664 allocated bytes across 7936 measured exchanges (42591.44 bytes per
  exchange); `classic-fgn-paced-evidence.lifecycle.json` reports 1257335152
  bytes (158434.37 per exchange). Copper capacity reports 156599472 bytes across
  3840 measured exchanges and 323081008 ns of process GC time. These are the
  declared whole-simulator-process intervals, not RTC callback measurements.
- Confirmed source mechanisms: after admission, the owner reopens and reads up
  to 16385 bytes of the same control-request file and constructs a new String
  on every owner-loop iteration. Its equality check avoids repeated JSON parsing
  of unchanged requests, but does not avoid their read/allocation. Paced idle
  iterations repeat this work. Julia 1.12.7's `isfile` uses `stat`, whose source
  allocates a `Memory{UInt8}` buffer. `sleep(sec)` calls `wait(Timer(sec))`.
  The frozen adapter's `_wait_for_sequence` and the owner pacing path therefore
  construct timers repeatedly. The adapter's existing calibration completion
  helper also constructs a callback Timer per wait and is not an allocation-free
  replacement.
- Latest disposition: corrected for the four continuous, stopped-reset and
  tested paced CUDA compositions and observed FGN diagnostic cohorts in the
  2026-10-05 table. Remaining
  campaign gates are listed below. The historical failed measurements and
  remediation checkpoints here are retained; callback replay allocations alone
  never established this simulator result.
- Smallest measurable plan: retain exact installed sources, warm and measure
  owner marker/control polling, wall-idle policy, direct plant step/adoption,
  adapter exchange, and recording separately through concrete function barriers;
  also retain the whole-process interval as the acceptance measurement. Attribute
  remaining bytes with a short allocation profile outside cadence qualification.
  Remove one confirmed mechanism at a time and repeat the same measurements.
- Candidate wait experiment: public `yield()` plus periodic `GC.safepoint()`
  avoids constructing per-poll Timers. Preserve the exact atomic sequence checks,
  monotonic timeout, stream-error checks and the existing public thread-loop
  lock. Keep retry `trigger_process!` on its existing approximately millisecond
  schedule while polling completion promptly; triggering on every busy poll
  changes load and behavior. This candidate needs measured allocation and CPU
  results and is not yet an approved zero-allocation implementation.
- Control-path design obligation: event-driven directory notification with a
  bounded prepared mailbox can remove unchanged-file work from ordinary loops.
  Preserve atomic-renamed control files, exact IDs, request-size limits,
  serialized pause/reset and failure handling. A periodic background poller in
  the same process would merely move allocations within the measured scope.
  Parsing an actually new administrative request remains separate work that must
  be reported honestly; no timer/poller allocation may be hidden from the ordinary
  steady-state simulator interval.
- GC/progress obligation: a nonallocating spin must reach `GC.safepoint()` so
  native callback threads requesting GC can proceed. A safepoint does not yield
  to other Julia tasks; a same-thread event watcher needs scheduler progress too.
  Released PipeWireAO 0.6.13 already uses a GC-safe native thread-loop lock.
  Preserve that wrapper; do not replace it with raw pointers, private native
  locks, machine instructions or weaker atomic access.
- Required validation: zero ordinary steady-state whole-process bytes after
  measured warmup, unchanged exact sequence/model chronology and seed/controller
  state, delayed completion, timeout/disconnect/invalid-sequence failures,
  pause/reset controls, and progress when another participating thread requests
  GC. Recheck wall misses, CPU occupancy, GPU staging and latency distributions
  on the established placement. No CPU0/1 migration or host tuning is selected.

#### SR-10 remediation checkpoint

The newest source consumes each control request before publishing its matching
acknowledgement. Under the broker's one-outstanding-request contract, this is
the correct order: the broker cannot publish the next request until after the
old pathname has been removed. Unchanged control content is no longer reread.
The public `ispath` quiet marker check and `yield()`/`GC.safepoint()` pacing
have focused zero-allocation assertions; this supersedes the earlier candidate
event-watcher proposal and does not require a new mailbox architecture.
Actual request parsing, report generation and acknowledgements remain cold
allocating operations. Those bytes must remain visible whenever a measured
whole-process interval includes administrative operations.

The revised truth witness allocates three SHA contexts per retained frame and
a reusable canonical row-major little-endian byte workspace before admission.
Recording updates each fresh context once; the report finalizes and caches
strings. All three input shapes, finite products, chronology and variances are
validated before context updates. The inspected tests exercise signed zero,
subnormals, finite extremes, repeated reports, report-then-resume, reset,
rejected shape/nonfinite inputs and successful recording into the previously
rejected slot. For the prepared owned Matrix buffers, no hash-semantic or
rejected-input context-mutation defect was found. Sparse later truth staging
does not overwrite the already updated prefix contexts.

The adapter remediation is in the separate worktree
`/home/dgamroth/workspaces/codex/AdaptiveOpticsSimPipeWireHIL-zero-alloc`, based
on `39efcf5`. It gives prepared context/core/stream fields concrete type
parameters and precompiles exact callback signatures before admission. It
replaces timer polling with safepoint/yield calls, while retaining stream health
checks and explicit retry triggering. No atomic or native-lock contract is
weakened. The simulator additionally precompiles exact public exchange,
recording, truth and metric signatures before starting the streams and publishing
the connected acknowledgement. This compiles methods without executing a
transported frame or advancing model/controller state. It is appropriate for
held admission, but does not prove that every first-call allocation has been
eliminated. The final focused adapter log contains 33 passing assertions,
including the sequence-loop and retry cases described below.

`E/classic-allocation-components-before-v2.json` provides new measured evidence:
all 32 warmed optical step/stage/adoption samples allocate 14896 bytes; transport
encoding/staging samples allocate zero. Profile stacks identify CUDA kernel
launch bookkeeping on the optical path. The experiment excludes live transport
and owner polling.

The current simulator selects `CapturedGraphExecution()` for accelerator targets
and `StreamGraphExecution()` for host targets, and reports the actual
`graph_execution` type. Inspection confirms that the same loaded graph,
parameters, buffers, model period and warm/reset operations are supplied to the
public graph preparation API. This is an execution-policy change; it does not
establish bitwise scientific equivalence. The inspected experiments use CUDA;
they provide no additional AMDGPU qualification. The independent analyzer loads
the hash-checked installed simulator, so historical Stream packages retain their
own execution behavior instead of silently using the latest source default.

`E/classic-execution-policy-comparison-reset.json` records 256 optical steps
with the same noisy graph, seeds, 2 ms model steps and adopted command trace.
Stream allocates 14896 bytes on each measured step; captured allocates zero on
all 256. Nineteen detector values differ across 31719424 values, with maximum
difference 1. Atmosphere and pupil OPD differences reach
2.2737367544323206e-13 m; the compared PDM surface values are exact.
`E/copper-execution-policy-comparison.json` records 12688 Stream bytes per step;
captured has one 64-byte sample and 255 zero-byte samples. It records 223
differing Float32 detector values, maximum difference 1.0244140625, OPD maximum
difference 3.410605131648481e-13 m and exact compared PDM surface values. This
Copper comparison does not measure the difference after UInt16 transport encoding.

The inspected comparison script replays fixed measured commands into both plants;
it does not let each changed detector trajectory drive a separate RTC controller.
Its `reset_exact` flags compare only the first detector frame after reset, not
the complete 256-frame trajectory or all optical state. Both flags are true for
each profile. These results characterize execution differences and support a
fresh closed-loop experiment; they do not supply an accepted numerical tolerance
or an instrument-precision claim.

The separate `E/copper-captured-allocation-components.json` records zero bytes
for all 512 optical units and all 512 UInt16 staging samples, plus an empty
reported optical allocation profile. Its declared scope is warmed graph steps,
host staging and zero-command adoption, excluding live transport and owner
polling. It does not explain the earlier isolated 64-byte sample or close SR-10.
Fresh packages still require exact within-policy replay/reset evidence,
numerical qualification of the changed closed-loop trajectory and the declared
whole-process zero-byte/zero-GC acceptance interval.

#### SR-10 owner specialization and native-lock checkpoint

`E/classic-fgn-allocation-fixed-evidence.lifecycle.json` records a remaining
failure of the allocation contract after captured execution and quiet polling:
34536208 allocated bytes over 7936 measured exchanges, one GC pause and
37880275 ns of GC time. This actual process result supersedes any inference
from the zero-byte optical and polling component tests.

The inspected `E/classic-live-allocation-profile.json` contains 207 allocation
records totalling 32912 bytes in the short live profile. Of these, 28288 bytes
are boxed `PreparedGraphHILBoundary` values and 768 bytes are boxed
`FixedStepModelTimeDriver` values obtained through `getproperty` in the owner.
It also identifies 640 bytes of `Box` and 640 bytes of `Ptr` allocations in
`with_thread_loop_lock`. These are observed allocation sites; this profile is
not itself a measurement of the full sustained interval.

The revised simulator crosses a function barrier once after public
`prepare_pipewire_hil`: `run_prepared_owner!` receives the concrete prepared
science, recorder, protocol state, sustained recorder, transport and wall
period. The reset/report closures and existing frame loop move together into
that function. Exact exchange warming, stream start and the connected ACK stay
inside its `try`; exceptions still set the failure report, close transport in
`finally`, and write the final report even when close throws. Inspection found
no changed exchange order, buffer ownership or newly admitted preparation frame.
Preparation still uses the public graph and HIL APIs. The only other simulator
change between the two frozen packages selects the same three truth outputs
through their existing `Val` API. All 15 protected calibration, graph and plant
artifacts compare byte-for-byte equal between `classic-fgn-allocation-fixed`
and `classic-fgn-allocation-fixed-v2`.

The additional PipeWireAO patch lives in the separate
`/home/dgamroth/workspaces/codex/pipewire/PipeWireAO-simulator-alloc` worktree,
based on `6d5a5f1e9722d5257d821b58d0f98728b8ed8d41`. Its production diff only
renames the inner `handle` binding to `native_handle` in
`with_thread_loop_lock`. The closure returns that same native handle into the
outer binding; no later closure observation or mutation of the outer binding
is required. State-lock reservation, `native_access_count`, native
`gc_safe=true` acquisition, `finally` unlock/decrement and close's exclusion
while reserved are unchanged. No public interface or pointer operation is added.

The inspected `E/thread-loop-allocations-before.log` records 32000 bytes for
1000 warmed real native-loop lock calls and five other passing assertions.
`E/thread-loop-allocations-after.log` records all six assertions passing,
including zero bytes, callback argument identity, throwing-callback cleanup,
subsequent lock acquisition, zero access count and successful close. These are
native-loop software tests, not a contended callback/GC stress qualification.
No new confirmed correctness defect was found in this narrow patch or the
owner barrier. The new live package uses locally modified PipeWireAO sources;
it must not be described as an unchanged released PipeWireAO 0.6.13 run. The
`allocation-fixed-v2` whole-process result remains unqualified at this review
checkpoint, and SR-10 stays open.

#### SR-10 closure specialization, stream state and acceptance gate

The later completed run is preserved under the distinct shorter name
`E/classic-fgn-alloc-v2-evidence/run-1/sustained-result.json`. It records 8192
completed exchanges and 31243136 allocated bytes over the 7936 measured
exchanges, with zero GC pauses/time. The longer-named
`classic-fgn-allocation-fixed-v2` attempt failed before admission and has no
run-1 evidence; it is not the source of this completed allocation measurement.
Zero GC alone therefore does not close the allocation requirement.

`E/classic-live-allocation-profile-v3.json` contains 55 records: seven captured
reset-closure allocations totalling 26152 bytes and 48 `RefValue` allocations
totalling 768 bytes. The owner now explicitly specializes both `Reset` and
`Report` callable types in `consume_control_request!`. Its body, request
consumption ordering and control semantics are unchanged. The new regression
captures a 512-element immutable tuple in the reset closure and polls 64 times
with no request. `E/owner-capture-before.log` records 266240 bytes; the same
assertion passes at zero in `E/owner-capture-after.log`, which records all 56
owner assertions passing. The measured loop includes closure argument passing;
the test does not assert that cold control invocation or report serialization
allocates zero.

The sibling PipeWireAO `stream_state` change constructs its native error-output
`Ref` inside the existing state-lock closure and handles the returned state and
error there. Callback-error checking still precedes that lock. The regular
state return is unchanged; closed-handle validation remains inside the lock.
On native error, the error string is now copied while the same state lock
prevents concurrent wrapper close or `set_error!` from invalidating that native
storage. Exception unwinding still releases the Julia lock. This does not add
native synchronization or replace the caller's existing thread-loop locking
obligation. No new lifetime, lock-order or ownership defect was found.

`E/stream-state-before.log` records 16000 bytes for 1000 state queries.
`E/native-lock-and-stream-after.log` records zero-byte query assertions and all
eight stream-state assertions passing, including the native error code/detail
and closed-stream rejection; all six native thread-loop lock assertions also
pass. The before fixture had four assertions and the final fixture adds native
error checks, so only the allocation assertion is the identical before/after
oracle. Neither fixture is a concurrent state-change stress test.

The coordinator's new `require_allocation_free` requires positive measured
exchanges and integer zero values for allocated bytes, GC time/pauses/sweeps and
pool/big/malloc/realloc counts, rejecting absent or malformed evidence. It runs
after payload/report preservation and assignment of the completed run into the
lifecycle record. Rejection enters the existing exception/finally cleanup and
retains the unsuccessful result. `E/allocation-gate-tests.log` records 32 gate
assertions, eight ring assertions and 73 cleanup assertions passing. The gate
is unconditional, including lifecycle mode: pause/status/report allocations
inside the declared interval must cause failure, rather than be hidden by a
functional lifecycle success.

Validation gap for primary-agent adjudication: the new gate equates allocation
exchange count with `metrics.measured_count`, but does not independently compare
both with total exchanges minus retained frames. Its unit tests do not include
an internally matching but truncated interval, nor exercise preservation and
cleanup through a gate failure in `main`. Current producer source increments
the measured count after the retained prefix; no actual count error or lost
failure evidence is asserted. These are acceptance-validator coverage gaps,
not demonstrated scientific or delivery failures. The current `alloc-v4` live
case has not been qualified by this inspection; SR-10 remains open.

### SR-11 — Control request open can block before regular-file validation

- Severity: high. Confidence: high. Evidence: source behavior and inspected
  fail-before/pass-after logs; no fault run was launched by this review pass.
- The first remediation of `consume_control_request!` checked `ispath`, called
  ordinary `open`, and only then checked `isfile(stat(io))`. A FIFO satisfies
  `ispath` and its read open can
  block indefinitely waiting for a writer before regular-file validation runs.
  The previous outer `isfile` check did not enter that open for a FIFO.
- Disposition: corrected. The opened descriptor now uses public read-only,
  nonblocking and no-follow flags, validates its regular-file status before
  reading the bounded payload, and closes in `finally`. Consume-before-ACK
  ordering is preserved.
- Validation: `E/owner-loop-invalid-files-before.log` records seven failures
  among eight fault assertions, including the bounded child timing out on the
  FIFO. `E/owner-loop-tests.log` records all 55 assertions passing; the same eight
  fault assertions complete in 0.8 s. The tests preserve the outside symlink
  target, verify unchanged request ID and absent false ACK, and exercise actual
  FIFO open in a child with a 15 s bound. Ordinary requests, next-request
  publication, stale/malformed requests, pause and reset remain covered.

### SR-12 — Double atomic observation can reject a matching command

- Severity: high. Confidence: high. Evidence: source-level interleaving.
- The previous adapter `_wait_for_sequence` read the atomic sequence in the `while`
  condition and again into `observed`. If completion occurs between these loads,
  the first sees zero and the second sees the expected command. With
  `allow_prior=false`, the rejection condition then throws for the matching
  value: "expected N, received N". This race predates the allocation patch.
- Disposition: corrected. `_sequence_complete` reads the atomic once, accepts
  that matching observation immediately, and only then rejects disallowed
  prior/future values. The loop uses that helper without a second sequence read.
  Existing atomic publication and one outstanding exchange are preserved.
- Validation: `E/adapter-wait-final-tests.log` records seven passing sequence
  assertions covering zero, permitted/rejected prior, equal and future values.
  The nine bounded-wait assertions additionally cover completion, timeout,
  allowed prior, future rejection and propagation of a retry failure. Source
  inspection establishes removal of the two-read interleaving; these tests are
  not a forced native callback race or a live disconnect test. No live incidence
  of the original race is asserted.

### SR-13 — Retry deadline is computed before potentially blocking work

- Severity: medium. Confidence: high. Evidence: source-level timing derivation.
- The first revised sequence wait computed `now` before acquiring the thread-loop
  lock, checking streams and triggering, then set `retry_at=now+1 ms`. If that
  work blocks longer than a millisecond, the deadline is already past immediately
  after triggering; the following yield can be followed by another immediate
  trigger. The previous sleep occurred after the work and preserved separation.
- Disposition: corrected. The next retry is now `time_ns() + 1 ms` after the
  protected check/trigger returns. Completion remains checked on every yielded
  pass, with the existing timeout/error behavior. No observed live burst is claimed.
- Validation: the nine bounded-wait assertions in
  `E/adapter-wait-final-tests.log` include a first retry that spends 3 ms in
  simulated work and verify that the second trigger occurs at least 1 ms after
  the first trigger timestamp. They also measure zero allocations in the exact
  wait helper. Three further assertions cover zero-byte yielding and Julia-task
  progress; 14 cover existing timing observations. These unit results do not
  measure live native lock contention or whole-process GC progress.

### SR-14 — Repeated command-sequence-2 failure after allocation changes

- Severity: high. Confidence: high for the observed failure. Latest disposition:
  remediated by serialized native cycles, with all four continuous production
  cases and all four reset cases passing. Detailed native activation causality remains
  unestablished; later campaign gates do not erase the reproduced failures below.
- Observed: both `E/classic-fgn-alloc-v4-evidence.deployment.log` and the matching
  v5 log show held connection followed by
  `correction_command.sequence: sequence 2 did not complete before the development timeout`.
  The RTC's required-source-disappeared message follows that failure. Both
  lifecycle records report unsuccessful public shutdown, complete final owned
  process cleanup, and `/proc/<rtc-pid>/status` ENOENT as the coordinator failure.
  The observer exception therefore obscures the earlier source failure in that
  summary field; it is not evidence that the RTC exited before the source timeout.
  Neither run reaches the measured post-prefix allocation interval.
- Derived: `_exchange_frame!` waits for `frame_published == sequence` before
  entering the command wait. Reaching this particular sequence-2 timeout implies
  that frame 2 was published. The timeout is not a failure to connect, prepare
  the optical frame or publish frame 2. A permanent native/state-lock deadlock is
  less consistent with reaching the timed exception, since timeout checking is
  after the retry operation; transient blocking is still possible.
- Source review: the new ordinary `stream_state` path retains the same callback
  error check, Julia state-lock acquisition and native query. The `Ref` remains
  alive through its native call; its output is read before returning. Error
  string copying stays protected by the state lock. The owner change only
  specializes callable types and does not invoke reset on absent requests.
  The wait loop still reaches `GC.safepoint()` and `yield()` and the native-loop
  lock remains GC-safe. No source evidence currently establishes invalid `Ref`
  lifetime, new lock-order inversion or unintended scientific reset.
- Hypotheses: removing allocations or changing specialization can alter when
  the owner reaches triggers and native callbacks, exposing an existing
  readiness/buffer scheduling race. A cold specialization delay could also
  change the first-to-second exchange gap. These are timing hypotheses, not
  demonstrated causes; the unit zero-byte tests cannot discriminate them.
- Proposed discriminator: revert only the stream-state change in a fresh
  package while retaining the thread-loop binding fix and callable
  specialization, as selected by the primary agent. A completed run would show
  dependence on that change or its timing, not prove a defective native query.
  A repeated original/revert pair, or a second factor that reverts only callable
  specialization if the first revert still fails, can narrow the dependency.
  Keep the declared scientific graph, seeds, calibration and wall policy fixed.
- If needed, the smallest additional timeout evidence is the four exchange
  sequence markers, retry count, frame/command callback counts and successful
  dequeue counts, recorded in bounded prepared storage and serialized after
  failure. Frame publication with no command callback differs from command
  callbacks receiving no buffer. Public stream states, driving state and
  callback errors can further separate these cases. Do not change safepoint,
  native locking or scientific parameters before that evidence selects a cause.

#### SR-14 trigger and completion evidence checkpoint

The stream-state-only revert in
`E/classic-fgn-alloc-v6-evidence.lifecycle.json` completed the exchange run,
preserved evidence and confirmed public shutdown. The stricter gate correctly
rejected 769440 bytes and 48090 pool allocations over 7936 measured exchanges,
with no big allocations or GC. This establishes a behavioral dependence on the
changed query or its timing in that run; it does not isolate a native-query
semantic defect. The alternative v7 implementation uses a per-Stream
`RefValue{Cstring}`, initialized with the stream and queried under its existing
state lock. The returned native error detail is copied under that same lock.
Inspection found no new unrooted reference or shared-query race, and this heap
reference variant still fails command sequence 2. A stack-only output-reference
failure is therefore not established by these experiments.

`E/callback-probe-v9.json` records ready/published frame sequence 2, command-ready
zero and completed timing sequence 1, with both streams in state 3 and the frame
stream driving. Its bounded counters show 4946 frame callbacks but only two
eligible frames, two successful frame dequeues and two queued frames; there is
only one command callback, dequeue, copy and queue completion. The 4954 retry
checks do not establish 4954 successful trigger calls. The paired public native
status reports a running RTC, three owned links, two owned nodes and zero
discarded buffers at failure. The observed loss is therefore beyond queuing the
second source frame and before a second command callback, rather than a second
command callback rejecting a buffer.

The inspected `E/callback-probe-v10.json` adds 4947 public trigger-done events,
alongside 4946 frame callbacks and the same single command callback. Native
cycle completion events continue during the failed exchange. Its pre-exchange-2
snapshot has 12 frame callbacks and 11 trigger-done events; these are different
event counters, not proof of a one-to-one issue/completion mapping or the exact
native cycle state when frame 2 was armed.

Public `src/pipewire/stream.h` in the inspected native source documents that a
driving trigger schedules a graph iteration and successful completion emits
`trigger_done`. It explicitly permits an iteration not to finish, requiring a
bounded retry policy for progress. Consequently, an unconditional requirement
that every issued trigger eventually contributes one completion is invalid
after an incomplete cycle. The callback carries no model sequence or trigger ID.
With current DRIVER/no-TRIGGER flags, `pw_stream_trigger_process` sets
`using_trigger` and dispatches `do_trigger_driver`; `impl_node_process_output`
emits done at driver end. `PW_STREAM_FLAG_TRIGGER` selects a different native
scheduling path and adds a trigger dependency. It is not needed merely to
receive done notifications. Non-RT process callbacks select async nodes, so
native cycle completion must not substitute for exact command receipt.

The inspected `impl-node.c` readiness path can recover an unfinished driver
cycle and reset target activations when retriggered. This supports investigating
overlapping driver iterations; it does not prove that this path caused the lost
command. A cheap discriminating experiment is to allow one normal driver cycle
at a time, wait for its completion before retrying or arming the next model
frame, and retain a bounded failure if completion never arrives. Keep command
receipt as a separate necessary condition. A timeout recovery that retriggers
while an earlier untagged done event can still arrive needs an explicit recovery
policy; simple issued/completed arithmetic cannot establish event identity.
The public documentation's suggested multiple of the quantum refers to the
actual native graph quantum/rate, not automatically the 2 ms model step.

Publishing `command_ready` before returning the borrowed command buffer is not
yet established as an ownership defect: command data have already been copied,
and the next trigger/reset acquires the native thread-loop lock, serializing
against completion of the previous non-RT callback and its buffer return. Moving
publication later can strengthen its meaning, but the current evidence does not
justify describing that move as the root-cause fix. SR-14 remains open.

#### SR-14 successful cycle-gate experiment and production obligations

The inspected `E/classic-fgn-cycle-v11-evidence.lifecycle.json` records success,
512 completed frames and commands, 256 retained frames and a 256-exchange
measured interval with zero allocated bytes, zero pool/big/malloc/realloc
counts and zero GC pauses/time/sweeps. Public shutdown is confirmed and final
owned cleanup is complete. These are delivery and allocation observations for
this one experiment, not an independent claim of exact ADC or optical replay.
The failed v10 already had the completion callback; v11 additionally waits for
normal cycle completion before another trigger, before arming the next frame
and after command receipt before adoption. It fails within the existing bounded
timeout when a pending cycle does not complete and does not replace that cycle
with an ambiguous recovery trigger. This discriminates cycle ordering from
the earlier callback-presence change, while still leaving detailed native
activation causality unproven.

The exact installed experimental adapter uses global atomic/reference state.
It is evidence, not the proposed production ownership design. The proposed
`DriverCycle` belongs to one prepared HIL owner: a completion callback writes
only its atomic completion counter, while the serialized owner writes its epoch
and pending flag. Preparation initializes the counter and precompiles the exact
completion callback. The issue helper must snapshot the counter and mark pending
before invoking the trigger under the native-loop lock; it must not issue a
second cycle while that snapshot is unchanged. The completion wait must yield
with a GC safepoint without retaining the native lock needed by the callback.
Command identity and native completion remain separate required observations.

Timeout or trigger error must leave the unresolved cycle visible and fail the
exchange; silently clearing pending would authorize replacement. Reset must
check quiescence before changing model/transport state and must not reset the
completion counter while an event can remain outstanding. A monotonic counter
can be retained across quiescent reset and snapshotted for the next issue.
Cleanup must still stop/close resources after a pending-cycle failure; a
quiescence check must not prevent teardown. Stream-health errors should retain
bounded propagation while waiting for completion.

Required focused validation includes independent owner state, an old completion
not satisfying a new issue, completion during the trigger call, suppression of
reissue while pending, one subsequent issue after completion, trigger exceptions,
timeout retaining pending state, reset rejection without partial mutation, and
resource cleanup after timeout. Measure the concrete helpers and callback after
warming. Full production acceptance still requires the fresh Classic/Copper
FGN/JFG sustained cases, lifecycle/reset evidence and exact scientific replay
within the selected execution policy. SR-10 and SR-14 are not closed by v11.

Returning PipeWireAO's query to the smaller temporary-Ref-under-lock change can
remove the experimental per-Stream scratch field. Both temporary and prepared
heap references failed without cycle serialization, so this choice should be
judged by narrowness and fresh validation with the cycle gate, not by an
unsubstantiated compiler-defect diagnosis.

#### SR-10/SR-14 production cycle-gate checkpoint

`E/classic-fgn-cycle-v12-evidence/run-1/sustained-result.json` records 8192
completed frames and commands with the prepared per-owner production cycle
state and the smaller temporary-Ref-under-lock PipeWireAO query. Across 7936
post-prefix exchanges it records 64 allocated bytes and four pool allocations,
with zero big/malloc/realloc counts and zero GC pauses/time/sweeps. The lifecycle
record correctly fails the strict allocation gate while preserving the completed
run; public shutdown and final owned cleanup both succeed. This is sustained
delivery evidence for the production gate, not satisfaction of the zero-byte
requirement or repeated multi-profile qualification.

Inspection confirms that the callback only increments its owner's atomic
completion counter, the owner establishes pending before triggering, bounded
wait errors retain pending, reset checks cycle quiescence before scientific
mutation, and cleanup still attempts all resources. The old per-Stream query
scratch field is absent. `E/driver-cycle-tests.log` records 40 assertions passing
for independent owners, old/immediate completion, suppression of repeated issue,
issuer/check failures, pending timeout, reset without counter rewind, and task
progress. These tests support the state transition design.

The zero-byte assertion in that fixture completes the cycle synchronously in
the issue callback. Consequently it does not execute the completion wait's
loop body or the real nested stream-health-check closure. Delayed completion
has behavioral coverage but no separate allocation assertion in this fixture.
The adapter's readiness wait also still constructs a sleep timer if stream
readiness is absent, although no evidence establishes that this branch ran in
the v12 measured interval. Source inspection does not attribute the four
allocations to either path. The selected full-interval allocation profile is
the appropriate next discriminator; no additional speculative source change
or compiler-defect diagnosis is supported at this checkpoint. SR-10 remains
open, and SR-14 still requires the repeated production qualification above.

#### SR-10 residual allocation attribution and CUDA API boundary

The full-interval `E/classic-live-allocation-profile-v13.json` contains exactly
four 16-byte `RefValue` allocations. Every stack passes through AOS's captured
prepared-context blocking wait, CUDA's `synchronize(...; blocking=true)` and
`maybe_collect(true)`. Two allocations are the free/total output references in
the device-memory query, and two are memory-pool cached/used attribute outputs.
The inspected CUDACore `yn2cv` source refreshes this memory-budget estimate
after ten seconds. This identifies the measured residual mechanism; it does
not implicate the adapter health-check closure or establish a compiler defect.

A narrow public-API experiment is to wait for `CUDA.isdone` on the prepared
captured stream using `GC.safepoint()` and `yield()`, then retain ordinary
`CUDA.synchronize(stream)` for final driver and Julia kernel exception checks.
In the inspected default nonblocking synchronization implementation, an already
completed stream takes the direct synchronization fast path without
`maybe_collect`. This is an implementation-specific performance observation,
not a public promise of zero allocations: the alternate nonblocking-disabled
preference still reaches the heuristic. No global CUDA GC setting or Julia GC
policy needs to change. Keep the prepared stream's submission ownership and
context binding unchanged so work cannot be added between the completion
observation and final synchronization.

The low-level CUDA stream synchronization wrapper is GC-safe and checks driver
errors, but calling it alone does not replace the separate Julia kernel
exception check. `check_exceptions` is internal in the inspected CUDACore
source, without an exported/public declaration; adding that private dependency
is avoidable. Public `isdone` propagates driver-query errors but does not itself
perform that Julia kernel exception check, so it is not a replacement for the
final high-level synchronization.

Keep any experiment limited to the existing captured prepared-context wait,
whose execution contract excludes host callbacks; ordinary graph execution
and scientific state are unaffected by the proposed scope. The existing wait
has no AOS deadline, so adding a hard timeout also requires a separate policy
for still-running device work and resource lifetime. Required validation is
zero allocation beyond the ten-second refresh window, preserved device/kernel
error propagation and GC/task progress, exact same-policy scientific/reset
results and fresh sustained process evidence. No implementation or workload
was performed by this review, and SR-10 remains open.

#### SR-10 public prepared wait and first complete zero-byte production case

The inspected AOS worktree
`/home/dgamroth/workspaces/codex/AdaptiveOpticsSim-captured-wait`, based on
`d30db3f`, changes only the captured prepared-context wait in the CUDA extension
and adds its focused test/selector. The implementation polls public
`CUDA.isdone`, executes `GC.safepoint()` and `yield()` while pending, then calls
ordinary public `CUDA.synchronize`. It introduces no private exception helper,
driver pointer operation, global GC setting or scientific-state change.

`E/cuda-prepared-wait-tests.log` records seven assertions passing. The source
test warms a runtime kernel, explicitly observes it pending before the measured
wait, checks finite/equal output lanes, and measures another completed-stream
wait after a 10.1 s sleep outside the allocation window. Both waits allocate
zero. The numerical assertions characterize the test kernel's output; they are
not an adaptive-optics algorithm or physical-precision acceptance criterion.
The fixture documents CUDA 6.4.1 with its default nonblocking synchronization
policy. With that preference disabled the wait remains semantically correct,
but the final synchronization can execute the memory-pressure heuristic; zero
allocation is not established for that configuration.

`E/classic-fgn-wait-v14-evidence.lifecycle.json` records success, 8192 delivered
frames and commands, and 7936 measured post-prefix exchanges with zero allocated
bytes, all four allocation counts zero, and all GC counters/time zero. Public
shutdown is confirmed and final owned cleanup is complete. Its recorded
retained ADC SHA-256 is
`f339fb3f408529e6ddc3de38d1836cf2c8345cc6a6a0b0517e180156e52530fb`
and command SHA-256 is
`30db8e0ecd580198ebcad7ad77776b4269dd1451c919e2d1c4dd84c30b2899fe`;
both match the v12 retained-prefix report exactly. This comparison concerns
the retained 256-frame prefix, not independent replay of all 8192 exchanges.

Remaining error-path validation can use isolated processes and public APIs:
warm a bounds-checked kernel on a one-element device array with runtime index 1,
then submit the same compiled kernel with index 2 on the prepared stream and
require the prepared wait to propagate a runtime device/kernel error. Compare
the error category and public rendered detail with ordinary synchronization of
the same faulty workload in a separate fresh process. This separates runtime
error propagation from compilation failure and avoids relying on a recoverable
CUDA context after the injected error. Do not measure these exceptional paths
as ordinary zero-allocation intervals or manipulate private exception flags.
This experiment is proposed, not performed by the reviewer or covered by the
seven existing assertions.

SR-10 now has a complete positive Classic FGN process interval in the tested
configuration. It remains open for the rest of the requested campaign and
remaining error-path evidence. SR-14 has successful production delivery evidence
with the cycle gate, but its repeated multi-profile qualification is not yet
complete. Neither result is a claim about unchanged released dependencies:
the measured package includes the reviewed local adapter, PipeWireAO and AOS
remediations.

## Measurement, warming and scientific limits

The recorder keeps at most 256 complete detector images and commands. Histograms
have fixed storage and explicit bin/overflow semantics. Sparse witness storage
is bounded, retains global sequence/model timestamps, and shares staging without
altering the stored finite-prefix hashes. No reset occurs at retention completion.

Preparation warms plant/transport staging and both report versions, including
success and failure serialization.
The new sustained constructor preallocates its arrays; it does not itself prove
every sustained code path has executed before admission. Histograms and GC
measurement exclude the configured retained prefix. Allocation evidence names
the entire simulator process and includes control/pause diagnostics. It cannot
establish zero allocation in an FGN callback or a separate JFG owner. Sparse OPD
copies synchronize the device and diagnostic-enabled runs cannot qualify clean
capacity. First-use/compilation effects must remain visible when interpreting
allocation and outlier results.

Inspected logs report metrics 99/99, sustained-run 101/101, simulator 171/171,
owner protocol 84/84, deployment 174/174, coordinator 81/81, graph replay 123/123,
and export 126/126. Metrics tests include zero-allocation
updates, histogram bounds and post-prefix invalid inputs. Simulator tests include
prefix/summary counts, payload extents and an explicit late-failure report. They
do not execute the full source/transport scientific loop. The separately executed
40-assertion SR-06 broker suite covers source-status failure and supervisor
cleanup; the coordinator tests cover the exceptional fallback in SR-09.
Export fixture logs contain expected Git revision lookup errors for non-Git
temporary source fixtures; the test summaries report passes. These messages
must not be represented as missing live installed-artifact identity checks.

Chronological ordinary-array graph replay can expose requested-minus-demanded
and physical/controller feedback and characterize public `process!` allocations.
It does not measure foreign callbacks or establish live intermediate FGN receipts.
The normal sustained commands do not exercise clipping recovery. The following
separate replay and stress evidence preserves that distinction.

## Graph replay and clipping evidence

Inspected `classic-shared-graph-replay/graph-replay.json` and
`copper-shared-graph-replay/graph-replay.json` report maximum demanded-command
differences of 1.8474111176405252 × 10⁻⁷ µm and
3.900879629171724 × 10⁻⁶ µm respectively. Both measured public `process!`
paths allocate zero bytes over the replayed prefix after their documented warm
and reset. No numerical acceptance threshold or callback-allocation claim is
attached to these observations.

The Copper comparison explicitly permits a reconstructor difference: 11
coefficients differ, maximum 9.5367431640625 × 10⁻⁷, relative Frobenius difference
3.592309806978162 × 10⁻¹¹. The two hashes and the exception appear in the input
metadata. This comparison therefore characterizes the selected installations;
it is not a bit-identical-matrix equivalence result. Other parameter and
controller-coefficient differences remain rejected by admission.

The separate Classic clipping fixture deliberately tightens demanded-command
rails to ±0.01 µm and preserves the accepted matrices, gains and plant.
`classic-fgn-clipping-evidence.lifecycle.json` confirms two finite batches and
public shutdown. The paired SPA-assignment replay reports nonzero physical and
controller constraint feedback on all 256 frames, zero ordinary `process!`
allocations and maximum demanded-command difference
3.9079850565472646 × 10⁻⁸ µm. These are replayed internal feedback values, not
independent live FGN internal receipts. The legacy finite simulator report still
labels its normal command limit as 0.8 µm; stress rail interpretation must use
the bound stress graph and actual commands, not that inherited statistic.

The optional negative control prepares another graph, warms and resets it,
loads the same recorded ADC inputs, and leaves controller feedback zero for
every frame. Its code and 24 focused test assertions distinguish nonzero feedback
with a changed demanded output from an uninformative fully railed output. The
gate intentionally requires only an exact Float32 output difference; it is a
sensitivity check, not a numerical acceptance tolerance or a new plant
trajectory. The actual clipping negative-control result is pending at this
review checkpoint.

An earlier ad hoc JFG clipping copy rewrote graph assignments as JSON. The frozen
JFG parser rejects that input syntax. Failed copies/logs are preserved; corrected
preparation retains the supported SPA assignment syntax and checks decoded graph
equality apart from the declared rail change. This is a diagnostic input-format
limitation. No parser redesign or sibling-package repair is selected here.

## Completion and exclusions

No unresolved confirmed production defect remains among SR-01 through SR-09;
historical metadata and measurement limits above remain part of the evidence.
SR-11 through SR-13 are corrected. SR-10 and SR-14 are remediated for the selected
ordinary CUDA frame loop, with all four continuous, stopped-reset and tested
paced compositions represented in the latest-disposition evidence. Copper
clipping-feedback characterization, its informative fixed-input controls, the
UInt16 wire comparison and the fresh registry-resolved PipeWireAO live check
are complete. This pass requests no additional production repair before merging
the selected increment.

Midrun pause/status/report operations still allocate. Removing those allocations
is deferred work; stopped-reset runs and ordinary frame-loop qualification do
not qualify an interval containing those operations. Final serialization and the
retained warm prefix are explicitly outside the measured interval. Sparse truth
sampling does not verify every sustained frame against a replay.

The initially contaminated Classic capacity run remains identified by
`E/classic-fgn-capacity-observer-load.json`; it cannot support a clean timing
claim. The newer zero-byte continuous records are completion-driven observations
in their stated configuration. Paced shared-host measurements retain their
observed missed periods and over-budget exchanges. Scope excludes isolated
maximum-rate claims, measured HIP zero allocation, zero allocation under untested
CUDA synchronization preferences, HEART changes, host tuning, physical-device
acceptance and hard real-time qualification. Stream/Captured differences remain
numerical characterization without an invented acceptance tolerance.

## Reviewed identities

The measured FGN descriptor SHA-256 is
`91ffcd072eea5667a1be804186eb8657a38435386fe35e0bb833d2984aa2903e`.
Its acquisition coordinator SHA-256 is
`dc3331aae4b42c15f3d41a37ee6f5e7c888a88f11a451e011bc8185ac33fa2c0`.
The earlier reviewed coordinator had SHA-256
`b1509efbec26102700cffc107b4fdebc9e2594a427d8ee389e2187d612ec16e1`;
its difference from the acquisition coordinator includes later telemetry.
The pre-allocation-remediation source review identified the files below; the
subsequent SR-10 through SR-13 checkpoint reviews newer uncommitted changes and
does not replace these identities. Historical run hashes
remain authoritative for their own acquisition and must not be replaced by the
latest source identities.

| Reviewed source | SHA-256 |
| --- | --- |
| `deployment/qualify_sustained.jl` | `e50b86d9446df024236c5eed276c1d5353d4165c334a2dea15cc6c78a8257fc8` |
| `deployment/hil/check_graph_replay.jl` | `ff9ab355bbe9b809e38451756786af13a330d5e8545df8eaa9b46bc3b3d4cdc5` |
| `deployment/hil/simulator.jl` | `e8b110ee2aa25c7c87f3354fedb833acce9a75178b83a83b87b9f5b2057ab086` |
| `deployment/hil/sustained_run.jl` | `5cf0fb379fc4b2cc0a8dee552da7b3f863ca5f1bbf8976abc0e69f65d9ed4083` |
| `deployment/hil/sustained_metrics.jl` | `32f21fcd72027475e8236510047a4146dfdab8e80b284210ea930a52db22977c` |
| `deployment/hil/owner_protocol.jl` | `0db2f50f7064b957ae5a71eb163706a02ee24f2be1fb9d295cf4134a948d0283` |
| `deployment/julia/src/deploy.jl` | `5cf879047bab5c8328ca2e2c0fea340e1266603357057ad734a67301033e9035` |
| `deployment/julia/src/hil_export.jl` | `365b1657191f8b7d053a0e9681059710f1d0cd3a694de91d355dfdf766ced158` |

The final allocation-remediation inspection used these newer source identities.
They identify reviewed source, not a qualified live acquisition:

| Reviewed remediation source | SHA-256 |
| --- | --- |
| `deployment/hil/simulator.jl` | `22ea8674e9b2fea1e1467d8d0aeaa02c5596ecd57d9a080ec3c700958236e731` |
| `deployment/hil/correction_truth.jl` | `d6005cc6423d2dd7e047b2d8a2c028aaf200cc0e7256e8be4cd9c0042c0dc5b5` |
| `deployment/hil/test_owner_loop.jl` | `3a782afd02c69599b12bdd3b00e6a42ae13a7d17916875cde227e81b8214e009` |
| Sibling adapter `src/exchange.jl` | `5537387e345ec79f31879af776bf937a91af876ce14672e7bdc2e9a36e38152e` |
| Sibling adapter `test/exchange_wait.jl` | `81f082e3d182975ebc300776e757685c5ce382ecc2ee6127c190335b4a986e83` |

The later owner-specialization/native-lock checkpoint inspected simulator
SHA-256 `a39299b8ab23092f39125cb5a22b9ac265f673a52b3c3c5352593c0dab1873a4`
and sibling PipeWireAO `src/thread_loop.jl` SHA-256
`4463551caf2a612af955a19aa0a70aea01b91f9a8e8bab6932cf007831a4a74d`.

The closure-specialization/stream-state checkpoint inspected simulator SHA-256
`fad8e3021dd3c08c4ce026528d6c16506dd1dd204713a51d9f37b83d0b1c7248`,
coordinator SHA-256
`d1b658a2e6c810f9f86ebc9469ff8f226391446b9cd8d585465d7be18caa0526`
and sibling PipeWireAO `src/stream.jl` SHA-256
`c0ef9f6dcbdefedb831f58cdbffeeb5fba4acb8b58b83379bd39ee50ea74e67b`.
