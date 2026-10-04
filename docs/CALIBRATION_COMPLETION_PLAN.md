# Calibration completion plan

## Question and scope

Can measured, noisy AOS detector responses through the deployed RTC interfaces
produce useful, reproducible reconstructors for Classic and Copper, and can
the same procedure be used with FGN, JFG, unchanged HEART and available
accelerator simulation? This is simulated scientific qualification under
RTC-ARCH-023 / RTC-DEV-029, not physical instrument qualification.

Starting RTC revision: `6f57ea48b2620fe13b9d09a08a02ee4aeca755ce`.
Worktree: `pipewireao-rtc-calibration-completion`, branch
`work/calibration-completion-20261003`. At plan creation, the canonical RTC
checkout was clean and the AOS checkout had unrelated changes to preserve. Each acquisition
seals its actual copied sources, detector settings, graph arrays and binaries;
repository revision alone is not sufficient provenance.

## Five steps and existing evidence

| Step | Existing evidence | Remaining work |
| --- | --- | --- |
| 1. Flat illumination and probe characterization | Classic noisy ADC and amplitude study; Copper 10× screen inadequate, 100× matching-reference screen has measurable repeated response without saturation | Retain these provisional detector limits in subsequent scientific claims |
| 2. Repeated interaction matrices | Classic full zonal/Hadamard and modal acquisitions; six Copper captures per FGN/JFG engine complete with matched matrices byte identical; all six native Copper captures pass acquisition, public shutdown and candidate reduction | Preserve paired-source and method-cost evidence |
| 3. Method comparison and held-out prediction | Classic selected 206-mode Hadamard inverse; Copper FGN/JFG independently selected 248-mode Hadamard inverses; locked and spatial forward validation passed; native grid, selection, locked and partial-span spatial utility independently reproduced; CUDA-derived inverse passes actual paired AMD directional transfer | Retain partial-span and probe-energy accounting |
| 4. Coordinates, reconstructor and correction | Classic 277→221 composition and finite FGN/JFG CPU, CUDA, AMD and native HEART correction pass; Copper 277→253/rank250 composition, FGN/JFG CUDA, FGN AMD and selected native HEART correction pass | Preserve finite-corpus limits and dropout diagnostics |
| 5. Unchanged HEART and accelerator acquisition | Native deferred Copper reference, training, selection, locked utility and active correction pass with bound evidence; full CUDA cohort and paired AMD directional transfer/normal correction pass; all four selected Classic accelerator correction cases and native Classic correction/reset/replay pass | Ordinary native Copper streaming CCR-017 remains a separate qualification gate |

Reuse the completed Classic evidence in `CALIBRATION_METHOD_SELECTION.md`;
do not rerun a full acquisition merely to replace its historical orchestration
language. Qualify the maintained Julia entrypoints with bounded checks.

## Frozen first Copper experiment

Compare the prior magnitude 5.752574989159953 pilot with a magnitude
3.252574989159953 lamp (10× incident flux). Acquire a matching dark/training/
independent-reference candidate first. Preserve exposure, gain, noise, background
estimation, geometry and settling policy. Use actuator 139, physical probes
±0.04 µm OPD, eight accepted exposures per signed batch, two opposing sign
orders, null brackets, a fresh detector seed, and one completed discarded
exposure after each adoption. Freeze exact recipe files before starting.

The current detector fixture has gain 1 and excess-noise factor 1. It is a
provisional noisy unity-gain EMCCD model, not a qualification of the DU860
settings discussed with the user. Report this distinction with the result.

No scientific acceptance is inferred merely from brighter illumination or
FGN/JFG byte equality. Record signal size, repeated derivative disagreement,
null-response variability, ADC saturation, normalization intensity and
first/later exposure behavior. The result determines the cheapest next
discriminating experiment; retain failed screens and source identities.

## Acceptance and decision rules

