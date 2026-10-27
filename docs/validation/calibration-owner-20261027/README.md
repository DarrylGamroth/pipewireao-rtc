# Native initial calibration — 2026-10-27

The shared initial-session endpoint now derives its exact WFS frontend and PDM
conditioner from a built regular graph, accepts the existing native action
profile, adopts transported absolute commands, and collects correlated owned
raw/slopes/flux/validity data. There is one authored RTC graph. The cold builder
rechecks selected graph/FITS authority; it adds no flat, offset, threshold or
mask. The existing Procedure remains the acquisition coordinator.

The [plan](PLAN.md) records ownership and gates; the [independent review](REVIEW.md)
records findings and dispositions. Normal configured ADC, photon noise and
readout noise remain enabled. No GPU, installed session or device was used.

## Observed verification

Julia 1.13.3, CPU, registered scientific dependencies with explicit RTC/HIL source
overrides only in the validation environment. The selected Classic application
was the existing registered-0.2.21 build, graph SHA-256
`a9e39891219b83e5a3327027951395c9fdfe74f2e9b8a1cecd511f3f7eb2a575`; its complete application-file hash map was unchanged.
The final optical selector uses public APIs throughout.

| Check | Result | Scope |
| --- | --- | --- |
| RTC complete software suite | 5,624 assertions, 213 testsets passed | Includes 22 native dispatch/idle-loss checks; software/private-core qualification |
| Cold regular-graph projections | 29 passed | Exact declarations, parameter arrays, typed ports and source immutability |
| Same-graph stale FITS rejection | 6 passed independently | Reject before plant/transport creation |
| Four-stream capture | 80 unit + 16 private-core assertions passed | Row-major data, full identities, copied metadata, validity preservation and deadlines |
| Command transport and registry identity | 27 passed | Actual conditioner clipping, matching feedback, restoration, worker cancellation and incarnation fencing |
| Registry readiness regression | 62 passed | Twenty fresh pairs of native graph workers; registry notifications, finite deadlines, no diagnostic wake |
| HIL full package suite | 2,993 passed, including Aqua | Private cores, publication-cycle witness and failure/reset fences |
| Actual Classic safety integration | 106 passed | Scientific rejection, early cancellation, idle controller loss, closure, unchanged files and no loaded GPU package |
| Plan diagram | Rendered with repository-prescribed Mermaid container | Documentation structure |

Logs are retained in the external `standard-calibration-validation` evidence
workspace. Relevant basenames are `calibration-owner-root-tests-20261027-r3.log`,
`calibration-capture-primary-20261027.log`,
`calibration-transport-drain-20261027.log`,
`hil-publication-cycle-Pkg-test.log` and
`initial-calibration-classic-private-core-20261027-r8-adjudicated-safety.log`.
Failed ordering experiments remain separate evidence, not passing gates.

The complete RTC `Pkg.test()` invocation also passed 5,624 assertions on Julia
1.13.3 (`calibration-owner-Pkg-test.log`). Its stale workspace-hash warning was
addressed by resolving the final release metadata through Pkg; no manifest was
edited by hand. The final release package selector passed 326 assertions, with public API,
version and docstring smoke checks also passing. The tracked workspace manifest
changed only its project hash and this package's version; dependencies did not
change.

The first fresh registered-only RTC 0.2.23 / HIL 0.2.7 run passed package
identity checks, 29 projection checks and 6 stale-binding checks. The optical
selector passed its rejection/restoration and early-cancellation cases, but
the third constructor reached its readiness deadline (91 assertions passed,
one errored). A captured stack showed both graph workers in their native run
loops and the owner awaiting worker readiness. This failed gate is preserved in
`calibration-owner-registered-023-qualification.log`; the earlier source run
does not substitute for registered qualification.

The isolated original readiness predicate reproduced a missing notification in
five of nineteen warm trials: both workers were ready with valid published IDs
while their owner still waited; one diagnostic wake resumed it. The repaired
predicate completed twenty trials with no diagnostic wake. This confirms the
notification-contract defect; the earlier registered timeout did not capture
IDs, so its precise cause remains unconfirmed. The original and repaired stress
logs are `readiness-original-predicate-stress-20261027.log` and
`readiness-registry-predicate-stress-20261027.log`.

Startup now discovers every required server node and port through the registry
events that publish them. Fresh UUID graph names prevent a prior session's node
from matching. Links retain exact IDs and object serials, which are rechecked
before creation and admission. Link-info events replace synchronous startup
roundtrips; removal/error/UNLINKED invalidate readiness permanently. The final
focused selectors passed 27 transport/identity and 62 readiness assertions
(`calibration-owner-registry-focused-20261027.log`). Run these optional selectors
with the scientific environment and four Julia threads:

