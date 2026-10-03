# Classic calibration quality: independent technical review

## Scope and provenance

Date: 2026-10-03. RTC review baseline
`3624d258505003ab2776deac9c3232c759af9b64`, worktree
`pipewireao-rtc-calibration-quality`. The earlier worktree-creation revision in
[ANALYSIS_PLAN.md](ANALYSIS_PLAN.md) remains historical provenance. The current
uncommitted production changes inspected here are timing instrumentation in
`deployment/calibration_campaign.py` and its focused tests. The reviewer owns
this document only; no production edits, RTC launches or instrument actions
were performed.

Authority: [ANALYSIS_PLAN.md](ANALYSIS_PLAN.md),
[CALIBRATION_PROVENANCE.md](CALIBRATION_PROVENANCE.md), RTC-ARCH-023 and
RTC-DEV-029. No instrument-specific acceptance thresholds were supplied.
This review does not change detector thresholds, controller coefficients,
HEART, hardware or dependencies and does not provide legal clearance.

The review distinguishes observations from derived numerical summaries and
unresolved mechanisms. A candidate finite-amplitude matrix is not an accepted
infinitesimal derivative, full-rank inverse or correction solution.

## Evidence examined

Cache root: `~/.cache/rtc-calibration-quality-20261003`.

| Case | Seed | Complete batches | Accepted exposure identities | Scope |
| --- | ---: | ---: | ---: | --- |
| `selected-v2-n16` | 41 | 72 | 1,152 unique; sequence2 through1224 with settling gaps | Two actuators, four amplitudes, four repeats, eight reference means |
| `selected-v2-n64` | 42 | 72 | 4,608 unique; sequence2 through4680 with settling gaps | Same ordered conditions,64 frames per batch |

Conditions are one-based physical actuators139 and143, requested amplitudes
0.04/0.08/0.16/0.32 µm OPD, with exact Float32 amplitudes used as divisors.
The two detector seeds differ. Each case includes actual deployed WFS mean
responses with recorded exposure IDs, normal noisy ADC and unchanged control
coefficients. These are two actual actuator coordinates, not eight independent
spatial directions. The frozen184-ROI mask defines368 eligible slope entries
inside the full376-entry response order.

Source artifact SHA-256:

| Artifact | N16 | N64 |
| --- | --- | --- |
| `interaction-plan.json` | `66050777b534b8469ae910cb4c1036668c386ab98444e9ef2cf93122bc9c3551` | `620362e56e0886d928338769df16d1501a5a1b8ba861190c376c0ac9506b5506` |
| `evidence/rtc-calibrate.json` | `3b9cadda38964760137c1453adde37deeb62d0e8e2d4c72761436a9a57a9d588` | `4fb081de37fc3bd29ae38dedc24b4f3e9e3326d33d90b8b62ed9472cc1438001` |
| `exploratory-summary.json` | `97ce4db264801a0efcd2404bede68f7008a73d540a8b842981d457395988652f` | `22284b74ffb3cfc4d20087ec9ecda11144a741a167c9c3fc8d4428929d3585ed` |

Both `probe-labels.json` files have hash
`4e2f0047a36af63ab5a1201f808805645517074056ffd065b213dd98af263f66`.
No claim of complete pipeline requalification follows from this bounded
identity/count and numerical audit. The existing coordinator validates adopted
commands and associated mean responses; future acquisitions retain that path.

The64-frame individual null capture now has successful restoration, release,
shutdown and launcher-exit0 recorded. Its covariance/sequence analysis was
not completed by this reviewer. Do not replace that analysis with the eight
reference batch means, or count the64 exposures as64 independent repeats of
a64-frame mean.

## CQ-R1 — Coherent amplitude dependence survives vector-noise summaries

**Severity:** high for choosing the full-matrix acquisition policy.
**Confidence:** confirmed amplitude association; cause unresolved.

For actuator j and repeat r, the observed finite-amplitude derivative is

```text
d(j,a,r) = (mean_response(+a) − mean_response(−a)) / (2 a)
```

The existing exploratory summary reports a trace-based mean-error norm across
four repeats. This is a useful global noise diagnostic, but most noise may
lie perpendicular to a coherent systematic difference. Therefore a vector
difference comparable to that norm does not establish amplitude independence.