Before a full method cohort, freeze its recipes, actuator basis, units,
measurement order, null/settling policy, estimator, validation directions,
locked test directions and selection rule. Separate training, selection and
locked-test data. There is no supplied instrument accuracy threshold.
Finite-corpus utility requires finite predictions and improvement over the
zero-response/zero-command baseline in both signed repeats and declared nonzero
direction groups. Null directions are separately reported bias/noise diagnostics:
the exact zero-command predictor has zero loss for a true null. Report both raw
and baseline-projected forward errors and the removed sensitivity. The new seed
and measured reference also differ from the old pilot, so the brightness screen
is a discriminator rather than a causal flux-only estimate.
Do not claim population uncertainty from two repeats or
independent exposures when normalization introduces correlation.

Keep the 253 Copper wire coordinates. Source inspection of a recorded base
found three exactly unactuated controller coordinates; verify the selected
base bytes and actual rank before composition. Never assume selector maps are
transposes or that a physical prefix is the controller coordinate system.
For absolute four-pupil measurements, test the candidate inverse on actual
flat-lamp outputs: offline signed differences alone do not establish unbiased
deployed correction. Any baseline-rejection or centering policy must also be
implemented in each qualified deployed path and exposed in provenance.

Report acquisition, startup, estimation and shutdown time separately, along
with exposure count and command energy. A partial spatial sine basis is
qualified only over its measured span; compare full inverses only on supported
coordinates. Completion-driven model time and wall-clock frame rate are
different quantities. GPU availability/preparation, calibration, correction
and cadence are separate gates. No fallback qualifies an unavailable backend.

## Execution and evidence

Use Julia operational owners, normal simulated DM transport, noisy ADC and
deployed WFS algorithms. Restore the reference figure, release ownership and
confirm public shutdown before analysis or the next stage. Preserve unknown
outcome faults. No edits to HEART, host power/IRQ/scheduler policy, or unowned
processes. New artifacts belong under
`~/.cache/rtc-calibration-completion-20261003/` with immutable completed capture
manifests and hashes. Independent findings and dispositions are recorded in
`CALIBRATION_COMPLETION_REVIEW.md`.

## Normal correction ADC policy alignment

This decision follows the failed first complete native Copper correction
window; it is not a retrospective pass. That window reaches the 14-bit ADC
rail in two pixels, at exposures 21 and 26. Independent retained-payload checks
find the same two rail locations in both reset batches of the prior FGN CUDA,
JFG CUDA and FGN AMD correction runs. Native phase handling and zero restoration
complete, but the native owner rejects the window using a stricter zero-rail
rule than the original normal-correction verifier.

For a fresh normal-correction run, use the original common acceptance rule:
every encoded ADC value must be within the declared detector range; exact ADC,
command association, direct truth and zero-command replay must pass; correction
must improve over zero in each declared finite window; and the independent
physical DM witness must exclude limiting. Count and retain every saturated
pixel and affected exposure, including initialization. Independently recompute
these diagnostics from retained detector payloads and reject inconsistent
reports. Do not omit saturated samples, refit the inverse, change illumination,
tune gains or select different evaluation windows.

The new native source and contract must seal this policy explicitly and pass a
fresh two-window/reset/restoration/shutdown/replay run. Preserve the failed
window and its false lifecycle gates. This qualifies correction with the
declared quantized detector model, not unsaturated operation or instrument
headroom. Held calibration/reference/probe captures retain their predeclared
zero-rail admission rule; no measured matrix or prior selection is changed.

## Classic normal subaperture-status policy

This decision follows the failed native Classic package4 first exchange and
applies only to a fresh normal-correction run. It is not a retrospective pass.
The retained first response has 182 eligible valid subapertures and two with
state 0 because their measured fluxes, 947.1875 and 989, are below the unchanged
1,000 threshold. All four permanently inactive regions have state −1 and zero
slopes. These are normal dynamic dropouts, not zero-lag initialization.

HEART excludes each non-active subaperture from reconstruction. Independent
recalculation of its actual first VDM using the dynamically masked slopes agrees
within 6.16 × 10⁻⁸ µm; using the unmasked slopes misses by 0.02585635 µm.
FGN/JFG likewise emit zero measurement contributions below their matched flux
threshold. The adapter's whole-frame valid-response requirement was inherited
from strict calibration and rejects this normal behavior.

