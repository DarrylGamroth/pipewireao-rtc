# PipeWireAO RTC

`pipewireao-rtc` provides configuration, installation and native control clients
for a headless, non-actuating adaptive-optics workstation. WirePlumberAO Lua
owns session admission, lifecycle and external links. systemd user services own
process lifetime and resource policy. PipeWireAO schedules NDArray transport;
FGN and JFG execute the scientific graphs. AOS/HIL supplies simulated instrument
sources and sinks; AOC supplies calibration algorithms.

The Rust Statig runner and Julia `DeploymentRunner` are retired. Scientists
continue to develop typed algorithms and ordinary graph configurations. The GUI
and command-line tools act as clients of the same WirePlumber session authority.

## Start here

- [Current work and qualification](docs/roadmap.md#current-work)
- [Ownership and migration design](docs/WIREPLUMBER_SESSION_DESIGN.md)
- [Julia deployment and calibration tools](docs/JULIA_DEPLOYMENT_USAGE.md)
- [Installed replacement checks](docs/validation/wireplumber-session-20261007/SESSION_CHECKS.md)

## Launch a sealed session package

Instantiate the one-shot tooling environment:

```sh
julia --startup-file=no --project=deployment/julia -e 'using Pkg; Pkg.instantiate()'
```

A sealed package includes its scientific configurations, calibration artifacts,
scientific owners, Julia SDK and selected WirePlumberAO binary/modules/scripts.
The start helper installs to a fresh stage, starts an exact systemd instance,
and returns after held admission. The helper exits; WirePlumber remains the
session authority.

```sh
julia --startup-file=no --project=deployment/julia -e '
    using PipeWireAODeployment
    W = PipeWireAODeployment.WirePlumberSessionRuntime
    println(W.start!(ARGS[1], ARGS[2]))
' /absolute/sealed-package /absolute/fresh-stage
```

The default PipeWireAO prefix is `/opt/pipewireao`. Select another installed
prefix with the helper's `prefix` keyword. Startup verifies actual process
incarnations, native readiness and declared placement before acquisition is
released. Packages with missing WirePlumber assets are rejected.

## Native session control

Build the Rust client and list candidate sessions:

```sh
cargo build --features live
cargo run --features live -- session --list
```

Explicit selection proves the exact live endpoint and fresh Status. Commands
use native PipeWire serialization; JSON on stdout is only a local report.

```sh
cargo run --features live -- session --session UUID -- status
cargo run --features live -- session --session UUID -- session-start
cargo run --features live -- session --session UUID -- session-stop
cargo run --features live -- session --session UUID -- reset
cargo run --features live -- session --session UUID -- properties GRAPH
cargo run --features live -- session --session UUID -- quit
```

Gain updates and sparse ndarray parameter publication use the same endpoint.
Submission and graph adoption are separate observations. Clients never
reconnect or repeat a request after an unknown outcome. Normal Quit requests
WirePlumber withdrawal; systemd cleanup reconciles the exact owned cohort.
Emergency `systemctl --user stop UNIT` is process cleanup, not proof of a
successful public shutdown.

## Source layout

| Path | Responsibility |
| --- | --- |
| `src/control/` | Operator commands, domain types and native control envelopes |
| `src/session/` | Session discovery, protocol, connection clients and CLI |
| `src/calibration/` | Completion-driven acquisition and native calibration clients |
| `src/connection.rs` | Private socket connection support |
| `configs/` | Retained development graph/session configurations |
| `tests/data/` | Serialized protocol records and test input data |
| `deployment/julia/` | Julia export, installation, session and calibration clients |

Unit tests live beside each Rust domain under its `tests/` directory. Existing
flat Rust module imports remain aliases for GUI/client compatibility; new code
uses the domain paths. Session lifecycle policy lives in WirePlumberAO Lua,
not this crate.

The 2026-10-08 organization change passed 99 live-feature Rust tests,
19 default-feature Rust tests, Clippy with warnings denied, and 2,663 Julia SDK
assertions. Existing default/live public imports compile; all 19 development
configs and 94 non-Markdown test-data files remain byte-identical. These are
source/API checks, not new live-loop or timing qualification.

## Qualification scope

Copper complete-frame CPU FGN/JFG with CUDA AOS passes the recorded 512-exchange
scientific checks and exact retained per-engine prefixes, plus live gain/matrix
adoption. Simulator tail allocation/GC counters are zero. These checks do not
establish target timing, physical authority, every failure case, Classic or
row-block parity under the new session owner, or the full calibration campaign.
The algorithms and accepted artifacts remain with their scientific owners.
Historical runner reports retain their original revision and scope.
