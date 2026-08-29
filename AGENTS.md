# Repository agent instructions

## Purpose and scope

This repository owns the headless PipeWireAO real-time controller (RTC)
product. Its responsibilities include instrument lifecycle, desired and
observed state, graph deployment, configuration and artifact admission,
operator control, telemetry, recording, audit, and run reconstruction.

The repository is currently architecture-first. The documents describe a
proposed system and its delivery gates; they are not evidence that the runtime
has been implemented or qualified.

Before making architectural or implementation changes, read
`docs/README.md`, then the documents that own the affected contracts. Start
with `docs/architecture.md` for work that crosses subsystem boundaries and
`docs/roadmap.md` for implementation order and acceptance evidence.

## Authority boundaries

- PipeWireAO owns generic SPA/PipeWire ndarray transport, the FGN ABI and
  graph host, acquisition metadata, polling scheduling, row-block transport,
  and progressive execution.
- Calculon owns transport-neutral scientific algorithms and their portable
  declarations.
- Device-plugin repositories own camera, deformable-mirror, file-source, and
  other hardware adapters.
- `pipewireao-gui` is an ordinary inspection, control, and visualization
  client. It does not own RTC state or correction authority.
- WirePlumber supplies reusable session-policy mechanisms. It is not the RTC
  domain authority.

Use public, versioned interfaces across these boundaries. Do not depend on
PipeWire daemon-private pointers, object layouts, or undocumented callback
behavior. Do not copy a low-level contract into this repository: link to its
authoritative document and state only its RTC-level consequences. Changes in a
sibling repository require explicit task scope and must preserve that
repository's unrelated worktree changes.

## Implementation constraints

- Rust is the default language for the headless RTC application, command-line
  client, domain state, deployment transactions, and recorder services.
- Use C only for a qualified ABI-facing or strict-path mechanism that cannot be
  expressed adequately through the Rust bindings.
- Julia remains a scientist-facing graph and algorithm environment; Julia code
  must run outside the PipeWire daemon unless a separately qualified AOT
  component has an explicit real-time contract.
- Implement the hierarchical instrument lifecycle with Statig's blocking,
  serialized dispatcher. Keep Statig types private and keep lifecycle I/O in
  asynchronous typed effects and correlated completion events.
- Keep lifecycle, filesystem, database, GUI, logging, and network work outside
  the correction data path.
- Scientists declare ordinary typed Calculon algorithms, ports, properties,
  parameters, shapes, and schemas. They must not write SPA callbacks, raw
  pointer handling, errno translation, publication machinery, or worker
  scheduling code.
- FGN and its host-owned fixed workers remain transparent execution
  mechanisms. Deployment selects worker count, row-block size, affinity,
  scheduling, and idle policy.
- Do not scaffold a runtime or silently settle an open decision unless the
  task explicitly begins the corresponding roadmap phase.

## Documentation rules

- Preserve the document ownership split in `docs/README.md`. Do not merge the
  focused contracts back into one large architecture file.
- Preserve stable `RTC-*` requirement and `RTC-ARCH-*` decision identifiers.
  Change their meaning only through an explicit contract revision.
- Distinguish observed current capability, proposed design, qualification
  evidence, and future scope. Passing a component test does not promote a
  system-level claim.
- Keep Mermaid diagrams compatible with VS Code's built-in renderer. Diagrams
  explain relationships; prose and tables remain authoritative.
- Use canonical adaptive-optics terms consistently, especially requested,
  demanded, submitted, accepted, applied, and measured deformable-mirror
  command stages.
- Record implementation phases in dependency order and give every completion
  gate concrete evidence.

## Change and validation discipline

- Inspect the complete worktree before editing. Existing changes belong to the
  user unless the task clearly includes them.
- Keep each commit focused and exclude unrelated files. Do not rewrite
  published history unless explicitly requested.
- For documentation changes, check local links, trailing whitespace, final
  newlines, unique requirement definitions, and Markdown rendering. Validate
  Mermaid diagrams when a renderer is available.
- Once a Rust workspace exists, run formatting, focused tests, workspace tests,
  and Clippy in proportion to the change. Add narrower checks for lifecycle,
  deployment, recorder, replay, and fault behavior as those subsystems appear.
- Performance or real-time claims require the evidence defined in
  `docs/time-and-performance.md`; a functional test or microbenchmark alone is
  insufficient.
