# RTC package boundaries

Inventory date: 2026-10-08. Starting source: `b345823`, clean `main`.
Implementation worktree: `/tmp/pipewireao-rtc-package-boundaries-20261008`, branch
`work/rtc-package-boundaries-20261008`. The package remains `PipeWireAODeployment`.
This inventory supports [the migration plan](JULIA_RTC_STRUCTURE_PLAN.md);
current delivery status remains in [the roadmap](roadmap.md#current-work).

## Source ownership and destinations

“Shared” means reusable across independently configured instrument projects.
The selected independent instrument package is `REVOLTRTC`, in sibling
`REVOLTRTC.jl`. It owns Classic and Copper integration. HEART source remains
unchanged. This destination is separate from the shared repository and does not
require the GUI.

### Extraction contracts

- Keep the shared `PipeWireAODeployment` package name and UUID. Its root
  `Project.toml`, `src/`, `test/` and package-relative `assets/` replace the
  nested package. Retain native protocol records under `test/data/`.
- Keep public native v1 IDs and field types, including existing acquisition
  instrument IDs. Package separation does not authorize protocol changes.
- Export shared and instrument Julia projects separately (`julia/` and
  `revolt/`). Resolve the instrument dependency on the shared project before
  sealing. Operational wrappers load the shared project; instrument wrappers
  load `REVOLTRTC`. Each package declares and validates its own closure.
- Retain the shared parameter type and inert helper bindings. Instrument
  staging has a local forwarding function so isolated test substitutions cannot
  modify the shared WirePlumber staging function.
- Compose source evidence from both packages using distinct `julia/` and
  `revolt/` prefixes. Preserve containment, file hashes and relocation checks.
- Old sealed SDKs retain their files and original launchers. Only fresh exports
  use the new project layout. WirePlumber and systemd ownership is unchanged.

| Current source group | Destination | Work needed |
| --- | --- | --- |
| Common, Placement, SystemdOwners and its unit helpers | Shared package | Preserve literal unit rendering, exact process ownership and bounded cleanup; supply placement from project/site configuration. |
| RuntimeExport | Shared package | Base-only file-copy helpers; caller supplies explicit relative entries. Extracted in this increment. |
| Native control/session and owner bootstrap clients/codecs, RunnerCommands | Shared package | Retain native v1 contracts, fresh selection, correlation and unknown-outcome behavior. |
| Native acquisition lifecycle/action clients/codecs | Shared calibration support | Retain typed owner contract; separate driver from instrument capture/analysis rules. |
| WirePlumberSessionRuntime | Shared session tools | Preserve one-shot systemd preparation and native requests; no persistent coordinator. |
| ScienceExport | Shared and REVOLT | Generic parameter descriptions, payload validation and configuration serialization stay shared. Classic parameter lists and fixed host defaults are in REVOLT. File-copy helpers live in RuntimeExport. |
| DeploymentConfiguration | Shared validation with REVOLT preflight | File/process/placement validation and native v1 owner-profile compatibility stay shared. REVOLT Installation additionally validates its source closure, identity and installed entrypoints before startup. |
| HILExport, CalibrationExport | REVOLT integration | Select Classic/Copper geometry, graph labels, scientific packages and ports. Algorithms remain in AOS/HIL, AOC, JFG and FGN; adapters compose their APIs. |
| CalibrationCampaign | REVOLT recipes and shared acquisition | Acquisition driving is shared. Detector extents/channels, lamp preparation, coordinate conventions, stage artifacts and analysis commands belong to REVOLT recipes. |
| HeartConfiguration/Export/Owner/CalibrationExport/ClassicTransfer/CorrectionExport; native HEART client/codec | REVOLT HEART adapter | Move bridge configuration and client support together; retain unchanged external HEART and explicit native-profile compatibility. |
| CopperReference, CalibrationMethod, CopperQuality | REVOLT recipes/analysis | Use AOC methods; preserve existing scientific acceptance failures and measured-unit conventions. |
| assets/deployment/hil models, instrument entrypoints and exported scientific environments | REVOLT integration and existing science owners | Separate scientific environment; no mandatory CUDA/AOS/JFG/AOC dependencies in operational tools. Generic parameter-source resource stays shared. |
| GUI view TOML | Instrument project | Optional input to the independent GUI; not a graph definition or headless dependency. |
| GUI-used native Rust client closure | GUI native adapter | Relocated and independently reviewed in GUI `d193254`; headless RTC Cargo dependency removed. Remaining RTC Rust retired in `3101c5a`. |

## Caller and resource constraints

- [The package includes](../src/PipeWireAODeployment.jl) load only shared
  modules. The independent `REVOLTRTC` package includes instrument modules.
- [HIL](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/src/hil_export.jl),
  [calibration](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/src/calibration_export.jl) and
  [HEART](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/src/heart_export.jl) exporters call the same
  `ScienceExport.copy_deployment_runtime`. Preserve this entrypoint while
  changing its implementation.
- [Deployment configuration](../src/deployment_configuration.jl)
  imports shared ScienceExport. Existing native v1 profile identifiers and
  owner argv compatibility rules remain protocol contracts; this split does not
  change those IDs. Instrument startup additionally uses REVOLT Installation.
- [The campaign](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/src/calibration_campaign.jl) invokes the
  exported `bin/rtc-calibrate` entrypoint for interaction acquisition. Fresh
  exports now use the shared [Julia driver](JULIA_CALIBRATION_ACQUISITION.md);
  old sealed packages retain their Rust executable. Instrument capture and
  scientific analysis reside in REVOLT with their separate scientific environment.
- REVOLT export tests include modules in an isolated namespace and stub
  integration services. Its local staging wrapper preserves those bindings
  without extending the shared staging function.
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

## Independent project extraction

The root shared package and independent REVOLT package have separate runtime
inventories and dependencies. Fresh SDKs retain `julia/` for shared tools and
add `revolt/` for instrument tools, with a resolved relative dependency before
sealing. Provenance covers both source roots. Installed re-export and relocation
checks include both projects. Existing sealed SDKs remain unchanged.

See [the split record](validation/julia-instrument-split-20261008/README.md).
Affected installed live qualification remains a separate migration gate.
