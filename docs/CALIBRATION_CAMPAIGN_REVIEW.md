# Classic calibration campaign design review

## Review baseline and disposition

Independent source and contract review, 2026-10-02. Worktree:
`pipewireao-rtc-calibration-campaign`, branch
`work/calibration-campaign-20261002`, baseline
`dccb17931df131e8845c1dc4f8bb5c7c252ba625`. The worktree was clean at review start.
Only this review document is owned by the reviewer. No production changes,
runtime launches, or new implementation tests were performed.

Authority: [RTC-ARCH-023](architecture.md#instrument-calibration-through-deployed-endpoints),
[RTC-DEV-029](operations.md#rtc-dev-029--operational-interaction-calibration),
and the operational calibration section of the [roadmap](roadmap.md).
This document proposes an implementation allocation; it does not amend those
requirements or promote automatic campaign support.

**Disposition:** implementable as a small orchestration increment after the
explicit interface and scientific-policy gaps below are adjudicated. Reuse
fresh initial-calibration sessions and standard graph startup parameters.
Do not introduce live illumination switching or a live multi-parameter
transaction merely to avoid restarting a stage.

Selected scope: Classic CPU first, measured noisy dark acquisition, lamp
reference/training capture, explicit eligibility selection, independent
qualification, then the existing zonal interaction acquisition. FGN and JFG
retain their own deployed WFS implementations. HEART, Copper, physical devices,
modal/sinusoidal probes, sharpening, automatic exposure/brightness tuning,
reconstructor activation, and correction/rate qualification are separate work.

## Confirmed interface gaps

These are gaps for the proposed campaign, not regressions in the current
interaction-calibration contract. IDs are review findings, not normative IDs.

### CC-R1 — Bounded capture evidence is missing

- Severity: blocking design prerequisite. Confidence: confirmed by source.
- Evidence: `deployment/hil/calibration_server.jl:7–9,265–289` limits replies to
  64 KiB and returns only averaged response values plus exposure identities.
  `session_response_values` selects the first WFS sink. The raw, flux, and
  validity sinks exist in `calibration_acquisition.jl:105–122,163–180`, but no
  maintained campaign interface exports their individual completed values.
- A Classic raw frame is 123,904 UInt16 values, or 247,808 bytes before JSON.
  Raising `measurements` or reusing the response array cannot fit the existing
  record limit or preserve its 376-value measurement contract.
- Complete dark/training captures can legitimately have false WFS quality.
  `collect!` returns `valid=false` for a complete quality-invalid batch so the
  interaction coordinator can abort and restore. Relabeling such a batch as a
  valid interaction response would hide the evidence.
- Proposed remedy: add one explicitly specified campaign capture operation to
  the same bounded completion channel, with a completion distinct from
  interaction `responses`. It uses the existing held/adopted/settled cursor
  rules, records complete raw and WFS evidence, and leaves the current
  interaction action semantics unchanged. See the ownership contract below.
- Required validation: record-size rejection before acquisition; exact raw/WFS
  identity association; complete dark data with false intrinsic WFS validity;
  missing/duplicate/stale channel rejection; partial write, cancellation,
  timeout, and disconnect behavior; no successful capture from partial data.
- Disposition: requires parent-approved protocol extension before production.

### CC-R2 — Illumination and stage identity are not an owner interface

- Severity: blocking design prerequisite. Confidence: confirmed by source.
- Evidence: `calibration_acquisition.jl:24–76` already prepares public declared
  lamp or dark graphs while retaining the production detector configuration.
  `calibration_owner.jl:71–76` always uses the default lamp selection. Preparation
  warms and resets the boundary before creating operational endpoints.
- Proposed remedy: a validated startup selection for dark or lamp, propagated
  through the maintained owner/exporter and recorded in stage provenance. Keep
  the same detector configuration and normal ADC/noise behavior. Dark means
  zero declared incident photon rate, not disabled detector noise. Lamp
  brightness is an explicit input with a finite policy; it is not tuned until
  a desired number of ROIs pass.
- Each fresh stage has its own complete acquisition domain and generation.
  Preserve the domain mapping, rather than making sequence1 from successive
  stages appear to be the same exposure. A fresh owner may reset detector RNG:
  equal seed/configuration can replay training data. Qualification needs
  declared disjoint samples, for example a separately declared seed in the
  simulated endpoint; do not claim independent validation from replayed data.
- Required validation: actual transported dark/lamp frames, unchanged detector
  settings and exposure duration, truthful illumination reporting, distinct
  stage identities, and explicit qualification sampling provenance.
- Disposition: startup selection is recommended; live switching is deferred.

### CC-R3 — Scientific reduction and eligibility policy need an owner

- Severity: blocking design prerequisite. Confidence: confirmed inventory gap.
- Evidence: the existing `calibration_client.jl` uses public AOC probe-basis
  and structured interaction-matrix APIs. The package inventory found no
  public bounded dark/window mean, reference-window estimator, or measured
  eligibility-selection operation in current AOC/FGA. Existing
  `deployment/hil/calibrate_detector.jl` performs direct graph stepping and a
  noiseless optical-flat/reference calculation; `export_hil.py:242–259`
  invokes that historical fixture path. RTC-DEV-029 explicitly distinguishes
  it from operational calibration.
- Proposed remedy: add the smallest transport-neutral AOC/FGA operations
  needed by this campaign, using ordinary arrays and explicit policy inputs.
  Their owning package must define accumulation precision, sample-count
  bounds, nonfinite/overflow handling, reference convention, and result status.
  RTC composes those operations after complete capture; it must not copy cache
  Welford, centroid, threshold, or selection formulas into an RTC algorithm.
- Eligibility operates over the explicit deployed candidate universe, retains
  all 188 ROI positions and intrinsic flags, and never targets a fixed count
  of184. The prior measured policy (all training samples valid plus a declared
  minimum-flux margin and ADC clipping constraint) is evidence for one fixture,
  not a universal unannounced default. Selected policy and lamp level must be
  declared before observing qualification results. Empty selection rejects.
- Reference estimation must define whether it averages individual deployed
  centroid measurements or estimates a centroid from an averaged image; these
  are generally different operations. The narrow route is an explicit zero
  reference during training and a package-owned estimator over the individual
  deployed WFS responses. Do not average already-subtracted slopes and then
  silently treat them as absolute reference coordinates.
- Required validation: deterministic ordinary-array tests in the scientific
  owner, typed invalid-result handling, count/units/order checks, noisy sample
  reproducibility, and independent qualification after parameters are frozen.
- Disposition: scientific owner/API and policy require adjudication; no new
  generic calibration framework is needed.

### CC-R4 — Parameter submission cannot establish a stage boundary

- Severity: high if a running graph is reused. Confidence: confirmed source.
- Evidence: `src/control.rs:488–512` reports parameter replacement as
  `submitted`, explicitly `active_adoption_observed=false`. Operations requires
  submission and active adoption to remain distinct. The acquisition session
  copies its acceptance mask at preparation (`calibration_acquisition.jl:155–166`).
  Export binds it to the exact graph active selection
  (`export_calibration.py:324–343`). A changed graph mask without a corresponding
  owner policy would break that binding.
- Proposed remedy for this increment: finish restoration/release and shut down
  the stage, prepare a new candidate package with standard startup background,
  reference and active parameters, then require normal preparation/Ready before
  acquiring under that snapshot. FGN uses maintained startup parameters and
  construction fields; JFG uses the maintained `--parameter`/construction
  interface (`export_calibration.py:100–122,421–444`). Existing FGN startup-file
  handling permits Float32, so an active Bool mask must retain its supported
  construction representation; do not smuggle it through a Float32 parameter.
- Record exact startup artifacts and derive the owner mask from the deployed
  WFS declaration as today. A new session avoids changing graph parameters
  between receipts without an observable adoption boundary.
- Required validation: stale mask/background/reference rejection, exact mask
  binding, standard owner preload, and first accepted post-startup exposure
  using the declared snapshot. A future live update would additionally need
  correlated adoption, in-flight fences and one coherent parameter generation.
- Disposition: use fresh sessions; a live transaction is unnecessary here.

### CC-R5 — Campaign publication and recovery need an explicit boundary

- Severity: high. Confidence: derived from RTC-DEV-029 and current lifecycle.
- Evidence: the current server has terminal release and one served connection;
  the owner marks completion after `serve!` and waits for public quit.
  `calibration_server.jl:292–361` permits release only after acknowledged
  restoration. Failed adapters cannot be reused. Existing exporters require a
  new output directory and stage their output before publication.
- Proposed remedy: every stage is a finite session with an acknowledged
  reference restoration and release, followed by normal public stop/quit and
  owned-process cleanup. Reduce/analyze stage evidence only after that sequence,
  so a long scientific calculation does not accidentally consume an idle socket
  deadline. Build all stage results as campaign candidates. Publish a completed
  candidate artifact set only after required qualification and zonal estimation
  succeed; never overwrite an active calibration with a partial campaign.
- If transport or adoption outcome is unknown, preserve the original failure
  and the held/fault disposition. Attempt restoration only through the declared
  endpoint contract; report an unconfirmed attempt truthfully. Killing/restarting
  an owner is not proof that its old reference was restored. Do not retry an
  unknown request or reuse the failed adapter.
- Required validation: failure at each stage, scientific rejection versus
  transport failure, unsuccessful restoration, interrupted export, no active
  artifact replacement, and next-stage launch prohibited until the prior stage
  has the required terminal evidence.
- Disposition: campaign lifecycle contract required; no continuous-controller
  hold/restart or physical safety claim is implied.

## Recommended minimal campaign

| Stage | Deployed inputs and work | Accepted output / transition |
| --- | --- | --- |
| Prepare | Explicit Classic profile, normal detector settings, command units/order/reference, lamp setting, sample counts, candidate ROI mask, eligibility and qualification policy; finite stage/request/data budgets | Validated plan and new candidate directory; no active artifact replacement |
| Dark | Fresh dark initial-calibration session; hold, adopt declared reference through ordinary DM transport, settle, capture bounded raw plus complete WFS evidence | Complete identities and detector statistics; false WFS quality retained; restore/release/stop/quit |
| Dark analysis | Public scientific reducer over transported encoded ADC samples | Measured background with units/order/hash/sample identities; no direct detector graph call |
| Lamp training | Fresh lamp session with measured background, explicit zero WFS reference and original declared candidate universe; ordinary reference adoption and finite noisy capture | Individual slopes/flux/intrinsic validity/raw rail evidence; restore/release/stop/quit |
| Freeze | Public scientific reference/eligibility operations under predeclared policy | Candidate background/reference/mask and all excluded-row evidence; standard graph export only |
| Qualification | Fresh lamp session with frozen candidate parameters and held-out samples | Selected-channel validity, reference residual and ADC bounds checked against declared criteria; no reselection from validation results |
| Zonal | Existing public AOC probe preparation, `rtc-calibrate` completion protocol, normal demanded/adopted checks and complete WFS receipts | Accepted responses, fresh reference restoration/release, public AOC valid interaction matrix |
| Publish candidate | Verify the complete provenance and acceptance record | Atomic completed candidate artifact set; activation/reconstructor/correction remain separate |

Each session has the ordinary command/WFS graphs, raw observer, and controller
absence by topology. The application does not schedule frames based on a sleep.
Existing readiness polling may service lifecycle control, but elapsed time is
never evidence of adoption, settling, capture completion, or restoration.

The campaign driver can be a thin deployment-side coordinator that calls public
launcher/control interfaces and scientific package APIs. Keep the Rust runner
outside frame processing. Do not monkey-patch `session_acquire!` as the cache
diagnostic recorder did; implement one maintained, bounded capture path with
explicit ownership instead.

## Small bounded capture contract to adjudicate

Prefer an application-owned temporary artifact transfer for this local
simulation increment, with a bounded descriptor in the existing JSON reply.
This is a calibration evidence transfer, not a new graph configuration format
or a general durable recording service. It must be selected explicitly in
RTC-DEV-029 before implementation; the current six-action table does not
authorize silently adding a raw response variant.

1. The campaign declares a new owned staging directory, maximum frame count,
   total bytes, channels, and per-request deadline before any acquisition.
   Reject impossible extents and paths before effects. One Classic exposure's
   four fixed payloads total250,252 bytes. A16-frame window is about4MB; larger
   windows require an explicit budget, not an unbounded vector of frames.
2. The serialized owner acquires through the existing public session operation
   with complete transport association and `require_valid=false`. It retains
   each intrinsic quality flag. Nonfinite/missing/mismatched transport output
   still fails; accepting dark evidence does not relax interaction validity.
3. After all receipts and the publisher task have completed, copy/write from
   the public sink-owned arrays before admitting the next exposure. The arrays
   are borrowed until rearm; an asynchronous writer must own a bounded copy
   and be joined before releasing that storage. No file I/O or mathematics
   runs in a PipeWire callback.
4. Use existing packed array element types/layouts and exact byte counts. A
   small manifest associates every payload with complete domain, generation,
   sequence, model start/duration, stage/settings identity, quality and digest.
   The completion binds that manifest digest to the current run/request/probe.
   A final rename/manifest publication occurs only after all required bytes are
   written. The original deadline covers capture and final publication.
5. The producer keeps completed files immutable until the campaign consumer
   verifies their hashes and lengths. Define consumer completion/cleanup
   ownership explicitly; never overwrite a shared single file before its
   reader finishes. No arbitrary client-supplied path may escape the owned
   staging directory. A successful descriptor must not reference a partial
   file. Failed-stage cleanup must preserve the failure record and cannot
   delete a newer stage's files.
6. The scientific consumer streams/reduces one completed record at a time,
   under its own declared memory/data budget, after restoration/release.
   Intermediate artifacts remain candidates. Native ndarray transfer is also
   possible, but adding another live collector/acknowledgement lifecycle is
   unnecessary unless temporary artifact transfer is rejected by authority.

This transfer proposal requires a concrete reviewed schema and lifetime rule;
it is not an instruction to raise JSON limits, expose pointers, or send bulk
data through a control parameter.

## Closure and evidence plan

| RTC-DEV-029 obligation | Existing reuse | Additional campaign evidence |
| --- | --- | --- |
| Ordinary DM transport and explicit hold | Initial-calibration topology, requested/demanded/adopted checks | Every stage uses the same ownership/adoption path; rejected clipping retained |
| Normal detector background/reference acquisition | Noisy lamp/dark graph preparation, raw observer | Maintained illumination selection and bounded actual raw evidence, no historical noiseless export substitution |
| Unique associated exposures | Full UUID/generation/sequence/duration checks | Per-stage domain mapping, capture manifest correlation and held-out qualification |
| Declared units/order/settings/policy | Current plan/client/artifact descriptors | Training/eligibility/reference policies and immutable startup parameter snapshot |
| Event completion and finite deadlines | Existing request dispatcher, settling and task fences | Capture publication completion, stage transition fences, data/memory bounds |
| Restoration and interrupted-run disposition | Restore/release/fault server semantics | Failure injection across capture/reduction/export; no next stage or active replacement on incomplete campaign |
| Public scientific mathematics | AOC zonal preparation/structured estimator; deployed FGA WFS | Small scientific reduction/selection APIs and invalid-result handling |
| Shared artifacts require agreement | Prior actual FGN/JFG captured-payload comparison | Fresh campaign results and explicit comparison policy; equal seeds alone are insufficient |

Initial acceptance should demonstrate one automatic Classic CPU campaign from
declared inputs through measured offsets, frozen qualification and a valid
zonal matrix artifact, including bounded rejection and restoration paths.
Repeat with the second frontend and compare actual retained ADC/WFS evidence
before promoting shared numerical artifacts. This closes only the automatic
campaign slice; RTC-DEV-029 remains partial until its other selected scientific
and endpoint obligations are separately established.

## Independent production review — first implementation pass

Reviewed the uncommitted campaign/capture/exporter diff and the AOC
`ReferenceFrames` addition against the approved campaign extension now present
in RTC-ARCH-023/RTC-DEV-029 and `CALIBRATION_CAMPAIGN_PLAN.md`. This pass is source
review, not an installed campaign qualification. The reviewer did not modify
production files or run additional implementation tests.

### Confirmed findings requiring disposition

| ID | Severity / confidence | Evidence and consequence | Minimal remediation / validation | Disposition |
| --- | --- | --- | --- | --- |
| CC-R6 | High; source-confirmed | `calibration_campaign.py:run_stage` raises after a correlated `adopted` reply with `clipped=true`, then closes the connection and terminates the deployment. The server has completed adoption and remains held/adopted; no restoration is requested. Correlated pre-effect rejection has the same blanket abort path. This omits DEV029's abort restoration attempt for known outcomes. | Track known completion/rejection separately from unknown I/O/correlation outcomes. For a usable held endpoint, request bounded restoration and release only on valid restoration acknowledgment. Preserve the original failure and any recovery failure; never retry an unknown operation or reuse a faulted adapter. Cover clipped adoption and pre-effect rejection separately from timeout/disconnect. | Open; reported to parent immediately |
| CC-R7 | High; source-confirmed | `verify_capture` validates stage/run/serial and payload hashes, but not manifest probe, illumination/profile/settings/settings digest against the startup report/package. It does not compare the first exposure with the settled cursor or the last exposure with the returned completion cursor. A self-consistent wrong-settings/stale manifest can satisfy these checks. It reads the manifest before enforcing its size bound. | Supply explicit settled/startup/settings expectations; reject wrong probe, domain/generation, first/last sequence/time/duration and final cursor. Verify metadata size before reading/parsing, strict scalar types, declared settings digest and payload extents/hashes. Check resolved descendants stay under the owned directory, including ancestor symlinks. Add negative cases for each binding and oversized metadata before consumption. | Open; reported to parent immediately |
| CC-R8 | High; source-confirmed | `Endpoint.request` checks the host deadline only before `recv`; after receiving and parsing the final newline it accepts the reply without a new deadline check. A reply whose processing completes after the authoritative deadline can advance the campaign. `sendall` inherits the socket timeout from an earlier receive. | Establish one absolute deadline, set each I/O timeout from its remaining budget, and check again after completed read/validation before accepting any result. Late completion is an unknown outcome and must not trigger a fresh operation. Validate delayed final-byte/reply-processing cases. | Open; reported to parent |
| CC-R9 | Medium; source-confirmed | Recipes retain arbitrary Python Float64 reference values, while the endpoint adopts Float32. `run_stage` compares returned JSON numbers directly to the original recipe. For example, declared0.123456789 becomes Float32 and may serialize as0.12345679, causing rejection despite valid Float32 adoption. | Canonicalize reference/amplitudes through the declared finite/no-underflow Float32 policy before acquisition, and compare the exact wire representation. Apply the same canonical inputs to capture and AOC interaction planning. Check representable nonzero references and rejected overflow/underflow before effects. | Open; reported to parent |
| CC-R10 | Medium; source-confirmed | `stage_base` checks Classic/frame only; it does not reject a CUDA/AMDGPU base or contradictory source-owner backend, while the selected increment and campaign result claim Classic CPU. | Validate the actual declared backend in provenance and owner argv before preparing/launching a stage; reject unsupported or inconsistent profiles rather than implying qualification. | Open; reported to parent |

CC-R7 concerns the composing consumer's required checks. It is not evidence
that the current serialized native owner has produced stale data. CC-R8 is a
missing acceptance guard, not a claim of an observed live late-completion run.
These findings have concrete source paths but do not yet have synthetic or
installed fail-before/pass-after evidence; remediation owners should add the
narrow corresponding cases.

### Confirmed preservation and numerical assessment

- Capture production uses the settled-to-collected state transition, current
  probe and exact after-cursor validation. Capacity is reserved before any
  exposure; the4096-frame and cumulative payload limits remain finite.
- Each capture waits for the existing complete raw/WFS receipts and joined
  publisher before writing borrowed sink-owned arrays. The serialized task
  finishes all four synchronous writes before acquiring/rearming another
  exposure. No extra callback processing or independent writer lifetime was
  introduced.
- The manifest is written last through a temporary file and rename, with
  deadline/connection checks. Failed execution discards a pending manifest.
  Payloads have fixed types/extents and metadata is separately bounded.
  Complete quality-invalid dark evidence is retained without becoming a valid
  interaction response; ordinary `collect` semantics remain unchanged.
- Owner startup now selects lamp/dark and records it. The exporter refreshes
  maintained orchestration sources while retaining the supplied scientific
  packages/manifest and records per-file hashes. Fresh stage exports retain
  standard startup parameter bindings and owner-mask derivation.
- The campaign creates a new output root and writes only candidate artifacts.
  It never replaces active calibration files. It uses ordinary DM adoption and
  the existing AOC zonal/coordinator route for interaction acquisition.
- AOC dark moments implement per-pixel Float64 Welford mean and unbiased
  variance M2/(N−1), resetting scratch each complete batch. Array axes are
  explicitly one-based and exact dimensions/aliasing are checked before
  processing. Mean units are ADC counts, variance units are ADC counts squared.
- AOC lamp references average individual deployed centroid samples in Float64;
  they do not centroid an averaged image. Eligibility is all-samples intrinsic
  validity plus the declared minimum-flux threshold. Any raw value at/above the
  upper rail invalidates the whole lamp batch. Nonfinite inputs/intermediates
  invalidate; no eligible ROI has its own status. Diagnostics retain every ROI,
  with excluded reference entries zero and no fixed expected active count.
- The raw row-major-to-Julia transpose and reverse conversion for background
  are correct. The376-row centroid input preserves the wire's interleaved pair
  ordering; reference output remains188×2 in packed wire order. Matrix output
  explicitly transposes to its declared ROW_MAJOR representation.
- Qualification adds the explicitly frozen deployed reference to actual
  residual samples in Float64, invokes the same public AOC calculation, and
  compares selected means to that frozen reference. This is a known coordinate
  conversion, not hidden AOS truth. It does not reselect or overwrite the mask.
- No confirmed numerical defect was found in the AOC methods for the documented
  scalar CPU, one-based array contract. The campaign's hard limits bound its
  complete-batch allocations. Generic GPU support is neither implemented nor
  implied by the algorithms' AbstractArray signatures.

### Remaining verification and claim limits

The capture writer and analysis reinterpret native memory while labeling files
U16_LE/F32_LE/F64_LE. The selected x86 host is little-endian, so this is not a
blocker for that explicitly limited run. Add an explicit little-endian guard
or portable conversion before claiming another byte order; the current code
must not imply architecture-independent serialization.

The existing deployment launcher does not reject all nonzero child returns
in `wait_owned_process`. `shutdown_confirmed` currently checks successful
public control, launcher exit/state and runtime removal; these checks alone do
not prove every child exited0. Retain the distinction in campaign evidence,
and inspect terminal owner and child outcomes in installed verification.

Package/analysis source versions, exact recipe, candidate array hashes,
startup report, complete domains, request/reply records and stage outcomes
must be retained. The new stage-result and campaign-result records alone do
not replace actual installed negative and full successful campaign evidence.
Numerical precision, physical observability,221-coordinate map composition,
reconstruction, activation, correction quality and rate remain separate gates.

Source snapshot hashes for this review pass (production may advance afterward):

- `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-calibration-campaign/deployment/calibration_campaign.py`: `481dfcc6fd7fbf65e6608a89f47cb322a5222a515830f45190312459b5278c0b`.
- `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-calibration-campaign/deployment/hil/calibration_campaign_analysis.jl`: `a898e0a9cb5421532458ab2ca58e5bac4aa30ac2856f6db01472710f546f145a`.
- `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-calibration-campaign/deployment/hil/calibration_server.jl`: `db246dbf904f28d69eb2da98794e33c0a377d62cb8890e68d52e6791bc2ce5f3`.
- `/home/dgamroth/workspaces/codex/AdaptiveOpticsCalibration-reference-frames/src/reference_frames/dark_frame_moments.jl`: `f578d4a8234f3e9a096d8533090b4dfdca77cf866a4ed6220178173c3ced840a`.
- `/home/dgamroth/workspaces/codex/AdaptiveOpticsCalibration-reference-frames/src/reference_frames/lamp_reference.jl`: `73cdaf209e19e00858a784c97cd9d890ab3be08ebfb26fdd32c85050ccf3ede0`.

## Remediation verification — second source pass

Independently reran `python3 -m unittest test_calibration_campaign
test_export_calibration` from `deployment`: **20 tests discovered,19 executed
and passed,1 environment-dependent skip**, exit0. These tests exercise recipe
validation, Float32 equivalence, capture binding/bounds, known rejection versus
unknown correlation, and late reply handling. This is software verification;
no installed campaign result is promoted here.

| Finding | Verified change | Current disposition |
| --- | --- | --- |
| CC-R6 | Endpoint distinguishes correlated success/pre-effect invalid_evidence from unknown endpoint/I/O/correlation failures. `run_stage` now attempts bounded restore and then release for a recoverable known outcome, preserving original and recovery failures. Clipped restoration forbids release. | Source correction verified; focused Endpoint recovery tests pass. Full stage recovery and installed interruption evidence remain integration obligations. |
| CC-R7 | Manifest size is checked before reading; stage/probe/profile/illumination, startup settings/digest, full-domain mapping, first-after and final cursor are now compared. Descendant symlinks are rejected. | Partial: expected exposure duration and startup generation are not yet bound; header/domain scalar types remain permissive. See residual below. |
| CC-R8 | Each request resets socket send timeout from one deadline; success checks deadline after JSON parse and after result validation. Existing late-reply negative test passes. | Partial: correlated invalid_evidence branch enables recovery before the final validation deadline check. |
| CC-R9 | Recipe reference and amplitudes are canonical Float32; returned figures compare packed Float32 bytes. Public AOC plan preparation now runs before the first deployment launch, rejecting lost absolute probe deltas before acquisition. | Source/software correction verified. |
| CC-R10 | Source package must declare Classic/frame/CPU and source-owner argv must contain one CPU backend option. | Source correction verified; malformed/unsupported backend rejection is pre-effect. |

Capture writer, analysis reader and campaign now explicitly reject a non-little-
endian host. The earlier byte-order limitation is closed by rejection rather
than an untested portable serialization claim. AOC ReferenceFrames is committed
at `3c11576fe65ca4998f1357d0210bb399d68e7b12`; the independent numerical/axis
assessment remains unchanged. No new scientific defect was found.

### Remaining CC-R7 and CC-R8 checks

`verify_capture` currently requires positive exposure duration but does not
compare it with the declared startup detector exposure. A manifest with changed
positive durations and a correspondingly changed completion cursor remains
self-consistent and can pass. Bind every duration to the declared startup
exposure and require the initial/settled generation to match the startup report.
Also validate exact integer types/ranges for manifest version/run/serial/probe/
frames/bytes, and all16 complete-domain bytes. Python equality currently admits
values such as `probe=false` or `frames=2.0` as equal to their integer forms.
These are malformed-evidence acceptance gaps, not observed bad native captures.

The `failed/invalid_evidence` branch in `Endpoint.request` raises before the last
host-deadline guard. Check that deadline immediately before enabling restoration
for a validated rejection, as done for successful completions. A late rejection
must not become new operational authority.

### CC-R11 — Readiness can belong to another launcher

- Severity: high. Confidence: confirmed source race.
- Evidence: `calibration_campaign.py:wait_state` reads `runtime/state.json` and
  returns a matching `phase=running` before checking the newly spawned process.
  It never checks that the state's launcher PID equals `process.pid`.
- Failure mechanism: reuse `--runtime/stage` while an earlier deployment is
  still running. Its existing running state can satisfy the new campaign's
  readiness predicate immediately, before the new launcher fails its runtime
  lock. `run_stage` then takes the older state's socket path and can issue
  calibration/control requests to the unrelated owner.
- Remedy: validate readiness/error state ownership against the newly launched
  PID and expected instance before accepting it. An unrelated old state must
  never authorize opening an endpoint or sending public control. A live-process
  check alone is insufficient because the new launcher can still be starting.
- Required validation: retained running state for another PID; newly spawned
  launcher still alive or exiting on lock; prove zero calibration/control
  requests to the unrelated instance. Verify normal matching-PID readiness.
- Disposition: open, reported to parent immediately. This blocks general
  campaign release even if an isolated fresh-runtime fixture succeeds.

Source snapshot for this pass:

- `deployment/calibration_campaign.py` SHA-256 `21bff177c91b39ec99ba48717e0b7d35de46c8e48664c33c8ea1dd9f0a1d51ee`.

- `deployment/test_calibration_campaign.py` SHA-256 `5a3fd8c9bf75feb9f5f644475de471ca82fcea289cbc9fef03aa88b56abc0045`.

- `deployment/hil/calibration_campaign_analysis.jl` SHA-256 `a0997f6c414b6860d8aa8cd0eb3b1ef91cda5c04a614482826030ade2d0f8412`.

## Final residual-guard verification — 2026-10-02

The latest source closes the remaining source defects in CC-R7, CC-R8 and
CC-R11. This supersedes their open/partial dispositions above without removing
the original failure analysis.

- **CC-R7 — corrected.** Manifest identity/count fields require exact Python
  integer types. The complete acquisition domain requires sixteen integer
  bytes and a nonzero identifier. Every exposure duration equals the startup
  detector duration converted to nanoseconds; the settled generation must
  equal the startup generation. Existing startup settings, digest, probe,
  first-after and final-cursor checks remain. This is source verification; the
  focused suite does not individually exercise every malformed scalar variant.
- **CC-R8 — corrected.** The correlated `invalid_evidence` path checks the
  original host deadline immediately before granting restoration authority.
  The added late-rejection test proves it leaves `can_restore=false`. Success
  retains its post-validation deadline check.
- **CC-R11 — corrected.** `run_stage` rejects an existing or symlink runtime
  directory before launching. `wait_state` requires the state PID to match the
  newly owned launcher and checks that process is alive before invoking the
  readiness predicate. The foreign-running-state regression rejects an old
  state even with an otherwise always-true predicate. No foreign endpoint is
  opened by this path.

Independent rerun: `python3 -m unittest test_calibration_campaign
test_export_calibration` from `deployment`: **22 discovered,21 passed,1
environment-dependent skip**, exit0. No installed automatic campaign or
scientific acceptance result is claimed by this review. Previously recorded
shutdown-evidence limits remain.

Reviewed source SHA-256:

- `deployment/calibration_campaign.py`: `d61954c327c589af17657d3facfbae5196d063447448abb100729e42cf3c8fda`.
- `deployment/test_calibration_campaign.py`: `adbc483620e78f32bb1bc9b33787d48316a13aa3c3b3326818040cc9911413af`.
