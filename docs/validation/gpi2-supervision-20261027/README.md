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
never deployment dependencies. These isolated trials did not change live services
or the GUI; the combined deployment is recorded below.

## Registered 0.8.4 update

The [focused selector log](fga-0.8.4-selectors.log) passes the actual registered
biquad and pupil-flux tests plus threaded observer and native-client model checks.
Instrument commit `c3e1c60` updates only the FGA pin to 0.8.4 and adds the bounded
monitor-only policy, copied configuration binding and offline source/export tests.
All 17 source/export assertions and formatting pass. These are offline source
checks, not a new installed or live dependency cohort.

## Release integration

The merged RTC software suite at `fdab742` passes **6,292 assertions in 237
testsets**, exit zero: `julia --startup-file=no --threads=3,0 --project=.
test/runtests.jl` ([log](rtc-full-suite.log)). The initial `git cat-file` diagnostic
comes from the deliberately rejected missing artifact; the suite completes.
RTC 0.2.29 raises its optional graph dependencies to registered FGA 0.8.5 and
FGPW 0.1.11. FGA 0.8.5 only promotes the existing admitted metadata record to
the public advanced API; numerical definitions remain identical to 0.8.4.
The FGPW release passes 1,932 assertions in 92 testsets, including the observer's
96 assertions. These gates precede the combined installed/live application check.

## Combined deployment checks

The combined registered application uses RTC 0.2.29
(`c4efa037e8da4d84d49a8ff1b05a33db4b636944`), FGA 0.8.5
(`442906ad123bb0f68d474ee128ca8e8e58b97849`) and FGPW 0.1.11
(`5aa920cec0ab3b8ecc24a8ea43b57bcca58eeac0`). Its environment has no
path overrides. Registered-consumer supervision selectors and all 39 optical
presentation assertions pass; the CPU instrument export passes 19 assertions.
Controller graph, parameter bindings and all 32 calibration FITS files are
byte-identical to the prior installed application. Calibration context values
are equal; its text gains the 0.2.27 writer's Generated header. A preliminary
comparison harness used a nonexistent `rtc/calibration/context.yaml` path; the
corrected verification reads `calibration/context.yaml` and checks both byte and
parsed equality. Failed preliminary logs remain in the deployment cache.

During replacement, the prior `c0bba364fde4` session's one native Quit request
expired its reply deadline. No Quit retry was sent. The exact old main process
and cgroup subsequently disappeared, systemd reported successful inactive state,
and read-only `reconcile_cleanup!` confirmed `phase=stopped`,
`cleanup_complete=true`, no cleanup errors and no retained application error.
Cleanup is confirmed; native Quit acknowledgement remains unknown. This does
not establish the cause of the reply timeout. The replacement has its own
incarnation and does not inherit the uncertain request.

The replacement is RUNNING: unit `pipewireao-session@e19fdf39bd12.service`,
invocation `47a0e5fb29e348ea8402556cdc126914`, session UUID
`7d98ecb7-1dd1-461a-848a-c3b9775bc0e0`. Its registered application is installed
under `/home/dgamroth/.local/state/pipewireao/gpi2-supervision-live-20261027/session/installed`.
The [native snapshot](live-supervision-properties.json) reports fresh Clear
observations for both physical feedback outputs. Their action is `none`, because
that field is the trip recommendation, not the configured monitor-only policy.
The first read-only verifier incorrectly required `monitor_only` while Clear;
the corrected verifier checks the installed policy and permits `none` or
`monitor_only` recommendations. It passes. No protective client runs live.
The [prior cleanup receipt](previous-cleanup-reconciled.json) retains the unknown
Quit acknowledgement separately from successful cleanup.

