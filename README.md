# PipeWireAO RTC

`pipewireao-rtc` is the headless real-time-controller product built around
PipeWireAO and Calculon. This repository owns the system-level application:
instrument lifecycle, graph deployment, configuration and artifact admission,
operator control, telemetry, recording, audit, and run reconstruction.

The repository currently contains the proposed architecture and delivery
contracts. Runtime implementation has not started here yet.

## Repository boundaries

| Repository | Authority |
|---|---|
| `pipewireao-rtc` | RTC product behavior, lifecycle, deployment, operations, scientific command semantics, audit, and delivery plan |
| [PipeWireAO](https://github.com/DarrylGamroth/PipeWireAO) | Generic SPA/PipeWire ndarray transport, FGN plugin and host ABI, acquisition metadata, polling loops, row-block transport, and progressive execution |
| `calculon-algorithms` | Transport-neutral scientific algorithms and declarations |
| PipeWireAO device-plugin repositories | Camera, deformable-mirror, file-source, and other hardware adapters |
| `pipewireao-gui` | Interactive inspection, control, and visualization client |

The RTC uses public, versioned PipeWireAO interfaces. Product policy does not
belong in the PipeWire daemon, and generic data-plane mechanisms do not belong
in this repository.

## Documents

Start with the [document index](docs/README.md). The main entry point is the
[system architecture](docs/architecture.md).
