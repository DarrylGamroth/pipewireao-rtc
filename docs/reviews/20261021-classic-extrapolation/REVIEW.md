# Classic central actuator extrapolation: independent review

Started: 2026-10-21. Finalized: 2026-10-22. Reviewer: independent numerical/design review agent.

## Disposition

The selected central-completion candidate passes the reviewed numerical, structural and managed CPU integration gates. No blocking finding remains for this scope. The final sealed application passes 71/71 offline checks, including its updated documentation and preparation files. The corrected managed 256-frame run passes 2859/2859 assertions with exact controller and plant replay, accepted Quit and complete cleanup. The first attempt's evidence-capture configuration error is retained below, together with the unresolved cause of small HEART-reference regeneration differences.

This conclusion concerns finite CPU simulation and the declared provisional Gaussian mirror. It does not qualify measured hardware, physical actuator stroke, GPU execution, sustained 500 Hz cadence, worst-case latency or stability for arbitrary atmosphere and commands.

## Reviewed revisions and evidence

- Application worktree: `/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc-extrapolation`, branch `codex/classic-extrapolation-20261021`, base `934b9db3e696c9f8ac31db16f833c27bba646bd1`. Review covers the working changes, including calibration scripts, retained inputs and promoted numeric artifacts.
- RTC worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-classic-extrapolation`, base `85121d1e6ae04577713be00f65d4de9c4805815d`. `test/integration/classic_replay.jl:28` derives feedback storage from the prepared graph's input shape instead of hard-coding 221. `test/integration/classic_managed_replay.jl:218` adds preflight checks for the expected phase-timing directory and a nonnegative warmup shorter than the finite run.
- Raw evidence root: `/home/dgamroth/workspaces/codex/worktrees/classic-extrapolation-20261021` (called `raw/` below). Evidence was read independently; the reviewer did not operate services or GPUs.
- Selected calibration identity: `1837924beaf3a198726c096cfc3922d30529935be3f73974a1979169cb2962e4`.
- Original HEART reference calibration identity: `7eed4b105320799bb58b8375c55b1804f128e3c4f7f7c0b7b0886dc5cb14eb0e`.
- Final HEART reference calibration identity: `5eb5a5499d9a75532bfc0ef030714662e80c292cd3a1d495cccc5328608f5cb7`.

The reviewer independently compared all 22 FITS files in `raw/central`, `raw/central-final` and the promoted application: every file is byte-identical across all three. `Project.toml` and `Manifest.toml` equal the application base exactly. Their SHA-256 values remain `a044e19f383eca2ad56b941c1068259c6af3c97e8f655fec7253a4ab5ccb5a47` and `7a6d7b7acec8ebc9cc7573dc072456328c1ceb2efe103780264e57f03a35b371`. A parsed comparison of `simulation.conf` finds only the calibration identity changed; its default remains CUDA. Offline evidence identifies Julia 1.13.2 and RTC 0.2.1.

## Mathematical and ownership review

The original E₀ is 277 × 221. Nine directly controlled actuator centres fall inside the model obstruction radius 0.204918 in normalized pupil coordinates, on the declared 19 × 19 grid with pitch 0.125. Their one-based physical command IDs are 119, 120, 121, 138, 139, 140, 157, 158 and 159. These IDs follow the existing actuator map; no hardware registration claim is inferred.

`calibration.jl:83` builds a four-neighbour discrete Dirichlet problem. For obscured coordinates h and retained boundary commands u, the equations are Lh = Bu, where L has degree four on its diagonal and −1 for each obscured neighbour. The substitution S retains 212 direct coordinates and fills the nine others using L⁻¹B. The executed completion is E = E₀S, with shape 277 × 212. Composition preserves any dependence of the existing outer completion on the replaced coordinates.

Independent calculations found rank(E) = 212 and T E = I exactly in Float32, where T selects the retained direct physical rows. Every new central row satisfies 4Eᵢ − ΣEⱼ = 0 exactly over its four neighbours. Central weights range from 0 to 0.33035713; their row sums differ from one by at most 5.96 × 10⁻⁸. Tests exercise constant and affine figures plus random command bounds. There are 212 direct rows and 65 extrapolated rows.

These central rows are convex combinations, so they cannot exceed the boundary extrema before downstream physical offsets and clipping. This is not a property of the whole inherited completion: its minimum coefficient is −0.02304 and its maximum row-sum deviation is approximately 0.069222. Outer extrapolation can still exceed direct-coordinate extrema.

The feedback map is T, not a fitted inverse. Physical constraint feedback is requested minus demanded; the controller subtracts the projected feedback using anti-windup gain 0.99. With identity 277-coordinate physical projections and identity 212-coordinate controller maps, the sign and coordinate units are consistent. Truncation intentionally omits extrapolated-only clipping from controller feedback, matching the selected HEART convention; this does not establish a general constrained-optimal allocation.

Calibration prepares the completion before probing and recalculates the interaction matrix in that completed basis. Each probe is ±0.01 µm in one controller coordinate, converted to metres using 10⁻⁶ before plant adoption. D = (s₊ − s₋)/(2 × 0.01 µm) has units pixel/µm; the reconstructor has units µm/pixel. AOC push/pull ordering agrees with the capture rows, and FGA's interleaved X/Y slope order agrees with the recorded measurements. The calibration uses the 480-sample pupil, noiseless detector rounded to UInt16, flat reference slopes, measured flat validity, and unchanged thresholds 20/1000. TSVD relative cutoff 0.02 retains 208 modes for the selected 376 × 212 interaction matrix; 184 subapertures are active.

The gain −0.3, pole 0.99 and anti-windup gain 0.99 remain unchanged. Both sides of the wire conversion specify OPD, so there is no additional factor of two for mirror displacement. The ±0.8 µm clipping bounds are explicit software model settings; no normalized ALPAO-command-to-OPD conversion or measured stroke is available. Preparation is cold application code, and the runtime receives sealed numeric arrays through the existing ownership boundaries. The replay storage change respects the prepared graph contract and avoids a second independent coordinate count.

## CPU validation observed

RMS means the mean of per-frame piston-removed pupil OPD RMS over frames 129 through the end, in nm. Clipping counts actuator samples over the entire run, including startup, rather than counting distinct actuators or frames. These definitions were checked in `validate-calibration.jl` and against the raw JSON values.

| 512-frame case | Baseline RMS / clips | Original HEART reference RMS / clips | Selected central RMS / clips |
| --- | ---: | ---: | ---: |
| Seed 1, r₀ = 0.15 m | 51.911920 / 453 | 51.450833 / 0 | 50.517938 / 0 |
| Seed 2, r₀ = 0.15 m | 50.376074 / 461 | 49.396633 / 0 | 48.631807 / 0 |
| Seed 3, r₀ = 0.12 m | 63.892077 / 528 | 63.557685 / 0 | 62.667943 / 0 |

Baseline central clipping accounts for 451, 461 and 516 actuator samples respectively. The selected candidate has no clipping in all three cases. The 2048-frame seed-1 run also has zero clipping, mean RMS 50.260560 nm and maximum command magnitude 0.5915242 µm. These finite comparisons show improvement for the tested conditions; they are not a universal stability or performance proof.

The regenerated final HEART reference was separately validated for seed 1: 51.304542 nm and zero clipping. Seed-2 and seed-3 HEART results in the table belong to the original reference calibration identity, not the final one. Evidence: `raw/*-512-seed*.json`, `raw/central-2048-seed1.json`, `raw/validate-matrix.log` and `raw/validate-heart-final.log`.

The final managed CPU run observed all 256 distinct sequences in detector, demanded and applied streams. `raw/managed-final/science-result.json` records exact controller replay and exact plant detector replay, and mean corrected RMS 49.975397 nm versus matched uncorrected RMS 281.046099 nm after discarding 128 frames. Its calibration identity is the selected `1837924…` identity. The model rate is 500 Hz, with requested wall pacing 2 Hz; this is a functional integration result, not a cadence measurement. The reviewer independently verified every application, harness and payload hash recorded in that receipt. Both captured physical-command arrays contain 70912 Float32 values (277 × 256); their maximum magnitude is 0.458374918 µm, below the software bound. This bound check alone is not a count of pre-clipping residuals; the separate numerical runs above provide the no-clipping evidence.

The subsequent captured-frame controller check (`raw/postcapture-check.log`, 516/516 assertions; `raw/managed-final/command-check.json`) verifies zero physical constraint-feedback values over all 256 frames, including the nine central actuators. Their correction roles are all 2 (extrapolated), their commands are nonzero, and their maximum magnitude is 0.12684967 µm. This explicitly distinguishes central extrapolation from zeroing and checks the residual before drawing a no-clipping conclusion.

`raw/completion-final-tests.log` records 54 central-completion assertions and 6 archived-HEART assertions passing. The initial offline run passed 64/64 assertions. After resealing documentation and preparation files, `raw/offline-final.log` records 71/71 passing; `raw/offline-final/offline-check.json` explicitly reports no simulator or services started and no GPU modules/libraries loaded. The reviewer independently hashed every one of its 44 declared artifacts against the current application and found no mismatch. Numerical result JSON files independently report no GPU modules or runtime loaded. The final `raw/managed-final/gpu-audit.json` has empty GPU mappings for all five observed owners. `raw/managed-final.log` records 2859/2859 passing assertions; `raw/preflight-regression.log` records 2/2 passing preflight regressions. `raw/semantic-diff.log` shows only the intended 221 → 212 coordinate extents and calibration identity changes across graph, session, parameters, simulator configuration and operator profile; gains, pole, bounds and default CUDA configuration are preserved.

## Findings and dispositions

### CE-001 — Weakly sensed independent central coordinates saturate in the baseline

Severity: medium for this simulator application. Confidence: high in the observed saturation and its removal; the complete causal contribution of conditioning versus other model effects was not separately identified. Evidence: the baseline and central same-seed JSON comparisons above; affected preparation: `calibration.jl:83` and `calibrate.jl:20` onward.

Disposition: addressed by replacing the nine independent obscured coordinates with harmonic completion and recalibrating the full response. Fail-before/pass-after evidence is available in all three finite cases and the selected long run. Required retained validation is the completion invariants, bounded finite closed-loop comparisons and managed transport/replay gate. Holding central commands at zero was an earlier diagnostic and is not this implementation.

### CE-002 — Archived HEART completion has an asymmetric direct-feedback basis

Severity: low for a labelled comparison reference; material if silently promoted to an assumed identity allocation. Confidence: high. Evidence: hash-verified legacy input and independent matrix examination. The 277 × 277 archive has 214 nonzero input columns and rank 214 after removing zero columns, but only 213 exact direct rows. Physical input 264 has no direct-feedback row; the corresponding retained-coordinate feedback row 210 is zero.

Disposition: accepted reference limitation, preserved without repair. The archive is not the selected production matrix. `heart_completion` explicitly constructs exact-unit-row truncation. The currently inspected HEART loader accepts another format, so the archived file does not prove the matrix loaded by an unspecified historical runtime. Required validation is the retained archive hash and regression assertions; both are present.

### CE-003 — Repeated HEART preparation is not bitwise reproducible

Severity: low for the selected central candidate; material to exact reference attribution. Confidence: high in the numeric differences; root cause remains a hypothesis. Evidence: independent comparison of `raw/heart/artifacts` and `raw/heart-final/artifacts`.

| Product | Differing entries | Maximum absolute difference | Relative norm difference |
| --- | ---: | ---: | ---: |
| Push/pull response | 4 / 160928 | 0.000910567 pixel | 0.00108941 |
| Interaction matrix | 4 / 80464 | 0.0455284 pixel/µm | 0.000770434 |
| Reconstructor | 80464 / 80464 | 0.00751430 µm/pixel | 0.00801537 |
| Singular values | 211 / 214 | 0.00124931 | 0.0000507980 |

The affected responses are actuator 151 positive at subaperture 9 and actuator 226 negative at subaperture 47. Both retain 211 TSVD modes. All other parameter arrays and the completion are identical. Installed Shack–Hartmann preparation uses `plan_repeated_fft_backend!`, which selects `FFTW.MEASURE`; varying FFT roundoff crossing UInt16 rounding boundaries is plausible, but neither this mechanism nor a particular threshold crossing has been demonstrated by the retained response products.

Disposition: retain both reference calibrations and their distinct hashes; attribute each run to the exact artifact used. The final reference received an additional seed-1 validation. No speculative production change was made. All 22 selected central FITS files reproduce exactly in the observed regeneration. If strict reference reproducibility later becomes a requirement, the discriminating experiment is to retain FFT plan descriptions and pre/post-quantization affected frames from fresh preparations. That investigation is deferred, not presented as a confirmed root cause.

### CE-004 — Final managed integration and publication binding

Severity: low test-harness configuration defect, resolved. Confidence: high in the first failure mechanism and completed corrected-run evidence.

The first run, preserved in `raw/managed.log` and `raw/managed/`, ended with 16 passing assertions and one error while copying the absent `phase-timing-1.json`. Its `observation.json` records all 256 distinct sequences for detector, demanded and applied streams; Stop returned Ready, Quit was accepted, and `final-launch.json` reports `service_result = success` and `cleanup_complete = true`. The test did not reach the later scientific replay assertions, so the failed run must not be counted as a complete managed pass.

The copied application requested a phase-timing warmup of 512 frames for a finite 256-frame run. The timing recorder excludes warmup frames and its save path writes nothing when no samples were recorded. The absent file therefore follows from the evidence configuration; the available observations do not indicate a plant or RTC execution failure. The corrected `raw/cpu-application-final` has one instance of each timing option, capacity 256, warmup 128, and CPU wall pacing 2 Hz. This is a test-only variant of the application; the saved default CUDA deployment remains unchanged. The reviewed preflight catches the first run's impossible warmup and wrong/missing timing directory before admission. Its use of the first option occurrence is adequate for this inspected variant, whose flags are unique; it is not a general duplicate-argument validator.

Disposition: **closed** for the reviewed CPU integration and publication-binding gates. The corrected run passes 2859/2859 assertions and the preflight regressions pass 2/2. The reviewer inspected `raw/managed-final/science-result.json`, `observation.json`, `gpu-audit.json`, `shutdown-attempt.json` and `final-launch.json`: all 256 sequences were captured in each stream; controller and plant replay were exact; the selected calibration identity and CPU configuration are recorded; Quit was accepted; service result is success and cleanup is complete. All application, harness and captured-payload hashes in the final scientific receipt match the retained files. All 44 final offline artifact hashes also match and 71/71 offline assertions passed. The initial failed run remains preserved. No hardware, GPU, latency or sustained-cadence qualification is implied.

### CE-005 — Live applied-command comparison must include the Float32 unit roundtrip

Severity: low diagnostic assertion error, resolved; no production defect identified. Confidence: high, supported by released HIL source and independent binary inspection.

After local application promotion to `b0637ac`, the bounded live check uses evidence under `/home/dgamroth/.local/state/pipewireao/classic-cpu-extrapolation-live-20261022`. The first checker incorrectly required raw demanded and applied wire values to be bitwise identical; its script and failed log remain as `check-live-first.jl` and `check-live-first.log`. HIL 0.2.2 (`AdaptiveOpticsSimPipeWireHIL`, tree `b86b36d35bf428be1f9b5bbf98eaf288302d2789`) multiplies incoming wire commands by the Float32 scale in `src/exchange.jl:465`, then divides the adopted plant values by that scale for optional applied observations in `src/applied_command.jl:50`. Thus the exact expected wire observation is Float32(Float32(demand × 10⁻⁶) / 10⁻⁶), which need not equal the original Float32 demand.

The corrected read-only checker matches demanded and applied products by sequence and uses that exact roundtrip. Independent inspection of the saved 60 × 277 command arrays found 501 values unequal to raw demand, with maximum difference 1.4901161 × 10⁻⁸ µm; all 16620 values match the expected Float32 roundtrip exactly. `live-command-check.json` reports 60 matching sequences (20211–20270), selected calibration identity `1837924…`, zero physical constraint feedback, nonzero central commands and all nine central roles extrapolated. Demand peaks at 0.42954344 µm, with central peak 0.10403183 µm; offsets are zero. `live-gpu-audit.json` reports no GPU runtime mappings or GPU device handles in the RTC, simulator, controller, parameter owner, core or connected GUI.

Disposition: closed by correcting the diagnostic expectation, with no production change. The live CPU/GUI snapshot supports the selected behavior during the observed interval; it does not establish future no-clipping behavior, sustained cadence, GPU operation or hardware qualification. The review agent inspected saved evidence only and did not operate the live services.