The reviewer formed a fixed unit template u from the mean N16/seed41 derivative
at a0.32 for each actuator, then projected the independent N64/seed42 derivatives
onto u. The template is itself noisy but is independent of the evaluated seed;
this is a conditional directional diagnostic, not an estimated physical mode.

For clear actuator143:

| a, µm OPD | Mean projected derivative, pixel/µm | Sample SEM across4 repeats |
| ---: | ---: | ---: |
| 0.04 | 5.693368 | 0.031001 |
| 0.08 | 5.769983 | 0.011416 |
| 0.16 | 5.855724 | 0.005862 |
| 0.32 | 5.908755 | 0.003243 |

Paired-repeat contrasts against0.32 are respectively
−0.215387±0.033824, −0.138773±0.013263 and −0.053031±0.007062 pixel/µm,
where ± denotes sample SEM, **not a Gaussian confidence interval**. All four
N64 repeats increase across these amplitude choices. The0.08-to0.32 projected
change is about2.35% of the0.32 response. The full trace-error comparison alone
would obscure this repeatable directional effect.

The same projected means for obscured actuator139 are
1.134746/1.174980/1.174741/1.162318 pixel/µm, with SEM
0.017691/0.018869/0.009913/0.005628. There is no corresponding monotonic trend.
This neither establishes that actuator139 is optically unobservable nor proves
linearity of its complete response.

### Even response and timed reference interpolation

For each signed pair, the reviewer interpolated between its repeat's bracketing
zero-command mean vectors at the actual mean exposure-midpoint timestamps.
The even residual is

```text
b(j,a,r) = (mean_response(+a) + mean_response(−a))/2 − reference(t_pair_mid)
```

At N64, the even-residual vector norms and corresponding trace SEM are:

| Actuator | a0.04 | a0.08 | a0.16 | a0.32 |
| --- | --- | --- | --- | --- |
| 139 norm / SEM, pixels | .02351 / .02497 | .02321 / .02448 | .02315 / .02390 | .02426 / .02395 |
| 143 norm / SEM, pixels | .02593 / .02477 | .02497 / .02543 | .02635 / .02587 | .02766 / .02662 |

Actuator143's directional even residuals are
−.000514±.002394, −.002803±.000952, +.000223±.001529 and
−.001589±.001263 pixels. These do not form a consistent amplitude trend.
The isolated0.08 excursion is not a general nonlinearity conclusion.
Reference means are reused within a repeat, so even-residual contrasts share
reference uncertainty; they must not be treated as independent observations.

Every existing signed pair is positive then negative. Pair midpoint separation
is1.7 model seconds at N16 and6.5 at N64; bracketing-reference separation is
28.9 and110.5 seconds respectively. Correcting each N64 actuator143 signed
mean with the fitted linear reference drift changes projected derivatives by
only +.000736/.000368/.000184/.000092 pixel/µm across the four amplitudes.
Thus that fitted smooth drift does not explain the observed0.08-to0.32 change.
Unobserved short-time variation, sign/order effects and physical/WFS amplitude
dependence remain competing mechanisms. No one is established as the cause.

**Disposition:** primary agent agreed to defer full277-column acquisition and
run the bounded sign/order discriminator below. This is an acquisition-design
decision, not scientific acceptance of a probe amplitude.

## Agreed next discriminator

Use the existing coordinator, normal noisy ADC, unchanged settings, detector
seed45, N64, actuators139/143 and amplitudes0.02/0.04/0.08/0.16 µm OPD.
Budget:128 signed batches and16 reference batches.

- Four local quartets per actuator/amplitude. Commands are ABBA
  `(+a,−a,−a,+a)`, counterbalanced with BAAB in half the quartets.
- Each quartet yields forward-order and reverse-order central differences.
  Their mean cancels a local linear-in-time offset; their contrast diagnoses
  order sensitivity. This assumption does not remove arbitrary drift or noise.
- There are eight signed-pair estimates but four quartet blocks per condition.
  Report those distinct counts; do not advertise eight independent quartet
  repeats. Estimate between-block variation at the quartet level.
- Use balanced four-amplitude Latin orders `A B D C`, `B C A D`,
  `C D B A`, `D A C B`, alternate actuator order, and bracket each actuator
  block with zero-command means. Apply ordinary adoption/settling even for
  the equal middle commands.
- Compare order contrasts, order-balanced amplitude contrasts and even
  residuals against timed references. Preserve individual full identities and
  actual adopted figures; reject clipped or changed probes.

