# GPI separate-DM sensing calibration — 2026-10-28

This is a fresh simulation-local calibration of the optional GPI
`pwfs-dm-planes` sensing model, using CUDA graph capture. It is not an adoption
of the old common-pupil interaction matrix. Live configuration, the selected
calibration, installed processes and instrument defaults remain unchanged.

## Model and acquisition

The candidate retains atmosphere/woofer/stage at surface 48 and tweeter at
surface 60, propagates at 750 nm through pupil 64, then passes the complex field
through the provisional ideal pupil relay to the PWFS. The actual downstream
PWFS relay prescription remains unavailable. Centered scalar optics, Gaussian
mirrors, ADC assumptions and the ideal relay remain explicit approximations.

In a fresh source copy, `graphs.calibration` selects the optional deterministic
`simulation/pwfs-dm-planes-calibration.yaml`. There is no evolving atmosphere,
detector noise or dynamic actuator response in that role. Disturbances enter
surface 48 once; their diagnostic composition shares that input, while the relay
entrance has a separate zero binding. Generated snapshots are regenerated with
the supported ZEMAX preparation API. The normal exporter builds the application.

The shared calibration procedure uses its existing ±20 nm push/pull probes,
piston-removed pupil-RMS weighting, annular completion, 5% TSVD cutoff and
25 Hz tip/tilt filter at a 2 kHz model sample rate. No gain, threshold, limit,
probe amplitude or inversion policy was tuned to obtain a result.

| Quantity | Result |
| --- | ---: |
| Measurements | 11,104 |
| Controller coordinates | 1,509 (97 woofer, 1,412 tweeter; first two coupled coordinates drive the stage) |
| Retained rank | 1,445 |
| Relative inverse residual | 0.054787233 |
| Common-plane stage-to-woofer fit residual | 0.021530246 |
| Coupled projection condition | 2.5826187 |

The inverse residual is an observed matrix diagnostic, not a 5% precision
acceptance claim: truncation is applied to the RMS-weighted matrix.
The bundle receipt SHA-256 is
`ee3800c0874ab650ada6c6de7e874aa6f3965fa849d564dbed006c6b8af1c10f`.
Its prescription is
`sha256:6817601a3ba3da7edcd51937a7e7804b56b2f0ec8822e61521ad3a223dce0a6a`.

## Closed-loop results

All four 48-step deterministic cases pass the propagated-field gate. Values
below compare the initial field with the mean of the final eight frames.

| Disturbance | Initial overlap | Final overlap | Remaining overlap-loss fraction | Diagnostic common-pupil RMS ratio |
| --- | ---: | ---: | ---: | ---: |
| Tip/tilt | 0.9611019 | 0.9998911 | 0.002800 | 1.25249 |
| Focus | 0.9454068 | 0.9999030 | 0.001776 | 0.18465 |
| Astigmatism | 0.9584175 | 0.9998785 | 0.002922 | 0.26739 |
| Mixed | 0.9743381 | 0.9999412 | 0.002291 | 1.29478 |

The paired, noisy, moving-atmosphere test passes 256 frames (0.128 s of model
time). Over frames 128–256, mean corrected overlap is approximately 0.7983
versus 0.00093 with zero correction. The mean overlap-loss ratio is **0.201844**,
about an 80% reduction. These are normalized coherent-field quantities, not
wavefront-RMS or physical Strehl measurements. The two captured plants have
exactly equal atmosphere OPD at every paired frame and advance exactly 256
model steps. Commands/fields stay finite and raw acquisition retains UInt16
with zero padded rows.

Receiving pupil power relative to the flat field stays between 0.99964 and
1.000102 across both plants; improvement is not obtained by extinguishing light.
The woofer has no nonzero clipping feedback. The tweeter still reaches limits:
the maximum simultaneous nonzero-feedback count is 43 of 2,304 actuators
(mean 26.39). This candidate does not establish clipping-free operation,
long-term stability or a qualified supervision policy.

The standard staging API creates a separate candidate source with 33 parameter
bindings; no installation follows. Its staged calibration identity is
`sha256:8e6a5f6b91590f16b9fcf14803ce7fe1c5cedd40b0989e5a60be0a90fc2e0253`.
The acquisition bundle above remains byte-for-byte intact.

