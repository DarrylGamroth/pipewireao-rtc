# PipeWireAO development roadmap

Status: active implementation plan

Review date: 2026-09-01

## Goal

Deliver the smallest useful RTC workstation: one command constructs a declared
non-actuating PipeWireAO session, one lifecycle runs its existing `fgn-native`
filter graphs, scientists can add ordinary typed algorithms without transport
boilerplate, and the maintained scientific graph is demonstrably equivalent
to the direct or fused implementation.

The first executable remains deliberately small. Delivery proceeds from FITS
→ discard, through one minimal filter graph, to serial and independent
multi-graph composition. Graph authoring remains in standard PipeWireAO
`filter.graph` configuration files. PipeWire and FGN, not the RTC runner,
schedule graph execution. A GUI is a valuable optional observer and editor of
that standard configuration, never a runtime prerequisite.

The active work ends at the non-actuating development gate. The larger former
roadmap is retained only in the [inactive design archive](archive/full-rtc/README.md).

## Starting assets

The sibling Calculon and PipeWireAO repositories already provide the intended
foundation:

- typed Calculon algorithm declarations and array-level reference behavior;
- the FGN plugin ABI and ndarray graph host;
- bounded scalar-property and ndarray-parameter publication;
- a generated REVOLT Classic graph with explicit SHWFS subaperture origins;
- simulated or FITS-compatible sources and non-actuating sinks; and
- standard PipeWire discovery plus GUI inspection surfaces.

These are starting assumptions, not evidence for the RTC gate. The first
implementation task revalidates the exact revisions and interfaces it uses.

## Delivery sequence

```mermaid
flowchart LR
    Contract["0. Freeze the small contract"]
    Transport["1a. FITS to discard"]
    Fixture["1b. One filter graph"]
    Chain["1c. Serial graph chain"]
    Parallel["1d. Independent paths"]
    Revolt["2. REVOLT Classic equivalence"]
    Authoring["3. Scientist authoring proof"]
    Profile["4. Development performance profile"]
    Gate["Development gate"]

    Contract --> Transport --> Fixture --> Chain --> Parallel
    Parallel --> Revolt --> Authoring --> Profile --> Gate
```

### 0. Freeze the small contract

- keep only the active architecture, operating contract, and roadmap in the
  maintained document set;
- use standard PipeWire relaxed SPA-JSON rather than inventing another
  configuration language;
- identify the exact current PipeWireAO and Calculon revisions; and
- map RTC-DEV-001 through RTC-DEV-010 to implementation and tests as work
  begins.

Exit evidence: the active index has no dependency on archived requirements,
all links and diagrams validate, and the implementation team can describe the
first executable without loading the archive.

### 1. Build the RTCW foundation

Deliver these slices in order:

1. **RTC-owned FITS → discard transport fixture.** In the RTC repository's
   private PipeWireAO core, link one finite complete-frame FITS source directly
   to the maintained format-agnostic discard SPA sink through public PipeWire
   factory interfaces. Observe at least one complete buffer and clean up both
   nodes and the link while preserving an unrelated object. This is a transport
   integration preflight, not RTC-DEV-002 or RTC-DEV-004 runner evidence; the
   sibling plugin test remains only factory-level regression coverage.
2. **FITS → one graph → discard.** Use the small Rust runner, one session
   lifecycle, one minimal `fgn-native` graph, and exact declared links. This is
   the minimum RTC-DEV-002 fixture.
3. **FITS → graph A → graph B → discard.** Reuse existing `filter.graph`
   configurations, delegate their parsing to PipeWireAO, and add only the
   session-level composition needed by RTC-DEV-010.
4. **Two independent source → graph → discard paths.** Realize and control
   both paths as one session while leaving their execution to PipeWire. Inspect
   the active topology with ordinary tools and, where a bounded non-gating
   boundary exists, attach and stall an optional GUI observer.

For the runner slices beginning with FITS → one graph → discard:

- create the small Rust `pipewireao-rtc` executable;
- use Statig's blocking state-machine API, a `MANAGED` superstate, one
  serialized dispatcher, and typed effects from the first implementation;
- load admitted sources, existing `fgn-native` filter graphs, and maintained
  discard sinks from standard configuration;
- implement `OFFLINE`, `CONFIGURING`, `READY`, `RUNNING`, and `FAULT`;
- validate topology and initial values before streaming;
- expose the objects to standard PipeWire inspection; and
- clean up only owned objects on every failure point.

Exit evidence: the RTC-owned transport preflight delivers one complete 4 by 3
U16 image-sized buffer and removes its source, link, and sink without touching
the unrelated object. It does not inspect pixel values. Every subsequent
runner fixture starts, runs, stops, restarts, retries, and unloads repeatedly;
each complete path delivers a buffer to its discard sink; malformed
configurations fail with scientific diagnostics; exact owned objects are
removed; unrelated PipeWire objects survive; and a read-only observer is
optional.

