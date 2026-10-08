# Merged Classic live methodology review

Tool provenance: the Python scripts and retired Julia launcher referenced here
were removed from the current checkout on 2026-10-08. Commands describe the
[recorded source revision](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/CLASSIC_MERGED_LIVE_REVIEW.md);
these commands are not runnable in this checkout. Results and design claims
retain their original scope. See the [current benchmark index](README.md) for retained tooling.

## Scope and disposition

Independent review, 2026-10-01, in `pipewireao-rtc-classic-merged-live`, based on
`7e443105e17824fb85ede894c918302f77a0b605`. The incoming tree contained the new
campaign document, summarizer and tests; remediation subsequently modified the
capacity analyzer and its tests. This review changes documentation only.

Reviewed the summarizer, capacity classification, campaign failure retention,
row-work and scheduler analyzers, and the completed frame and row baseline
artifacts. The previous direct numerical review is not repeated here.

The 36 historical baseline windows support the bounded delivery and latency statements in
`CLASSIC_MERGED_LIVE.md`. MLM-001 and MLM-002 are resolved and independently
verified.
The qualified 250 Hz diagnostic work results are independently reproduced in
`CLASSIC_ROW_HANDOFF_REVIEW.md` (RH-004), including the JFG clock-margin
sensitivity. Capacity results remain pending independent artifact review. The separate
maintained live-update functional test is reviewed below. No physical accuracy, physical DM response, systemd deployment,
indefinite capacity or worst-case latency qualification is provided.

The final CPU0/1-free 250 Hz baseline is independently verified below: twelve
FGN/JFG windows pass, while HEART passes two windows and fails one. The failed
window remains in the three-window series. Historical placement results are
not pooled with this corrected baseline.

## Findings

### MLM-001 — Aggregation must enforce comparable conditions

- **Severity:** medium. **Confidence:** high. **Classification:** confirmed
  analyzer defect; current baseline measurements are unaffected.
- **Affected source:** `summarize_classic_merged_live.py`, `read_manifests`,
  `_apply_qos_admission`, and percentile grouping.
- **Fail-before evidence:** modifying the recorded binary hash between repeated
  FGN windows still yielded a passing rate. Changing one window's worker count
  made capacity incomparable but still combined all three percentile values.
  Rate bounds also permitted different readouts without a declared camera law.
- **Impact:** a repeated series could silently combine changed executables,
  workloads or placement; a finite bound could combine different camera
  schedules.
- **Remediation verified:** admitted windows now require one per-path identity
  containing recorded source heads/status, harness hashes, input/binary hashes,
  parameter/profile hashes, runtime provenance, placement, workers, matrix layout
  and frame count. Default admission requires fixed readout; explicit
  `--readout-fraction` checks `floor(10⁶ × fraction / rate)` for each window.
  Duplicate run directories are rejected. Missing or ineffective QoS windows
  remain excluded and do not poison otherwise comparable eligible windows.
  Analyzer hashes are recorded.
- **Final verification:** numerical-acceptance policy is now included in the
  per-path identity. Known, nonempty arithmetic fixture maps must agree across
  admitted backends. All 11 summarizer tests pass, including changed policy,
  mismatched cross-backend fixture and retained missing-arithmetic failure.
  Successful post-delivery fixture maps are deliberately excluded from the
  immutable per-path identity: a real delivery failure can prevent production
  of the arithmetic report. Pre-ingress input/binary, parameter/profile, source
  and runtime hashes still enforce work identity; missing post-delivery evidence
  stays visible and is not fabricated as success. This distinction is sound for
  the recorded campaign and avoids losing the very failures needed for bounds.
- **Disposition:** resolved. Future artifact formats must continue to preserve
  pre-ingress workload identity for failed windows; missing output evidence must
  never be used as a substitute for that identity.

### MLM-002 — Failed-delivery load admission must validate actual source work

- **Severity:** medium. **Confidence:** high. **Classification:** confirmed
  analyzer defect, resolved.