A fresh Classic normal fixture must bind an explicit per-subaperture policy:
validate every native state against the sealed flux thresholds and permanent
mask; reject inconsistent classifications or nonfinite payloads; retain raw
slopes, validity states and all detector samples; and report dropout exposure
and subaperture counts. Do not relabel affected frames as fully valid. Native
masking, FGN/JFG algorithms, inverse, illumination, detector, coefficients and
evaluation windows remain unchanged. Exact ADC/command/direct-truth replay,
positive correction utility in every declared window, no DM limiting, reset,
zero restoration and public cleanup remain mandatory gates.

Held calibration and reference acquisition still require valid eligible probe
responses. Copper's first zero-lag initialization rule is unchanged. Preserve
the original failed Classic package4, source snapshot, raw records and false
gates. Observed dropout counts establish neither instrument tolerance nor
physical-loop qualification. Independent finding CCR-034 records this
post-observation policy correction and its engineering basis.

## Progress

Historical checkpoint before active correction: all six deferred native Copper training captures and the
native grid pass independent review (123 assertions, 21,566 input hashes, all
six packed candidates reproduced bitwise). Native reserved validation independently
selects the 248-mode Hadamard inverse; frozen selected-only locked utility passes.
Spatial held-out prediction passes in the measured 64-mode span. Independent
review approves both locked and spatial utility. Active correction remains a
separate gate.
All four selected Classic FGN/JFG CUDA/AMDGPU correction cases pass both reset
batches and both backend replays. Native Classic preparation must bind the
accepted operational background, reference slopes and fixed mask; historical
HEART slopes/mask differ and cannot qualify the simulation-derived inverse.

These entries preserve the sequence of decisions and failed attempts. The table
above and [current evidence](CALIBRATION_COMPLETION_VALIDATION.md) state the
completed and remaining gates.

- Plan recorded before new acquisitions.
- At plan creation, prior Classic finite CPU scientific evidence was identified;
  Copper, unchanged HEART calibration and accelerator scientific gates were open.
- The 10× brighter flat has mean pupil intensity 273.825 ADC and maximum 438,
  below the 16,383 rail. Its ±0.04 µm, N=8 opposite-order derivative comparison
  has cosine 0.68045 and relative difference 0.79737. This is insufficient
  evidence for selecting a full inverse. Next declared screen: 100× original
  illumination (magnitude 0.752574989159953), matching independently measured
  reference (32 training and 32 qualification exposures), amplitudes
  0.02/0.04/0.08 µm, N=16 per signed batch, two orders, null brackets and fresh
  seeds 521–524. Preserve all other detector/model settings. ADC saturation,
  clipping or invalid completion blocks full-matrix admission.
- The Julia pilot initially failed before any acquisition with a missing
  `HILExport` import in `CopperQuality.source_snapshot`. The worktree fix and
  a frozen copy of the corrected owner completed the same pilot successfully;
  retain the initial failure log. No active graph calibration was changed.
- Actual backend imports report CUDA functional on RTX 3080 and AMDGPU
  functional on Radeon gfx1030. These are availability checks only.
- The 100× lamp reference has mean intensity 2,744.16 ADC and maximum 3,990;
  independent qualification maximum is 4,001. Opposite-order derivative cosines
  for 0.02/0.04/0.08 µm are 0.91956/0.97737/0.99421; relative discrepancies are
  0.40208/0.21295/0.10753. These establish a measurable pilot response, without
  an instrument accuracy claim. Proceed to candidates and independent held-out
  testing at 0.04 µm zonal and 0.01 µm Hadamard, N=16, two fresh seeds and
  reversed chronology. Both remain unaccepted until held-out scoring.
- CUDA and AMDGPU each completed the same finite 35-exposure deployed noisy
  detector probe smoke, with zero ADC rail hits and confirmed restoration,
  release and shutdown. These prove operational acquisition, not a useful full
  inverse, correction or a 500 Hz wall-clock rate. An initial 90-second cold
  preparation deadline was insufficient; the explicit finite preparation
  budget is separate from scientific operation deadlines. A stale lifecycle
  cursor in final-report retention was corrected using the current public
  pause acknowledgement; failed captures remain preserved.
