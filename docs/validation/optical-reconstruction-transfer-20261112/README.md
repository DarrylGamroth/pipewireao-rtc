# Optical reconstruction transfer verification

This implements CAL-SCOPE-05 in the
[AdaptiveOpticsCalibration ownership review](../../reviews/20261112-calibration-numerics/REVIEW.md).
The RTC baseline is `13de882`. AdaptiveOpticsCalibration `fe8e07c`
provides the new methods and sets the package version to 0.17.4. The
RTC integration requires that version or a compatible newer release.

The transfer retains signed central differences with direct division, the
existing TSVD cutoff and fit coordinates, zeroing of unowned rows, and
the full-to-half-poke difference relative to the half-poke norm with a
Float32 epsilon floor. The held-out reconstruction accumulates branch
estimates in declaration order. Its pupil diagnostic removes piston and
retains the Float64 epsilon floor on the original residual norm.
RTC still selects probes, measures the plant, applies acceptance thresholds
and writes the products.

## CPU parity against RTC

Julia 1.13.3 ran the baseline and candidate in temporary copies of the same
science environment. The baseline used AdaptiveOpticsCalibration 0.17.3.
The candidate used a local development override to `fe8e07c` and the RTC
candidate checkout. The other science dependencies retained their existing
versions.

Temporary copies of `test/calibration_optical.jl` and
`test/calibration_chopped.jl` wrapped each completed calibration and recorded
its numerical products with Julia Serialization. The comparison used
`isequal` for each field, without a tolerance. All 13 completed calibrations
and 22 branches matched, including both interaction matrices, reconstructor,
selection and recovery matrices, rank, singular values, error and cross-talk,
command projection, nulling diagnostics, held-out results, acceptance and
calibration identity. The selectors passed 203 optical and 58 chopped
assertions. The optical publication selector passed 72 assertions.
AdaptiveOpticsCalibration's `Pkg.test()` passed 2,751 assertions,
including the signed-probe, zero-response, rank and held-out boundary checks.

The full RTC core suite passed 10,482 assertions with the registered
PipeWireAO_jll prefix. The checks ran on CPU and used local development paths for the new release.

## AdaptiveOpticsCalibration 0.17.4 release

[AdaptiveOpticsCalibration v0.17.4](https://github.com/DarrylGamroth/AdaptiveOpticsCalibration.jl/releases/tag/v0.17.4)
tags commit `fe8e07c76dce9a2f5168e593d4854597cb3f7a2c`.
[DarrylGamrothRegistry 47cd974](https://github.com/DarrylGamroth/PackageRegistry/commit/47cd9746765fd5ec7c9d1cf9857e3d812557571e)
registers source tree `3091300ace8597034aab04f9bb9e2063079a5d0a`.

Julia 1.13.3 started with an empty depot and only General and
DarrylGamrothRegistry. The sole local path was the unreleased RTC candidate,
`38d8d5b`, whose selectors exercised the integration. Every external package
was resolved by Pkg through the registries and the installed
AdaptiveOpticsCalibration tree matched the registered hash.
The direct science cohort was AdaptiveOpticsCalibration 0.17.4,
AdaptiveOpticsSim 0.3.22, AdaptiveOpticsSimPipeWireHIL 0.5.1,
FilterGraphAlgorithms 0.12.2, FilterGraphPipeWire 0.5.3, FilterGraphs 0.10.2,
PipeWireAO 0.9.2 and PipeWireAO_jll 4.0.2+0.

The RTC optical selector passed 203 assertions, chopped calibration passed
58, and publication passed 72. Repeating the comparison against the RTC
baseline produced exact equality for 13 completed calibrations and 22
branches, including full- and half-poke matrices, held-out diagnostics,
acceptance and calibration identity.
