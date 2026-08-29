# PipeWireAO RTC assessment and delivery roadmap

Status: proposed assessment, implementation roadmap, and evidence baseline

Review date: 2026-08-29

## Authority and scope

This document records the comparative evidence, current capability assessment,
missing work, implementation order, completion gates, open decisions, and
evidence baseline for the
[PipeWireAO RTC system architecture](architecture.md). It does not
replace the normative FGN, acquisition, row-block, time, scientific-data, or
command and audit contracts and does not promote an implementation claim.

## Comparative review of the local RTCs

### Execution and control architecture

| System | Scientific execution and transport | Lifecycle and process ownership | Main strength | Main cost or lesson |
| --- | --- | --- | --- | --- |
| pyRTC | Python components exchange arrays through shared memory. A soft RTC can assemble components in one process; a hard RTC launches hardware components as subprocesses and uses lightweight command sockets. | Components primarily expose `alive` and `running`; scripts and launchers coordinate the system. | Very low barrier for a scientist to assemble, modify, and inspect a loop. | The ease comes from weak system-wide contracts: no authoritative instrument state machine, correction authority, atomic deployment, or hard real-time admission boundary. |
| HEART | C blocks are grouped into pipes, commonly in one server process. Blocks have command and worker threads and exchange data through circular buffers. | Blocks follow explicit states from construction and readiness through running and correcting. Pipes coordinate block state and correction permission; systemd and scripts manage services. | Clear AO-specific lifecycle vocabulary and mature high-rate execution. | Scientists inherit block, circular-buffer, command, and configuration machinery. Same-process grouping and shared infrastructure increase coupling. |
| CACAO | C processes and `milk` commands communicate through ImageStreamIO shared-memory images and semaphores. | Shell tools, process-control interfaces, status files, locks, process lists, and terminal sessions form much of the operational control plane. | Proven AO stream workflows, calibration staging, and inspectable shared data. | Operational meaning is distributed across shell conventions, files, streams, and process state. Reconstructing exact intent and failure atomicity is difficult. |
| MagAO-X | Individual `MagAOXApp` processes use INDI for control/status and ImageStreamIO for image data; CACAO supplies the main AO loop. | Each application has a substantial device lifecycle. Python and shell tooling launch process lists, commonly in terminal sessions, while operators supervise recovery. | Broad instrument operations: device control, telemetry, recording, metadata, and observatory integration. | Multiple control and data systems plus per-application boilerplate make the complete system powerful but operationally complex. |
| TAO-RT | C servers expose typed shared objects and arrays using System V shared memory, mutexes, and condition variables. Camera servers separate command/server ownership from worker execution. | Device run levels, command serials, and request/acknowledgement/completion counters provide disciplined single-writer device control. | Strong device ownership and command-completion semantics. | It is a low-level library and server framework, not a complete graph, application lifecycle, operator, or archive system. |
| Raven | A GStreamer pipeline composes camera and AO plugins. Standard element states and bus events expose generic lifecycle; a controller can inspect elements and properties. | A pipeline controller changes element state and properties; graph composition is naturally visible. | The closest historical precedent for an inspectable media-style AO graph. | The inspected implementation is an old prototype with a forked media stack and limited instrument-safety and artifact-provenance semantics. |
| SPIDERS and RtcFramework.jl | Julia services communicate through Aeron. `RtcFramework.jl` supplies hierarchical state machines, agents, properties, timers, and counters. | Services have explicit waiting, ready, processing, playing, paused, stopped, error, and exit behavior. | Typed Julia services and explicit state-machine patterns; archiving and replay are first-class services. | A second message runtime, distributed service configuration, and per-service framework concepts impose more software-engineering work than the desired scientist surface. |
| Calculon and PipeWireAO today | Typed scientific plans are generated into an ndarray filter graph. PipeWireAO supplies negotiated ports, bounded buffers, scheduling, row blocks, parameter publication, and device adapters. | PipeWire node state and module lifetime exist, but there is no AO-level owner of the instrument lifecycle or correction permission. | A small transport-neutral algorithm surface over a capable, introspectable, low-latency graph. | The data plane is ahead of the control plane. It can run a graph, but it cannot yet prove which complete instrument deployment is active or safely operate it. |

### Configuration, artifacts, telemetry, and recording