### 2. Add REVOLT Classic

- load the maintained 277-actuator complete-frame REVOLT Classic graph;
- use explicit subaperture origins;
- publish its reconstructor, references, origins, and other ndarray
  parameters through their declared parameter ports;
- apply declared scalar properties through the existing property surface;
- connect a deterministic simulated or FITS input and a non-actuating command
  sink; and
- compare every accepted output and relevant state with the direct or fused
  reference.

Exit evidence: deterministic start, stop, source end, reset, property update,
and parameter update scenarios satisfy RTC-DEV-007 at declared tolerances.

### 3. Prove scientist authoring

- remove any remaining requirement to edit a central adapter registry;
- demonstrate package-local declarations for representative stateless,
  stateful, multi-input, and ndarray-parameter algorithms;
- make errors use scientific port, property, parameter, shape, and schema
  names; and
- show that the same implementations run in ordinary array tests and can be
  consumed by a non-PipeWire graph builder.

Exit evidence: a scientist unfamiliar with SPA can add, test, compose, run,
and inspect a representative algorithm by touching only its scientific package
and graph configuration.

### 4. Characterize development performance

Performance characterization answers whether the abstraction is practical;
it does not create a real-time qualification claim.

- compare the complete-frame FGN graph with the maintained direct or fused
  REVOLT implementation using identical inputs and thread settings;
- measure warmup separately from steady state;
- retain per-frame distributions, throughput, CPU time, allocations, context
  switches, and the exact software and host configuration;
- profile enough to attribute material overhead to graph callbacks, format or
  buffer handling, operation boundaries, or algorithm work; and
- repeat after any optimization that changes the comparison.

Exit evidence: a reproducible report states the cost of the development graph,
where that cost occurs, and whether it is acceptable for continued work. It
does not claim camera-to-DM latency, fixed-arrival behavior, row-block benefit,
or correction-critical suitability.

## Requirement delivery map

| Requirement | Primary increment | Implementation | Evidence | Required evidence |
| --- | --- | --- | --- | --- |
| RTC-DEV-001 | 1 | partial | partial | Endpoint allowlist and negative physical/correction fixtures pass; the live development fixture reaches `READY` and `RUNNING` without physical authority |
| RTC-DEV-002 | 1 | partial | partial | The minimal fixture and field-by-field diagnostics pass; both live links negotiate before `READY`, but explicit live enumeration of every declared format field remains missing |
| RTC-DEV-003 | 1 | partial | partial | Failure-injected cleanup and the live exact topology pass; both links are admitted, owned objects are removed, and the unrelated node survives |
| RTC-DEV-004 | 1 | partial | partial | Transition, retry, invalid-command, required-object failure, repeated-cycle, and complete live lifecycle tests pass; the live graph also stops and restarts within one load |
| RTC-DEV-005 | 2 | planned | missing | Requested/active property and parameter update tests |
| RTC-DEV-006 | 1d and 2 | partial | missing | The runner has no GUI dependency and rejects an undeclared observation; no suitable bounded non-gating sample boundary is available for attach, detach, and stall evidence |
| RTC-DEV-007 | 2 | planned | missing | Deterministic REVOLT output and state oracle |
| RTC-DEV-008 | 3 | planned | missing | Package-local declaration examples and ordinary-array tests |
| RTC-DEV-009 | 1 | partial | partial | Statig hierarchy, serialized dispatch, typed effects, effect failure, stale-completion, and full private-core lifecycle tests pass |
| RTC-DEV-010 | 1c and 1d | planned | missing | Exact serial and independent multi-graph sessions, session-wide lifecycle and failure injection, standard configuration delegation, and absence of a runner scheduler |

Implementation and evidence state remain separate when this table is updated.
A merged implementation is not validated until its complete evidence passes
for both maintained fixtures.

### Increment 1 implementation note

The current implementation baseline is PipeWireAO
`abe269d63c0aa553c5cb96da245a8a5de715ec42`, the public PipeWireAO Rust
binding `75f407498f24a884f97ef3dc4fa3675a61e641fd`, PipeWireAO SPA plugins
`059dbc63d15f2089a054722ca6b5162e1a18b832`, and Calculon
`3d49237b3c9f4423f120b52bd2761cd5a90f5e94`. These revisions identify the
interfaces inspected for this increment; they do not promote sibling worktree
changes to evidence.