The existing dataset is exploratory and informed this design. Conclusions
from the next independent sequence must be labeled confirmation of a declared
finite-amplitude range, not proof of zero nonlinearity. No confidence rule or
instrument-specific error tolerance has yet been promoted to an acceptance
requirement by this review.

## CQ-R2 — HIL export currently replaces operational measured offsets

**Severity:** high for correction provenance. **Confidence:** confirmed source.

`deployment/export_hil.py:export_hil` calls `simulated_calibration`
unconditionally. That helper invokes `calibrate_detector.jl` and adopts its
generated background/reference offsets. Re-exporting a measured candidate
through this path would therefore fail to preserve its operational estimator.
The historical fixture mode is useful but cannot silently represent the
measured calibration used to characterize D.

### Minimal explicit preservation contract

1. Add an explicit Classic CPU operational-measured-offset selection to the
   existing exporter. Use existing campaign/artifact descriptors and provenance;
   no new numerical file format or generic calibration store is needed. Default
   historical fixture behavior remains identified as such.
2. In preservation mode, never invoke detector calibration or synthesize a
   noiseless reference. Preserve exact measured background, reference slopes
   and eligible-mask bytes. An arbitrary inherited package must not gain a
   measured-origin claim merely from a Boolean flag.
3. Require the measured source/result identity, completion/provenance record,
   payload hashes, shapes, element types, ROW_MAJOR ordering and units. Require
   the actual calibration reference command and its relation to runtime
   system-flat/controller origin; do not silently replace that origin.
4. Bind calibration-relevant detector/exposure/geometry/ROI origins/coordinates/
   thresholds/illumination context. Record intentional target changes such as
   an independent seed, declared disturbance and candidate reconstructor.
   Such differences must not authorize an unrecorded exposure or estimator
   change. Full graph hashes can differ for declared changes; preserve both
   hashes and an explicit difference record rather than asserting equality.
5. Resolve the actual startup bindings for each engine. FGN startup parameter
   properties and JFG owner parameter arguments must consume the preserved
   bytes. Construction-time active values must agree with the selected mask;
   duplicate or conflicting bindings fail before publication.
6. Reject missing, stale-hash, nonfinite, wrong-sized, malformed-mask or
   incompatible descriptors. Preserve input packages and completed evidence;
   publish only a new fully validated output directory by the existing atomic
   export mechanism. Record base hashes, measured-source hashes and final
   deployed bindings in existing provenance structures.

Required tests: both FGN and JFG preservation, exact byte/hash survival, a spy
showing zero `calibrate_detector` calls, default fixture regression, unsupported
profile/backend rejection for the initially bounded mode, each invalid binding
and payload case, failed export leaving no published candidate, and original
inputs unchanged. An installed startup check must verify the actual preserved
parameter/mask configuration before correction; source packaging tests alone
do not prove runtime adoption.

**Disposition:** confirmed blocker for claiming measured-offset correction;
remedy contract proposed for primary-agent adjudication. No exporter edit made.

## CQ-R3 — Noise and observability limits constrain inverse policy

**Classification:** confirmed mathematical limitation, not an implementation
defect. Four repeated vectors have sample covariance rank at most3;64 individual
null vectors have rank at most63. Neither supplies an invertible empirical
368-dimensional covariance. Rounded numerical rank is not physical rank.

Use complete-batch AOC moments for means, variances and covariance factors.
The factor supports fixed-direction uncertainty without claiming a full noise
inverse. Examine null time order, block means and reference drift before using
the independent-noise `1/√N` scaling. A64-frame trace cannot establish universal
independence or long-time stability. Report uncertainty assumptions explicitly.

Do not discard weak physical directions solely because two selected actuators
have repeatable responses. Do not promote an observed noisy matrix's singular
values into physical observability. A regularized or truncated inverse needs
held-out prediction and noise-amplification evidence.

## CQ-R4 — Coordinate composition and held-out prediction gate

**Classification:** required integration validation; not yet performed.

Retain Dphysical376×277 and the frozen row selector S368×376. The inventoried
forward maps give

```text
A = S Dphysical P E C             # 368 measurements × 221 controller coordinates
Rfull = Rselected S               # 221 controller coordinates × 376 stored slopes
```

C and P are the recorded identity maps. E is277×221; feedback selection T is
221×277 with TE=I. E differs from T′, and T is not a first221 slice. Keep
forward completion and feedback interpretation separate. The actual map hashes
in `command-map-inventory.json` identify this statement. It does not prove
control sign, command origin, physical linearity or rank.