| System | Configuration and artifacts | Telemetry and recording | Reusable lesson |
| --- | --- | --- | --- |
| pyRTC | YAML component configuration and Python construction scripts; matrices and calibration values are loaded by components. | A lightweight telemetry helper captures finite raw samples, and Python tools display data. | Preserve the immediacy of script assembly and quick inspection. Add a resolved manifest and explicit activation semantics. |
| HEART | YAML configures blocks, circular buffers, and telemetry streams. Runtime configuration and status are visible through shared management structures. | Dedicated telemetry threads decimate and write circular-buffer streams to files or sockets, with loss and corruption reporting. | Lifecycle, stream identity, and loss accounting should be standard, not application-specific. |
| CACAO | Instrument trees contain many text files, stream links, FITS matrices, staged calibration directories, and explicit adoption steps. | ImageStreamIO makes internal arrays visible; downstream processes record or inspect selected streams. | Keep staging and adoption of calibration artifacts, but replace implicit directory conventions with typed manifests and transactions. |
| MagAO-X | Per-application configuration files and role-specific process lists are combined with CACAO loop configuration and calibration artifacts. | Binary telemetry, log managers, database ingestion, dashboards, XRIF stream recording, and FITS export cover operations well. | Separate low-rate telemetry, image recording, event logs, and export. Preserve acquisition identity across all of them. |
| TAO-RT | Typed device configuration is reflected through shared remote objects and command serials. | Shared arrays expose current data; a complete run archive is outside the core framework. | Requested, accepted, and active configuration must be distinguishable. |
| Raven | Pipeline definitions configure the graph; element properties configure nodes. | AMQP branches and data-management services record HDF5 or images. | Observation should be a branch from the graph, not work performed by the critical path. |
| SPIDERS and RtcFramework.jl | TOML/environment configuration identifies distributed services and streams. | The archive service dynamically subscribes to Aeron streams and writes each complete encoded message verbatim into rolling raw log files. A nightly SQLite database indexes message headers, source stream, log filename, and byte range; replay and FITS export query the index and memory-map the logs. | Keep payload logs separate from their searchable catalog. Recording needs a subscription model, recoverable byte index, replay contract, and explicit durability and loss semantics—not a database full of tensor payloads. |
| Calculon and PipeWireAO today | Graph configuration, typed properties, construction configuration, and ndarray parameter ports exist. Instrument profiles and generated graph examples exist, but no service resolves all inputs into one admitted deployment. | PipeWire metadata and streams make live observation possible; the GUI can inspect many of them. A general RTC event log, metrics contract, recorder, run catalog, and replay workflow are absent. | Retain the current configuration categories, then bind them with a deployment manifest and non-gating observation services. |

### Supporting projects in `RTC_planning`

Some directories are supporting layers rather than independent RTCs:

- ImageStreamIO is an important shared-image and notification substrate. It
  does not by itself define graph topology, correction authority, lifecycle,
  or deployment provenance.
- `ao3k_loop_confs` is evidence of the amount of instrument-specific geometry,
  calibration, tuning, and startup configuration a production RTC must bind.
- the MagAO-X handbook and setup repositories encode operational knowledge,
  host setup, process roles, and recovery procedures that are not visible in
  the algorithm graph;
- Lookyloo demonstrates that visualization, metadata association, and data
  export are user-facing systems in their own right; and
- the SPIDERS archive and performance services show why recording and timing
  should be designed as graph consumers with explicit identities and loss
  semantics. In particular, the archive's separation of verbatim rolling log
  files from a SQLite byte-range index enabled efficient selection,
  memory-mapped decoding, replay, and later FITS generation without putting tensor
  bodies in the database.

The important conclusion is not that one existing RTC should be copied. Each
one has solved a different part of the problem. PipeWireAO should retain
pyRTC's authoring ease, HEART's lifecycle clarity, CACAO's calibration
adoption discipline, MagAO-X's operational telemetry, TAO-RT's single-writer
device semantics, Raven's inspectable graph, and SPIDERS' typed services and
replay—without importing their transports or process conventions.

## Legacy Calculon decision disposition

The former Calculon architecture is evidence and design input, not another
active RTC architecture. Its decisions have these dispositions:

| Legacy decision family | Disposition in PipeWireAO | Owning document |
| --- | --- | --- |
| Explicit time domains, identity-based causation, completed-frame boundaries, deadline classes, and replay semantic time | Adapted. Use SPA acquisition metadata, FGN generations, and RTC events rather than the former message headers and agent clocks. | [Time, causality, and performance](time-and-performance.md) |
| Fixed-range local latency histograms, off-path interval extraction, missing-interval visibility, open-loop load, and coordinated-omission protection | Adapted as implementation-neutral evidence requirements. HdrHistogram is suitable, but HdrHistogram.jl and Agrona are not system dependencies. | [Time, causality, and performance](time-and-performance.md) |
| Quantity, encoded unit, coordinate frame, basis, sign, normalization, and matrix input/output meaning | Adopted as schema and artifact compatibility. Dynamic unit systems remain outside the strict path. | [Scientific data and command contracts](scientific-data-and-command-contracts.md) |
| Direct correction plus requested, demanded, submitted, accepted, applied, and measured DM state | Adapted and strengthened so API acceptance cannot masquerade as physical application or measurement. | [Scientific data and command contracts](scientific-data-and-command-contracts.md) |
| Acceptance-versus-application, causal event progression, external recorder, reconstruction, and safe replay | Adapted to RTC events and portable logical SPA-buffer records. The SBE envelope and Snowflake identity format are not retained. | [Audit and reconstruction](audit-and-reconstruction.md) and [operational architecture](operations.md) |
| Raw-first archive with derived FITS and explicit temporal metadata joins | Adopted. FITS is an exporter or qualified backend, not the correction-path record format. | [Operational architecture](operations.md) |
| Deterministic operator reducer, immutable snapshots, logical view bindings, and no GUI-held data-plane leases | Adapted for the shared PipeWireAO client core. | [Operational architecture](operations.md) |
| Hierarchical program-by-difference, desired-versus-observed state, typed completions, quiescing, and cold recovery | Adapted at the instrument, device, and service authority levels. Pure Calculon algorithms do not acquire per-algorithm lifecycle machines. | [Operational architecture](operations.md) |
| Iceoryx2 as the machine-local data plane, SBE as the universal wire format, Agrona counters as the common observation plane, and custom service discovery | Rejected. PipeWire, SPA, FGN, metadata, properties, ports, and ordinary clients already own these roles. | [System architecture](architecture.md) |
| One process, execution agent, duty cycle, and lifecycle HSM per scientific block | Rejected. FGN composes ordinary scientific algorithms inside a bounded graph, while meaningful device and service authorities retain lifecycle. | [System architecture](architecture.md) and [operational architecture](operations.md) |
| Julia-first deployment, library-specific clock and counter mappings, QP/C selection, and mandatory PTP | Rejected as generic architecture. Language runtimes, HSM libraries, and synchronized-time services are qualified implementation or deployment profiles. | [System architecture](architecture.md) and [time contract](time-and-performance.md) |
| Fixed SCAO-240x277 topology and universal per-agent property-transaction protocol | Retained only as historical fixture evidence. Instrument dimensions are profile data; FGN publication and RTC deployment transactions own current activation. | [Operational architecture](operations.md) |
| WebAssembly gateway, multi-host orchestration, and detailed accelerator profiles | Deferred until a concrete deployment need exists. They do not shape the first single-host RTC contract. | This roadmap |

## Current Calculon and PipeWireAO assets

### Scientific authoring

Calculon already makes the correct separation between scientific code and
transport. A scientist can implement an ordinary typed algorithm or plan and
add a local declaration that describes its ports, exact shapes and schemas,
properties, construction values, and large ndarray parameters. Generated
filter-graph ndarray (FGN) descriptors make declared algorithms available to
the ndarray graph without a handwritten SPA plugin or central per-algorithm
wrapper registry.

The current Rust path is substantially ahead of the system integration. Julia
has the portable property and declaration concepts and an emerging
PipeWireAO-client path, but strict admission of arbitrary Julia algorithms to
the real-time FGN path still requires an ahead-of-time (AOT) compilation and
runtime policy, allocation and tail-latency evidence, callback-thread
preparation, and bounded teardown.
Those are language-runtime qualification tasks, not reasons to change the
scientific interface.

### Deterministic graph

The ndarray filter graph provides:

- exact typed and shaped ports with scientific schemas;
- synchronous graph validation and execution;
- bounded two-slot publication for scalar property and large parameter plans;
- frame-boundary adoption and requested-versus-active revisions;
- chunk and row-block handling;
- an implemented, FGN-owned fixed-worker group used by dense reconstruction and
  by the SHWFS and PWFS progressive row-block adapters;
- C and Rust plugin boundaries with a versioned C ABI; and
- projection as an ordinary PipeWire node with discoverable ports and
  parameters.

It deliberately does not define instrument lifecycle, artifact qualification,
operator authorization, process supervision, or a recording catalog. It also
does not make every stateful feedback operation decomposable: operations that
require atomic rollback or unit-delay feedback may remain fused until the
graph has an explicit state/delay contract.

### Device boundaries

The plugin workspaces contain camera, descrambler, calibration, queue, and
ALPAO boundaries. These are the appropriate owners of SDK calls, hardware
formats, DMA or vendor buffers, and physical reset behavior. Hardware
qualification, canonical device identity, safe-state verification, and
failure-atomic layout changes still require instrument-specific closure.

### GUI

The GUI already has the beginnings of the right engineering client:

- a dedicated PipeWire thread and reconnect generations;
- registry snapshots for nodes, ports, and links;
- generated property editors from `PropInfo` and `Props`;
- bounded, generation-checked property requests;
- video and generic rank-two ndarray viewing with capacity-one handoff; and
- strict operator-view configuration with logical bindings.