- Copper FGN CUDA zonal repeats each acquired 9,419 exposures and produced
  3,600×277 candidate matrices. ADC maxima were 4,636 and 4,611, with no rail
  hits; all three lifecycle gates passed. Acquisition took 166.03 and 166.79
  seconds, separate from startup (133.02 and 137.53 seconds). Their relative
  matrix disagreement is 0.25679. The predeclared repeat-scale cutoffs yield
  training ranks 221/185/135; these are training diagnostics, not selection.
- Both full FGN Hadamard captures acquired 17,409 exposures, maximum ADC
  4,679, zero rail hits and all lifecycle confirmations. Acquisition took
  295.41/291.42 seconds and startup 133.04/133.50 seconds. Their relative
  matrix disagreement is 0.04608 and training ranks are 248/235/219. The
  differing matrix hashes and detector seeds are recorded; identical ADC
  maxima do not imply identical captures. Compare the unequal probe energy
  and acquisition cost before attributing improvement to method alone.
- Both 64-mode FGN spatial captures acquired 2,177 exposures, maximum ADC
  6,205/6,190, zero rail hits and all lifecycle confirmations. The actual
  physical directional span has rank 64; relative mode-matrix disagreement
  is 0.01669. This supports only a partial-span comparison, not a complete
  physical reconstructor. Independent within-span validation remains required.
- The first matching JFG zonal capture acquired 9,419 exposures, maximum ADC
  4,636 and no rail hits, with all lifecycle confirmations. Its candidate
  matrix and canonical absolute batch means are bit identical to FGN's
  seed-531 capture. This is calibration-measurement equivalence; selected
  inverse and closed-loop equivalence remain separate gates.
- Both matching JFG zonal and Hadamard repeats are now complete. All four
  candidate matrix payloads and complete public calibration response documents
  are byte identical to their matching FGN acquisitions. Each passed ADC,
  restoration, release and shutdown checks. The second Hadamard capture took
  295.61 seconds for acquisition and 109.59 seconds for startup, separately
  from reduction (6.82 seconds). This establishes equivalence on the measured
  calibration corpus; independent selection and deployed correction still
  require their own evidence.
- The initial N=64 held-out collection was rejected before side effects:
  its conservative encoded-reply budget exceeded the former 64 KiB protocol
  limit. Both Julia admission and Rust transport now use 128 KiB. The old
  failure is preserved and an immutable alias ledger identifies the retry
  with unchanged seed, probes and estimator. The retry completed 1,041
  exposures, maximum ADC 5,804, no rail hits or invalid frames, and confirmed
  restoration, release and shutdown. It is not a numerical selection result.
- Native standard-DM receipt, matching DM telemetry and positive relay
  adoption now pass after source-defined telemetry name/filename corrections.
  The first actual detector frame also appears in native raw and calibrated
  records with matching sync identity, but no measurement record arrives.
  The v9 diagnostic explicitly shows the processor polling calibrated bucket
  1 while the delivered frame is bucket 0. Source review is determining a
  public configuration/transport remedy; unchanged HEART calibration remains
  unqualified. Diagnostic logging is excluded from scientific timing claims.
- Copper FGN held-out selection chose `hadamard-1`, rank 248, cutoff
  0.8230663662, from the frozen six-candidate grid. Both validation seeds
  551/552 passed sparse and mixed groups: pooled physical command SSE
  0.01312843/0.01439414 versus zero-command SSE 0.60150538. The selected
  Float32 estimator SHA-256 is
  `7be960b755ac8aede4b762db47d6084bd6cf75a9c569c24e774a1610360b698b`.
  Its bytes and negative controller representation were frozen before the
  independently acquired locked tests, seeds 553/554. Both locked tests
  passed the same declared group gates: SSE 0.02335807/0.02334386 versus
  zero-command SSE 0.68178564. Each acquired 1,041 exposures, maximum ADC
  5,712/5,674, with no rail hits or invalid frames and all lifecycle gates.
  These are finite N=64 averaged-input utility results; deployed dynamic
  correction and per-exposure performance remain unqualified.
