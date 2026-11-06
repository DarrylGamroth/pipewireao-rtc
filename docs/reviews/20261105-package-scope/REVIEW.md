# Package necessity and ownership review — 2026-11-05

Baseline: clean `0b50101`, branch `codex/julia-session-policy-20261104`, existing
dedicated worktree `pipewireao-rtc-cleanup`. The user prioritized reducing
unnecessary implementation before further repair or qualification. This is a
bounded source review, not a completed dead-code audit or an approved withdrawal
of existing features. Current delivery status belongs in the roadmap.

## What accounts for the size

The package combines session policy, native application protocols, process
deployment, instrument authoring, simulation integration, calibration,
observation, artifact cataloging and management. Its root module includes the
shared source modules eagerly; scientific extensions load conditionally.

Measured physical lines, including comments and docstrings:

| Surface | Files | Lines |
| --- | ---: | ---: |
| `src/` | 109 | 46,314 |
| `ext/` | 40 | 17,644 |
| Implementation total | 149 | 63,958 |
| `test/` Julia files | 248 | 66,463 |
| MediaSession alone, included within `src/` above | 10 | 6,360 |

The MediaSession count is not an estimate of the complete runtime dependency
closure or a deletion target. Tests and file length do not establish necessity
or waste. No generated-source headers were found among the counted implementation
files; generated upstream bindings and historical evidence were not counted.

## Findings

### NEC-01 — scientific execution is implemented in RTC

**Confirmed ownership mismatch; high confidence; transfer before deletion.**

[Detector layout](../../../ext/aos/graph_adapters.jl) implements an AOS graph node:
padding, affine conversion, clipping, ADC rounding, preparation, reset and GPU
capture capability. Its `step_graph_node!` performs scientific array operations
(lines 295–301). Its callers include configured simulation preparation in
[the AOS integration](../../../ext/aos/instruments.jl), lines 207 and 275.

[Measured influence loading](../../../src/instruments/influence_functions.jl),
lines 179–229, performs bilinear resampling and converts OPD per physical command.
The live caller is `binding_values(::Val{:measured_influences}, ...)` in
[InstrumentConfiguration](../../../src/instrument_configuration.jl), line 1007.
This is the package's only numerical use of its direct Interpolations dependency.

The architecture assigns scientific implementations to their scientific packages.
AOS 0.3.19 provides the graph-node hooks/builtin registry and the typed
`Optics.MeasuredInfluenceFunctions` destination. It does not currently provide
these exact replacement implementations. Removing RTC's functions immediately
would break real callers.

**Action:** transfer the detector node and its numerical/capture tests into AOS,
preserving its configured name and contracts; then delete RTC's implementation
and registry addition. Transfer the influence calculation separately, keeping
RTC's necessary path/hash/admission checks. Remove Interpolations from RTC once
its sole calculation has moved. Do not create another RTC algorithm framework.

### NEC-02 — a fixed instrument capture product is in the shared package

**Confirmed instrument coupling; high confidence; scope-transfer proposal.**

[The capture-file implementation](../../../src/calibration_capture_files.jl)
fixes raw images at 352×352 and measurements at 188 ROIs in
`CLASSIC_CAPTURE_CONTRACTS` (line 11). Its CaptureStore documentation explicitly
supports only Classic (lines 133–135). The generic calibration owner constructs
that store in [calibration_owner.jl](../../../ext/calibration_owner.jl), lines
843–889. The product reader is also a public calibration surface.

This makes an instrument's detector geometry and capture-file evolution reasons
to change the shared RTC package. Independent instrument projects own geometry
and calibration integration. The existing Classic instrument project is a
candidate receiver, but its receiving capture API is not implemented today.

**Action:** transfer the Classic writer, reader and schema tests together into
the instrument integration, preserving manifest version 4, hashes, units and
provenance. Retain generic acquisition admission and transport collection where
they belong. Current upstream capture interfaces do not constitute a drop-in
replacement for the full UInt16/mixed-output metadata collector. Do not delete
that collector or invent a generic capture platform solely to hide one profile.

### NEC-03 — native endpoint resources are implemented twice

**Confirmed duplication; high confidence; removal candidate without feature retirement.**

[OwnerBootstrapRuntime.Transport](../../../src/control/owner_bootstrap_runtime.jl),
lines 40 onward, and
[AcquisitionLifecycleRuntime.Runtime](../../../src/control/acquisition_lifecycle_runtime.jl),
lines 27 onward, repeat the same resource fields, ThreadLoop/Context/Core creation,
callback/wake setup, registry listeners, publication synchronization and cleanup.
The terminal-publication polling bodies at lines 199 and 174 respectively share
the same decisions and native locking rules.

Their profile/command/lifecycle semantics differ legitimately. Their resource
ownership mechanics do not need independent implementations. Clock and lifetime
fixes currently require parallel changes.

**Action:** choose one canonical implementation of that resource ownership and
remove the other copy. Keep bootstrap Hsm policy, acquisition state and protocol
codecs distinct. Reuse ControlEndpoint and public PipeWireAO resource interfaces;
do not replace the copies with a new general service framework. Verify both native
bootstrap and acquisition selectors, publication failure and terminal release.

