# Frozen native preparation helper review

2026-10-06. Independent bounded source review of the three helpers retained at
RTC `f51cc3a632ed95db857ec4db456ddd5e0431ce87`, under
`docs/validation/integrated-gates-review-20261006/preparation`. Reviewed against
the maintained HIL/HEART exporter APIs and strict deployment admission. No
production edit, build, test, SCI or dependency change was performed. CPU15 was
used only for read-only hashes. Canonical GUI documentation was untouched.

**Disposition:** approved for the selected frozen inputs and previously planned
cohorts. No confirmed helper defect or new execution obligation was found.

## Findings by helper

- `prepare_cuda_observation_cohort-20261006.jl` requires strict native source
  admission, verifies source seals and refuses an already observed reference.
  It retains scientific implementation/calibration/plant bytes. Explicit source
  changes are full 256-frame recording, 256 exchanges and 10 Hz wall pacing;
  actual inspected descriptors retain 500 Hz model cadence, original exposure,
  CUDA and native bootstrap/control bindings. The enabled cohort adds the exact
  maintained capacity-one copy/drop-oldest queue and separate observer-loop
  recipe. Required scientific modules remain; only the required loop class is
  adjusted as in that recipe. CPU14 observer placement matches the inspected
  core affinity. Derived service files are regenerated, artifacts resealed and
  final strict profile/install admission required.
- `export_native_cuda_heart-20261006.jl` passes explicit
  `simulator_backend="cuda"` to the existing public HEART exporter. That exporter
  checks the selected base backend before export; this avoids its CPU default
  changing the intended admission. The helper selects the existing instrument
  configuration/vendor source and delegates native lifecycle/seal generation
  and installation to the maintained APIs. No vendor or scientific patch is
  introduced by this helper.
- `prepare_native_recorded_gui_fixture-20261006.jl` confines legacy admission to
  the historical recorded input with no external owners. It refreshes deployment
  runtime, explicit runner and source SDK, binds the existing FITS input and
  deliberately matches the primary human label. Protected graph/calibration
  bytes are checked, then the output is resealed and admitted in strict default
  mode before install. Fresh UUID/incarnation remain runtime identity. The
  installed GUI harness separately enforces non-actuating authority. This peer
  is a discovery/control fixture, not a second AOS or an algorithm comparison.

## Independent seal checks

The retained proof descriptor hashes match actual installed files. All declared
artifacts were independently hashed, with zero mismatches and zero protected
declaration changes: **579** Classic FGN disabled, **579** Classic FGN enabled,
and **710** Copper JFG disabled. The protected sets contain 578, 577 and 709
files respectively; the optional core change is explicitly excluded only from
the enabled protected set.

Helper/proof hashes and exact installed paths are recorded in the
[preparation receipt](validation/integrated-gates-review-20261006/preparation-review.json).
This is cold preparation acceptance. Actual native admission, optional-observer
progress, full trajectory/reset equivalence and owned shutdown remain the
already planned installed gates; no zero-allocation or timing result follows.
