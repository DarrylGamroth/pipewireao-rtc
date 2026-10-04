# Copper precision and amplitude characterization

The maintained `deployment/copper_quality.jl` collects a bounded one-direction
pilot through the ordinary deployed Copper CPU calibration endpoint. It requires
a complete-frame FGN/JFG science base and its completed measured-reference
candidate from `copper_reference.jl`. It does not adopt a reference or reconstructor.
The [predeclared plan](COPPER_QUALITY_PLAN.md) explains the scientific limits.

## Explicit recipe

Declare JSON Version 1 with exactly these fields:

```python
recipe = {
    "version": 1,
    "actuator": 139,
    "amplitudes": [0.02, 0.04, 0.08],
    "repeats": 2,
    "frames_per_batch": 8,
    "reference": [0.0] * 277,
    "seed": 444,
    "lamp_magnitude": 5.752574989159953,
    "settling": {"kind": "discard_exposures", "frames": 1},
    "adc_upper_rail": 16383,
    "request_timeout_ns": 30000000000,
    "stage_timeout_seconds": 900,
}
```

The actuator is one-based in the 277-physical-command order. Figures are absolute
µm OPD; the ordinary DM adapter converts once to metres. Amplitudes must remain
positive and distinct after Float32 rounding. The recipe admits 1–3 ascending
amplitudes, 2–4 traversals and 2–16 frames per batch, with at most 32 batches.
Every represented positive/negative figure must straddle the reference; collapsed
or overflowing pokes reject before launch. Reduction uses the actual represented
interval and reports its command midpoint relative to the reference.

Each traversal starts and ends with a null batch. Even zero-based traversals
use ascending amplitude and positive then negative signs; odd traversals reverse
both. This balances order but leaves time, normalization history and sign effects
confounded. Do not interpret repeat differences as a noise-only estimate or a
causal linearity measurement.

The candidate must match the original science base, reference figure, lamp,
ADC rail, graph, non-background calibration arrays and detector/plant fixture.
Only the declared detector seed and measured background change. The current
qualified fixture is 64×64 and 14 bit; it is not a qualified DU860 gain/noise model.

## Invocation

```sh
julia --startup-file=no --project=deployment/julia deployment/copper_quality.jl \
  --base-package /absolute/path/to/copper-cpu-science-base \
  --reference-candidate /absolute/path/to/completed-reference-candidate \
  --recipe /absolute/path/to/recipe.json \
  --output /absolute/path/to/fresh-pilot \
  --aoc-source /absolute/path/to/AdaptiveOpticsCalibration.jl \
  --rtc-binary /absolute/path/to/pipewireao-rtc \
  --calibration-binary /absolute/path/to/rtc-calibrate \
  --runtime /short/absolute/path/to/fresh-runtime
```

Use `/opt/pipewireao` and fresh output/runtime roots. The inherited affinity mask
must admit every configured owner/helper core. The characterized host runs admit
CPUs 2–15 and exclude CPUs 0 and 1. Serialize live runs on these shared cores.
Exposure association and settling use completion events; lifecycle readiness
polling is not exposure timing evidence.

## Products

`quality-inputs.json` seals the recipe, deterministic schedule, copied reference
products/reports and exported package. `quality-result.json` records source
identities, lifecycle status and wall time. `training-evidence` contains
chronological control receipts, per-probe raw/pixel/intensity captures and the
successful `analysis.json` report. Completed batches are preserved before
advancing, including when a later operation fails. Failed runs cannot publish a
complete candidate; retain them and use fresh paths for retries.

| Artifact | Float64 row-major shape | Units |
| --- | --- | --- |
| `batch-means.f64le` | batch × 3,600 | normalized pixel |
| `batch-variances.f64le` | batch × 3,600 | normalized pixel squared |
| `derivative-repeats.f64le` | amplitude × traversal × 3,600 | normalized pixel / µm OPD |
| `derivative-means.f64le` | amplitude × 3,600 | normalized pixel / µm OPD |

Batch reduction uses public AOC `Diagnostics.RepeatedResponseMoments`; the
finite-amplitude one-column secant uses public `InteractionMatrices.ZonalPushPull`.
Intensity is diagnostic and is excluded from the 3,600-value four-pupil response.
Reports include ADC/intensity ranges, first-versus-later sample differences,
null/reference differences, derivative norms/cosines and signed-pair midpoints
against bracketing nulls. No drift correction is applied.

N−1 variances are descriptive. The previous-frame normalizer can correlate
adjacent exposures, and the discarded exposure's intrinsic validity is not
provided by the settling receipt. Do not infer confidence intervals or use
variance divided by frame count as a proven batch-mean uncertainty. Successful
collection characterizes this direction; it does not establish a global
interaction matrix, inverse, correction, instrument precision or frame-rate claim.
