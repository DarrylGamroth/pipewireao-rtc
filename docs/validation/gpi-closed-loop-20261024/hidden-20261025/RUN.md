# GPI2 weighted discarded-direction hidden-removal diagnostic

Scope: private scientific arrays only. No native PipeWire core, native session, controls, production repository edits or deployment changes. Actual installed GPI2 application, calibration artifacts, registered packages and production source prescription are used. R, J, science gains, pole, antiwindup, limits, detector noise, atmosphere and backend are unchanged.

Commands (same wrapper and registered environment):

```sh
WRAPPER=/home/dgamroth/.cache/pipewireao/gpi2-registered-20261025/with-env.sh
ENVIRONMENT=/home/dgamroth/.cache/pipewireao/gpi2-registered-20261025/environment
SCRATCH=/home/dgamroth/.cache/pipewireao/gpi2-hidden-20261025
"$WRAPPER" julia --startup-file=no --project="$ENVIRONMENT" "$SCRATCH/static-basis.jl" > "$SCRATCH/static-basis.log" 2>&1
"$WRAPPER" julia --startup-file=no --project="$ENVIRONMENT" "$SCRATCH/replay-hidden.jl" cuda > "$SCRATCH/replay-hidden.log" 2>&1
python3 "$SCRATCH/summarize.py"
```

The wrapper sets Julia/BLAS threads to one. A single CUDA plant is reset between matched runs. Native live workloads elsewhere on the host remain untouched, so replay wall time is diagnostic execution cost, not an isolated performance benchmark.

AOC public `corrector_singular_vectors` supplies Vd from Jw = J W, W = diag(1 / mode_rms). The 64 weakest directions are explicitly experimental removal candidates; all have nonzero singular values. H = Vdᵀ W⁻¹; B = W Vd. Static diagnostics compare BH with I − RJ and record inverse, idempotence, weighted symmetry, threshold and calibration reproduction errors. The original R is never replaced. Norms of controller coordinates (including column-RMS-scaled coordinates) are not physical optical RMS.

The original graph's `closed-loop-integrator-f32` node is replaced only in a private configuration by `closed-loop-correction-f32`, with projection parameter ports and hidden-mode-count64. Shared graph outputs observe correction, feedback-corrected state and residual error. The actual JFG algorithm removes hidden content of the commanded-realized shape: realized = preceding correction − delayed constraint feedback; candidate state = realized − hidden_gain B H realized; correction = candidate state − 0.3 residual error. This differs from the previously rejected feedback-only projection.

Before CUDA preparation, deterministic camera inputs test all outputs for bit equality between the original integrator graph and the genuine correction graph at hidden gain0. During the gain0 scientific run, the original graph processes each identical camera frame in parallel and all outputs must remain bit-identical. After reset, gain0.1 and gain1 runs must have identical full atmospheric-field SHA256 observations. Per-frame state and correction recurrences are checked separately. Clipping statistics cover every frame in512-frame windows. Optical quantities use uniform64-frame observations after the first32 frames.

`static-basis.json` and `replay-hidden-result.json` retain package/source, graph, receipt, basis and driver identities. `summary.json` adds hashes of all scratch artifacts. No result claims hardware, native-session, long-term stability, or live-deployment validation.

The first replay attempt passed the32-frame zero-gain test, then failed before optical preparation because relocated package precompile code embedded an absent original resource directory. It is preserved as `replay-hidden-setup-relocation-failure.{jl,log,json}`. The second attempt applies `resource-path-resolver.jl` only inside its process: exact copies of the three installed resource loader functions change only their package-root expression to `pkgdir(parentmodule(@__MODULE__))`. No installed package/global path changes are made. The report retains original/patched function hashes and all package YAML hashes. The original plant preparation's prescription-identity check still requires exact agreement with the frozen receipt, covering all used template/catalog hashes and resolved declarations.

After all short runs, the same process extends only the best candidate to16384frames from reset if its mean residual WFE over frames2049–4096 improves by at least2%. If both candidates are worse, no long run is performed.

