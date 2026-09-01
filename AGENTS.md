# Repository agent instructions

## Purpose and active scope

This repository currently owns a small headless PipeWireAO development runner.
The first executable loads one simulated or recorded complete-frame source,
one `fgn-native` Calculon graph, and one non-actuating sink from a standard
PipeWire configuration. The active RTCW extension composes multiple existing
filter-graph instances and exact PipeWire links under the same session
lifecycle. It does not add another graph-authoring format or scheduler.

Runtime implementation is underway and remains incomplete. Documentation is
not implementation or qualification evidence.

Physical devices, correction authority, durable recording, Julia execution,
remote access, progressive scheduling, operational supervision, and target-
host qualification are not active scope. Their former proposals are preserved
under `docs/archive/full-rtc/` as inactive design input. Do not load, cite, or
implement that archive unless the user explicitly asks to promote one deferred
capability. Never reactivate the archive wholesale.

Before making changes, read `docs/README.md` and the relevant active document:

- `docs/architecture.md` for scope and component boundaries;
- `docs/operations.md` for RTC-DEV requirements and lifecycle; and
- `docs/roadmap.md` for implementation order and completion evidence.

## Authority boundaries

- PipeWireAO owns generic SPA/PipeWire ndarray transport, the FGN ABI and
  graph host, properties, parameters, metadata, polling, row-block transport,
  and progressive execution.
- Calculon owns transport-neutral scientific algorithms and portable
  declarations.
- This repository owns only development configuration, exact graph
  realization, basic runner lifecycle, diagnostics, and system-level tests.
- Device-plugin repositories own camera, deformable-mirror, file-source, and
  other adapters.
- `pipewireao-gui` and command-line tools are ordinary optional observers.

Use public, versioned interfaces across these boundaries. Do not depend on
PipeWire daemon-private pointers, object layouts, or undocumented callback
behavior. Link to low-level contracts instead of copying them. Changes in a
sibling repository require explicit task scope and must preserve unrelated
worktree changes.

## Implementation constraints

- Rust is the default language for the small headless runner.
- Implement the lifecycle with Statig's blocking state-machine API and one
  serialized dispatcher from the first increment. Keep Statig types private.
  State handlers emit typed effects; potentially blocking PipeWire,
  configuration, and filesystem work executes outside the handlers and returns
  as typed completion events.
- Use the existing standard PipeWire relaxed SPA-JSON configuration and
  maintained generator. Do not add TOML, YAML, a database, or an operational
  bundle format to the development runner without an approved scope change.
- Keep the runner outside frame processing. FGN and PipeWireAO own scheduling,
  buffers, property publication, parameter adoption, and worker mechanisms.
- Scientists declare ordinary typed Calculon algorithms, ports, properties,
  parameters, shapes, and schemas. They must not write SPA callbacks, raw-
  pointer handling, errno translation, publication machinery, worker code, or
  central adapter-registry entries.
- Keep the scientific implementation directly testable with ordinary arrays
  and usable by a non-PipeWire graph executor.
- The active baseline is complete-frame and non-actuating. Do not scaffold
  physical authority, recording, Julia services, row-block scheduling,
  service-manager policy, or qualification infrastructure in anticipation of
  later work.
- Add implementation only in the dependency order in `docs/roadmap.md` unless
  the user explicitly changes that order.

## Documentation rules

- `docs/README.md` is the maintained authority map.
- The active set contains only `docs/architecture.md`, `docs/operations.md`,
  and `docs/roadmap.md`.
- Preserve active `RTC-ARCH-*` and `RTC-DEV-*` identities. Do not reuse an
  archived identity or change its historical meaning.
- A deferred capability needs a new active architecture decision and a small
  reviewed contract before implementation. Archived wording is design input,
  not current authority.
- Distinguish observed capability, planned behavior, test evidence, benchmark
  observations, and qualification claims.
- Keep Mermaid diagrams compatible with VS Code's built-in renderer. Diagrams
  explain relationships; prose and tables remain authoritative.

## Change and validation discipline

- Inspect the complete worktree before editing. Existing changes belong to the
  user unless the task clearly includes them.
- Keep commits focused and exclude unrelated files. Do not rewrite published
  history unless explicitly requested.
- For documentation changes, check local links, trailing whitespace, final
  newlines, unique active and archived requirement definitions, and Markdown
  rendering.
- Mermaid CLI is available through the local Podman image
  `ghcr.io/mermaid-js/mermaid-cli/mermaid-cli:latest`. Render every changed
  Mermaid document, preferably by mounting the repository read-only and
  writing output to a temporary directory. For example:

  ```sh
  podman run --rm -v "$PWD:/work:ro,Z" \
    ghcr.io/mermaid-js/mermaid-cli/mermaid-cli:latest \
    -i /work/docs/architecture.md -o /tmp/architecture.md \
    -a /tmp/architecture
  ```

- Once a Rust workspace exists, run formatting, focused tests, workspace
  tests, and Clippy in proportion to the change.
- The development performance comparison is characterization only. Do not
  infer a deadline, tail-latency, physical-loop, safety, or real-time claim
  from a functional test or microbenchmark.