### NEC-04 — the same journal schema has two migration implementations

**Confirmed duplication; high confidence; removal candidate without losing durability.**

[ConfigurationStore](../../../src/configuration_store.jl), lines 20 and 143–174,
and [MediaSession journal](../../../src/media_session/journal.jl), lines 118–169,
both create/migrate `operation_events` and its indexes. This is the same database:
the store uses `history.sqlite3` (line 114), and
[session configuration](../../../src/configuration/session_configuration.jl),
line 287, assigns the journal that path.

The catalog reader and serialized journal writer have different operational
roles. The database schema has one contract and should have one maintained
definition. Parallel copies create schema-drift and synchronized-edit costs.

**Action:** retain one schema/migration implementation and delete the duplicate.
Keep the journal's worker ownership, bounded messages and write-before-effect
ordering. This is not evidence for removing the selected durability requirement
or combining live control with catalog management.

### NEC-05 — a deployment copies the entire development test tree

**Confirmed deployment payload expansion; high confidence; runtime-closure reduction.**

[ScienceExport.RUNTIME_ENTRIES](../../../src/deployment/science_export.jl),
line 172, includes all of `src`, `ext` and `test`. `copy_deployment_runtime`
recursively copies those entries. The same file's `orchestration_sources`
explicitly skips `test` at line 417. Nevertheless,
[validate_runtime](../../../src/configuration/deployment_configuration.jl),
line 773, requires both `test/Project.toml` and `test/runtests.jl` in an installation.

Thus every generated runtime carries the development test tree, including its
66,463 Julia lines. This is deployment payload, not runtime execution of tests.
The root Project's Julia workspace references the test project, so removing a
single export-list entry is insufficient.

**Action:** derive and validate a runtime package/environment closure that excludes
the development test suite; keep qualification material separately when needed.
Change the generator and validator together, then test cold resolution, export,
installation and relocation. Keep source tests in the repository. Do not fix this
by hand-editing generated applications or suppressing installed-source validation.

### NEC-06 — optional workstation features are part of the core package surface

**Observed scope expansion; explicit product decision, not a dead-code finding.**

[The root module](../../../src/PipeWireAORTC.jl), lines 49–89, includes artifact
cataloging, optical authoring, Analysis, simulator replacement and ManagementCLI
alongside the session implementation. The corresponding dependencies and public
module surface are in Project.toml and the root `public` declaration.

The current architecture deliberately includes many of these features, including
artifact cataloging and cold simulator replacement. They have callers and cannot
be declared unnecessary because the RTC could theoretically be smaller.
Their inclusion still makes a narrow session package responsible for a broader
workstation suite's release, dependency and testing closure.

**Action:** decide which of those products must remain in this package. If the
target is the session control plane, keep optional authoring/management programs
outside its mandatory load/export closure, with existing public contracts at the
boundary. Moving code alone does not remove ecosystem maintenance; retire
unwanted features and their tests, or replace implementations with existing owner
APIs before claiming a net reduction.

## Recommended removal order

1. Establish the surviving runtime entrypoints and optional product features first.
   Do not consolidate or qualify a subsystem that the scope decision would retire.
2. For the retained endpoints/journal, delete the duplicate resource/schema
   implementations while preserving behavior. Do not add a new service framework.
3. Remove development tests from normal runtime exports through a proper package
   closure, including workspace/validator changes.
4. Transfer detector execution into AOS, then remove the RTC implementation;
   transfer the influence calculation and remove RTC's Interpolations dependency.
5. Move the Classic capture product to its instrument owner with its reader and
   tests. Keep generic acquisition/process ownership stable.

The retained core is one MediaSession authority, its application protocol/admission
contracts, declared connections, lifecycle/fault handling and necessary one-shot
control/deployment boundaries. PipeWireAO and scientific packages keep their
transport/execution/algorithm responsibilities. This review changes no requirement
IDs or ownership decisions by itself and proposes no arbitrary line-count target.

## Review evidence and limits

Reviewed current architecture, root includes/public modules, dependency and
extension declarations, selected implementations and their callers. An independent
read-only scientific ownership review corroborated NEC-01/02; primary review
checked their calculation and call sites. Scope counts and the skill hotspot
scanner only prioritized inspection. Concrete mutable state, large files and
long protocol names were not admitted as findings on their own.

No major group was proven safely dead. For example, an apparently unused sensor
publication helper has downstream callers; calibration dispatch wrappers invoke
active implementations. A complete unused-public-API/dynamic-call audit was not
performed. The October boundary inventory is historical, not a current deletion
authority. No claim is made that whole instrument/extension directories can be
removed today or that every line in a named file belongs at the same destination.

Local inventories: `/tmp/rtc-package-scope-lines-20261105.tsv` and
`/tmp/rtc-package-scope-hotspots-20261105.json`. Only review documentation changed.
No runtime tests, services, simulations, live data or source implementations were
changed. Source/dependency/caller verification supports the review; it does not
establish numerical, allocation, hardware or deadline qualification after future
removals. Those changes require their focused receiving-package and integration
checks before each commit.