- **Affected source:** `classic_capacity.py`, `source_pacing_from_packets` and
  `classify_window`; `test_classic_capacity.py`.
- **Fail-before evidence:** a two-frame stream containing only zero-filled WFS
  headers, sequence/frame identifiers and timestamps was admitted as complete
  Classic ingress at 100 Hz despite missing every pixel payload and having
  invalid UDP lengths and geometry.
- **Impact:** malformed or changed source work could establish an RTC failure
  bound when DM delivery was missing.
- **Remediation verified:** fallback parses the complete payload, checks Classic
  dimensions, bit width, lengths, ordered raster/frame/packet coordinates and
  finite ordered nanosecond timestamps, with correct rate units. Classification
  additionally requires the physical qualifier's source-pixel attestation:
  missing/malformed evidence, WFS errors or any FITS pixel mismatch exclude the
  window. DM-only failures remain eligible when source admission passes.
  The physical qualifier separately validates encoding and checksum conventions.
- **Pass-after evidence:** all 17 focused capacity tests pass, including
  header-only, geometry, truncated payload, UDP length and raster corruptions;
  source-pixel absence/mismatch; DM-only failure; compressed corrupt/incomplete
  evidence; underdrive, duplicate repeats, and finite failure bounds. Expected
  decompressor errors from corrupt-input tests are retained. Both complete
  baseline campaigns still classify all 18 windows as passed.
- **Disposition:** resolved; do not reinterpret excluded source/placement/exit
  failures as tested RTC capacity upper bounds.

## Verified evidence

Reviewer ran lightweight offline checks on housekeeping CPU 14; no new live
benchmark or build was launched. Commands:

```text
taskset -c 14 python3 -m unittest discover -s benchmark -p test_classic_capacity.py -v
taskset -c 14 python3 -m unittest discover -s benchmark -p test_summarize_classic_merged_live.py -v
```

At final aggregation verification these passed 17 and 11 tests respectively. The reviewer also
called `read_manifests` and `summarize` independently on the original manifests:

- Frame: `/tmp/rtc-classic-merged-frame1029-20261001/manifest.json`.
- Row: `/tmp/rtc-classic-merged-row1029-20261001/manifest.json` plus
  `/tmp/rtc-classic-merged-row1029-continuation-20261001/manifest.json`.
- Independent outputs:
  `/tmp/classic-merged-frame-independent-review-20261001.json` and
  `/tmp/classic-merged-row-independent-review-20261001.json`.

Each phase has 18 passing windows, 18,522 DM commands and 592,704 WFS packets.
Every documented p50/p99 endpoint matches rounding of the per-window summary
values. These ranges use three windows of 929 post-first-100 frames per
path/rate; all 1,029 frames remain in delivery and deadline qualification.
The complete fixture-hash maps agree across all receiver paths in each phase.

Reviewed analyzer fingerprints at this checkpoint:

| File | SHA-256 |
| --- | --- |
| `summarize_classic_merged_live.py` | `298dcc06a229bd10f088cfefff2dfd05568b53dabce0c84f4cecd952a75156fc` |
| `classic_capacity.py` | `42ca8c4b5a73fe833c4c00e02ef4f1d34a63fe66effd08fd2a8ec80de9daebe3` |

## Interpretation and remaining validation

- Capture boundaries are first/terminal WFS packet to DM UDP packet. They
  exclude exposure and physical actuator response. Mean source-rate admission
  within 1% is not a bound on individual source interarrival jitter.
- Failed windows, read errors, historical strict numerical failures, QoS
  exclusions and launcher failures remain visible. Child exit or placement
  failure is an explicit exclusion under the current capacity contract, not
  evidence that a receiver passed. A failure bound requires eligible offered
  work and enough distinct repeated windows.
- Full-frame and progressive implementations have different execution and
  arithmetic costs. HEART remains progressive in both phases. Reduced terminal
  latency alone does not quantify SH/MVM work hidden within readout and does
  not isolate language cost.