After an explicitly chosen finite-amplitude full matrix, acquire a small
prespecified held-out set of sparse and mixed controller-coordinate commands.
Generate their requested physical figures through P E C and require actual
adoption without clipping. Include independent signs/amplitudes within the
declared range and null references. Test A c against the measured response
before assessing the inverse. No ideal optical truth enters this estimator.

Use separate validation patterns to select among a short explicit TSVD/ridge
policy set, and a locked final test set to assess the chosen policy. Report
weak/discarded directions, command amplification and propagated measured noise.
Compare prediction residuals with matched repeat/null uncertainty and the zero-
response baseline. A proposed simulation-relative utility criterion must be
declared before inspecting its final test set; there is no inherited instrument
threshold. Training reconstruction residual alone cannot justify selection.

Only then exercise candidate-only non-actuating correction through normal
startup loading, with measured offsets preserved and unchanged controller
gain/poles. Check control sign and command origin explicitly. Require nonzero
unclipped demanded commands, correlated feedback, and an improvement assessed
against a matched no-correction baseline with repeated normal-noise samples.
The user-authorized sequence is preserved; later method comparisons and
Copper/HEART/GPU work remain outside this gate.

## Ownership and timing assessment

AOC owns complete-array numerical moments, finite-difference estimators,
composition/inverse calculations and diagnostics. RTC's cold layer owns recipe,
identity/association validation, measured artifact provenance, deployment,
restoration/release and candidate publication. Neither numerical processing
inside transport callbacks nor hidden plant truth belongs in this increment.

The current timing diff uses `perf_counter_ns` around launcher readiness,
acquisition through confirmed restore/release, public shutdown and total stage/
campaign duration. It records failed intervals separately from confirmed
completion and handles process-creation failure with `process=None`. These are
cold wall-clock intervals. They include orchestration work and do not measure
per-exposure latency, real-time cadence or independent statistical sample time.
The focused timing tests were inspected, not run by this reviewer. No timing
benchmark claim is added here.

## Current decision

Proceed with the adjudicated small balanced confirmation. Keep full277
acquisition conditional on its interpretation and a declared candidate policy.
Resolve measured-offset preservation before correction deployment. Numerical
source review, acquisition completion, finite-amplitude prediction and physical
correction acceptance remain distinct evidence levels. Historical ADC
differences and licensing/provenance uncertainties remain recorded; neither is
resolved by this review.

## Held-out inverse plan — proposed before inspecting the full matrices

This section supersedes the earlier acquisition hold as a plan update, not a
scientific acceptance statement. The primary agent has started two full277
candidate sweeps at a0.04 µm OPD and N64, seeds61/62, with ascending positive/
negative and descending negative/positive order. The balanced confirmation
supports0.04 as a finite-amplitude candidate: clear-actuator projected responses
at0.02 and0.04 agree within the measured quartet variability, while0.08 and0.16
increase coherently. This is not proof of an infinitesimal linear regime for
every physical actuator. The corrected public AOC moment implementation must
be used for the final numerical record.

The following finite-corpus utility rule is proposed for primary-agent
adjudication and freezing before held-out outcomes are inspected. It is not an
instrument acceptance target or a confidence-bound claim. A valid outcome is
that every inverse candidate fails and no correction candidate is promoted.

### Freeze directions before seeing D

- Validation:8 controller directions, comprising4 distinct sparse coordinates
  and4 dense supplied Rademacher vectors.
- Locked test:16 different directions, comprising8 other sparse coordinates
  and8 new-seed dense Rademacher vectors. Sparse indices span the existing
  controller order and are selected without using D or its singular vectors.
- Within each sparse/mixed subgroup, use equal numbers at physical peak0.02
  and0.04 µm OPD. Let B=P E C. Normalize through B, then verify the actual
  Float32 requested/adopted physical figures stay within the declared peak.
  Freeze vectors, normalization, seeds, order, source maps and hashes before
  examining the matrices. No adjustment based on observed singular vectors.
- For each direction acquire two signed pairs with opposite order, as one
  ABBA/BAAB quartet, N64 per signed batch. Alternate quartet orientation and
  bracket blocks with zero-reference means. Thus8/16 denotes directions,
  requiring32/64 signed batches, not8/16 exposures.