## Validation and measurement authority

The instrument's deterministic CPU topology selector passes 43 checks. Focused
bundle/FITS/temporal-coefficient and field-metric selectors pass 361 checks.
The captured-CUDA optical response selector passes 19 checks: raw photon-rate
derivatives for one woofer actuator, one tweeter actuator and both stage axes
agree with CPU to relative L2 errors 1.44×10⁻⁵, 3.10×10⁻⁵, 1.12×10⁻⁵ and
1.05×10⁻⁵. These are optical derivatives, not a CPU reacquisition of every saved
normalized interaction-matrix column. UInt16 acquisition, padded rows and
deterministic captured replay are checked.

The receiving-field metric is normalized coherent overlap with a propagated
flat reference:

```text
F(E₀,E) = |⟨E₀,E⟩|² / (‖E₀‖₂² ‖E‖₂²)
```

It is invariant to piston and uniform attenuation. It compares phase and
relative amplitude profile, not absolute throughput or unwrapped OPD. The
field-selected gate requires a 20% decrease in overlap loss. The legacy OPD-RMS
gate remains unchanged when no field output is selected.

An initial test incorrectly required the new model's common-pupil `pupil_opd`
diagnostic to pass as well. The preserved result showed tip/tilt field overlap
improving from 0.9611019194 to 0.9998910781 (99.72% overlap-loss reduction), while
that diagnostic's RMS ratio was 1.25249. The model contract already states that
the common-pupil sum is not the propagated field's OPD. Independent review
therefore accepted using propagated fidelity for this model while retaining
the old OPD result as a non-acceptance diagnostic. This changes the measurement
authority, not gains, inversion, optical data or the legacy model's gate.

The first acquisition attempt also exposed a cold extension-loading defect:
Proper loaded inside graph preparation was too late for the calling Julia
world. Calibration now loads the declared optical dependency before entering
the complete procedure through `invokelatest`. The same fresh CUDA CLI then
completed the acquisition. Two initial GPU-test coding errors (node-name access
and a scalar GPU write) were repaired without production numerical changes.

An unrelated `modal_hidden_modes.jl` fixture fails bundle file validation on
both unchanged RTC main and this branch. Logs preserve both reproductions;
this work does not claim that selector passes.

Independent final review found no blocking issue. It verified the command order,
flat reference ownership, same-atmosphere pairing, artifact/recipe identity checks
and receipt calculations. The cold Proper loading fix and choice of propagated
measurement authority were accepted from the reproduced failures and existing
model contract. A wording correction records the precise 129-frame tail above.
The final loop selector uses ordinary error predicates for the same checked
conditions, so a failed receipt cannot be marked passed by an enclosing testset.

## Reproduction and retained artifacts

Use a separate source-validation environment with Julia 1.13.3, AOS source
containing planar field output, this RTC implementation, Proper 0.4.1,
CUDA 6.4.2, HIL 0.2.11, FGA 0.8.13, JFG 0.4.3 and AOC 0.17.3. The host has an
RTX 3080 with driver 615.71.10. Julia and BLAS each use one thread. CPU execution
is only a bounded correctness oracle; GPU execution uses graph capture.

The retained cache `gpi-pwfs-calibration-20261028` contains the source/application,
hash-verified standard bundle and FITS, environment, generator commands and all
successful/failed logs. Source bases are RTC `08c0aae`, instruments `89365f1`
and AOS `ff6a213e`; the task commits contain the calibration changes.
The application and candidate were never installed or launched.

```sh
julia --project=<science-environment> prepare-candidate.jl <instrument-repository> <fresh-directory>
julia --project=<science-environment> tools/calibrate.jl <application> <fresh-bundle> cuda capture
julia --project=<science-environment> tools/validate-calibration.jl <application> <bundle> <fresh-report.yaml> cuda capture pwfs_pupil_field
julia --project=<science-environment> test/gpi2_pwfs_calibrated_loop.jl <application> <bundle> <fresh-noisy-report.yaml>
```

These are finite simulated numerical checks, not physical calibration, an
as-built optical model, native transport qualification or a 2 kHz deadline.
