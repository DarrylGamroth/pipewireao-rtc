# Independent review — 2026-10-26

## Scope and revisions

Read-only review of AOS `dc2b867b`, RTC `225c605` (including `e68a2fa`,
`f69c4d0`, and `60189f8`), and the uncommitted GPI2 definition, recipe, and
README changes above instruments `b760613`. The reviewed worktrees are
`aos-stage-response-20261026`, `rtc-gpi2-temporal-split-20261026`, and
`instruments-gpi2-temporal-split-20261026`. Existing RTC evidence was untracked;
the instruments worktree already contained those three intended edits.
No source edits, new numerical experiments, live controls, or deployment were
performed by this reviewer.

## Source assessment

No blocking implementation finding was identified in the reviewed diff.

- The augmented matrix exponential implements the declared held-input
  second-order equation. Coefficient order agrees with both state updates;
  position and velocity use the same old state. State, output, and exact input
  bindings have separate ownership. Reset preserves storage and restores rest.
  The accelerator enqueue uses one kernel and no host-side state progression.
- The low-pass helper follows FGA's `(b0,b1,b2,a1,a2)` convention and denominator
  sign. Its post-rounding numerator normalization preserves unity DC gain.
  The recipe fills both axes of the existing stage bank; modal coefficients
  remain identity. The unchanged controller subtracts filtered correction
  minus constraint feedback, preserving offset-free stage allocation and
  clipping spillover into the woofer.
- Response insertion retains the graph boundary and places the native response
  before its original consumer. Both declaration-period and application-cadence
  checks are present. At the selected 0.0005 s period, the response, atmosphere,
  detector exposure, and controller coefficient sample rate share 2,000 Hz.
- Calibration expansion deliberately excludes physical response. This is a
  static spatial calibration for a unity-DC response, not temporal calibration.
  Prescription hashing includes the response declaration. The instrument guide
  requires fresh calibration/build and preserves historical FITS/receipt bytes.
- The replay checks actual input adoption and applied stage coefficients,
  independent 2×2 exponential recurrence, clamp/feedback identities, explicit
  resets, atmosphere identity, and the historical ideal/identity observations.
  WFE remains sampled, and the final issued command awaits the next frame.

## Findings and disposition

| ID | Severity / confidence | Evidence and analysis | Disposition / required validation |
| --- | --- | --- | --- |
| TREV-01 | Minor / confirmed | Scratch `replay-temporal.jl:297` skips the elapsed-time rejection on the final frame. A final checkpoint above the predeclared 300 s warm-case bound can therefore be labelled complete by this driver. | Addressed for this experiment: `verify-results.jl` independently requires complete requested frame counts and `0 ≤ elapsed_s ≤ 300` for every saved scientific case. All six pass. The driver limitation remains documented; no repeat experiment is required. |
| TREV-02 | Resolved defect / confirmed | The failed setup appended the response after its optical consumer. RTC `225c605` now inserts it immediately before that consumer. `test_response_cadence.jl` exercises native response→optics preparation, stepping, and reset; the saved selector log reports 8 passing assertions, and preflight checks every actual GPI direct-link ordering. | Corrected in source. Preserve the rejected setup and do not count it as scientific instability or a successful case. |

The duplicate-controller preparation timeout and the later report-dictionary
type failure also occurred before scientific cases. Their frozen drivers,
logs, reports, and RUN.md explanations remain evidence of failed setup attempts.
The response schema reference resolves before declaration validation; it is
not an unresolved schema defect.

## Validation boundary

The supplied focused-test evidence includes AOS CPU/response and CUDA
capture/reset coverage, RTC coefficient/FGA and configuration/export checks,
and native cadence/admission coverage. This reviewer inspected their test
logic and the saved 8-assertion admission log without rerunning them.

## Final numerical assessment

