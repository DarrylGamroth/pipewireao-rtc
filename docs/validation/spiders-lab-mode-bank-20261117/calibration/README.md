# Transferring the lab modes

The first 112 SCC modes come from the [preceding bank](../../spiders-fringe-banks-20261117/calibration/README.md).
The added 32 modes come from 16 recorded quadrature pairs in the SPIDERS
`fourier-modes-to-actus.fits` bank. Its four HDUs give 650 native command
vectors on the 468-actuator mirror, the two grid-frequency coordinates and
the phase. For each new pair both phase rows have nonzero archived iFTS
response in the fringe band. [Selection and FITS row numbers](lab-bank-selection.json) ·
[Archived camera response checks](lab-measurement-check.json)

The two BAX307 actuator maps agree exactly. Fitting the simulator's
normalized DM coordinates to the lab grid identifies the axis order,
orientation and pitch. For a lab grid frequency vector k and coordinate
map i = Aᵀp + b, the model recipe frequency is Ak/24. Its nominal focal
separation is 2‖Ak/24‖ in λ/D. We used that mapping to select the rows and
copied the command samples themselves to preserve phase.

We chose one phase pair per azimuth sector (eight sectors modulo π) in
each of two annuli, 9–10.5 and 10.5–12 λ/D. Within each cell we selected
the pair whose least independent direction added the most to the existing
command span. This choice used actuator geometry only. The 16 selected
separations span 9.072–11.735 λ/D. The selected inputs on the model's
334 directly controlled actuators are peak-scaled lab command samples.
The model supplies the remaining 134 actuator commands through its usual
completion matrix, nulls LLOWFS in the SCC calibration and normalizes the
probes. Completion alone changes the full vectors by relative L² norms
of 0.65–1.24. [Direct command samples](lab-direct-projection.fits) ·
[Command and measurement overlap with 112 modes](bank-overlap.json)

CUDA calibration used full and half push/pull amplitudes of 5 and 2.5 nm
on the ordinary flat. The 112 SCC columns and the active centroid-to-DM
map reproduced exactly. The shared projection of actuator constraint
feedback into LLOWFS changed by 15.44% in relative Frobenius norm. The
fitted iFTS band with no spot masks retained all 144 SCC directions. Hard
spot masks would retain 136. The Tikhonov scale was 62,516 electrons/m
versus 71,173 for 112 modes under the same smallest-retained-singular-value
rule. The full- and half-poke linearized spectral radii at gain −0.05 were
0.977201 and 0.977204. A single SCC correction on the static CUDA flat
lowered the unfringed mean by 4.255%. [Conditioning](acquisition-conditioning.json) ·
[First step](first-step.json)

## Replay

Use the 112-mode experiment directory, normal-flat calibration input,
lab bank and map, and the earlier CUDA environment. Keep the original
application and lab assets read-only.

1. Run `select-bank.jl WIDE112 LAB_BANK LAB_MAP INPUT OUTPUT` in that
   environment. It writes the [optical recipe](optical-dark-hole.yaml)
   into the copy of the input and writes the projection and selection
   record to OUTPUT. Set the copy's joint controller command count to 146.
2. Copy the shared instrument optical tools at
   `58ecd8ac842a789c8df06586a2875273b0b80042`. Apply
   `patch -p1 < lab-transfer.patch` in the copied optical_calibration
   directory. This raises its frequency limit to 72 pairs and passes the
   lab projection through the existing actuator calibration. Run
   `calibrate.jl MODULE INPUT OUTPUT`. [Calibration report](calibration.json)
3. Take the 112-mode `push-pull.jl` and `reconstruct.jl` (after applying
   the preceding bank's `wide-replay.patch`), apply `144-replay.patch` and
   run `push-pull.jl MODULE INPUT OUTPUT/calibration/scc/artifacts DERIVED`.
   All 292 full-frame derivative columns reproduce the archived selected
   pixels exactly. Stage with the preceding bank's `stage.jl`, substituting
   the wide recipe, filtered assets and joint command count. Run
   `check-bank.jl WIDE112 OUTPUT` to check the staged source.
4. To independently check the lab image rows, run `check-lab-response.jl
   lab-bank-selection.json DIFFERENTIAL_RESPONSE_FITS MASK_FITS RESULT_JSON`
   with the archived iFTS differential images and overall mask.

[Input hashes](inputs.sha256) · [Product hashes](outputs.sha256)
