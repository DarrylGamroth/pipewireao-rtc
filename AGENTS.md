# Repository agent instructions

## Start here

- Inspect the branch, revision and complete worktree status. Preserve unrelated
  edits and processes; keep substantial work on a dedicated branch/worktree.
- Read [the task index](docs/README.md) and only the requirement/design sections
  relevant to the change. Use `rg` for IDs/headings before opening long files.
  The index links current work; do not reconstruct status from old reports.
- Architecture, requirements and delivery order are authoritative in
  `docs/architecture.md`, `docs/operations.md` and `docs/roadmap.md`, respectively.
  Preserve `RTC-ARCH-*`/`RTC-DEV-*` identities and meanings. Evidence is not a
  requirement, and documentation is not implementation or qualification.
- Read a historical review/receipt only for an affected finding or claim. Reuse
  verified results while their source, dependency, configuration and measurement
  assumptions still apply; rerun affected gates when those assumptions change.

## Scope and owners

- This repository owns the non-actuating development RTC: configuration, exact
  session/links, lifecycle, execution groups, deployment supervision, diagnostics
  and system tests. Optional GUI/CLI clients do not own the science lifecycle.
- PipeWireAO owns ndarray/FGN transport, graph hosting, properties, parameters,
  metadata, polling, row blocks, progressive scheduling, buffers and workers.
- Scientific packages own transport-neutral Algorithms and declarations;
  device-plugin repositories own adapters. External Julia owners run their own
  graphs. Use public versioned contracts, never daemon-private layouts/callbacks.
- Current backend/qualification selections are in the roadmap's **Current work**
  section. Functional, numerical, allocation, cadence and latency evidence are
  separate. Simulated offsets come from the plant; measured matrices imply a
  declared hybrid calibration. HEART remains an unchanged external owner.
- Physical devices/authority, durable recording, remote access, RTC-owned data
  scheduling and target-host qualification remain deferred. Do not load or
  promote `docs/archive/full-rtc/` without an explicit scope decision.
- Sibling edits need task scope and must preserve unrelated changes.

## Implementation

- RTC-ARCH-026 supersedes RTC-ARCH-025's ownership allocation. The headless RTC
  application owns session lifecycle, admission and declared application links.
  It reuses libwireplumber hooks, discovery and public WpLink APIs as a library;
  upstream WirePlumber remains the runtime, while site/device policy is
  configured separately. The WirePlumber fork carries build integration and
  independent upstream fixes, not another runtime API. systemd owns process
  lifetime; Julia tools export, install, inspect and send native controls as
  one-shot clients. Rust Statig and Julia DeploymentRunner coordinators remain
  retired. Do not introduce a second session authority or supervisor fallback.
  One-shot clients and scientific owners remain; qualify each profile separately.
- Production calibration orchestration uses Julia and the existing acquisition,
  protocol, analysis and AdaptiveOpticsCalibration APIs. Maintained repository
  scripts and scripting tests use Julia; do not add Python implementations.
  Historical Python tools remain in Git history with their recorded evidence.
- Live controls use native PipeWire serialization (`RTC-ARCH-024`/`RTC-DEV-030`).
  Saved reports/configuration may use JSON. Saved files never prove live readiness.
- Native PipeWire configuration uses maintained standard relaxed SPA-JSON.
  Human-authored instrument, simulation, RTC, process/profile, calibration and
  GUI configuration uses bounded YAML and is compiled to existing native runtime
  contracts at export. Do not create another optical graph language or executor.
- Humans and agents must not edit generated files directly, including headers,
  formatting, recorded hashes or generated fixtures. Change the authoritative
  source or generator, then regenerate the affected outputs and their dependent
  hashes/receipts with the supported tooling. Review the source and generated
  diffs together. If the generation path is missing or unclear, establish it
  before changing the output; do not treat the generated copy as authoring input.
- Generated files must identify themselves as generated. Comment-capable text starts
  with a `Generated` header, retained by the writer on regeneration; include
  source/regeneration guidance when known. FITS uses native header cards.
  Strict JSON and fixed binary payloads must retain their required format;
  keep their generation/provenance in schema-supported metadata or the owning
  manifest rather than injecting comments or changing payload bytes.
- Keep the runner outside frame processing. Scientists declare typed Algorithms,
  ports, properties, parameters, shapes and schemas; they do not write SPA
  callbacks, pointer/errno handling, publication or worker machinery.
- Algorithms must remain array-testable and usable by other executors. Support
  declared full-frame/row-block owners without adding an RTC data scheduler.
- Follow the relevant roadmap dependencies unless the user changes their order.

- Keep shared Julia code in `src/`, package tests in `test/` and native protocol
  records in `test/data/`. Independent instrument projects own their named graphs,
  resources and calibration integration. The RTC Rust crate is retired; the GUI
  owns its native Rust client. Preserve protocol names and historical report fields.
  Use domain names for test inputs instead of “fixture”.

## Validation and documentation

- Use Julia 1.13 or newer for development, validation and release tooling.
- Run the core Julia suite from the package environment, with the native prefix
  selected explicitly: `julia --project=. -e 'using PipeWireAO;
  ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir);
  include("test/runtests.jl")'`. The optional science environment alone does not
  expose all core-test dependencies. This selector does not qualify hardware.