GUI commit `ec4e32c`, binary SHA-256
`90a2360886ea73470438e66cf96c9bc14ac2b8f526328cb1e192599541b85286`, runs in
`pipewireao-gpi2-supervision-gui-20261027.service`, invocation
`8e72839fe4894d2f9d67ca31b4bd6316`. MCP verifies RUNNING and 84 nodes.
Restore reference reaches Observed Open / “Reference reached · close inhibited”;
Close is disabled. Allow close leaves it Open and enables Close. Only the
subsequent explicit Close reaches Observed Closed. Scientific displays remain
available in the retained snapshots and final screenshot. This live cycle
supplements, rather than replaces, the isolated numerical no-old-command oracle.
The stage Settings show named X/Y coefficient selectors, Autoscale off and both
fixed ranges at ±1e-6 m OPD; the zero-centered chart and live displays were
visually inspected. GUI full tests and disconnected browser DPR1/DPR2 checks pass.
Commands, failed preliminary checks, MCP snapshots and screenshot are retained in
`/home/dgamroth/.cache/pipewireao/gpi-supervision-live-20261027/` and the adjacent
GUI release receipt. Gains, limits and selected calibration are preserved.

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

## GUI recovery across Stop/Start

GUI `178075c` fixes a client-side readiness defect: valid stopped-owner recovery
properties previously latched a permanent “Recovery readback is missing or
incompatible” error. Running observations could not clear that error for the
same owner. This was reproduced through MCP during replacement-session startup,
independently of a recovery operation. A source regression fails before the fix.

Known stopped observations now suspend recovery readiness and preserve the
operation. A resumed held/released recovery requires a newer successful-frame
observation. Genuine faults, changed owner identity, unknown outcomes and
expired operation deadlines remain faults; no request is retried. Restore
reference still inhibits closure until explicit Allow close and Close loop.
Stop/Start does not release that inhibition.

All 16 recovery tests pass, including five new Stop/Start cases; full Rust tests
pass (827 library, 200 bridge, 307 native GUI, 12 integration; existing ignored
tests retained). WASM, formatting and 151 Julia script assertions pass. Strict
Clippy remains failed on six pre-existing findings in untouched modules; a
supplemental pass allowing only those existing lint categories and deprecations
passes. The inspection-enabled release binary SHA-256 is
`7d01980a7c1d8580af918cb69ec0085cc0854019df031a6f758b1f8c145b4811`.

The failed old-GUI MCP snapshot and subsequent live checks are retained with the
package/deployment receipts in
`/home/dgamroth/.cache/pipewireao/atmosphere-axes-20261027/`.

### Live pass-after

MCP inspection of GUI `178075c` on the new registered cohort passes:

1. Open loop is observed Open; Restore reference reaches reference with Close
   disabled and Allow close enabled.
2. Stop completes, then explicit Refresh observes READY and “Correction
   processing stopped.” Recovery/release are disabled while stopped.
3. Start completes, then explicit Refresh observes RUNNING. The same owner and
   recovery operation remain Open/inhibited; fresh frame evidence re-enables
   Allow close without latching a fault or replaying Restore.
4. Allow close produces “Close permitted · loop remains open.” Only explicit
   Close loop then yields Observed Closed / “Reference recovery complete.”

The GUI deliberately marks lifecycle status stale after a Start/Stop reply;
Refresh is required before the next mutation. This existing interaction was
observed and preserved, not bypassed by trusting a mutation acknowledgment.
The [before snapshot](gui-baseline.json) and
[restored](fixed-restored.json), [stopped](fixed-ready.json),
[resumed/inhibited](fixed-running-held.json), [released](fixed-released.json) and
[closed](fixed-closed.json) snapshots retain the button states and owner identity.

A final native [status](final-status.json) and [properties](final-properties.json)
check, made with the GUI stopped to avoid overlapping client queries, confirms
Running/Closed, no correction fault, recovery released and no remaining closure
inhibition or close guard. Both native clipping monitor observations are fresh
([assertion output](verify-final.log)). The GUI was then relaunched and attached
for operator use, with the prior layout and hardware rendering preserved.

The final session is
`pipewireao-session@c6b4bd92c462.service`, invocation
`d6374d08a47540ee958c7a65d0366843`, UUID
`6dc4e0d2-7c09-4f89-9e6b-271f0771a817`. Discovery contains only its live record.
The installed policy remains monitor-only. Both replaced RTC incarnations
acknowledged native Quit and completed cleanup; no shutdown retry was sent.
This validates the bounded simulated GUI interaction, not hardware-safe settling,
latency or all fault conditions.
