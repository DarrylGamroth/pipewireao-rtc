# GPI2 correction supervision — 2026-10-27

## Scope and source cohort

Work starts from RTC `8977d4d`, JFG `6f67f48`, instrument `bcbd339`
and GUI `23de559`. The JFG observer seam is `ccef7547`; the selected
scientific dependency is registered FilterGraphAlgorithms **0.8.4**, tree
`f2c56787e0a63e85ebea1fd4de5d1bca7f84b727`. Earlier source checks
used 0.8.3 and do not establish 0.8.4 performance. All selected controllers
are complete-frame CPU owners; the unchanged live plant uses CUDA.

This increment binds optional supervision to successful full-rate public
constraint-feedback products. It does not tune controller gains, physical limits,
calibration, allocation or hidden modes. Live automatic protection is **not**
enabled. Instrument defaults are provisional monitor-only diagnostics.

## Ownership and bounded execution

The existing JFG process observes each successful accepted complete frame after
output finalization and delayed-feedback commit. It borrows readonly public
outputs and the existing concrete admitted-metadata records. No arrays or sample
metadata escape the callback. Missing/corrupt/discontinuous/repeated evidence is
unavailable, never zero clipping. Header sequences retain their actual values;
persistence uses the owner monotonic clock, not model PTS.

The callback performs a finite/count reduction and bounded atomic publication.
It does not submit controls, perform I/O, log, acquire a lock or wait for a reader.
A control reader makes at most three coherent-snapshot attempts. Observer failure
is retained and disables optional observation without rejecting accepted science.
When monitoring is absent, the `nothing` observer specialization removes its path.

The headless `CorrectionSupervision.Client` reads native owner evidence on its
serialized control connection. A configured restore-reference trip enters the
existing atomic-first admitted recovery, remains Holding, and cannot close or
retry automatically. Exact owner identity and trigger freshness are checked
before the first effect; completion retains its original bounded deadline.
Local rearm stages intent for a new fresh clear frame and never changes closure.
A resident protection service and remote rearm command are not supplied here.

The measured fraction counts every declared physical constraint-feedback element
whose absolute value exceeds an explicit tolerance. Feedback can include stroke,
slew and quantization differences; this is not a pure physical stroke detector.

## Reset availability restriction

RTC session Reset advances acquisition generation and restarts source sequence
without replacing the scientific owner. Generic stopped-owner Reset does not
prove all old input buffers were drained. After trusted feedback, Reset therefore
retains trip identity and sequence high-water and makes supervision unavailable
until owner replacement. Neither a low restarted sequence nor an old higher one
can clear this fence. Explicit and pending rearm cannot clear it. Science remains
non-gating. Cold preparation before any trusted feedback does not set the fence.
Acquisition-generation-aware resumable monitoring is a separate extension.

The same reset regression fails 2 of 4 assertions at the preceding observer and
passes all 4 with the fence ([before](reset-before.log), [after](reset-after.log),
[reproducer](reset-regression.jl)). Thirteen focused reset assertions pass,
including retained trips, rejected direct
and pending rearm, unavailable lower/higher sequences and zero warmed allocation.
An independent actual `prepare!` → native first-frame check observes Clear,
sequence 1, with the reset fence unset. Invalidation without Reset remains
recoverable from new trusted feedback.

## Numerical and generated-code checks

The initial early-exit nonfinite check inhibited LLVM vectorization. Independent
Boolean finite-AND and exact integer count reductions preserve the comparisons
without relaxed floating-point semantics. Scalar-oracle tests cover NaN,
infinities, signed zero, subnormals, tolerance boundaries, shifted axes and strided
views. The observer does not add `@fastmath`, `@simd` or unchecked indexing.

Julia 1.13.3 / LLVM 20.1.8 / znver3 inspection of the actual readonly BorrowedArray
and RowMajorBorrowedArray observer specializations finds vector loads, packed
comparisons/conversions and integer accumulation. Mixed present/absent admitted
metadata callbacks have zero warmed heap allocation. Isolated reduction timing
is not a whole-controller or fixed-rate latency claim. Full prepared-graph
inspection and calibrated disconnected-controller timing are recorded separately
when their gates finish.

## Native and live functional evidence

