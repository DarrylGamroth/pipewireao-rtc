# Woofer amplitude sensitivity experiment, 2026-10-26

Authorized private-array experiment: original integrator with hidden-mode gain0, changing only woofer VectorConditioningF32 command limits from±1.0e-6 to±3.4e-6 mOPD. This is a provisional-versus-HEART-reference sensitivity comparison, not measured hardware-stroke qualification. No live GUI, native core/session request, controller, or production repository mutation is authorized or performed.

Source inspection found no clipping device bound in the installed grid Gaussian DM component. Its node config has no stroke/actuator-model field; preparation constructs DeformableMirror without an actuator_model, whose default resolves to LinearStaticActuators. The scatter node copies incoming physical-actuator commands into its grid; the linear actuator model copies those commands unchanged before surface evaluation. Therefore only the private controller graph amplitude policy changes. Runtime checks will assert that actuator-model type and compare adopted, grid, and applied actuator commands each frame. Original optical prescription and calibration remain unchanged and must match the frozen receipt.

Both graphs receive the same four observation outputs for conditioner preclip requests and actual stage constraint feedback. The candidate's sole science configuration difference must be woofer-command.config.command_limits; restoring those two numbers must reproduce baseline exactly. Stage/tweeter limits, all other graph configuration/properties, parameters, R, optics, atmosphere, detector noise settings and reset policy are unchanged.

Preparation bounds:600s for controller graph/parameter preparation;600s for optical preparation;600s for cold runner specialization. Each scientific case gets300s after two-frame instrumentation warmup and a fresh full reset. These are finite scientific execution gates, not a real-time benchmark. Single private CUDA worker. No H/B/SVD preparation.

Commands:

```sh
WRAPPER=/home/dgamroth/.cache/pipewireao/gpi2-registered-20261025/with-env.sh
ENVIRONMENT=/home/dgamroth/.cache/pipewireao/gpi2-registered-20261025/environment
SCRATCH=/home/dgamroth/.cache/pipewireao/gpi2-woofer-stroke-20261026
"$WRAPPER" julia --startup-file=no --project="$ENVIRONMENT" "$SCRATCH/replay-woofer-stroke.jl" cpu preflight-only > "$SCRATCH/preflight.log" 2>&1
"$WRAPPER" julia --startup-file=no --project="$ENVIRONMENT" "$SCRATCH/replay-woofer-stroke.jl" cuda > "$SCRATCH/replay.log" 2>&1
"$WRAPPER" julia --startup-file=no --project="$ENVIRONMENT" "$SCRATCH/summarize.jl"
```

The copied proven resource resolver is installed at top level before `main`, preventing the prior relocation/world-age setup faults. It changes only3 resource-root path expressions inside the process; all used template/catalog hashes and original frozen optical prescription identities remain verified. No package/global cache paths are changed.

Every frame records whole spatial atmosphere SHA256, direct woofer/tweeter/stage preclip peaks and actual constraint-feedback clipping counts. Controller outputs, atmosphere and residual optical output must be finite. Demanded commands must exactly equal the declared Float32 clamp. Feedback must exactly equal requested minus demanded. At frame n, command n−1 must exactly match adopted graph input, mirror grid command and applied linear actuator command; the stage's adopted coefficient buffer is also checked. The final frame's newly issued command is bounded and finite but awaits the next optical frame. WFE, camera frame hashes and detector RNG metadata are sampled first32frames then every64frames.

Noise matching requires identical frozen detector configuration, seed2 and reset policy/draw sequence; it does not require identical photon input or raw camera pixels after optical trajectories differ. Full spatial atmosphere hashes must match on every frame. Original atmosphere seed1/settings remain unchanged. Before scientific timing, two instrumented frames warm the same runner specialization, followed by full graph/controller/model-time/command and detector RNG reset for every case.

Extension policy: first4096frames of baseline and candidate; compare mean sampled residual WFE over2049–4096. If candidate improves by at least2% and no finite/structural/adoption/bound check fails, run BOTH16384-frame cases from reset. Record sampled WFE maxima/flares without claiming stability. No gain search or deployment occurs.

## Observed results

Both4096-frame cases and both16384-frame cases completed. All preparation phases stayed below600s. Warm4096-frame execution took40.05s baseline and42.49s candidate; warm16384-frame execution took166.61s baseline and166.15s candidate, below300s per case. These execution times are not real-time performance measurements.

The fixed short assessment window, frames2049–4096, improved mean sampled WFE from66.3727nm to54.1808nm (18.37% lower), meeting the agreed extension criterion. The paired long assessment below uses frames2049–16384, model interval1.024–8.192s. WFE is piston-removed pupil OPD RMS on the declared valid support, sampled uniformly every64frames (224observations in this window). Command statistics cover all14336frames. Optical frame n uses the preceding adopted command n−1.

