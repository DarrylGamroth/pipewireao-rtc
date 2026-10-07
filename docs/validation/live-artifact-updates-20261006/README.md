# Live artifact update checks

Date: 2026-10-06. RTC starting revision `8a5e3bf`; worktree
`/tmp/rtc-live-artifact-updates-20261006`, branch
`work/live-artifact-updates-20261006`. The starting worktree was clean.
The selected work is artifact loading, native controls and frame-boundary
adoption; completed calibration campaigns are reused within their own scope.

## Observed CPU allocation and numerical results

Both probes use Julia 1.12.7, CPU15, one Julia/BLAS thread, GC enabled,
offline dependencies and existing compiled modules. Their package environment
is `/tmp/copper-jfg-main-noobs-v2-installed/jfg/deployment`.
The installed scientific/executor source hashes agree with JFG main
`b60911697c9439f83897d79492e93a5324edb05a` for the measured paths.
Exact package versions and source hashes are in the logs.

After 32 warming sequences, each allocation measurement has 64 samples through
a concrete function barrier. Numerical assertions are outside the allocation
measurement. No production source was changed.

| Probe | Warmed adoption | Adoption plus graph processing | Control preparation |
| --- | ---: | ---: | ---: |
| ClosedLoopCorrectionF32 scalar gain | 0 B | 0 B | 2,144 B/update |
| ClosedLoopCorrectionF32 projection parameter | 0 B | 0 B | 1,712 B/update |
| Heterogeneous graph scalar gain | 0 B | 0 B | Measured separately in the log |
| Copper PyramidPupilReconstructorF32 matrix | 0 B | 0 B | 3,644,376 B/update |

Both admitted and checked public graph processing also measure 0 B after
warmup. The small controller probe checks 385 recurrence/output cases, and
the heterogeneous graph checks 128 output cases.

The Copper probe uses the actual row-major F32 calibration matrix, shape
253 × 3,600, SHA256
`8cfeba562c55ff99de362e77d5046cbb1d4011c21bce334b93ab50912596c043`.
Its one-node graph uses four pupils with 900 selected pixels per pupil and
253 controller residual coordinates. Same-shape matrices alternate between
scales 1 and 0.99. All 290 output comparisons with an independent Float64
scalar calculation pass; maximum absolute error is approximately 6.15e-5
within the probe's declared relative bound. Output norms change from 506.77902
to 501.71118, so this is not a comparison of identical or clipped outputs.

Reproduce against the retained installed package:

```sh
taskset -c 15 env JULIA_PKG_OFFLINE=true JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
  julia --compiled-modules=existing \
  --project=/tmp/copper-jfg-main-noobs-v2-installed/jfg/deployment \
  docs/validation/live-artifact-updates-20261006/copper-reconstructor-probe.jl
```

The [controller probe](control-adoption-probe.jl) and
[log](control-adoption-probe.log), and the
[Copper matrix probe](copper-reconstructor-probe.jl) and
[log](copper-reconstructor-probe.log), retain the exact calls and checks.
The controller probe additionally needs the JFG test fixtures at its recorded
canonical repository path. These are investigative probes, not deployed tools.

## Native GUI control check

The repaired GUI test passes gain updates, same-file reconstructor publication,
separate active-generation observations, typed negative controls and reconnect
against the installed recorded Copper FGN graph. The transient user service
stops, its runtime is removed, the installed package is unchanged and unrelated
sessions are preserved. The [passed receipt](native-control-smoke-passed.json),
[client trace](native-control-smoke-passed.log) and
[build identity](native-control-test-build.json) bind this result.

The repair is test-only, merged to GUI main as `3cebf28`. The native protocol
permits a known failed Completion without a runner snapshot; the former test
incorrectly required one. The test now requires fresh Status after that failure
and still compares it with the independently known previous runner identity.
Four focused identity tests pass. Success replies without identity and refreshed
Status from a different runner remain failures. No production adapter, graph or
scientific algorithm changed. This functional test publishes the same matrix
bytes and does not establish numerical update effects, allocations or timing.

## Preserved initial GUI failure

An existing GUI native client was also tried against the recorded installed
Copper FGN fixture `/tmp/gui-recorded-duplicate-peer-v1-installed`, using its
actual `control:gain` property. Initial live properties and requested/active
generation queries pass. The rejected-command loop then fails because the
client expects a session identity that is absent from a reply; it stops before
the accepted gain and reconstructor updates. This is a preserved failed smoke
check, not an adoption pass or a confirmed executor defect. The newer frozen client showed the same test assumption. Source inspection and
the repaired test establish the accepted-error contract described above.
The [receipt](native-control-smoke.json) and
[client trace](native-control-smoke-failed.log) retain the observation.

