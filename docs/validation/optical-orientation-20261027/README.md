# Optical diagnostic orientation — 2026-10-27

The RTC 0.2.28 patch corrects the optional simulator wavefront and focal-plane
images. AOS reports increasing physical `[x,y]`; GUI images use `[row,column]`
with rows increasing down. Direct copying swapped physical axes on screen.
The publication boundary now transposes and reverses physical y so +x is right
and +y is up, matching owner-published DM positions.

Scientific arrays, camera frames, command vectors, calibration FITS, gains,
limits and raw-pupil RMS remain unchanged. The conversion uses preallocated
host products in the optional diagnostic worker, outside controller processing.
No instrument-specific renderer or GUI orientation override was added.

## Validation

Source fix `069da605` starts from RTC `8c6f1f0` (0.2.26). The
[versions](remediation-versions.json) and [commands](remediation-commands.json)
record exact scientific and transport sources.

- The same actual AOS 0.3.2 / HIL 0.2.7 isolated-actuator export probe fails
  8 of 20 assertions [before](actuator-fail-before.log) and passes all
  20 [after](actuator-pass-after.log). Physical +y now moves up and +x right.
- [Bounds-checked focused tests](pass-after.log) pass 39 assertions covering
  rectangular asymmetric arrays/masks, offset and strided views, source/RMS
  preservation, alias rejection and zero warmed allocation for both conversions.
- [Small SH/Pyramid prepared-owner checks](cpu-products.log) pass 80 assertions,
  including actual product formation and raw scientific-output preservation.
- Actual AOS focal metadata declares `PlaneAxisOrientation((:x,:y),(1,1))`;
  one-pixel source displacements validate the focal mapping independently.

The managed Classic transport/replay oracle was updated and syntax checked;
its complete live/private-core replay was not rerun. These are CPU software
checks, not hardware, fixed-rate latency or complete-system qualification.

## Deployment

The initial rollout ran registered RTC 0.2.29 / FGA 0.8.5 / FGPW 0.1.11 on the CUDA plant.
The registered consumer passes all 39 presentation assertions. Installed and GUI
checks are recorded in the [combined deployment](../gpi2-supervision-20261027/README.md#combined-deployment-checks).

## Atmosphere wind-axis inconsistency

The operator then observed raw pyramid features moving right while DM and
residual features moved up. Registered AOS 0.3.2 configures one ground layer at
10 m/s and 0°. Its atmospheric extraction interprets index 1 as y and index 2 as
x, on both CPU and CUDA. Gaussian DM coordinates, pyramid mask coordinates and
the RTC tip/tilt basis instead interpret index 1 as x and index 2 as y. Thus the
configured positive wind-x motion advances native index 2, physically +y in the
other optical owners. Raw camera row/column rendering shows it toward the right;
the physical DM and corrected diagnostic mapping show it upward. No additional
wire transpose is present. These are the same evolving field, not independently
rotated atmospheric realizations.

The disconnected [asymmetric marker probe](atmosphere_axes.jl) passes three
assertions against registered AOS ([output](atmosphere-axis-probe.log)):
baseline peak `(4,5)`, +offset_x peak `(4,6)`, +offset_y peak `(5,5)`.
An independent source inspection confirms the same CPU/CUDA convention and the
existing atmosphere test's column-shift expectation. No scientific source or
live wind setting was changed. Correcting atmospheric axes requires coordinated
CPU/CUDA and finite/infinite-screen, source-footprint and directional-regression
checks; rotating a GUI view would conceal the inconsistent convention.

## AOS atmosphere correction and package update

AOS 0.3.3 (`7c710381`, registered tree
`4c22c7e8005a8782bdf511a5cd25f8e4bd24b7a0`) corrects finite/infinite
atmospheric sampling and source footprints to the native physical `[x,y]`
convention. It does not rotate raw camera frames or command vectors. The AOS
repository records the CPU scalar/KernelAbstractions, CUDA and AMDGPU axis
checks, regression evidence and reference-snapshot disposition in
`benchmarks/results/platform/2026-10-27-atmosphere-axes.toml`.

The registered consumer passes 51 CUDA axis assertions with scalar indexing
disabled. The calibrated 128-frame noisy GPI CUDA test passes all four assertions
with AOS 0.3.3, FGA 0.8.6 and FGPW 0.1.12. It uses UInt16 detector frames and the
existing calibration. Initial residual RMS is 1.32948e-6 m OPD; final RMS is
5.68744e-8 m OPD and trailing corrected/uncorrected RMS ratio is 0.0437362.
This exactly matches the AOS 0.3.3 check with FGA 0.8.5 / FGPW 0.1.11. The new
FGPW row-major calibration optimization remains opt-in and was not enabled.

Both the GPI export and Classic CPU export succeed. All 36 selected GPI graph,
parameter, view, supervision and calibration files remain byte-identical to the
previous deployment; the calibration context is semantically unchanged.
Instrument main `c4bf801` updates the GPI package pins; Classic's AOS pin was
updated in `9e6dde5` without otherwise changing its older package cohort.
The instrument repository remains local as requested.

The [cohort](final-cohort.json), [numerical report](gpi-jfg-cuda.yaml),
[run log](gpi-jfg-cuda.log), [export results](build-jfg.log) and
[unchanged-file comparison](scientific-file-comparison-jfg.json) are retained here.
Full logs, manifests and additional comparison receipts are retained in
`/home/dgamroth/.cache/pipewireao/atmosphere-axes-20261027/`. The finite numerical
check and cold exports do not establish connected latency, long-duration
stability or physical-hardware behavior.
