# PipeWireAO RTC

`pipewireao-rtc` is the small headless development runner for Calculon graphs
on PipeWireAO. Its first target loads one simulated or recorded source, one
native ndarray filter graph, and one non-actuating sink from a standard
PipeWire configuration. The planned RTC workstation extension composes
multiple existing filter graphs and explicit PipeWire links under one session
lifecycle without adding another graph-authoring format.

The repository contains a partial runner plus the active development
architecture and delivery contract. Physical devices, correction authority,
recording, Julia execution, remote operation, progressive scheduling, and
real-time qualification are deliberately deferred.

## Repository boundaries

| Repository | Authority |
|---|---|
| `pipewireao-rtc` | Development configuration, exact graph realization, basic lifecycle, diagnostics, equivalence, and scientist-facing integration boundary |
| [PipeWireAO](https://github.com/DarrylGamroth/PipeWireAO) | Generic SPA/PipeWire ndarray transport, FGN plugin and host ABI, acquisition metadata, polling loops, row-block transport, and progressive execution |
| `calculon-algorithms` | Transport-neutral scientific algorithms and declarations |
| PipeWireAO device-plugin repositories | Camera, deformable-mirror, file-source, and other hardware adapters |
| `pipewireao-gui` | Interactive inspection, control, and visualization client |

The runner uses public, versioned PipeWireAO interfaces. Generic data-plane
mechanisms do not belong in this repository.

## Documents

Start with the [document index](docs/README.md). The main entry point is the
[development architecture](docs/architecture.md). The former full-RTC proposal
is preserved as an [inactive design archive](docs/archive/full-rtc/README.md).
