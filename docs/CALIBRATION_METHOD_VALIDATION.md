# Classic selectable calibration measurements

## Scope

2026-10-03, non-actuating Classic CPU, normal deployed noisy ADC and completion-
driven demanded/adopted/settled DM/WFS exchange. The qualified baseline and
finite reconstruction/correction gates are in
[quality validation](CALIBRATION_QUALITY_VALIDATION.md). This document records
subsequent probe-method characterization. No HEART source changes, physical
commands, platform tuning or controller gain/limit changes are included.
Independent audits are in [method review](CALIBRATION_METHOD_COMPARISON.md).

Cache: `~/.cache/rtc-calibration-quality-20261003`. The maintained selectable
owner and its bounded integration check are described in
[usage](CALIBRATION_METHOD_USAGE.md). A complete candidate is not automatically
an accepted interaction matrix or reconstructor.

## Dense-pattern screen

Public AOC constructed four Hadamard rows, four controller-map columns and
four spatial sine/cosine modes. Their exact rounded physical directions,
geometry, maps, seed and acquisition plan were frozen before measurement.
Each pattern used physical peak amplitudes 0.02/0.04 µm OPD, one counterbalanced
quartet per amplitude, 16 accepted frames per batch and bracketing zero-command
references. The normal qualified background, reference slopes and mask remained
in use. No ideal optical measurement entered estimation.

All 144 batches and 2,304 accepted exposures completed; restoration, release
and shutdown passed. Acquisition took 67.183 s, startup 49.710 s and shutdown
1.443 s. Several dense patterns had about 3% larger projected signed response
at 0.04 than 0.02 µm. The first screen always placed the low amplitude first,
so it could not separate amplitude association from traversal/drift.

## Reversed-order confirmation

The follow-up selected Hadamard rows 17/401 and spatial modes 1/16 after seeing
the screen. They intentionally represent strong/weak observed contrasts;
this is not a random sample of all patterns. Amplitudes were 0.01/0.02/0.04 µm,
64 accepted frames per batch, two opposite-orientation quartets per condition,
and two bracketing references per quartet. Repetition 2 reversed both amplitude
triples and pattern traversal. The plan, seed 83 and budget were frozen before
acquisition.

All 144 batches and 9,216 accepted exposures completed. The restoration exposure
was sequence 9,361; release, public shutdown and launcher exit 0 passed.
Acquisition took 135.783 s, startup 41.192 s and shutdown 1.013 s.

The table reports `(projected_derivative_high − projected_derivative_low)`
normalized by the direction's prediction norm from the earlier noisy mean
zonal matrix. It is an amplitude contrast expressed as a percentage of that
fixed norm, rather than a confidence interval or ground-truth bias estimate.

| Pattern | 0.01→0.02, repetition 1 / 2 | 0.02→0.04, repetition 1 / 2 |
| --- | ---: | ---: |
| Hadamard 17 | −0.002% / −0.033% | 2.849% / 2.840% |
| Hadamard 401 | 0.572% / 0.202% | 2.684% / 2.665% |
| Spatial 1 | 0.544% / 0.888% | 3.419% / 3.325% |
| Spatial 16 | 0.425% / 0.700% | 1.212% / 1.266% |

Independent recomputation reproduced every numerical field within
2.14×10⁻¹³. Actual normalized Float32 command directions match across these
binary-scaled amplitudes. Symmetric bracketing-reference interpolation does not
produce the balanced derivative contrast. The coherent 0.02→0.04 association
persists when order is reversed, so universal low-first ordering is insufficient
to explain it. A particular WFS, detector or optical mechanism has not been
identified. The positive 0.01→0.02 contrasts also mean that 0.01 is a conservative
finite characterization choice, not a proven linear plateau.

## Complete physical-span comparison declaration

Before acquiring the first new candidate, four recipes/method files and their
hashes were frozen in `method-cohort-inputs/policy.json`. Acquisition order is
Hadamard 1, zonal 1, zonal 2, Hadamard 2; the second repeat reverses signed-row
chronology. Seeds 84/85 identify Hadamard repeats and 86/87 zonal repeats.
The same plant snapshot, measured offsets, active mask and normal detector
settings are retained. The recipe explicitly supplies each method's amplitude
and averaging count; no hidden figure override is involved.

| Family, per sweep | Peak µm OPD | Accepted frames per signed batch | Signed batches | Accepted exposures | Including settling/restoration |
| --- | ---: | ---: | ---: | ---: | ---: |
| Complete Hadamard | 0.01 | 8 | 1,024 | 8,192 | 9,217 |
| Complete zonal | 0.04 | 16 | 554 | 8,864 | 9,419 |

The four sweeps total 34,112 accepted exposures and 37,272 model exposures.
Under an ideal linear homogeneous independent-noise model, these settings
predict Hadamard coefficient standard deviation one quarter of zonal's.
That conditional model is not an observed uncertainty bound. Hadamard's total
integrated squared physical command energy is **16 times** zonal's per sweep:
226.9184 versus 14.1824 µm² OPD × accepted exposures. Actual rounded figures
will determine the recorded energy values.

