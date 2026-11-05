# Optical types and calibration projections — 2026-11-04

## Scope and baseline

Continued the authorized cleanup in `pipewireao-rtc-cleanup`, on
`codex/package-cleanup-20261104`, based at
`4658e7f676c538df01c919b4902c9df25a63a105`. The 220 pre-existing changed paths
and earlier Hsm/Agent/Clocks work were preserved. The original checkout, installed
applications, instrument sources and running services were not changed.

RTC-DEV-029/030 remain authoritative. This increment changes representation and
dispatch while retaining optical calculations, transport contracts, provenance
and cleanup. It adds no scheduler or session authority. The production filter
graph remains in its separate process. Lua replacement remains later work.

## Findings and disposition

### OPT-01 — Projection behavior depends on record shape

Accepted improvement; implemented. `GraphProjection` retains graph, document,
bindings, parameter arrays and exact source/FITS provenance. Scalar and ordered
named projections dispatch separately for validation, metadata, probe selection,
worker startup, connections, capture eligibility and partial cleanup. A named
command `graph` no longer collides with a field-based classifier. Graph input and
output declaration forms dispatch on strings, mappings, tuples and named tuples;
boundary validation still reports malformed declarations in the existing order.

Copy construction changes explicit fields without copying or transferring the
graph or arrays. Startup still revalidates original provenance. Partial failures
close accepted graphs once and retain primary and cleanup errors.