## Complete Copper live updates

Four independent installed runs pass: CPU JFG baseline and updates, CPU FGN
baseline and updates, each with CUDA AOS, 512 consecutive command exchanges,
independently observed native completion, and successful owned-session cleanup.
The model/exposure period is 2 ms; closed-loop wall pacing is 100 Hz. This is a
finite functional check, not a fixed-arrival throughput or deadline experiment.
The [summary](live-update-summary.json) links exact hashes and measured scopes.
All original calibration arrays are identical across these fixtures.

The update runs submit gain `0.0125f0` and a same-shape 253 × 3,600 reconstructor
containing the original Float32 coefficients multiplied by `0.99f0`. Requested
and active generations are queried separately; gain and parameter updates leave
the other generation unchanged. An integer gain is rejected without changing
active properties or either generation. Every subsequent Status remains Running
until the committed source completion. No live JSON control is used.

| Recorded prefix (256 frames) | JFG baseline | JFG updates | FGN baseline | FGN updates |
| --- | ---: | ---: | ---: | ---: |
| Publication → adopted command p50 (µs) | 1,058.049 | 1,059.987 | 1,057.901 | 1,059.834 |
| Publication → adopted command p99 (µs) | 2,058.351 | 2,047.469 | 2,060.299 | 2,063.312 |
| Maximum (µs) | 2,059.472 | 2,063.419 | 5,062.212 | 2,082.158 |
| Completed commands in full run | 512 | 512 | 512 | 512 |

These intervals end when the simulator receives/adopts the command and include
adapter polling/wakeup. They are not isolated RTC computation/egress time and
cannot be compared directly with previous terminal-WFS-packet → DM measurements.
One run per case does not establish a change in the tail distribution. The
baseline FGN outlier also prevents describing update time as the only source of
variation. JFG callback-body p50/p99 are 196.177/357.949 µs in the baseline and
212.048/459.812 µs with updates (512 traced callbacks per case).

### Numerical replay and unclipped effects

The offline checker carries controller state and delayed clipping feedback
chronologically through the full public JFG graph. Native submission and active
observations bound asynchronous adoption; candidate frames are searched using
nonnegative prefix error as a lower bound. The saved search records prove the
global minimum and retain ties, without imposing a new scientific tolerance.

| Case | Best gain / matrix frame | Maximum output difference from JFG replay | Exact trajectory matches |
| --- | --- | ---: | ---: |
| JFG baseline | Neither changed | 0 m | 1 |
| JFG updates | 137 / 233 | 0 m | 1 |
| FGN baseline | Neither changed | 4.9534e-12 m | 0 |
| FGN updates | 139 / 234 | 5.0022e-12 m | 0 |

All 277 × 256 recorded JFG values match bitwise, including both updates. FGN's
approximately 5 pm differences are characterized, not relabelled as bitwise
or scientifically accepted equivalence. Its fitted adoption indices are not
direct frame-boundary instrumentation. No best-fit adoption ambiguity remains.
The same-ADC-input counterfactual without updates differs by up to 0.040079 µm
(JFG) or 0.039946 µm (FGN reference); preclip requested and demanded commands
both change. Requested-minus-demanded is zero throughout these prefixes, so
clipping does not conceal the update effect.

The four [JFG baseline](jfg-baseline-replay.json),
[JFG updates](jfg-updates-replay.json), [FGN baseline](fgn-baseline-replay.json)
and [FGN updates](fgn-updates-replay.json) reports bind retained input hashes,
source/package identities, candidate search and per-frame errors. Their paired
`*-receipt.json` and `*-prefix.json` files preserve actual live responses and
publication/reception timing. Raw ADC/command payloads remain at their recorded
experiment paths; they are not duplicated in Git.

### Allocation boundaries

The separate warmed/reset full public JFG `process!` replay measures 0 B for
every frame in all four cases. FGN replay uses JFG as its numerical reference:
that allocation result does not measure the Rust allocator. Earlier minimal
probes separately measure warmed adoption at 0 B.

The JFG baseline's process-wide callback trace observes 0 B and zero GC pauses
throughout the measured run. The update trace observes 4,210,552 process-wide
bytes and zero GC pauses. One callback interval overlaps 29,312 process-wide
bytes; this interval alone cannot attribute those bytes to the frame task,
because the control worker shares the process. Cold matrix/property preparation
allocates and must remain separately accounted for. All four simulator tails
(last 256 exchanges) measure zero Julia heap bytes, GC pauses and GC time.
Those simulator counters do not measure FGN/JFG callback allocations.