The unchanged live GUI completed Restore reference → Holding → Allow close →
Open → explicit Close, ending RUNNING/Observed Closed. This does not by itself
prove numerical history clearing; the isolated native recovery oracle does.

Private native trial `native001` passed 37 assertions with 51 frames: a real
owner-published trip caused no monitor-only effect; expired/stale evidence
retained request token zero; fresh explicitly configured restore caused exactly
one recovery; repeated polls stayed Holding; ordinary close was refused; explicit
release/close then produced six reference frames without old correction. Private
process cleanup completed. This trial predates the reset-fence source change;
its no-reset path is supporting evidence, not the final-source gate.

Trial `native002` failed 2 of 42 harness assertions because a captured local
name was shared by source-publication and expected-recovery tokens. Actual
native recovery token stayed one. Its legacy receipt `passed` field is not an
authoritative outcome; the failing test log and exit status are preserved.
The renamed-variable rerun `native003` passed **42/42**, exit zero, on the
final reset-fenced observer. Its [receipt](native-receipt.json) and
[version cohort](native-cohort.json) identify source FGA 0.8.3, separate from the
registered 0.8.4 checks. Recovery remained token/generation one across three
Holding polls and two polls after explicit release/close. Frames 40–46 retained
reference demand 0.2 and zero feedback. Owned processes exited without cleanup
errors. Known forced-SIGTERM private
teardown warnings remain; no physical settling or shutdown qualification follows.

Cache evidence is under
`/home/dgamroth/.cache/pipewireao/gpi-operations-20261027/` and
`/tmp/correction-supervision-codegen-20261027/`. These paths are evidence only,
never deployment dependencies. Live services and the GUI remain unchanged.

## Registered 0.8.4 update

The [focused selector log](fga-0.8.4-selectors.log) passes the actual registered
biquad and pupil-flux tests plus threaded observer and native-client model checks.
Instrument commit `c3e1c60` updates only the FGA pin to 0.8.4 and adds the bounded
monitor-only policy, copied configuration binding and offline source/export tests.
All 17 source/export assertions and formatting pass. These are offline source
checks, not a new installed or live dependency cohort.

## Prepared-filter-graph inspection

The registered-0.8.4 [prepared-graph report](graph-report.json) and
[run log](graph-run.log) cover a real two-node graph: 256-mode, two-section
biquad → command conditioner, with public PDM constraint feedback and actual
native borrowed buffers. All 64 enabled/disabled frame pairs have identical
demanded/feedback bytes and committed biquad state. Both warmed native callbacks
allocate zero bytes.

Typed IR for the actual graph node statically invokes the numerical process with
`RowMajorBorrowedArray{Float32,1,false}` input and the same concrete biquad
workspace/plan signatures in both modes. The actual shared biquad stage retains
packed AVX operations (`vmulps`, `vaddps`, `vsubps`) without fused arithmetic;
the integrated monitor caller retains vector LLVM. This proves SIMD retention
for these concrete routed specializations, not all possible graphs or backends.
No whole-GPI timing or connected scheduling/Props-contention claim follows.
The full assembly, typed IR and reproducer remain in the recorded cache directory.

## Indicative calibrated GPI callback comparison

The [report](calibrated-callback-timing.json) and
[2,048 paired samples](calibrated-callback-timing.csv) use registered FGA 0.8.4,
the installed calibrated GPI graph/FITS bindings and actual disconnected CPU
native callbacks. Constant synthetic UInt16 input is identical in both owners;
it is not plant feedback. Both callbacks allocate zero warmed bytes and every
paired block has identical scientific output bytes.

Baseline median was 3.715 ms and monitored median 3.647 ms; descriptive p99
was 6.692 ms and 6.680 ms. The small negative difference is not a speedup claim: a
shared host, one process and alternating 64-frame blocks do not resolve the
monitor's small added cost. No large regression is observed in this trial. Both
monitors ended Tripped; real-clock policy phase was not held constant. This is
not arrival-rate, connected Props-reader contention, fixed-rate latency or
deadline qualification. The [harness](benchmark_callback.jl) records the setup.

Two preliminary harness issues were corrected before this reported run: an old
helper-extraction marker included unrelated tests, and captured mutable sequence
state erased the timed cursor type. The final run uses concrete measurement
functions. Earlier interrupted runs are not timing evidence.
