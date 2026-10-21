> Current ownership is [RTC-ARCH-026](HEADLESS_RTC_DESIGN.md): the headless RTC
> owns lifecycle and explicit application links, using libwireplumber as a
> library. Upstream WirePlumber remains the runtime; site/device policy is
> configured separately. No AO-specific device policy is currently defined or
> qualified. Dated pilots
> below retain their original providers and evidence scope.

# PipeWireAO ecosystem integration

Direction requested on 2026-10-06; ownership updated on 2026-10-21 to match
[RTC-ARCH-026](HEADLESS_RTC_DESIGN.md). The headless RTC application owns its
lifecycle and connections; upstream WirePlumber may run with separately
configured site/device policy, systemd supervises processes, and PipeWireAORTC
supplies native clients and application/deployment tools. The historical
pilots below retain their original scope; they do not define current ownership.
The [architecture](architecture.md), [operating contract](operations.md) and
[current roadmap](roadmap.md#current-work) remain authoritative.

## Component responsibilities

The workstation should assemble existing components around an ordinary PipeWire
session. Our extensions are NDArray transport and scientific graph execution.
Process supervision, object discovery and general session policy can use systemd
and WirePlumber. Algorithms remain in their scientific packages.

Graph authoring remains in existing PipeWireAO `filter.graph` configurations,
using standard PipeWire relaxed SPA-JSON. AOS model configuration and AOC method
configuration stay with their existing applications. Integration should reference
these configurations rather than introduce another graph language or bundle
format.

| Component | Responsibility | Integration boundary |
| --- | --- | --- |
| **PipeWireAO** | PipeWire with NDArray formats, buffers, ports, metadata and scheduling; the native FGN graph host | Typed NDArray ports, explicit links, native properties and parameters |
| **FGN** | Execute a prepared scientific graph through the native graph host; Rust algorithms come from `calculon-algorithms` and its FGN adapter | An ordinary PipeWire processing node exposing declared ports and controls |
| **JFG** | Prepare and execute Julia scientific graphs; `FilterGraphAlgorithms` supplies algorithms and `FilterGraphPipeWire` publishes the graph | The same kind of ordinary processing node, implemented in Julia |
| **AOS** | Simulate the instrument: atmosphere, optics, mirrors, wavefront sensors and detectors | An owner may publish multiple sources and sinks; the current HIL adapter exposes one WFS/command exchange |
| **AOC** | Prepare probes, estimate interaction matrices, construct reconstructors and calculate calibration diagnostics | Numerical plans, workspaces and results; acquisition uses the deployed instrument endpoints |
| **Upstream WirePlumber** | Optionally apply separately configured site/device policy | Stock WirePlumber configuration and interfaces; no AO-specific device policy is currently defined or qualified |
| **Headless RTC** | Own exact discovery, application links, readiness and coordinated start/stop/reset/failure policy using libwireplumber | Existing native session/owner contracts and public WpLink APIs |
| **systemd** | Start, stop and supervise processes; apply resource and scheduling limits | User services and, where configured, administrator-provisioned resources |
| **PipeWireAORTC application/deployment tools** | Export, install and preflight applications; verify processes and request operations as clients | Standard configuration, systemd services and native session controls |
| **Workstation GUI and CLI tools** | Edit/select configurations, request lifecycle and property/parameter changes, and observe status | Clients of the headless RTC and scientific owners |

FGN and JFG are alternative implementations of a processing role. A session can
contain either or both when their port contracts agree. Matching algorithms,
coordinates, units and calibration artifacts is necessary for numerical
equivalence; choosing another executor alone does not establish equivalence.

PipeWire schedules the published nodes. FGN or JFG schedules its own internal
graph and manages its prepared workspaces and workers. WirePlumber does not
execute the reconstructor or assign individual MVM shards.

Instrument-facing terminology comes from the relevant REVOLT/HEART or GPI 2.0
definitions, including the quantity, units and mirror identity. Applications
publish those labels through the existing metadata surfaces; the GUI does not
translate instruments through hard-coded handlers. A generic internal algorithm
or schema name is not evidence that it matches an instrument-specific quantity.
The [reuse audit](reviews/20261021-wireplumber-reuse/REVIEW.md) records the initial
terminology evidence and unresolved offset mapping.

## Data path

The selected instrument supplies pixels and receives commands. An AOS instance
can occupy this role through its existing adapter.

```mermaid
flowchart LR
    Instrument["Camera and DM, or AOS instrument"]
    WFS["WFS NDArray source"]
    RTC["FGN or JFG processing graph"]
    DM["DM command sink"]
    Instrument --> WFS --> RTC --> DM --> Instrument
```

This diagram shows one WFS/command path, not a limit on an instrument's endpoint
count. The arrows show its scientific path through PipeWireAO ports and links.
Calibration, telemetry and science-camera nodes can be attached through their
declared ports. A real device adapter may use its device protocol internally;
the RTC algorithms still consume and produce their declared array types.

The current development profiles are non-actuating. Real hardware authority and
device admission require their own qualification; this diagram does not assert
that those deployment gates are complete.

## Control and deployment

The selected deployment separates process supervision from session policy and
scientific execution:

```mermaid
flowchart TD
    Systemd["systemd user services"]
    Core["Selected PipeWireAO core"]
    RTC["Headless RTC application"]
    WP["WirePlumber device and shared routing policy"]
    Owners["FGN/JFG and optional AOS owners"]
    Tools["PipeWireAORTC deployment tools"]
    Clients["GUI, CLI and calibration clients"]
    Systemd --> Core
    Systemd --> RTC
    Systemd --> WP
    Systemd --> Owners
    Tools -->|install and preflight| Systemd
    Clients -->|native requests| RTC
    RTC -->|owner controls| Owners
    RTC -->|declared application links| Core
    WP -->|device and shared routing policy| Core
    Owners --> Core
```

The headless RTC owns application admission and lifecycle. Its native endpoint
accepts requests from the GUI, CLI and Julia clients; those clients do not
decide whether a requested transition succeeded. Scientific owners perform
preparation, numerical execution and update adoption. One-shot deployment tools
prepare application environments and systemd units without creating links or
releasing acquisition. Systemd service activation alone never admits ingress.

The [adversarial architecture review](APPLICATION_ARCHITECTURE_REVIEW.md) makes
link-ownership transfer conditional on preserving admission, negotiation and
failure behavior. The first pilot retains established FGN hosting and separate
JFG processes. `module-rt` supplies participating PipeWire thread scheduling;
it does not launch JFG or place every executor worker. WirePlumber's
`pw-module-client` hosting is an optional FGN deployment choice sharing its
process lifetime, not a prerequisite for integration.

### GUI and command-line control

The GUI edits the project and controls a running session. Command-line tools
must be able to select that same session and use the same native operations,
admission checks and completion semantics. There is one lifecycle owner across
both clients. Disconnecting or terminating either client does not stop an
otherwise running RTC. Clients request a stop through an explicit lifecycle
operation.

Lifecycle, status, properties and parameter publication already have native
contracts. The existing `pipewireao-rtc-deploy` CLI exposes `sessions`,
`select-session` and `control`; see [deployment usage](JULIA_DEPLOYMENT_USAGE.md)
and [supervisor controls](NATIVE_SUPERVISOR_CONTROL.md). For example, the existing
installed CLI can list sessions and query one exact session, with
`RTC_SESSION_UUID` set to the selected session's UUID:

```sh
pipewireao-rtc-deploy sessions
pipewireao-rtc-deploy control --session "$RTC_SESSION_UUID" -- status
```

This records an existing interface, not a claim that every desired operator
workflow has been qualified. Future GUI and CLI actions should extend the same
public contracts. Saved project edits do not silently modify an active graph;
the runtime must admit and report the requested change. Live controls use native
PipeWire serialization even when a CLI renders its result as JSON.

### Running an RTC

1. Start or connect to the selected PipeWireAO core, using an explicit instance.
2. Start or load the selected graph owner with its existing graph configuration
   and calibration artifacts. Prepare buffers, algorithm workspaces and any JIT
   compilation before accepting acquisition.
3. Discover the exact declared sources, processing nodes and sinks. Validate
   their types, layouts, dimensions, units, rates and identities; create the
   declared links.
4. Confirm graph readiness and actual worker placement, then release the source.
   Observe lifecycle and command delivery through existing native interfaces.
5. On stop or reset, coordinate the source and processing owners so an unfinished
   frame cannot become a command from the next generation.

The headless RTC performs the live admission sequence. The Julia launcher prepares
the systemd-owned processes and configuration, verifies effective resources and
requests native admission; only the Lua session policy transitions to Ready.
The retired Julia supervisor and Rust session runner are historical implementations.

`After=` orders systemd service startup. It does not establish that a graph has
prepared its reconstructor, completed Julia warmup or negotiated its ports.
WirePlumber object activation likewise does not establish scientific readiness.
The headless RTC retains that domain-level admission responsibility.

Systemd can provide the process CPU envelope and scheduling/memory-lock limits.
Executor code retains per-thread placement and verifies its actual workers.
An affinity mask alone does not establish exclusive cores or immutable thread
placement. User services cannot grant privileges beyond the limits provisioned
for the user. The selected RTC layouts exclude CPU0/1.

### Activating AOS

A simulation session selects AOS as the instrument endpoint provider, with a
model configuration for Classic, Copper or another supported instrument. The
RTC graph remains an RTC graph. Its instrument binding and applicable calibration
artifacts must match the simulated sensor, mirror and coordinate conventions.

AOS HIL is a first-class session participant. It is optional when selecting the
instrument provider, but required for the admitted session once selected. One
AOS instance may publish multiple sources and sinks, such as several WFS and
science-camera outputs and several mirror or other controllable-optic inputs.
The session binds each declared endpoint to its exact owner instance and role;
discovery must not mix instances or interchangeable-looking endpoints by name.

The session declares which endpoints are required for its operating mode and
which are optional observation products. Each has its own shape, encoding,
coordinates, units and rate. Optional observers do not become required simulation
dependencies. The AOS owner retains model-time advancement, shared plant state
and synchronization between sensors and commands; source count does not imply
independent optical stepping or a mandatory one-source/one-sink pairing.

| Session concern | AOS HIL participation |
| --- | --- |
| Process and core | An independently supervised Julia owner joins the selected PipeWireAO core through the existing HIL adapter |
| Preparation | Prepare/warm the selected model, backend and transport while acquisition is held; verify all required endpoints and resource placement |
| Connections | Bind the declared sensor, command and observation paths through FGN/JFG and other session nodes using each endpoint's exact contract |
| Acquisition | Declare drivers, rates and command/exposure association for the selected model; release only after complete session admission |
| Control | GUI and CLI request coordinated start/pause/reset/stop through the headless runtime and existing native owner controls |
| Loss/restart | Simulator or required endpoint loss revokes admission; restart prepares a fresh instance and requires readmission |

The currently implemented complete-frame simulation has one WFS source and one
command sink. Its source is the lockstep graph driver. This is a supported
simulation run, not an architectural limit on the number of endpoints an AOS
instance can provide. A general multiple-endpoint adapter and its
timing/coherence contracts are not claimed implemented by this simulation.

For that simulation, command/frame feedback stays inside the simulator owner. The
external PipeWire plant exchange path remains acyclic: source → processor → sink.
A transport feedback link is not needed to advance the plant; declared scientific
feedback and observation paths retain their existing contracts. For this exchange,
frame `n` accepts its matching command, which AOS applies to frame `n + 1`. Coordinate
pause/reset at a completed exchange and preserve coordinated drain/reset behavior.
The pilot must verify that stale or duplicate commands, including commands from
before reset/restart, cannot be adopted into a new acquisition generation.

The simulation process prepares the model and adapter before releasing pixels.
The existing HIL adapter publishes WFS arrays, receives a matching DM command and
uses it to advance the next simulated frame. Model time and wall-clock pacing
are separate. Pausing, resetting and stopping require coordination at the
exchange boundary.

AOS may use CUDA or AMDGPU while the RTC uses CPU FGN or JFG. GPU simulation does
not require a GPU RTC executor. The current HIL exchange uses complete images
and one frame/command exchange in flight; it is not proof of progressive camera
readout or multiple frames in flight. Its GPU-to-host transport staging is also
not a wholly zero-copy GPU-to-CPU path.

Enabling the simulator should become a workstation action backed by lifecycle
controls and systemd services. It should not require a second RTC implementation,
a second session core or optics calculations inside WirePlumber. The GUI can
disconnect while the admitted RTC and simulation continue.

The one-shot launcher prepares the single-exchange owner on its selected remote
with native bootstrap and held acquisition (`src/deployment/session_launch.jl`
and `src/owners/aos_owner.jl`). WirePlumber/systemd integration preserves that behavior;
publishing endpoint nodes alone is not sufficient HIL admission. Calibration uses
the existing held-probe/exposure path and its selected session topology.

The pilot checks cross-instance pairing with duplicate endpoint names, zero
publication while held and actual source-driver selection. It also checks
pause/reset during a pending exchange, completion or bounded failure, delayed
commands across reset, independent endpoint loss and fresh held owner restart.
These are functional participation gates, not additional timing claims.

### Using AOC for calibration

AOC supplies numerical methods. The existing Julia calibration application
supplies the acquisition workflow:

1. Select a method and prepare its probes: zonal, Hadamard, modal or spatial
   sine/cosine, as supported by the current method configuration.
2. Apply each probe through the deployed command path. Collect the corresponding
   exposure and WFS response using command/exposure completion identities.
3. Estimate the interaction matrix and evaluate flux, clipping, uncertainty,
   repeatability and held-out prediction error.
4. Construct and validate a reconstructor in the controller's coordinates, then
   save the artifacts and load the prepared reconstructor through existing
   parameter controls.

The workflow uses completion events rather than arbitrary sleep intervals.
Using AOS changes the instrument endpoints, not the meaning of calibration.
Real and simulated instruments should use the same acquisition procedure where
their adapters support it. Spatial sine/cosine probes sample a chosen modal
basis; a partial basis does not automatically provide a complete zonal matrix.

AOC does not own process supervision, PipeWire linking or artifact activation.
Focal-plane sharpening primitives are available, but they do not by themselves
constitute a deployed closed-loop sharpening workflow. Saved configurations and
reports may use JSON; live controls retain native PipeWire serialization.

## What to reuse from WirePlumber

The cloned WirePlumber 0.5.18 source already contains:

- `WpObjectManager` for asynchronous object discovery and feature activation;
- PipeWire object proxies and native parameter enumeration;
- `WpSpaPod`, `WpProperties` and `WpSpaJson` wrappers;
- configurable components, profiles, Lua policy and events/hooks;
- link creation and activation infrastructure;
- `wireplumber.service` and `wireplumber@.service` user-unit templates.

The RTC application profile selects the library components needed for its
explicit declared connections. Any separate site/device policy uses stock
WirePlumber configuration. Desktop audio default-device selection and automatic
rerouting are not
appropriate substitutes for instrument identity, array shape and calibration
matching. Existing generic mechanisms should be used before adding extensions.

**Upstream WirePlumber is the runtime. Site/device policy is configured
separately, and application lifecycle policy belongs to the headless RTC.** The
ordinary Git fork is a contribution vehicle for upstream patches, not a runtime
dependency. Build and package integration is documented in the sibling
[PipeWireAO package guide](../../wireplumber/packaging/pipewireao/README.md).
Native changes should fix demonstrated upstream defects or extend existing
interfaces for a demonstrated integration gap. No AO-specific device policy is
currently defined or qualified.

The [reuse audit](reviews/20261021-wireplumber-reuse/REVIEW.md) distinguishes
upstream asynchronous hooks from the AO rules they execute. PipeWire already
links exact port IDs, and WirePlumber uses `si-node` for video as well as other
non-audio nodes. NDArray data alone does not require a different linking
framework. Our declared topology resolves symbolic node/port names to exact
IDs, rather than asking automatic audio-channel policy to choose connections.

The RTC now creates ordinary `WpLink` objects through the upstream Link factory.
The former `si-node` / `si-standard-link` extensions and custom Link Format API
are removed. Its existing native control module supplies a small Lua binding to
public C cancellation/disposal and negotiated Format observation. The RTC retains
endpoint identity, scientific admission, downstream ordering, deadlines and
Core-sync/correlated-absence proof. The remaining Lua/POD binding gaps are now supplied by RTC-local public C
helpers, and the clock uses upstream GLib directly. Genuine library bug fixes
remain separately tested. The generator now emits standard relaxed SPA-JSON
with bare feature names, so generated startup no longer requires the component
dependency-string correction.
See the [standard link design](HEADLESS_RTC_DESIGN.md#standard-link-apis--2026-10-21)
and [validation](validation/standard-links-20261021/README.md).

Model new functionality on existing implementations and extend their interfaces
where capabilities are missing. Loading the stock all-feature event source
would also subscribe to unrelated scientific properties; the current profile
uses the upstream dispatcher with selective ObjectManagers. The
[CPU-only integration evidence](validation/wireplumber-reuse-20261021/SESSION_ITEMS.md)
records real NDArray negotiation, delivery and withdrawal without a simulator.

### Historical integration pilots — 2026-10-06/07

The following paragraphs record the pre-transfer implementation. Their
observer-only and supervisor allocations are superseded by RTC-ARCH-025;
the linked evidence keeps its original revision and qualification scope.

The [initial compatibility fixture](validation/wireplumber-compatibility-20261006/README.md)
now passes with unmodified WirePlumber source built against AO through private
build dependency aliases. Generic discovery, NDArray format/metadata parsing and
explicit linking work for that complete-frame FITS/discard path. This requires
no native WirePlumber patch; a maintained build/release selection and additional
AO contracts still need qualification.

The [Copper HIL coexistence pilot](validation/wireplumber-hil-coexistence-20261006/README.md)
also passes with CUDA AOS and each CPU executor using existing artifacts. A
port/link-only WirePlumber profile observes the exact admitted cohort while the
runtime retains scientific admission and every link. Native stop/reset/resume,
exact retained baseline prefixes and continued operation after WirePlumber
SIGKILL pass. No native WirePlumber or scientific source changes were needed.
This is observation/coexistence evidence, not connection-policy or ownership
transfer qualification. Required-owner loss and replacement remain open here.

The broader compatibility questions retain these scopes:

1. WirePlumber currently requests `libpipewire-0.3` and `libspa-0.2` through
   pkg-config; PipeWireAO uses an AO library namespace. Determine whether stock
   WirePlumber can attach to the AO instance and which build selection changes,
   if any, are necessary.
2. Verify discovery, SPA parameter handling and explicit links for NDArray
   formats and metadata. Determine whether generic wrappers suffice and which
   standard audio-specific helpers should be excluded from the AO profile.

Its user-unit template currently binds to `pipewire.service`. An AO deployment
must bind to the intended AO core and select the correct remote, configuration
and module paths. It should not replace or disturb the desktop audio session.

RTC already provides a generated `pipewireao-rtc@.service`: systemd starts its
Julia supervisor, which prepares the private core and required scientific owners,
admits the session and retains their cleanup. There are no independent core,
AOS or JFG units in that package. Keep this service as the first integration
boundary and add WirePlumber as an optional instance-scoped service. The current
RTC `READY` notification follows source release, so `After=pipewireao-rtc@…`
can order post-admission observation but cannot establish observation during
held startup. Such an observer must not stop the RTC when it exits or authorize
source release when it restarts. Separate scientific-owner units retain the
failure-cohort gates in the architecture review.

The [optional Copper user-service increment](validation/wireplumber-user-service-20261007/README.md)
now implements that boundary. A copied companion runs upstream WirePlumber
directly under systemd; its Julia ExecStartPre adapter binds fresh configuration
to the active RTC MainPID, exact native incarnation and admitted topology.
`BindsTo`/`After`/`PartOf` propagate RTC lifecycle to the observer without reverse
control. Both CPU executors with CUDA AOS pass the scoped lifecycle, prefix and
cleanup gates. The runtime still supervises its scientific owners and owns all
links; separate owner units and connection policy transfer remain unimplemented.

The [declared-connection checks](validation/wireplumber-connection-policy-20261007/README.md)
now compare negotiated contracts with session declarations and watch exact
owner-client incarnations. Periodic RTC monitoring also detects required link
removal/failure and latches external endpoint removal. Both selected Copper
paths pass link/simulator loss, bounded cleanup and fresh admission with matching
baseline prefixes. This observer remains optional and has no repair or source
authority. Its current startup cannot replace initial RTC link realization;
the pre-admission realization/withdrawal interface is still missing. RTC-owned
links remain the working migration state until the transfer gates pass. This
startup arrangement is not an architectural reason to keep link realization in
the RTC permanently.

## Current ownership

| Work | Owner |
| --- | --- |
| Process startup, termination and reaping | systemd; one-shot Julia deployment tools verify exact incarnations |
| Optional site/device configuration, access and shared routing | Upstream WirePlumber using separately maintained stock configuration; no AO-specific policy is currently defined or qualified |
| RTC application links, scientific readiness and lifecycle coordination | Headless RTC application using libwireplumber hooks and public WpLink APIs |
| NDArray buffers, scheduling and internal graph execution | PipeWireAO, FGN and JFG |
| Instrument physics and calibration algorithms | AOS/adapter and AOC/Julia scientific owners |
| Operator interface | Optional GUI/CLI/Julia clients of the same native headless endpoint |

The RTC is the only application lifecycle and link owner. Required-owner loss
revokes admission; fresh incarnations remain held until readmission. No
WirePlumber daemon policy independently creates those links. Device-policy
requirements remain profile-specific. See the [implementation and acceptance
plan](HEADLESS_RTC_DESIGN.md); historical provider evidence below is not a
qualification claim for the new host.

## Historical migration sequence — 2026-10-07

This sequence records the work planned at the earlier link-transfer baseline.
The current owner allocation is above; follow the
[current roadmap](roadmap.md#current-work) for remaining work.

The isolated FITS/discard compatibility and Copper runtime-owned-link
coexistence steps pass within their recorded scopes. Explicit WirePlumber link
realization now passes native, deployed clean, same-process adapter retry,
all eight required-loss and fresh-admission checks for Copper CPU FGN/JFG
with CUDA AOS. See the [scoped acceptance](validation/wireplumber-realization-20261007/README.md).
Separate owner service supervision remains pending. The
[current roadmap](roadmap.md#current-work) owns delivery order:

1. Source fault disposal/report completion now passes the preserved Copper
   link/owner-loss cases for both CPU executors with CUDA AOS. Reuse
   [the scoped correction and evidence](validation/fault-teardown-20261007/README.md).
   Expected native/transport fault diagnostics remain; fault-time pause
   acknowledgements and source-revocation latency remain unqualified.
2. Qualify WirePlumber connection realization before RTC admission for one
   existing Copper session. Use existing WirePlumber/PipeWire facilities and
   native control contracts. Preserve exact owner identities, negotiation order,
   passive links and held-source admission. Check pending withdrawal, unload/retry,
   delayed callbacks, owner replacement and runtime/WirePlumber/core loss before
   transferring link lifetime. Define who owns each link during the transition.
   Use CUDA AOS with each CPU executor and existing artifacts; source-to-discard
   alone does not establish HIL participation or scientific equivalence.
3. After the selected link-transfer failure gates pass, migrate process
   supervision separately to systemd user services, including
   optional AOS activation on the same core. Preserve required-owner failure
   handling, held startup, fresh readmission and actual per-thread placement.
   Check start, stop, reset, owner failure and GUI/CLI absence before claiming
   deployment parity. Process restart alone never authorizes acquisition.
4. Remove redundant supervision and registry/link code after the respective
   parity gates. Keep scientific packages, graph configurations and native
   controls intact. Leave the desktop session and unchanged HEART untouched.

No new graph language, private command bus or frame scheduler is selected by
this responsibility split. General multiple-endpoint AOS and timing qualification
retain their separate gates.

Timing qualification remains a separate gate: define the offered camera/readout
pattern, age/loss/overload contract and resource budget, and measure concurrent
owner-reaching controls as well as independently paced ingress. Lockstep HIL
remains scientific/lifecycle evidence.

## Source pointers

The initial source inventory, preserved as historical provenance, inspected:
RTC `dae581a`, WirePlumber `bdc17eb`, PipeWireAO `29da2d6`, JFG `b609116`,
AOS `ed9a3f3`, HIL adapter `15fd37d` and AOC `f79104d`. AOS and
`calculon-algorithms` have pre-existing working-tree edits; their observed APIs
are not a claim that every edit has been committed or qualified.

- Current RTC boundaries: `native/main.c`, `native/scripts/ao/session.lua`, `src/configuration/session_configuration.jl`,
  `src/deployment/session_launch.jl`, `src/deployment/session_runtime.jl`, and
  `src/simulator_configuration/jobs.jl`.
- Scientific packages: JFG's root `README.md`; AOS's model cookbook;
  the HIL adapter's `README.md` and exchange implementation; AOC's `README.md`
  and public module documentation.
- WirePlumber: `lib/wp/object-manager.*`, `lib/wp/spa-pod.*`,
  `src/config/wireplumber.conf`, `src/scripts/linking/`, `src/systemd/user/`.
- Upstream documentation: [WirePlumber design](https://pipewire.pages.freedesktop.org/wireplumber/design/understanding_wireplumber.html),
  [components and profiles](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/components_and_profiles.html)
  and [multiple instances](https://pipewire.pages.freedesktop.org/wireplumber/daemon/multi_instance.html).
