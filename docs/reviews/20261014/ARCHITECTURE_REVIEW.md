# Headless RTC package and application architecture review

Date: 2026-10-14. Reviewer: independent Astra architecture pass. Status: review complete; findings and design recommendations are **proposed**, pending primary-agent/user adjudication. No production code changed. No tests, Julia sessions, services, or benchmarks were run.

## Decision summary

The useful shared product is **PipeWireAORTC**: Julia configuration validation, one-shot installation and native session clients, reusable scientific-owner entry points, and calibration acquisition clients. Its boundary is coherent if WirePlumber Lua remains the sole session/admission authority, systemd remains process supervisor, and scientific algorithms stay with FGA/JFG/AOS/AOC. The name change is appropriate but insufficient: present deployment generation still copies SDK source, uses path dependencies, reads packed binary artifact files, and requires instrument-specific executable glue.

A small instrument application should contain Project/Manifest, native RTC graph/session configuration, a simulation graph when selected, and FITS artifacts. Optional GUI views and derived reports may accompany it but must not be launch requirements. Package source belongs in Julia's resolved dependencies; native runtime binaries belong in a separately versioned installation/artifact closure. Runtime-generated unit files, admission records and decoded memory are distinct from the authored application.

Do **not** register REVOLTClassicSim as the solution to package resolution. Move Classic presets, geometry and ordering into configuration/FITS; reuse AOS model operations. Do register the reusable dependency closure through the user's LocalRegistry. AOC is already present at 0.17.0. Combining the two transport adapters into PipeWireAO extensions is feasible but is not necessary to obtain this deployment model; preserve their conceptual interfaces and defer physical consolidation until the callable parent API and compatibility tests are specified.

## Baseline and authority

Paths below are relative to these roots unless otherwise stated:

| Alias | Root | Observed branch / HEAD |
| --- | --- | --- |
| RTC | `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc` | main / `f7777e8154f9593b793edb50b5162df05161b9aa` |
| REVOLT | `/home/dgamroth/workspaces/codex/pipewire/REVOLTRTC.jl` | main / `9c3e51ce6d943719ffa9aec180f18b34cfb26a1b` |
| JFG | `/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph.jl` | main / `97ead7c36ba0ee69e548164ca7a719658ff6968c` |
| HIL | `/home/dgamroth/workspaces/codex/AdaptiveOpticsSimPipeWireHIL.jl` | main / `2c15a9f062532e43b69076429465482f4297a0e9` |
| GUI | `/home/dgamroth/workspaces/codex/pipewire/pipewireao-gui` | main / `566b521a49c5f12faddb4c48d884c7c67fa1d7a2` |
| Classic | `/home/dgamroth/workspaces/codex/REVOLTClassicSim.jl` | `e0fbdab9a5483d92fa6df5539019624d40b84f1e` |
| Review | `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-astra-review-20261014` | review worktree at RTC HEAD |

The review read actual working files. RTC has modified README and package entry point plus untracked `src/native_source_control.jl`. REVOLT has modified `assets/deployment/hil/simulator_owner.jl`, `test_owner_loop.jl`, `test_source_control.jl`, and deleted `source_control.jl`. JFG has modified deployment runner/tests/docs, FGA declarations/results, FGPW project/main/graph/tests, JFG latest-hold, Spiders project/module/tests; untracked FGPW extension and borrowed-alias test, Spiders SCC files, benchmark caches and `gmon.out`. HIL has modified README/module/calibration/exchange/tests plus untracked acquisition source/test. GUI has modified `docs/workstation-review.md`. Classic has modified Project/README and pyrtc/test files plus untracked test Project, AOC integration test and benchmark result. These changes were preserved; source conclusions do not imply any of them are in a registered release.

The shared task scope and initial dirty-file hashes are recorded in [SCOPE.md](SCOPE.md). Review branch: `codex/rtc-astra-review-20261014`.

Authorities read: repository AGENTS files, RTC task index, current roadmap, selected architecture/configuration/ownership clauses, package boundary inventory and structure proposal; GUI development contract; HIL and Classic ownership guidance. Applied `review-julia-package-design` and `audit-code-slop`, including their review references. A mechanical hotspot scan inspected 52 RTC/REVOLT source files and emitted 442 signals; these were triage prompts, not findings. Its approximate Julia function boundaries are not authoritative. No authorship inference was made.

User-selected constraints override older source-copy deployment and instrument-package assumptions in the historical documents. RTC-ARCH-025 remains controlling. This report does not re-audit the mathematical algorithms, prove concurrency correctness, or revise protocol IDs.

## Findings