Specialized Shack–Hartmann wavefront-sensor (SHWFS), pyramid wavefront-sensor
(PWFS), self-coherent camera (SCC), and DM views, graph editing, run catalog
browsing, artifact selection, and RTC lifecycle control are still future
capabilities. The GUI must remain restartable without changing loop state.

There are also two graph levels. The PipeWire registry exposes the camera,
composite filter-chain, DM, recorders, and viewer clients as PipeWire objects.
The Calculon operations inside one FGN composite are not each separate
PipeWire globals. Today their definition is available from configuration and
their properties can be projected by the composite, but uniform runtime
introspection of their internal ports, links, health, and monitor taps is not a
complete GUI contract.

### Capability position

This matrix makes the intended “middle space” explicit. “Current” describes
the inspected Calculon/PipeWireAO work, not the target in the
[system architecture](architecture.md).

| Capability | Useful precedent | Calculon/PipeWireAO current | Intended target |
| --- | --- | --- | --- |
| Scientist writes an algorithm without transport code | pyRTC and ordinary Julia/Python functions | Strong in Rust declarations; Julia declaration/runtime path is partial | Strong and equivalent in Rust and Julia, with no central adapter edit |
| Scientist composes a visible graph | pyRTC scripts and Raven pipelines | Standard config and generated examples exist; no shared script/GUI editor model | Typed script builder and GUI over one standard SPA-JSON graph model |
| Bounded typed real-time data plane | HEART and specialized C loops | Strong proof-of-concept contracts and tests; target hardware qualification remains | Explicit deployment-specific latency and overload admission |
| Progressive row-block processing | HEART camera/pixel pipeline | Contract and fixed-worker SHWFS/PWFS paths exist; instrument sources, scheduling, and asynchronous multi-batch operation are not yet qualified | Per-camera declared readout model and measured camera-to-DM benefit |
| Instrument lifecycle | HEART blocks and MagAO-X applications | Missing above individual PipeWire node/module state | One AO-level state machine with guarded requested and observed transitions |
| Correction authority and safe DM | HEART correction state and device applications | Device reset behavior exists in parts; system authority is missing | Single RTC application grant plus independent bounded device-side revocation |
| Device command completion | TAO-RT serial and completion counters | PipeWire control and property acknowledgements are component-specific | Uniform request, acceptance, active generation, timeout, and failure evidence |
| Calibration staging and adoption | CACAO calibration workflows | Parameter preparation/adoption exists inside the graph | Typed artifact resolver, qualification, digest, atomic activation, and rollback |
| Exact deployment provenance | Partial conventions across mature systems | Missing system-level resolved manifest | Immutable admitted manifest plus append-only changes and final run record |
| Live graph inspection | Raven, ImageStreamIO tools, and INDI clients | Strong registry/property basis; generic ndarray viewing exists | Complete engineering view plus AO-specialized visualizations |
| Operational GUI control | MagAO-X/INDI operator tools | Direct node/property controls only | RTC application lifecycle, artifact, graph-generation, and fault workflows |
| Telemetry and metrics | HEART telemetry and MagAO-X binary telemetry | Per-node data and metadata exist without a common RTC contract | Standard counters, acquisition identity, event log, and timing summaries |
| Continuous recording and run catalog | MagAO-X XRIF/Lookyloo and SPIDERS archive | No general recorder/catalog | Bounded non-gating recorders, loss accounting, catalog, and format adapters |
| Replay and regression | SPIDERS archive/replay and offline pyRTC workflows | Component and numerical tests, but no run-level replay | Reconstruct a deployment from a run and compare every selected boundary |
| Process supervision | HEART systemd and mature operational scripts | Daemon/modules can be launched, but no generated RTC service deployment | systemd owns processes; the RTC application owns logical readiness and correction |
| Simulation portability | pyRTC and Calculon's transport neutrality | Calculon algorithms remain independently testable | Same scientific graph model can be executed by PipeWireAO or AdaptiveOpticsSim |

## What is missing

### Blocking a safely controllable instrument

1. **One lifecycle owner.** Nothing currently turns node discovery and
   low-level node states into an authoritative instrument state with guarded,
   idempotent transitions.
2. **Correction authority.** There is no single gate that distinguishes
   “frames are flowing” from “commands may reach the physical DM,” revokes
   that permission on every relevant failure, and records why it changed.
3. **Resolved deployment admission.** There is no transaction that verifies
   device identity, dimensions, schemas, graph topology, plugin ABI, buffer
   budgets, artifacts, properties, and scheduling policy before declaring the
   RTC ready.
