# PipeWireAORTC

`pipewireao-rtc` is the headless, non-actuating adaptive-optics application. It
owns admission, lifecycle and declared application links through its Julia
`MediaSession` module and public PipeWireAO interfaces. Independent WirePlumber
may provide site-configured device policy separately. The Julia package provides
configuration, installation and native clients. systemd user
services own process lifetime and resource policy. PipeWireAO schedules NDArray transport;
FGN and FilterGraphs execute the scientific graphs. AOS/HIL supplies simulated instrument
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

Version 0.7.1 selects the updated optional graph dependency cohort, which
uses `FilterGraphAlgorithms` 0.12, `FilterGraphs` 0.10
(UUID `8053475d-7091-4a8a-adbc-8ed688b6da8d`) and `FilterGraphPipeWire` 0.5.
`FilterGraphs` replaces the former `JuliaFilterGraph` package identity;
`FilterGraphPipeWire` now also owns the standalone launcher previously supplied
by `FilterGraphIsland`. The `filtergraph-island` command keeps its name.
Programmatic admission uses `FilterGraphPipeWire.prepare_service_graph(path;
initial_parameters=...)`; command parsing belongs to launchers. This source
cohort requires PipeWireAO 0.9.2 and native SDK/JLL 4.0.2. Development validation can
select local package sources. Installed applications resolve the released cohort
from the existing custom registry.

The callable session modules use application names. Update former
`WirePlumber*` module references to the following bindings when upgrading:

New applications select the RTC package and its dependencies through their sealed
Project/Manifest. PipeWireAO provides the selected native libraries and runtime
assets. Classic records the selected native prefix and seals its registered
package pins. Development and release tooling require Julia 1.13 or newer.

| Module | Purpose |
| --- | --- |
| `SessionConfiguration` | Generate and write native session configuration |
| `SessionInstall` | Install a sealed session package |
| `SessionRuntime` | Start, attach, inspect and stop an installed session |
| `SessionClient` | Send controls to a selected session |
| `ConfigurationStore` | Register and retrieve Git artifacts through a SQLite catalog |
| `ConfigurationStoreCLI` | Headless management interface used by GUI, CLI and scripts |
| `CalibrationAcquisition` | Sequence calibration acquisition actions |
| `CalibrationCLI`, `SessionCLI` | Translate command arguments and reports |
| `OwnerBootstrapRuntime`, `ParameterSource`, `SourceControl` | Cold admission, parameter publication and source controls |
| `Artifacts` | Select FITS images and prepare owned arrays and transient wire bytes |
| `GraphOwner`, `AOSOwner` | Package-owned optional scientific owners, configured with graphs and FITS bindings |

## Registered applications

A deployment selects `runtime = { kind = registered project = "." }` in
`deployment.conf`. Its sealed Project/Manifest resolve registered packages,
including PipeWireAORTC; the application does not bundle a copy of the RTC
package or its test workspace. Instrument identity, simulation declarations,
RTC configuration, graphs and profiles remain authored in the instrument
repository. The shared build tool prepares those files against the registered
application environment. The native PipeWireAO prefix is supplied explicitly
at installation. The installer generates its launcher and exact systemd unit;
the registered Julia dependency supplies the implementation. Existing sealed
SDK deployments retain their recorded runtime and require their matching tools.

`GraphOwner.main` accepts existing graph options plus `--fits-bindings PATH`.
`AOSOwner.main` accepts a simulation configuration through `--config PATH`.
Both publish native Preparing before optional scientific packages load. These
modules load no science during an ordinary operational client import. See the
[Classic delivery and validation record](docs/CLASSIC_REGISTERED_DEPLOYMENT.md).

For example, `PipeWireAORTC.SessionCLI.main(["sessions"])` is the callable
counterpart of the root `session_cli.jl` command. Root `session_*.jl`
files are thin command entry points; their implementation loads with the package
from `src/configuration/`, `src/deployment/` and the `src/*_cli.jl` modules.
Control protocol codecs, clients and endpoints live under `src/control/`.
Correction sequencing lives under `src/correction/`; graph execution and
simulation preparation live under `src/graphs/` and `src/simulation/`.
The registered application environment is the supported launch path for new
deployments. Existing sealed SDK deployments retain their recorded runtime and
must use the matching older tools; the registered installer does not migrate
their package contents.

