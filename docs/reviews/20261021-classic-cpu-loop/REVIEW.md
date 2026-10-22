# Managed Classic CPU loop review — 2026-10-21

Status: source, remediation and retained-evidence verification complete. The
finite managed CPU result is accepted within the scope below; the initial
native Quit failure remains unresolved and preserved.

This independent, bounded review covers the test-only managed Classic replay
harness, its shared direct controller oracle, and the optional observer hooks.
The reviewed worktree is
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-classic-cpu-validation`,
branch `codex/classic-cpu-validation-20261021`, starting at
`54cfabd9503de57f1cc0a13e0edea9261c6106b8`. At entry, the observer and finite
replay files had task edits; the managed and shared replay files were untracked.
The reviewer did not change executable code or operate live services.

## Source conclusions

- **Observed:** `capture_session` uses `SessionRuntime.start!`, native status,
  start and stop requests, and `shutdown!`. This exercises the managed headless
  application. The final harness creates only exact optional queue-output links;
  the session remains the science lifecycle authority. The new observer keywords
  preserve the existing default callback, completion condition and lifecycle.
- **Observed:** the shared `ClassicReplay` retains the former finite replay's
  controller preparation, warmup/reset, row-major detector reconstruction,
  feedback update and exact Float32 command comparison. It calculates new
  controller output from recorded detector data rather than copying recorded
  demands into the expected output.
- **Observed:** the direct plant steps frame n, checks its independently
  generated UInt16 detector payload, measures pupil OPD, then adopts command n.
  The released AOS boundary applies that command to frame n+1. There is no
  same-frame command insertion into the compared detector image.
- **Observed:** demanded micrometres are multiplied by Float32(10⁻⁶), matching
  the HIL transport-to-plant conversion. Applied observations are compared to
  the inverse conversion, preserving its Float32 rounding. The selected
  application declares the same command scale.
- **Derived from source:** two fresh plants use identical configuration,
  atmosphere seed 1, detector seed 0 and warmup/reset. The second retains its
  initial zero command. Both metrics remove pupil piston over the same telescope
  mask. Comparing means over frames 129–256 therefore measures correction
  against a matched zero-command realization, not a different atmosphere.
- **Observed:** native Quit is attempted once, with an exact-owned-unit stop on
  failure. Normal completion checks the retained cleanup receipt, process
  incarnation and cgroup emptiness for the RTC and owners. GPU library mapping
  checks cover live owners; the direct replay checks loaded GPU packages and
  libraries. These are scoped software checks, not hardware qualification.

The replay is independent of transport execution, not an independent physical
model validation. It reuses the same released scientific algorithms. Even a
successful run establishes only the selected finite seeded CPU scenario; it
does not establish cadence, latency, long-run stability, hardware behavior or
GPU behavior. A complete finite prefix is an observed acceptance condition at
slow wall pacing, not a losslessness guarantee for the display queues. Applied-command
observations may be subsampled, but must include the final exchange and at least
two distinct samples. Every retained applied sample is checked against its
corresponding Header sequence, timestamp and converted demand. Acquisition
domain/generation identity is required on detector and demanded products;
the released optional applied-command source does not publish it.

## Findings

### CCPU-01 — Success receipt emitted before test failure propagation

Severity: medium. Confidence: high. Classification: confirmed defect in evidence
emission. Disposition: corrected; independently verified in source and a focused
failure-path experiment.

Affected code: the initial `test/integration/classic_managed_replay.jl` wrote
`science-result.json` inside its outer `@testset`, with `complete=true` and both
exact-replay fields unconditionally true. Julia's ordinary `@test` records a
failed assertion and continues; the enclosing testset raises only when it
finishes. An unequal replay, failed improvement or failed cleanup/GPU check
could therefore leave a success-labelled receipt even though the process later
exits unsuccessfully.

Evidence: a Julia 1.13.2 stdlib-only experiment executed `@test false`, printed
`REACHED_SUCCESS_REPORT_WRITE` later in the same testset, and then raised
`TestSetException`. The initial harness had the same ordering.

Remediation: the final source saves raw payloads, identities and payload hashes
after collection and before replay assertions. It constructs the candidate
report inside the testset, then writes the success receipt only after the
complete enclosing testset returns successfully. Application asset and harness
hashes are checked again before acceptance. Independent source inspection and a
Julia 1.13.2 stdlib experiment confirm a failed testset cannot reach the later
success-emission statement. Runtime success and its receipts remain pending.

### CCPU-02 — Observer readiness required activation before native Start

Severity: medium. Confidence: high. Classification: confirmed harness-only
startup deadlock. Disposition: corrected in source; live pass-after demonstrated
by `closed-loop-002` reaching native Start and Running.

Affected code: the initial optional `on_ready` branch in
`test/integration/classic_observation.jl` required every observer link to be
Active before invoking the callback that sends native session Start. The held
JFG command producer legitimately keeps its observer link Paused until Start.
The new harness therefore waited for a state that its own callback had to
enable. The wait is bounded by 120 seconds, after which owned cleanup runs.

Evidence: the retained `observer-held-diagnostic.json` under
`/home/dgamroth/workspaces/codex/worktrees/classic-cpu-validation-20261021/`
has SHA-256
`43eacd2874c8d2197e293c0b38856066964bd7bd94ee74e15b0d9199ec626f10`.
Independent inspection shows detector link 151 Active, demanded link 152 Paused
and applied link 153 Active, with no link errors. All three links and observer
input ports have the expected negotiated element type, shape, row-major layout
and schema. This establishes a negotiated held observer, not a format failure.

Remediation: the gate still requires current link information and each exact
negotiated capture format, while accepting either Paused or Active. Native Start
remains caller-owned and outside the native loop lock. The normal observation
path and its Active-only driver requests are unchanged. The revised predicate
accepts the recorded held state. The next run's log records observer negotiation
followed by native Start, and its start receipt reports Running. Its later
collection timeout is the separate CCPU-05 finding.

### CCPU-03 — Failed Quit fallback obscures the original harness failure

Severity: medium. Confidence: high. Classification: confirmed harness cleanup
diagnostic defect. Disposition: corrected and independently verified in source.

In `closed-loop-001`, the observer's held-state timeout entered the harness
`finally` block. Native Quit then reported an unknown outcome because its owner
proxy was removed. The unconditional fallback `SessionRuntime.stop!` rejected
the already-deactivating manager as inactive. The test consequently reported
the fallback identity error as its primary exception; the original observer
failure and uncertain Quit survive only in the nested exception chain and
separate receipt. That fallback also skipped bounded cleanup reconciliation.

Remediation: preserve original and cleanup failures in order. Reuse the bounded
helpers in `test/integration/session_faults.jl`, loaded in an isolated module:
they validate the exact manager incarnation, stop only an exact active manager
without an existing stop fence, and otherwise observe existing policy shutdown.
The final harness loads those helpers in an inert isolated module, retains
original and cleanup exceptions in order, and throws a `CompositeException`
after cleanup. An unknown Quit remains failed even when cleanup subsequently
succeeds; native Quit is not retried. Partial payloads are saved on collection
failure when all three captures have been constructed.

### CCPU-04 — Initial-run native Quit expired; initiating mechanism unresolved

Severity: medium. Confidence: high for the observed failure, undetermined for
its initiating mechanism. Classification: runtime failure requiring
discrimination, not a confirmed production source defect. Disposition: retain
as failed evidence and investigate if reproduced by the corrected harness.

Exact initial manager: `pipewireao-session@2e08f7698dac.service`, invocation
`f51096a5755b46feb3b6c017376fc9a1`. Its ready receipt reports Ready, and no Start
was sent before the observer timeout. Native Quit was attempted once and its
saved attempt remains `accepted=false`.

Observed journal ordering on 2026-10-21 (host local time):

- 16:42:36.030: simulator owner process accounting/exit record.
- 16:42:37.120167: internal session effect expired, outcome unknown.
- 16:42:37.120264–.120309: fault compensation, two null-property assertions,
  then a source-hold attempt fails with `Missing object serial`.
- 16:42:37.247891–.280601: RTC connection lost, process exit status 69.
- 16:42:37.668708/.812249: graph/parameter owner process accounting records.

Source-derived conclusions: `ao/session.lua` caps a requested operation at five
seconds independently of the larger client cleanup deadline. Quit sequentially
holds the source and graphs, withdraws links, shuts down source/owners, releases
the controller endpoint and waits for exact client removal. The generic expiry
message does not identify the active phase. Graph/parameter process exit records
are after expiry; the logs do not establish that every owner completed shutdown
before the deadline. The missing source serial is a subsequent compensation
attempt against an already-removed source, not evidence of the initiating
failure. Neither a client-removal wait defect nor resource contention is
established by this evidence.

The retained exact invocation's `launch.json` subsequently reports
`cleanup_complete=true`, `phase=failed`, and `service_result=exit-code`. This is
cleanup recovery, not successful native Quit qualification.

Cheapest next discriminator if the corrected run reproduces: one isolated
Ready→Quit trial without concurrent cold startup, recording monotonic quit-phase
entry, owner request/acknowledgement, controller release and exact client-removal
timestamps. Use temporary investigative instrumentation or existing dispatcher
tracing; do not change deadlines or production behavior speculatively. A
no-observer versus attached/retired-observer comparison is useful only if that
first isolated trial does not reproduce the failure.

Follow-up: `closed-loop-002` completed native Quit successfully after entering
Running. Its receipt has `accepted=true`; its final ledger has
`cleanup_complete=true`, `phase=stopped`, `service_result=success`, and no error.
This does not reproduce CCPU-04 and supports only the observed finite functional
shutdown result. The initiating cause of run 001 remains unresolved; five-second
shutdown reliability is not qualified.

### CCPU-05 — Lossy display queues were required to retain every exchange

Severity: medium. Confidence: high. Classification: confirmed harness acceptance
error. Disposition: direct-tap experiment rejected; complete run-005 capture
through unchanged display queues verified at requested 1 Hz wall pacing.

The original harness required all 256 samples from capacity-one copy/drop-oldest
queues. `closed-loop-002` reached Running but timed out with 250 detector, 250
demanded-command and 251 applied-command distinct samples. Such queues permit
drops; they cannot establish a complete replay prefix by contract.

The run-003 experimental harness used `node.reliable=true`, non-driver direct detector
and JFG demanded-output taps, matching the maintained finite replay's capture
pattern. It retains the ordinary optional applied-command queue and permits
subsampling there. Default observer behavior is unchanged. All 256 reliable
detector and demanded samples remain mandatory; exact plant/controller replay
still checks the entire finite prefix. The documented acceptance scope excludes
optional-observer invariance and timing because reliable taps participate in
delivery. The managed headless application still owns all required application
links and science lifecycle transitions.

The revised capture configuration failed in `closed-loop-003`, so it is not
accepted as a reliable continuous capture solution. Both persisted detector and
demanded prefixes contain sequences 1 and 3; sequence 2 was already missing.
The AOS owner reported `wfs_frame.sequence: sequence 4 did not complete before
the development timeout`; required-link removal and session Fault followed.
The native HIL source waits for its publication marker before command receipt,
so this symptom localizes the immediate failure to frame-4 source publication,
not its controller computation. The evidence does not distinguish an omitted
source callback, unavailable source buffer, or a related transport-credit
condition.

An additional difference from the maintained finite replay is consequential:
that harness waits for both recorder sequence/count values after every
`exchange_frame!` and before advancing the next frame. Its success therefore
does not prove that identical tap declarations retain continuously managed
frames. `node.reliable=true` on a consumer alone also does not establish a
lossless producer-output contract.

For a bounded investigative comparison, match the old direct tap's fixed three
buffers, no explicit loop name, no format-callback buffer reannouncement and
original connection flags, retaining format validation. This is a comparison,
not an established fix. Native non-RT stream setup supplies
`node.loop.class=main`; current loop selection prioritizes that class, making
the explicit loop name alone a weak causal candidate. The cheapest decisive
trace records source process invocation/dequeue success and tap received and
returned buffer IDs/sequences for the first eight frames. That separates
callback omission from pool-credit retention and lost sequence delivery.

The final run-004 harness removes the direct-tap extension entirely. It retains
the capacity-one queue declarations, invokes collection and completion
predicates while held to compile those calls before native Start, and uses a
separately sealed candidate with requested wall pacing of 1 Hz. The 500 Hz model
cadence, 256 steps, science, calibration and exact replay requirements remain
unchanged. This gives the collector more wall time; it does not establish why
run 002 missed samples or guarantee losslessness. The unsuccessful direct-tap
experiment remains preserved and is not part of final acceptance.

### CCPU-06 — Lazy CUDA import crosses the current function's world age

Severity: medium. Confidence: high. Classification: source-derived regression
in the optional finite replay CUDA branch. Disposition: corrected and
independently verified in source.

The CPU extension to `classic_finite_replay.jl` imports CUDA using `@eval import
CUDA` inside `main`, then directly calls newly loaded CUDA methods and extension
dispatch from that older function world. A fresh Julia 1.13.2 experiment using
the equivalent `@eval import Dates; Dates.Date(2026,1,1)` inside a function
raises `MethodError` with methods too new for the current world. The CPU branch
is unaffected; this is not a GPU runtime test.

Load CUDA in a cold wrapper before invoking the dependent main implementation,
or invoke the entire dependent continuation in the latest world. Wrapping only
`CUDA.functional` leaves later allocations, device queries and newly loaded
extension methods exposed. Verify the control-flow boundary without introducing
CUDA into the CPU path, and retain actual CUDA execution as untested here.
The final wrapper now conditionally imports CUDA, then invokes the full
`run_replay` continuation through `Base.invokelatest`; independent inspection
confirms this covers subsequent optional-backend calls and extension dispatch.

### CCPU-07 — Applied observation incorrectly required Acquisition metadata

Severity: medium. Confidence: high. Classification: confirmed harness contract
error. Disposition: corrected in source; retained-capture offline validation
passed and independently reviewed.

The released HIL 0.2.2 `src/applied_command.jl` declares only ndarray format,
buffers and Header metadata for `PreparedAppliedCommandSource`. Its state owns
sequence and source publication PTS, with no acquisition domain/generation.
The callback writes the adopted command divided by Float32 command scale and
`BufferHeader(0,0,pts,0,sequence)`. Requiring an applied `AcquisitionIdentity`
therefore exceeds the actual public observation contract.

`closed-loop-005` captured all 256 detector, demanded and applied samples, then
its original testset reported 2,603 passes and 256 failures. Independent log
inspection confirms every failed expression is the unsupported applied versus
detector Acquisition-identity equality. The original failed harness and log
must remain failed evidence.

Independent read-only checks of retained run-005 evidence establish:

- All three seen masks contain 256 samples; detector and demanded Acquisition
  identity arrays match exactly, including sequences 1–256.
- All three PTS arrays match. Applied Acquisition identities are consistently
  absent, as the source contract permits.
- Recomputed payload hashes match the capture's `observation.json`.
- A fresh stdlib Julia check confirms all 277 × 256 applied values equal
  `(demanded × Float32(10⁻⁶)) / Float32(10⁻⁶)`, demand is finite and nonzero,
  and the detector payload has the expected byte length.
- Native Quit has `accepted=true`; final cleanup has `cleanup_complete=true`,
  `phase=stopped`, `service_result=success`, and no error.

Correcting the applied assertion to its Header sequence/PTS and unit-scaled
payload contract does not weaken the mandatory detector/demanded Acquisition
checks. Revalidating the same preserved prefix offline is appropriate without
repeating native controls: verify payload/metadata provenance, rerun the complete
controller and direct plant comparisons, then emit a separately identified
offline-verification receipt only after its testset succeeds. Do not relabel
the original complete harness as passing or claim a new managed capture.

The final `verify_science` factor retains the same controller and plant oracles.
`classic_saved_replay.jl` checks saved byte sizes and payload hashes, candidate
provenance, native lifecycle/cleanup receipts and retained metadata stability.
It reconstructs only the saved PTS field; Header sequence association comes from
the original capture's sequence-indexed columns. It does not invent absent
Header fields. Its success receipt is emitted after its testset completes.
That offline testset passed all 2,846 assertions. Independent checks additionally
confirmed every payload, retained metadata, frozen collection-source and current
verification-source hash in the receipt, and every candidate application hash.

## Reviewed source snapshot

The remediation review inspected these SHA-256 values; later changes require
reconciliation before claiming exact-source runtime verification:

| File under `test/integration/` | SHA-256 |
| --- | --- |
| `classic_managed_replay.jl` | `cf13b85811ad9cc33660aa270e5a8da1fe41c7a41906d0d71f931a3919ad97a0` |
| `classic_observation.jl` | `29a56734bfdf022e62092cd4ad6b851dfa1f4638ccb31be946f51bbce1278ef6` |
| `classic_replay.jl` | `ea0b4f5a5a2aacfb5d20157e19764754f54f29ed7b90041424119bbf55dcc44c` |
| `session_faults.jl` | `be57020d2726ba4b3b16d227242378b7a4fe903d666ce8bb4987b62a0450d2a7` |
| `classic_finite_replay.jl` | `a92226d828f213789d55471c21712df81b75f8f02830f4056778e637ca02c76a` |
| `classic_saved_replay.jl` | `e01beb55f2b083b75cadefdd4f95a826af93154584f93c992afd555a95c41ffa` |

## Runtime evidence

Accepted evidence root:
`/home/dgamroth/workspaces/codex/worktrees/classic-cpu-validation-20261021`.
The selected candidate is CPU, 480-pixel pupil, 500 Hz model time, requested 1 Hz
wall pacing, and 256 exchanges. The managed capture is `closed-loop-005`; its
separate successful science receipt is `offline-verification.json`. The original
managed test result remains 2,603 passes/256 failed assertions as described in
CCPU-07. The frozen original harness is retained under `collected-005-harness`.

| Evidence | Observed result |
| --- | --- |
| Corrected offline controller and plant replay | 2,846/2,846 assertions; all 256 frames and commands exact |
| Native lifecycle | Ready → Running → Ready; native Quit accepted; final stopped/success ledger |
| Phase and cleanup verification | 808/808 assertions; complete 256-row phase record; owner PIDs absent |
| CPU private replay, 16 frames in none/normal/slow/churn observer modes | 1,327/1,327 assertions |
| Actual link-removal fault | 41/41 assertions; policy shutdown, complete cleanup and fresh Running readmission |
| Actual controller-exit fault | 124/124 assertions; held outcome, complete cleanup and fresh Running readmission |
| GPU exclusion | Live RTC/core/scientific owner mapping audits empty; offline GPU package/library checks passed |

The accepted capture's UUID is `f356f32b-59fb-4698-bf01-e4ce03afca2f`, manager
`pipewireao-session@837201799ae3.service`, invocation
`c87b8e34d2ee484392c0855f58351d35`. Independently inspected Ready, Start and Stop
receipts all match that UUID. The Quit attempt is accepted; the final ledger
reports complete cleanup, phase `stopped`, service result `success`, and no
error. All recorded owner PIDs are absent. The captured phase record has 256
entries; its one-second period is wall pacing, distinct from the 2 ms model step.

For frames 129–256, corrected mean piston-removed pupil OPD RMS is
51.0335799846 nm versus 281.0460990579 nm for the matched zero-command plant.
The ratio is 0.1815843741, approximately 81.84% lower. The reviewer independently
recomputed both means from the receipt's complete RMS arrays, agreeing within
floating-point summation rounding.

This supports the requested finite managed CPU functional/scientific comparison
and the two observed fault/readmission cases. It does not establish losslessness
of optional display queues, 500 Hz wall performance, cadence/deadline or
all-load shutdown reliability, long-run stability, independent physical-model
validity, hardware behavior or GPU execution. CCPU-04 remains an unresolved
initial-run shutdown failure; failed run 003 remains an unaccepted direct-tap
experiment. Neither has been silently converted into successful evidence.
