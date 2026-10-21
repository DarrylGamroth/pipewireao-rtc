# PipeWireAORTC

`pipewireao-rtc` is the headless, non-actuating adaptive-optics application. It
owns admission, lifecycle and declared application links, reusing public
libwireplumber interfaces. Upstream WirePlumber may run with site-configured
device policy, managed separately from this package. The ordinary Git fork is a
contribution vehicle; the runtime remains upstream WirePlumber. The Julia
package provides configuration, installation and native clients. systemd user
services own process lifetime and resource policy. PipeWireAO schedules NDArray transport;
FGN and JFG execute the scientific graphs. AOS/HIL supplies simulated instrument
sources and sinks; AOC supplies calibration algorithms.

The Rust Statig runner and Julia `DeploymentRunner` are retired. Scientists
continue to develop typed algorithms and ordinary graph configurations. The GUI
and command-line tools act as clients of the same headless RTC authority.

## Start here

- [Current work and qualification](docs/roadmap.md#current-work)
- [Ownership and migration design](docs/HEADLESS_RTC_DESIGN.md)
- [Julia deployment and calibration tools](docs/JULIA_DEPLOYMENT_USAGE.md)
- [Proposed Julia RTC structure and migration](docs/JULIA_RTC_STRUCTURE_PLAN.md)
- [Installed replacement checks](docs/validation/wireplumber-session-20261007/SESSION_CHECKS.md)

## Development workspace

Open [rtc.code-workspace](rtc.code-workspace) to edit the shared RTC package,
REVOLT application, scientific graph packages, PipeWireAO, the WirePlumber
upstream/package integration, GUI and the Classic, Copper and GPI 2.0 plants
together. The `rtc` folder is the
checkout containing this workspace file; opening it in a worktree selects that
worktree explicitly. Each repository retains its own history and dependencies.
The workspace does not start services or select a Julia deployment environment.

The [simulation integration contract](docs/REGISTERED_RTC_MIGRATION.md#independent-simulators-and-rtc-definitions)
separates instrument definitions, controller graphs, session connections and
optional GUI views.

## Julia package API

The shared Julia package is `PipeWireAORTC` (UUID
`a3e2c7da-f73f-4284-8482-36ac422b34e6`). Update `using PipeWireAODeployment`
to `using PipeWireAORTC` and resolve the environment after upgrading. Existing
native protocol names and v1 records retain their identities.

The callable session modules use application names. Update former
`WirePlumber*` module references to the following bindings when upgrading:

| Module | Purpose |
| --- | --- |
| `SessionConfiguration` | Generate and write native session configuration |
| `SessionInstall` | Install a sealed session package |
| `SessionRuntime` | Start, attach, inspect and stop an installed session |
| `NativeSessionClient` | Send controls to a selected native session |
| `ConfigurationStore` | Register and retrieve Git artifacts; query the shared SQLite journal |
| `ConfigurationStoreCLI` | Headless management interface used by GUI, CLI and scripts |
| `SimulatorConfiguration` | Describe declared simulator settings and submit/observe cold application replacement jobs |
| `CalibrationAcquisition` | Sequence calibration acquisition actions |
| `CalibrationCLI`, `SessionCLI` | Translate command arguments and reports |
| `NativeOwnerBootstrapRuntime`, `NativeParameterSource`, `NativeSourceControl` | Reusable cold owner entry points and native source controls |
| `Artifacts` | Select FITS images and prepare owned arrays and transient wire bytes |
| `GraphOwner`, `AOSOwner` | Package-owned optional scientific owners, configured with graphs and FITS bindings |

## Registered applications

A deployment may select `runtime = { kind = registered project = "." }` in
`deployment.conf`. Its sealed Project/Manifest resolve registered packages;
no framework source or raw calibration files belong in the application.
The native PipeWireAO/WirePlumber prefix is supplied explicitly at installation.
The installer generates its launcher and exact systemd unit, while the Julia
package supplies the implementation. Existing sealed SDKs retain their path.

`GraphOwner.main` accepts existing graph options plus `--fits-bindings PATH`.
`AOSOwner.main` accepts a simulation configuration through `--config PATH`.
Both publish native Preparing before optional scientific packages load. These
modules load no science during an ordinary operational client import. See the
[Classic delivery and validation record](docs/CLASSIC_REGISTERED_DEPLOYMENT.md).

For example, `PipeWireAORTC.SessionCLI.main(["sessions"])` is the callable
counterpart of the root `session_cli.jl` command. Root `session_*.jl`
files are thin command entry points; their implementation loads with the package
from `src/configuration/`, `src/deployment/` and `src/cli.jl`. Native protocols
live under `src/native/`, and reusable owner runtimes live under `src/owners/`.
The sealed SDK launch path remains available during application migration.

### FITS calibration inputs

```julia
using PipeWireAORTC.Artifacts
reference = FITSArtifact("artifacts/reference-slopes.fits"; hdu=1, axes=(2, 1))
prepared = prepare(reference, Float32, (188, 2))
slopes = prepared.data  # owned logical subaperture × axis array
```

Multidimensional FITS inputs require explicit axis order, including square
matrices. Preparation validates bounds, finite values and exact integer/Boolean
conversion, retaining hashes and FITS units in `prepared.provenance`. It performs
no calibration or unit conversion and creates no packed artifact files.

Sparse parameter-source configuration version 2 accepts `initial_artifact`
instead of version 1's `initial_payload_path`. A selection has `path`, optional
one-based `hdu`, and explicit multidimensional `axes`; relative paths resolve
against the configuration file. This is cold FITS preload support. Native v1 live
requests retain their raw-file contract; FITS live replacement remains a separate
owner/adoption interface. See [migration contracts and evidence gates](docs/REGISTERED_RTC_MIGRATION.md).

## Launch a sealed session package

Instantiate the one-shot tooling environment:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()'
```

A sealed package includes its scientific configurations, calibration artifacts,
scientific owners, Julia SDK, native headless RTC and selected libwireplumber
library/modules. Build the native host from [native/](native/README.md).
The start helper installs to a fresh stage, starts an exact systemd instance,
and returns after held admission. The helper exits; the headless RTC remains
the session authority.

```sh
julia --startup-file=no --project=. -e '
    using PipeWireAORTC
    W = PipeWireAORTC.SessionRuntime
    println(W.start!(ARGS[1], ARGS[2]))
' /absolute/sealed-package /absolute/fresh-stage
```

The default PipeWireAO prefix is `/opt/pipewireao`. Select another installed
prefix with the helper's `prefix` keyword. Startup verifies actual process
incarnations, native readiness and declared placement before acquisition is
released. Packages missing the headless RTC or required library assets are rejected.
Old sealed deployments keep their recorded runtime; generate a new package to
use this ownership change. There is no fallback to the WirePlumber daemon.

Cold Julia/CUDA compilation can need a longer preparation budget. A sealed
profile may explicitly set `startup-timeout-ms` (1000–3600000); the default is
300000. This setting applies to systemd startup, owner admission and initial
session publication. The caller's absolute deadline must also cover installation
and startup. Live controls and acquisition retain their existing deadlines.
Budgets above five minutes require the matching RTC owner policy.

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
julia --startup-file=no --project=. session_cli.jl sessions
```

Explicit selection proves the exact live endpoint and fresh Status. Commands
use native PipeWire serialization; JSON on stdout is only a local report.

```sh
julia --startup-file=no --project=. session_cli.jl control --session UUID -- status
julia --startup-file=no --project=. session_cli.jl control --session UUID -- session-start
julia --startup-file=no --project=. session_cli.jl control --session UUID -- session-stop
julia --startup-file=no --project=. session_cli.jl control --session UUID -- reset
julia --startup-file=no --project=. session_cli.jl control --session UUID -- properties GRAPH
julia --startup-file=no --project=. session_cli.jl control --session UUID -- quit
```

Gain updates and sparse ndarray parameter publication use the same endpoint.
Submission and graph adoption are separate observations. Clients never
reconnect or repeat a request after an unknown outcome. Normal Quit requests
headless RTC withdrawal; systemd cleanup reconciles the exact owned cohort.
Emergency `systemctl --user stop UNIT` is process cleanup, not proof of a
successful public shutdown.

See [headless artifact registration and shared update history](docs/JULIA_DEPLOYMENT_USAGE.md#headless-artifact-registration-and-shared-update-history) for catalog, script and GUI usage.

## Source layout

| Path | Responsibility |
| --- | --- |
| `Project.toml`, `Manifest.toml` | Julia package identity and pinned operational environment |
| `src/` | Julia native clients, shared operational tools |
| `native/` | Headless executable, application Lua policy, native control and journal modules |
| `test/` | Package tests and native protocol records under `test/data/` |
| `assets/deployment/` | Generic systemd, PipeWire and parameter-source resources |
| `configs/` | Retained development graph/session configurations |
| `session_*.jl` | One-shot native session and systemd installation commands |

Session lifecycle policy lives in the headless RTC process under `native/`. The RTC Rust crate is
retired: the GUI owns its native Rust client, and calibration driving uses the
shared Julia implementation. Existing sealed SDKs retain their original files
and launchers. REVOLT Classic/Copper/HEART integration is in the independent
[REVOLTRTC.jl project](../REVOLTRTC.jl/README.md). Use its export/calibration
commands and `REVOLTRTC.Installation.start!` for instrument preflight; shared
session clients remain instrument-independent.

## Qualification scope

The following historical checks used the former WirePlumber-owned runtime;
they do not qualify the new headless host. Copper complete-frame CPU FGN/JFG
with CUDA AOS passes the recorded 512-exchange
scientific checks and exact retained per-engine prefixes, plus live gain/matrix
adoption. Simulator tail allocation/GC counters are zero. These checks do not
establish target timing, physical authority, every failure case, Classic or
row-block parity under the new session owner, or the full calibration campaign.
The algorithms and accepted artifacts remain with their scientific owners.
Historical runner reports retain their original revision and scope.

## Finite source control

`NativeSourceControl` owns the existing native v1 source run/reset/query mailbox
and retained snapshots. The implementation was moved from the REVOLT HIL
resources without changing wire keys, IDs or request/response semantics.
Instrument owners apply accepted requests between completed exchanges and
publish under their source loop lock. Scientific stepping and reporting remain
with each instrument; callbacks stage only bounded scalar requests.

## Fault qualification tests

[RTC fault tests](test/integration/README.md) cover the production Lua fault path
and opt-in installed-session sink/link loss and graph-owner exit. They run in
isolated sessions and preserve the headless RTC/systemd authority boundary.
Physical-device safe-state and recovery qualification remain outside the current
non-actuating profile.
