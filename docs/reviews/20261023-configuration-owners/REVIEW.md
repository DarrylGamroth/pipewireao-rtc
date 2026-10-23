# Configuration ownership review — 2026-10-23

Scope: RTC source `8215cf2` and instrument source `c7e71f5`, reviewed in dedicated
`codex/configuration-owners` worktrees. Neither source had pre-existing edits.
The review used a separate Sol worker with read-only ownership and temporary CPU
copies. No managed session, physical device or GPU was opened by validation.

## Findings and dispositions

| ID | Severity / confidence | Evidence and disposition |
| --- | --- | --- |
| CFG-01 | P2 / confirmed | Simulator startup could override the RTC calibration identity while recomputing expected publication. A temporary CPU probe accepted an old wrapper after only the authoritative RTC identity changed. Fixed: publication has no identity override, startup checks the current RTC identity, and refreshed publication alone cannot authorize a stale wrapper. |
| CFG-02 | P2 / confirmed | PDM command limits and calibration recipe repeated the RTC mirror-control limits. A ±0.2 edit changed publication while enforcement remained ±0.8. Fixed: both consume `/rtc/deformable_mirrors/<id>/limiter` references, preserving scalar or per-actuator values. |
| CFG-03 | P2 / confirmed | Calibration conversion and rewrite assumed scalar limits after vector bounds became referenceable. Fixed: shared typed validation preserves scalar/vector representation; rewriting updates the selected RTC mirror controls and publication, and numerical validation checks actuator bounds individually. |
| CFG-04 | P2 / confirmed | Calibration publication calls used a default RTC path despite supporting an alternate authoring path. Fixed: declared paths and exporter defaults propagate consistently. |
| CFG-05 | P3 / confirmed | Atmosphere stepping repeated the simulation cadence as a literal. Fixed: graph stepping and wrapper rate derive from the simulation definition. |
| CFG-06 | P2 / confirmed | The new limit validator initially admitted equal bounds although publication requires strict lower < upper. Fixed before integration: reject equal or precision-collapsed bounds before writing output. |

No scientific algorithm, gain, default sampling, actuator order, pupil
registration, calibration input or measured artifact was intentionally changed.
Analytic basis recipes and custom FITS matrices belong to RTC control YAML;
resolved publication remains schema 2 for existing generic GUI consumers.

## Validation boundary

Focused schema/export/reference checks, independent CPU regression probes and
instrument selectors cover ownership and stale-data rejection. Complete resolved
production/calibration graph comparisons against the pre-change source cover the
two Gaussian profiles. CPU first-frame execution is distinct from hardware,
GPU, sustained cadence and real-time qualification. Commands and final selector
results are retained in the instrument repository's `MIGRATION.md`.

Final targeted review found no remaining actionable findings. RTC selectors
passed 62 schema, 132 export, 40 graph-reference and 36 SH/Pyramid CPU-product
assertions. The separate review probe passed 11 identity/limit/cadence assertions;
a typed command-limit probe passed 7 malformed/scalar/vector checks. Instrument
selectors include 57 configuration and 141 calibration assertions, including
rejection of equal limits before any application byte changes. Final instrument
configuration/calibration/comparison runs were warning-free; intermediate cache
warnings during concurrent edits are retained in the migration record.
