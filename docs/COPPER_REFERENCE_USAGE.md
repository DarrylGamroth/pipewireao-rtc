# Copper measured dark and reference candidates

`deployment/copper_reference.jl` acquires three finite batches through the
existing deployed calibration endpoint: dark, lamp training and independently
seeded lamp qualification. It uses public AdaptiveOpticsCalibration moments;
the [plan](COPPER_REFERENCE_PLAN.md) and [review](COPPER_REFERENCE_REVIEW.md)
describe the coordinate and acceptance boundaries.

## Inputs and invocation

Use a complete-frame Copper FGN or JFG CPU **science base**, with its complete
`graphs/graph.conf.in`, local AOC dependency and valid deployment descriptor.
An already split calibration package is not a science base. This increment
requires the explicit 64×64, 14-bit detector fixture and `/opt/pipewireao`.

Declare the complete Version 1 recipe in JSON. This example writes the
measured fixture's zero 277-coordinate physical reference:

```python
import json
from pathlib import Path

recipe = {
  "version": 1,
  "dark_frames": 8,
  "training_frames": 8,
  "qualification_frames": 8,
  "seeds": {"dark": 111, "training": 222, "qualification": 333},
  "lamp_magnitude": 5.752574989159953,
  "reference": [0.0] * 277,
  "settling": {"kind": "discard_exposures", "frames": 1},
  "adc_upper_rail": 16383,
  "request_timeout_ns": 30000000000,
  "stage_timeout_seconds": 300
}
Path("recipe.json").write_text(json.dumps(recipe, indent=2) + "\n")
```

Reference values are finite physical coordinates in micrometres OPD.
The three counts must each be 2–64, seeds must be distinct UInt32 values and
settling must discard at least one completed exposure or require positive
model time. Immediate settling is rejected. Declare policy before acquisition.

```sh
julia --startup-file=no --project=deployment/julia deployment/copper_reference.jl \
  --base-package /absolute/path/to/copper-cpu-science-base \
  --output /absolute/path/to/fresh-candidate \
  --recipe /absolute/path/to/recipe.json \
  --aoc-source /absolute/path/to/AdaptiveOpticsCalibration.jl \
  --rtc-binary /absolute/path/to/pipewireao-rtc \
  --calibration-binary /absolute/path/to/rtc-calibrate \
  --runtime /short/absolute/path/to/fresh-runtime
```

Both output and runtime roots must be fresh. Keep the runtime path short for
Unix socket limits. The launcher places owners according to the existing
deployment; an enclosing affinity mask must include every declared core.
The characterization used inherited CPUs 2–15, excluding CPUs 0 and 1.
Serialize live runs with other deployments that use those cores.

## Products and failure behavior

The output contains the frozen recipe, fresh per-stage bases/packages, capture
receipts and analysis reports, plus:

| File | Type and order | Meaning |
| --- | --- | --- |
| `measured-background.f32le` | 64×64 Float32, row-major | Mean raw detector ADC counts |
| `measured-dark-variance.f64le` | 64×64 Float64, row-major | Descriptive N−1 ADC variance |
| `measured-reference-pixels.f32le` | 3,600 Float32 values, pupil-block wire order | Mean of individual normalized absolute lamp vectors |
| `measured-reference-variance.f64le` | 3,600 Float64 values, same order | Descriptive N−1 normalized-pixel variance |
| `qualification-mean.f64le` | 3,600 Float64 values, same order | Fresh lamp mean compared with the frozen Float32 reference |

The mean intensity is diagnostic and is excluded from the 3,600-value response.
The reference uses four pupils, not an I4Q signal. Training and qualification
use the measured dark background while preserving the base flat, pupil
selection and command maps.

`reference-result.json` records completion or failure, source snapshots,
artifact/report identities and timing. Each stage must restore, release and
complete public shutdown before reduction. ADC rail equality, invalid lamp
responses, altered producer products or changing source inputs reject the
candidate. Preserve a failed output and use new paths for a retry.

## Acceptance limits

Successful collection creates reusable candidates. It does not adopt reference
subtraction in an active science graph, select an interaction matrix or
reconstructor, or demonstrate correction. Previous-frame normalization can
correlate adjacent samples, so sample variance is descriptive and no confidence
interval is inferred. Qualification reports residuals against the frozen
reference without inventing an instrument tolerance.

The detector fixture remains provisional, rather than a qualified DU860 EMCCD
configuration. Acquisition and numerical timing include cold preparation and
compilation; model period and exposure duration do not establish wall cadence.
