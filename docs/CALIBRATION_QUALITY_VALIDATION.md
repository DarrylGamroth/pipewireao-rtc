# Classic measured-calibration quality validation

## Scope

2026-10-03, Classic CPU, non-actuating normal deployed detector/WFS/DM exchange.
This extends [operational acquisition](CALIBRATION_ACQUISITION_VALIDATION.md) and
[campaign evidence](CALIBRATION_CAMPAIGN_VALIDATION.md). The measured matrix,
controller-coordinate composition, frozen held-out test and correction checks
are separate gates. No instrument-specific acceptance targets were supplied.

Cache root: `~/.cache/rtc-calibration-quality-20261003`. The starting revisions
and authority boundaries are in [the analysis plan](ANALYSIS_PLAN.md). AOC
numerical changes are merged and pushed at `f79104d`; RTC work uses
`work/classic-calibration-quality-20261003`, starting at `04f692c`.
Independent findings are in [quality review](CALIBRATION_QUALITY_REVIEW.md),
[offset review](CALIBRATION_OFFSET_REVIEW.md) and
[correction review](CORRECTION_ANALYSIS_REVIEW.md).

## Measurements and estimation

A bounded null/actuator pilot preceded full acquisition. Normal noisy ADC,
measured background/reference slopes and the frozen 184-ROI mask remain in use.
The detector is not replaced by ideal optical measurements. Actual Float32
probe demands and adopted, settled completion receipts determine the data.
Controller gain −0.3, pole 0.99, antiwindup 0.99 and ±0.8 µm OPD limits remain
unchanged.

Two full 277-coordinate zonal sweeps used ±0.03999999910593033 µm OPD and 64
accepted frames per sign. Sweep 1 is ascending actuator, positive/negative;
sweep 2 reverses actuator and sign order, with independent detector seeds 61/62.
Each completed 554 batches, 35,456 accepted measurement exposures, 554 discarded
settling exposures and one restoration exposure. Restoration, ownership
release, public shutdown and launcher exit 0 were confirmed for both.

| Stage | Startup readiness | Acquisition, including completion/restoration | Public shutdown | Total stage |
| --- | ---: | ---: | ---: | ---: |
| Full sweep 1 | 41.651 s | 492.560 s | 1.009 s | 535.221 s |
| Full sweep 2 | 42.053 s | 485.494 s | 1.045 s | 528.594 s |
| Validation, 8 directions | 42.324 s | 52.830 s | 1.001 s | 96.156 s |
| Locked test, 16 fresh directions | 41.544 s | 109.273 s | 1.133 s | 151.950 s |

These are CPU simulation and cold deployment times, not detector wall-rate
qualification. The mean responses, not all individual sweep frames, are
retained by this acquisition contract. The public AOC physical estimates took
306.125 ms and 0.682 ms respectively; the first TSVD took 491.788 ms and later
candidate TSVD calls about 10.6–11.1 ms. First-call compilation is included;
these mixed cold/warm samples are not a fair method timing benchmark.

The physical mean D has shape 376×277, pixel/µm OPD. Chronological receipts are
validated before undoing the reverse sweep permutation. Using exact existing
maps, A = S D P E C has shape 368×221. S selects the two slopes per active ROI;
P maps VDM to PDM, E completes active to full VDM, and C maps controller to
active VDM. Feedback selection is derived separately. The selector satisfies
T E = I, but E is not Tᵀ, and active coordinates are not the first 221 physical
coordinates. Known-array composition/permutation tests passed 7 assertions.

The relative physical/controller sweep discrepancies are 0.2460/0.2349. The
single-matrix-scale repeat/order operator norm is 1.84401343 pixel/µm. This
combines noise, order and any repeat effects; it is not an unbiased noise
estimate or a confidence bound. Local balanced pilots support the candidate
0.04 µm amplitude; global infinitesimal linearity is not established.

## Frozen held-out decision

Public AOC TSVD candidates used cutoff 1/2/4 times the empirical discrepancy,
retaining 186/144/46 modes. No full-rank inverse or covariance inversion was
assumed. All inactive measurement columns in the deployed 221×376 Float32
reconstructor are explicitly zero.

Validation used four sparse and four dense controller directions at physical
peak amplitudes 0.02/0.04 µm OPD, counterbalanced signed pairs, two repetitions
and bracketing references, with 64 accepted frames per batch. The selection
rule required finite forward and inverse improvements over zero in each
repeat and sparse/dense subgroup, then minimized worst-repeat pooled physical
command mean-squared loss over all eight directions; ties favor higher cutoff.
It selected the 186-mode candidate. The frozen selection binds validation,
analysis, exact packed inverse, command maps and all locked-test declarations
before test acquisition. The 16 fresh test directions passed without retuning.

| Result | Validation | Locked test |
| --- | ---: | ---: |
| Selected retained modes | 186 | 186, unchanged |
| Worst-repeat pooled physical command loss, µm² OPD | 0.019474 | 0.018563 |
| Worst subgroup loss / zero-command loss | 0.18671 | 0.21456 |
| Forward prediction improves over zero, every subgroup/repeat | Passed | Passed |

Locked-test sparse prediction RMS was 0.009483 pixel with residual RMS
0.001959/0.001968; dense prediction RMS was 0.118864 pixel with residual RMS
0.015081/0.015049. These are finite-corpus local prediction results, not
instrument tolerances or confidence intervals.

