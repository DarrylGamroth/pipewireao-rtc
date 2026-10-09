# RTC package boundaries

Inventory date: 2026-10-08. Starting source: `b345823`, clean `main`.
Implementation worktree: `/tmp/pipewireao-rtc-package-boundaries-20261008`, branch
`work/rtc-package-boundaries-20261008`. The package remains `PipeWireAODeployment`.
This inventory supports [the migration plan](JULIA_RTC_STRUCTURE_PLAN.md);
current delivery status remains in [the roadmap](roadmap.md#current-work).

## Source ownership and destinations

“Shared” means reusable across independently configured instrument projects.
“REVOLT project” is a migration destination, not an existing new repository.
Its name/location is pending selection. HEART source remains unchanged.

| Current source group | Destination | Work needed |
| --- | --- | --- |
| Common, Placement, SystemdOwners and its unit helpers | Shared package | Preserve literal unit rendering, exact process ownership and bounded cleanup; supply placement from project/site configuration. |
| RuntimeExport | Shared package | Base-only file-copy helpers; caller supplies explicit relative entries. Extracted in this increment. |
| Native control/session and owner bootstrap clients/codecs, RunnerCommands | Shared package | Retain native v1 contracts, fresh selection, correlation and unknown-outcome behavior. |
| Native acquisition lifecycle/action clients/codecs | Shared calibration support | Retain typed owner contract; separate driver from instrument capture/analysis rules. |
| WirePlumberSessionRuntime | Shared session tools | Preserve one-shot systemd preparation and native requests; no persistent coordinator. |
| ScienceExport | Split | Generic parameter descriptions, payload validation and configuration serialization stay shared. Classic parameter lists and fixed host defaults belong to REVOLT/site configuration. File-copy helpers now live in RuntimeExport. |
| DeploymentConfiguration | Split | Generic file/process/placement validation stays shared. Selected owner-profile rules, instrument argv checks and installed scientific entrypoints require adapter/resource separation. |
| HILExport, CalibrationExport | REVOLT integration plus extracted generic helpers | Currently select Classic/Copper geometry, graph labels, scientific packages and ports. Keep algorithms in AOS/HIL, AOC, JFG and FGN; adapters compose their APIs. |
| CalibrationCampaign | Split | Acquisition driving becomes shared. Detector extents/channels, lamp preparation, coordinate conventions, stage artifacts and analysis commands belong to REVOLT recipes. |
| HeartConfiguration/Export/Owner/CalibrationExport/ClassicTransfer/CorrectionExport; native HEART client/codec | REVOLT HEART adapter | Move bridge configuration and client support together; retain unchanged external HEART and explicit native-profile compatibility. |
| CopperReference, CalibrationMethod, CopperQuality | REVOLT recipes/analysis | Use AOC methods; preserve existing scientific acceptance failures and measured-unit conventions. |
| deployment/hil models, instrument entrypoints and exported scientific environments | Instrument project, or existing owning science package where already generic | Avoid mandatory CUDA/AOS/JFG/AOC dependencies in operational tools. Inventory entrypoints before transfer. |
| GUI view TOML | Instrument project | Optional input to the independent GUI; not a graph definition or headless dependency. |
| GUI-used native Rust client closure | GUI native adapter | Relocated and independently reviewed in GUI `d193254`; headless RTC Cargo dependency removed. Remaining RTC Rust retirement belongs to the extraction phase. |

## Caller and resource constraints

- [The package includes](../deployment/julia/src/PipeWireAODeployment.jl) currently
  load generic and instrument modules together. Extraction is incomplete.
- [HIL](../deployment/julia/src/hil_export.jl),
  [calibration](../deployment/julia/src/calibration_export.jl) and
  [HEART](../deployment/julia/src/heart_export.jl) exporters call the same
  `ScienceExport.copy_deployment_runtime`. Preserve this entrypoint while
  changing its implementation.
- [Deployment configuration](../deployment/julia/src/deployment_configuration.jl)
  imports ScienceExport. Calling configuration “generic” before removing that
  instrument/resource dependency would leave a misleading boundary.
- [The campaign](../deployment/julia/src/calibration_campaign.jl) invokes the
  exported `bin/rtc-calibrate` entrypoint for interaction acquisition. Fresh
  exports now use the shared [Julia driver](JULIA_CALIBRATION_ACQUISITION.md);
  old sealed packages retain their Rust executable. Instrument capture and
  scientific analysis remain separate migration work.
- [Export tests](../deployment/julia/test/test_exports.jl) include modules in an
  isolated namespace and stub integration services. Preserve those bindings
  while adding shared modules; package imports alone are not the entire closure.
- Installed resource discovery uses package-relative `assets/deployment` and
  supports relocated SDKs. Existing sealed SDKs remain immutable; changed exports
  get new source hashes/provenance.

## First implementation increment

The old runtime exporter recursively copied the entire Julia package root.
An unrelated build-file probe was exported before the fix. The same probe is
excluded after the fix. Runtime source export now selects existing Project,
Manifest, source/test directories, required entrypoints and the two legacy host
assets explicitly. Top-level deployment entrypoints are also an explicit list.
Installation validation and campaign provenance use those same declarations.

`RuntimeExport` contains file-copy helpers and copying of caller-declared entries.
It has no science, instrument or operational package dependency. Existing
`ScienceExport.copy_file/copy_tree` bindings remain the same functions, preserving
callers. The selected `src`, `test`, `hil` and `templates` directories remain
recursive closures during migration; this increment does not claim that every
selected SDK is already free of instrument code. Extra top-level repository,
build, unrelated-instrument or GUI directories are not selected.

See [the validation record](validation/runtime-export-20261008/README.md).
Qualification for this increment is software/package validation: explicit entry
selection, symlink/escape/overlap rejection, installed re-export and relocation,
plus the existing Julia tooling suite. It changes neither algorithms nor live
session authority and establishes no new numerical, allocation or latency result.