- The first cold scorer invocation used an uninstantiated source-template
  project and failed before numerical selection. The preserved retry uses
  the captured backend HIL project, one Julia thread and one BLAS thread;
  independent review recomputed the actual validation scores and winner.
  Correction admission independently recomputes the frozen grid scores and
  binds both validation and locked capture identities. Local run numbers
  intentionally repeat across families; distinct frozen seeds and sealed
  acquisition identities establish cross-family separation.
- HEART v10 did not exercise the pacing hypothesis: its 128-byte probe CSV
  pathname was truncated by the legacy 128-byte command field to a `.cs`
  filename, and native loading failed before any exposure. The previous
  127-byte pathname and CSV bytes were verified. Preparation now checks the
  127-byte maximum, reserving the entire probe-sequence filename range; the
  fresh v11 retry uses a short evidence directory. No native source changed.
- The paced native v11 retry produced the correct first measurement and frame
  association, but the adapter then required a positive timestamp from the
  auxiliary calibrated-pixel buffer. Actual source/data show that this buffer
  can carry timestamp zero with complete progress, positive duration and the
  correct bucket/sync. The narrow auxiliary check now follows that contract;
  raw and measurement timestamps and pixel/frame association remain strict.
  The fresh v12 retry passed all 10 exposures and exactly four manual native
  DM records, restore/release and public shutdown. Its first declared settling
  exposure alone is invalid because reconstruction pixels initialize to zero;
  all accepted responses are valid, ADC maximum 4,417 and no rail hits. This
  is a bounded native interface result, not a full interaction matrix.
- Copper FGN's selected negative estimator completed two normal dynamic
  256-frame CUDA simulation batches with exact frame/command counts, identical
  ADC, command and direct OPD-witness records after reset, and clean public
  shutdown. The captured-project cold replay verified the live OPD witness
  and zero-command baseline. Residual/atmosphere variance ratios are
  0.71547319 for frames 17:128 and 0.64897217 for 129:256; both pass the
  predeclared finite ratio < 1 gate. Peak demand is 0.15338954 µm OPD with
  no components at the preserved 0.8 µm limit. Gains/poles remain unchanged;
  this does not qualify wall-clock cadence or instrument convergence.
- Independent review reproduced an invalid native reduction admission:
  unrelated FGN response JSON and an unrelated stopped runtime could be
  labeled as HEART evidence. CCR-016 blocks full native candidate reduction
  until actual native records, captured measurements, owner reports and the
  acquisition's public shutdown are bound and revalidated. No full native
  matrix acquisition was launched through that incomplete gate.
- CCR-016 remediation binds the actual native streams, adopted figures,
  measurements, public means and acquisition runtime through public shutdown.
  The original counterexample now fails before candidate creation. A fresh
  nondebug seven-exposure N=2 native acquisition passed all three gates:
  acquisition, public shutdown, and AOC candidate reduction. Its resulting
  3,600×1 matrix remains a functional candidate, outside the scientific cohort.
- All six matched JFG training matrices are byte identical to FGN. Independent
  construction review approved JFG's six-candidate grid. Packed inverses differ
  in only 8–17 coefficients per matrix; relative matrix differences are below
  3.4×10⁻¹⁰. Exact input/map equality is verified; the execution mechanism behind
  the tiny rounding differences is not established. JFG's own held-out data
  independently select the 248-mode `hadamard-1` inverse, with physical SSE
  0.01312843/0.01439414 versus zero-command SSE 0.60150538. The selected bytes
  are frozen before locked tests and dynamic correction.
- JFG's independently acquired locked tests pass both sparse/mixed groups:
  physical SSE 0.02335807/0.02334386 versus zero-command SSE 0.68178564.
  Its selected inverse passed a complete independent admission recomputation,
  including all validation and locked scores and 5,141 bound input hashes.
  The normal correction package preserves the graph, gains, maps, dynamic
  atmosphere and detector; actual correction acquisition remains a separate gate.