The comparison measures complete physical matrices, repeat/order discrepancy,
controller-map composition, descriptive common held-out forward predictions,
and separate preparation/startup/acquisition/shutdown/reduction time. The
older mean zonal matrix is a noisy comparator. Existing held-out data may be
used descriptively; any tuning or scientific method/reconstructor selection
requires a fresh frozen test corpus. No winner is selected from the pilot or
candidate completion alone. Full controller-modal and partial spatial sweeps
follow interpretation of this smaller full-span comparison.

## Complete physical comparison results

All four maintained owner runs completed exact accepted-frame counts,
restoration, release, public shutdown and launcher exit 0. Their terminal source
sequences equal the declared 9,217/9,419 total model exposures. Normal selected-
ROI validity and positive flux are enforced by the deployed acquisition owner;
no invalid WFS response was accepted. All matrices are 376×277 physical products.

Independent analysis checked each 20-file preparation seal and 381-file package
set, exact input arrays, graphs, five HIL helper scripts and six package source
trees. Only declared detector seed, amplitude, averaging count and order differ.
Each candidate was independently decoded from chronological responses, including
the complete 512-row Hadamard cycle, and reproduced byte for byte.

| Per-family result | Zonal, 0.04/N16 | Hadamard, 0.01/N8 |
| --- | ---: | ---: |
| Relative physical repeat Frobenius discrepancy | 0.48271 | 0.12343 |
| Empirical controller spectral discrepancy, pixel/µm OPD | 3.96002 | 0.98450 |
| Acquisition, repeat 1 / 2 | 146.762 / 146.507 s | 156.867 / 154.381 s |
| Accepted signed command energy per sweep, µm² OPD × exposures | 14.1823994 | 226.918390 |
| Cold AOC estimation, repeat 1 / 2 | 117.672 / 117.928 ms | 190.067 / 246.921 ms |

The spectral quantity is `opnorm(S (D₁−D₂) B, 2) / √2`, with the exact existing
controller map B. It is an empirical repeat/order scale, not an unbiased noise
estimate or confidence interval. Matrix differences use independent detector
seeds and reversed chronology. The observed Hadamard/zonal discrepancy ratio
is close to the ideal model's one-quarter prediction. This association does not
establish that the model captures every noise or nonlinear contribution.

Both two-sweep means were scored against the **same previously acquired** 16
held-out physical commands and their two balanced signed-pair observations.
Chronological receipts, actual Float32 commands, bracketing references and
source bindings were checked. Before/after references are separately diagnosed;
like the original frozen score, they are not subtracted from signed-pair
contrasts. The matrix predicts each actual physical demand. No reconstructor,
method setting or controller property was selected from these scores.

| Mean-matrix held-out residual RMS | Zonal, repeat 1 / 2 | Hadamard, repeat 1 / 2 |
| --- | ---: | ---: |
| Sparse controller directions | 0.002628 / 0.002566 pixel | 0.001801 / 0.001800 pixel |
| Dense mixed controller directions | 0.028834 / 0.028812 pixel | 0.008901 / 0.008893 pixel |

The mixed subgroup's squared error relative to zero prediction was about
0.0570 for zonal and 0.00544 for Hadamard. Independent recomputation reproduced
all case, family and baseline scores within 1.43×10⁻¹⁴ and both spectral norms.
These measurements support lower repeat discrepancy and better finite-corpus
prediction under the declared Hadamard settings. They do not establish
intrinsic algorithm superiority at equal energy, complete-pattern linearity,
statistical confidence or physical acceptance. Hadamard uses 16× energy and
has longer observed acquisition despite fewer accepted exposures. The cause
of that timing difference has not been profiled. Cold estimation includes
compilation and is not a warmed numerical benchmark.

The previous full N64 zonal baseline remains a noisy comparator, with its
separate qualified inverse/correction gate. No active inverse was replaced.
The comparison source/test and result hashes are preserved in the evidence
ledger. The exploratory comparison script remains a cache artifact; selectable
acquisition and candidate reduction are maintained production entry points.

## Next directional comparison, declared before acquisition

The next four methods are frozen in `directional-cohort-inputs`: two
controller-modal 221-coordinate runs at 0.04/N16 and two spatial 64-mode runs
at 0.01/N16, with independent seeds and opposite signed-row order. They total
18,240 accepted exposures and 19,384 model exposures. The modal basis is the
existing controller→physical map B, normalized by column peak; all peaks here
are one. Its actual Float32 representation differs from B by at most
4.49666×10⁻⁸ in normalized command coordinates. The spatial sampled basis has
rank 64 at the declared relative tolerance 10⁻¹⁰ and condition number 5.13353.

Controller-modal G has shape 376×221 and can be composed into the complete
declared controller response with its recorded representation residual.
Spatial G has shape 376×64 and measures only that span. It will be compared
against fresh frozen sparse/mixed combinations inside that span, including
Float32 representation residuals; it will not be labelled a full physical D.
All eight fresh spatial directions and their 48-batch acquisition plan were
frozen before the first directional candidate was acquired. No inverse or
scientific method winner is accepted by this declaration.