| Quantity, frames2049–16384 | Baseline ±1µmOPD woofer | Candidate ±3.4µmOPD woofer |
| --- | ---: | ---: |
| Mean sampled residual WFE (nm) | 59.6812 | 54.0821 |
| Maximum sampled residual WFE (nm) | 89.2827 | 70.3233 |
| Mean woofer preclip peak request (µmOPD) | 1.01721 | 1.67523 |
| Maximum woofer preclip peak request (µmOPD) | 1.06293 | 2.37756 |
| Maximum actual demanded woofer peak (µmOPD) | 1.00000 | 2.37756 |
| Mean tweeter preclip peak request (µmOPD) | 1.11579 | 1.10421 |
| Maximum tweeter preclip peak request (µmOPD) | 1.25656 | 1.27009 |
| Maximum stage preclip coefficient (µmOPD) | 1.12158 | 0.65024 |
| Mean woofer clipped command coordinates | 6.28523 | 0 |
| Mean tweeter clipped command coordinates | 54.82199 | 27.43248 |
| Frames with actual stage constraint feedback (%) | 5.81752 | 0 |

The long-window mean WFE is9.38% lower. The candidate has no woofer clipping in this interval and its largest demanded woofer command is2.37756µmOPD, below the tested3.4µmOPD bound. At least one woofer coordinate exceeds the original1µmOPD limit on every late-window frame. Tweeter clipping remains frequent (99.69% of candidate frames), and its maximum preclip request increases slightly despite fewer clipped coordinates. These are direct conditioner requests/feedback and adopted simulated commands, not estimates from a displayed mirror map or measured hardware stroke.

Every one of4096/16384 whole atmosphere spatial hashes matched between each baseline/candidate pair. Detector seed/reset and sampled draw sequence matched. The96 historical baseline atmosphere/WFE/mirror-clip observations and atmosphere hashes match exactly. Direct preclip observations agree with historically reconstructed demanded-plus-feedback peaks within the recorded rounding tolerance. Both long runs reproduce all retained short-run command/WFE/camera observations over their first4096frames after reset.

All controller/atmosphere/residual outputs passed finite checks. The actual Float32 conditioner clamp, requested-minus-demanded feedback, adopted graph commands, DM grid scatter and applied actuator commands agreed exactly: every recorded maximum structural error is0nm. Runtime actuator models are `LinearStaticActuators` on both mirrors, confirming no second simulated-device clipping policy exists. The original graph, calibration receipt and environment manifest hashes remained unchanged. Source/staged resolved optical graphs and frozen prescription identities match; all controller parameter hashes are identical between cases.

## Derived interpretation and decision

Within this frozen simulator, the provisional woofer amplitude bound is a performance-sensitive assumption. The matched experiment isolates its two lower/upper limit numbers; the wider bound permits commands actually consumed by the optical plant and improves the recorded finite-window correction. No gains, anti-windup, pole, reconstructor, hidden-removal setting, command maps, detector settings, atmosphere, stage/tweeter limits, optical model or calibration were changed.

Retain this as positive provisional-versus-HEART-reference sensitivity evidence. Reject a claim that this establishes a measured hardware limit, an optimal stroke policy, or long-term stability. The3.4µmOPD bound was not reached in the assessed interval, and sampled WFE maxima are finite-interval flare observations. No production/deployment change follows from this experiment. The live controller, GUI and native sessions remain unchanged.

Reviewable artifacts: `replay-woofer-stroke.jl`, `preflight.json`, `replay-result.json`, `case-{baseline,candidate}-{4096,16384}.json`, `replay.log`, Julia-only `summarize.jl`, `summary.json`, `summary.txt`, and `final-verification.json`. Summary source hashes cover the wrapper, environment, helper, frozen graph/receipt, simulation declarations, grid-DM/actuator/RNG code and vector conditioner. Resource locator source/template hashes are retained in the preflight and main report.

## Retained evidence and independent verification

This record is retained on `codex/gpi2-woofer-stroke-20261026`, based on RTC
commit `49548303f08ff144f693d2c81047a831341c0a8d`. Production sources are unchanged.
`case-*.json.gz` retain the raw observations; decompress before running either
summarizer. `runners.tar.gz` contains the runner, resolver, summarizer, final
verification, direct-observation graph files and shared replay helper. Original
absolute source/environment paths and their identities remain in the receipts;
reproduction requires those dependencies and calibrated artifacts, not only this
archive. `SHA256SUMS` covers retained numerical records and scripts.

`verify-results.jl` separately recomputes late-window statistics and exact
short/long reset prefixes from all four raw cases. It passes 49/49 assertions;
see `independent-verification.log` and `independent-summary.json`. Its first run
stopped in report construction because an inferred numeric dictionary could not
hold nested device statistics (43 assertions had passed). Giving that cold report
dictionary an explicit value union corrected the verifier; no numerical replay
or case data changed.

Run it with JSON.jl available:

```sh
julia --startup-file=no --project=/path/to/json-environment verify-results.jl /path/to/decompressed-cases independent-summary.json
```

The final service check retains the original live RTC and GUI invocation IDs
and PIDs, both active. No deployment or lifecycle action was performed.
