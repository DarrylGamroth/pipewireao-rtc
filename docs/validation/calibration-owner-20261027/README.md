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
retained false active validity (ROIs [88], [71], [70, 101]). The storage selector's
`lamp-training` stage label tests descriptor binding; its frozen WFS reference
and ROI mask do not meet the zero-reference/candidate-universe training contract.
These samples qualify transport/storage only, not campaign lamp training or
interaction responses. Payloads total 750,756
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

### Registered 0.2.25 failure and format-scope correction

The fresh registered-only 0.2.25 environment built Classic successfully and
passed all 119 selected-bundle checks. Its native Capture selector then failed
before any command/acquisition: six assertions passed and construction rejected
the probe format. CO-10 records the confirmed cause: the final cold payload
check reused `format`, overwriting the requested Float32 `(277,)` command format
with the last payload's Bool `(188,)` validity format. The original source
171-assertion run preceded that late check and did not qualify this change.

The corrected loop uses a separate `payload_format`. Independent cold
reproduction passed 16 assertions against both applications' actual formats;
their regular graph hashes were identical. The same native Capture selector
then passed 171 assertions with corrected source against the previously failing
registered build (`internal-source-capture-format-fix-20261027.log`). No detector,
transport, schema, command or acceptance policy was changed. Published 0.2.25's
tag/tree/registry entry are retained; 0.2.26 supersedes it.

The fresh registered-only 0.2.26 environment successfully built a new Classic
application and passed the same 171 native Capture assertions (66.9 seconds
for the optical selector). All package dependencies were registry/stdlib entries,
the regular graph retained its exact `a9e398…` hash, the dependency manifest was
unchanged, and no GPU package loaded. The reference restored/released and every
private-core resource closed before saved samples were verified. The final
0.2.26 package/source-closure selector also passed 328 assertions plus the
version/public-function/docstring smoke checks.

The frozen external `qualify-capture-026-20261027.jl` reproduces the fresh build
and native selector; `internal-source-registered-026-qualification-20261027.log`
and its capture receipt/payload directory preserve the result. The registry
binds 0.2.26 to tree `ff22af2c3563fa8295719b6707d0b8dd69123632` at source commit
`9c4f3352aa908b4f0572775e2cde8a4c5b77a167`. This closes CO-10's registered
software gate, not lamp-training or scientific acceptance.

## Remaining gates

### Source and mechanism preparation follow-up

Work starts from RTC `1825877` and instruments `516b480` in dedicated
`codex/calibration-preparation-20261027` worktrees. Canonical instrument README,
CAL2 and optical-design edits are unrelated and retained. No generated output is
edited: the authored simulation declaration adds a dark graph, and application
outputs are rebuilt through `tools/build.jl`.

The user confirms REVOLT preparation is completely manual. The shared
[preparation contract](../../JULIA_CALIBRATION_ACQUISITION.md#source-and-mechanism-preparation)
therefore includes explicit operator-attested readiness as distinct from measured
device readback. Existing SPIDERS code inspected read-only under
`~/spiders-working` supplies concrete future adapter boundaries:
`device-superk/src/state-machine.jl` writes emission and separately reads
emission/interlock state; a handled write does not confirm readback.
`device-thorlabs/src/state-machine.jl` and `src/ThorlabsStage.jl` issue movement
and later report polled motion/position state. `device-galil/src/state-machine.jl`
calls blocking `motion_complete` and has no exposed axis-position readback in
its statevariables. These observations do not qualify any physical service or
its completion semantics. No service was started or commanded.

The new simulator dark graph retains the normal detector and held command
endpoint, feeding a declared zero Float32 photon-rate array of detector shape.
The existing magnitude-2 internal source remains unchanged. The old registered
RTC rejects the new graph selection; the updated cold selector passes 25 checks,
including rejection of an optical link or a binding not declared as `zeros`.
Focused component/schema/export regressions pass 418 assertions, and selected
bundle checks pass 125. A fresh `tools/build.jl` application passes both native
Capture selections: three dark exposures and three internal-source exposures,
171 assertions each. Dark raw samples span 0–7 ADC counts (means
0.6303–0.6312); illuminated samples span 0–339 (means 5.6605–5.6690). These are
finite diagnostics, not acceptance limits. Both selections confirm exact detector
settings, associated raw/WFS receipts, intrinsic validity, mirror restoration,
release, endpoint/core closure and unchanged source/application files. Independent
source review found no blocker; the Mermaid sequence renders and formatting and
whitespace checks pass. No GPU module, hardware or installed service is used.

Evidence logs and immutable captures are under the external
`standard-calibration-validation` directory with prefix
`calibration-preparation-20261027` / `calibration-preparation-native-*`.
The first build rejected a source-override manifest before producing a qualified
application. The corrected build seals registered dependencies from the frozen
0.2.27 environment; its compiler/native test driver uses this validation-only RTC
source worktree. This is source validation, not registered-release qualification:
0.2.27 does not understand the new dark selection. A compatible RTC release,
instrument dependency update and fresh registered build are required before
promoting this instrument declaration to normal application use. Concurrent RTC
main has also raised FGA/FGPW minimum versions; preserve separate cohort evidence
when integrating. Existing selected calibration artifacts remain byte-identical.

Integration with RTC main `40d290b` is retained at merge `becf402` (roadmap-only
conflict resolved by preserving both work summaries). A separate source-validation
run with registered FGA 0.8.5 / FGPW 0.1.11 passes 25 dark/source, 125 bundle and
342 actual private-core Capture assertions. All 24 retained raw, slopes, flux and
validity binary payloads are byte-identical across cohorts (28 parity assertions).
The integrated environment and captures are frozen under
`calibration-preparation-integrated-20261027`. A final 26-assertion cold check
also covers omission of the optional empty graph `links` field; existing explicit-link
graph behavior is unchanged. This still does not qualify a registered RTC build
or update the instrument's normal dependency pins. Delivery drafts are
[RTC PR 14](https://github.com/DarrylGamroth/pipewireao-rtc/pull/14) and
[instrument PR 1](https://github.com/DarrylGamroth/adaptive-optics-simulations/pull/1).

The earlier intermittent second-exposure timeout did not recur in these six
exposures. It remains unexplained, with no scheduling workaround or automatic
retry added. Neither transported images nor a successful software test establishes
accepted background estimation, reference training or physical readiness.

The original separate-`Collect` sequence was also exercised on the integrated
cohort, with the existing one-shot passive stall diagnostic and no retry. All
122 assertions pass; no passive outstanding/fault snapshot was reached. The
flat exposure rejected active ROI 88 (flux 981), the positive probe rejected
ROI 70 (flux 960), and the negative probe passed. The threshold remains 1000
and source magnitude remains 2. This directly preserves scientific rejection
and lifecycle behavior in the relevant action sequence, but one passing trial
does not explain the prior timeout or establish reliable acquisition. Logs and
the action receipt use prefix `calibration-preparation-collect-integrated-20261027`.

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