Selected packed inverse SHA-256:
`987a9560ace009c1184b1930e20f78dcfa94edeefeba3023af7677060338b138`.

Two prototype scoring rules differed from the declared pooled rule. Their
reports remain preserved. Correcting the scoring implementation before locked
acquisition did not change the selected candidate. Independent CQ-R5/CQ-R6
review verifies the corrected rule and frozen identities.

## Deployed correction

Separate FGN and JFG HIL packages use the same selected inverse, maps and
measured offset bytes. Each passed two 256-frame closed-loop runs with normal
noisy detector acquisition, exact frame/command counts, pause/hold/resume,
reset and shutdown. Within each engine the two raw and command recordings are
byte-identical after reset. All 70,912 command components per run are nonzero;
no demanded components are at the ±0.8 µm rail. Peak demands were
0.40172863 µm for FGN and 0.40172854 µm for JFG.

Independent noisy closed loops are not shared-input algorithm comparisons.
Their ADC streams diverged, so similar peaks do not establish numerical parity.
The ordinary-array discriminator replayed all 256 FGN detector frames through
the complete JFG graph with identical parameters and delayed feedback. Maximum
FGN/JFG adopted-command difference was 1.42108547 × 10⁻¹³ m OPD, RMS
2.74141801 × 10⁻¹⁴ m over 70,912 comparisons. This characterizes close agreement
on the shared corpus; 62,197 components are not bit-identical. No new instrument
tolerance was inferred. Requested-minus-demanded, physical and controller
feedback norms and both rail counts were zero throughout. Independent review
recalculated the differences from the retained binary command streams.
Rail proximity is not requested-minus-demanded clipping feedback; the shared
input graph exposes both command and feedback outputs separately.

The cold correction diagnostic requires exact retained-source ADC replay and
a verified zero-command reset baseline before publishing ratios. FGN passed
all 256 exact ADC comparisons, matching atmosphere replay and zero PDM
surface. On the uniform public annular pupil, after piston removal:

| Declared window | Residual / uncorrected atmosphere variance |
| --- | ---: |
| Frames 17–128 | 0.0402661 |
| Frames 129–256 | 0.0601099 |

This demonstrates correction for the recorded FGN corpus at unchanged settings.
The last recorded command affects the unrecorded next frame; it is not counted
as an observed effect. The two initial cold-loader errors (isolated-module
include binding and lazy-import world age) are preserved and fixed with focused
fail-before/pass-after tests. Independent review verified the complete package
manifest, retained payloads, exact replay and recalculated ratios.

JFG's first cold replay differed in 33 ADC pixels across 12 frames; a fresh
process differed in 66 pixels across 7 frames. Those historical scores remain
withheld. All atmosphere, pupil and PDM hashes match exactly between those cold
replays, localizing their variability downstream of those public OPD products.
The historical live OPD products were not recorded, so that observation alone
cannot qualify those live records.

A new opt-in `--correction-diagnostics` export records public live atmosphere,
pupil and PDM hashes plus pupil variances, with graph, ADC, command and helper
identities. It leaves normal noisy ADC and command adoption in place. Two fresh
JFG 256-frame runs passed lifecycle checks and reproduced identical ADC,
commands and truth after reset. Cold replay matched all 256 direct live truth
records, their pupil support, a zero-command baseline and, in this run, every
ADC pixel. JFG variance ratios were **0.0405205** and **0.0599519** in the same
fixed windows. Independent review verified all 516 manifest artifacts and
recomputed the ratios.

New reports with a direct witness require exact live OPD/statistic agreement;
ADC equality cannot override a witness mismatch. Legacy reports still require
exact ADC replay. This establishes correction for both finite deployed corpora
without reclassifying the earlier failed replays as accepted. The underlying
historical ADC variability remains unresolved. Diagnostic hashing adds source
work and allocations outside the RTC graph; its runs do not qualify wall rate.
Installed source identity assumes files remained unchanged during acquisition.

## Provenance and limitations

- Actual probe plan/policy overrides are authoritative. Copied campaign recipes
  retain their earlier default amplitude as startup/noise/offset inputs; do
  not attribute the override figures to recipe generation.
- Full acquisition binaries retain source revision `dccb179` and their recorded
  hashes. Rust source is unchanged through the quality branch; Python timing
  and offset export changes do not imply those binaries were rebuilt.
- The strict offset importer rejects cross-engine construction-default
  differences. JFG uses its own completed operational campaign; its imported
  background/reference/mask bytes match FGN's exactly. That compatibility limit
  remains explicit rather than weakening the validator.
- The simulator snapshots the exact prior calibration plant sources, preserving
  unrelated canonical AOS changes. The inherited reconstructor is replaced;
  inherited geometry and completion maps remain explicitly hybrid.
- Functional 500 Hz model time is not achieved CPU wall cadence: closed-loop
  batches ran about 46–59 Hz and recorded missed wall periods. They delivered
  every demanded command; these are distinct observations.
- Cache scripts are exploratory, absolute-path experiments. Their identities
  and results are durable evidence. The new [selectable method owner](CALIBRATION_METHOD_USAGE.md)
  separately passed a bounded reverse-modal deployed smoke; full method
  comparison and scientific selection remain pending.
- Copper, unchanged HEART, CUDA/AMDGPU, physical devices, instrument acceptance
  and statistical uncertainty across many independent full sweeps remain open.
- The licensing ledger remains separate from numerical acceptance; no GPL
  reference implementation was copied or translated.
