# Main integration — 2026-10-06

Reviewed native-control and deployment work is integrated from
`work/native-control-planes-20261005` into main. This is a development baseline;
the merge does not establish completion of every installed or scientific gate.

## Dependency and review alignment

The reviewed SDK registry-retirement API is on PipeWireAO.jl main, own published
commit `1417b69`, with package version 0.6.17. Deployment requires that minimum
version. Project sources and the Pkg-generated Manifest select the same exact
own GitHub commit until registration; no upstream Yggdrasil change or push is
needed. The SDK version preparation is not a claim of registry publication.

The reviewed bootstrap controller-retention change `7efd432` is integrated as
`323dcaf`. The independent [review](validation/bootstrap-seal-20261006/INDEPENDENT_REVIEW.md)
approves paired source integration and records the deliberate bootstrap authority
boundary. Generic public endpoints remain dynamically discoverable.

After resolving the exact published SDK, a fresh process loads deployment and
passes all 232 focused native/bootstrap/deadline/fault assertions. These cold
private-core tests run on CPU15, publish no science frames, and use no GPU.
The [integration receipt](validation/bootstrap-seal-20261006/integration-receipt.json)
binds source-resolution, loading, tests and review evidence. The first Pkg attempt
failed libgit SSH authentication; the CLI Git attempt succeeded. Both logs remain.

## GUI development handoff

The GUI integration pins RTC public Rust client `e01aa82`, which is included in
this main history. Its exact owned-socket connection correction passed the
installed two-session selection replay. No later Rust library change is required
by the Julia bootstrap fix. GUI detailed results are in its
`docs/NATIVE_HIL_GUI_PROGRESS_VALIDATION.md`.

Classic FGN has six exactly equal complete detector/command trajectories and
truth across baseline, unattended observation and observer death/replacement,
including reset. Copper JFG's baseline passed. These installed cohorts used the
previous sealed runtime; they do not qualify the newly merged bootstrap change.
The progress oracle now uses completed HIL exchanges, preserving the external
command-sink boundary adjudicated in [the review](NATIVE_HIL_PROGRESS_REVIEW.md).

## Work remaining

- Copper observation/death comparisons and explicit observer stall qualification.
- Fresh installed inclusive allocation and lifecycle checks against the merged
  paired runtime; cold zero-byte churn is supporting mechanism evidence only.
- Resolve the first native calibration startup failure using the preserved typed
  diagnostics before continuing Collect/Capture cases. Three planned cases have
  not run; the first failed result remains failed.
- Remaining current unchanged-HEART, calibration/correction consumer and full
  foreground/service matrix gates in [the qualification plan](NATIVE_FINAL_QUALIFICATION_PLAN.md).
- SDK registration/release and target performance qualification.

Calibration, allocation and scientific completion issues remain open. Their
status is not inferred from this merge or from GUI readiness.
