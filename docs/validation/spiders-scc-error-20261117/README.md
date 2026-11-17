# SPIDERS dark-hole brightening and SCC error

This check repeats the 64-mode TSVD arm of the
[mode-count and damping comparison](../spiders-factorial-20261117/README.md).
The standalone HIL simulator executes on the RTX 3080 with CUDA. Each seed
has its own fitted-dual application and private PipeWire core. The detector
model has photon noise disabled. SCC uses gain −0.05 and pole 1 around the
same optimized DM bias. LLOWFS stays open.

## Operating point

The experimental DM shape was obtained before the live run. The offline
CUDA search tried positive and negative moves along 64 modal directions
and kept moves that reduced the simulated unfringed mask mean. The run
applied the resulting fixed shape in the shared DM graph. The chopped
reference and response were calibrated around that shape. LLOWFS was
open. The results therefore measure SCC tracking about a supplied dark
hole. They do not establish that the SCC loop can form the hole from
the instrument's ordinary DM flat.
The offline search and static comparison are recorded in commit `edbc795`.

For camera-driven acquisition, the SCC target and interaction matrix
need to describe the same camera measurement. The earlier SPIDERS
generator `sccservice/scripts/generate-scc-im.jl` applies a spot mask to
each measured probe response before inversion and writes a zero
reference image. The live `choppedframesortservice` publishes a rolling
fringed-minus-unfringed image. The live `sccservice` subtracts its
configured reference and reconstructs the result. The current fitted
RTC graph instead binds the measured chopped image at its calibration
flat as the target.

An artifact-only check applied each fitted reconstructor to its bound
reference vector. In the 10-coordinate instrument bundle, the norm of
`R * reference` was 7.63 × 10⁻⁹ in the calibrated modal coordinates.
In the experimental 66-coordinate bundle it was 3.31 × 10⁻⁸. This is
the modal offset introduced at the respective calibration flat by
changing just the reference from its bound image to zero. A live
test of the earlier zero-reference convention needs its matched
measurement and response.

The proposed gain sweep at the supplied DM shape was stopped before
starting a private core. It produced no gain measurements or images.

## Result

Closing SCC removed most of the persistent error in the controller's active
modes. It increased the fluctuations around that mean, and the increase
in fluctuation power outweighed the removed mean-error power on both seeds.
The overall chopped-pixel RMS and the active-modal RMS both rose. The
unfringed dark hole also brightened by about 0.4%.

| Closed relative to biased open | Seed 17 | Seed 73 |
| --- | ---: | ---: |
| Mean unfringed contrast | +0.4240% | +0.4466% |
| Full chopped pixel RMS | +0.4665% | +0.1212% |
| Projected chopped RMS | +1.1320% | +0.1221% |
| Norm of the time-averaged projected error | −75.5907% | −87.6607% |
| Active modal RMS | +2.1234% | +1.5198% |
| Norm of the time-averaged active modal error | −95.5160% | −94.9825% |
| Active modal temporal standard deviation | +2.9754% | +2.2202% |

The active modal mean norm fell and the active modal RMS, full pixel RMS,
and unfringed intensity rose in each of the eight late blocks. The
integrator tracks the calibrated chopped difference through the
reconstructor. Near-zero average modal error is compatible with both
larger frame-to-frame error and brighter unfringed images, because the
feedback signal contains the difference of the two optical phases.
The contrast metric measures just the unfringed phase. These runs show
the tradeoff at the tested bias and gain. They do not separate possible
contributions from control delay, the gain, or the response of individual
optical modes. [Numeric results and block checks](comparison.txt)

Seed 17 retained 2,037 same-sequence camera and residual observations, and
seed 73 retained 2,036, out of 2,048 available in each late window. The
biased-open camera means agree bit for bit with the preceding experiment
on every shared sequence. The closed per-frame spatial means differ from
their previous values by 1.86 × 10⁻⁸ and 1.58 × 10⁻⁸ e⁻/pixel RMS,
respectively. The previous mean increases were 0.4213% and 0.4435%.
The inputs and Manifest hashes match the previous TSVD applications.

The closed mean normalized contrast was approximately 1.10 × 10⁻⁵ on both
seeds. The [dark-hole image](dark-hole.png) shows 1,022 and 1,019 matched
unfringed frames per epoch, respectively. The red areas in the difference
panels brightened and the blue areas darkened. The average over the
outlined mask rose by 0.423% and 0.445%. This image-only comparison uses
all shared camera pairs.

The two standalone simulator PIDs were observed on the RTX 3080.
Both sessions reached Running, adopted the requested SCC closure
generation, acknowledged native Quit, and removed their private
PipeWire sockets. The first attempts reached Ready and shut down after
a clock-import error in the observer, before any exposures were saved.
The evidence below uses the completed reruns.
[Seed 17 receipt](17/transport.json) · [Seed 73 receipt](73/transport.json)

## Measurements

The observer reads the SCC camera, the RTC's physical DM demand, and the
existing `selected-residuals` and `modal-residual` outputs of
`spiders-controller` via passive Links. These are the controller's live
outputs. The selected-pixel residual is the rolling fringed-minus-unfringed
pair minus the calibrated chopped reference. The modal residual is the
reconstructed vector plus its calibrated offset, immediately before the
closed-loop integrator. The bound offset is zero in this calibration.

The independent controllable projection uses an orthonormal basis for
columns 3–66 of the full-poke SCC interaction matrix. The first two
columns describe LLOWFS nuisance modes. The basis measures the component
of the chopped residual within the linearized SCC response. Modal
coordinates also reflect the reconstructor's gains and its treatment of
the nuisance columns.

Each run observes 4,096 exposures with the DM fixed at its optimized bias,
requests a native Restart, and observes 4,096 with SCC closed. Each exposure
represents 10 ms of model time. The retained window starts at exposure
2,049. The scalar comparison retains only acquisitions with the same
sequence, timestamp and phase in both epochs, with camera and both
residual outputs present. Chopped-error statistics use both phases
because the live pair rolls on every complete exposure. Contrast uses
unfringed exposures. The two epochs start from the same seed and clock.

Chopped RMS is the square root of the mean selected-pixel squared error,
pooled over the retained acquisitions. Projected chopped RMS uses the
same pixel-count normalization. Modal RMS uses the 64 active modes.
For the projected and modal errors, the analysis separates the squared
norm into the temporal mean component and the variance around that mean.
The summary also reports four 512-exposure blocks of the retained window.

The image panels average the full unfringed detector frames at the
acquisition sequences available in both epochs. The selected-pixel
mask is outlined. Both epochs use the same log contrast scale.
The difference panel displays closed minus open on a separate linear scale.
The log range is 8 × 10⁻⁷ to 1.5 × 10⁻⁴. The two difference panels
share symmetric limits from the larger of the two in-mask 98th percentiles
of absolute change. Detector coordinates use 7.86 pixels per λ/D.
The reference is the fitted model's unocculted star peak, converted to
18.27743 electrons per pixel per modeled exposure.
[Photometric inputs](../spiders-factorial-20261117/photometry.toml)

## Recalculate

Run `julia --project=<verified-application-environment> summarize.jl .`
from this directory. The per-seed directories contain matched scalars,
coordinate means, and mean camera images. The FITS reader reverses the
disk axes. Each coordinate cube stores the component index, window
(whole window followed by four blocks), and the open and closed projected
coordinates followed by the open and closed modal coordinates. Each
image cube stores biased open, SCC closed and the dark-hole mask.