RTC 0.7.1 requires FilterGraphAlgorithms 0.12, FilterGraphs 0.10,
FilterGraphPipeWire 0.5.2, PipeWireAO 0.9.2 and the native/JLL 4.0.2 SDK.
The [0.7.1 release record](docs/validation/filtergraphs-010-20261107/publication.md)
tracks publication and final public-registry verification. RTC 0.7.0 retains
FilterGraphs 0.9 in its sealed cohort.
The development manifest and exported applications resolve package dependencies
from the custom registry. See the [FilterGraphs 0.10 migration](docs/validation/filtergraphs-010-20261107/README.md)
and [artifact release verification](docs/validation/rtc-cohort-402-20261106/README.md)
for source identities, checks and qualification limits. Installed applications
keep their existing sealed dependencies until explicitly rebuilt and installed.

The 0.7 API cleanup removes the `Native` prefix from Julia control modules:
for example, use `SessionClient`, `ControlClient` and `ParameterSource` in place
of their former `Native*` names. See the [complete migration mapping](docs/reviews/20261104-package-cleanup/REVIEW.md#pkg-04--public-names-repeat-the-selected-transport).
Update source callers and regenerate deployments with the matching package
version; existing sealed applications retain their pinned APIs and files.

Use Julia help for callable contracts, including optional science entry points
before their extensions load. For example, enter
`?PipeWireAORTC.CalibrationAcquisition.Plan` or
`?PipeWireAORTC.InstrumentConfiguration.prepare_system` at the REPL. Docstrings
describe ownership, units and lifecycle effects; the architecture and operating
contract remain authoritative for system requirements.

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

A sealed application includes its scientific configurations, calibration artifacts,
owner declarations, generated RTC launcher and registered Project/Manifest.
Instantiate its selected dependencies before launch; RTC and scientific code load
from those packages. The selected PipeWireAO prefix supplies the native runtime.
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

Classic's instrument authoring files and shared build commands live in the
[instrument repository](../../adaptive-optics-simulations/README.md). Its
physical identity, optical simulation definitions, RTC configuration, graphs
and deployment profiles stay there as data. The root build tool resolves
PipeWireAORTC through the selected registered application Manifest; it does not
copy the RTC source tree into the generated application. The current Classic
instrument project pins RTC 0.4.4, so it needs a coordinated package and
launcher declaration update before adopting this dependency-only deployment
contract. Do not treat the documented historical Classic build as proof of a
build against the current package. Existing sealed output remains on its
recorded runtime.
The former `revolt-classic-rtc` application repository is superseded by
`adaptive-optics-simulations/revolt-classic`; its checkout is no longer required.
Dated validation records retain their original application paths and revisions.
The former `REVOLTRTC.jl` launcher is retired; older sealed packages retain
their recorded runtime and are not migrated by this command.

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

See [headless artifact registration](docs/JULIA_DEPLOYMENT_USAGE.md#headless-artifact-registration) for catalog and script usage.

## Source layout

| Path | Responsibility |
| --- | --- |
| `Project.toml`, `Manifest.toml` | Julia package identity and pinned operational environment |
| `src/control/` | Control codecs, clients, endpoints and cold admission |
| `src/correction/` | Correction-loop control, recovery, supervision and physical offsets |
| `src/graphs/` | Scientific graph preparation and execution entry point |
| `src/simulation/` | Simulation entry point and pupil-source configuration |
| `src/diagnostics/` | Phase timing capture |
| `runtime/` | C native runtime and local management companion |
| `test/` | Package tests and native protocol records under `test/data/` |
| `assets/deployment/` | Generic systemd, PipeWire and parameter-source resources |
| `configs/` | Retained development graph/session configurations |
| `session_*.jl` | One-shot native session and systemd installation commands |

Session lifecycle policy lives in the headless RTC process under `runtime/`. The RTC Rust crate is
retired: the GUI owns its native Rust client, and calibration driving uses the
shared Julia implementation. Existing sealed SDKs retain their original files
and launchers. Current instrument definitions are in the
[instrument repository](../../adaptive-optics-simulations/README.md), with reusable
preparation and deployment in this package. Dated REVOLTRTC/Copper/HEART guides
preserve historical procedures and evidence; they do not establish qualification
of those instruments on the current shared path.

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

`SourceControl` owns the existing native v1 source run/reset/query mailbox
and retained snapshots. The implementation was moved from the REVOLT HIL
resources without changing wire keys, IDs or request/response semantics.
Instrument owners apply accepted requests between completed exchanges and
publish under their source loop lock. Scientific stepping and reporting remain
with each instrument; callbacks stage only bounded scalar requests.

## Fault qualification tests

[RTC fault tests](test/integration/README.md) cover session lifecycle fault paths
and opt-in installed-session sink/link loss and graph-owner exit. They run in
isolated sessions and preserve the headless RTC/systemd authority boundary.
Physical-device safe-state and recovery qualification remain outside the current
non-actuating profile.