- Use independent detector samples/seeds for calibration, validation and locked
  test. Keep the locked16 outcomes unopened until the candidate and selection
  rule have been fixed. If they were inspected for tuning, they cease to be
  a locked test and require a newly declared independent test.

For each direction c and each signed pair r, define
`zᵣ=(mean_response(+q)−mean_response(−q))/2` in selected measurement coordinates.
Unlike a derivative estimate, z is not divided by amplitude: it predicts the
response to the complete supplied physical vector q. Preserve actual adopted
positive/negative commands and verify their symmetry and reference origin.
Reject clipping, changed commands, invalid selected rows or identity mismatches.

Use `p=S Dbar q_adopted`, with `Dbar=(D₁+D₂)/2`, for the physical forward
prediction. Compare `A c` with that prediction separately to expose map,
rounding or command-origin discrepancies. Float32 conversion is not permission
to pretend the original real-valued vector was adopted exactly.

### Public AOC inverse construction

Let `η=norm(S(D₁−D₂)B,2)/sqrt(2)` be the empirical repeat/order operator
discrepancy. The fixed cutoff grid is η,2η,4η. Because the sweeps also reverse
order, η includes any order-dependent disagreement; it is not a pure detector
noise estimate, upper error bound or confidence level. Under independent equal
noise alone, division by sqrt(2) gives the scale of one matrix, while division
by2 gives the scale of their average. Keeping the larger scale is an explicit
conservative candidate-grid choice.

The current public API supports the exact proposed absolute threshold:

```julia
using AdaptiveOpticsCalibration
using AdaptiveOpticsCalibration.Reconstructors

plan = prepare(TSVDInverse(atol=tau, rtol=0.0, n_trunc=0),
               ReconstructorSpecification(368, 221, Float64))
product = process(plan, SVDReconstructorInputs(A))
Rselected = reconstructor(product)
```

This method retains singular values strictly greater than tau. Its numerical
failures throw; this particular product does not have a success-status field.
Record `effective_rank`, `truncation_count`, singular values and spectral gains
through the public accessors. A finite rank-zero matrix is numerically legal
but cannot pass the useful-inverse gate. Reject a nonfinite/zero discrepancy
scale rather than invent a new grid after observing validation results.

The grid and SVD use unweighted selected slope coordinates; no full empirical
covariance inversion is implied. Assess the actual Float32 packed candidate
that will be deployed, and record differences from the Float64 numerical
product. Embed selected rows into `Rfull=Rselected S`, leaving inactive input
columns explicit. Do not remove physical or controller coordinates silently.

### Forward gate independent of inverse fitting

For each of the two held-out pair realizations, compute

```text
G_forward,r = mean_i(‖z_i,r‖² − ‖p_i − z_i,r‖²)
            = mean_i(2 p_i⋅z_i,r − ‖p_i‖²)
```

The same observation occurs in both losses, so its quadratic noise contribution
cancels in the comparison with zero prediction. The proposed finite-corpus
gate requires positive gain separately in both realizations and separately in
the sparse and mixed subgroups. Report amplitude-stratified and per-direction
values as diagnostics, including failures. This is not a statistical guarantee
of improvement on arbitrary221-dimensional inputs.

Report forward residual energy beside duplicate-pair disagreement and matched
null response energy. Do not divide by an invertible368-dimensional noise
covariance or call the result chi-squared. Small residuals below the observed
noise floor remain unresolved, not proven zero model error. Failure of the
forward gate blocks an inverse/correction claim even if AOC returns a matrix.

### Inverse selection and locked test

Choose the selection metric before computing the candidates. A minimal fixed
metric is physical command squared error, using known actually adopted probes:

```text
L_k,r = mean_i ‖B R_k z_i,r − q_i,adopted‖²
L_zero = mean_i ‖q_i,adopted‖²
```

This uses the fixed physical map B and actual held-out commands. It is
independent of the fitted matrix's training residual and is not normalized by
the candidate's retained rank. A candidate must remain finite, retain at least
one mode, and beat the zero-command loss separately in both pair realizations
and in both sparse/mixed groups. Select the eligible candidate with the lowest
worst-realization validation loss; break exact ties in favor of the larger
cutoff. Apply the unchanged rule on the locked16 without choosing another
candidate afterward. If none qualifies, report the failed gate.