- Row-work analysis derives completed scientific prefixes from synchronous
  zero-helper callbacks and calibrated clock anchors. It does not directly
  timestamp each SH/MVM operation; two anchors do not prove the absence of
  unobserved clock excursions. Keep source/configuration attestation, uncertainty
  and sensitivity calculations attached to any resulting work claim.
- Scheduler analysis retains trace loss, parse errors and censored intervals.
  Observed off-CPU intervals are not automatically scheduler delay. Instrumented
  windows must remain separate from normal latency percentiles.
- Source-equation acceptance and identical clipping classifications preserve a
  defined software comparison. They do not establish application accuracy or
  physical loop stability. The historical 10⁻⁶ diagnostics remain separate.
- Capacity must retain the explicit 0.85 frame-period readout law separately
  from the 2,000 µs baseline. Finite repeated pass/failure bounds are not a proof
  of indefinite operation, monotonic capacity, or worst-case latency.
- Review the final capacity, diagnostic and update artifacts when available;
  verify source identities, all retained failures, all-frame deadlines,
  diagnostic qualification and the live-update scope before promoting claims.


## CPU reservation correction and report retention

The user subsequently excluded CPU 0 from RTC work. Earlier measurements in
this document remain historical evidence under their recorded old placement;
they do not qualify the corrected layout and must not be pooled with it.
The old 2,000 Hz campaign interruption is retained in
`/tmp/rtc-classic-merged-capacity-2000hz1029-20261001/placement-correction-interruption.json`.
Its two completed old-layout cases are not a repeated capacity qualification.

Source review confirms corrected Classic defaults:

| Role | CPU placement |
| --- | --- |
| Receiver launcher envelope | 2–15, excluding CPU 0 and its SMT sibling 1 |
| RTC process envelope | 2, 4, 6, 8, 10, 14 |
| Source / housekeeping | 12 / 14 |
| Daemon and native FGN loop | 2 |
| Classic JFG native owner / default Julia pins | 4 / 4,14 |
| Standard-DM adapter loop | 8 |
| HEART WFS / processing / reconstruction | 2 / 4 / 6 |
| HEART TFC / CLWC / DM | 8 / 8 / 10 |

HEART has six worker threads on five physical cores; controller stages share
CPU 8. The diagnostic launcher imports the common corrected command generator,
and perf's idle filter follows CPUs 2,4,6,8,10. Optional adapter placement rejects
0/1 and distinguishes sharing a CPU from sharing a data-loop. This is source
and command-generation verification; fresh actual thread-placement evidence is
still required. Final Copper profile review is recorded below. Classic Julia helper pins are
`4,14,6,10` when two helpers are selected; adapter CPU 8 remains excluded.
The separate Copper fixture retains its declared two-thread `4,6` pins.

`read_case_reports` now records physical delivery before attempting an optional
arithmetic report. A false delivery result stays false if delivery loss prevents
science reporting; missing scientific acceptance remains `None` with an explicit
status, and no arithmetic artifact is invented. HEART still requires both its
arithmetic and exact-model results when present. Four focused report tests cover
these cases. The reviewer independently ran the full `test_classic_platform*.py`
selection (30 tests) and the three CPU-layout tests on CPU 14, all passing.

## Maintained live-update functional evidence

Reviewed `/tmp/rtc-classic-merged-live-update-20261001.log`, the retained
`private-core` evidence symlink under that directory, and the corresponding
`tests/live_private_core.rs` and Julia HIL provider source. One scoped
`PIPEWIREAO_RTC_LIVE_SCOPE=revolt` test passed; two other test cases were filtered.
The reviewer did not rerun a build or live test.

The HIL log records ten finite commands for each native and Julia implementation.
For both, sequences 5–7 use the previous reconstructor and sequence 8 uses the
requested one. Test source checks a one-way adoption transition, paired gain/pole
updates and observed generations, rejection of a transposed parameter shape,
retry and reload, finite source completion to READY, retained external objects,
and cleanup of session-owned graph resources. The Julia callback checks command
shape, sequence, bounds and finite values; the fixture owns numerical checks and
frame progression.

