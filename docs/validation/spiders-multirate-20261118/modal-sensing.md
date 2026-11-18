# Low-order sensing and temporal modal filters

## Current controller

The 112-mode SCC profile reserves two more modal coordinates for LLOWFS tip
and tilt. Both controllers use a scalar integrator (gain −0.05, pole 1).
The LLOWFS integrator gates its update on measurement validity. Neither
branch includes a temporal biquad. The SCC fringe filter is a spatial
filter used to build its interaction matrix.

FilterGraphAlgorithms 0.12.5 already registers `biquad-cascade-f32` for a
shared or per-mode bank of second-order sections. Adding temporal filters
would be a controller change. Each branch needs coefficients appropriate
to its accepted sample rate and delay, plus defined behavior when an
exposure is missing or a filter's state is reset. The fitted SPIDERS SCC can
produce a new rolling difference on each accepted alternating exposure
after priming. The frequency of complete chop cycles is different from
the frequency of those updates.

## MLLOWFS

The registered CPU Algorithm `ml-llowfs-f32` implements the lab's fixed
SimpleChains estimator. A 20 × 20 image crop is normalized by total flux,
centered and divided by its sample standard deviation. A model with 240,584
Float32 parameters returns 14 coefficients in the lab's calibrated basis.
The lab then maps those coefficients to 468 actuator commands. This is
distinct from the linear 14-mode differential-image inverse in the LOWFS
service. [Lab RTC comparison](../spiders-lab-mode-bank-20261117/lab-rtc.md)

The registered Algorithm reproduced all 14 Float32 predictions exactly on
the first archived crop using the lab's best saved parameters. The [receipt](ml-llowfs-parity.txt)
includes the two output vectors, model normalization and input hashes.
Reproduce with `check_ml_llowfs_parity.jl LAB_SERVICE_SOURCE WEIGHTS_FITS
IMAGE_CUBE_FITS` in the 112-mode application environment. This check uses
the archived lab network declaration and preprocessing. It establishes
inference parity on one image. It supplies no accuracy or timing estimate.

## Using additional modes in the RTC

1. Register the lab crop against the fitted or physical LLOWFS detector and
   reproduce its axis order, photometry, background treatment and operating
   range. The current fitted input is 256 × 320; a crop chosen by matching
   array dimensions alone would not establish the optical registration.
2. Place region extraction and the existing ML estimator in the low-order
   graph. Start by recording coefficients without sending mirror commands.
   Measure both sensors' signed responses to calibrated low-order DM pokes,
   then compare the ML and linear image estimators on independent labeled
   exposures. The archived cube has 203,088 images and no embedded command
   labels. Check a separate label source or acquire synchronized probes for
   accuracy measurements.
3. Define reference, sign, scale and modal ordering in the actual controller
   basis. Assign the selected low-order modes to LLOWFS, adjust the SCC
   projection to remove overlap, and regenerate the command and actuator
   limit-feedback maps. The present 112-mode calibration nulls just the
   measured tip/tilt coordinates. Simply padding the existing centroid
   output or appending 14 lab coefficients would not calibrate the joint
   controller.
4. Validate modal cross-talk, latency, validity at low flux, saturation and
   multirate recovery before closing the extra modes. The lab model fixes
   its 14 outputs; a different set of modes requires evidence that they
   are represented or a separately qualified model. A future dedicated
   low-order DM would need its own calibrated projection and physical limits.
