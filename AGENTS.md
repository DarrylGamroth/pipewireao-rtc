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

- Put `using`, `import`, `export` and `public` at the top of each Julia
  module or script. Include a child module before importing its names.
  Preserve optional package loading and tests that measure import order.
- Use `#` for implementation comments. Document exported and public functions
  with a triple-quoted Julia docstring, an indented signature and an imperative
  summary. Describe units, ownership and failure behavior where they matter.

- Follow the package-wide [Julia design conventions](docs/architecture.md#julia-design-conventions).
  Reuse existing interfaces and codecs; document required interface methods and
  trait results beside their definitions. Record consequential exceptions in the
  current migration plan or evidence, with their verification boundary.
- RTC-ARCH-026 supersedes RTC-ARCH-025's ownership allocation. The headless RTC
  application owns session lifecycle, admission and declared application links.
  The user selected removal of Lua and libwireplumber on 2026-11-04. The
  `MediaSession` module in `src/media_session/` uses public PipeWireAO.jl APIs
  and Hsm.jl; systemd owns process
  lifetime; Julia tools export, install, inspect and send native controls as
  one-shot clients. Rust Statig and Julia DeploymentRunner coordinators remain
  retired. Do not introduce a second session authority or supervisor fallback.
  One-shot clients and scientific owners remain; qualify each profile separately.
  Independent WirePlumber may supply site/device policy. Follow upstream
  media-session terminology with idiomatic Julia names; do not copy C prefixes
  or introduce parallel names for PipeWire objects and operations.
- The shared instrument tools own dark, lamp and qualification campaigns,
  offline optical and interaction campaigns, and calibration bundle staging.
  RTC retains bundle validation and export.
  RTC owns calibration projections, the native acquisition endpoint and
  client, and preparation evidence. AdaptiveOpticsCalibration owns numerical
  reductions. Maintained repository scripts and scripting tests use Julia;
  do not add Python implementations.
  Historical Python tools remain in Git history with their recorded evidence.
- Live controls use native PipeWire serialization (`RTC-ARCH-024`/`RTC-DEV-030`).
  Saved reports/configuration may use JSON. Saved files never prove live readiness.
- Deploy PipeWireAORTC as a registered dependency of the sealed application
  Project/Manifest. Do not copy the RTC package or its development test workspace
  into application payloads. Keep authored instrument/RTC/simulation data in the
  instrument repository; generated launchers load the selected dependency.
  New install/start paths reject copied SDK runtimes. Old sealed applications
  retain their original tools and are not rewritten during this migration.
- Session controls do not persist operation history or wait for durable writes.
  Preserve finite deadlines, exact correlation and unknown-outcome handling.
  Archiving is deferred to a separate service. Artifact provenance and catalog
  management receipts retain their separate contracts.
- AdaptiveOpticsSimPipeWireHIL owns the simulator process and its startup settings.
  RTC keeps cold export and calibration assets plus the existing PipeWire ports
  and source-control contracts for independent providers.
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
- Prefer Hsm.jl for Julia-owned state machines. Public mutation/observation
  functions dispatch domain events; state-specific and ancestor handlers own
  phase-dependent admission, transitions and state updates. Use hierarchy for
  shared behavior and return internal handling for updates that must not restart
  entry deadlines. Read-only status queries may inspect the active state. Keep
  scientific commands out of entry/exit behaviors and preserve one-shot effects.
  Document execution-boundary exceptions: C/Rust RT code, callback paths requiring
  bounded allocation/GC evidence, and durable receipts that are data rather than
  a running machine. Consistency must not introduce another lifecycle authority.
- Model domain evidence and operations with concrete types behind documented
  abstract interfaces. Dispatch behavior and comparisons on those interfaces;
  use traits for independent scope or capability distinctions. Normalize native
  records at their boundary so correlated controller facts stay together.
  Prefer typed methods and parametric structs over `isa` branches; do not hide
  type branches behind `typeof`/subtype predicates or field-presence selectors.
  Keep representation/tag checks at input validation boundaries, and keep
  partial-order semantics explicit for coupled-controller generations.
- Prefer Active Objects for long-lived cross-thread control: one Agent.jl duty
  cycle owns its Hsm and mutable application state. Other contexts send bounded
  typed messages and use replies or immutable published snapshots. Define queue
  capacity, full/closed behavior and shutdown acknowledgements; do not block
  native callbacks or wait for a reply while holding a native loop lock. Retain
  required PipeWire locks for native transactions. For blocking graph workers,
  use the public native command endpoint so their main loop receives commands
  while `run!` blocks. Keep scientific execution on its PipeWire data thread and
  lifecycle Hsms on their control thread. Cold-bound calibration nodes omit live
  sparse Parameter Ports. Reclaim graph storage only after an explicit release
  receipt and task completion. Other native owners retain their documented
  thread-safe quit capability until migrated. Synchronous clients and Hsms already
  owned by one task do not need an extra agent or queue solely for consistency.
- Use Clocks.jl monotonic clocks for control elapsed time. Preserve each public
  API's declared units and accept injected cached clocks for deterministic tests
  where a clock seam exists. Cached clocks have one updating owner and require
  explicit publication; native deadline validation must not silently use stale
  duty-cycle time. Keep epoch/reference timestamps separate from elapsed clocks.
  An agent samples its source once at the beginning of a duty cycle and uses
  its owned cached clock throughout that cycle; retain producer receipt times.
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
- Commit each coherent, verified changeset as work completes. Do not accumulate
  unrelated completed changes across tasks; preserve local dependency order.
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
- The calibration worker command selectors require native/JLL 4.0.2,
  PipeWireAO 0.9.2 and FilterGraphPipeWire 0.5.2 or newer compatible releases.
  The registered artifact contains the loop accessor; no JLL path preferences
  are needed. Set `PIPEWIREAO_PREFIX` to that artifact to select the matching
  private-core daemon. See the [artifact release evidence](docs/validation/rtc-cohort-402-20261106/README.md)
  and [worker protocol and selectors](docs/reviews/20261104-calibration-worker/REVIEW.md).
- Maintain current work in the roadmap's **Current work** section. Keep dated
  integration/review/validation records as evidence, indexed in
  `docs/EVIDENCE_INDEX.md`; do not append another competing status narrative.

## Instrument export checks

- `test/test_calibration_capture.jl` checks live multi-port exposure collection
  without AOS. The optional `test/test_calibration_capture_private_core.jl`
  checks the same transport on a temporary core with three default Julia threads
  and the matching native SDK. It uses `submit_array!(...; reference_timestamp=...)`.
- `test/test_instrument_influences.jl` checks measured-influence artifact admission
  without science packages. `test/instrument_influences_science.jl` runs the
  original FITS/resampling/provenance checks with AdaptiveOpticsSim 0.3.21 or newer
  selected explicitly; it also checks late extension loading without HIL. Neither
  selector opens a core. The scientific sampler belongs to AOS, not RTC.
- `test/aos_graph_adapters.jl` checks RTC factory composition against the selected
  AOS builtins, including detector layout. Scientific layout, reset, allocation,
  malformed-input and CPU/GPU capture tests live in AdaptiveOpticsSim's
  `test/test_detector_frame_layout.jl` and `test/test_detector_frame_layout_gpu.jl`.
- `test/test_instrument_export.jl` is the focused cold export/profile/template
  selector; it runs without scientific optional packages or GPU access.
- `test/runtime_install.jl` checks actual instrument export, registered dependency
  resolution, installation and software-environment relocation in temporary
  directories. It needs the selected RTC source version in a registry and an
  explicit compatible `PIPEWIREAO_PREFIX`; `--prepare-only` runs the offline
  export regression. It starts no core or service. Installed absolute service
  paths require reinstallation after moving an application.
- `test/session_graph_schema.jl` uses the optional JFG environment to check actual
  prepared port schemas against session declarations and native-command limiter
  equivalence. It opens no core, service or device.
- `julia --project=. test/test_aos_graph_selection.jl` checks cold graph selection
  and Proper detection without scientific imports.
- `julia --project=. test/test_zemax_components.jl` checks composable imported
  optics, physical pupil-plane metadata and named HIL graph selection without
  scientific packages. `julia --project=/path/to/science-environment
  test/zemax_component_preparation.jl` checks ordinary linked CPU graphs with
  AOS/HIL and explicit Proper. These selectors create no PipeWire core or files
  in the instrument source.
- `julia --project=/path/to/science-environment test/test_session_configuration_integration.jl`
  checks session metadata against the optional JFG and AOS/HIL packages. It
  checks small CPU Shack-Hartmann and Pyramid port contracts without a live
  session or GPU access. The core exporter runs independently.
- Instrument-source build/calibration/private-core selectors live in the
  instrument repository. Its README owns environment prerequisites and commands.
  Builds do not install or launch sessions. Keep source files and live RTCs
  unchanged while validating a fresh output.
- The instrument repository owns offline optical calibration selectors, including
  chopped measurements, detector observations, artifact publication and captured
  calibration. RTC's `test/external_optical_preparation.jl` checks ROI bounds and
  unknown-origin metadata against physical sensor dimensions.
- `test/test_pupil_source_owner.jl` and `test/test_physical_offset_inputs.jl`
  check the version-5 clocked pupil source and version-2 P/Q-only receiver cold,
  without optional science packages. The optional CPU selector
  `test/pupil_feedback_composition.jl` exercises actual mirror response and
  sealed calibration preparation.
- The optional `test/physical_offset_inputs_private_core.jl` requires three
  default Julia threads.
  `test/physical_offsets_private_core.jl` requires `--threads=4,0`.
  Their imported HIL helper selects the daemon with
  `PIPEWIREAO_HIL_TEST_PREFIX`, defaulting to the JLL artifact. Set that variable
  to the matching SDK and select client libraries through JLL preferences;
  `PIPEWIREAO_PREFIX` alone does not select this helper's daemon. The
  [graph negotiation evidence](docs/reviews/20261105-graph-buffers/REVIEW.md)
  records both tested daemon cohorts and commands. These selectors own and close
  their private cores, check native receipt admission, frame independence and
  Pause/Run continuity, and do not qualify hardware or deadlines.
- Optional `test/calibration_transport.jl` uses `--threads=3,1`;
  `test/calibration_named_transport.jl` and `test/calibration_readiness.jl` use
  `--threads=4,1`. These fixtures spawn blocking native graph owners and need an
  interactive main thread for the control task. Set `PIPEWIREAO_PREFIX` to the
  matching SDK: client-library preferences alone do not select the test daemon.
- Optional `test/captured_optical_preparation.jl` exercises the shared RTC device
  execution policy, monochromatic/finite-channel/chopped optics, detector response,
  changed inputs, seeded draws and reset without a core. Set
  `PIPEWIREAORTC_TEST_BACKEND=cpu`, `cuda` or `amdgpu` in separate matching package
  environments. Accelerator runs disable scalar indexing. GPU simulator production
  preparation requires captured execution; unsupported nodes fail closed.
- Optical publication and runner unit checks now live in
  AdaptiveOpticsSimPipeWireHIL's `test/optical_exposure_publication.jl` and
  `test/external_pupil_execution.jl`. Its
  `test/external_pupil_stream_formats.jl` checks exact exposure rates and compact
  metadata. RTC retains cold configuration export and
  calibration selectors. HIL owns scientific cursor, warmup, reset, pacing and
  completed-exposure batching.
  RTC publishes the source-control and bootstrap interfaces for external
  providers that implement the managed source contract.
- `test/simulation_export.jl` retains schema-1 lockstep export and relocation.
  `test/simulation_optical_export.jl` checks schema-2 external/clocked graphs,
  seeded detector/chopped trajectories, cold Proper loading, actual source
  planes and a relocated consumer without RTC. `test/simulation_compiled_export.jl`
  reuses HIL's tiny compiled model data writer and checks RTC asset copying,
  exact hashes, relocation and tamper rejection; matching development HIL test
  sources are needed for this selector. These checks open no core or GPU.
- HIL owns manifest parsing, prepared numerical execution and finite private-core
  controls/cleanup. Its optional CPU and CUDA selectors check optical, detector,
  compiled and captured preparation. Clocked sources remain on the host;
  accelerator optics require capture. Selectors do not qualify HEART plugins.