4. **Safe failure ownership.** The behavior for daemon loss, RTC application
   loss, camera staleness, malformed frames, DM disconnect, node error,
   parameter activation timeout, and deadline overload is not unified.
5. **Hardware-independent lifecycle tests.** A simulated camera and DM need to
   prove startup, open-loop operation, correction enable, fault revocation,
   reset, and shutdown before physical hardware is admitted.

### Blocking reproducible operation

1. **Artifact resolver and manifest.** A matrix pathname is not an activated
   calibration. The system needs typed roles, checksums, dimensions, units,
   coordinate frames, qualification state, requested and active generations,
   and an immutable record of what ran.
2. **Configuration layering.** Existing profile, graph, node, property, and
   deployment settings need one precedence and validation model without
   collapsing their distinct lifecycles.
3. **Event and audit log.** Lifecycle requests, accepted transitions, graph
   changes, artifact changes, protected property changes, faults, recoveries,
   and operator identity need one ordered record.
4. **Metrics contract.** Node health, sequence gaps, invalid data, deadline
   misses, drops, queue pressure, and active configuration revisions are not
   yet uniformly discoverable.
5. **Internal graph introspection.** The GUI needs a reconciled view of the FGN
   node IDs, labels, typed ports, links, properties, active revisions, health,
   and declared monitor boundaries without promoting every operation into a
   separately scheduled PipeWire node.
6. **Run catalog and recorder.** There is no standard non-gating service that
   binds recorded streams to the manifest and event log and states exactly
   what was lost.
7. **Replay qualification.** Complete recorded inputs cannot yet be replayed
   through a resolved graph as a routine numerical and timing regression.

### Important operational capabilities that can follow

- role-based control and PipeWire permission policy;
- remote artifact upload and repository/catalog integration;
- observatory command and status adapters;
- multi-host clock, deployment, and failure semantics;
- automated CPU placement and NUMA-aware buffer allocation;
- rolling update and warm-spare policy;
- searchable telemetry databases and dashboards; and
- optional hosting of the headless RTC application as WirePlumber components.

These should be anticipated by stable identities and manifests, but they do
not belong in the first vertical slice.

## Dependency-ordered implementation roadmap

### Phase 0 — Freeze the system vocabulary and minimum contracts

- adopt the definitions of RTC definition, deployment, headless RTC
  application, WirePlumber session policy, run, and correction authority;
- define stable identities for nodes, ports, devices, artifacts, deployments,
  acquisitions, and runs;
- freeze the source, progress-publication, arrival, monotonic measurement,
  synchronized epoch, semantic event, device, and physical-effect time
  vocabulary plus the fully completed frame boundary;
- freeze correction quantity, unit, frame, basis, sign, normalization, direct
  correction, requested physical command, demanded physical command,
  device-accepted, applied, and measured-state meanings;
- specify the lifecycle states, transition guards, fault taxonomy, and
  requested-versus-observed semantics;
- define the versioned public RTC state, event, rejection-reason, operation-ID,
  and correlation-ID schemas and the private Statig superstate map;
- define the configuration-layer precedence and canonical resolved manifest;
- define named placement variants, process membership, FGN worker policy, and
  the evidence required to admit a vendor SDK into the strict island;
- specify the portable SPA-buffer archive profile, admitted metadata codecs,
  stream-segment identity, and durability watermark semantics; and
- select the minimum node metrics and event record.

**Exit evidence:** reviewed schemas and lifecycle tests with no implementation
claims.

### Phase 1 — DAW-style headless RTC application vertical slice

- create the Rust `pipewireao-rtc` headless application and command-line client,
  using `libwireplumber` where it avoids raw asynchronous PipeWire plumbing;
- define a minimal maintained WirePlumber profile for device discovery and
  access policy, with generic fallback and movement disabled for AO objects;
- load the existing REVOLT Classic instrument profile and generated FGN graph;
- resolve and hash the subaperture origins, reference data, reconstructor, and
  controller parameters;
- create the graph, negotiate formats, publish large parameters, and wait for
  active generations;
- exercise the existing serial and fixed-worker FGN modes with complete-frame
  and row-block input while keeping worker policy in the deployment rather than
  the scientific declaration;
- expose the RTC control object and requested/observed lifecycle state;
- implement the private Statig HSM, serialized bounded event owner, reserved
  safety-event capacity, and asynchronous typed-effect runner;
- implement `OFFLINE`, `STARTING`, `CONFIGURING`, `READY`, `RUNNING`,
  `STOPPING`, and `FAULT` with a FITS or simulated camera and simulated DM; and
- persist a resolved manifest and ordered lifecycle event log.

**Exit evidence:** exhaustive state/event table tests, superstate fallback and
entry/exit ordering tests, stale-completion tests, shutdown and fault injection
from every implemented leaf, repeated start, stop, failed admission, PipeWireAO
and WirePlumber disconnect/restart tests, and proof that no missing AO target is
replaced or reconnected through generic fallback; no physical correction.

