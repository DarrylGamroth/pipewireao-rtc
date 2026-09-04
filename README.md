# PipeWireAO RTC

`pipewireao-rtc` is the small headless development runner for FGN graphs on
PipeWireAO. It loads one or more simulated or recorded sources, existing
native ndarray filter graphs, non-actuating sinks, and exact ordinary PipeWire
links from a standard PipeWire configuration. Serial graphs, one-source
fan-out, and independent paths share one session lifecycle without adding
another graph-authoring format or scheduler. Named execution groups can pause
and resume a whole chain or one independent branch while the session remains
loaded.

The repository contains the first executable runner increment plus the active
development architecture and delivery contract. The maintained live fixture
runs recorded FITS vectors through minimal, serial, forked, and independent
`fgn-native` graph sessions into generic discard sinks. It also discovers an
externally launched AdaptiveOpticsSim HIL source and sink and closes a
deterministic Shack–Hartmann SCAO loop through an RTC-owned FGN graph. The
runner does not load or execute Julia. Physical devices, correction authority,
recording, in-process Julia graph execution, remote operation, progressive
scheduling, and real-time qualification are deliberately deferred.

## Run the development fixture

Build-tree paths are explicit; the runner does not install into or admit system
plugin directories. Against an already running private PipeWireAO core, invoke
it as:

```sh
PIPEWIREAO_FITS_PLUGIN=/absolute/build/spa/plugins/fits/libspa-fits.so \
PIPEWIREAO_RTC_FITS_PATH=/absolute/input/excitation.fits \
PIPEWIREAO_DISCARD_PLUGIN=/absolute/build/spa/plugins/discard/libspa-pipewireao-discard.so \
PIPEWIREAO_RTC_GRAPH_MINIMAL=/absolute/generated/minimal-filter-graph.conf \
cargo run --features live -- \
  --config fixtures/minimal-development.conf \
  --remote private-core-name --hold
```

The command loads to `READY`, starts to `RUNNING`, and opens this small control
prompt:

```text
groups
status
stop GROUP
start GROUP
quit
```

`quit` (or end of input) stops the session to `READY` and unloads it to
`OFFLINE`. Group stop/start preserves the configured objects and links; it does
not reset, reload, or unload the graph. The referenced graph file is the
complete standard argument object for
`libpipewire-module-ndarray-filter-chain`; the runner passes it unchanged. The
held command continuously revalidates the exact global identities and ndarray
contracts of declared external endpoints. Loss, replacement, or incompatible
format mutation moves the session to `FAULT` through the same serialized
lifecycle dispatcher; cleanup still removes only runner-owned objects.
The maintained integration test materializes the fixture graph files, then
creates its own unique runtime directory and core name:

```sh
PIPEWIREAO_SPA_PLUGINS_BUILD=/absolute/plugin/build \
PIPEWIREAO_RTC_FGN_BUNDLE=/absolute/libcalculon_fgn_bundle.so \
PIPEWIREAO_RTC_AOS_HIL_PACKAGE=/absolute/AdaptiveOpticsSimPipeWireHIL.jl \
cargo test --features live --test live_private_core -- --ignored --nocapture
```

## Repository boundaries

| Repository | Authority |
|---|---|
| `pipewireao-rtc` | Development configuration, exact graph realization, basic lifecycle, diagnostics, equivalence, and scientist-facing integration boundary |
| [PipeWireAO](https://github.com/DarrylGamroth/PipeWireAO) | Generic SPA/PipeWire ndarray transport, FGN plugin and host ABI, acquisition metadata, polling loops, row-block transport, and progressive execution |
| `calculon-algorithms` | Legacy-named Rust package containing transport-neutral scientific Algorithms and declarations |
| PipeWireAO device-plugin repositories | Camera, deformable-mirror, file-source, and other hardware adapters |
| `pipewireao-gui` | Interactive inspection, control, and visualization client |

The runner uses public, versioned PipeWireAO interfaces. Generic data-plane
mechanisms do not belong in this repository.

## Documents

Start with the [document index](docs/README.md). The main entry point is the
[development architecture](docs/architecture.md). The former full-RTC proposal
is preserved as an [inactive design archive](docs/archive/full-rtc/README.md).