Two allocation-profile diagnostics complete 512 exchanges but fail shutdown
while serializing their post-stop recordings. The first expands a deeply nested
type; the second still repeats complete stacks for every sample, producing a
1.1 GiB partial report. Both failed receipts/logs are retained as
`allocation-profile*-failed-*`; neither partial recording supports an allocation
claim. Their large temporary TSVs were removed after recording hashes. The
writer now aggregates every captured sample by frame, parameter preparation,
property control or other stack, preserving frame allocation sites separately.
The [positive control](allocation-writer-positive-control.jl) deliberately
allocates in both frame and parameter-preparation functions and correctly
reports those categories (2 samples/96 B and 2 samples/128 B). This verifies
that the classifier can detect a nonzero frame result.

The aggregate repeat [passes](allocation-profile-passed-receipt.json), with
512 delivered commands, observed active updates, successful shutdown/cleanup
and no GC pause in its measured 512-callback span. Capture at sample rate 1.0
contains 440,504 allocations: zero samples/bytes with identified frame/adoption
stack roots, 8,883 property-control samples (696,749 B) and 431,621 other samples
(22,721,735 B). The latter includes startup/control work and is not fully
attributed. Capture starts after owner preparation and includes the initial
unmeasured run and bootstrap waiting. The writer and native C/Rust allocators
are outside that capture. Raw profiler timestamps are not claimed to be
nanoseconds or aligned with the callback clock.

The [attribution summary](allocation-profile-passed-summary.json),
[category counts](allocation-profile-passed-allocation-summary.tsv),
[frame sites](allocation-profile-passed-allocation-frame-sites.tsv) and
[callback trace](allocation-profile-passed-callbacks.csv) retain the result.
The measured process-wide allocation span is again 4,210,552 B, while frame
stack samples are zero. This supports the distinction between prepared-frame
processing and concurrent control/startup activity. Profiler timing is excluded
from the baseline/update table. The successful report is a few hundred bytes
plus its callback trace, replacing the discarded large partial dumps.

### Reproduction and harness checks

The development-only `benchmark/prepare_graph_update_fixture.py` copies and
seals existing installed packages; it never edits their science arrays. For FGN
it reuses the existing native algorithm bundle, graph, placement and session
with the current SDK and identical JFG plant/calibration. No new Rust algorithm
build is required. Production qualification and numerical replay are Julia:

```sh
# Run from the RTC repository; use fresh outputs and the full admission envelope.
taskset -c 2-15 env JULIA_PKG_OFFLINE=true OPENBLAS_NUM_THREADS=1 JULIA_NUM_THREADS=1,0 \
  julia --startup-file=no --compiled-modules=existing --project=PACKAGE/julia \
  deployment/qualify_graph_updates.jl PACKAGE RUNTIME EVIDENCE \
  revolt-copper-jfg-frame-graph correction reconstructor updates

# Numerical replay uses the exact installed JFG project and SDK load path.
JULIA_LOAD_PATH="PACKAGE/julia:@:@stdlib" taskset -c 8 \
  julia --startup-file=no --compiled-modules=existing --project=PACKAGE/jfg/deployment \
  deployment/hil/check_graph_updates.jl --package PACKAGE --receipt RECEIPT \
  --report EVIDENCE/run-1/simulator-result.json --output FRESH_REPLAY_DIRECTORY
```

Use FGN graph `revolt-copper-fgn-frame-graph`, property node `control` and
parameter port `reconstruct:reconstructor` for its live run. Both replays use the
installed JFG numerical reference. `baseline` omits the scientific mutations.
Pin the coordinator to CPU6 only after the child launcher has inherited the full
placement envelope; restricting the initial parent to CPU6 prevents admission.
The harness stops the initial preparation run, compiles its own coordinator,
queries read-only controls, resets to a new source generation, verifies paused
sequence zero, then releases the measured run. Owner update preparation is not
pre-submitted or hidden by that coordinator warmup.

Focused tests pass 32 qualifier assertions and 33 numerical-checker assertions.
Initial affinity, coordinator compilation/API and FGN SubString argument errors
were harness failures corrected before the four passing runs. They are not
scientific/executor defects or discarded failed capacity tests.

Interaction-matrix acquisition and reconstructor construction remain cold
calibration work. The RTC consumes the resulting reconstructor parameter; this
check does not imply that the graph consumes an interaction matrix directly.
