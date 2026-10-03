# Classic calibration quality analysis

## Objective

Characterize whether normal deployed noisy detector/WFS acquisition can
identify a useful Classic interaction matrix, compose it into the existing
controller coordinates, and demonstrate non-actuating simulated correction.
Extend RTC-ARCH-023 and RTC-DEV-029; do not replace their completed acquisition
evidence or claim physical-device or cadence qualification.

Worktree: `pipewireao-rtc-calibration-quality`, branch
`work/classic-calibration-quality-20261003`. Starting RTC revision
`04f692c2178ed79726232d409ba40fddd21b672d`, clean at creation. AOC starts at
`3997efe82d0e762d605b1d734864b076f73669ed`. No instrument-specific scientific
thresholds were supplied. Characterization precedes a documented
simulation-specific acceptance policy.

## Data and provenance

Reuse the completed candidate-only Classic CPU campaigns and their receipt,
settings and artifact hashes in [campaign evidence](CALIBRATION_CAMPAIGN_EVIDENCE.json).
The five candidate artifacts agree between the completed FGN/JFG campaigns;
four original qualification raw frames differed. The later shared-input
discriminator establishes observed WFS parity, not the historical cause of
those four differences. Preserve both records.

Acquisition retains demanded/adopted/settled probes, actual noisy ADC and
deployed WFS responses. No ideal optical response may enter operational
estimation. Use full acquisition identities and independent declared samples.
Raw Classic frames are 352×352 U16_LE ROW_MAJOR; measurement order is
188 interleaved x/y slope pairs, 376 total positions. The frozen eligible mask
currently selects 184 ROIs, 368 slope positions; inactive positions remain
explicit rather than being silently dropped.

Measured physical interaction matrices are 376×277. Existing controller
coordinates are 221-dimensional. Existing command-map files, not a first-221
column slice, define their relationship. Retain all payload hashes and units.

## Environment and maturity

- Python owns thin cold deployment orchestration and artifact validation.
- Julia/AOC owns reusable pure numerical estimators and diagnostics.
- Installed PipeWireAO, FGN/JFG and AOS own transport, processing and plant.
- Maturity: reusable package diagnostics with a finite reproducible deployment
  entry point; cache experiments precede API decisions.
- Preserve detector settings, controller gain/poles, clipping and feedback.
- No HEART source changes, physical actuation, CPU0/1 placement or platform tuning.
- Source/dependency constraints are in [calibration provenance](CALIBRATION_PROVENANCE.md).

## Target outputs

1. Tables of probe amplitude, averaging count, repeatability, response
   uncertainty, null-response noise and amplitude dependence, with sample
   identities and assumptions. A numerical completion is not acceptance.
2. An explicit physical→controller response composition and tested forward /
   feedback coordinate conventions, including units and sign.
3. Held-out response predictions and a declared reconstructor policy exposing
   weak/unobservable directions and residual uncertainty.
4. Candidate-only simulation artifacts, deployed FGN/JFG agreement and
   nonzero unclipped correction evidence at unchanged controller settings.
5. Durable evidence separating synthetic software tests, simulated deployment,
   scientific acceptance and unperformed hardware/rate qualification.

## Working knowledge

- The earlier 0.02 µm, two-frame zonal matrix completed acquisition but is not
  scientifically accepted. The flat covariance trace was approximately
  0.13258 pixel²; the independent-noise prediction of column noise RMS was
  9.10 pixel/µm versus observed column RMS 10.43.
- The selected clear-pupil actuator's 16-frame repeat cosine increased from
  0.739 at 0.02 µm to 0.978 at 0.08 µm. This is evidence for improved
  repeatability, not proof of amplitude linearity or sufficient full rank.
- Existing public AOC matrix-pair stability is available. It does not by
  itself estimate confidence intervals or distinguish nonlinear response from
  finite-sample noise.
- The current projection files contain an identity controller→active-VDM map,
  nontrivial active→full completion, identity VDM→PDM map and nontrivial
  full→active selection. Feedback selection is not the completion transpose.
  Confirm these properties against exact candidate inputs before composing.

## Chunks

### CQ-001: Establish numerical and licensing inputs

- Depends on: completed campaign acquisition.
- Description: validate current evidence identities, public numerical seams,
  command/feedback maps and source/dependency provenance.
- Verification: exact revisions, map shapes/order and selection invariants;
  bounded source audit and an explicit unresolved-license ledger.
- Status: verified for numerical inputs and the bounded audit/ledger.
- Notes: command/feedback maps verified; independent response-moment diagnostics
  implemented and reviewed in AOC. Its license declaration remains unresolved.

