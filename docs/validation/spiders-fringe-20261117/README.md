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