### Phase 2 — Correction authority and safety qualification

- add `CORRECTING` and explicit open-loop transition;
- implement a simulated DM authority lease, watchdog expiry, rejected-command
  fault, and safe-state read-back;
- implement requested and demanded physical command publication, terminal
  `Accepted`, `Limited`, `Rejected`, `Held`, and `Failed` command results, and
  truthful simulated acceptance, application, and measured-state observations;
- select and test when controller history commits relative to the matching
  terminal command result;
- define stale-frame, incomplete-row-block, sequence-gap, and deadline-miss
  policies;
- make topology and protected parameter changes revoke correction and apply
  transactionally;
- qualify one physical camera and DM boundary with failure injection; and
- compare the isolation-first and row-block-latency placements on the same
  graph, including process-crossing cost, worker scheduling, tail latency,
  overload, and crash containment.

**Exit evidence:** hardware-in-the-loop tests demonstrate that every single
process loss and declared data fault reaches the required safe state within a
measured bound.

### Phase 3 — Telemetry and reproducible recording

- implement the common health and performance counters;
- implement bounded single-writer latency recording, sequenced interval
  extraction, missing-interval reporting, and a schedule-preserving open-loop
  workload mode;
- create non-gating latest-value and recorder branches;
- implement a Rust observation command-line client for discovery, live status,
  snapshots, finite capture, and bounded file or TCP export;
- implement one Rust continuous recorder using the portable SPA-buffer profile,
  self-framing append-only log segments, and a SQLite byte-range index;
- define segment sealing, checksums, durability watermarks, crash-tail recovery,
  and explicit queue, stream, and storage-loss accounting;
- mediate dynamic observer subscriptions through the RTC application and prove
  that attaching and detaching at prepared queue outputs does not change the
  admitted scientific graph;
- implement one snapshot path and an offline FITS exporter over the same index;
- bind stream logs, exact command and lifecycle events, metrics, manifest, and
  loss summary into the run catalog; and
- add deterministic replay with numerical comparison to the direct Calculon
  reference.

**Exit evidence:** a recorded simulated run can be replayed from its catalog
without undocumented inputs; injected process and power-loss boundaries leave
no durable index row pointing to an incomplete record and recover every valid
log tail; FITS products are regenerated from the indexed logs; and recorder
overload does not perturb the strict-path latency distribution beyond its
admitted budget.

### Phase 4 — GUI operations

- discover and render the RTC control object;
- show lifecycle transition progress, faults, active generations, and
  correction authority;
- add specialized WFS, coefficient, command, and DM views;
- edit and validate the shared typed graph model;
- select qualified artifact sets and apply a new deployment generation; and
- browse runs and replay streams.

**Exit evidence:** closing, restarting, or slowing the GUI cannot change or
stall the loop; the script and GUI produce identical canonical deployments.

### Phase 5 — Scientist authoring and Julia qualification

- remove any remaining central-registry edit from new Calculon algorithm
  publication;
- provide typed graph builders for the primary scientist language and a Rust
  reference implementation;
- make declaration metadata drive GUI node palettes, property editors, artifact
  selectors, and validation;
- qualify the chosen Julia path: JIT client for development and non-real-time
  services, and JuliaC/AOT only for strict nodes that pass the real-time gate;
  and
- publish small SHWFS, PWFS, SCC, controller, and calibration examples.

**Exit evidence:** a scientist unfamiliar with PipeWire can implement, unit
test, graph, simulate, and inspect a new algorithm using only documented
scientific concepts.

### Phase 6 — Deployment and instrument qualification

- generate systemd units and host scheduling policy from the resolved
  deployment rather than hand-maintained launch scripts;
- add role-based permissions and observatory adapters;
- qualify target-host latency, bursts, overload, restart, and long-duration
  operation;
- retain raw latency distributions, offered and terminal outcome counts,
  environment and placement records, independent repetitions, and the
  correctness oracle required by the performance contract;
- reserve and verify the strict-island CPU budget, including the data-loop
  coordinator and every enabled FGN helper, without oversubscribing cores;
- establish artifact promotion and release procedures; and
- document operator recovery and maintenance workflows.

**Exit evidence:** an instrument release has a versioned bundle, target-host
benchmark record, hardware safety record, run-replay evidence, and operator
procedure.

### Phase 7 — Reassess application hosting and multi-host needs

After the headless application API is stable, compare its deployed complexity
with hosting the same AO application logic as upstream-compatible WirePlumber
components. Adopt that packaging only if it materially simplifies a fixed
appliance without obscuring the DAW-like domain boundary or putting blocking
work on the policy loop. Do not move the strict data path or device safety into
WirePlumber.

