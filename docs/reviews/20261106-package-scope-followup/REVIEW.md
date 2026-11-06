# Remaining RTC cleanup — 2026-11-06

Read-only source review at `bfc6187`, branch
`codex/julia-session-policy-20261104`, dedicated worktree `pipewireao-rtc-cleanup`.
The tree was clean. This follows the dependency-only deployment change and the
user's request to identify further cleanup before updating instrument releases.
This report changes no implementation or selected feature scope.

The retained purpose is session admission/lifecycle/links, deployment and control
integration, and calibration orchestration. Scientific computation belongs to
scientific packages; instrument-specific products belong to instrument projects.

## Confirmed ownership reductions

- **NEC-01 remains open: scientific implementation in RTC.**
  [Measured influence preparation](../../../src/instruments/influence_functions.jl)
  performs bilinear resampling and OPD conversion in `_load_influence_functions`.
  `binding_values(::Val{:measured_influences}, ...)` in
  [InstrumentConfiguration](../../../src/instrument_configuration.jl) still calls
  it. This remains the sole numerical use of RTC's Interpolations dependency.
  Transfer the calculation and numerical tests to the scientific owner, retain
  RTC's artifact/path/hash admission, then remove that dependency. Separately,
  [DetectorFrameLayoutOwner](../../../ext/aos/graph_adapters.jl) still implements
  padding, conversion, clipping, rounding, reset and capture capability through
  AOS graph-node interfaces. Transfer that node and its tests to AOS, preserving
  configured names and CPU/GPU behavior. Both have active callers; neither is
  proven dead. Confidence: high; replacement implementations must be established
  and verified before deletion.
- **NEC-02 remains open: the Classic capture product.**
  [Capture files](../../../src/calibration_capture_files.jl) fixes 352×352 raw
  images and 188 measurement ROIs in `CLASSIC_CAPTURE_CONTRACTS`.
  [Calibration preparation](../../../ext/calibration_owner.jl) still validates
  those fixed formats and constructs `CaptureStore`. Move the writer, reader and
  schema tests together to the instrument integration, or explicitly retire that
  product. Preserve generic acquisition transport. Separate deferred archiving
  does not establish that calibration capture is unnecessary. Confidence: high;
  no drop-in receiving API was established by this review.

## Smaller removals and inconsistencies

- **NEC-07: unused legacy export-input mode.**
  [DeploymentConfiguration](../../../src/configuration/deployment_configuration.jl)
  still threads `legacy_export_input=false` through `profile`,
  `validate_application` and `validate_external_owner!`. Enabling it relaxes
  bootstrap/source protocol checks and admits marker-based owner fields. Searches
  found only definitions/forwarding in RTC Julia source and no callers in either
  inspected `adaptive-optics-simulations` worktree. Earlier conversion docs still
  claim exporters enable it. Remove the obsolete mode and marker admission
  branches after confirming downstream conversion support is retired; retain
  tests rejecting old declarations. Confidence: high for absent local callers;
  external use is not exhaustively excluded. This is a removal candidate, not a
  demonstrated runtime failure under the strict default.
- **NEC-08: current documentation disagrees with selected implementation.**
  [README](../../../README.md) opens by assigning the runtime to libwireplumber,
  although the selected architecture uses Julia MediaSession/PipeWireAO directly.
  [Deployment usage](../../JULIA_DEPLOYMENT_USAGE.md) and the root source version
  guard say Julia 1.12, whereas Project compatibility and development guidance
  require 1.13. The root resource docstring also describes an installed SDK.
  Align current guidance and guards with the selected dependency/runtime model;
  keep dated evidence and old sealed deployment instructions historically scoped.
  Confidence: high. The version guard mismatch is redundant/inaccurate guidance,
  not proof that Pkg admits Julia 1.12 against the current compatibility bound.

## Product boundary requiring a decision

**NEC-06 remains a scope choice.** The root eagerly includes ConfigurationStore,
Analysis, SimulatorConfiguration and ManagementCLI. The catalog imports SQLite
and DBInterface; Analysis includes finite capture/publication; simulator tools
include settings, rebuild jobs and management protocols. These have real callers
and selected contracts. Consider separating optional workstation tooling from the
session package's mandatory load/dependency closure. That alone moves maintenance
rather than deleting it; retire unwanted features explicitly before claiming a
net reduction. The artifact catalog is distinct from the retired session journal.

## Recommendation and evidence limits

Do NEC-07/08 as a bounded cleanup, then transfer measured influence calculations
first: it has one numerical dependency to remove and a clear retained admission
boundary. Transfer the detector node separately, then address the Classic capture
product. Decide optional workstation scope before refactoring those modules.

Rechecked the prior findings against current definitions and callers, package
includes/dependencies, architecture and the two local instrument worktrees.
The code-quality scanner prioritized inspection; file length and mutable storage
were not treated as defects. No additional large subsystem was proven safely
dead. This is a bounded source review, not an exhaustive downstream/public-API
audit or runtime/numerical/hardware qualification. Only review documentation
changes; future implementation requires focused receiving-package and integration
checks. No runtime tests or live services were needed for these source findings.
Documentation checks pass 730 assertions for local targets, new anchors,
requirement-ID preservation, fences and whitespace; existing historical broken
links are unchanged (`/tmp/rtc-scope-followup-doc-checks-20261106.log`).