The executable, standard PipeWire relaxed SPA-JSON decoder, Statig lifecycle,
fake graph adapter, and live private-core adapter are present. A narrow C shim
exposes the public `spa_json_*` cursor API missing from the Rust binding; the
runner decodes directly into its development configuration and does not parse
FGN graph internals. The configuration rejection matrix is in
`tests/configuration.rs`; lifecycle and effect-completion coverage is in
`tests/lifecycle.rs`; deterministic object and link failure injection is in
`tests/graph_adapter.rs`; and the maintained private-core target is in
`tests/live_private_core.rs`. Its RTC-owned FITS transport implementation is in
`tests/live_private_core/fits_discard.rs`; it does not invoke or count the
sibling repository's integration test.

The live test is intentionally ignored by the generic Cargo suite because it
requires the maintained sibling PipeWireAO and Calculon build artifacts. Its
explicit invocation now passes the complete `Load` → `READY` → `Start` →
`RUNNING` → `Stop` → `READY` → `Start` → `RUNNING` → `Stop` → `READY` →
`Unload` → `OFFLINE` lifecycle. It confirms the three configured nodes, both
admitted links, a discard-buffer increase after each start, complete
owned-object cleanup, and preservation of an unrelated node. The test observes
delivery to the sink, not the numerical contents of the output frame.

The discard scheduling handshake and lower-level factory regression are in
PipeWireAO SPA plugins commit
`a913feda4f564109844b635007b16b6bf7137435`, one commit ahead of that
repository's current `main`. The RTC live result uses its build-tree artifact
through `PIPEWIREAO_SPA_PLUGINS_BUILD`, but the RTC repository creates,
observes, and cleans up its own FITS → discard topology. The result is valid
local evidence but depends on an unmerged plugin revision. The next RTCW slice
replaces the simulated source in the runner fixture with the admitted FITS
source before adding graph chaining.

The FITS source currently ignores the requested public `node.name` and exposes
the fixed name `fits_source` from `spa/plugins/fits/source.c`. The RTC transport
fixture accepts that observed fallback so it can test frame delivery, but this
is not exact configured-identity evidence for RTC-DEV-003 or multi-source
evidence for RTC-DEV-010. The narrow lower-level fix is for the FITS factory to
adopt the supplied `node.name` during initialization and cover two distinctly
named instances in its factory tests.

The runner pins PipeWireAO-rs revision
`75f407498f24a884f97ef3dc4fa3675a61e641fd`. That revision accepts negotiated
fixed ndarray values represented as `SPA_CHOICE_None`, removes the retired
acquisition-wire definitions, and exposes a self-destruction-aware owner for
locally loaded modules. The live adapter uses that owner directly; it no longer
carries module-lifetime or retired-symbol compatibility shims.

The binding does not expose the public
`pipewireao-plugins/discard.h` property identifiers. The live adapter therefore
keeps the two metric IDs it reads at its narrow discard boundary. A later
PipeWireAO plugin binding can remove those constants; this gap does not require
another module or unsafe shim.

## Development completion gate

The milestone is complete only when:

- RTC-DEV-001 through RTC-DEV-010 are implemented for the maintained fixtures;
- one command loads the REVOLT Classic development configuration;
- output and state equivalence pass for nominal frames and updates;
- repeated lifecycle and failure tests leave no owned objects behind;
- an optional observer cannot change accepted results or progress;
- scientist authoring requires no SPA or central adapter work; and
- the development performance comparison is reproducible and honestly scoped.

This gate unlocks continued algorithm and graph development. It does not
unlock physical hardware, correction, production operation, or a real-time
claim.

## Deferred capabilities

The following topics are not active work. Their previous proposals are
sequestered so they do not expand the implementation by accident.

| Capability | Archived input | Promotion trigger |
| --- | --- | --- |
| Physical camera service | [camera sessions](archive/full-rtc/camera-sessions.md) | A named camera is selected after the development gate |
| Physical DM and correction authority | [scientific command contract](archive/full-rtc/scientific-data-and-command-contracts.md) | A named non-actuating simulation has first validated the command path |
| Recording and reconstruction | [audit](archive/full-rtc/audit-and-reconstruction.md) and [operations](archive/full-rtc/operations.md) | A concrete stream-retention and recovery need is selected |
| Row-block and worker execution | [time and performance](archive/full-rtc/time-and-performance.md) | Complete-frame correctness is established and a camera-readout latency target exists |
| Julia execution service | [full operations](archive/full-rtc/operations.md) | Native execution and the scientist declaration boundary are stable |
| Remote GUI and WebAssembly | [full operations](archive/full-rtc/operations.md) | A concrete remote-operations use case exists |
| Operational lifecycle and service supervision | [full architecture](archive/full-rtc/architecture.md) and [operations](archive/full-rtc/operations.md) | A physical service or unattended deployment is selected |
| Target-host qualification | [time and performance](archive/full-rtc/time-and-performance.md) | An exact physical topology, offered load, deadline, and host are named |

Promotion is one capability at a time. The archived text must be reviewed
against current lower-level interfaces and reduced to the minimum active
contract needed for that capability; the archive is never reactivated as one
package.
