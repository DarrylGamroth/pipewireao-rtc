# Classic detector oracle — independent final review

Date: 2026-10-22. Disposition: **accepted for the finite CPU integration gate**.
CD-004 is corrected and independently verified against the expanded final
witness. No blocking issue remains in the reviewed test changes. The original
failed oracle's numerical cause remains unproven.

## Scope and revisions

Reviewed RTC worktree `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-detector`,
branch `codex/classic-detector-oracle-20261022`, based on
`bd6c82719e86c18487849fdf9edd8eb79ae7aef6`, with final test implementation at
`e4b0e8b6f0a8a36a2b544ac777d6426bb16af8ab`.
Reviewed `classic_fft_oracle.jl`, `classic_wavefront.jl`,
`prepare_classic_wavefront.jl`, and `test_classic_fft_oracle.jl` under
`test/integration/`. The production `src/` and `ext/` implementation is unchanged.
Pre-existing and coordinating-agent changes were preserved. This reviewer wrote
only this review during the final gate.

Raw evidence root:
`/home/dgamroth/workspaces/codex/worktrees/classic-detector-20261022/`.
The independent numerical experiments described below were performed earlier
in this review assignment. The final gate inspected retained results and source;
it did not repeat services, builds, or the managed experiment.

## Findings and disposition

### CD-001 — Floating-point input sensitivity crosses a discrete photon threshold

Severity: informational. Confidence: high. Classification: observed.
Disposition: established mechanism; no detector physics change warranted.

In controlled MEASURE versus NO_SIMD optical preparations, frame 14 at row 297,
column 209 has photon rates 802437.0625 versus 802437.125 photons/s. With identical
initial detector RNG state and identical normal draw, the CPU photon sampler's
argument is 438.49998894698905 versus 438.5000194645672. Rounding yields 438 versus
439 electrons and subsequently 305 versus 306 ADU. Independent detector captures
exactly reproduce both complete retained frames and final RNG states. Swapping
only that pixel's rate reproduces the opposite complete ADC frame in both
directions. Evidence: `independent_detector_causal.jl`,
`independent-detector-causal.json`, and `independent-detector-causal.log`.

At the original frame-10 pixel, row 276, column 189, a controlled one-Float32-ULP
rate reduction, 325130.3125 → 325130.28125 photons/s, changes the sampler argument
164.50001284208076 → 164.4999977267515 and ADC 110 → 109. Only that ADC pixel
changes, and final RNG state remains identical. Evidence:
`independent-detector-frame10.json`. These experiments loaded no GPU modules or
GPU libraries.

### CD-002 — Historical cause cannot be recovered from missing inputs

Severity: informational, historical uncertainty. Confidence: high for the
limitation; the proposed historical cause remains a hypothesis.
Disposition: retained uncertainty, not a blocker for the newly scoped gate.

The original oracle's photon arrays and FFT plans were not retained. CD-001
reproduces its symptom but does not establish that the original process used
the perturbed rate or a differing FFT plan. Preserve the original failed receipt
and [WS-003](../20261022-wavefront-series/REVIEW.md); do not relabel that experiment
as passed or the historical FFT explanation as confirmed.

### CD-003 — Exact replay now checks the retained FFT execution contract

Severity: informational. Confidence: high. Disposition: accepted.

The isolated application adds a cold preparation witness, invokes the existing
science preparation, and exports its FFTW wisdom and retained plan descriptions.
The reference checks Julia/FFTW/provider/thread/hash provenance, imports the
wisdom, requires `WISDOM_ONLY` for repeated transforms, and compares retained
plans before exact ADC replay. No ADC or controller assertion was relaxed.
Missing wisdom, incompatible plans, corrupt witness data, and empty inventories
fail closed in the tested cases. The native execution remains MEASURE-based.
The prepared and installed helper SHA-256 both match the reviewed source:
`05ca2e24fe12b33cf24b14b43818c24eb3289019e0d5cdbf0f20c2869056f9d9`.

