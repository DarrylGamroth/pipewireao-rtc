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

- RTC-ARCH-025 selects WirePlumber Lua as the sole session lifecycle and
  admission authority. systemd owns process lifetime; Julia tools export,
  install, inspect and send native controls as one-shot clients. Rust Statig
  and Julia DeploymentRunner coordinators are retired. Do not
  restore a parallel session authority or supervisor fallback. One-shot clients
  and scientific owners remain; qualify each selected profile separately.
- Production calibration orchestration uses Julia and the existing acquisition,
  protocol, analysis and AdaptiveOpticsCalibration APIs. Maintained repository
  scripts and scripting tests use Julia; do not add Python implementations.
  Historical Python tools remain in Git history with their recorded evidence.
- Live controls use native PipeWire serialization (`RTC-ARCH-024`/`RTC-DEV-030`).
  Saved reports/configuration may use JSON. Saved files never prove live readiness.
- Use maintained standard PipeWire relaxed SPA-JSON configuration/generators.
  Do not introduce another configuration language or operational bundle format.
- Keep the runner outside frame processing. Scientists declare typed Algorithms,
  ports, properties, parameters, shapes and schemas; they do not write SPA
  callbacks, pointer/errno handling, publication or worker machinery.
- Algorithms must remain array-testable and usable by other executors. Support
  declared full-frame/row-block owners without adding an RTC data scheduler.
- Follow the relevant roadmap dependencies unless the user changes their order.

## Validation and documentation

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
