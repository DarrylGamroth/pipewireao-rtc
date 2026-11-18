# SPIDERS fringe filtering

The lab checkout in `~/spiders-working` supplies two related calibrations.
The CRED2 frame sorter publishes the most recent fringed exposure minus
the most recent unfringed exposure on Aeron stream 5003. The SCC service
subscribes to 5003, subtracts its selected reference pixels and applies
the matrix. The normal launcher invokes `generate-scc-im.jl`. Its
640 × 512 recipe uses an apodized image mask and Fourier radii 89–190.
The saved main-camera January calibration has a 416 × 380 crop, so the
launcher script alone does not identify its exact generation settings.

The fitted HIL optical model represents the iFTS port. The lab's separate
`archiver-calibrated-scc-2-ifts.jl` used the iFTS camera on stream 1016
for its push/pull responses, while also recording the chopped CRED2
stream. The iFTS generator passes radii 29–60 on a 256 × 200 DFT,
inverse-transforms to the detector plane, masks the two probe spots and
selects the half dark hole. It regularizes the inverse and writes a zero
reference image. A filtered calibration acting on the simulator's chopped
camera signal combines the iFTS geometry with the SCC service measurement.

## Lab artifact replay

For all 650 saved iFTS modes, the reconstructed filtered image matches
the stored spot-masked product at every nonzero output pixel, with maximum
relative error zero. This checks the Fourier filter independently of how
spot centers were selected. The saved reference is exactly zero and the
final lab mask selects 8,456 pixels. Run `lab-filter.jl /mnt/datadrive/DATA/SCC-IFTS`
in the optical package environment. [Numerical results](lab-filter.json)

## Transfer to the fitted camera

We replayed the 66 positive/negative probe directions on CUDA around the
ordinary DM flat at both calibration amplitudes. Selecting the RTC pixels
from the full 221 × 221 derivatives reproduced all 132 archived columns
exactly. The two nuisance directions belong to LLOWFS. The fitted
reconstructor uses the other 64 directions for SCC.

We mapped the iFTS annulus using the detector dimensions and 7.13 lab
and 7.86 fitted pixels per λ/D. The band retained 78.14% of the
mean-subtracted flat chopped image power and 2.34% of the unfringed
image power. Applying the two hard spot masks reduced the measured rank
to 58 under the calibration cutoff. We used the band alone to test
all 64 modes. The live graph applies the inverse to the selected raw
F−U pixels with the zero lab reference.

At gain magnitude 0.05, the linearized update on the measured raw
probes has spectral radius 0.9751. Central differences along the first
camera-generated correction predict a 2.11% reduction in unfringed
intensity at the static normal flat for both diagnostic poke amplitudes.
[Conditioning](acquisition-conditioning.json) · [Directional check](first-step.json)

Run `push-pull.jl MODULE APPLICATION ASSETS OUTPUT` to regenerate the
full camera derivatives from the calibration application, then
`reconstruct.jl APPLICATION ASSETS OUTPUT` to build the matrix and
reference. Re-run the first command with an additional `first-step`
argument for the directional check. MODULE is the shared instrument
tools' OpticalCalibration.jl. ASSETS is the normal-flat SCC artifact
directory from the preceding acquisition experiment.
