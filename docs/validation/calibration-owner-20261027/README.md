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

### Registered dark/source release — 2026-10-27

RTC 0.2.30 is published and registered from `e241bc6` (registry tree
`9f13f6707650f85873551eb038b1f01d1b3ed686`). AOC 0.17.2 is published and
registered from `7df02f5` (tree `5128a4816ad4dbec4803de21f7c819b859174273`).
The latter supplies bounded running dark/lamp states with unchanged batch
equations; 2,450 CPU assertions and an independent 80-case randomized comparison
against AOC 0.17.1 pass. No raw history is retained by these states.

The full RTC 0.2.30 suite passed 6,239 assertions on Julia 1.13.3. A fresh
Classic application resolved only registered packages (AOC 0.17.2, FGA 0.8.5,
FGPW 0.1.11, RTC 0.2.30), built successfully, and passed 151 cold graph/bundle
assertions plus 342 native dark/light Capture assertions. Each native session
restored/released and closed its own private CPU core. No GPU package was
loaded. The instrument source change is merged in
[PR 2](https://github.com/DarrylGamroth/adaptive-optics-simulations/pull/2).
PR 1 was superseded to exclude unrelated local GPI supervision commits without
rewriting its published history; the verified Classic files are identical.

Logs under the shared validation directory use prefixes `registered-030-`,
`calibration-release-030-` and `reference-aoc-0172-`. Failed harness attempts are
preserved: the first package run omitted the required PipeWire prefix, the first
native invocation passed an incorrect selector argument, and the first formatter
invocation selected an uninstantiated tools environment. Corrected invocations
passed; these were setup failures before the affected verification ran. This
release closes the registered-build prerequisite, not online campaign,
interaction-matrix or physical qualification.

### Online reference campaign implementation and review — 2026-10-27

The pending RTC increment adds `CalibrationPreparation` and
`InstrumentCalibration.calibrate_references`: declared dark/lamp stages, online
AOC state updates, typed startup parameter sources and a later exposure window
using frozen training mask/reference. The full core suite passes 6,441 assertions
in 243 testsets; the science contract selector passes 30 cold assertions and
typed stage-source projection passes 56 assertions (29 existing projection
assertions also pass). An actual private-core consumer selector passes 187
assertions covering correlation, borrowed-sample mutation, a mid-batch consumer
exception, truthful remaining exposure counts, latched rejection and confirmed
Restore/Release/teardown with unchanged source/application bytes. The initial
consumer test incorrectly equated exposure duration with frame period: Classic
has 1,896,000 ns exposure in a 2,000,000 ns period. The failed test is retained;
the corrected cadence/nonoverlap checks pass without changing product behavior.

Independent source/numerical review resolved these confirmed findings:

| ID | Finding and evidence | Disposition |
| --- | --- | --- |
| RC-01 | `Collect` read validity/slopes after a reducer borrowed mutable sample arrays. A fail-before reproduction changed invalid NaNs into valid values of 42. | Native response evidence is now frozen before invoking the reducer. Six focused checks and the native mutation regression pass. Borrowing remains explicitly read-only. |
| RC-02 | A custom preparation confirmation could name another simulator while the receipt named the selected owner. | Reject foreign witnesses before acquisition; the confirmed witness must exactly match the selected simulator incarnation/domain. |
| RC-04 | The source listener omitted the public native `RequestProcess` command. A fresh-idle baseline received one command but completed no cycle. | Service the request only while streaming and driving, without stepping AOS. This is an independent event-service defect; it does not establish the earlier stall's cause. |

Independent preparation tests pass 175 assertions, and the reference contract
selector independently passes 30. No unresolved confirmed source finding was
reported. Actual full campaign qualification failed: the first dark stage
reached an unknown absolute-request-deadline outcome after 11 minutes 21.8 seconds
in the native test body. No background or candidate was published. The aggregated
error also contained a second exception whose detail was not displayed; it is
not assigned a cause here. Temporary directories were automatically removed.
This observation does not identify a cause. No wake, retry,
source-brightness, noise, mask-threshold or scheduling workaround is used to
claim success. The campaign is not released or an activatable calibration.
The next instrument after REVOLT is GPI; mechanism authority remains external.

A separate direct-owner dark `Collect(16)` experiment reproduced the failure
outside the new coordinator. Hold, Adopt and Settle completed; AOC consumed
exposure 1. The passive snapshot showed exposure 2's raw receipt complete,
all WFS slots armed without receipts, HIL publication cycle 2/pending exposure
2 and no reported HIL failure. Collection reached its 120 s deadline. No
diagnostic wake or retry was issued, and application hashes were unchanged.
See `reference-campaign-first-dark-diagnostic-20261027.{jl,log,yaml}`.

Independent review identified a separate admission-contract defect (RC-03):
initial workers used the native latest-input default. The pinned native source
(`62a3aff`, JLL 1.7.1) recycles dequeued inputs if output buffers are unavailable.
Calibration requires every requested command/exposure, so workers now select
the existing bounded FIFO mode. The exact pinned source's native admission
target passed all 11 existing C checks, including controlled output starvation:
zero callbacks/returns while unavailable, then one callback/return when supplied.
This is fake-queue unit evidence, not a physical or scheduler qualification.
The generated `native-fifo-admission-receipt-20261027.yaml` binds source, binary
and log hashes; installed libraries and services were untouched.

FIFO alone did **not** fix the observed stall: the otherwise identical direct
dark test again stopped after exposure 1, with raw 2 present and WFS 2 absent.
Its `reference-campaign-first-dark-fifo-20261027` evidence remains failed.
A separate FIFO-off trace/observer experiment completed 16 input callbacks and
16 terminal WFS samples, all with identical zero slopes/flux and false validity
but advancing exact acquisition identities. This contradicts deterministic
unchanged-payload suppression; instrumentation may affect timing and is not a
production remedy. That evidence uses prefix `reference-delivery-diagnostic-20261027`.
A FIFO-on run with no trace or frame observer also completed 16 samples. Existing
frontend counters, read only after worker/core shutdown, showed 16 callbacks;
the command worker showed three. Both workers closed without errors and the
application hashes were unchanged. This single pass does not establish reliable
delivery or explain the earlier failures. Its prefix is
`reference-campaign-frontend-count-20261027`.

The native public driver contract also forwards downstream `RequestProcess`
commands to the source stream. A proposed source listener services that demand
with `trigger_process!` only while the stream is streaming and driving; it does
not step the plant or stage another exposure. Passive command observers on a
frozen baseline and the proposed implementation each saw 16 samples complete,
but neither observed `RequestProcess` after attachment. Startup precedes the
observation window. These passes therefore do not demonstrate handler exercise
or a causal fix. Only Pause was observed during teardown, with no parse errors;
the source reported driving and non-lazy. The evidence prefixes are
`reference-campaign-driver-command-probe-20261027` and
`reference-campaign-driver-command-service-20261027`.

The complete selector subsequently passed 30 cold assertions and 57 native
assertions in one run (`reference-campaign-complete-service-20261027`). Dark,
lamp training and later-window frozen qualification completed online, with
Restore/Release recorded for each stage. Training selected 176 of the declared
188 ROIs using unchanged thresholds; all 176 retained eligibility in
qualification. Dark/lamp/qualification status was Valid, with reference
difference RMS 0.008752788613187231 pixels and maximum 0.02652870473684743
pixels. These are diagnostics, not an independently specified accuracy claim.
Cancellation, stale confirmation, foreign witness and deadline rejection checks
also passed without publishing additional candidates. The generated candidate
receipt retains hashes and full acquisition domains; no raw history was kept.
This source-validation run does not replace registered-build qualification or
explain the intermittent earlier failures. Reliable delivery remains open.

A deliberate public `RequestProcess` test now exercises the proposed listener:
one command caused one observed command and one completed native cycle while
the AOS sequence, publication sequence, acquisition cursor, pending exposure and
capture receipts remained unchanged at idle. A subsequent 16-frame Collect,
Restore/Release and complete shutdown passed; frontend completion count was
exactly 16. The clean evidence uses prefix
`reference-campaign-request-process-locked-20261027`. The first harness attempt
closed its bound diagnostic Node proxy outside the ThreadLoop lock and emitted
a wrong-context warning. That warning-bearing evidence is retained under
`reference-campaign-request-process-control-20261027`; the harness was corrected
and rerun without changing production code. This proves event service without
extra scientific acquisition, not the cause of the earlier intermittent stall.
Independent source review found no callback/reentrancy or teardown defect in the
listener. The affected native consumer regression also passes 187 assertions
after the FIFO/listener changes (`reference-campaign-consumer-service-20261027`).

The maintained consumer selector now includes the explicit request on a fresh
idle owner before Hold/Adopt or settling cycles. It verifies streaming/driving,
zero initial scientific sequence, exact source identity, event service and an
unchanged locked scientific snapshot. The identical test file
(`1ed9c8b0e708182c856db7c766e7f436f00caaaa32f22d58f8644c605da7a723`)
failed on the frozen handler-free baseline: 196 assertions passed and only the
service assertion failed (one request, zero later cycles). With the listener,
all 197 assertions passed (one request, one later cycle), including ordinary
collection, reducer failure/recovery, source/application immutability, no GPU
and complete teardown. Logs use prefix
`consumer-request-process-fresh-idle-{baseline,postchange}-20261027`.
The earlier settling-cycle variant is retained separately; fresh-idle placement
avoids mistaking an old settling completion for service of the request. An
initial baseline harness setup referenced a removed source worktree; its setup
failure is retained and is not counted as fail-before evidence.

If delivery stalls again, the next discriminating measurement is the existing
bounded passive FIFO ingress trace together with the native node-ready trace,
dumped after the cutoff/shutdown and correlated with raw/WFS slots and worker
completion/errors. These native traces are compiled only with
`PW_ENABLE_DIAGNOSTIC_TRACE`; enabling their environment variables alone is
insufficient. Establish a separate diagnostic build from the exact pinned
source, record its compiler flags/binary hashes, and preserve the registered
libraries and installed services. Ingress D without G distinguishes readiness/backpressure;
G without E distinguishes callback execution; completed E/O without capture
distinguishes downstream delivery. No D directs investigation upstream to the
native cycle/input admission. The trace header sequence must be associated with
the recorded session domain/generation. A passing traced run only establishes
its own path; it cannot explain an uninstrumented failure. No further production
change is justified by the current stall evidence alone.

The fixed repeated-run gate at committed `d7e4568` **failed**. Trial 1 completed
all three 16-sample stages with 176 qualifying ROIs, confirmed restoration and
release. Trial 2 timed out in the qualification-stage call; trial 3 was not
attempted and no replacement trial was run. Recursive causes are the client's
`UnknownOutcome("absolute request deadline expired")` and the owner's
`ErrorException("native owner request deadline expired")`. The stack identifies
the stage, not the exact blocked action or sample count. Passive filesystem
observation found staged background/training/active/reference files but no final
candidate receipt; it does not prove a particular native phase. Both attempted
trials removed candidates, exited their private cores with code 0 and removed
the core directories. Code/application/instrument hashes remained unchanged.
Evidence uses `reference-campaign-repeated-d7e4568-20261027` and its runtime
supplement. This reproduces the problem with FIFO and the event listener
present: the event-service correction is independently valid but insufficient.
The campaign remains unreleased.

An isolated trace build from the same pinned native source `62a3aff` now enables
`PW_ENABLE_DIAGNOSTIC_TRACE`, with release optimization and the recipe's feature
selections. Host toolchain/ISA configuration differs from BinaryBuilder, so no
timing comparison is qualified. A validation-only Project selects all three
local JLL products through supported path preferences; the private helper's
prefix selection is adapted in memory, with unchanged lifecycle and generated
configuration headers. Installed libraries, global overrides and services were
untouched. A fresh private-core FIFO-filter construction/connection/closure
smoke emitted both CSV types with zero records/omissions; it proves trace
capability only, not acquisition progress. The main library hash is
`c18ad0c27189aedda6b0be02f97726bdf4c8e018526a6046a2ad50f1cac5c659`;
`native-trace-receipt-20261027.yaml` binds all products/configuration/commands.
Three existing compiler warnings were retained and classified: nullable INFO
formatting in `conf.c` (logging gated off here), unused disabled-flatpak helper,
and audioadapter inlining (not used by this ndarray smoke). Harness-only
pre-core library-path assertions and a post-smoke receipt-writer syntax error
remain preserved; the corrected writer regenerated the receipt without
repeating native execution. A separate fixed three-trial acquisition trace
experiment uses a recorded 300 s stage budget and stops on its first failure.

That trace series also failed: two complete campaigns passed, then trial 3
timed out in lamp training. All 208 CSV hashes match the receipt and all report
zero omitted records. The failed lamp domain contains one WFS frame completing
D/G/E/O0/O1/O2/R with successful results, but no D for frame 2. Native detector,
WFS and output nodes finish their last recorded cycles. Earlier target-state
snapshots precede those completions and do not establish stuck targets.
Output commits and downstream execution do not prove matching capture receipts;
the trace cannot establish that the calibration owner advanced to exposure 2.
Evidence uses `reference-campaign-trace-d7e4568-20261027`, with the failed lamp
ingress in trial 3's `ndarray-filter-2573392-15.csv` and node-ready files
`node-ready-2573392-93.csv` (WFS) and `node-ready-2573392-84.csv` (detector).
All private cores exited with code 0 and candidates/core directories were
removed. Source, application and instrument hashes remained unchanged.

The next experiment uses the original registered native products and a separate
source worktree with cold preparation/closure observer hooks only. A single
passive timer per owner records capture receipts, current action, acquisition
cursor, publication state and wait condition if the owner remains open after
30 s. Each protected group uses its own existing lock; the combined snapshot is
not atomic. Same-control-thread scalar observations are explicitly labeled.
The observer sends no processing command, condition notification or plant step;
worker counters are read only after tasks stop and both cores close. Its fixed
three-trial series stops on the first failure, without replacement trials.
These diagnostic hooks are not production changes.

The first observer series (`reference-campaign-stall-observer-d7e4568-20261027`)
stopped on trial 1's dark-stage deadline. Its observer referenced a driver-cycle
field that the calibration transport type does not have, so no valid capture
snapshot survived; this is a harness defect and supplies no action-level cause.
After teardown both workers were done, inactive and error-free, with completion
counts of 2 each. Core exit, directory removal, observer-reference release and
unchanged input/source hashes were confirmed. A distinct corrected series uses
`reference-campaign-stall-snapshot-d7e4568-20261027`, checks loaded field names
before creating a core and retains completed observation groups if a later
group fails. Neither series modifies production source.

The corrected series completed trials 1 and 2, then captured trial 3 during
qualification: the applying command is Collect(16), serial/token 4. Capture is
ARMED and waiting for generation 1 exposure 19, with exposure 18 last complete.
The raw slot has the matching exposure-19 receipt; slopes, flux and validity
remain ARMED without receipts. Capture reports no failure. HIL publication
ready/published/cycle-witness values are all 19, streams are STREAMING and
driving, with no HIL/probe error. The separate condition observation is open,
unset and has one waiter. Same-control-thread scalar observations show cursor
18 and pending exposure 19. These groups are separately locked, not a single
atomic snapshot. This establishes a later-exposure raw/WFS delivery boundary,
not a publication-witness wait or a confirmed native retry defect. The trial
subsequently reached its original qualification deadline with the same client
and native-owner deadline causes. No observer error occurred. After teardown,
frontend completion count was 19 and command count 2, with both workers done,
inactive and error-free. A frontend count is callback completion, not proof of
output publication. All three cores exited with code 0, candidates/core
directories were removed, observer references were released, and source and
input hashes remained unchanged.

A combined experiment now uses those same observer hooks plus a metadata-only
native patch in a separate worktree based on `62a3aff`. The existing bounded
node-ready ring gains explicit guard/retry/return decision records, alongside
the existing port-handoff trace. Original event meanings and transport policy
are preserved. The release-mode isolated build completed with the same three
pre-existing warning locations and no warning in changed diagnostic code.
`native-row-retry-build-receipt-20261027.yaml` binds source, patch, build inputs,
logs and all selected products; its main library hash is
`a25b4fa621d311de65af743db77d72ce57c4d0d8f0d9f5b5f8478cf7ed317e0a`.
The fixed three-trial `reference-campaign-stall-native-d7e4568-20261027` series
stops on its first failure, retaining bounded metadata only. Its altered
diagnostic binary is not a release candidate or timing comparison.

The combined series passed all three campaigns with the same 176 qualifying
ROIs and reference-difference diagnostics. All 612 trace hashes verify, with
zero omissions; all nine owners restored/released and cleanup/input hashes
passed. No passive stall snapshot fired. Trial 1 contains no new decision
records: the helper targets row-transport drivers, while the HIL stream
properties do not select that native mode. Thus the successful baseline does
not exercise the targeted guard telemetry or explain the registered failure.
The next discriminator retains the registered-native passive observer and
reads existing JFG rejection diagnostics only after worker join/core closure.
An expected Algorithm rejection can suppress FGPW outputs while incrementing
its completion count without a worker exception; that is an alternative to
native output loss, not a confirmed explanation.

The registered-library rejection series passed trial 1 and failed trial 2's
dark collection; trial 3 was not attempted. Its passive snapshot shows raw
exposure 6 present and all three WFS receipts absent. After full teardown the
frontend has completion count 6, no rejection/error, all pixel-calibration and
SH outputs available, and all three published output metadata slots matching
that exact domain/generation/exposure 6. This does not support expected
Algorithm rejection as the explanation for that run. It places the observed
boundary after accepted Julia graph processing, without proving native output
queueing or consumption. Cleanup and unchanged hashes passed. Evidence prefix:
`reference-campaign-rejection-d7e4568-20261027`.

Source review also excludes an unqualified property-only fix: FIFO cannot
recover graph cycles lost before helper admission. Native `node.reliable`
changes output tee semantics to first-eligible-mix transfer; it is not reliable
broadcast for the current raw/WFS same-port fanout. The qualified HEART row
transport contract is likewise not a generic full-frame stream contract.
Independent review recommends establishing exact delivery/lease behavior with
numbered UInt16 fanout and held-consumer tests before promoting a transport
change. No reliability property or scientific graph topology has been changed.

The explicitly ACTIVE `reference-campaign-progress-pulse-d7e4568-20261027`
experiment completed three campaigns. Trial 2 lamp training stalled at exposure
15, with raw present and WFS receipts absent. After saving and revalidating the
same Collect ticket/exposure, one public native processing request was issued
without a plant step, source republish or deadline reset. Immediate scientific
sequence fields stayed expected 15/last 14; the owner subsequently released
and closed before the later passive snapshot. Exactly one pulse occurred.
Frontend counts remained 16/16/32 per campaign, with no graph rejection, and
cleanup/hash checks passed. This supports missing-quantum flushing for that
controlled case; it is not a production fix, root-cause proof or qualification.

Independent source review supports a narrower configuration experiment before
new transport APIs: inactive stream connection selects the main data loop and
graph-ASYNC scheduling. Public post-connect `node.async=false` updates scheduling
without moving the data loop or enabling RT_PROCESS. Applying and observing it
before links are created could make calibration data capture participate in
the driver's completion fence. Existing links must not be assumed to rebuild
on that property update. The candidate must verify actual frontend/sink
scheduling and callback placement, and capture completion at the publication
cycle witness, without the former unconditional extra native trigger. Other
asynchronous command/feedback nodes remain outside any universal quiescence
claim. No candidate implementation or qualification follows from this review.

The isolated synchronous-capture A/B candidate failed trial 1's dark stage at
its explicit publication-cycle/capture-completion assertion. All four sink
NodeInfo properties reported `node.async=false`/`node.loop.class=main` before
links, and all public data-loop comparisons matched the capture ThreadLoop.
The frontend async property was absent, with native-default interpretation
recorded rather than an observed false. After teardown the frontend count was
6, with no rejection/error and all output metadata at exposure 6. No passive
30 s snapshot fired before the assertion, so the precise incomplete slot set
at assertion time is unknown. The caller also observed owner removal. Cleanup
and unchanged hashes passed; no later trials were attempted. Evidence prefix:
`reference-campaign-sync-capture-d7e4568-20261027`. This configuration is not
promoted. The next measurement must distinguish actual activation/link IO
state from the source completion notification's cycle association.

The maintained consumer regression now observes first-cycle receipt completion
and callback loop placement. Its unchanged-source baseline run reached the
deliberate reducer-failure Collect, then hit the known request deadline:
112 assertions passed and one error occurred. The later first-cycle assertions
were not reached, so that run does not independently establish their failure.
Its log is `capture-first-cycle-baseline-20261027.log`.

A second, isolated diagnostic build records the cycle at native notification
scheduling (`T`) and delivery (`D`), effective activation flags and single versus
double link IO slots. The source remains pinned at `62a3aff`; the metadata-only
patch is `9b410f741fd3e702e6ac3e2857a97c94a8aa0ae2069ce00d00c841bb011973dd`.
All 707 build targets and local-prefix installation passed. The same three
previously classified compiler warnings remain; none occurs in changed code.
The original native checkout remains clean. Build receipt:
`native-node-cycle-build-receipt-20261027.yaml` (SHA-256
`280bae90661c1ba149262bd277919bcc135109fae445ba2e922ea1374fcb79bc`).

The one planned `reference-campaign-sync-fence-trace-d7e4568-20261027` campaign
passed all three stages with counts 16/16/32 and no capture-fence snapshot.
All 103 recorded notification deliveries observed the same current cycle as
the immutable scheduling cycle. This run does not demonstrate stale completion
attribution and does not resolve the prior registered-library candidate
failure. The error-only pre-teardown snapshot remains unexercised. No
production scheduling change or release qualification follows from this pass.
Effective capture/frontend activation flags were zero (ASYNC clear). The
scientific detector-to-frontend/raw and frontend-to-WFS capture handoffs used
shared IO slots. All 204 trace hashes and cleanup checks passed. Thus this run
observes the candidate's intended synchronous link configuration, rather than
inferring it solely from NodeInfo properties.

The registered-library error-snapshot series stopped on trial 1, dark exposure
1. Its immediate locked COMPLETE check was false, but the subsequent locked
snapshot already held raw/slopes/flux/validity COMPLETE with all four exact
exposure identities. The owner had not consumed them. Joined frontend output
metadata also matched exposure 1 with no rejection or error. Cleanup and
source/application/instrument hashes passed. The earlier precise missing-slot
set was not recorded. Evidence:
`reference-campaign-sync-fence-registered-d7e4568-20261027.{yaml,log}`.
This demonstrates a readiness race in the candidate assertion, not stale native
notification attribution. The immediate assertion and its first-callback test
are withdrawn; exact capture receipts must be awaited with the existing event
primitive and unchanged deadline.

The next production candidate keeps capture graph-synchronous on its main
ThreadLoop, configures it before links, and removes the unconditional additional
native trigger. It retains `CalibrationCapture.await!`, full receipt identity
checks and all existing failure/restore/release behavior. The source publication
witness is described as a historical callback observation, not a strict native
cycle fence. A separate HIL contract weakness remains deferred: reset does not
own/fence outstanding native cycles, so the mutable publication observation
cannot authenticate a delayed completion across generations. Source/state review
establishes that limitation; no native interleaving or campaign cause is claimed.

### Synchronous capture with event-based receipt completion

Production source `a3f927b486e0e17746a3fc1d0720b89d8665d29d` passed the fixed
three-campaign series using the original registered native products, without
hooks, tracing, pulses or replacement trials. Every campaign collected 16 dark,
16 lamp and 16 qualification samples after 16 qualification discards. All nine
stages restored/released, with distinct acquisition domains, and all private
cores exited zero and disappeared. Temporary candidates/cores were removed;
source/application/instrument hashes remained unchanged. All 176 eligible ROIs
retained eligibility; diagnostic RMS/max differences remained 0.008752788613187231 /
0.02652870473684743 pixel. Interaction-matrix acceptance remains false. Evidence:
`reference-campaign-registered-a3f927b-20261027.{jl,log,yaml}`.

Focused selectors on the same source passed:

- Consumer integrity/failure/recovery: 209 assertions, including the formerly
  blocked reducer-failure Collect, restoration and release. The earlier 112-pass
  deadline failure remains in `capture-first-cycle-baseline-20261027.log`.
- Standalone capture: 96 assertions, including 16 actual private-core assertions
  and shared wakeup ownership.
- Complete reference selector: 87 assertions (30 cold numerical/contract and 57
  private-core campaign/preparation fault checks), including cancellation,
  stale/foreign preparation evidence and cold deadline rejection.

Logs are respectively `capture-synchronous-await-consumer-20261027.log`,
`capture-synchronous-private-core-20261027.log` and
`reference-synchronous-await-service-20261027.log`. Julia 1.13.3 was used; GPU
modules remained unloaded. These results establish scoped functional behavior,
not physical correctness, a timing bound, universal delivery or the native cause
of prior failures. The separate HIL strict-ordering limitation above is retained.

Core-suite setup attempts are preserved separately: the optional science
project did not expose FITSIO to the core tests; the package-environment attempt
then reached schema checks without the required `PIPEWIREAO_PREFIX` and stopped
with one failure/one error. Neither was a production calibration failure. The
complete package-environment command with the explicit registered prefix is
recorded in `AGENTS.md`; its corrected run is kept separately as
`reference-synchronous-await-core-prefix-20261027.log`. The expected missing-Git-
object negative test writes `git cat-file` failure text to stderr.

The corrected core run exited zero: 6,488 passing assertions across 243 test
sets, with no test failure/error marker. Its assertion count differs from the
prior 6,441 only because the existing concurrent-snapshot test completed 128
rather than 81 iterations. The standalone capture, consumer, complete reference
and three-campaign receipts were independently inspected; no blocker was found
for the scoped Classic CPU candidate procedure. Fresh stage owners/domains and
exact four-stream receipts avoid relying on cross-reset witness attribution.
Registered-package qualification remains the next delivery gate.

### Published RTC 0.2.31 and fresh registered build

RTC PR 15 merged at `61b52d4a699b32e0f875c7223ed8a32e278bb598`; tag/release
`v0.2.31` is published and registry commit `b580163` records tree
`4aaa7e93db1b249e5e037a655297b61ec0c6e4d2`. A fresh registry-only environment
retains all exact scientific/native pins, contains no path/repository overrides
or preferences, and verifies the actual installed RTC tree before and after
execution. Fresh Classic build, source hashes and no-GPU guards passed.

The installed package passes the complete reference selector: 87 assertions
(30 cold and 57 private-core campaign/preparation-fault assertions). All three
stages were Valid and restored/released, with 176 eligible ROIs. Its diagnostic
RMS is 0.0087526875551957 pixel, recorded separately from the earlier source
cohort; no exact cross-run equality or physical precision claim is made. The
main release Manifest remained unchanged, with SHA-256
`774a0d87fa1876d73ce927f1ed953609daa8195a57b7216b9e4b02daf70c81ac`.
A separate test environment promotes the same YAML 0.4.17 to a direct dependency
and retains identical resolved package entries; the instrument calibration
selector passes 161 assertions. The initial missing-direct-YAML import failure
is preserved and occurred before assertions.

Evidence stems are `reference-campaign-registered-release-build-20261027`,
`reference-campaign-registered-release-selector-20261027` and
`reference-campaign-registered-release-tools-yaml-cold-20261027` in the existing
validation directory. Instrument PR 3 merged at
`8673dec6dffc3c94305f401f2e9d5a275de42a67`, adding the shared command, recipe and
exact RTC pin. Formatting passes. Physical REVOLT preparation remains manual;
GPI's adapter and qualification are next.

Six completed diagnostic worktrees were removed after their source commits,
exact patches and untracked note were preserved and hash-verified in
`completed-diagnostics-20261027/manifest.json`. Original native source,
unrelated worktrees and local GPI edits were preserved. This cleanup removes no
failed evidence or unmerged investigative bytes.