```julia
include("test/calibration_transport.jl")
include("test/calibration_readiness.jl")
```

The final RTC 0.2.24 source, including UUID graph names and sticky link
invalidation, passed all 106 optical safety assertions
(`calibration-owner-registry-final-optical-20261027.log`). Its package/source
closure selector passed 326 assertions (`calibration-owner-024-package.log`).
The patch changes cold startup only; the previously passing full RTC and HIL
suites above remain separate evidence.

### Registered release qualification

Published RTC 0.2.24 (tree `48106f033af8c55389984cc5f13e83cecaf2c4ac`)
and HIL 0.2.7 (tree `c7e680c89acbfc284f171589d070282be84a2c6a`)
passed the combined registered-only run on Julia 1.13.3 with four threads.
The project has no source overrides; its manifest was checked for absent path
and repository overrides and exact registered tree identities.

All 237 assertions passed: six package identities, 29 projections, six stale
bindings, 27 transport/identity, 62 readiness, 106 actual Classic optical safety,
and one final no-loaded-GPU assertion. Evidence is
`registered-024-qualification.jl` and
`calibration-owner-registered-024-qualification.log` in the external evidence
workspace. The first assembly of this harness imported both Pkg and PipeWireAO
exports into Main, making `Registry` ambiguous in the optional transport test.
Using `import Pkg` fixed that harness-only error; its script/log remain preserved
with the `assembly-error` suffix. No production change was needed.

The instrument repository's selected-bundle check also passed 119 assertions
using the registered cohort; its formatter check passed. Classic and GPI2 pin
RTC 0.2.24/HIL 0.2.7 on main, preserving their respective FGA selections. Releases
and registry entries were pushed. The five completed task worktrees were removed;
working source-validation environments now reference the main checkouts, with
their prior project/manifest files retained in the evidence workspace. The
original registered-0.2.21 environment and frozen calibration inputs are unchanged.

## What the optical test establishes

A genuine transported probe is adopted before an exposure executes. Raw UInt16
pixels and all WFS outputs carry the same full wire acquisition identity,
model start and duration. The endpoint retains the full wire domain and its
explicit coordinator-domain-ID association. Header PTS remains a separate clock.
Native source queueing, source-cycle completion and complete sink capture are
separate facts. The shared HIL publication-cycle witness orders one downstream
progress request; it does not establish WFS success or advance the optical model.

The selected frozen estimator has 184 active subapertures. Under the selected
normal noisy, turbulent plant, positions 85 and 104 measured fluxes 932 and 975
against the existing threshold 1,000. All response values were finite. The owner
correctly returned invalid scientific evidence; the Procedure rejected it,
restored the reference and released exactly once. The online numerical consumer
was not called with the invalid batch. This is a verified rejection, not an
accepted interaction calibration. Noise versus atmospheric contribution was
not distinguished, and no mask or threshold was changed to force acceptance.

Cancellation before Hold also restored/released without exposing a frame. Loss
of the exact idle controller after Hold faulted and fenced the endpoint without
restoration, another probe or any exposure. All graph workers, borrowed buffers,
streams, listeners, cores, timers and owned notifications were closed.

## Stationary-source and bounded Capture follow-up

The user selected the existing source level initially: R-band magnitude 2,
on axis at 800 nm. The declared optional `internal-source` simulation graph
removes atmosphere from the optical path and retains the exact production
detector configuration, UInt16 transport, normal photon/read noise and ADC.
This is a stationary point-source equivalent, not a calibrated physical lamp
model. The regular RTC graph and frozen artifacts remain unchanged. The cold
graph selector passed 17 assertions; normal CPU build and declaration checks
passed without loading a GPU package.

A separate eleven-exposure trial completed 326 transport/identity assertions,
but accepted zero exposures under the frozen mask. Five flat and three of each
signed-probe frames had fluctuating failures across active ROIs
70, 71, 85, 88, 101, 104, 118 and 119. The minimum observed flux was 917 against
the unchanged 1000 threshold. Raw ADC values remained in 0–339. No ROI failed
every flat exposure. This supports explicit lamp training and independent
qualification; it does not justify choosing brighter illumination or manually
editing the mask. The external `internal-source-20261027/RECEIPT.md` retains
samples, hashes, failed experimental builds and the final copied-source patch.

