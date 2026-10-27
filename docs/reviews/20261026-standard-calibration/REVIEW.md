# Standard calibration: source review

Reviewed on 2026-10-26. No blocking source-review finding remains in the reviewed
implementation. Completion of the fresh acquisition, validation, staging and
rebuild workflows remains a separate primary validation gate. The maintained
[validation record](../../validation/standard-calibration-20261026/README.md)
records that gate and its final scope.

## Cohort and independence

- RTC: branch `codex/standard-calibration`, base
  `6c9c21ed2c880880e946698d0958580fef768c9a`, worktree
  `/home/dgamroth/workspaces/codex/worktrees/rtc-standard-calibration-20261026`.
- Instruments: branch `codex/standard-calibration`, base
  `02a50bf5f22b0083fdf0572b852e8a526c95162d`, worktree
  `/home/dgamroth/workspaces/codex/worktrees/instruments-standard-calibration-20261026`.
- Review covers the working changes in the bundle/recipe contracts, shared
  sensor procedures, typed startup/staging, instrument recipes/templates and
  replacement CLI paths. Existing acquisition/native protocols are outside this
  change. Both dedicated worktrees were inspected before review; no unrelated
  edits were discarded.

The reviewer independently assessed the implementation and reported findings
before remediation. At the primary agent's later request, the reviewer also
performed the bounded instrument-data migration described below. That migration
is an implementation contribution, not independent approval of the reviewer's
own changes. The primary agent owns its separate diff inspection, data-contract
tests and final pipeline validation.

## Scientific and lifecycle assessment

The Shack–Hartmann procedure preserves the original monorepo calibration's flat
reference/validity measurement, central completion, positive/negative probe
order, interleaved slope ordering through `vec(permutedims(slopes))`, AOC
`ZonalPushPull` construction and TSVD inversion. The metre probe is divided by
the instrument command conversion before forming the interaction matrix. For
Classic, 10⁻⁸ m / 10⁻⁶ m per wire unit gives the previous 0.01 wire-unit probe;
the plant still receives the probe in metres. No extra surface-to-OPD factor,
gain change or HEART-completion fallback was introduced. The controller and
physical limit semantics remain unchanged by preserving authored limits in
Float64 before their existing Float32 runtime conversion.

The pyramid procedure's pupil normalization, pupil-RMS weighting, fitted
tip/tilt coupling, modal projections and AOC inversion are unchanged. Its
implementation now uses private sensor dispatch and the common writer. Typed
bundle startup is shared with validation and staging, including explicit FITS
aliases and complete parameter coverage.

`read_recipe` requires the built application, rejects stale authoring and
checks that the retained `graph_source` resolves to the compiled `graph` using
the selected RTC context. Resolved template and execution paths must differ,
which prevents publication from overwriting an aliased retained template.
Calibration hashes the retained template, while
staging resolves it again against the candidate context. After checking that
resolution against the verified bundle, staging copies the selected concrete
graph to the owned copy's compiled graph path before cold publication. The
retained template is preserved. This lets publication observe newly calibrated
dimensions and parameters before rebuilding the application. Shack–Hartmann
acquisition, replay and staging use the same merged startup settings for
prescription identity checks.

Fresh bundle publication and staging use owned sibling temporary directories
and publish only after integrity and typed-startup checks succeed. Failure
cleanup removes owned staging. Public calibration/validation destinations must
be fresh and outside their inputs. No validation path starts a PipeWire core,
contacts the desktop core or installs an application.

The final staging contract takes authored source, its built application,
calibration bundle and fresh destination separately. It rejects a built
application in the source role. Raw source/application recipe equality,
template hashes and localized optical-prescription identity under acquisition
settings bind the authored source to the verified application and receipt.
Only the authored source is copied, so native shared-runtime templates, merged
session products and compiled YAML outputs from a build never enter the
staged source. There is no three-argument fallback or uncompile operation.

## Adjudicated findings

All findings below were confirmed against the implementation, rather than
inferred from successful builds. Severity describes the defective intermediate
state; dispositions describe the reviewed final source.