Severity: P1 blocks the requested application/deployment outcome; P2 is a concrete integration or maintainability problem; P3 is optional polish. Confidence is in the cited source observation, not an unperformed runtime experiment.

### AAR-01 — The exporter and installer require copied SDKs and local source overrides

**Severity P1; confidence high; classification observed, impact derived; disposition proposed.**

Evidence:

- RTC `src/science_export.jl:47` includes `src` and `test` in `RUNTIME_ENTRIES`; `:54–94` copies them to `julia/`, with resources.
- RTC `src/deployment_configuration.jl:396–438` requires copied package source, test entry points, package identity and resource files. Merely stopping the copy would make the installer reject the application.
- REVOLT `src/science_export.jl:24–28` adds another source/test/bin closure; `:35–69` copies it to `revolt/` and runs `Pkg.develop(path="../julia")`.
- REVOLT `src/hil_export.jl:787–808` emits `[sources]` paths for AOC, AOS, HIL, PipeWireAO, FGA and the plant; `:1330–1337` copies owner scripts and those packages into the deployment. `:860–885` binds the JFG environment to another copied PipeWireAO tree.
- RTC `Project.toml:1` still names PipeWireAODeployment; its `[sources]` pins PipeWireAO by Git revision. REVOLT's Project and Manifest pin a different committed PipeWireAODeployment revision (`1687b9f…`) from the reviewed RTC working tree.
- Local `DarrylGamrothRegistry/Registry.toml` lists AOC, PipeWireAO, FGA and JFG. AOC `Versions.toml` contains 0.17.0, tree `6d1fc92218133a4edfea1118cf35ce5dc1a48677`. The inspected registry does not list AOS, FGPW, HIL or PipeWireAODeployment.

Impact: the current “small project” would still depend on developer checkout/source-copy machinery, and the importer/installer explicitly treats copied code as deployment data. A Manifest alone cannot select uncommitted changes. Registering only the renamed top package leaves other missing packages unresolved.

Minimal remediation: release the required reusable dependency versions, including the working changes selected by adjudication; resolve application Project/Manifest from LocalRegistry without path overrides; replace source-closure validation with dependency identity and application/configuration/artifact validation. Keep old sealed SDKs executable with their existing launcher. Stop embedding tests/source in new applications. Record native PipeWire/WirePlumber runtime identity separately; moving Julia source out does not remove the native dependency requirement. Preserve explicitly qualified preferences such as the CUDA synchronization policy in REVOLT `hil_export.jl:824–857`, rather than dropping them while simplifying files.

Required validation: instantiate and cold-prepare the selected application in a fresh depot with only LocalRegistry and required native runtime available; inspect the resulting application for source trees, path dependencies and developer absolute paths; relocate the application and repeat. Verify exact scientific inputs and native protocol records are unchanged. Existing source-copy tests must be replaced by the new contract, not simply deleted: RTC `test/test_package.jl` currently explicitly expects copied tests and relocated SDK re-export.

### AAR-02 — FITS is an authoring input, but raw files remain the mandatory runtime representation

**Severity P1; confidence high; classification observed, impact derived; disposition proposed.**

Evidence:

- REVOLT `src/artifact_files.jl:154–198` copies `original.fits`, decodes it, then calls `write_payload` at `:181` to create the packed file. `:132–143` encodes row-major little-endian bytes.
- RTC `src/science_export.jl:15–28` defines `Parameter` with a mandatory `file::String`; `:110–126` validates a raw file by expected byte size and element type.
- JFG `deployment/startup.jl:14–21,53–80` represents startup parameters by raw-file paths, reads their bytes and converts row-major layout to logical Julia axes. `deployment/run_island.jl:29–31` exposes that requirement in the CLI.
- RTC `src/native_parameter_source.jl:475–489` receives a parameter file path and reads raw bytes before publication. Thus changing only cold authoring would leave the live parameter path unchanged.
- REVOLT `scripts/classic_template.jl:368–372` exports a FITS baseline and immediately prepares the packed replacement.

Impact: deleting `.u8`/`.f32le` files from the application currently breaks startup and/or update paths. The FITS layer does not meet the requested direct-to-memory deployment boundary.

Minimal remediation: retain the existing FITS validation rules but return a prepared array/payload with owned storage and provenance rather than a filename. Keep source selection (relative FITS path, HDU, explicit axis permutation, optional units/schema expectations) distinct from prepared in-memory data. Decode during cold owner preparation before readiness, bind arrays through scientific package APIs, and encode transport storage only in memory. Avoid fitting FITS into `Parameter.file` by pretending it is already a raw payload. For FGN, use an existing validated in-memory parameter path if its selected host exposes one; otherwise add that narrow owner/host capability before claiming FGN parity. Do not invent a new graph parser.