### CQ-002: Measure precision and amplitude dependence

- Depends on: CQ-001 numerical inputs.
- Description: use selected clear/obscured actuators and null commands first;
  declare amplitudes, averaging counts, independent repeats and budgets before
  launching. Increase scope only after the cheap discriminator. Inspect
  sequence dependence before using independent-noise uncertainty formulas.
- Verification: complete receipt/lifecycle validation; finite actual unclipped
  probes; bounded restore/release/shutdown; noise predictions versus independent
  repeats and held-out amplitude residuals. Portable analytical tests for any
  reusable AOC diagnostic added.
- Status: characterized for the declared finite Classic CPU corpus. Both full
  sweeps completed; fresh validation and locked-test responses passed the frozen
  forward/inverse policy. Global linearity, unbiased uncertainty and physical
  instrument acceptance remain unestablished.

### CQ-003: Compose physical responses into controller coordinates

- Depends on: CQ-001; accepted precision policy from CQ-002.
- Description: with measurement selection S, measured physical response D,
  VDM→PDM map P, active→full completion E and controller→active map C, use
  D_controller = S D P E C. Derive feedback conventions separately; validate
  sign from commanded/adopted responses and existing controller semantics.
- Verification: shapes, exact map hashes, selected-row identity, independent
  known-array fixtures and held-out deployed command predictions. No truncation
  of the 277 physical coordinates.
- Status: verified. Exact command-map composition, permutation fixtures and
  held-out predictions passed; see [quality validation](CALIBRATION_QUALITY_VALIDATION.md).

### CQ-004: Evaluate reconstruction and simulated correction

- Depends on: CQ-002 and CQ-003.
- Description: choose an explicit AOC reconstruction policy from measured
  uncertainty/observability evidence; publish candidates only. Exercise normal
  startup loading and deployed non-actuating closed-loop simulation.
- Verification: held-out predictions, visible weak modes, FGN/JFG output
  agreement, command clipping/feedback diagnostics and correction at unchanged
  controller settings. No convergence claim from clipped or zero outputs.
- Status: verified for the declared finite simulated corpora. The selected
  186-mode TSVD passed the locked test; both engines passed deployed correction
  checks at unchanged settings. Shared-input command differences were measured
  and clipping feedback was zero. Earlier JFG ADC replay failures remain
  unaccepted; the fresh live truth witness independently verifies correction.

## Open questions

- Which amplitudes/counts provide adequate precision without nonlinear
  response? Balanced selected-actuator results support a candidate ±0.04 µm
  local amplitude. Full physical sweeps and held-out mixed probes now support
  the declared finite-corpus candidate; global linearity remains unestablished.
- Are independent-noise assumptions adequate over the operational sequence?
- What measurable simulation-specific prediction and correction criteria are
  defensible? No instrument acceptance thresholds are available.
- Is the provisional simulated physical geometry compatible with all inherited
  completion-map conventions? Retain the hybrid-model provenance.
- AOC's own license declaration and inherited FFTW/native packaging obligations
  remain separate from acceptance of independently written methods.

## Evidence ledger

2026-10-03, CQ-001: clean dedicated RTC worktree created at `04f692c`;
bounded recent-AOC dependency/source reconnaissance found no dependency changes
in `875a7c2..3997efe`. License and numerical review limits are recorded in
[calibration provenance](CALIBRATION_PROVENANCE.md). This entry records the starting state; subsequent measurements are listed below.

2026-10-03, CQ-001: an independent source/provenance review of the recent AOC
additions found no confirmed copied/translated GPL material and retained the
SPIDERS/outbound-license gaps. The cached installed native FFTW provider and
its bundled license were identified; no backend or dependency was changed.

2026-10-03, CQ-001: six cached command/feedback payloads were read as exact
ROW_MAJOR F32_LE matrices, length-checked and SHA-256 recorded in
`~/.cache/rtc-calibration-quality-20261003/command-map-inventory.json`.
Controller↔active-VDM and VDM↔PDM maps are identities. The selector has 221
unique unit rows and its product with the completion matrix is exactly I.
Selected zero-based full indices start `9,10,11,12,13,17,18,19,20,21,22,23,24,25,28`.
The selector is not a first-221 slice and the completion is not its transpose.
This validates the recorded map structure, not measured response precision,
sign or correction.