Public migration: `calibration_graph` returns a record instead of a NamedTuple.
Property reads remain compatible. Use `GraphProjection(projection; changes...)`
instead of `merge`; the constructor is in `PipeWireAORTCCalibrationExt`. See the
[acquisition guide](../../JULIA_CALIBRATION_ACQUISITION.md#cpu-initial-session-endpoint).

### OPT-02 — Optional fields select measurement and command semantics

Accepted improvement; implemented. Prepared branches carry a `measurement_kind`
subtype of `OpticalMeasurementKind`: `SelectedPixels` or `CenterOfGravity`.
Dispatch selects measurement, fitted rows, reconstruction error, nulling
admission, identity fields, count, reference, units, graph checks and publication.

Prepared results carry a `command_coordinates` subtype of
`OpticalCommandCoordinates`: `PhysicalCommandCoordinates` or
`CompletedVDMCoordinates`. Dispatch selects projection names, command counts,
parameter units and completion publication. An optional measured physical
inverse remains a diagnostic; its presence does not select command coordinates.

Normal preparation supplies both tags. Downstream code manually constructing or
replacing branch/result NamedTuples must retain or explicitly provide them; no
field-presence compatibility fallback remains. These extension-local tags do not
change native schemas or historical report field names.

Observed parity: all 378 saved before/after oracle records match exactly,
including numerical array bits, identity/report values and every generated
bundle file's byte hash. Cases include mixed centroid/pixel/signed branches, nulling
and completed VDM with and without the optional physical inverse. An independent
review parsed the records and confirmed equality. Identity encoding retains
Julia column-major `vec` ordering; selected measurements and FITS retain their
existing row-major conventions. Centroid coordinates remain X=column, Y=row.

### OPT-03 — Adjacent type selectors obscure existing interfaces

Accepted improvement; implemented. Reference stage remote normalization,
Shack-Hartmann settings, native fraction conversion and ordinary/composed
chopped warmup now dispatch on their existing types or sensor trait. Validation,
metadata sequences and optional package loading order are preserved. Tests use
actual private Unix sockets, native ndarray formats and a prepared JFG
composition. No test core is needed for these checks.

### OPT-04 — Calibration worker shares mutable application state

Subsequent disposition: the [command ownership migration](../20261104-calibration-worker/REVIEW.md)
implements the upstream endpoint and removes this RTC sharing. The following
paragraphs retain the API constraint observed during the optical increment.

Confirmed remaining design gap; not migrated in this increment. The user directs
threads to communicate through bounded commands and owned receipts. Each thread
should own its mutable graph/Hsm; dispatch runs to completion on that owner.
Messages containing mutable arrays require copying or an explicit transfer with
no producer access until ownership returns. Cleanup acknowledgement and task
completion precede caller reuse or destruction of scientific storage. Queue
publication may synchronize internally; it does not authorize sharing graph
state between application threads.

`CalibrationGraphWorker` currently shares node/error Refs and readiness/stop
atomics. Independent inspection confirms that FilterGraphPipeWire 0.4.0 delegates
to PipeWireAO 0.9.0's standalone `NdArrayFilter`. Its public contract requires
owner-thread construction/connect/run/close, permitting only `quit!` from another
thread. It exposes no loop accessor, nonblocking iteration or command endpoint.
PipeWireAO's `LoopChannel` requires an `AbstractPipeWireLoop`, so it cannot attach
to this filter. An Agent duty cycle blocked inside `run!` cannot drain commands.
No complete migration using these public APIs was found. The numerical routines
are synchronous and need no additional Agent.

The next implementation boundary is a versioned upstream command endpoint that
wakes the native loop while retaining the Julia node on its executing thread.
It must retain stop during preparation and the readiness-to-run interval; the
current native quit queues a loop invocation and already covers the latter.
Completion is emitted after owner-thread close, and failure/full/closed queues
must not strand shutdown. Status receipts alone would improve publication but
would leave the shared-node quit boundary unresolved. No private native layouts,
speculative callbacks or additional blocking Agent were introduced here.

## Verification

Julia 1.13.3; optional CPU environment created under `/tmp` using this worktree:
AdaptiveOpticsSim 0.3.19, AdaptiveOpticsSimPipeWireHIL 0.5.0,
AdaptiveOpticsCalibration 0.17.3, FilterGraphIsland/FilterGraphPipeWire 0.4.0,
JuliaFilterGraph 0.7.0 and PipeWireAO 0.9.0. The environment directly includes
Proper and the graph packages; the root dependency files were not changed for
these optional checks. Native prefix is the explicitly selected artifact
`0e8228b168a266b5414800f73b12194c4da1beea`. No installed application was rebuilt.

| Software check | Assertions passed |
| --- | ---: |
| Full core suite, package environment | 9,525 across 426 testsets |
| Named projections and declaration/error-order checks | 99 |
| Actual built Classic graph projections | 51 |
| Stale FITS bindings | 6 |
| Parameter source provenance | 56 |
| Partial-stage cleanup | 13 |
| Optical numerical calibration | 202 |
| Optical publication | 72 |
| Detector/exposure calibration | 25 |
| Final chopped CPU calibration | 58 |
| Reference remotes and retained numerical oracle | 40 |
| Native rates and prepared-composition warmup dispatch | 25 |
| Private scalar command transport | 33 |
| Private named command transport | 16 |

The optical detector selector initially failed against both saved and current
production source: its test supplied an empty frame map while the existing
chopped frontend requires the declared detector frame. A test-only correction
supplies its actual schema and shape. Numerical assertions and production
chopped processing were not weakened or changed.

Final private scalar/named transport reruns pass 33/16 assertions using owned
temporary cores, conditioner graphs and real stream links. They exercise
reference/feedback delivery and cleanup, not physical devices. The named selector
also reruns its 99 cold projection assertions; those are counted separately above.

Independent source review found no confirmed regression in projection ownership,
provenance, measurement identities or publication. The real optional extensions
load successfully and the extension/API ambiguity scan reports zero. Independent
final review also confirms the adjacent selectors and final graph parser retain
their previous branch conditions, metadata sequence and error precedence. One
inaccurate test comment was corrected. Live reference campaigns and fresh
Shack-Hartmann staging were not exercised.

The core command is the repository-prescribed `test/runtests.jl` invocation with
the artifact prefix. CPU selectors use the temporary optional environment and
`OPENBLAS_NUM_THREADS=1`. Transport selectors explicitly use that prefix with
`--threads=3,1` (scalar) and `--threads=4,1` (named). Temporary detailed receipts
are `/tmp/pipewireao-rtc-optical-types-core.log`,
`/tmp/pipewireao-rtc-optical-measurement-comparison.txt`,
`/tmp/optical-projection-dispatch-*.log`,
`/tmp/pipewireao-rtc-chopped-final.log` and
`/tmp/pipewireao-rtc-optical-*-transport-final.log`.

These are software functional/numerical checks. They establish no GPU, hardware,
allocation, GC, cadence, deadline or tail-latency qualification. Existing native
runtime/Lua findings remain under their earlier evidence; no C/Lua changes were
made in this increment.
