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
- [Proposed Julia RTC structure and migration](docs/JULIA_RTC_STRUCTURE_PLAN.md)
- [Installed replacement checks](docs/validation/wireplumber-session-20261007/SESSION_CHECKS.md)

## Launch a sealed session package

Instantiate the one-shot tooling environment:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()'
```

A sealed package includes its scientific configurations, calibration artifacts,
scientific owners, Julia SDK and selected WirePlumberAO binary/modules/scripts.
The start helper installs to a fresh stage, starts an exact systemd instance,
and returns after held admission. The helper exits; WirePlumber remains the
session authority.

```sh
julia --startup-file=no --project=. -e '
    using PipeWireAODeployment
    W = PipeWireAODeployment.WirePlumberSessionRuntime
    println(W.start!(ARGS[1], ARGS[2]))
' /absolute/sealed-package /absolute/fresh-stage
```

The default PipeWireAO prefix is `/opt/pipewireao`. Select another installed
prefix with the helper's `prefix` keyword. Startup verifies actual process
incarnations, native readiness and declared placement before acquisition is
released. Packages with missing WirePlumber assets are rejected.

For an exported REVOLT instrument package, use its preflight before session
startup. From this shared repository root:

```sh
julia --startup-file=no --project=../REVOLTRTC.jl -e '
    using REVOLTRTC
    println(REVOLTRTC.Installation.start!(ARGS[1], ARGS[2]))
' /absolute/sealed-package /absolute/fresh-stage
```

## Native session control

List candidate sessions with the Julia client:

```sh
julia --startup-file=no --project=. wireplumber_cli.jl sessions
```

Explicit selection proves the exact live endpoint and fresh Status. Commands
use native PipeWire serialization; JSON on stdout is only a local report.

```sh
julia --startup-file=no --project=. wireplumber_cli.jl control --session UUID -- status
julia --startup-file=no --project=. wireplumber_cli.jl control --session UUID -- session-start
julia --startup-file=no --project=. wireplumber_cli.jl control --session UUID -- session-stop
julia --startup-file=no --project=. wireplumber_cli.jl control --session UUID -- reset
julia --startup-file=no --project=. wireplumber_cli.jl control --session UUID -- properties GRAPH
julia --startup-file=no --project=. wireplumber_cli.jl control --session UUID -- quit
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
| `Project.toml`, `Manifest.toml` | Julia package identity and pinned operational environment |
| `src/` | Native clients, shared operational tools |
| `test/` | Package tests and native protocol records under `test/data/` |
| `assets/deployment/` | Generic systemd, PipeWire and parameter-source resources |
| `configs/` | Retained development graph/session configurations |
| `wireplumber_*.jl` | One-shot native session and systemd installation commands |

Session lifecycle policy lives in WirePlumberAO Lua. The RTC Rust crate is
retired: the GUI owns its native Rust client, and calibration driving uses the
shared Julia implementation. Existing sealed SDKs retain their original files
and launchers. REVOLT Classic/Copper/HEART integration is in the independent
[REVOLTRTC.jl project](../REVOLTRTC.jl/README.md). Use its export/calibration
commands and `REVOLTRTC.Installation.start!` for instrument preflight; shared
session clients remain instrument-independent.

## Qualification scope

Copper complete-frame CPU FGN/JFG with CUDA AOS passes the recorded 512-exchange
scientific checks and exact retained per-engine prefixes, plus live gain/matrix
adoption. Simulator tail allocation/GC counters are zero. These checks do not
establish target timing, physical authority, every failure case, Classic or
row-block parity under the new session owner, or the full calibration campaign.
The algorithms and accepted artifacts remain with their scientific owners.
Historical runner reports retain their original revision and scope.
