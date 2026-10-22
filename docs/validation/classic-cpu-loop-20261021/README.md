# Classic CPU closed-loop and fault validation — 2026-10-21

This campaign exercises the registered Classic CPU plant and CPU JFG controller
through the headless RTC with upstream libwireplumber built against PipeWireAO.
The normal Classic CUDA application is preserved. Artifact-management work
remains paused. No GPU backend or GUI is started.

## Results

| Gate | Result | Evidence |
| --- | --- | --- |
| Managed 256-exchange CPU capture, native Stop/Quit and cleanup | Complete capture; original harness rejects an unsupported optional metadata requirement | [Observation](managed-005/observation.json), [native cleanup](managed-005/final-launch.json), [original failed log](managed-005/failed-closed-loop-005.log) |
| Corrected offline revalidation of that same capture | 2,846/2,846 assertions; exact controller and noisy detector replay; 281.05 → 51.03 nm mean pupil OPD RMS | [Log](managed-005/offline-revalidation.log), [separate receipt](managed-005/offline-verification.json) |
| Read-only exchange ordering and final cleanup | 808/808 assertions, including every frame-before-adoption ordering and retained partial-run cleanup | [Log](final-verification.log), [receipt](final-verification.json) |
| Required link removal | 41/41 assertions; Fault and policy shutdown, complete cleanup, fresh Ready → Running and cleanup | [Log](fault-link.log), [receipt](fault-link/qualification.json) |
| Controller exit | 124/124 assertions; stopped-source acknowledgement in Fault, complete cleanup, fresh Ready → Running and cleanup | [Log](fault-controller.log), [receipt](fault-controller/qualification.json) |
| Separate private-core CPU composition | 1,327/1,327 assertions; exact 16-frame replay in no/normal/slow/detach-reattach observer modes | [Log](private-replay.log), [record](private-replay.toml) |

Each fault case starts only fresh isolated cohorts. Link removal names the exact
injected registry identity before any later source timeout. Controller exit
signals only the verified `julia` owner's exact unit/process. The receipts retain
expected fault service results, complete process/cgroup cleanup, fresh session
and owner incarnations, and both GPU-library audits. The injected link-loss case
cannot acknowledge a source Hold while its command is lost; the native policy
correctly requires emergency cleanup rather than fabricating a stopped ACK.

The private-core test is additional scientific/observer evidence. It builds its
own controller and links and does not qualify headless RTC ownership. The managed
test separately uses `SessionRuntime.start!` and ordinary native session controls.

## Scientific and deployment scope

The source application is canonical Classic `934b9db3e696c9f8ac31db16f833c27bba646bd1`
and the headless RTC source is `54cfabd9503de57f1cc0a13e0edea9261c6106b8`.
The deployed registered RTC is private candidate 0.2.1; AOS 0.2.2, shared HIL
0.2.2 and Classic 0.2.4 are unchanged. Julia is 1.13.2. The selected native
prefix is `~/.local/opt/pipewireao-classic-headless-20261021`; its upstream
WirePlumber build omits the two optional fixes. [Native hashes](native-sha256.txt)
retain the actual selected files; the prefix retains the previously documented
host/symlink dependency limitations and is not a hermetic native closure.

The sealed CPU candidates preserve the manifest, controller, matrices,
projections, gains, offsets, 480-sample pupil, five-layer atmosphere, 352 × 352
noisy detector, 277-actuator provisional Gaussian mirror, 500 Hz model period and
1.896 ms exposure. Only the simulation configuration, deployment identity and
owner GPU visibility/phase-capture arguments change. The
[fault candidate](application-fault-provenance.json) uses 10 Hz wall pacing.
The final [managed candidate](application-closed-loop-wall1-provenance.json) uses
1 Hz wall pacing and stops after 256 exchanges. [Candidate generation](create-candidates.jl)
and the [slow variant](create-slow-candidate.jl) retain the construction steps.

The managed collector uses the existing capacity-one copy/drop-oldest display
queues. It compiles collection while held before native Start and requires
every detector frame and demanded command from 1 through 256. Optional applied
samples may be a subset, including the last exchange. Queue losslessness is
never inferred from this slow finite collection. Run 005 actually retained all
256 samples on each stream. Detector and demanded Acquisition identities match
throughout; the applied source supplies Header sequence/PTS and payload only.
All three PTS arrays match. The direct controller replay
uses the recorded detector frames; the independent plant replay starts from
the same reset seeds and adopts command n only after producing frame n. It
compares every noisy ADC frame exactly and reports pupil-mask, piston-removed
OPD RMS against a separate zero-command trajectory, excluding the first 128
frames for the finite improvement comparison.

