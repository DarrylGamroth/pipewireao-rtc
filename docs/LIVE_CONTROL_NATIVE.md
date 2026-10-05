# Native simulator control contract

This is the selected complete-frame simulator control transport under
[RTC-DEV-025/026](operations.md#rtc-dev-025--acknowledged-simulator-admission-and-controls).
The selected source-owner implementation passes the installed Classic/Copper
FGN/JFG lifecycle checks in [validation](LIVE_CONTROL_VALIDATION.md). Existing
sustained frame evidence is separate. Independent findings and adjudications are
in [LIVE_CONTROL_REVIEW.md](LIVE_CONTROL_REVIEW.md).

## Transport and ownership

The supervisor connects to the deployment's private PipeWire core by its
owned absolute socket path and binds exactly one advertised source node. The
supervisor does not inherit the child owners' private runtime-directory setting. Registry global ID and `object.serial`
identify that incarnation; public NodeInfo provides control versions, positive
source instance and the expected supervised owner PID. Initial discovery and
static compilation use one absolute cold-preparation deadline selected by the
owner preparation option: 90 seconds by default. The qualification harness
explicitly selects 900 seconds. This phase keeps the source held and emits no
commands or frames; it compiles the concrete request keyword signature before
admission. Failure marks the source failed and prevents reconnection in cleanup.
Each actual request then has its own absolute deadline covering dispatch,
submission and completion observation: 8 seconds normally, 16 seconds for
stopped reset. The startup phase is never re-entered by a live request. No
blocking core roundtrip is used.
Wrong/missing schema, removal, replacement, disconnect or timeout yields an
unknown outcome, revokes admission and prohibits automatic retries.

The parameter callback copies a bounded POD into prepared storage, validates
it, and stages scalar fields. It never changes plant or admission state.
The serialized simulator consumes requests between completed exchanges, after
the previous same-sequence DM command was adopted. Its pending slot remains
occupied until publication succeeds. Reset executes only with the source held
and RTC stopped, changes acquisition generation and retains token history.

The unchanged native V1 run/reset request and completion PODs are built and
parsed using PipeWireAO's public native wrappers. Pause/resume request
`stopped`/`running`; reset uses its existing native reset contract. A status
request uses a separate, exact V1 named SPA Props schema:

| Query key suffix under `pipewireao.source-query.` | SPA type | Meaning |
| --- | --- | --- |
| `version` | Int | 1 |
| `request-token` | Long | Positive Int64 token, shared monotonic namespace |
| `instance` | Long | Positive source instance advertised by the bound node |

## Completion and rejection snapshots

One prepared native update publishes all four retained `SPA_PARAM_Props`
objects: native run status, native reset status, accepted source snapshot and
independent callback-rejection snapshot. All use standard `SPA_PROP_params`
named scalar fields. No custom property ID or native header change is needed.

A source snapshot uses key prefix `pipewireao.source-snapshot.`; its rejection
counterpart uses `pipewireao.source-rejection.` with the same scalar shape.

| Key suffix | SPA type | Meaning |
| --- | --- | --- |
| `version` | Int | 1 |
| `instance` | Long | Bound source instance |
| `kind` | Int | Initial 0, run 1, reset 2, query 3; malformed rejection 4 |
| `completed-token` | Long | Matching positive token; zero only for initial/malformed |
| `result` | Int | Zero success or negative native errno |
| `generation` | Long | Positive acquisition generation |
| `sequence` | Long | Nonnegative adopted frame/command sequence |
| `running` | Bool | Whether the owner admits another frame |
| `completed` | Bool | Finite run reached final adoption |
| `report-generation` | Long | Generation of the last successfully saved report |
| `report-sequence` | Long | Adopted sequence of that saved report |

Report readiness means both report coordinates equal the live coordinates.
This equality alone does not imply completion: the prepared/reset empty report
is ready at sequence zero. Completed readiness is published only after final
report writing succeeds. Prefix reports still contain retained-prefix counts;
the sustained companion contains total adopted delivery at its stated cursor.

Subscriber callbacks are separate events, not an atomic snapshot transaction.
The supervisor joins a run/reset snapshot to the corresponding native status
by bound incarnation, kind, token, result and actual state. A query completes
with its own fresh snapshot. Historical run/reset statuses remain cached; they
must not be joined to a later query or a different mutation. Later frames do
not relabel a mutation's committed acknowledgement.

Callback-stage rejections have their own retained object and cannot overwrite
an accepted snapshot/status. A repeated pending or retained committed kind/token identity has its original
outcome, including a conflicting run-state payload under that same token. It
does not change state or publish a competing duplicate rejection. Clients must
use a fresh token for a different request.
A busy/stale validated identity can have a negative rejection snapshot.
Malformed/oversized input has invalid kind and token zero; partial native
parser output never supplies a request identity. Zero-token diagnostics cannot
resolve a positive-token supervisor request.

The implementation has one accepted-request slot and one rejection slot.
Further rejected requests can be discarded while that slot is full. Bounded
storage does not promise replies to a flooding controller; a missing reply
remains timeout/unknown. The supported supervisor serializes requests. Handled
oversize is nonfatal and leaves callback storage and plant state unchanged.

## Reports and allocation measurement

Live status, pause and resume use native snapshots. They do not rewrite JSON,
frame binaries or command binaries. Saved artifacts remain cold preparation,
stopped-reset, final and orderly-termination outputs. Calibration-owner pause
restoration/checkpoint behavior is a separate contract and remains intact.

The simulator process still measures from retained-prefix adoption through
final command adoption, including all actual live controls and held waiting.
The owner uses its existing cooperative yield plus `GC.safepoint()` while held;
this consumes an assigned CPU and is not an isolation or hard real-time claim.
GC remains enabled. Reset begins a new declared run; pause/resume never reset
or subtract counters. Native allocator and subscriber costs are distinct from
Julia heap allocation and require separate resource characterization.

## Current evidence boundary

Prepared native codecs, strict scalar Props parsing, bounded callback overflow,
actual callback trampoline and native source-client private-core lifecycle have
focused passing tests. The owner-loop no-request test exposed and corrected a
captured binding (`Core.Box`); its same fixture now passes. Installed midrun
FGN/JFG campaigns deliver all requested exchanges with zero inclusive simulator
heap/GC fields, stable held cursors and exact repeated reset-prefix hashes.
The separate public deployment command socket and calibration-owner controls
have not been migrated by this source-owner increment.