Host recorded during this run: Linux6.12.113+deb13-amd64 x86_64; NVIDIA GeForce RTX3080 (10240MiB), driver615.71.10; Julia1.13.2, registered CUDA.jl6.4.2. Precise environment manifest SHA256 is in `static-basis.json`.

The second setup attempt is retained as `replay-hidden-world-age-failure.{jl,log,json}`. Installing replacement locators inside `main` left its compiled call path in an older Julia world, so it still called the old missing-resource locator after passing the zero-gain test. The final driver installs the identical resource-only methods at top level before invoking `main` and verifies source prescription identity inside `main` before preparing either controller graph. The separate `resource-preflight.json` verifies the same patched loaders from a fresh top-level call. These were setup failures before any optical simulation frames, not negative scientific results.

## Observed result and adjudication

All three genuine-JFG CUDA cases completed4096frames from reset (2.048s model time). The optical comparison window is frames2049–4096; optical values use32 uniform64-frame observations in that window. Mirror clip counts use all2048frames. All96 full atmospheric-field hashes per case match at the recorded observations. At hidden gain0, all graph outputs are bit-identical to the original integrator on every frame; all96 recorded atmosphere/WFE/mirror requested-peak/clip observations also exactly reproduce the earlier baseline. Per-frame Float32 state and correction recurrence errors are0 for all three cases.

| Quantity, frames2049–4096 | Gain0 | Gain0.1 | Gain1 |
| --- | ---: | ---: | ---: |
| Mean residual WFE (nm) | 66.3727 | 97.7691 | 148.7278 |
| Maximum sampled residual WFE (nm) | 89.2827 | 223.2757 | 366.7885 |
| Mean woofer peak preclip request (nm) | 1025.4135 | 1080.1319 | 1111.4127 |
| Maximum sampled woofer peak preclip request (nm) | 1043.7267 | 1131.2826 | 1241.9795 |
| Mean tweeter peak preclip request (nm) | 1124.1277 | 1092.7658 | 1114.5994 |
| Maximum sampled tweeter peak preclip request (nm) | 1189.2240 | 1152.5691 | 1214.0662 |
| Mean woofer clipped actuators | 11.3105 | 8.7832 | 5.5864 |
| Mean tweeter clipped actuators | 60.7495 | 38.9531 | 43.0142 |
| Mean hidden realized raw coordinate norm (nm-coordinate) | 6160.6682 | 1232.1770 | 185.1926 |
| Mean hidden state raw coordinate norm (nm-coordinate) | 6160.6682 | 1108.9593 | 0.000685 |

Observed: gain0.1 worsens mean WFE by47.303%; gain1 worsens it by124.080%. Removing hidden state and reducing mirror clipping do not establish improved optical correction. Reject enabling this tested candidate; no long extension ran. No live controller change was made.

Derived analytical comparison: for P=I−BH, Nc_prev=0 and Ne=0, full-gain realized-shape removal P(c_prev−b)+gain·e equals the earlier feedback-only update c_prev−Pb+gain·e. Those assumptions are approximate for stored finite-precision operators. The genuine gain1 mean WFE148.7278nm is1.808% above the earlier feedback-only146.0864nm in the same window; atmosphere RMS observations are identical, while residual traces differ by up to27.36nm. This supports a similar unfavorable allocation outcome without claiming trajectory identity or equivalence for nonzero initial hidden state.

Production-basis boundary: the generated exact production H/B FITS were compared independently with axes(2,1). Their projector differs from this diagnostic basis by8.7864×10⁻⁶ relative in raw coordinates and5.5014×10⁻⁶ after column-RMS weighting. `production-basis-comparison.json` retains the exact generated receipt and hashes; `production-hidden-basis.jls` is a separately named snapshot. The short runs used the diagnostic basis, so they do not qualify exact production artifacts. Neither candidate improved, and no extension or positive qualification claim was made. Weak discarded calibration directions have nonzero optical response and are not exact null modes.

Limits: this is software numerical evidence for a finite from-reset interval, not hardware/native-session validation, global stability, or proof of optimal allocation. No nonzero-initial-hidden-state removal experiment was needed to reject the tested enabling policy.
