# Classic extrapolation validation evidence

This directory preserves compact reports and logs for the 2026-10-21 Classic
CPU extrapolation comparison. The JSON results are full per-frame outputs and
record 512-frame runs at pupil resolution 480, with 128 frames discarded as
warm-up. `mean_rms_nm_after128` is the reported mean over the retained frames.

| Case | Seed | r₀ (m) | Mean residual RMS (nm) | Clipped actuator samples | Max command (µm) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline | 1 | 0.15 | 51.912 | 453 | 0.800 |
| Baseline | 2 | 0.15 | 50.376 | 461 | 0.800 |
| Baseline | 3 | 0.12 | 63.892 | 528 | 0.800 |
| HEART reference | 1 | 0.15 | 51.451 | 0 | 0.556 |
| HEART reference | 2 | 0.15 | 49.397 | 0 | 0.524 |
| HEART reference | 3 | 0.12 | 63.558 | 0 | 0.724 |
| Central completion | 1 | 0.15 | 50.518 | 0 | 0.515 |
| Central completion | 2 | 0.15 | 48.632 | 0 | 0.456 |
| Central completion | 3 | 0.12 | 62.668 | 0 | 0.685 |

The central completion also has a 2,048-frame seed-1 run in
`results/central-2048-seed1.json`: 50.261 nm mean RMS, zero clipped actuator
samples, and 0.592 µm maximum command. A separate final HEART calibration
seed-1 run is preserved as `results/heart-final-512-seed1.json` (51.305 nm,
zero clipped actuator samples).

The baseline files identify the deployed starting calibration as
`ff09bfd…`. Retained calibration reports identify HEART comparison data as the archived
`revolt-on-sky@31a86a7/config/ExtrapolatorVegaTT.csv` (SHA-256
`ec6b38669279fa0f7bfdd75a356dfb5a2c5b5b41e37c2501ec6723df097525cc`), and
the inherited outer completion as the prior Classic 277×221 map from
`934b9db` (SHA-256
`35be859539f498abc8f7c9760b55aea1de1d553e4f37246532bca7f055d9e02e`). The
central model removes nine directly controlled coordinates in the obscured
centre, fills them by a four-neighbour discrete harmonic extension, then
composes that extension with the inherited outer completion to form a 277×212
active-to-full map. The corresponding full-to-active feedback map directly
selects those 212 coordinates. The final calibration results and provenance
are kept under `calibration/central-final/` and `calibration/heart-final/`;
the first HEART calibration result is retained separately under
`calibration/heart-initial/`.

Command values are unit-peak actuator surface-OPD coefficients in µm, converted
to plant metres with `1e-6`; completion maps are dimensionless. The configured
±0.8 µm limit is a software simulation bound. No measured conversion from
normalized ALPAO command to surface OPD, physical stroke, or voltage is
available. These results are finite seeded CPU simulations and do not establish
hardware performance or physical stroke.

The initial managed replay failed while collecting the phase-timing report:
the 512-frame timing warmup exceeded its 256-frame run, so no timing file was
written. The expected file was absent after 16 test assertions passed. Its log and
available session receipts are preserved under `managed/first-attempt/`. The
later managed CPU replay passed 2,859 of 2,859 checks and completed 256
observations on each stream, with corrected mean RMS 49.975 nm and uncorrected
mean RMS 281.046 nm. Its receipt reports exact controller and plant-detector
replay, completed cleanup, and a CPU backend;
the accompanying GPU audit lists no GPU mappings for the captured processes.
The observed state/stop receipts report a ready state and completed stop.
This is finite replay evidence, not cadence, latency, long-run stability,
hardware, or GPU qualification. Details are in `managed/final/`.

A further 516-assertion replay of those captured frames checks physical
pre-clipping residuals: zero nonzero samples across all 277 actuators and
all 256 frames. The central commands are nonzero, all nine carry the existing
extrapolated correction-role value 2, and the peak physical command is
0.458375 µm. See `managed/final/command-check.json` and
`managed/final/postcapture-check.log`.

The independent [review](../../reviews/20261021-classic-extrapolation/REVIEW.md)
records the archived HEART matrix's asymmetric direct-feedback basis and small
reference-regeneration differences. All 22 selected central FITS products were
byte-identical in the observed regeneration. The cause of the HEART reference
differences remains unproved; each result retains its actual calibration hash.

`completion-final-tests.log`, `offline-final.log`,
`offline-check.json`, and `preflight-regression.log` preserve the supporting
software checks. No binary command/frame arrays or FITS artifacts are included
in this evidence bundle.

## Live CPU deployment — 2026-10-22

The application is integrated into its normal checkout on local `main` at
`b0637ac3e61e339dfc1fed8bbd3600c83a69bcff`. The previous CPU session accepted
Quit and completed exact cleanup. A fresh, separately sealed CPU application
uses the selected `1837924…` calibration, continuous operation and requested
10 Hz wall pacing; its numerical model period remains 2 ms. The canonical
application retains its CUDA default. The installed native RTC and released
Julia dependencies are unchanged.

The live unit is `pipewireao-session@b16ca74284a4.service`; the software-rendered
GUI is `pipewireao-classic-cpu-extrapolation-gui-20261022.service`. Native status
reports Running. `live/live-command-check.json` records 60 samples per product,
sequences 20211–20270, all nine central correction roles equal to 2
(extrapolated), nonzero central commands, zero physical clipping feedback and
zero offsets. Peak demanded/applied magnitude is 0.42954344 µm; the central
peak is 0.10403183 µm. All 60 sequence-matched demanded/applied pairs agree
exactly after the declared Float32 µm → m → µm conversion. Four GUI observation
nodes were discovered on this session. The GPU audit finds no GPU runtime
mappings or GPU device handles in the six selected owner/RTC/GUI processes.
This is a sampled live check, not a claim about every exchange or future state.

Two one-off diagnostic failures are preserved. The first cutover script used
the wrong handle field after successfully shutting down the old session;
the continuation verified complete cleanup before starting the new one. The
first live command comparison incorrectly required equality without unit
conversion. The independently checked saved arrays differ by at most
1.49 × 10⁻⁸ µm under that comparison; all values match the specified conversion
exactly. Neither correction changed production runtime or scientific settings.
The scripts and logs under `live/` retain these failures and the successful
continuation. The session and GUI are deliberately left running on the CPU.