For live updates, preserve the native v1 path command unchanged for old clients. A new FITS-backed staging route must have an explicit compatibility decision: either the owner resolves an admitted FITS selection under a versioned public operation or a cold registered helper prepares a memory-backed publication handle. Do not silently reinterpret the v1 filename as arbitrary FITS plus guessed HDU/axes, and do not hide persistent raw files in another directory.

Required validation: identical logical arrays and transport bytes for representative nonsquare images/matrices, square matrices with explicit axes, Bool and integer masks, FITS scaling, nonfinite/overflow rejection and unit/schema mismatch. Verify data lifetime across callback publication, startup/adoption sequencing, and no FITS I/O after admission in the repeated frame path. Verify both JFG and FGN plus live update/capture paths independently. Existing per-image byte bounds are not a demonstrated peak-memory bound.

### AAR-03 — Simulator ownership still depends on executable instrument packages and fixed geometry

**Severity P1; confidence high; classification observed, impact derived; disposition proposed.**

Evidence:

- REVOLT `assets/deployment/hil/simulator_owner.jl:43–54` imports REVOLTClassicSim or REVOLTCopperSim by profile; `:97–113` requires their graph helper and 277 commands, selects `shwfs_frame` versus `pwfs_frame`, and fixes detector shapes to 352×352 or 64×64. Recorder allocation at `:143–149` also assumes 277 commands.
- Classic `src/hsdm277.jl:20–43,54–66` encodes the actuator geometry/order as constants and executable generation; `src/hil.jl:1–43` similarly encodes telescope/detector preset values and the valid lenslet mask.
- Classic `src/graphs.jl:42–68,79–94` supplies array bindings and then calls AOS's graph preparation and HIL boundary APIs. AOS `src/algorithm_graphs/api.jl:14–35` already exposes reusable graph construction, DM/atmosphere/detector operations, loader and preparation APIs.

Impact: an instrument configuration cannot currently select another command extent, detector shape or boundary name without editing owner code. Registering REVOLTClassicSim would preserve precisely the application/package coupling the requested design rejects.

Minimal remediation: store exact Classic actuator index map, grid indices/coordinates and masks as FITS with ordering/unit/provisional-value provenance; place telescope/pupil/DM/detector presets and boundary names in the simulation graph/configuration. The reusable simulator owner accepts a prepared AOS boundary plus explicit transport configuration, deriving extents from validated declarations/buffers. Move genuinely reusable calibration graph transformations/diagnostics into AOS only after identifying their stable inputs; retain Classic-specific settings in configuration. Do not move the whole Classic module into AOS or silently substitute inferred/measured geometry. Apply the same rule to Copper when migrating its application.

Required validation: preserve exact actuator order and mask bytes, units and provisional labels; compare old and new prepared graph/boundary declarations and deterministic outputs for the same seeds and configuration; exercise at least one different detector extent and command count to show the owner is genuinely generic. CPU software evidence and GPU/model/system evidence remain distinct. This review did not validate scientific equivalence.

### AAR-04 — Cross-package source inclusion bypasses the package API and creates duplicate module identities

**Severity P2; confidence high; classification observed, type-identity consequence derived; disposition proposed.**

Evidence:

- REVOLT `assets/deployment/hil/native_owner_bootstrap.jl:5–18` searches an SDK source directory or `Base.find_package`, then includes five RTC source files into its own module.
- REVOLT `assets/deployment/hil/native_acquisition_lifecycle.jl:19–24` separately includes the envelope, client, endpoint, lifecycle and action implementations.
- The dirty `simulator_owner.jl:13` includes the relocated shared `native_source_control.jl` by source path rather than importing the loaded package binding.
- REVOLT `src/installation.jl:5` includes RTC's root `wireplumber_install.jl`; RTC `test/test_calibration_install.jl:3` exercises the same source include.

Impact: source filenames and relative module context become downstream APIs; loading the same source in separate enclosing modules creates distinct Julia types/generic functions. A refactor can break scientific owners despite unchanged package APIs, and method dispatch/type identity can diverge when include-loaded and package-loaded values cross. No actual cross-instance dispatch failure was run or claimed here. The cold bootstrap intent is legitimate: ownership must become observable before expensive scientific preparation.

Minimal remediation: expose a small cold owner/bootstrap API from PipeWireAORTC and import it normally; provide package-owned entry points for simulator/JFG/parameter owners. Keep expensive science/backend loading after cold bootstrap via deliberate entry-point sequencing or optional integration. Replace duplicate includes with shared bindings while preserving cold cancellation/readiness behavior. Do not replace the lifecycle endpoint with a Julia coordinator.

