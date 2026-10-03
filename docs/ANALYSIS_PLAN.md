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
- Status: in-progress.
- Notes: no new scientific API or third-party source reuse yet.

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
- Status: not-started.

### CQ-003: Compose physical responses into controller coordinates

- Depends on: CQ-001; accepted precision policy from CQ-002.
- Description: with measurement selection S, measured physical response D,
  VDM→PDM map P, active→full completion E and controller→active map C, use
  D_controller = S D P E C. Derive feedback conventions separately; validate
  sign from commanded/adopted responses and existing controller semantics.
- Verification: shapes, exact map hashes, selected-row identity, independent
  known-array fixtures and held-out deployed command predictions. No truncation
  of the 277 physical coordinates.
- Status: not-started.

### CQ-004: Evaluate reconstruction and simulated correction

- Depends on: CQ-002 and CQ-003.
- Description: choose an explicit AOC reconstruction policy from measured
  uncertainty/observability evidence; publish candidates only. Exercise normal
  startup loading and deployed non-actuating closed-loop simulation.
- Verification: held-out predictions, visible weak modes, FGN/JFG output
  agreement, command clipping/feedback diagnostics and correction at unchanged
  controller settings. No convergence claim from clipped or zero outputs.
- Status: not-started.

## Open questions

- Which amplitudes/counts provide adequate precision without nonlinear
  response? Current amplitude residuals still contain substantial noise.
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
[calibration provenance](CALIBRATION_PROVENANCE.md). Further measurements have
not yet been run for this increment.

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
