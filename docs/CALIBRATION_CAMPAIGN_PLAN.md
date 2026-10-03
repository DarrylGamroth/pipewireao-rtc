# Automatic Classic calibration campaign

Implementation baseline: RTC `dccb179`, isolated worktree
`pipewireao-rtc-calibration-campaign`, branch
`work/calibration-campaign-20261002`. No pre-existing production edits.
Authority is RTC-ARCH-023 and RTC-DEV-029 as extended in this increment.
The [independent review](CALIBRATION_CAMPAIGN_REVIEW.md) records confirmed
findings and their dispositions. [Usage](CALIBRATION_CAMPAIGN_USAGE.md) and
[validation](CALIBRATION_CAMPAIGN_VALIDATION.md) describe the selected delivery
and its evidence limits.

## Selected delivery

Classic CPU FGN/JFG, completion-driven simulated instrument calibration with
normal noisy ADC samples. Fresh dark → lamp training → frozen qualification →
existing zonal sessions. Every stage uses normal demanded/adopted commands,
exposure receipts, reference restoration, release and public stop/quit.
The numerical owner is AOC; RTC owns association, declared acceptance policy,
temporary evidence, startup packaging and lifecycle. No active artifact is
replaced. Zonal finite-difference estimation is retained; Hadamard, modal,
sinusoidal, LiFT and DOCRIME qualification are independent work.

| Obligation | Allocation | Verification / acceptance | State |
| --- | --- | --- | --- |
| Normal dark/lamp ADC and stage identity | Owner startup selection and reports | Actual transported bytes, unchanged detector settings, distinct declared samples | Implemented; software fixture tests and installed selected CPU campaigns pass |
| Bounded raw/WFS evidence | Serialized owner capture, fixed payloads, manifest-last publication | Capacity-before-effects, all channels/receipts/hashes, invalid dark quality retained, partial write/deadline failure | Implemented; software fixture tests and installed selected CPU campaigns pass |
| Scientific statistics/reference | Public bounded AOC batch methods | Known-array mean/variance/reference/mask, finite values, dimensions/order, invalid and empty selection | Implemented; software fixture tests and installed selected CPU campaigns pass |
| Declared eligibility and held-out qualification | Campaign recipe and separate fresh session | All ROI evidence retained; no forced count/reselection; references are individual deployed measurements | Implemented; software fixture tests and installed selected CPU campaigns pass |
| Startup parameter snapshot | Standard existing graph artifacts/export | Exact background/reference/mask binding and preparation before first exposure | Implemented; software fixture tests and installed selected CPU campaigns pass |
| Restoration and stage transition | Existing protocol and public launcher | Confirmed restore/release/stop/quit before reduction/next stage, failures preserve disposition | Implemented; software fixture tests and installed selected CPU campaigns pass |
| Candidate publication and numerical agreement | Campaign provenance and comparison | Complete candidate only, source/settings hashes, equivalent ADC/WFS processing | Candidate generation/artifact equality and later shared-input WFS parity observed; historical trajectory difference remains unresolved |
| Interaction matrix | Existing AOC zonal helpers and Rust coordinator | 554 signed commands, full 277 physical coordinates, valid associated responses | Implemented; both campaign interaction sessions complete |

RTC-DEV-029 remains partial. Precision/linearity/observability and 221-coordinate
command-map composition, reconstructor acceptance, correction, Copper, unchanged
HEART, CUDA/HIP and cadence are later gates. This increment establishes no
physical-device, hard real-time or simulator-rate claim.

## Review adjudication

- CC-R1: accept bounded optional capture; keep interaction validity unchanged.
- CC-R2: accept startup illumination and explicit held-out sample provenance.
- CC-R3: accept public transport-neutral scientific batch operations. AOC owns
  estimators and their numerical diagnostics; RTC applies declared campaign
  acceptance and owns publication.
- CC-R4: accept fresh stages and ordinary startup snapshots; defer live
  multi-parameter transactions.
- CC-R5: accept restoration/release/public shutdown fences and candidate-only
  output. Do not recover unknown effects by blind retries.

Tests cover protocol boundaries and deterministic scientific operations;
installed noisy AOS runs qualify only the selected simulated software path.
Original failures and remaining acceptance limits must remain in the final
evidence record.