Required validation: all owner processes load the same named package modules; no external include of dependency `src/` remains in new paths; cold-start preparation cancellation and terminal retention tests continue to pass. Compare representative `typeof`/method dispatch across clients and owners after import changes. Measure cold preparation separately if import timing becomes a concern; source shape does not prove a latency regression.

### AAR-05 — The supported install/launch/configuration API lives outside the Julia package boundary

**Severity P2; confidence high; classification observed, impact derived; disposition proposed.**

Evidence:

- RTC `src/PipeWireAODeployment.jl:32–61` loads the source modules but does not include the four root `wireplumber_*.jl` modules.
- RTC `wireplumber_cli.jl:9–11` includes configuration/launch/install scripts and contains substantive publication, stop, discovery and control logic. `wireplumber_launch.jl:349` begins preparation; `:598` handles cleanup. These are reusable operational functions, not just command-line argument parsing.
- REVOLT's package-level `Installation.install` can call installation only by the source include in AAR-04.
- REVOLT `scripts/classic_template.jl:454–478` writes a recipe with the current absolute script filename, active project directory, base SDK path and deployment script path. Its “project” is consequently tied to the authoring checkout/environment.

Impact: installing the named Julia package does not provide a stable callable installation interface; callers must know repository paths. The generated user workflow remains a prepared SDK derivation procedure rather than a portable instrument project.

Minimal remediation: move implementation under `src/` and expose a small documented application API; keep executable files as thin argument/exit-code wrappers. Have the instrument application use that registered API with project-relative graph and artifact selections. Use explicit application/environment/configuration inputs rather than capturing `Base.active_project()` as future execution authority. Keep native session selection and destructive controls explicit; convenience must not infer a replacement session after an unknown result.

Required validation: install/validate/inspect/control entry points work from an unrelated working directory using only the resolved project; generated applications contain no authoring-checkout paths; CLI and Julia calls use the same implementation and retain exit codes/error semantics. Existing installed SDK wrappers remain compatible or explicitly use their old runtime.

### AAR-06 — The graph catalog depends on private prepared-layout details instead of a scientific introspection contract

**Severity P2; confidence high; classification observed, compatibility impact derived; disposition proposed.**

Evidence: REVOLT `scripts/graph_catalog.jl:96–121` requires private `PreparedNode` fields, extracts the declaration from `typeof(node).parameters[1]`, and accesses `PreparedAlgorithm.plan` by `getfield`. It correctly checks field presence and limits the reflection to this adapter. FGA public declaration/property functions are already used at `:70–92,122–129`. JFG's source export/public list has graph preparation and execution APIs but no corresponding prepared-node catalog API in the inspected module surface.

Impact: a scientifically equivalent internal type-layout change can break instrument authoring/catalog generation. Field presence alone does not establish semantics or the type-parameter position. This is a known temporary compatibility seam, not evidence that the current catalog is wrong.

Minimal remediation: add one narrow read-only scientific introspection API in FGA/JFG for instantiated node declaration, ports/formats and configured properties; the RTC adapter renders its result. Preserve defaults versus configured values and distinguish startup binding from live writability. Do not duplicate Algorithm declarations in RTC or introduce a second registration system.

Required validation: catalog output for existing graphs stays equivalent; add a consumer contract check through the public accessor and verify node order/names, properties, conditional outputs, layouts, schema and rates. Pin compatibility until the accessor is released; no promise of arbitrary old/new internal layouts.

### AAR-07 — The shared acquisition profile is still explicitly Classic/Copper-specific

**Severity P2 for general instrument support; confidence high; classification observed, generalization limit derived; disposition proposed.**

Evidence: RTC `src/native_acquisition_lifecycle_codec.jl:32–33` defines `Instrument::UInt32` with only `Classic=1` and `Copper=2`; `:59–75` requires that type in every acquisition Snapshot. REVOLT `src/calibration_export.jl:18–23` also selects capture budgets by Classic/Copper names.

Impact: the current acquisition protocol cannot represent an arbitrary new instrument merely by providing graphs and FITS. The fixed IDs are existing v1 compatibility, so removing or renumbering them as naming cleanup would be incorrect.

Minimal remediation: keep the v1 codec intact and clearly scoped. Decide whether the next instrument can use a generic existing acquisition contract or requires a new version/capability with declared boundary metadata. Derive memory/capture limits from validated formats and explicit budgets rather than instrument names. Avoid creating a new framework solely to make the enum extensible.

Required validation: frozen v1 records remain byte-compatible; rejection of unsupported identities stays explicit; any generic profile gets conformance tests in both Julia and the consuming WirePlumber/GUI implementations before use. This is a target capability gap, not a demonstrated defect in Classic/Copper operation.