2026-10-03, CQ-002: two selected-actuator runs (N=16 and N=64), a separate
64-frame null window, and an N=64 balanced-sign/amplitude run completed with
confirmed restoration, ownership release and shutdown. Four independent local
quartets are retained; their eight signed pairs are not counted as eight
independent repeats. The corrected analysis is
`~/.cache/rtc-calibration-quality-20261003/balanced-analysis.json`.
For clear-pupil actuator 143, projected derivatives at 0.02/0.04/0.08/0.16 µm
were 5.6678/5.6718/5.7604/5.8577 pixel/µm. The paired 0.04−0.02 contrast was
0.0040 with empirical mean standard error 0.0112; the larger amplitudes showed
coherent changes. These conditional sample errors are not confidence bounds.
The null covariance trace was 0.13952 pixel²; four disjoint N=16 means gave
0.00845 versus the independent-noise prediction 0.00872. One window does not
establish stationarity or independence.

2026-10-03, CQ-002: full-sweep policy declared before launch: two 277-coordinate
zonal runs at the actual Float32 amplitude 0.03999999910593033 µm OPD, 64
measurements per signed probe, seeds 61 and 62. Sweep 1 uses ascending actuator
order and positive/negative pairs; sweep 2 reverses actuator and sign order.
Each expects 35,456 measurement exposures plus 554 discarded settling exposures
and one restoration exposure. Responses must first pass chronological receipt
validation, then be permuted to canonical actuator/sign order before AOC
estimation. The matrix difference is an empirical repeat/order discrepancy,
not an unbiased noise estimate or a confidence bound. Candidate TSVD thresholds
will be checked using fresh held-out measurements; no rank is prescribed.
Plans, recipes and policy records are under
`~/.cache/rtc-calibration-quality-20261003/full-n64-sweep{1,2}`.

2026-10-03, CQ-002: AOC's independently implemented repeated-response moments
are merged at `f79104d`. Independent review reproduced a large-offset variance
failure before the correction; shifted-coordinate accumulation passes the same
fixture after correction. Focused tests passed 213 assertions and the full
suite passed 2,181 assertions in 97 summaries. This is numerical software
verification, not detector or RTC rate qualification. Source/dependency reuse
constraints remain unchanged.

2026-10-03, CQ-002/CQ-003/CQ-004: both full sweeps, validation and locked test
completed with restoration, release and shutdown. Public AOC TSVD candidates
retained 186/144/46 modes at 1/2/4 times the empirical repeat/order operator
norm. The frozen validation rule selected 186 modes; the independent locked
test passed without retuning. Both FGN and JFG completed two 256-frame deployed
closed-loop runs, exactly reproducible within each engine after reset. FGN's
exact ADC replay and zero-command baseline verified residual variance ratios
0.040266/0.060110 in the declared windows. JFG cold replays differed from live
ADC and correctly withheld scores, despite identical public OPD products
between cold processes. Detailed results and limitations are in
[quality validation](CALIBRATION_QUALITY_VALIDATION.md); original failures remain
in the evidence and [independent correction review](CORRECTION_ANALYSIS_REVIEW.md).

2026-10-03, CQ-004: fresh JFG direct live public-wavefront witnesses matched cold
replay, zero-command baseline and all 256 ADC frames. Fixed-window variance
ratios were 0.040521/0.059952. Two live reset batches reproduced ADC, commands
and truth records exactly. Independent review verified the artifact bindings
and ratios. The shared-input full JFG graph differed from FGN by at most
1.42108547 × 10⁻¹³ m OPD, with zero requested-minus-demanded, physical and
controller clipping feedback. This completes the finite Classic CPU baseline;
physical, global-linearity, Copper/HEART/accelerator and wall-cadence claims
remain outside that evidence. The next comparison follows
[the method design](CALIBRATION_METHOD_COMPARISON.md).


2026-10-03, selectable methods: all eight declared full candidate sweeps completed
through the maintained owner: two zonal, two complete Hadamard, two
controller-modal and two spatial. Fresh spatial combinations completed through
the same acquisition path. Independent review reproduced candidate bytes,
receipt/lifecycle invariants and all finite forward scores. Hadamard settings
showed lower repeat discrepancy and forward residuals than the declared zonal
settings, while using 16× integrated command energy. Controller-modal reduced
acquisition cost; spatial measured only a 64-mode span. See
[method measurements](CALIBRATION_METHOD_VALIDATION.md). The subsequent
[fresh method selection](CALIBRATION_METHOD_SELECTION.md) freezes ten inverses,
selects the 206-mode Hadamard candidate on new common validation responses, and
passes its selected-only locked test and deployed FGN/JFG correction checks.
Original baseline packages remain preserved; only staged comparison packages
adopt the new inverse. Copper, unchanged HEART, accelerator calibration and
wall-cadence qualification remain open.
