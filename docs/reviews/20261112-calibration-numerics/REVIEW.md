# AdaptiveOpticsCalibration ownership review

Reviewed RTC `13de882` against the local AdaptiveOpticsCalibration (AOC)
checkout `c7983df`. AOC exposes numerical methods through
`prepare`, `process` and `process!`. It accepts scientific arrays and
specifications. Its package contract excludes plant propagation, graph
execution, equipment control, transport, persistence, acceptance and
activation. This source review follows the
[calibration and capture-file scope review](../20261112-calibration-scope/REVIEW.md).
The CaptureFiles and CLI retirements are complete.

## CAL-SCOPE-05 — Extract optical reconstruction and diagnostics

**First transfer. High confidence in ownership. AOC API work required.**

The array-only portion of [optical calibration](../../../ext/optical_calibration.jl)
builds the full and half-poke interaction matrices, fits per-branch TSVD
reconstructors and measures recovery, cross-talk and held-out prediction.
`optical_nulling_projection` also solves for compensating owned-mode commands,
normalizes command columns and measures the residual. These operations can
receive explicit command projections, owned and fitted mode indices,
response arrays, and a TSVD cutoff. Move the grouped numerical work into AOC's
existing InteractionMatrices, Reconstructors and Diagnostics interfaces as
appropriate. Keep the optical branch declarations, centroid-specific choice of
fitted columns, report serialization and acceptance thresholds with the caller.
RTC can still drive the probes and pass signed responses or derivatives to AOC.

AOC already provides `ZonalPushPull` and `TSVDInverse`. Reuse those building
blocks where their input order and numerical behavior match. AOC's
`InteractionMatrixStability` uses a symmetric difference with the sum of norms
and adds column gates. The RTC optical branch uses
`norm(D - Dhalf) / max(norm(Dhalf), eps(Float32))`. Substituting the AOC
stability method would change the acceptance contract. Preserve the RTC
quantity and zero-response behavior through a separate numerical mode or
method only if needed. Return diagnostic quantities for the caller to qualify.

Before switching callers, compare full and half-poke matrices, retained rank,
unowned-mode row zeroing, recovery, nulling normalization and residual, and
held-out results against the current implementation. Include zero responses,
rank deficiency, disjoint mode assignments, and signed chopped measurements.
Run `test/calibration_optical.jl`, `test/calibration_chopped.jl` and
`test/calibration_optical_publication.jl` after switching. Keep artifact keys,
units and acceptance semantics stable. This can remove a contiguous numerical
section of RTC's 3,073-line optical file. The file also prepares graphs and
publishes products, so full deletion depends on other owners taking those paths.

## CAL-SCOPE-06 — Share the OPD-weighted modal inverse if needed

**Second transfer. High confidence in the separation. Confirm the shared use.**

[Modal calibration](../../../ext/modal_calibration.jl) applies inverse
pupil-RMS OPD column weights before the AOC TSVD and maps the inverse back to
the original coordinates. AOC's current `TSVDInverse` is unweighted and its
`StrokeWeightedTikhonov` solves a different regularized problem. If the optical
extraction or a second caller needs weighted TSVD, give AOC an explicit scale
array and let it own both transforms and the inverse. The caller supplies
measured RMS and the rule for excluding near-zero modes. The same file's
tip/tilt least-squares fit and QR complement are numerical candidates only
after separating them from the mirror selection and stage allocation. Keep the
current calls until a shared contract is established. Compare rank, zero-weight
behavior and reconstruction in original command units before changing callers.

## CAL-SCOPE-07 — Keep orchestration with its existing owners

**High confidence in the package boundary. Larger RTC deletions depend on
moving application workflows.**

- [Reference campaigns](../../../ext/reference_calibration.jl) and
  [pyramid reference campaigns](../../../ext/pyramid_reference_calibration.jl)
  total 1,639 lines. AOC already owns dark moments and both reference
  accumulators through ReferenceFrames. Move the campaigns to the shared
  instrument tools after exposing the required RTC acquisition interface.
  Keep declared commands, stage deadlines, restoration and validity policy
  with the campaign. The Classic and GPI2 private-core selectors remain the
  verification boundary for that transfer.
- [Shack-Hartmann calibration](../../../ext/shack_hartmann_calibration.jl)
  already delegates interaction and inverse math to AOC. Plant stepping,
  recipe binding and publication should move with the instrument workflow.
- [Optical expectation](../../../ext/optical_expectation.jl) includes AOS
  detector statistics, ADC rounding, graph execution and campaign-specific
  evidence. Reusable detector expectations belong in AOS. AOC's
  RepeatedResponseMoments consumes complete, equally weighted repeats. It
  cannot replace the conditional control variate and independent rounding
  checks. Keep those checks with the expectation method until an equivalent
  transport-independent numerical boundary is demonstrated.
- Keep live Collect, native calibration actions, session admission and
  restoration, and deployment artifact validation in RTC. Keep simulated
  exposure publication in standalone HIL. FITS and report publication for
  calibration products can leave RTC with the instrument tools. Preserve
  export-side admission of the products.

The ownership decisions are based on source and public API inspection.
No numerical or runtime code changed in this review.