## Package and extension adjudication

| Proposal | Review judgment | Reason and condition |
| --- | --- | --- |
| Rename PipeWireAODeployment to PipeWireAORTC | Accept direction | The package already contains runtime clients, acquisition and owner adapters as well as export. Coordinate Project/module/entry point/docs/callers and registry identity; a repository rename is optional. Preserve v1 wire names. |
| Single large RTC package with direct AOS/JFG/AOC/CUDA dependencies | Reject as default | The current operational Project deliberately has no science/GPU closure. Retain small cold clients and bootstrap; optional owner integration may depend on science. |
| Keep FilterGraphPipeWire as a registered adapter | Accept as initial migration | It has an established `PipeWireNode` API, array/layout projection, feedback and captured-graph contracts. Removing copied source only needs registration and callable owner startup. |
| Move FGPW into a PipeWireAO extension | Viable, conditional | Trigger on FGA/JFG; move implementation behind parent-owned public constructors/functions. Preserve borrowed-array Base contracts, captured replacement and ForwardDiff alias integration. Do not make callers depend on extension module names. |
| Keep AdaptiveOpticsSimPipeWireHIL as a registered adapter | Accept as initial migration | Its boundary is coherent: AOS preparation/model time, PipeWire endpoint mapping and correlation, and explicit prepared ownership. Registration is simpler than redesigning its public types immediately. |
| Move AOS HIL into a PipeWireAO extension | Viable, conditional | Trigger on AOS; keep optical operations and model-time meaning in AOS. Parent API must define how callers construct configuration and receive handles without requiring extension-defined public types. Preserve exposures, provenance and calibration transport APIs. |
| Merge both adapters into one undifferentiated integration layer | Reject | Graph execution adaptation and plant frame/command/exposure causality are different contracts. Shared low-level helpers can move to PipeWireAO when duplicated semantics are established; a common prefix is insufficient evidence. |
| Put RTC session/admission logic in PipeWireAO extensions | Reject | Would blur session authority and transport ownership. WirePlumber retains authority; RTC owners implement local requested actions. |
| Register REVOLTClassicSim | Reject for selected target | Its remaining value is instrument presets/artifacts plus reusable transformations; remove the runtime dependency as described in AAR-03. |
| Register AdaptiveOpticsCalibration | Already satisfied at 0.17.0 | Ensure the chosen release contains required APIs; registration does not imply the deployment uses it, because the current exporter overrides it with copied source. |

Consolidation tradeoff: extensions can reduce named adapter packages while keeping optional dependencies. They increase PipeWireAO's integration compatibility surface and can obscure type ownership if APIs only exist inside extension modules. Neither option is intrinsically more Julian. The migration should choose based on a concrete callable API and test responsibility, not the number of directories. The recommended order is stable registered contracts first, physical consolidation later. If consolidation is chosen now, treat it as its own reviewed dependency change rather than bundling it with FITS, owner extraction and rename.

Evidence supporting existing boundaries: FGPW imports `process!`, `reset!`, `replace_parameters!` and PipeWire lifecycle functions rather than reimplementing science (`julia/FilterGraphPipeWire/src/FilterGraphPipeWire.jl:20–29`). It supports more than the simple LeakyIntegrator constructor: prepared/captured graph constructors and callbacks live in `graph_node.jl:2295–2444,2612`. HIL's configuration explicitly defines frame encoding and command units (`src/configuration.jl:18–43`); its exported exposure/provenance/model-time interfaces are substantive, not forwarding aliases. Base `close` owns cleanup for both prepared HIL and calibration handles (`exchange.jl:1133`, `calibration.jl:742`).

## Current public surface and recommended ownership

The root RTC module exports no top-level names. The following are submodule exports or documented qualified APIs, not a claim that every accessible helper is public. Inventory is static; no runtime reflection or method-ambiguity check was performed.

