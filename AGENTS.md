# PipeWireAORTC agent instructions

## Start here

- Check the branch, revision and full worktree status. Preserve unrelated edits
  and running processes. Use a dedicated branch and worktree for substantial work.
  Edit sibling repositories only when the task includes them.
- Start with the [task index](docs/README.md) and the affected sections of the
  [architecture](docs/architecture.md), [operating contract](docs/operations.md)
  and [current roadmap](docs/roadmap.md#current-work). Use `rg` to locate
  requirements and follow the relevant delivery dependencies. Preserve the
  identities and meanings of `RTC-ARCH-*` and `RTC-DEV-*`.
- Maintain delivery status in the roadmap's **Current work** section. Use the
  [evidence index](docs/EVIDENCE_INDEX.md) to find or record dated results. Reuse
  evidence only within its source, dependency, configuration and measurement
  scope. Leave the inactive full-RTC archive alone unless the task changes scope.

## Ownership

- This repository owns the non-actuating development RTC. Under RTC-ARCH-026,
  [MediaSession](src/media_session/MediaSession.jl) is the sole application
  authority for lifecycle, exact admission, declared PipeWire Links and
  execution groups. Use the public PipeWireAO.jl bindings to native APIs.
  Keep RTC policy in MediaSession and implement new transport behavior in
  native PipeWireAO before exposing it in the binding. systemd owns process
  lifetime. GUI and CLI tools are clients. Independent WirePlumber may provide
  site/device policy. Keep Lua, libwireplumber and retired coordinators out of
  the RTC runtime.
- PipeWireAO owns NDArray transport, negotiation and data scheduling. FGN and
  FilterGraphs own graph execution. Scientific packages own transport-neutral,
  array-testable Algorithms. External graph and device owners expose public,
  versioned contracts. Compose declared complete-frame and row-block owners
  through those contracts. Keep frame processing and scheduling outside the RTC
  runner and keep SPA callbacks and worker machinery out of Algorithms.
- AdaptiveOpticsSimPipeWireHIL owns simulator execution and startup settings.
  RTC retains cold export, calibration assets and native source-control and
  bootstrap contracts for independent providers. HEART remains an external
  owner. For an already-publishing input, use the
  [independent service binding](docs/HIL_CONFIGURATION.md#attach-an-rtc-to-an-already-publishing-source).
  Verify live endpoints and placement on each RTC activation. The provider owns
  its process, publication and model clock across RTC restarts. Follow the
  [offset calibration contract](docs/operations.md#rtc-dev-027--simulation-derived-calibration-offsets)
  for simulated and declared hybrid inputs.
- RTC owns calibration projections, native live acquisition and its clients,
  preparation evidence, bundle validation and export. Shared instrument tools
  own dark, lamp, qualification, offline optical and interaction campaigns and
  bundle staging. AdaptiveOpticsCalibration owns numerical reductions.
- Physical-device authority, durable recording, remote access and target-host
  qualification remain deferred.

## Implementation

- Follow the [Julia design conventions](docs/architecture.md#julia-design-conventions),
  including [.JuliaFormatter.toml](.JuliaFormatter.toml). Put `using`, `import`,
  `export` and `public` at the top. Include child modules before importing them
  and preserve optional package loading and import-order checks. Use `#` for
  implementation comments. Document public and exported functions with a
  triple-quoted docstring, indented signature and imperative summary. Describe
  units, ownership and failure behavior where relevant.
- Keep shared Julia code in `src/`, package tests in `test/` and native protocol
  records in `test/data/`. Use Julia for maintained scripts and scripting tests.
  Reuse public interfaces and codecs. Use upstream PipeWire terms with Julia
  naming, retain exact wire and historical report fields, and name test inputs
  by their domain role.
- Use documented abstract interfaces, concrete representations and dispatch for
  domain behavior. Use traits for independent capabilities. Normalize native
  records at ingress, keep correlated facts together and preserve the partial
  ordering of coupled-controller generations.
- Use Hsm.jl for Julia control state machines. Public operations dispatch domain
  events and state handlers decide phase-dependent behavior. Keep scientific
  commands outside entry and exit handlers, preserve one-shot effects, and use
  internal handling for updates that keep the existing entry deadline. Record
  consequential execution-boundary exceptions and their verification evidence.
- Give each long-lived cross-thread controller a single Agent.jl owner of its
  Hsm and mutable state. Use bounded typed messages, replies or immutable
  snapshots. Define queue capacity, full and closed behavior, and shutdown
  acknowledgements. Keep native callbacks nonblocking, retain required PipeWire
  locks for native transactions and release those locks before waiting for
  replies. Keep scientific execution on the PipeWire data thread. Use the
  public native command endpoint for blocking calibration graph workers and
  reclaim their storage after explicit release and task completion. Cold-bound
  calibration nodes omit live sparse Parameter Ports.
- Use Clocks.jl monotonic time for control deadlines. Sample the owned cached
  clock once per duty cycle, preserve producer receipt times and validate
  transport deadlines with fresh time. Preserve public units and deterministic
  clock injection. Keep elapsed time separate from epoch and reference times.
- Use native PipeWire serialization for live controls (RTC-ARCH-024 and
  RTC-DEV-030). Preserve finite deadlines, exact correlation and unknown
  outcomes without an operation journal or a durable write gate. Artifact
  provenance and management receipts have separate contracts. Require live
  protocol evidence for readiness.
- Use bounded YAML for human-authored instrument, RTC, simulation, profile,
  calibration and GUI configuration, and relaxed SPA-JSON for native PipeWire
  configuration. Keep instrument declarations and named graphs in the
  instrument repository. Use the sealed application Project/Manifest to deploy
  PipeWireAORTC as a registered dependency. Keep copied SDK runtimes and the
  development test workspace out of new payloads. Preserve existing sealed
  applications and their pinned launchers.
- Change the authoritative source or generator, then regenerate affected
  outputs, hashes and receipts with the supported tooling. Locate the generation
  path before editing, and review source and output diffs together. Start
  generated text with a `Generated` header where the format permits comments.
  Add regeneration guidance where known. Use FITS header cards or
  schema-supported provenance for strict formats and preserve binary layouts.

## Validation

Use Julia 1.13 or newer. Check [Project.toml](Project.toml) for package
compatibility and the selected environment for the resolved Julia and native
dependencies. Run the core tests from the RTC package environment with the
matching native prefix:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.test(; allow_reresolve=false)'
```

- Choose focused checks by behavior. For cold instrument export and profile
  validation, use [test_instrument_export.jl](test/test_instrument_export.jl).
  For export, registered resolution, installation and software relocation,
  run `julia --startup-file=no --project=. test/runtime_install_registry.jl`
  after instantiating the workspace. This selector registers the Git `HEAD`
  tree in a disposable depot under `/var/tmp` and verifies the installed
  dependency trees against the workspace lock. It uses the PipeWireAO JLL
  prefix unless `PIPEWIREAO_PREFIX` selects a compatible SDK. Pass an LCOV
  output path as the optional argument to record the registered CLI's
  coverage against the checkout. For offline export without a registry
  entry, pass `--prepare-only` to
  [runtime_install.jl](test/runtime_install.jl). The installation selector uses
  temporary applications without starting services. Reinstall generated units
  after moving an application with absolute service paths.
- Use the [HIL configuration guide](docs/HIL_CONFIGURATION.md) for simulation
  export selectors. Use the instrument repository's README for instrument
  build, calibration and private-core commands. For optional science or
  accelerator checks, use an environment containing the relevant extension
  dependencies. The compiled simulation export selector needs matching HIL
  test sources. For [captured optical preparation](test/captured_optical_preparation.jl),
  select `PIPEWIREAORTC_TEST_BACKEND=cpu`, `cuda` or `amdgpu` in the matching
  environment.
- Use the [integration guide](test/integration/README.md) for MediaSession
  private-core and installed-session checks. For the
  [calibration command endpoint](docs/reviews/20261104-calibration-worker/REVIEW.md),
  match the client libraries and `PIPEWIREAO_PREFIX`. Run
  `calibration_transport.jl` with `--threads=3,1` and
  `calibration_named_transport.jl` and `calibration_readiness.jl` with
  `--threads=4,1`. The extra interactive thread runs the control task.
  Use three default threads for
  `test_calibration_capture_private_core.jl`.
- The [physical-offset private-core selectors](docs/reviews/20261105-graph-buffers/REVIEW.md)
  use the HIL helper. Use three default threads for
  `physical_offset_inputs_private_core.jl` and `--threads=4,0` for
  `physical_offsets_private_core.jl`. The helper selects its daemon via
  `PIPEWIREAO_HIL_TEST_PREFIX` or the JLL default. Match client libraries to that
  daemon.
- For changes to the C management companion, use the
  [Meson and private-socket checks](runtime/README.md#compiled-management-companion).
  Live and hardware checks are opt-in. Leave existing daemons, instruments and
  experiments running. Preserve failed gates and their scope. Report functional,
  numerical, allocation, cadence, latency and hardware results with their own
  validation scopes.
- For documentation changes, check local links and anchors, Markdown structure,
  whitespace, final newlines and requirement IDs. Render changed Mermaid
  diagrams with the local Podman image
  `ghcr.io/mermaid-js/mermaid-cli/mermaid-cli:latest`, mounting source read-only
  and writing to a temporary directory. Keep diagrams VS Code-compatible.
- Commit each coherent, verified changeset. Keep commits focused and preserve
  local dependency order and published history.
