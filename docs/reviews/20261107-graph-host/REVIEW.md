# Remaining graph-host scope

Date: 2026-11-07. Baseline: published main `b2260ef`, RTC 0.7.1.
Branch/worktree: `codex/graph-host-scope-20261107` / `pipewireao-rtc-graph-host`.
The baseline worktree was clean. Existing worktrees, installed packages and live
sessions are preserved. This continues NEC-12 from the
[runtime scope review](../20261106-runtime-scope/REVIEW.md).

## Findings and disposition

The reviewed host already delegates scientific graph preparation, worker setup,
node construction, startup execution, run/quit and execution cleanup to public
FilterGraphPipeWire 0.5.2 APIs. FilterGraphs 0.10 owns graph processing. No
additional graph executor or worker pool was found in the reviewed RTC host,
analysis or calibration worker. Source size alone does not establish another
upstream-owned implementation to delete.

| Responsibility | Current owner and disposition |
| --- | --- |
| Algorithms, graph preparation and workers | Public `algorithm_declarations`, `configure_threads`, `prepare_service_graph`, `prepare!` and `close_execution` are already used. Retain delegation. |
| Native graph adaptation and processing | Public `PipeWireNode`, `connect!`, `run!`, `quit!` and `command_endpoint` are already used. No callback executor is added in RTC. |
| Metadata requirements | Public `required_input_metadata` supplies algorithm obligations; RTC retains its declared optional telemetry and source-routing policy. Consolidate that policy below. |
| Native admission and session authority | RTC keeps preparation cancellation, connect tickets, readiness, finishing/fault effects and single session authority. Standalone event-file orchestration is not equivalent. |
| FITS startup admission | RTC keeps bounded artifacts, axes/type/shape checks, provenance and cancellation. Public preparation receives the resulting owned arrays. |
| Correction, supervision and physical offsets | RTC keeps its declared observers, control authority and callback composition. These are not another graph engine. |
| Calibration worker lifetime | RTC keeps the owning task/Hsm, bounded commands, stop handoff and release receipts; native execution and endpoint dispatch remain upstream. |

### Removed repetition

Four paths separately assembled the same metadata profiles: graph contract
export, the admitted graph host, optional analysis and calibration workers. They
repeated graph format/source queries and algorithm-requirement resolution. This
could make exported port contracts and actual nodes diverge when policy changes.

Private `GraphOwner.metadata_profiles` now assembles that existing RTC policy
once, using only public FilterGraphs format/provenance APIs and
FilterGraphPipeWire `required_input_metadata`. It returns the existing
`input_metadata` / `output_metadata` constructor keywords. All four paths use
the result. The optional extension interface is declared without importing
science into the core package. This removes 20 net runtime lines; it does not
claim a new upstream transfer.

The helper retains the full input-index domain for output provenance while
excluding private feedback ports from the public profiles. Required records,
optional acquisition/exposure/reference facts and optical/electrical
classification negotiation still come from the unchanged `Common` policy.
Analysis still derives profiles from its original graph before synchronized
input wrapping. No new type tests, dependencies, configuration or public API
names are introduced.

| Identifier | Meaning and naming authority | Scope |
| --- | --- | --- |
| `GraphOwner.metadata_profiles` | RTC's metadata profiles for public graph data ports; follows `Common.telemetry_metadata_ports` and PipeWireNode's documented exact metadata-profile keywords | Private optional graph interface, not a new exported API |

### Remaining integration limits

The standalone `run_service` is not a public library replacement for the RTC
host: it owns event-file readiness/connect/quit orchestration. Replacing RTC's
outer lifecycle with it would lose native admission and cancellation boundaries.
Do not introduce another generic host wrapper merely to hide existing library
calls. Further upstream lifetime consolidation must preserve externally owned
admission, exact metadata, observer composition and cleanup before it can replace
that sequence.

Analysis still reads the upstream frame observer's retained failure state, and
correction timer notification accesses the node's underlying filter. The current
public node API has no equivalent observer-status/notification accessor. Native
`last_error` is not a substitute: observer failures intentionally leave accepted
science running. These representation accesses are retained rather than replaced
with a new polling or failure policy.

NEC-13's sparse publisher and calibration probe publication are transport
questions for PipeWireAO, not graph execution that `run_service` replaces.
Authority validation immediately before publication and exact feedback
correlation must remain. No scientific, transport or lifecycle feature is
retired by this cleanup.

## Verification

The cohort selects registered FilterGraphs 0.10.0, FilterGraphAlgorithms 0.12.0,
FilterGraphPipeWire 0.5.2, PipeWireAO 0.9.2 / JLL 4.0.2+0, AOS 0.3.21,
HIL 0.5.0 and calibration 0.17.3. Only RTC is a development source. No upstream
package or registry metadata is changed.

Focused selectors cover actual native metadata callbacks, synchronized analysis,
prepared session schemas, typed/chopped calibration and FITS startup binding.
Private-core selectors cover worker ownership and named-command transport with
the JLL artifact explicitly selecting the matching daemon.

| Gate | Passing assertions |
| --- | ---: |
| Actual analysis metadata callbacks | 20 |
| Synchronized analysis construction | 3 |
| Prepared graph/session schemas | 32 |
| Session/science metadata integration | 90 |
| Calibration type/dispatch contracts | 27 |
| Chopped calibration | 58 |
| FITS graph startup integration | 25 |
| Private-core calibration worker | 206 |
| Private-core named-command transport | 133 |
| Documentation links/structure/requirement IDs | 689 |

All focused and private-core selectors exit 0, totaling 255 and 339 assertions
respectively. All four modified Julia files are formatter-idempotent. The core
suite is still in progress; its result will be recorded after completion.

An independent read-only source review found no semantic changes in feedback
indices, synchronized-input handling, required/optional records, extension load
dependencies or lifecycle ownership. Logs use
`/tmp/rtc-graph-host-*-20261107.log`; the temporary cohort project is
`/tmp/rtc-graph-host-env-20261107`.

These checks create no installed application or live session. They establish
software behavior, not hardware, cadence, allocation or real-time qualification.