The actual declared-graph selector subsequently passed 122 assertions twice,
including native flat/signed commands, truthful validity, restoration, release
and cleanup. Its first run instead timed out on the second Collect (54 passed,
one error). No slot snapshot was available before teardown, so the cause is
unconfirmed. Later timing diagnostics did not reproduce it. A standalone Julia
1.13.3 AsyncCondition experiment passed 105 assertions and rejected the simple
single-consumer lost-notification hypothesis. Native stream documentation permits
a triggered iteration to require another progress request, but this is a relevant
contract boundary, not an established explanation of the observed timeout.
No production scheduling change, diagnostic wake or automatic retry was added.
Three further bounded fresh-core trials with per-action output suppressed each
passed 122 assertions (366 total); no Collect reached the one-shot 10-second
passive snapshot. Their receipts, code/dependency cohort hashes and separate logs
use `internal-source-quiet-20261027-trial-1` through `-3`. This did not reproduce
or explain the earlier failure and is not a statistical reliability claim.

Classic native Capture now writes bounded owned raw/WFS payloads outside
callbacks and returns the existing hashed manifest descriptor. The optional
constructor arguments are `capture_directory`, `capture_stage` and
`capture_maximum_bytes`; the directory must be fresh and the cumulative payload
budget is reserved before exposure. Stage, illumination, detector/source settings,
RTC graph and both projections' exact prepared FITS identities are bound into
the manifest. `InstrumentCalibration.read_capture` requires the caller's expected
profile, stage, illumination and settings before returning owned arrays.
Unsupported payload contracts and Copper reject; interaction validity is not
relaxed. Failed admitted requests retain charged partial evidence and the native
unknown-outcome fault fence. The campaign owns retained files.

The corrected native Capture selector passed 171 assertions: a four-frame
request rejected before effects against a three-frame budget, three consecutive
frames completed, the reference restored/released, all workers/core closed,
and only then the descriptor and saved samples were verified. Model starts were
0, 2,000,000 and 4,000,000 ns, each exposure 1,896,000 ns. All three exposures
retained false active validity (ROIs [88], [71], [70, 101]); these are useful
training evidence, not accepted interaction responses. Payloads total 750,756
bytes and the manifest 11,105 bytes. Files and source hashes remained unchanged.

The first Capture harness compared prepared-array hashes to original FITS-file
hashes after the provenance correction. It completed the same native operations
but reported seven harness failures (134 assertions passed). That harness and
receipt remain separate from the corrected passing run. External evidence uses
`native-capture-first-20261027` and `native-capture-provenance-20261027` prefixes.
The file-boundary selector passed 150 assertions and the graph-owner selector
86, including same-file/distinct-HDU regression coverage. CO-07–09 in the
[independent review](REVIEW.md) preserve fail-before/pass-after evidence.

The complete RTC source suite passed 5,786 assertions in 215 testsets on Julia
1.13.3 (`internal-source-root-tests-20261027.log`). Its expected missing-Git-object
negative test emits `git cat-file: could not get object info` and passed; it is
not a failed integrity check on the application or source. This software result
does not close the repeated optical acquisition or scientific gates below.
The final 0.2.25 package/source-closure selector passed 328 assertions and the
version/public-function/docstring smoke checks passed. Pkg resolved the tracked
workspace manifest with only its self-package version changing; dependencies
were unchanged.

## Remaining gates

A stationary calibration-source/eligibility procedure and an accepted complete
basis remain prerequisites for AOC estimation and an activatable bundle. This
increment does not qualify accepted optical acquisition, optical consumer-failure
recovery, controller loss during an exposure, multi-WFS/named-corrector coherence,
physical settling, deadline performance, GPU execution or running-controller
state preservation. Existing Procedure unit tests cover online consumers and
known processing failure; they are not substituted for those optical gates.

The user's intended operation is daytime internal-source calibration followed
by on-sky adjustment, with a bright target as an alternative calibration source.
The recommended next qualification therefore uses a declared stationary source
and no atmospheric disturbances, retaining normal detector noise/ADC and the
existing validity checks and 25 Hz filter. Internal-source path coverage and
illumination eligibility must be explicit. On-sky registration/response checks,
controller/optical gain adjustment and acquisition through turbulence need
their own acceptance rules on the same asynchronous interfaces. No numerical
gain is selected here; the existing source level is retained.

An in-flight synchronous HIL call resolves or reaches its finite deadline before
cooperative revocation checks. No immediate hard cancellation is claimed. Unknown
outcomes never authorize retry, rebind or ordinary-loop resumption. Bounded
Capture is a qualified software prerequisite; the automatic dark/lamp/qualification
campaign, reliable repeated acquisition, accepted complete basis, numerical
acceptance and physical instrument qualification remain open.