This is the maintained simulated closed-loop/private-core, build-tree functional
contract. It uses a 277 × 376 reconstructor and the `integrate` property interface,
not the exact 221-coordinate matched progressive graph used in the UDP comparison.
It therefore establishes the covered RTC update/lifecycle behavior, not live
adoption of that exact row graph, fixed-arrival performance, physical AO stability,
or an updated numerical calibration. Test-only gain and matrix changes do not
modify campaign calibration or gains.

The successful log retains an existing Rust future-incompatibility warning for
`proc-macro-error2` and Julia precompile warnings about already-loaded dependency
versions. They do not contradict the completed behavioral assertions, but this
run is not evidence of a warning-free build or latency qualification. Archive the
resolved private-core directory contents, not merely the symlink, with the log.


## HEART controller placement decision

Read-only inspection of HEART source revision
`6a5c06b11a8b934effeb6328a73a70895b2af94a` supports keeping TFC and CLWC on
CPU 8 at FIFO15 for the corrected baseline. No wait-path defect requiring an
8/9 SMT split was found.

Evidence within `heart-copper-comparison/source`:

- `pipes/src/hrtWcPipe.c:363` and `:422` create TFC and CLWC with
  `hrtBlock_triggerType_SEMAPHORE`. The older `hrtWccPipe.c:564` and `:771`
  creation path uses the same trigger type.
- Both workers use `blocks/src/hrtBlock.c::hrtBlock_worker`; line 1867 calls
  `sem_wait` before each worker iteration.
- TFC publishes its DM-error data and triggers downstream at
  `blocks/src/hrtTfcBlock.c:3562`. Its input routine and CLWC's
  `getInputData` select existing circular-buffer buckets; the reviewed path does
  not busy-wait for same-frame work from the other controller worker. TFC's
  CLWC-dependent feedback is consumed on a later iteration.
- CLWC's optional background completion waits use `sem_wait`; its start-flag
  loops use `clock_nanosleep` with a 1 µs request. The generic circular-buffer
  wait in `util/src/hrtCircBuffer.c:4512` also calls `clock_nanosleep`. These
  waits release CPU execution rather than continuously spinning.
- This host reports CPU 8's SMT siblings as `8-9`.

**Derived conclusion:** with triggers exhausted, the running controller worker
blocks and the equal-priority peer can execute on CPU 8. Same-logical-CPU
placement therefore has a sound baseline liveness rationale. Under overload,
an accumulated semaphore backlog can allow repeated iterations before a block;
this is not a bound on peer latency or fairness. Fresh complete-window delivery,
deadline and placement evidence remains necessary.

**Recommendation:** keep 8/8 for the first corrected baseline. Treat 8/9 as a
separate SMT experiment if needed; it introduces simultaneous contention on one
physical core and is not a remedy for an established spin deadlock. Keep source
12, housekeeping 14 and the CPU 0/1 exclusion unchanged. No HEART source or
scientific parameter change is proposed.

## MLM-003 — Copper profile requirements must match emitted loop configuration

- **Severity:** medium. **Confidence:** high. **Classification:** confirmed
  configuration integration gap in maintained Copper mode; Classic command
  generation is unaffected.
- **Evidence:** the revised strict `ryzen-6800h-copper.json` requires the
  adapter data-loop on CPU 8 and FGN observer placement on 14. However,
  `run_copper_baseline.py` sets adapter/observer explicit loop configuration only
  with `--configure-all-loops`; strict-profile-only mode still launches the
  adapter process with the broad RTC envelope. Profile-only structural tests
  pass without showing that generated launch settings meet these requirements.
- **Additional ownership boundary:** the external FGN runner starts its observer
  without `placed(...)`, so its process leader inherits launcher affinity;
  `--observer-loop-cpus` configures only the data-loop. The new profile's observer
  process envelope of 14 needs matching launcher/leader placement as well.