- Native reference training passed 34 exposures, with 32 accepted responses,
  zero ADC rails and confirmed public shutdown. Qualification reference failed
  on exposure 4: native processing reported reader counter 2→4 and deliberately
  published a committed invalid gradient (bucket 3, sync 3) while raw/calibrated
  bucket 3 carried sync 4. The adapter correctly rejected it. Failed restoration
  and shutdown remain failed; owned processes were subsequently reaped.
  CCR-017 preserves this ordinary-streaming failure. The existing comparison
  build's explicitly selected deferred Copper ingress is being qualified
  separately for completion-driven calibration: both packets are received before
  first-half release, with native processor/reconstructor snapshot handshakes
  before final-half release. This changes availability and synchronization.
  It cannot establish ordinary progressive delivery or hardware cadence, and
  does not resolve CCR-017 for the streaming mode.

## Copper cohort and selection policy

The frozen first full cohort uses zonal seeds 531/532 and Hadamard seeds
533/534, the independently measured 100× lamp background/reference, and one
discarded exposure after each adoption. Retain noisy 14-bit acquisition. The
complete Hadamard cycle has 512 patterns, 1,024 signed batches; zonal has 554.
With the selected amplitudes and equal N=16, Hadamard spends 32× the signed
command energy of zonal. Report this cost alongside acquisition/estimation
time and uncertainty diagnostics rather than attributing any difference to
method alone. A separately measured 64-direction spatial sine/cosine basis
will be scored only over its measured span.

Use the exact command map B and orthonormal actuated physical basis U from its
thin SVD. Fit the paired mean D̄ = (D₁ + D₂)/2, with projected response Q D̄ U,
using public AOC TSVD and publish
R = W K Q, B W = U, as described in the independent review. Fit projection
before inversion and preserve exactly zero wire rows. Compare empirical cutoff
multipliers 1, 2 and 4 applied to δ = ½‖Q(D₁ − D₂)U‖₂.
This is an empirical repeat/order scale, not a confidence
interval. Candidate construction must reject zero-rank or nonfinite inverses;
do not retune this grid after validation.

Fresh validation uses physical-basis columns 20, 60, 120, 200 and four mixed
directions from fixed RNG seed 1051; normalize physical peak to 0.04 µm OPD.
Use 64 accepted exposures per signed batch, detector seeds 551/552 and opposing
chronology. The locked test uses different columns 35, 85, 155, 230 and mixed
directions from seed 1052, detector seeds 553/554, with the same declared
amplitude/averaging. Freeze exact represented Float32 figures and direction
metadata before admission; input basis signs/arrays are recorded, not inferred
again from a later SVD.

The primary loss uses the packed inverse on absolute N=64 batch means:
Σ±‖B R y± − (±q)‖₂², where q is the represented Float32 physical probe.
An eligible candidate must improve this pooled physical command squared error over
the zero-command predictor in each nonzero direction group and both repeated
validation acquisitions. Signed-difference inverse loss is a separate diagnostic
and does not control eligibility or ranking. Disclose fresh flat-lamp bias, raw and projected forward error,
projection loss, optical rank and clipping. Choose the lowest worst-repeat
physical squared error; ties prefer the larger cutoff then lexical family.
Freeze the selected packed bytes before the selected-only locked test. A failed
locked or correction gate remains failed and does not trigger new tuning.
The existing controller gains, poles, anti-windup and physical limits remain
fixed for correction checks.

### Estimation and correction polarity

Source review before any held-out validation or correction confirmed that the
copied plant adds DM surface OPD, and the Copper controller uses positive gain
0.01 with pole 0.99. The estimator R above predicts the positive physical
probe, so the correction artifact for this preserved controller is
R_ctrl = −R_est. Primary estimation scores B R_est y against q are equivalently
correction scores B R_ctrl y against −q. This representation conversion does
not change the selection losses, cutoff grid or controller coefficients.
Record both artifact identities and the source-derived polarity. Check each
engine's actual recurrence before deployment; Classic and native HEART must
not inherit Copper's sign without that check. Independent review CCR-010
records the equations and the ideal 50% static residual limit from the
preserved Copper leak/gain. No near-zero or cadence claim follows from it.