Additionally report recovered versus discarded components using the retained
right-singular-vector projector, but do not use projected-target error alone
for selection: deleting all modes would make that target trivially zero.
Euclidean controller-mode orthogonality does not imply orthogonality under the
nontrivial physical map B, so those physical component energies need not add.

The duplicate realizations reveal repeat/order sensitivity, not a confidence
interval. The locked test samples at most16 independent command directions;
even dense vectors do not certify all221 directions or physical rank.
Success establishes only useful recovery over this declared finite corpus and
command range, with the reported retained subspace and uncertainty.

The N64 held-out measurements characterize batch reconstruction. Separately
propagate the actual individual-frame null covariance factor through B R to
report single-frame command-noise RMS and noise amplification. Multiplying a
covariance factor for this diagnostic does not require its inversion. Do not
rescale the N64 result into a per-frame operating claim without validating
time-order assumptions. The existing temporal controller can alter that noise;
its actual closed-loop behavior must be measured at unchanged coefficients.

### Non-actuating atmospheric correction verification

Passing the numerical gates permits a bounded simulation experiment; it does
not itself prove correction. Preserve measured background, reference, mask,
actual command origin and the selected packed reconstructor under the explicit
export-preservation contract. Keep detector settings, controller gain/poles,
constraint behavior and graph timing fixed.

1. Verify sign and pipeline association with a small declared static simulated
   disturbance before a dynamic atmosphere run. Use actual requested/adopted
   commands, raw ADC, WFS outputs and constraint feedback. A predicted command
   alone is not evidence that the simulated plant consumed it.
2. Predeclare model-step count, transient exclusion, disturbance configuration,
   finite independent atmospheric seeds and matched no-correction runs. Reset
   the same public simulator/controller state for each comparison. No tuning
   gains, disturbance strength or scoring window after inspecting outcomes.
3. Use only ordinary measured WFS data in calibration/reconstruction/control.
   Public simulator disturbance/residual pupil OPD may be copied separately for
   verification. Compare piston-removed pupil residual under the same explicit
   pupil weighting; record model-time alignment and command delay.
4. Confirm the actual injected disturbance trajectories are matched, rather
   than assuming a shared seed guarantees identical trajectories. Detector
   frames need not match when correction changes photon distributions. If
   disturbances do not match, do not treat the runs as a paired comparison.
5. Report residual OPD and selected WFS residual distributions, null/noise
   baseline, command RMS/peak, clipping counts, constraint feedback, transient
   behavior and every receipt/lifecycle failure. Require nonzero consumed
   commands, no clipping for the claimed range, and repeatable improvement over
   the matched no-correction baseline in the predeclared scoring window.
6. A zero-disturbance run exposes reconstruction/control noise injection. A
   dynamic atmosphere run checks the existing controller and actual delay/rate;
   spatial inverse validity cannot establish bandwidth or stability. Failure
   leads to a reported failed gate, not an unapproved gain/threshold change.

The primary agent must select and freeze the finite run budget and disturbance
settings before this verification. These tests can support the stated simulated
scenario only. They do not qualify physical actuation, an instrument's Strehl
target, universal atmospheric correction, real-time cadence, HEART or GPUs.


## Cache prototype implementation review — 2026-10-03

Scope: read-only source and saved validation-output review of
`~/.cache/rtc-calibration-quality-20261003/`. No RTC run, acquisition, production
edit or locked-response inspection was performed by this reviewer. The four
reviewed scripts had these SHA-256 identities:

| Script | SHA-256 |
| --- | --- |
| `prepare-full.jl` | `c1ec7931ec443a9cd6defe0bd2234561595771a2eff269ff90a773eb4fa7c287` |
| `prepare-heldout.jl` | `cd8904ce2b9d4bcd4b9ad4badb259aac8c629b4d68c582c67ec931780379e5fb` |
| `analyze-full.jl` | `67285f96ccf53af12547cfa73f9d416a1a300d2507fa68667cef940e583c12ce` |
| `score-heldout.jl` | `61495bfb76f0fe54806b54705edc442451eac2ba13e85eaf47d310263b2cbaa8` |

### Confirmed mathematical and execution contracts

- Full-sweep responses are validated in chronological acquisition order before
  reordering. The check `figures == canonical.figures[permutation,:]` and the
  subsequent `responses[invperm(permutation),:]` correctly recover canonical
  interleaved plus/minus rows. Reordering first would invalidate temporal
  receipt checks; the prototype does not do that.