Over frames 129–256 the mean corrected pupil OPD RMS is 51.0336 nm versus
281.0461 nm for the matched zero-command trajectory, an 81.84% reduction.
This is a finite seeded comparison using the released scientific algorithms,
not an independent physical mirror-model validation. The original run's native
Ready → Running → Ready controls and accepted Quit are preserved separately
from the subsequent read-only numerical verification. No native lifecycle was
repeated to correct the optional-metadata assertion.

This is software simulation evidence for the selected Classic CPU/JFG profile.
It does not qualify physical calibration or devices, GPU execution, FGN/Copper/
GPI profiles, sustained cadence, latency, long-run stability, arbitrary observer
noninterference, or shutdown reliability under every host load.

## Retained failed attempts

The fresh-stage precondition failures occurred before any service started.
Their available records are retained in the fault evidence folders. The initial
link precondition console output was overwritten by its successful log; a
clearly labeled excerpt records that evidence limitation.

Managed attempt 001 waited for an Active observation link that correctly stayed
Paused while its controller was held. The corrected gate accepts negotiated
Paused or Active links. Its subsequent native Quit exceeded the five-second
internal effect budget, returned an unknown outcome and triggered emergency
cleanup. A fallback test error initially obscured that failure; all errors and
the eventual cleanup record remain retained. No native Quit was retried. Attempt
002 independently passed native Start, Quit and cleanup; its display queues
delivered 250/250/251 distinct samples, so the complete-prefix test correctly
failed. The initiating cause of attempt 001's shutdown delay is not isolated;
secondary missing-source warnings are not promoted to that cause.

Attempt 003's experimental direct taps stalled source publication of frame 4
after capturing sequences 1 and 3. That setup was removed; no production buffer
or timeout was changed. Attempt 004's long deployment name failed validation
before service startup. The final candidate corrects that name. A preliminary
private-core CPU run failed before core startup because an advanced device type
needed its explicit module name; that is corrected. The optional CUDA loader now
crosses one cold `invokelatest` boundary, preserving its method world without
loading CUDA during CPU checks. No new CUDA execution is claimed.

Run 005 completed its capture and native cleanup, with all scientific replay,
improvement, payload scaling and GPU checks passing. Its original harness
reported 2,603 passes and 256 failures, all requiring applied-command Acquisition
metadata that the released HIL source intentionally does not publish. That
failed result and its exact harness remain preserved. The maintained harness
now checks the actual Header-only applied contract, retaining every mandatory
detector/demanded identity check. A fresh offline process rechecked the saved
payload hashes and sealed candidate, then reran the complete controller and
plant oracles: 2,846 checks pass. Its success receipt is explicitly separate;
the original live test is not relabeled as wholly passing.

The [independent review](../../reviews/20261021-classic-cpu-loop/REVIEW.md)
records adjudicated harness findings and these evidence boundaries.

## Raw evidence and reproduction

Raw scripts, candidates, failed logs, binary payloads and exact stages remain at
`/home/dgamroth/workspaces/codex/worktrees/classic-cpu-validation-20261021/`.
The maintained [integration guide](../../../test/integration/README.md) gives the
managed and fault entrypoints. Select the canonical Classic registered project,
`JULIA_DEPOT_PATH=~/.local/share/classic-review-20261020/depot`, disable automatic
Pkg GC/precompilation, clear GPU visibility and select the tested prefix's client
configuration/module/SPA/library paths. Use a new stage for each invocation.
Do not attach an injection harness to another live session.

The [evidence manifest](evidence-manifest.json) retains raw source paths, byte
sizes and hashes. The 64,006,144 bytes of captured arrays remain in the raw
stage rather than Git. The frozen original harness is under
`managed-005/collected-harness/`; maintained corrected entrypoints are under
`test/integration/`. All task sessions are stopped and no simulation owner
remains running. Canonical Classic scientific files and its normal CUDA default
are unchanged.

Integrated into canonical RTC `main` at `b11f900a8e167011bdc8c0ae8e108fc2951385ed`;
the clean task worktree and its merged branch are removed. The subsequent
[125-check integration result](integration.log) verifies canonical source and
evidence hashes, unchanged clean Classic `main`, and no active simulation
session units. The [integration receipt](integration.json) records this final
state. Raw GPU audit text is kept byte-identical, including trailing spaces in
process argument dumps.