## Immediate recommended slice

The next concrete deliverable should be deliberately narrow:

1. One REVOLT Classic bundle using the existing 277-actuator graph and
   explicit subaperture origins.
2. A simulated or FITS source that can operate in complete-frame and row-block
   modes.
3. A simulated DM sink with authority lease, safe state, requested and demanded
   physical vectors, distinct acceptance, application, and measurement
   observations, terminal command results, counters, and injected failures.
4. A headless RTC application that reaches `READY`, runs open-loop, enters and
   exits simulated `CORRECTING`, and writes a manifest plus events.
5. The GUI displaying the RTC state, graph, one WFS stream, one coefficient
   stream, one command stream, and active artifact generations.
6. A Rust recorder producing indexed portable SPA-buffer logs, a replayable
   run, an offline FITS product, and explicit loss accounting.
7. An isolation-first versus qualified camera-co-located benchmark using the
   same graph, row-block sizes, fixed FGN worker counts, schedule-preserving
   camera arrivals, exact acquisition-to-command boundaries, raw latency
   distributions, terminal outcome counts, environment record, and
   numerical-equivalence checks.

This slice exercises every ownership boundary without waiting for a general
artifact server, telemetry database, remote API, or custom WirePlumber
components. It also
turns the existing processing benchmark into a system benchmark: camera
availability to DM command, with and without row-block overlap, while the GUI
and recorder are independently loaded.

## Completion gates

Calculon/PipeWireAO should not be called a complete RTC platform until:

- scientists can add and compose algorithms without PipeWire-specific source
  changes or central adapter edits;
- a complete deployment is validated and identified before `READY`;
- every correction-relevant port and artifact has an exact quantity, unit,
  coordinate frame or layout, basis, sign, normalization, and schema contract,
  and equal-shaped incompatible values are rejected before operation;
- correction authority is explicit, single-owner, bounded, and independently
  fail-safe at the actuator;
- requested and demanded physical commands, device-native submission, device
  acceptance, qualified applied state, and measurement are not conflated; every
  admitted correction proposal has one reconstructable terminal result and the
  controller-history policy is verified;
- every protected property and artifact update has requested and active
  identity and appears in the run record;
- frame-scoped updates either wait for a fully completed frame boundary or
  invalidate the partial frame without mixed-generation output or state
  advance;
- graph, device, data-validity, deadline, daemon, WirePlumber, RTC application,
  GUI, and recorder failures have tested outcomes;
- every public lifecycle request has an explicit accepted, rejected, or stale
  result; shared HSM events behave identically from every descendant; and
  restart, stale completion, or queue overload can never restore correction
  authority;
- observation and recording cannot introduce unbounded work or backpressure
  into the correction path;
- a run is reproducible from its manifest and recorded inputs, including
  multi-block data, chunk offsets, admitted metadata, format generations, and
  visible sequence gaps;
- every timestamp and derived cross-clock latency has a declared measurement
  point, time domain, mapping generation, and uncertainty where applicable;
  causal order comes from identities and predecessor references rather than
  recorder arrival order;
- target hardware meets an explicit end-to-end latency and overload contract;
- target-rate latency uses schedule-preserving offered load, accounts for every
  arrival and terminal outcome, retains raw supported-percentile distributions
  and environment records, and demonstrates bounded post-overload recovery;
- FGN serial and fixed-worker execution produce equivalent accepted outputs,
  and every admitted worker count, row-block size, CPU set, scheduling class,
  and placement variant has target-host tail-latency and failure evidence; and
- the GUI and script interface manipulate the same typed definition and show
  observed—not merely requested—state.

The current implementation is a strong foundation for this work, but it is
not yet at these gates. The missing work is mostly system ownership and
operational closure, not another scientific graph abstraction.

## Risks and open decisions

