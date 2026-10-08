# Classic platform campaign independent review

Review date: 2026-09-30. Status: source remediation, completed normal matrix,
and final diagnostic evidence verified within the stated limits.

This review covers the CPU latency request, campaign lifecycle, ingress
barriers, scheduler analyzer, summary writer, and their focused tests. It uses
the [platform experiment](../benchmark/CLASSIC_PLATFORM.md) as the experimental
contract and preserves the distinction between development characterization
and hardware or real-time qualification.

The reviewed worktree is
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-platform-latency`, branch
`codex/classic-platform-latency-20260930`, starting HEAD
`f8dbb47930f8d24fa7711509bac557fe9d867077`. The campaign files were already
modified or untracked. This reviewer owns this document only; production
files, tests, and running experiments were left untouched. No live replay,
profiler, or test suite was started during the active normal matrix. Test
coverage statements below describe inspected source, not independently
executed tests.

## Findings and disposition

| ID | Severity / confidence | Classification | Disposition |
| --- | --- | --- | --- |
| CPR-01 | P2 / high | Confirmed cleanup defect | Fixed; source and retained process regression reviewed |
| CPR-02 | P2 / high | Confirmed admission-order defect | Fixed; admission ordering and focused test reviewed |
| CPR-03 | Scope limit / high | QoS intervention does not identify each delay mechanism | Retain in final claims |
| CPR-04 | Improvement / high | Capture envelope and callback span have different meanings | Existing analyzer labels are suitable; retain them |
| CPR-05 | Verification obligation / high | Completed matrix and diagnostic evidence remain required | Closed for the retained 30 normal and 10 diagnostic cases |

### CPR-01 — runner exit does not establish process-group cleanup

**Observed:** The reviewed `run_classic_platform_campaign.py:run_case`
cleanup block checks the runner's `poll()`, sends SIGINT to that PID only,
and sends SIGKILL to the process group only if the PID fails to exit within
120 seconds. If the leader has already exited, or exits promptly while a
descendant survives, the group is never examined. The initial group-membership
check covers prepared receiver PIDs; it does not establish eventual absence
of every descendant.

**Derived:** An abruptly terminated runner can leave receiver, capture, or
other child work active. Continuing the matrix could then contaminate the
following run or retain a HEART-owned QoS request. This is a source-established
failure-path defect; no leaked process was observed in the accepted normal
windows examined during review.

**Remediation:** Audit the owned process group after runner termination on
every path. Retain surviving members as a failure, terminate the owned group
with bounded escalation, and verify its disappearance before proceeding.
Preserve the original error when cleanup also fails. The primary has accepted
this approach. Do not mutate the already loaded campaign or its archived
provenance to suggest it used the fix.

**Required validation:** A runner that exits while leaving a child alive must
exercise cleanup even though the leader has exited. Cover a normally exiting
leader, an abruptly exiting leader, and a child that ignores the first signal.
Audit the completed normal campaign's saved process groups separately; normal
child exit evidence remains useful but does not retroactively add the guard.

**Closure:** The revised runner initializes `case_group_empty=false`, calls
`cleanup_case_group` after receiver/perf cleanup even when the leader has
already exited, records surviving members as errors, and attempts SIGTERM
then SIGKILL with bounded waits. A failed group audit leaves the flag false;
the outer campaign writes the failed result and stops before the next case.
An earlier cleanup exception also leaves the initialized false flag in place.
Zombies are excluded from active membership because they cannot execute work.

The retained normal campaign `cleanup-regression.json` records a real forked
child surviving its leader's zero exit status, then disappearing under the new
cleanup, with the leak retained as an error. This directly exercises the case
the old leader-only conditional skipped. The primary reports 207 Classic
unit tests passing after remediation, including mocked persistent-member
escalation; this reviewer inspected those tests and the saved process evidence
without rerunning them during diagnostics. An independent `/proc` scan also
found no active member of any of the 30 saved normal case groups.

### CPR-02 — an invalid off condition is rejected after ingress

**Observed:** In the reviewed campaign, the check for an externally imposed
zero-latency constraint in an `off` case occurs after capture, report loading,
and the functional gates. `release.touch()` has already launched ingress.
This contradicts the experiment's claim that failed admission keeps ingress
closed. HEART/off is explicitly skipped by the current matrix, but an
unrelated zero-latency request can produce the same condition for FGN or JFG.

**Remediation:** Reject a conflicting effective request inside the QoS
context before enabling perf or releasing ingress. Compare the saved
before-ingress and after-capture readbacks when classifying the condition;
retaining those values without examining them is weaker than the available
evidence. Do not claim continuous monitoring from endpoint snapshots.

**Required validation:** Inject a conflicting off readback and verify that
the release marker is never created and the failed case remains recorded.
Exercise a condition that changes between endpoint snapshots. This is a
harness admission correction, not evidence that the observed successful
windows had the wrong QoS setting: all 24 retained normal windows examined
at the intermediate audit had matching endpoint values (zero for latency0,
2,000,000,000 µs for off).

**Closure:** The revised runner checks the off request immediately after
entering `cpu_latency_request`, before `PerfCapture` construction and before
creating the release marker. The saved before-ingress and after-capture
readbacks are checked again before interval generation. The focused
`QoSAdmissionTests` fixture asserts no release marker, no perf construction,
and no interval generation when the prepared off readback is zero. The
primary reports this test passing in the 207-test run. This closes the
identified admission-order defect; endpoint sampling still cannot establish
continuous absence of unrelated host requests.

### CPR-03 — keep intervention effects separate from causal attribution

**Observed:** The intervention is a host-wide CPU latency request. It can
affect the source on CPU 12, receiver/science CPUs, transport, housekeeping,
and other host activity. Existing source and scientific workloads are held
constant, but host-wide power behavior is deliberately changed. HEART
intrinsically requests zero latency, so its legitimate matched condition is
the zero-latency condition. Earlier inaccessible-device baselines cannot be
reclassified from these new readbacks.

**Supported inference:** Repeated matched FGN/JFG windows can establish the
effect of this intervention on measured packet-to-command latency on this
host. A large reduction is consistent with idle/power behavior contributing
to the earlier tails.

**Not established:** A particular idle state's exit latency explains every
tail; scheduler wake-to-run delay equals the full physical wake delay; or
callback wall time minus off-CPU time equals isolated algorithm execution.
The analyzer correctly warns that the remainder includes interrupts,
instrumentation, and other unobserved effects. An idle residency count is not
an exit-latency measurement. Nominal source rate plus an average pacing gate
does not establish the timing of every source arrival; retain readout and
source-period distributions when making comparisons.

**Required validation:** Use separate diagnostic windows, loss-free decoded
events, attested thread identities, complete native records, and matched
callback/scheduler brackets. Preserve the distinction between
`comparison_qualified`, `qualified_trace`, and `qualified_callbacks`. A
successful `perf script` exit or a functional packet replay alone is not
complete attribution evidence.

### CPR-04 — retain the distinction between acquisition and callback spans

**Observed:** The parent polls the completion marker every 20 ms, closes perf,
and then takes `after_capture`. That timestamp follows actual wire closure
and the last recorded perf event. Both live runners also retain a post-source
margin before closing capture. The analyzer's release-to-capture envelope
therefore includes source startup and stop margin. It already labels these
facts, censors trace edges, and provides a separate first-callback to
last-callback span.

**Disposition:** No source defect is asserted from this difference. Use the
callback span for activity associated with callback processing, and label the
broader envelope and sysfs idle deltas accurately. Neither span is exactly
the first WFS packet through last DM packet. A timestamped completion marker
could improve future acquisition-boundary precision without changing frame
processing, but it is not necessary to compare complete interior callback
intervals.

## Clock provenance

Native FGN records in the selected private
`module-ndarray-filter-chain.c` call `clock_gettime(CLOCK_MONOTONIC)` for both
callback endpoints. The perf command explicitly uses `--clockid mono`.

The installed Julia 1.12.7 runtime was inspected without starting Julia.
`share/julia/base/Base_compiler.jl:195` implements `time_ns()` through
`jl_hrtime`. In `lib/julia/libjulia-internal.so`, `ijl_hrtime` at `0x79b70`
jumps to `uv_hrtime` at `0x14786d`, which passes zero to `uv__hrtime` at
`0x161e7e`. That branch passes clock ID 1 to `clock_gettime` and returns
seconds × 10⁹ + nanoseconds. The installed Linux header defines ID 1 as
`CLOCK_MONOTONIC`. The inspected DSO SHA-256 is
`e36f5186f293ebc66ee8a5ebf0ee29cd6bf5e72ccf091f5a58ab44b59fdf52c5`.
This establishes a common callback/perf clock for the inspected runtime;
the generic phrase “monotonic nanoseconds” alone would not have established
a common epoch.

Normal packet latencies are differences between captured epoch timestamps.
They must not be directly subtracted from monotonic callback or perf times.
The retained endpoint clock anchors and
[previous clock review](CLASSIC_FINAL_REVIEW.md) remain relevant to any
packet/native correlation. Endpoint anchors and monotonic packet-order
checks cannot exclude every interior realtime-clock excursion.

## Evidence reviewed and remaining checks

The completed normal matrix contains all 30 distinct planned
path/rate/mode/repeat combinations: three windows for each of ten admitted
conditions. Every window reports qualified wire/science/functional/child-exit
and source-pacing gates, zero runner exit status, no errors, and 1,029 latency
samples. All QoS endpoint readbacks match the intended conditions; all
after-run readbacks return to 2,000,000,000 µs. The 13 FGN/JFG parameter file
hashes are identical across all their windows. No deadline exceedance is
observed among the 30,870 measured frames.

The reviewer independently checked those manifest invariants and the summary
group counts. The normal manifest is retained locally at
`/home/dgamroth/.cache/rtc-classic-platform-normal1029-20260930/manifest.json`,
SHA-256 `6d8ab496a5e61591bf91373aa98220653806912113ae654187bede6faf15f44a`.
Each of the six source copies in `executed-harness` matches its manifest hash;
they preserve the originally executed pre-remediation campaign.

After excluding the first 100 frames, per-window terminal-packet-to-command
p99 ranges in microseconds are:

| Path | Rate | Off | Zero-latency request |
| --- | ---: | ---: | ---: |
| FGN row | 100 Hz | 1,290.7–1,412.2 | 72.2–80.4 |
| FGN row | 250 Hz | 143.2–999.2 | 66.9–76.2 |
| JFG row | 100 Hz | 1,092.4–1,158.5 | 103.3–189.7 |
| JFG row | 250 Hz | 499.2–738.3 | 121.9–149.3 |
| HEART | 100 Hz | Excluded | 101.0–109.2 |
| HEART | 250 Hz | Excluded | 92.0–141.6 |

These are ranges of three window percentiles, not pooled percentiles or
confidence intervals. The off FGN 250 Hz median varies substantially
(55.2–213.6 µs), and one is below the zero-condition median. The supported
comparison is the repeated tail reduction; it is not a claim that every
quantile improves in every window. Both all-frame and after-first-100
distributions remain retained.

The existing failed/partial diagnostic attempts must remain disclosed,
including the intrinsically constrained HEART/off case and the disk-space
failure. They are not replacements for the fresh diagnostic matrix. Tests
inspected cover descriptor release, perf acknowledgement, ingress markers,
scheduler pairing/censorship/loss, native omission counters, and qualified
summary selection. No independent test pass is claimed by this source review.

The fresh diagnostic matrix is retained at
`/home/dgamroth/.cache/rtc-classic-platform-diagnostic252-final-20260930`.
Its manifest SHA-256 is
`676655f9f0f5b92c33ac8359eb4f906104174c2d3ea97bdb2057414a4c6a064d`.
All ten cases pass comparison qualification with empty error arrays and empty
case process groups. Each captures 8,064 WFS packets and 252 DM commands;
each endpoint QoS value matches its condition. All ten scheduler reports have
`qualified_trace=true`, no reported perf loss, no parse errors, and no analysis
errors. All eight FGN/JFG cases have `qualified_callbacks=true`, with zero
excluded or outside-window callback records. HEART intentionally has no
FGN/JFG callback qualification.

The reviewer checked every handoff input hash against the retained file,
native capacity/use/omission headers against actual CSV row counts, all 8,064
frame/offset identities per case, and every ordered receive/publication/
callback/sink timestamp chain against the acquisition window. Each of the
eight handoff reports qualifies. The selected source, sink, and FGN native
records have no omissions; each JFG callback report declares complete records.
The private PipeWire library, module, and HEART plugin hashes are identical
across the eight row diagnostic cases. Perf's decoded reports and loss logs
were reviewed; raw perf binary decoding was not independently rerun.

### Handoff boundary verification

The new [handoff analyzer](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/analyze_classic_handoff.py) was reviewed
against the instrumented source, not only its labels:

- Source `R` records a monotonic timestamp after `recv` returns. Its stored
  row offset is unset; exact frame and packet ordinal order reconstructs
  offset = 11 × (ordinal − 1) for this fixed 32-packet layout.
- Source `P` is recorded after setting the buffer ID and
  `SPA_STATUS_HAVE_DATA`. Receive-to-publication includes assembly,
  admission, queue residence, scheduling, and possibly downstream
  backpressure. It is not isolated source execution or idle-exit time.
- Native `G` in `ndarray-filter.c` occurs after buffer collection/projection
  and region validation, immediately before `filter->events.process`.
  Its interpretation is a native input-ready/pre-process observation.
  `G` to the JFG body is the final callback-entry segment, not the entire
  dequeue/get path or all adapter overhead.
- Sink `C` contains `transmit_command`, but starts before metadata lookup and
  sequence bookkeeping. It also contains an optional diagnostic delay if
  configured. No such delay is selected by these recorded configurations.
  The measured sink duration therefore denotes an inclusive bracket, not
  isolated transmit-call or syscall cost. Sink `S` is a
  lifecycle Start observation and is correctly excluded from handoff timing.

No new significant analyzer correctness defect was found in the reviewed
cases. These naming/interpretation limits were sent to the primary for the
final methods and result text.

Terminal-row receive-to-publication p99 changes from approximately
1,395/755 µs to 15/15 µs for FGN at 100/250 Hz, and from 1,310/736 µs to
18/21 µs for JFG. Publication-to-body p99 is approximately 2.9–7.0 µs for
FGN and 8.5–15.8 µs for JFG. This locates a large observed off-condition
delay before publication; it does not uniquely identify the mechanism.
JFG terminal `G`-to-body p99 spans 0.370–0.591 µs; that range is not a maximum
bound (one terminal maximum is 1.333 µs).

The additional cached `terminal-publication-scheduler.json` associates each
terminal receive-to-publication interval with the unique prepared daemon
`rtc-data-loop` TID attested on CPU 0. The reviewer independently recomputed
all 2,016 intersections from the retained scheduler switch endpoints. Every
result matches the saved off-CPU and wall-minus-off-CPU values; all intervals
fall inside the observed trace bounds without censored overlap. In off cases,
off-CPU time accounts for 21.35%/16.81% of summed terminal R-to-P wall time
for FGN at 100/250 Hz and 67.03%/63.51% for JFG. These are aggregate duration
fractions, not a percentile decomposition. The remaining per-frame wall-time
p99 values are still 1,015.6/635.8 µs for FGN and 417.8/233.6 µs for JFG.
Zero-QoS cases have no FGN terminal off-CPU overlaps and only two/one JFG
overlaps. This directly establishes descheduling during part of the interval;
it leaves the remaining scheduled time and the pre-receive interval to further
investigation. The remainder may include other queued-row work, kernel and
interrupt work, instrumentation, and execution at varying performance. It
does not identify isolated source self time or a complete idle-exit delay.

All four JFG cases show zero recorded pause-count, GC-time, and allocated-byte
counter changes across their 8,064 callback bodies. The inspected code samples
these process-wide counters inside the body timestamps. This supports the
reported absence of counter changes within those brackets; it does not prove
whole-stack zero allocation, exclude activity between callbacks, or establish
an algorithm-only allocation attribution.

The retained row-work reports label their SH/MVM prefix counts as derived
under the fixed-graph and endpoint clock-envelope assumptions. With zero QoS,
all 252 frames have positive lower bounds: FGN 184 subapertures/368 columns,
JFG 166–184 subapertures/332–368 columns. Widening the clock envelope by 10 µs
retains those ranges. The off 100 Hz cases retain zero lower bounds for ten
FGN frames and one JFG frame; these are not removed. Callback completion plus
the previously reviewed synchronous algorithm supplies these counts; separate
SH/MVM kernel completion timestamps are not present.

CPR-05 is closed for this retained evidence, with failed preliminary attempts
still disclosed separately. Three finite windows and zero observed deadline
misses establish
observations for those windows; they do not establish a hard deadline bound,
rare-tail guarantee, hardware validation, or deployment policy.

## Final compact evidence check

The final [compact evidence](../benchmark/data/classic_platform_20260930.json)
was independently checked after the C/G naming corrections and dependent
analysis regeneration. Its SHA-256 at review is
`5cfc60853da8737ed32b1167217034bf5254818abceab397b47777321f813575`.
All 41 explicit path/hash references match existing retained files. Its ten
normal condition summaries exactly match the saved normal summary; its ten
diagnostic case summaries match their result, scheduler, handoff and row-work
inputs; its eight publication/scheduler aggregates match the detailed
intersection report. All handoff analyzer/input hashes and regenerated
intersection input hashes are current.

The final [methods and results](../benchmark/CLASSIC_PLATFORM.md) preserve the
reviewed measurement boundaries, independent window-percentile ranges,
preliminary failure disclosures, QoS scope, GC limitations, and unresolved
FGN elapsed-time mechanism. Their claims fit this review. The reported single
6.913 µs JFG body interruption matches the retained callback summary; the
zero-QoS JFG source-loop overlaps occur at frames 0 and 108 at 100 Hz and frame
0 at 250 Hz, consistent with the stated cold-first-frame qualification.

The retained final test log, whose reference hash also matches, reports
216 tests run and `OK`. This reviewer read that log without rerunning tests
or live experiments. No remaining finding blocks the stated finite-window
software characterization; the deployment and physical-validation limits
remain explicit.