- Keep commits focused; never rewrite published history without authorization.
- Choose checks for the changed behavior. Rust code: formatting, focused tests,
  workspace tests and Clippy in proportion to the change. Live/hardware gates
  are opt-in; do not stop an existing daemon, instrument or experiment.
- Documentation-only changes: local links/anchors, whitespace, final newlines,
  requirement-ID preservation and Markdown structure. No runtime rebuild is
  needed solely because prose or navigation changed.
- Render changed Mermaid diagrams with the local Podman image
  `ghcr.io/mermaid-js/mermaid-cli/mermaid-cli:latest`; mount source read-only and
  write temporary output. Keep diagrams VS Code-compatible; prose is authoritative.
- Keep observed, derived and unconfirmed conclusions distinct. A functional
  check/microbenchmark does not establish deadline, tail-latency, physical-loop,
  safety or real-time qualification. Preserve failed gates and their scope.
- Maintain current work in the roadmap's **Current work** section. Keep dated
  integration/review/validation records as evidence, indexed in
  `docs/EVIDENCE_INDEX.md`; do not append another competing status narrative.

## Instrument export checks

- `test/test_instrument_export.jl` is the focused cold export/profile/template
  selector; it runs without scientific optional packages or GPU access.
- `julia --project=. test/test_aos_graph_selection.jl` checks version-3 graph
  selection and Preparing-before-Proper load order without science packages.
  `julia --project=/path/to/science-environment test/aos_selected_graph_loading.jl`
  checks the real optional loaders and selected CPU optics/observation contracts
  in a fresh process, without a PipeWire core.
- `julia --project=/path/to/science-environment test/aos_owner_science_loading.jl
  /path/to/built-application/simulation.conf` checks the version-4 owner's real
  optional science/Proper loaders in a fresh process. Supply a real built
  external-pupil configuration and direct AOS/HIL/Proper dependencies; do not
  preload those packages. The selector explicitly chooses CPU preparation,
  injects only the bootstrap boundary and prepares the declared optics without
  a PipeWire core, service, GPU import or instrument/configuration mutation.
  This catches extension world-age failures; it does not qualify native owner
  lifecycle or the application's selected accelerator execution.
- `julia --project=. test/test_zemax_components.jl` checks composable imported
  optics, physical pupil-plane metadata and named HIL graph selection without
  scientific packages. `julia --project=/path/to/science-environment
  test/zemax_component_preparation.jl` checks ordinary linked CPU graphs with
  AOS/HIL and explicit Proper. These selectors create no PipeWire core or files
  in the instrument source.
- `julia --project=/path/to/science-environment test/test_session_configuration_integration.jl`
  checks session metadata against the optional JFG and AOS/HIL packages. It
  prepares small CPU Shack-Hartmann and Pyramid products without a live session
  or GPU access; the core exporter selector remains independent of these packages.
- The optional CPU selector `test/aos_instrument_preparation.jl cpu` requires
  `REVOLT_CLASSIC_MIRROR_DESCRIPTION` to name `mirrors/alpao/hsdm277.yaml`
  in the instrument repository, in addition to the scientific test environment.
  The test serializes that authoring YAML to native JSON for the legacy package
  reader; the source and live deployment remain untouched.
- Instrument-source build/calibration/private-core selectors live in the
  instrument repository. Its README owns environment prerequisites and commands.
  Builds do not install or launch sessions. Keep source files and live RTCs
  unchanged while validating a fresh output.
- `julia --project=/path/to/science-environment test/calibration_chopped.jl`
  checks the actual CPU chopped measurement prefix, signed numerical calibration,
  typed reference-difference publication and old-calibration rejection without
  a core or GPU. `test/calibration_optical_publication.jl` retains the ordinary
  intensity publication regression. These tests do not qualify a rolling loop.
- `test/test_pupil_source_owner.jl` and `test/test_physical_offset_inputs.jl`
  check the version-5 clocked pupil source and version-2 P/Q-only receiver cold,
  without optional science packages. The optional CPU selectors
  `test/pupil_source_owner_science.jl` and `test/pupil_feedback_composition.jl`
  exercise actual mirror response, model chronology and sealed preparation.
- The optional `test/physical_offset_inputs_private_core.jl` and
  `test/pupil_source_control_private_core.jl` require three default Julia threads
  and explicit `PIPEWIREAO_PREFIX` pointing to a compatible private native SDK.
  They own and close their private cores, check native receipt admission and
  Pause/Run continuity, and do not qualify hardware or deadlines.
- Optional `test/captured_optical_preparation.jl` exercises the shared RTC device
  execution policy, monochromatic/finite-channel/chopped optics, detector response,
  changed inputs, seeded draws and reset without a core. Set
  `PIPEWIREAORTC_TEST_BACKEND=cpu`, `cuda` or `amdgpu` in separate matching package
  environments. Accelerator runs disable scalar indexing. GPU simulator production
  preparation requires captured execution; unsupported nodes fail closed.