| Question | Recommended default | Decision trigger |
| --- | --- | --- |
| Which clocks are required? | A named local monotonic clock for deadlines and source-domain acquisition metadata everywhere; require PTP-qualified TAI only for a deployment that needs cross-host comparison or synchronized effects. | Instrument trigger topology, recorder query requirements, multi-host joins, and maximum admitted mapping uncertainty. |
| When does controller history commit? | Declare it per controller and command path; never imply applied-state feedback without a bounded matching result. Keep a stateful controller fused with command-result handling until an explicit FGN delay or feedback contract is qualified. | Control-law oracle, allowable pipeline depth, device-result latency, rollback semantics, and missing-result safety policy. |
| How should remote management work? | Local bundle selection plus PipeWire control object first. | Add a management transport when remote upload or transactional editing has a concrete deployment requirement. |
| What does WirePlumber own? | Device discovery, access, and explicitly assigned generic policy; never the RTC definition, instrument lifecycle, or AO fallback target. | Change only through a new ownership decision and conflict tests. |
| Should the RTC application be hosted inside WirePlumber? | No by default; keep the DAW-style headless process. | Revisit for a fixed appliance after the application API and blocking-work boundaries are proven. |
| Which scripting language defines graphs? | One versioned model serialized as standard SPA-JSON; Julia first for scientists, Rust as reference, Python as an optional operations client. | User studies and package maturity. |
| Can Julia execute strict nodes? | Only declared AOT nodes that pass admission; JIT Julia remains excellent for development, simulation, artifact generation, and non-real-time graph clients. | Allocation, callback-thread, GC, tail-latency, and teardown evidence. |
| Where should the camera and DM SDKs run? | Separate processes by default. Permit camera co-location first when repeated row-block crossings consume the deadline; keep the DM isolated unless a measured once-per-frame crossing also matters. | Blocking and allocation audit, crash recovery, safe-state evidence, and end-to-end latency distributions for both placements. |
| How should row-block worker threading be exposed? | Use the existing FGN host-owned fixed worker group. Scientists declare scientific ports and operations; deployments choose workers, row-block size, CPU set, scheduling, and idle policy. | Add a different executor only when measured synchronous fork/join or platform constraints require it; asynchronous multi-batch is a separately admitted capability. |
| Should Statig handlers perform asynchronous lifecycle I/O? | No. Use synchronous serialized HSM dispatch to emit typed effects, execute those effects asynchronously, and return correlated result events. | Revisit only for an operation proven bounded, cancellation-safe, and unable to delay shutdown or safety events; the public lifecycle contract remains unchanged. |
| Must recording be lossless? | No universal rule; declare it per stream and deployment. | Science and qualification requirements for a particular run. |
| Should graph changes occur while correcting? | Read-only clients may attach to pre-admitted observer-side queue outputs. Critical-side links, internal FGN exports, formats, algorithms, camera links, and DM links require revocation, transaction, and re-admission. | Broaden only with measured link/pool transition evidence or a proven dual-graph or atomic-swap design. |
| Which continuous stream encoding should follow the initial indexed log? | Preserve the self-framing exact-record contract first; treat XRIF, HDF5, Zarr, compression, and network replication as pluggable qualified backends or exporters. | A concrete science, bandwidth, portability, or retention requirement with recovery and latency evidence. |
| How is correction authority enforced? | Bounded lease or equivalent device-local watchdog plus RTC application state. | ALPAO and other hardware capabilities and measured safe-state bounds. |

## Evidence baseline

This review used these source snapshots and their adjacent documentation and
tests:

| Workspace | Revision or status |
| --- | --- |
| `RTC_planning/pyRTC` | `1c0a55e81433` |
| `RTC_planning/heart` | `4831cce49bd5` |
| `RTC_planning/cacao` | `ecfb694cb319` |
| `RTC_planning/MagAOX` | `66a6087f7c4d` |
| `RTC_planning/tao-rt` | `4c376e745cf1` |
| `RTC_planning/RtcFramework.jl` | `09a5e4ac0dda` |
| `RTC_planning/ImageStreamIO` | `47c1b261a57a` |
| `RTC_planning/ao3k_loop_confs` | `478a13dd2bf3` |
| `RTC_planning/magao-x-setup` | `119adb864b8f` |
| `RTC_planning/lookyloo` | `8d8bbcdce185` |
| `RTC_planning/raven` | inspected workspace without an independent Git revision |
| `RTC_planning/spiders` | inspected linked workspace without an independent root revision; archive evidence includes `archiverservice/src/service.jl`, `replay.jl`, `select-messages.jl`, and the FITS dump tool |
| legacy Calculon architecture workspace | `886aa6b2aa55`; source-neutral time, causality, quantity, DM command, audit, replay, performance-measurement, and operator-client decisions were adapted without adopting its Iceoryx2, SBE, Agrona, per-agent lifecycle, or process topology |
| `calculon-algorithms` | `078218004032` plus its uncommitted Julia client work |
| `pipewire` | `416a1f4ceb14` plus pre-existing row-block and daemon-config changes |
| `pipewireao-spa-plugins` | `c6b7633e904b` |
| `pipewireao-gui` | `bdfcf0074d12` plus its existing working-tree changes |
| [Statig](https://github.com/mdeloof/statig) | upstream `main` at `3780eecdbcf4`; [docs.rs crate 0.4.1](https://docs.rs/statig/0.4.1/statig/) inspected for hierarchy, state-local storage, actions, introspection, and blocking/async modes |

Passing component tests does not establish the proposed system properties.
Each phase above therefore names the system evidence needed before its claims
can be promoted.
