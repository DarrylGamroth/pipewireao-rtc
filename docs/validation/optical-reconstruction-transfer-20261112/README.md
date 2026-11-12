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