| Current surface | Significant public names/contracts | Recommended ownership |
| --- | --- | --- |
| NativeControlCodec | ControllerIdentity, RequestHeader, ReplyHeader; request/completion/rejection encode/decode | Internal protocol layer, retain conformance corpus |
| NativeControlClient | Profile, Client, connect, request!, UnknownOutcome; profile traits at `:12–40` | Small documented native integration seam; don't expose every field |
| NativeControlEndpoint | Endpoint/ticket/retained-reply APIs used by owner runtimes | Owner support, package-imported |
| NativeRunnerCodec + NativeSessionCodec/Profile | RunnerCommand/Scalar/Result/Error, Completion/Rejection, lifecycle/outcome/group values; Warmup/Admit | Session protocol; preserve external operation IDs and legacy aliases |
| NativeSessionDiscovery | SessionRecord, Verification, DiscoveryEntry, FreshSessionStatus, SelectedSession; list/select/publish/remove records | Discovery/client seam, observed identity remains mandatory |
| NativeSessionClient | Connection, select_session, select_direct_session, request!, lifecycle, render_direct | Public session client facade |
| RunnerCommands | parse, render | CLI translation, no session authority |
| WirePlumberSessionRuntime | Handle, start!, attach, ready, running!, control!, source_status, stop!, shutdown!, reconciliation/final_record | Bounded one-shot installed-session API |
| SystemdOwners + Placement | Coordinator, Service, pid/alive/failure/record/verify!/stop!; cpu_set, credentials, snapshots | Deployment internals; avoid exposing service fields as user API |
| DeploymentConfiguration | profile/decode/validation/substitution/runtime-path/wrapper helpers | Validated configuration and installation internals; curate public subset |
| NativeOwnerBootstrapCodec/Runtime/Client | Runtime, prepared!/connecting!/finish!, connection hooks, Binding/Connection/status | Public owner integration; cold and lightweight |
| NativeSourceControl | Mailbox and native v1 staged source requests/snapshots | Shared owner support; working-tree addition requires release/tests |
| NativeAcquisitionLifecycle* | Profiles, lifecycle/Instrument/Snapshot/Cursor, Runtime and Connection | Existing v1 profile; generic support requires explicit decision |
| NativeCalibrationAction* | Binding/Connection, Hold/Adopt/Settle/Collect/Capture/Restore/Release, typed replies/exposures/rules | Public acquisition transport; algorithm-independent |
| CalibrationAcquisition | Plan, Timeouts, acquire!, acquire, read_plan, document, Cancelled | Reusable acquisition client; AOC still owns estimates/solvers |
| CalibrationCLI | run/main and bounded evidence journal | Thin entry point plus separate evidence implementation |
| Common / RuntimeExport / ScienceExport | JSON/process/file helpers; Parameter and artifact validation/export; resource roots | Internal helpers; replace SDK staging and split artifact/config concerns |
| REVOLTRTC | Reexports shared module bindings and instrument exporter/campaign/HEART modules | Application migration source; retain legacy exporter/HEART compatibility until replacement verified |
| FGPW | PipeWireNode; connect!/run!/quit!/close; prepare!, replace_parameters!, prepare_replacement/replace_graph! | Scientific graph transport adapter, separate package or optional extension |
| AOS HIL | PipeWireHILConfiguration, PreparedPipeWireHIL/Calibration, prepare/exchange/reset, exposure/probe/model-time/provenance/stream APIs | Scientific plant transport adapter, separate package or optional extension |

The `Profile` trait is justified by actual bootstrap, session, lifecycle and calibration profiles. The `ConnectionHooks` seam is justified by owner-local connect/quit behavior. Do not replace them with string dispatch. Conversely, no new abstract `Instrument` hierarchy is needed simply to select configuration. Concrete payload/identity storage and mutable native-lifetime objects are not defects by appearance.

## File and module map

This is a proposed organization, not a demand to rename all files in one commit. Group by responsibility; retain internal names during compatibility migration where changing them adds no value. The first phase should preserve public types, method signatures and binding identity while moving implementation into the named package. A facade can expose selected existing bindings without adding forwarding wrappers or a new module at every directory level. A new prepared-artifact representation is a separate explicit API change, not incidental file cleanup.

