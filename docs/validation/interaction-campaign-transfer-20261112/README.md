# Offline interaction calibration campaign transfer

This implements RTC-SCOPE-01 from the
[scope review](../../reviews/20261112-remaining-rtc-scope/REVIEW.md#rtc-scope-01--move-offline-interaction-calibration-and-validation).
The instrument tools' `InteractionCalibration` module drives the built
application's YAML-selected Shack–Hartmann or modal procedure. RTC retains
the recipe reader, typed graph and bundle preparation, settings used by
staging, and live acquisition.

## Comparison inputs

Baseline RTC `1e1b114` used the original launchers from instrument revision
`355c139`. The candidate used the shared module on the same applications,
Julia 1.13.3 and one BLAS thread. The other 199 package records in the two
environments matched, including AdaptiveOpticsCalibration 0.17.4,
AdaptiveOpticsSim 0.3.22, AdaptiveOpticsSimPipeWireHIL 0.5.1,
FilterGraphAlgorithms 0.12.2, FilterGraphs 0.10.2, FilterGraphPipeWire 0.5.3,
PipeWireAO 0.9.2 and PipeWireAO_jll 4.0.2+0.

| Input | Classic SHA-256 | GPI2 SHA-256 |
| --- | --- | --- |
| Deployment catalog | `e66c6016b2078566b5d5ccfbc2a3967d449fccfbc497d3fa2d543ad095f34c0a` | `a529a2329b62f40cc60c0d7dba4eac3f7ca1dacffa485f8c548f35c955820b13` |
| Calibration recipe | `3940442a86fe0d9203e17c8433bd940902581815ed088d2ce6f22839301efd09` | `36c173b2487398aeb4af58afee51070b6d05d1cf95bc155330b43e57572a06dc` |

## Classic

All three campaigns produced 212 modes at retained rank 208. The candidate
and an independent baseline repeat matched byte-for-byte for all 25 FITS
artifacts, the graph and the context. Their result reports differed only in
source-file provenance hashes. Against the first baseline, relative L2
differences were 0.0006514 for the interaction matrix and 0.0018376 for the
reconstructor. The original path reproduced those same differences on repeat.

The first baseline, repeat and candidate completed 512 frames with the same
seed and zero clipped actuator samples. Mean pupil RMS after frame 128 was
48.2952 nm, 48.3338 nm and 48.2920 nm, respectively. These are finite model
results. The validation time series varied between repeats of the original
path. The comparison did not isolate the source of that variation.

## GPI2

Both campaigns produced 1,509 modes at retained rank 1,445. The graph, context
and 32 of 36 FITS artifacts matched byte-for-byte. Relative L2 differences
were 0.002021 for the interaction matrix, 0.008406 for the reconstructor,
0.00002930 for singular values and 0.02918 for the modal reference. The
maximum absolute modal-reference difference was 1.771×10⁻⁹. The inverse
residual changed from 0.048331883 to 0.048340388.

Both 48-step replays passed all four authored disturbance cases. The worst
residual ratio was 0.007376 in the baseline and 0.007372 in the candidate,
with a 0.8 acceptance limit. The largest paired change in residual ratio was
0.00002801. Both replays loaded and checked their typed bundles.

The comparison establishes matching rank, graph and acceptance outcomes.
The exploratory elementwise comparison at 10⁻⁵ relative tolerance failed
on the inverse residual before reaching the FITS checks. The runs establish
the differences above. Their cause was not isolated.

## Regression selectors

| Selector | Passing assertions |
| --- | ---: |
| RTC core | 10,503 |
| Instrument Classic calibration | 167 |
| Instrument Classic staging | 17 |
| Instrument modal completion guard | 2 |
| Classic reference on a private core, including 57 live assertions | 100 |

The staging selector used the candidate Classic bundle. The live selector
completed dark, lamp-training and qualification stages on an isolated
PipeWire core. Neither result qualifies physical devices or timing.

## GPI2 FFT planning isolation

The follow-up uses the same built GPI2 application, recipe, package cohort,
and CPU settings. It repeats the original RTC launcher with default planning
and compares both launchers with a controlled planning policy. The controls
run in fresh processes and modify no production source or calibration assets.

Two preparations of the same GPI2 calibration plant used identical zero
and positive woofer commands over 13 frames, with detector noise disabled
by the authored graph. Their pupil OPD matched bit-for-bit. FFTW selected
different single-precision plans. The pyramid photon-rate arrays differed in
all 13 frames. Nearest-even UInt16 ADC rounding changed five pixel samples
by one code across four frames. Replaying each preparation's FFTW wisdom
reproduced its own photon-rate and detector arrays byte-for-byte. Changing
only the repeated host FFT planning policy to `FFTW.ESTIMATE` yielded
identical OPD, photon-rate and detector arrays in two fresh processes.

This locates the observed differences upstream of the estimator and SVD.
Different FFT arithmetic order perturbs photon rates near an ADC rounding
boundary. The interaction matrix divides the signed response difference by
twice the probe amplitude. The reconstructor then inverts the weighted
interaction matrix with the recipe's existing rank cutoff.

The [probe](probe-plans.jl) accepts the built application, planning mode and
an existing output directory. Use `measure` to export wisdom and arrays, or
`replay` with `GPI2_FFT_WISDOM` pointing to a recorded wisdom file.
The [campaign runner](run-gpi2.jl) accepts the planning mode, original or moved
launcher path, application, fresh output and, for validation, its input bundle.
It uses [the same planning control](fft-control.jl) in calibration and
validation. Use `OPENBLAS_NUM_THREADS=1` in each science environment.

| FITS artifact | Original versus original repeat, relative L2 | Original versus moved, relative L2 |
| --- | ---: | ---: |
| Interaction matrix | 0.00200720 | 0.00202122 |
| Reconstructor | 0.00847850 | 0.00840645 |
| Singular values | 0.0000242475 | 0.0000292969 |
| Modal reference | 0.0287186 | 0.0291819 |

The original repeat changed the same four artifacts. Its maximum absolute
modal-reference difference was 1.750×10⁻⁹. The original repeat retained rank
1,445 and passed all four replay cases. Its worst residual ratio was 0.007354.

With the repeated FFT policy held at `ESTIMATE` in both environments, the
full 1,509-mode calibration produced byte-identical graphs, contexts, result
reports and all 36 FITS files. Both retained rank 1,445. All four 48-step
validation traces and scientific metrics matched exactly after excluding
per-step elapsed time. The worst residual ratio was 0.00738855.
The [comparison](check-fft-parity.jl) verifies hashes and report equality.
The experiment leaves default production FFT planning intact.
