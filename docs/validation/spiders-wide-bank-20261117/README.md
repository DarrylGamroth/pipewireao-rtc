# SPIDERS 64-mode and wider-bank contrast comparison

The [earlier 64-mode run](../spiders-closed-loop-20261117/README.md)
compared SCC feedback with the same optimized static DM bias in both epochs.
The integrator tracks the chopped fringed-minus-unfringed signature measured
at that bias. Its objective is the residual relative to that reference.
Mean unfringed intensity measures a different quantity. Over the earlier
20-frame window, with gain −0.05 and unit pole, the peak physical command
deviation from the bias was 0.001168 native units. The static bias had
already reduced the unfringed mean by 28.09% versus zero bias on that
trajectory. These facts establish the operating point and the small measured
feedback excursion. The earlier experiment alone cannot quantify how much
the mode count limited correction.

## Reconstructors

The control arm uses the previously accepted 64-mode SCC TSVD calibration
around the optimized bias, with two separate LLOWFS tip/tilt modes. The wider
arm retains those 32 Fourier frequency pairs and adds 24 pairs at 5, 7 and
9 cycles per pupil diameter, with angular directions between those of the
original rings. It fits 112 SCC directions and the same two nuisance
tip/tilt directions. Both arms use the same measured BAX307 influence
functions and active-to-physical completion, 4–13 λ/D mask, 5 nm full poke
and 2.5 nm half poke, chopped reference measurement, actuator limits,
system flat, integrator gain and pole. LLOWFS stays open during measurement.

The legacy `sccservice/scripts/generate-scc-im.jl` forms the inverse from
`S_reg = (S² + S[100]²) / S`. Its executed inverse damps the full spectrum.
This comparison reuses that regularization with the fitted current SCC
measurement matrix. It retains the current camera mask and measurement
frontend. The SVD includes the two nuisance columns. Only the 112 SCC
rows can contribute to the SCC correction. The fitted interaction matrix
retained rank 114 and reached condition number 67.93. The legacy scale
`λ = σ₁₀₀` was 253461.4 in the measured matrix units. The normalized
mode-recovery error of the regularized inverse was 0.2721, which measures
the shrinkage imposed by damping. The separate measured interaction and
TSVD diagnostics passed the existing calibration gates before replacing
the experimental inverse. This comparison changes both the frequency bank
and the inverse, so it evaluates the combined controller change.

[Wider recipe](optical-wide.yaml) · [Interaction calibration receipt](calibration.json) ·
[Regularization spectrum](legacy-regularization.json)

## Private-core experiment

The fitted-dual RTC and standalone HIL simulator use independent facility
residual RNG seeds 17 and 73. The earlier experiment used seed 1. Every
arm uses the same seed-specific source graph with the same atmosphere
strength and model timestep. The alternate source graphs are generated
from the authored simulator source with the seed replaced. The static
calibration uses the same optical prescription about the same F/U and
centroid references. Scene comparisons pair model sequence, model time and
SCC phase. The planned window is sequences 5–16 after omitting the first four
startup exposures. Each seed and arm runs the same biased-open and
SCC-closed procedure, with a native Restart between epochs on its private
PipeWire core.

The scientific outcome is mean intensity over the frozen 12,703-pixel
dark-hole region at the same modeled flux and exposure. Ratios therefore
measure relative contrast. This is a software simulation comparison on
deterministic held-out trajectories.

All four sessions reached Running, acknowledged SCC Close with matching
requested and active generations, and acknowledged native Quit. All private
core sockets were removed and all owners exited. For each seed, the two
open-loop traces matched exactly at all 16 model samples. Each row below
uses six paired samples per phase, per arm.

| Seed | SCC phase | 64 TSVD, close vs open | 112 legacy, close vs open | 112 closed vs 64 closed |
| --- | --- | ---: | ---: | ---: |
| 17 | Unfringed | −0.2503% | −0.4093% | −0.1594% |
| 73 | Unfringed | −0.2392% | +0.0133% | +0.2531% |
| 17 | Fringed | −0.1539% | −0.1502% | +0.0037% |
| 73 | Fringed | +0.2141% | +0.2199% | +0.0058% |

The wider regularized controller reduced unfringed intensity relative to 64
modes on one seed and increased it on the other. Neither arm changed the
mean unfringed intensity by as much as half a percent in these held-out
windows. Peak feedback excursions were 0.00147 and 0.00124 native units
for 64 modes and 0.00124 and 0.00125 for 112 modes, by seed. The test
covers the first 160 ms of modeled exposure time with detector noise off.
It provides evidence about early closed-loop contrast at the tested gain.
Steady-state contrast and the individual effects of bank width and
regularization remain open.

The application used Julia 1.13.3, RTC 0.7.23 with the recovery patch
`7222557`, HIL 0.5.9, AOS 0.3.26, AOC 0.17.4, FilterGraphPipeWire
0.5.6 and PipeWireAO JLL 4.0.4+0. The four application Manifests
matched byte for byte. [Controller hashes](controller-inputs.sha256)
show that the SCC flat difference and mask were identical across the
two arms. [Source hashes](trajectories.sha256) matched within each seed.
[Source generator](trajectory.jl)

From the evidence directory, recalculate the paired means and ratios.

```sh
julia --startup-file=no compare.jl 64-17.csv 112-17.csv
julia --startup-file=no compare.jl 64-73.csv 112-73.csv
```