Scope limits: inventory traversal covers named retained plans and bounded
nonnumeric arrays, skips numeric/string/symbol storage, and fails above its
collection/depth bounds. `WISDOM_ONLY` enforcement applies to repeated WFS
transforms. The five atmosphere transforms use the ordinary planning helper;
their retained plans are now also compared exactly after wisdom import. This
is not enforcement of `WISDOM_ONLY` on every transient preparation FFT. BLAS
and Julia thread provenance are recorded; this is not a universal cross-process,
cross-version, or cross-hardware bitwise guarantee. The final native witness
records Julia 1.13.2, FFTW 3.3.11, 20 retained plan paths (15 SHWFS paths including
aliases and five atmosphere paths), one FFT/BLAS thread, and two Julia threads.
The reference science execution is single-threaded.

### CD-004 — Atmosphere FFT plans omitted from the retained-plan witness

Severity: medium. Confidence: high. Classification: confirmed test coverage defect.
Disposition: **closed; corrected and verified at e4b0e8b**.

The initial `plans` traversal skipped every `AbstractArray`. The current pinned
AOS implementation stores `MultiLayerAtmosphere.layers` in a vector of
`MovingAtmosphereLayer`; each layer retains an FFT in
`layer.generator.state.ifft_plan`. Thus the initial 15-path witness checked SHWFS
aliases but omitted existing atmosphere transforms. This reviewer initially
underestimated the array-traversal limit and accepts the primary review's
correction. The initial passing ADC result remains valid; its claim of a
comprehensive retained-plan comparison required the repair below.

The correction traverses nonnumeric arrays of at most 1024 elements, skips
numeric buffers, and retains the depth bound. Regression tests establish nested
plan discovery and reject removed/changed nested plans and oversized owner
collections. Source inspection verifies those branches; the retained focused
run passes 11/11 checks. The new native managed run passes 1027/1027, and its
20-path witness explicitly contains all five
`graph.nodes.atmosphere.owner.atmosphere.layers.N.generator.state.ifft_plan.p`
paths for N = 1…5. Prepared, installed, and reviewed helper hashes match.
The initial 15-path run remains preliminary evidence under `managed/`; final
acceptance relies on `managed-all-plans/`. This is not a production detector
defect and does not establish the historical failure cause.

## Verification inspected

- `oracle-all-plans-preconditions.log`: **11/11 passed**, including positive
  restoration, nested-plan discovery, and negative preconditions.
- `managed-all-plans.log`: **1027/1027 passed**, two finite reset generations.
- `managed-all-plans/wavefront-result.json`: complete and cleanup complete;
  each generation has 32 exact detector and controller replays, no ADC
  differences, 31 wavefront samples, paired RMS, pupil-mask and
  acquisition-identity/PTS checks. Maximum image error is
  1.5258179359989299e−5 nm, within the unchanged 1e−4 nm tolerance.
- `managed-all-plans/fft-oracle/`: 20 retained plan paths independently
  inspected, including five atmosphere plans. Wisdom hash matches the recorded
  `6f5c1893c26c31fb45f5d35ecbd7034fc26d265627478cc64d9592986d14d263`.
- `managed-all-plans/final-launch.json`: stopped, service success, cleanup
  complete, unit files removed, no reported error. Managed tests also check
  process exit.
- Helper source, `all-plans-application/` copy, and installed copy have the
  identical SHA-256 recorded in CD-003. Production `src/` and `ext/` are unchanged
  relative to the starting RTC revision.
- RTC `git diff --check`: passed during review.

These are finite CPU software/transport results. They do not establish cadence,
tail latency, GPU behavior, hardware behavior, or physical-loop qualification.

## Additional GUI review boundary

A narrow read-only review inspected the chart changes in
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-gui-chart-interaction` relative
to `630198f88fd07cdba5c0c316f1c0307b4f58c2f2`, including the new `input.rs` and
`plot.rs` files and associated tests. No actionable defect was found in unique
source resolution, connection replacement handling, the latched schema/format/
shape contract, bounded channel/history storage, configured-model versus
exploratory-PTS clock selection, or restoration fencing. The source selector
uses existing read-only observation requests; it does not add RTC authority.

This was a source-level review of those boundaries and chart interactions,
not an exhaustive GUI review. GUI tests, browser rendering, GPU rendering, and
live user interaction were not independently rerun. Reported broader GUI test
counts remain the coordinating agent's validation evidence.

The coordinating agent subsequently reported GUI integration at canonical
`main` revision `758a6b3` and removal of the task worktree. That integration
revision was not independently re-reviewed here; the GUI assessment above
refers to the inspected source changes.
