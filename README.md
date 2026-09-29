# PipeWireAO RTC

`pipewireao-rtc` is the small headless development runner for processing graphs
on PipeWireAO. It loads one or more simulated or recorded sources, existing
native or externally owned ndarray filter graphs, non-actuating sinks, and
exact ordinary PipeWire links from a standard PipeWire configuration. Serial
graphs, one-source
fan-out, and independent paths share one session lifecycle without adding
another graph-authoring format or scheduler. Named execution groups can stop
and restart a whole chain or one independent branch while the session remains
loaded.

The repository contains the first executable runner increment plus the active
development architecture and delivery contract. The maintained live fixture
runs recorded FITS vectors through minimal, serial, forked, and independent
`fgn-native` graph sessions into generic discard sinks. It also discovers an
externally launched AdaptiveOpticsSim HIL source and sink and closes a
deterministic Shack–Hartmann SCAO loop through an RTC-owned FGN graph. The
runner can also admit an externally owned processing node by its PipeWire
contracts and an explicit run-control grant. The maintained fixture substitutes
an externally owned Julia Filter Graph for the native graph and exercises the
same durable start, stop, restart, and unload sequence. A REVOLT Classic fixture
uses the same external plant nodes with either an RTC-owned native FGN
controller or an externally owned Julia Filter Graph controller and compares
both with direct references. The runner does not load or execute Julia itself.
Physical devices, correction authority,
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
reset
property GRAPH NODE:PROPERTY TYPE VALUE
parameter GRAPH PORT ELEMENT_TYPE DIMS SCHEMA PATH
quit
```

`quit` (or end of input) stops the session to `READY` and unloads it to
`OFFLINE`. Group stop/start preserves the configured objects and links; it does
not reset, reload, or unload the graph. `reset` clears graph processing state
while stopped. `property` submits one typed scalar through the graph's standard
Props surface. `parameter` publishes one complete ndarray value from a file on
the exact configured Parameter Port; dimensions use forms such as `277x376`.
The referenced graph file is the
complete standard argument object for
`libpipewire-module-ndarray-filter-chain`; the runner passes it unchanged. The
held command continuously revalidates the exact global identities and ndarray
contracts of declared external objects. Loss, replacement, or incompatible
format mutation moves the session to `FAULT` through the same serialized
lifecycle dispatcher; cleanup still removes only runner-owned objects.
The maintained integration test materializes the fixture graph files, then
creates its own unique runtime directory and core name:

```sh
julia --startup-file=no --project=/absolute/JuliaFilterGraph.jl/deployment \
  -e 'using Pkg; Pkg.instantiate()'

PIPEWIREAO_SPA_PLUGINS_BUILD=/absolute/plugin/build \
PIPEWIREAO_RTC_PIPEWIRE_BUILD=/absolute/pipewire/build \
PIPEWIREAO_RTC_FGN_BUNDLE=/absolute/libcalculon_fgn_bundle.so \
PIPEWIREAO_RTC_AOS_HIL_PACKAGE=/absolute/AdaptiveOpticsSimPipeWireHIL.jl \
PIPEWIREAO_RTC_REVOLT_HIL_PACKAGE=/absolute/REVOLTClassicSimPipeWireHIL.jl \
PIPEWIREAO_RTC_PIPEWIREAO_JULIA=/absolute/PipeWireAO.jl \
PIPEWIREAO_RTC_JULIA_FILTER_GRAPH=/absolute/JuliaFilterGraph.jl \
cargo test --features live --test live_private_core -- --ignored --nocapture
```

Set `PIPEWIREAO_RTC_LIVE_SCOPE=revolt` on that command to run only the REVOLT
Classic native/Julia equivalence fixture on the isolated core.
Set `PIPEWIREAO_RTC_LIVE_SCOPE=revolt-lockstep` to run the common-input
fixture. Its one WFS source fans each 352 × 352 F32 frame out to distinct
native FGN and JuliaFilterGraph nodes. Separate 277-element F32 metre command
sinks receive matching Header sequences. The provider checks both commands
against the direct Classic oracle and each other before advancing the plant.
This ten-frame fixture uses the initial calibrated reconstructor, gain, and
pole. The separate `revolt` fixture covers controller updates and finite
source completion; simultaneous parity during the parameter-adoption window
remains unverified.

The common-input fixture passed on the development host with this command
on 2026-09-29:

```sh
PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig \
LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
PIPEWIREAO_RTC_FGN_BUNDLE=/home/dgamroth/workspaces/codex/pipewire/calculon-algorithms-copper-fullframe/target/release/libcalculon_fgn_bundle.so \
PIPEWIREAO_RTC_LIVE_SCOPE=revolt-lockstep \
cargo test --features live --test live_private_core -- --ignored --nocapture
```

## REVOLT development configurations

| System | RTC configuration | Input → command | Maintained replay |
| --- | --- | --- | --- |
| Classic, native FGN | [`revolt-classic-native-development.conf`](fixtures/revolt-classic-native-development.conf) | Simulated 352 × 352 F32 SHWFS frame → 277 actuator-surface OPD values in metres | The private-core command above with `PIPEWIREAO_RTC_LIVE_SCOPE=revolt` |
| Classic, JuliaFilterGraph | [`revolt-classic-julia-development.conf`](fixtures/revolt-classic-julia-development.conf) | The same simulated plant and scientific boundary | The same private-core command; it runs after the native fixture |
| Classic, common input | [`revolt-classic-lockstep-development.conf`](fixtures/revolt-classic-lockstep-development.conf) | One simulated WFS frame → native and Julia controllers → separate HSDM277 command sinks | The private-core command above with `PIPEWIREAO_RTC_LIVE_SCOPE=revolt-lockstep` |
| Copper, native FGN | [`revolt-copper-native-development.conf`](fixtures/revolt-copper-native-development.conf) | HEART WFS 64 × 64 U16 detector frame → 277 demanded commands in micrometres | [`run_copper_rtc.py`](benchmark/run_copper_rtc.py), documented in [COPPER.md](benchmark/COPPER.md) |

The Classic fixtures use the external `REVOLTClassicSimPipeWireHIL.jl` plant,
the generated controller graph, and a published 277 × 376 reconstructor
parameter. The Copper replay prepares its calibration in the generated graph
arguments and uses the shared FITS cube through HEART's WFS source. These are
different optical systems and command units; their command vectors are not
interchangeable. Both RTC configurations are complete-frame and non-actuating.

For the latest/hold fixture, set `PIPEWIREAO_RTC_LIVE_SCOPE=latest-hold`. The
Julia environment selected by `PIPEWIREAO_RTC_PIPEWIREAO_JULIA` must resolve
`PipeWireAO_jll` 1.7.0+17 or newer; the JFG `deployment` environment is a
working choice when the local `PipeWireAO.jl` manifest is older.

## Completion-paced REVOLT graph-path latency

The optional [REVOLT latency harness](benchmark/README.md) repeats that same
ignored private-core fixture and records the HIL source Header-PTS through
matching command-receipt interval for the native and external Julia controller
paths. It retains raw observations, excludes warmup from its mergeable
histograms, and checks each recorded sequence and command against the existing
direct controller reference. This is completion-paced simulated graph-path
characterization, not fixed-arrival, detector-readout-overlap, PTP,
camera-to-DM, or hard-real-time qualification. Fair comparisons with HEART
belong at this application boundary with the same workload and arrival model.

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