- The public AOC zonal estimator receives the actual Float32 amplitude0.04.
  Its Float32 estimated matrix is widened to Float64 for averaging, composition
  and SVD. Widening does not recover precision already lost in that estimator.
- `B=P E C`, `A=Dbar[selected,:] B` and the repeat/order operator discrepancy
  use the physical277 and controller221 axes correctly. The explicit `T E=I`
  check does not replace E with a transpose or a cropped identity.
- The saved 188-element mask repeats each ROI twice, matching the interleaved
  x/y376 measurement order. Full-sweep1, full-sweep2 and validation packaged
  `wfs-active.u8` all have SHA-256
  `04090c0ed1a3808cd3b8ad03503008eb4915bab3c5eedbc856b14cc8db543697`.
- Held-out directions are constructed without reading D. ABBA/BAAB labels are
  resolved to plus/minus within each pair; the signed response is divided by2,
  not by amplitude. The scorer checks both plan figures against the recorded
  Float32 physical vector and predicts with that vector. It separately reports
  `norm(B*c-q_actual)` rather than silently identifying real-valued c with its
  rounded physical image.
- Candidate scores reload the packed Float32 reconstructor, so coefficient
  quantization is included. Products are accumulated in Float64: this does not
  qualify the deployed graph's Float32 arithmetic, cadence or closed loop.
- Rank-zero candidates cannot pass. Failure of all candidates writes diagnostic
  scores and throws before writing a selection. Higher-cutoff tie preference
  is implemented, subject to CQ-R5's correction of the primary score.

### CQ-R5 — Selection score differs from the declared physical loss

**Severity:** medium; selection-contract blocker until corrected.
**Confidence:** high. **Disposition:** confirmed source defect; remediation
owned by the primary agent. No changed selection is observed in existing data.

`score-heldout.jl` sorts candidates by the maximum subgroup-relative loss,
`max(loss/zero_loss)`. The frozen policy and this review instead specify minimum
worst-realization physical command loss, with subgroup gains as eligibility
checks. Sparse and mixed zero-command energies differ substantially, so these
rules are not interchangeable in general.

Read-only recomputation from saved `validation-scores.json` gives the following
worst-repeat physical losses, pooling the equal-size sparse and mixed groups:

| Cutoff | Worst pooled loss (µm² OPD) | Existing eligibility |
| --- | ---: | --- |
| η | 0.019473567362455407 | pass |
| 2η | 0.03617536139343386 | pass |
| 4η | 0.09058409734337579 | pass |

The declared rule therefore selects the same η candidate as the original
relative-loss implementation. Correcting an implementation to the already
frozen rule does not require new validation acquisition. Preserve the original
report and record the correction explicitly; do not retrospectively claim the
original implementation used the declared rule. Required verification: pooled
per-repeat loss drives ordering, subgroup gains still gate eligibility, and
exact ties still favor the larger cutoff.

### CQ-R6 — Locked-test hashes are recorded but not enforced

**Severity:** high for locked-test claim integrity.
**Confidence:** high. **Disposition:** confirmed source guard omission;
no evidence of substituted data or an actually changed candidate.

The reviewed scorer reads locked responses before reading `selection.json`.
It then uses only the selected multiplier. It does not enforce the selection's
locked plan/direction hashes, its validation-report hash, or the binding from
validation analysis to the current analysis and exact candidate descriptor.
If the selected multiplier is absent, it can write a result with no candidate.
`run-heldout.py` guards acquisition on selection-file existence alone.

Before opening locked response data, require a validated selection, its exact
validation report and analysis, one matching previously eligible candidate,
the selected packed matrix hash, and the frozen locked plan/directions. Also
bind the probe labels used to recover signed pairs, held-out policy/map hashes,
and current map inventory to the analyzed inventory; labels affect the score
and cannot be treated as descriptive-only metadata. Reject zero/multiple
candidate matches. Apply the same plan/direction guard before locked launch.
These are checks on existing declarations, not a new artifact format.

Required verification is a bounded offline check that altered locked plan,
directions, signed labels, candidate or analysis, missing selection, and an
unknown selected multiplier fail before response evaluation. The unmodified
saved declarations must pass. No new RTC acquisition is needed for these guards.

### Recipe amplitude versus explicit probe-plan provenance

