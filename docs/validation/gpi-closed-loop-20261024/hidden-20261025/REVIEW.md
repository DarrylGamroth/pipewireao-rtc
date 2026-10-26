# Independent hidden-mode integration review — 2026-10-25

Reviewed the working diffs in RTC `codex/gpi2-heart-20261025` over
`e23c30a6b47c8a78b4d43c21e2ab1b301b47fa0e` and the instrument worktree over
`5ae24c87fededa6952ff77cf723b2b1ba9189307`. This review inspected source,
test assertions and existing numerical evidence; it performed no new numerical
runs or live actions. Only this review file was written by the reviewer.

## Findings and disposition

| ID | Finding | Disposition |
| --- | --- | --- |
| GPIH-01 | A generated profile could select another directory's graph and gain because its mode was fixed to `heart`. | Resolved. `prepare-hidden-controller.jl` now checks the declared mode's configuration and graph source against its output before creating artifacts, requires calibration selection, and emits that mode. |
| GPIH-02 | The generic helper accepted RMS values for which the parent calibration assigns zero TSVD weight. | Resolved. It rejects values at or below `sqrt(eps(Float32))`, preserving the supported nonzero-weight premise of the inverse-weight equations. A rejection test was added. |
| GPIH-03 | A graph destination could overwrite another declaration's explicit source. | Resolved. Resolved source/destination collisions are checked before any graph writes; the regression test verifies both inputs remain unchanged. |

No unresolved source correctness blocker was found in these corrections.
The complete two-mode offline export selector remains a required pending gate
at this review snapshot; its result must be recorded before claiming complete
export integration. The focused calibration log records 65/65 passes, and the
focused exporter selector records all testsets passing. The reviewer inspected
those logs but did not rerun them.

## Equations and ownership

The helper derives H = VdᵀW⁻¹ and B = WVd from the parent's weighted interaction
matrix JW, with W = diag(1 / mode_rms). HB approximates identity and BH is the
discarded-direction projector, oblique in raw controller coordinates. The
helper verifies parent hashes, dimensions, retained rank and reconstructor
agreement without replacing parent artifacts. Existing JFG projection names
and controller dimensions supply the terminology and execution ownership.

For the tested unit pole and anti-windup gain, the genuine JFG update is
`cₙ = (I − γBH)(cₙ₋₁ − bₙ₋₁) − 0.3eₙ`. It removes hidden content of the
preceding realized shape. This differs from projecting only constraint
feedback. The discarded directions have nonzero optical response; neither raw
nor column-RMS-scaled coordinate norms are actual optical RMS.

## Scientific evidence and decision

The [run record](RUN.md), replay driver and saved results support the stated
finite comparison: gain zero matches all original integrator graph outputs
bit-for-bit over 4,096 frames; recorded full atmospheric-field hashes match
between reset cases; per-frame state/output recurrence errors are zero.
Frames 2049–4096 provide 32 uniformly spaced optical observations, while the
clipping statistics cover every frame in that window.

Mean sampled residual WFE worsens from 66.37 nm at gain zero to 97.77 nm at
gain 0.1 and 148.73 nm at gain 1. Sampled residual maxima and woofer preclip
excursions also increase. Reduced hidden content and fewer clipped actuators
therefore do not satisfy the optical acceptance objective. Reject enabling
the tested nonzero removal policy; retain the default integrator and the
opt-in `heart` mode's zero gain. No additional experiment is needed to withhold
this candidate from live use.

The replay used an independently recomputed diagnostic basis. Exact generated
production FITS received static comparison only: the projector difference is
8.79 × 10⁻⁶ relative in raw coordinates and 5.50 × 10⁻⁶ after weighting. This
is not runtime qualification of those exact artifacts, nor proof that every
possible hidden-mode policy is harmful. The failed resource-location setup
attempts remain separate from completed scientific cases. No long extension,
hardware/native-session qualification, global stability proof, optimal
allocation claim or 2 kHz timing claim follows from this evidence. Live
controller settings remain unchanged.

## Post-review gate confirmation by the primary agent

The pending two-mode export selector subsequently exited successfully with
27/27 checks in 9m44.8s. The primary agent inspected the completed
`profile-tests-final.log`; no implementation changed after this review. The
gate covers the selected zero-gain profile and exact FITS loading, without
altering the scientific qualification boundaries above.