- **Impact:** a supported strict-only launch can reject itself before ingress;
  an unconfigured observer can retain CPU 0/1 if its launcher allows them.
- **Remediation requested:** make maintained strict-only/all-loop emitted commands
  and environments meet their selected profiles, and guarantee the observer
  process envelope. Add offline generated-launch tests for both paths, not only
  JSON field checks. Update the current all-loop description in `COPPER.md`
  (historical CPU 0 result paragraphs remain historical evidence).
- **Remediation verified:** strict-profile launches now require explicit
  `--configure-all-loops` before any process starts. Actual call sites emit
  FGN observer14/adapter8 and JFG daemon2/observer14/adapter8 requests, and launch
  the FGN parent under `taskset --cpu-list 14`, so the unplaced observer inherits
  the correct process envelope while explicitly placed children use their roles.
  Seven profile/emitted-launch tests and fifteen baseline tests pass independently.
- **Profile alias remediation verified:** both `ryzen-6800h-copper.json` and
  `ryzen-6800h-copper-all-loops.json` now require daemon `rtc-data-loop` on
  CPU 2 at FIFO83. Independent preflight and emitted-loop checks for both
  profiles succeed, so the maintained examples selecting the former profile
  satisfy the supported mode. All seven profile tests pass again on CPU 14.
- **Custom profile refinement verified:** the actual FGN launch call now derives
  its inherited parent mask from `roles["fgn-command-observer"]["cpus"]` when
  a strict profile is present, and retains CPU 14 otherwise. Required-role
  preflight precedes this lookup. The custom `10,14` helper regression passes;
  the final eight profile tests pass independently on CPU 14. Maintained
  profiles still select observer CPU 14 and exclude CPU 0/1. This change affects
  Copper launch configuration, not the captured Classic baseline harness.
- **Disposition:** resolved by source, profile and offline generated-launch
  verification. Actual live placement remains an admission requirement for each
  future Copper window. The original failure was before ingress, not an RTC failure.

The reviewer independently ran five Copper profile tests, fifteen Copper baseline
tests and three current Classic CPU-layout tests on CPU 14; all passed. The additional generated-launch coverage above closes the implementation gap.
Classic's fresh matched baseline can proceed with the reviewed 8/8 controller
placement. Copper launch/profile consistency is verified at the configuration
level; this review does not claim a fresh live Copper qualification.

## First corrected-layout HEART failure: observation, not root cause

The first HEART 8/8 window in
`/tmp/rtc-classic-cpu0-free-baseline250-1029-20261001/heart-250hz-latency0-r1/run`
fails exact delivery. Read-only review used its small JSON reports, placement
snapshots and logs; no capture decompression, live test or build was performed.

**Observed:** all 32,928 WFS packets for 1,029 frames were captured, with zero
FITS-payload mismatches and zero reported dumpcap loss. There are 1,028 valid,
finite DM packets; frame ID 19 appears three times, and IDs 20, 21 and 1,029 are
absent. Repeated ID 19 packets carry different native timestamps and different
first/last actuator values, so they are not simple duplicate capture records.
Normal child exits and before/after worker placement match the intended
2/4/6/8/8/10 layout at FIFO15. Neither exact delivery nor numerical acceptance
can be promoted for this failed window.

**Earliest concrete error chain:** `scao.log:526` reports WFS duplicate datagram
sequence 5; the error stack timestamps it at 16:07:56.999682, with only 209/352
pixel rows completed. Processing then logs a circular-buffer reader jump from
18 to 20, an invalid output bucket, invalid reconstruction input, no new TFC HO
input and skipped CLWC integration. At 16:07:57.003261 the WFS handler reports
skipping 27 datagrams to find a frame start. Its configured receive buffer had
been truncated from 262,144 to 212,992 bytes (`scao.log:310`). Later shutdown
and telemetry-close errors remain separate from this in-window chain.