**Observed:** each full/validation startup recipe retains amplitude0.02, while
`prepare-full.jl` writes amplitude0.04 probes and held-out preparation writes
explicit sparse/mixed figures. Full plan SHA-256 values are
`bc35af887aea34fe4e9a8399edb1d1038e4874911430ad79c0c689b0482e21f3`
and `7845bc5879dc7f3103cb01037c9f17d0da80cd81dc8486b955cdebe4cdd2cc90`;
validation plan SHA-256 is
`39c3f000895d574bba7e900983c6662587969b3e7b84558852f4cb43a1ced24a`.

**Source evidence:** `calibration_campaign.run_stage` passes the case's explicit
`interaction-plan.json` to `rtc-calibrate --plan`. Rust's adopted-evidence
transition rejects clipping and any figure unequal to that loaded plan's probe.
The recipe feeds startup detector/seed/settings and the stage timeout; its zonal
amplitude field is not the executed probe authority in these cache prototypes.

**Adjudication:** the explicit, declared override does not invalidate the
finite-amplitude science. Preserve the original recipe and state that these
are cache quality experiments with an explicit plan override, not unchanged
recipe-generated campaign probes. Final provenance must bind the exact plan,
CLI/result, binary/package identities, startup settings and maps. The public
Julia result validator checks lifecycle, dimensions and exposure chronology;
it does not independently attest command adoption from result JSON alone.
That attribution additionally relies on the executed coordinator's strict
adoption contract and the preserved command-line/plan provenance.

### CQ-R5/CQ-R6 remediation checkpoint

The primary agent revised the scorer to SHA-256
`7319b71aed153e6e90f88e84915e09121d763423f892b80d9cfeabf259a57aec`.
Independent source and saved-output inspection confirms selection now minimizes
`maximum(pooled_physical_loss)` over the two realizations; subgroup eligibility
and larger-cutoff ties remain separate. CQ-R5 is **closed**. The η/2η/4η
candidates retain186/144/46 modes and pass the declared validation eligibility.
The selected η candidate's two pooled losses are0.019425641503290007 and
0.019473567362455407 µm² OPD. This is validation evidence, not a locked-test or
physical-rank acceptance result.

The original relative and intermediate subgroup prototype reports/selections
are preserved under `*-relative-prototype.json` and
`*-subgroup-prototype.json`. The corrected selection SHA-256 is
`d58443ad3ac2283dd6257ce8fe96f3b878958dcf3703dd3581f49b2c61ab1fe2`.
Its validation, analysis, locked-plan and locked-directions hashes independently
match the files present. The current map inventory also matches the analyzed
inventory. The scorer now validates those selection/candidate contracts before
opening locked results and requires exactly one matching candidate.

CQ-R6 remains **partially remediated** at this checkpoint: freeze/check the
signed-label and policy identities plus the analyzed map inventory, and apply
prelaunch identity guards in `run-heldout.py`. These existing declarations
suffice; no new science or acquisition design is required.

### CQ-R6 final guard verification

CQ-R6 is **closed for the bounded cache workflow**. Reviewed final identities:

| Artifact | SHA-256 |
| --- | --- |
| `run-heldout.py` | `57afa4373d2b5256887434d396638cae72d499f1ca918a7fde77334476e70a36` |
| `score-heldout.jl` | `a3606aadf34e9786e6d7fd04a6bab7a8b57be48500ecd7d868258d5cce949b30` |
| `selection.json` | `179373f3359a54fb950fdb78b63949ccbb15366ae7380e64bf6301f8cdd4fe10` |
| `validation-scores.json` | `eca29550ed7945aff8f69550cf29146cbe2fa760afebbb1472ae8349f5bd2ab0` |

Source inspection confirms launch guards check all four locked declarations,
validation/analysis, map inventory and packed inverse before writing the recipe,
preparing/exporting packages or launching processes. Scoring applies those
identity checks and the unique selected-candidate contract before loading locked
response data. Mismatch branches throw; the launcher does not acquire first and
validate afterward.

An independent read-only Python audit verified every current hash, equality of
the selected choice with its validation entry and the eligible pooled-loss
winner, identity of selected versus analyzed map inventories, and the exact
packed candidate payload. The locked directory contained only the four frozen
declarations at audit time. Final validation output preserves the same pooled
losses and η choice. This verification used source inspection plus current-file
identity checks; no mutation-injection suite or RTC run was performed by the
reviewer. No remaining review blocker was found for acquisition of the declared
locked corpus. Its outcome and any later correction gate remain unverified.
