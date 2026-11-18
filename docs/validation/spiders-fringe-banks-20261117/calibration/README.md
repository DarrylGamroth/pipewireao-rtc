# Normal-flat fringe calibration for 112 SCC modes

The 56 spatial frequencies give 112 sine and cosine modes. The original
32 frequencies come first in the [calibration recipe](optical-dark-hole.yaml).
The added 24 directions sample eight orientations at each of 5, 7 and 9 λ/D.
The two LLOWFS commands retain indices 1 and 2 in the 114-element joint vector.

CUDA push/pull measurements at 5 and 2.5 nm reproduced every original
column of the two 64-mode interaction matrices exactly. The 221 × 221
detector, 12,703 selected pixels, calibration reference image and native
DM completion matrices also matched exactly. The effective LLOWFS map
from centroid to native demand is identical. Its projection of constraint
feedback back to tip/tilt changes when the joint basis grows (44.42%
relative Frobenius difference). This path receives the difference between
requested and limited demand. [Bank and LLOWFS overlap](bank-overlap.json)

The fitted iFTS fringe band, chopped measurement, zero target and Tikhonov
rule follow the [64-mode experiment](../../spiders-fringe-20261117/README.md).
The band retained all 112 SCC directions. Adding hard spot masks would
have retained 104. The Tikhonov scale (smallest retained singular value)
was 71,173 electrons/m for 112 modes and 220,779 for 64. At gain −0.05,
the linearized iteration spectral radius was 0.97686 at both poke levels.
The one-step operator norm was 1.039. A single camera-derived correction
at the static flat lowered mean unfringed intensity by 3.51% in the CUDA
model. [Conditioning](acquisition-conditioning.json) · [First step](first-step.json)

## Reproduction

Use the same normal-flat SPIDERS calibration input, CUDA environment
and optical package cohort as the 64-mode run. Copy the shared instrument
tools at revision `58ecd8ac842a789c8df06586a2875273b0b80042` into the
experiment directory. Apply `frequency-limit.patch` with `patch -p1` in
the copy of `tools/optical_calibration`. The existing validation limit is
32 spatial frequencies. The experimental limit is 56. The instrument
repository was unchanged.

1. Run `recipe.jl OLD_RECIPE NEW_RECIPE` on a copy of the normal-flat
   calibration application; use the new recipe and set its joint RTC
   command count to 114. Run `calibrate.jl MODULE APPLICATION OUTPUT`
   with the copied OpticalCalibration.jl module. [Calibration report](calibration.json)
2. Copy `push-pull.jl` and `reconstruct.jl` from the 64-mode evidence
   into the same directory and apply `wide-replay.patch` with `patch -p1`.
   Run `push-pull.jl MODULE APPLICATION OUTPUT/calibration/scc/artifacts DERIVED`
   in the CUDA environment. This reconstructs the full detector derivatives,
   filters them and selects the band-only inverse. Each full-frame derivative
   reproduced the archived selected columns exactly.
3. Copy the new recipe, 114-command declaration and derived acquisition FITS
   products into a copy of the instrument source used for each seed.
   Run `stage.jl SOURCE APPLICATION OUTPUT/calibration PREFIX` to bind both
   branch bundles and the filtered SCC inverse. `check-bank.jl NARROW WIDE`
   verifies the nested responses, effective LLOWFS maps and zero flat in
   the two experiment directories.

The hash lists record files in the original experiment workspace.
[Inputs](inputs.sha256) · [Products](outputs.sha256)