| ID | Severity / confidence | Evidence and effect | Remediation and disposition |
| --- | --- | --- | --- |
| SC-01 | High / observed | Classic startup aliases such as `shape-active-to-full` did not have same-named FITS files. A stem-only bundle contract rejected the preserved calibration. | Explicit `parameter_files` maps each runtime port to a hashed artifact. Reader, typed startup and staging use the mapping. Fixed. |
| SC-02 | High / observed | The extracted Shack–Hartmann validator referenced unimported `graph_output` and `mean`; it would fail on the first measured frame. | Uses `HIL.graph_output`, explicit reductions and host arrays for pupil-mask indexing. Fixed. |
| SC-03 | High / observed | Staging initially trusted the receipt recipe while preserving independently editable source authoring; resolved graphs also lost the references needed to regenerate calibration dimensions. | Canonical authored/compiled recipe equality, required retained `graph_source`, template/compiled equality and template-based staging. Fixed; full workflow remains a validation gate. |
| SC-04 | Medium / observed | Classic's acquired graph serialized widened Float32 limits as ±0.800000011920929 while the source context retained ±0.8. Exact graph reconstruction failed. | Validate/serialize the existing authored limits in Float64; runtime conversion remains Float32. Fixed. |
| SC-05 | High / observed | Classic's graph had 19 parameter ports but only 18 startup bindings because physical shape offset used the scientific owner's neutral default. Relaxing coverage would also permit accidental omission of calibrated arrays. | Preserve exact coverage and materialize the verified neutral Float32 physical offset. Both imported and newly generated Classic bundles cover all 19 ports. Fixed. |
| SC-06 | High / observed | Imported GPI calibration graph exposed 27 parameters, whereas selected startup bindings included four later shape-projection aliases. Its current graph also required two neutral physical offsets. | Explicit packaging adoption of the currently selected graph, two neutral offsets and preservation of the original graph under `history/graph.conf`. Typed startup covers all 33 ports. Fixed; primary independently verifies the migration. |
| SC-07 | High / observed | Formatting GPI context bytes invalidated `context_sha256`; independent `read_bundle` failed. | Refresh the receipt after canonical formatting and update the selected RTC receipt identity. Independent cold read then passed. Fixed. |
| SC-08 | Medium / observed | Hidden-mode derivation retained a separate raw receipt reader; pyramid validation initially ignored the new artifact mapping. | Hidden-mode input goes through `read_bundle`; pyramid validation uses the shared typed bundle loader. Fixed. |
| SC-09 | Medium / observed | Fresh outputs could be placed inside an input application or bundle. | Public output guards reject nested destinations. Fixed. |
| SC-10 | Medium / observed | A focused completion test still called the removed modal public API; instrument tests still read removed recipe-owned limits. | Test the private sensor rejection directly and read limits from RTC authority. Fixed. |
| SC-11 | High / observed | Staging a built tree retained compiled runtime YAML and failed the exporter's fresh-destination check. A second rebuild showed that deleting those files still retained rendered shared-runtime templates and merged session lists. | The cleanup attempt was superseded. Final four-input staging copies explicit authored source, verifies its raw recipe/template and localized acquisition prescription against the built application/bundle, then installs only the selected calibration products. Built source inputs are rejected; the three-argument method is removed. Reviewed against source export ownership. Fixed in source; primary Classic authored-source restaging and registered rebuild passed. Primary GPI 1,509-coordinate acquisition, four-case validation, 33-binding authored-source staging and registered rebuild subsequently passed; details remain in the validation artifact. |

Historical imported receipts deliberately retain their acquisition recipe and
source identities. They support integrity and selected startup checks, but are
not automatically rebound for the new acquisition/validation/staging sequence.
The documented requirement to acquire a new bundle is an accepted scope
boundary, not a compatibility fallback.

## Observed evidence

- The reviewer independently ran the cold bundle selector: 68/68 assertions
  passed, covering integrity rejection, frozen-history hashes, publication and
  failure cleanup. Cold reading both imported bundles loaded no CUDA, AMDGPU or
  GPUCompiler modules.
- The reviewer inspected `shared-focused.log`: 415/415 bundle, modal I/O and
  completion assertions passed. `calibration-unit-final.log` showed 156/156
  instrument calibration assertions before the final additional recipe checks.
  Later gate results belong in the linked validation record.
- Independent exact typed startup passed for the migrated root bundles:
  Classic 19 parameters / 23 artifacts; GPI 33 parameters / 32 artifacts. Alias
  bindings explain why GPI has more ports than artifact files.
- All 52 pre-existing Classic/GPI calibration artifact FITS files and the three
  original historical receipts were compared byte-for-byte with the instrument
  base. They were preserved. The migration added three known neutral Float32
  offsets: Classic 277, GPI woofer 97 and GPI tweeter 2304 elements. The original
  GPI graph remains byte-identical in history, with SHA-256
  `9e2044c1eb6a5e25b26e417b97aa2cfaadd260f363e1910137ad632e03e2abf8`.
- The reviewer observed the intermediate GPI context-hash rejection, then a
  successful cold-read retry after the corrected receipt. The Classic graph
  mismatch was independently reduced to the widened Float32 limit values.
- Both source diffs passed `git diff --check`. Migration-owned YAML passed
  standalone yamlfmt checks.

The original graph-reference selector already produced 9 passes, one failure
and one error; the primary reproduced the same baseline in the unmodified
checkout and the worktree. The pre-existing exact Float32 completion comparison
also differed by at most 4.656613 × 10⁻¹⁰; the primary retained affine/rank checks
and bounded the comparison with `eps(Float32)`. These are recorded baseline
observations, not calibration-regression evidence.

This source review and finite CPU software evidence do not qualify physical
actuators, measured hardware calibration, GPU numerical behavior, deadline
latency, sustained cadence or arbitrary closed-loop stability. No such claim is
made by this review.