All six scientific cases completed and satisfy the predeclared finite
experiment gates. The saved independent Julia verifier reports **99/99**
assertions passing in `independent-verification.log`. This reviewer separately
read and reaggregated the raw saved cases in
`/home/dgamroth/.cache/pipewireao/gpi2-temporal-20261026`; this was inspection
of existing observations, not another simulation or parameter search.

| Case | Frames | Elapsed s | Late sampled WFE mean / max nm | Stage tracking norm RMS nm |
| --- | ---: | ---: | ---: | ---: |
| ideal / identity | 4,096 | 71.944 | 54.18079 / 56.49649 | 0 |
| ideal / 25 Hz | 4,096 | 59.927 | 54.19333 / 56.49951 | 0 |
| dynamic / identity | 4,096 | 47.954 | 54.23175 / 56.56743 | 2.11494 |
| dynamic / 25 Hz | 4,096 | 46.737 | 54.19082 / 56.43461 | 1.26164 |
| dynamic / identity | 16,384 | 210.320 | 54.09387 / 70.06075 | 2.00271 |
| dynamic / 25 Hz | 16,384 | 234.186 | 54.09567 / 70.10287 | 1.07547 |

Late windows are frames 2049–4096 or 2049–16384. They contain 32 or 224
sampled optical observations. Stage tracking is
√mean(errorₓ² + errorᵧ²), evaluated every frame against the held adopted
command; it is a coefficient-space quantity, not pupil WFE.

Observed and independently checked from saved arrays:

- Ideal/identity exactly matches every retained preceding accepted-woofer
  command statistic, WFE/atmosphere statistic, all 4,096 atmosphere hashes,
  and all 96 retained camera hashes and RNG observations. Previous full command
  vectors were unavailable; equality of those unrecorded vectors is not claimed.
- Paired cases share the atmosphere field at every frame and matching detector
  seed/reset/draw observations. Different optical trajectories appropriately
  produce different camera pixels. Both dynamic 16,384-frame cases reproduce
  their entire 4,096-frame prefixes exactly, including full command hashes,
  per-frame traces, sampled WFE/cameras, and atmosphere fields.
- Every saved case has the requested frame count, finite retained observations,
  correct sampling and per-frame trace lengths, and a final duration below
  300 s. Controller, optical, and instrumentation preparation took 307.014,
  75.070, and 46.935 s, respectively, within their separate 600 s bounds.
- Adopted stage command n equals issued command n−1, starting from zero.
  Recorded clamp, feedback, input-adoption, actuator-grid/application, and
  stage-application identity errors are zero. Independent response recurrence
  checks passed every frame; the largest recorded position error is
  6.531 × 10⁻⁵ nm and velocity error 0.014635 nm/s, within the declared scaled
  Float32 tolerance.
- Woofer and stage commanded coordinates never clip in any of the six cases;
  applied stage coordinates never exceed the command boundary in this run.
  Tweeter clipping remains. In the long late window it averages 27.44524
  coordinates/frame with identity and 27.47949 with 25 Hz, reaching 95 and 97
  coordinates respectively. It occurs in 99.721% of those frames in both cases.
- Runtime receipts report only the stage coefficient bank changed between
  controller cases, preserved graph/receipt/environment hashes, static
  calibration-graph equality, and distinct ideal/dynamic prescription identities.

Derived interpretation: the 25 Hz filter reduces stage tracking error for this
trajectory, but does not establish an optical improvement. Its short dynamic
window has 0.07546% lower mean sampled WFE; its longer window has 0.00334%
higher mean sampled WFE. Report both outcomes and the approximately 70 nm
sampled late WFE peaks. These one-seed observations support implementation of
the requested configurable split and finite matched replay; they do not support
calling 25 Hz optimal or qualified tuning. No additional source finding or
blocking validation failure was identified.

Passing these checks establishes finite, configuration-specific software
behavior. It does not establish measured stage dynamics, asymptotic stability,
hardware limits, physical-device correctness, or real-time performance. The
250 Hz / 0.7 physical model remains provisional, and response position can
overshoot the demanded-command bound without an implicit physical clamp.