| Current path/module | Proposed placement/interface | Rationale |
| --- | --- | --- |
| `src/PipeWireAODeployment.jl` | `src/PipeWireAORTC.jl` | Approved package name, curated facade and module includes |
| root `wireplumber_cli.jl` | `src/cli.jl` plus thin installed command | Callable package implementation; arguments are only an adapter |
| root `wireplumber_install.jl` | `src/deployment/install.jl` | Registered install API |
| root `wireplumber_launch.jl` | `src/deployment/prepare.jl`, `cleanup.jl` | Separate preparation and exact owned-process cleanup responsibilities; no daemon loop |
| root `wireplumber_configuration.jl`, `src/deployment_configuration.jl` | `src/configuration/` with native schema validation/rendering | Keep source config versus realized WirePlumber config explicit |
| `src/systemd_owners.jl`, `systemd_units.jl`, `systemd_unit_files.jl` | `src/deployment/systemd.jl`, `units.jl` or existing coherent includes | Systemd resource/lifetime mechanics |
| `src/wireplumber_session_runtime.jl` | `src/session.jl` or documented `Session` facade | Session-bound client handle, not another lifecycle owner |
| `native_control_*`, codecs, client/profile/discovery | `src/native/`, grouped by protocol | Keep encoding, request transport and profile meanings distinct |
| bootstrap/source/parameter owner support | `src/owners/` | Public reusable cold owner entry points |
| `calibration_acquisition.jl`, `calibration_cli.jl` | `src/acquisition.jl`, CLI wrapper | Existing acquisition meaning retained |
| `science_export.jl` | Validated artifact/config functions under `src/artifacts.jl` and configuration; retire SDK-copy path for new apps | Current file combines raw artifacts, native binary staging, source-copy and provenance |
| `runtime_export.jl` | Legacy export helper or internal file operations only | No need for an independently registered package for file copies |
| REVOLT `src/artifact_files.jl` | Shared FITS artifact loader, optional FITSIO integration if cold clients should avoid it | Existing validation is useful; prepared output changes to memory |
| REVOLT `scripts/graph_catalog.jl` | Generic catalog consumer of FGA/JFG introspection API | Scientific declaration knowledge stays upstream |
| REVOLT simulator/graph/calibration owner scripts | Generic RTC owner implementations; science integration optional | Remove profile-specific dimensions/imports, preserve bootstrap |
| Classic `hsdm277.jl`, `hil.jl` preset constants and graph files | Instrument `simulation.toml` plus `artifacts/*.fits` | Data and exact ordering belong with the instrument |
| Classic reusable transformations/diagnostics | Narrow AOS APIs, only where truly reusable | Prevent moving instrument baggage into science core |
| GUI `src/native_rtc/`, `rtc_adapter/` | Remain GUI-owned Rust code | Separate client implementation is valid; share native conformance records/contracts |

Names requiring care: `SystemdOwners.Coordinator` is currently an immutable unit/invocation/cgroup/launcher record (`:20–26`), not a parallel session coordinator. Rename to a truthful internal cohort/invocation term when touching it, but its name alone is not a correctness defect. `RunnerCommand` and `native_runner_codec.jl` carry surviving v1 protocol semantics; preserve aliases while presenting Session to new callers. Keep `native` where it distinguishes the mandated wire transport; do not mechanically remove canonical domain words.

## Data, code and the intended user workflow

A small portable application has the following division:

| Authored application data | Registered code/runtime |
| --- | --- |
| Project/Manifest with selected released dependencies | PipeWireAORTC, PipeWireAO, AOS, AOC, FGA/JFG and selected adapters |
| Native RTC graph, core and session declarations (one or several `.conf` files) | Maintained native parser/graph executors; no replacement RTC graph language |
| Existing AOS simulation graph and explicit boundary/backend settings | AOS model operators and preparation; backend extensions |
| FITS HDUs for masks, matrices, geometry, references and measured/preset data | Shared FITS decoding/validation; owner memory and transport adapters |
| Optional GUI view configuration | Independent GUI/client |

FITS selection metadata belongs next to the existing parameter binding declarations, not in a parallel operational bundle schema. Use the existing AOS graph format for simulation; standard native RTC configuration remains SPA-JSON. “Small” does not require concatenating unrelated graphs into one file or suppressing provenance. It means the scientist owns configuration/data, not copied infrastructure.

The user should be able to instantiate the instrument environment, validate its graphs and FITS selections, prepare/start a named held session through a package command, inspect the catalog and live status, and explicitly request acquisition through the same session authority used by the GUI. Scientific parameter changes requiring construction stop and reprepare the owner. Live scalar/sparse updates follow declared capabilities and distinguish submitted from adopted generations. Native readiness cannot be inferred from a saved report.

The generated catalog is derived output, not an additional source of truth. Runtime receipts/systemd units may be produced outside the authored project. Original FITS files remain the scientific artifacts; decoded arrays and packing buffers are process-owned transient memory. Registration may still download package source into the Julia depot; that is distinct from copying an SDK into each instrument application.

## GUI/CLI and reuse conclusions

GUI `Cargo.toml` has no RTC Cargo path dependency; `src/native_rtc/mod.rs:1–15` states and implements GUI-owned native client modules. The GUI's Rust client and Julia RTC client are not automatically redundant implementations to collapse: both need their language-local binding and share the public wire contract. Keep common `.pod` conformance cases and contract meanings synchronized. The GUI remains optional; the headless app must not need GUI process state, view configuration or rendering dependencies.

Do not move AOC estimators into RTC merely because RTC orchestrates acquisition. Do not move FGA declarations into catalog/config code. Preserve JFG/AOS public preparation and lifecycle interfaces. Existing FGPW/HIL dispatch, typed exposure records and bounded ownership are valuable seams, not evidence of overengineering.