The exact basis and Float32 validation, locked-test and 64 spatial sine/cosine
figures are frozen in `~/.cache/rtc-calibration-completion-20261003/frozen-directions/`.
Spatial acquisition uses 0.04 µm peak, N=16 and detector seeds 535/536;
geometry comes from the copied plant's public `actuator_coordinates` in its
277-element physical order. The manifest seals the actual prepared plans,
recipes, map basis and preparation source. Averaged-input selection does not
establish per-exposure noise or closed-loop utility; correction is an
independent deployed gate.

- JFG normal Copper CUDA correction completed two 256-frame public stop/reset/restart batches, with exact within-engine reset payloads and live truth. Actual CUDA replay verifies every ADC pixel, the direct OPD witness and the zero-command baseline. Residual/atmosphere variance ratios are 0.71547328 (frames 17–128) and 0.64897240 (129–256), close to FGN's 0.71547319/0.64897217. Peak command is 0.15338977 µm OPD, with no components at the limit. Requested-minus-demanded clipping feedback is not recorded by this diagnostic; clipping correctness remains covered by the separate earlier algorithm tests. This is finite simulated correction, not wall-clock cadence or instrument qualification. Evidence: `jfg-correction-cuda-v2-evidence.lifecycle.json` and `jfg-correction-cuda-v2-batch1-analysis.json` under the sealed experiment cache.

- Fresh explicitly deferred native N2 calibration passed plan, public shutdown
  and independent reduction: seven exposures, four accepted responses, final
  stopped/unadmitted state and no error. Both later flat references passed
  34 exposures with 32 accepted responses and no rails; the native reference
  was frozen before training. Both native zonal runs now pass all three gates,
  each with 9,419 exposures, 8,864 accepted frames, 555 native DM records and a
  3,600×277 unaccepted candidate. Seeds are 531/532; ADC maxima 4,636/4,611,
  no rails. Each first initialization exposure is invalid and excluded from
  accepted responses. Acquisition takes 153.24/152.98 seconds, startup
  86.42/86.73, evidence revalidation/reduction 24.75/24.54 and driver total
  316.27/316.19. The selected existing compiled native binary is unchanged;
  explicitly deferred ingress does not resolve ordinary streaming CCR-017.
  Native Hadamard acquisition is ongoing at this checkpoint; neither a completed
  Hadamard pair nor native selection/correction is inferred. Native Classic
  scientific coverage remains separate from its functional bridge.
- Both AMD transfer acquisitions completed 1,041 exposures, zero ADC rails or
  invalid frames and all lifecycle gates. Initial cold report serialization
  failed on nested JSON3 Symbol keys. The separately reviewed v2 route calls the
  exact frozen scoring function with semantic metadata normalization; the same
  actual result now serializes and verifies. Sparse/mixed groups pass both
  repeats: SSE 0.02336354/0.02334527 versus zero 0.68178564. The CUDA-derived
  inverse then passes two normal dynamic 256-frame AMD reset batches and the
  retained batch-1 HIP replay: exact ADC/live OPD/zero baseline, ratios
  0.71547259/0.64897138 in windows 17:128/129:256, peak 0.15338704 µm OPD and
  no components at the limit. Matched transfer seeds are not independent noise
  corpora, and no full AMD inverse was refitted. Original sources, captures and
  serialization failure log remain retained.
- Classic FGN/JFG CUDA each pass two 256-frame reset batches, public shutdown
  and both actual CUDA replays. FGN window ratios are 0.04427237/0.03436843;
  JFG 0.04428807/0.03435182. Both have exact ADC/live OPD/zero baseline,
  maximum ADC 449 under the actual 12-bit rail, peak command about 0.378959 µm
  OPD and no components at the limit. The selected 206-mode CPU inverse,
  CPU-derived simulated offsets, maps, gain −0.3/pole 0.99/anti-windup 0.99
  remain unchanged. This is backend correction evidence, not new full GPU
  matrix fitting; Classic AMD cases remain pending.
- Final SDK integration initially failed because the isolated export test fixture omitted the new CalibrationCampaign dependency. A one-line include-order correction passes the same 71 export assertions; the full portable SDK rerun passes 820 assertions. Frozen acquisition packages are unaffected.