**Interpretation:** the reports establish a receiver/progressive-input error
and downstream invalid-data handling. Complete capture proves offered packets,
not successful delivery into HEART's UDP socket. Receive-queue loss/backlog or
frame-parser resynchronization is therefore an evidenced alternative mechanism
to controller CPU sharing. Buffer truncation alone does not prove overflow;
there is no socket-drop counter or scheduler trace resolving the initiating
cause in this window. Same-CPU controller backlog remains a hypothesis, not a
confirmed explanation. The pipeline's later continued output also does not
support claiming a persistent equal-priority spin deadlock.

**Disposition:** retain this failure, finish the fixed-condition repeats, then
compare an explicitly separate 8/9 layout if needed. If the failure repeats,
the cheapest discriminating diagnostics are receiver socket-drop evidence and
WFS frame/sequence receipt correlated with the first error, alongside worker
scheduling. Do not change HEART science or claim that an 8/9 pass alone proves
the original failure's mechanism.

## Final corrected-placement baseline verification

Independent offline verification of
`/tmp/rtc-classic-cpu0-free-baseline250-1029-20261001/manifest.json` regenerated
`summary-reviewed.json` exactly as a JSON object. The reviewer result is
`/tmp/classic-cpu0-free-independent-review-20261001.json`. Manifest SHA256 is
`f26c8939cc818ec7437be9fba27dadf432c0de944b416e724084fece90666b5a`;
summary SHA256 is
`3632c90d2c14e40800f1cc1ea654402376863602d7bc962a25ffc5162b4cd8ed`.

Verified the tracked compact evidence against those files, including every
per-window retained field, group count and percentile range. Independently
checked 85 harness/analyzer/window artifact hashes, all 30 before/after
placement hashes, and all 474 recorded thread affinity entries: none includes
CPU 0 or 1. The twelve frozen files in the sibling directory
`/tmp/rtc-classic-cpu0-free-executed-sources-20261001` match `INDEX.json`, and
all six manifest harness hashes match that snapshot. These checks establish
recorded source/artifact consistency and owned-thread affinity, not OS core
isolation or an unobserved continuous affinity trace.

All fifteen windows used 250 Hz, 2,000 µs nominal readout, 1,029 frames and the
same corrected placement. All twelve FGN/JFG windows satisfy exact delivery,
source-arithmetic acceptance, zero clipping-classification disagreements,
normal child exit, placement and zero-QoS admission. Each has 1,029 observed
all-frame deadlines with zero misses of the 4 ms first-packet-to-DM bound.
HEART's second and third windows pass. Its first remains an eligible **failed**
window, so both HEART delivery and delivery-plus-deadline series contracts fail.
The missing science/deadline measurements for that failed delivery remain
unknown; the failed combined contract is not a fabricated measured lateness.

The documentation's rounded terminal-to-DM percentile ranges agree with the
summary. They use each qualified window after the first 100 frames, without
pooling samples: FGN frame p50 252.4–253.1 µs / p99 272.6–293.2 µs; JFG frame
248.2–265.6 / 272.2–325.6; FGN row 67.0–67.6 / 75.5–78.5; JFG row 59.1–59.4 /
67.7–69.5; HEART's two qualified windows 85.4–85.8 / 95.1–105.7. The HEART
failure is excluded only from these conditional percentiles, not from the
series or its disposition. The preceding receiver-error analysis remains
unresolved; neither controller sharing nor socket overflow is established as
its cause.

The cleanup record accounts for 162,625,446 bytes across six completed private
Julia compiled-cache directories. It does not remove the reviewed reports,
placement evidence or executed source snapshot. The final archive must retain
the campaign directory, its sibling source snapshot and launch log together.

**Disposition:** the current bounded baseline claims are supported. No further
benchmark is required to state these observed results. They do not establish
an indefinite capacity, a corrected-layout high-rate limit, physical AO
accuracy/stability, or a successful three-window HEART qualification. No
production code, scientific parameter or live capture was changed by this review.