Source-copy helpers and compatibility aliases should disappear only after callers migrate. The `REVOLTRTC.ScienceExport` aliases preserve shared function/type identity; they are not by themselves duplicated implementations. Conversely, retaining both old and new SDK builders indefinitely would make new application semantics ambiguous. Mark legacy builders explicitly once the new path is established.

## Dependency-ordered migration

1. **Adjudicate this report and the independent correctness report.** Record accepted findings, profile scope and verification gates. Preserve working edits and all sealed/live sessions. Do not mix uncommitted science changes into a release accidentally.
2. **Define the narrow package facade and artifact/owner contracts.** Choose public install/validate/session/acquisition entry points and a prepared-array artifact contract. Decide whether native v1 update compatibility needs a distinct FITS-aware operation. Keep WirePlumber/systemd ownership explicit.
3. **Fill scientific interface gaps first.** Add JFG/FGA public prepared-graph introspection and array binding where absent; identify FGN in-memory adoption capability; place reusable model transformations in AOS. Do not claim parity before both selected engines can consume validated memory.
4. **Extract generic scientific owners.** Package imports replace source includes; configuration selects graph boundaries and units/extents; bootstrap still publishes before expensive preparation. Convert Classic geometry/presets to configuration/FITS with exact provenance. Remove REVOLTClassicSim from the runtime dependency closure.
5. **Release/register the dependency closure.** AOC 0.17.0 is already available; register required AOS/adapter/RTC versions and updated FGA/JFG/PipeWireAO as needed. Rename the RTC package in a deliberate release, preserving UUID continuity only after checking LocalRegistry identity/history and downstream manifests. Do not invent new UUIDs as cosmetic cleanup.
6. **Create a fresh small application environment.** Resolve registered dependencies, retain selected backend/preferences, use native configs/simulation graph/FITS, and package-owned commands. No copied SDK, dependency source path, raw payload file or developer checkout path is required. Keep old sealed SDK compatibility separate.
7. **Run focused software gates.** Fresh-depot install/relocation; declarations/catalog; FITS conversion/rejection/lifetime; owner/bootstrap shutdown; protocol v1 conformance; error propagation and unknown outcomes. Reuse existing tests where their contract still applies; change tests that enforce obsolete copied-source layout.
8. **Run selected isolated integration and scientific gates with explicit authority.** Verify FGN/JFG selected profiles, cold start/held readiness, reset/update/stop, acquisition restoration and exact cleanup, using owned services only. Demonstrate deterministic science preservation separately from software structure. Timing/allocation/hardware claims require their own evidence.
9. **Only then retire superseded generators and optionally consolidate adapter packages.** Extension consolidation needs parent API, dependency/load-order checks, optional-load absence/presence cases and compatibility with ForwardDiff/backend integrations. It is not a prerequisite for a small application.

## Coverage and limits

This was a static architecture review. Deep reads covered the RTC package entry point, Project, source-copy/config/runtime validators, protocol profile surface, session client facade, systemd record boundary, native parameter file path, CLI/install/launch structure, selected tests, REVOLT module/Project/export/environment/template/artifact/catalog code, simulator preparation/bootstrap includes, Classic geometry/graph/HIL presets, FGPW module/types/export surface and graph callback/constructor locations, HIL module/configuration/exchange/calibration preparation and cleanup boundaries, and GUI dependencies/client boundary. Source declarations were inventoried across RTC source; the hotspot scan covered RTC/REVOLT source breadth.

Partial coverage: complete native client/endpoint concurrency, every HIL callback, graph scheduling details, HEART scientific integration and every CLI failure path were not re-proven here. Relevant files were sampled for boundary evidence; the independent control review owns the deeper correctness pass. The simulator owner's dirty source-control integration was read as working source, not treated as a validated release. HIL/JFG dirty changes were inspected for API architecture, not fully reviewed line by line. Classic mathematical outputs, physical geometry validity and calibration quality were not re-audited.

No runtime reflection was used because runtime activity was excluded by this source-only assignment. No builds/tests/service operations were performed. Registry evidence is the local registry snapshot; remote availability and clean-depot resolution were not tested. Assertions about fresh installation, memory-only FGN parameters, extension loading and scientific equivalence are required future validation, not results. No performance conclusion is drawn from file size, types, allocations visible in source or prior reports.

The actionable findings concern concrete current dependencies and interfaces. Large codecs, typed native records, explicit lifecycle methods, duplicated test representations and long domain names were not promoted to findings simply because the scanner flagged them. Current preservation of source-first authority, unknown-outcome semantics, scientific ownership and native wire IDs should constrain remediation.
