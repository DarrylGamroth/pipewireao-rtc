# Native acquisition lifecycle integration

Implementation decisions for RTC issue #6, RTC-DEV-030 and migration phase D,
2026-10-06. This is an integration plan, not qualification evidence.

## Existing ownership

The scientific calibration owner, HEART calibration owner and HEART correction
owner remain their existing serialized acquisition owners. Parameter callbacks
only stage bounded requests. Native controls do not introduce an acquisition
task, frame scheduler, model driver or second mirror-command owner.

The calibration action migration remains issue #7. The phase D lifecycle
endpoint can coexist with the old action framing during implementation; that
framing remains explicitly unmigrated. It must not become a lifecycle fallback.

## Lifecycle and cursor contract

Separate calibration and correction profiles use the common native envelope.
Preparing, Prepared, Connected, Fault and Stopped describe deployment readiness;
running and completed describe the existing finite acquisition/admission state.
Do not make another scientific state machine from these readiness states.

Status, Pause, Resume, Reset, Connect and Shutdown are bounded zero-argument
operations. A status completion contains the actual acquisition cursor and a
separate report cursor. Each preserves all four UInt64 components: domain,
generation, sequence and model time. A report cursor advances only after the
corresponding saved report was successfully published. Report existence or a
cached report cursor cannot satisfy a fresh query.

The snapshot retains the existing acquisition phase, held/restored flags and,
for correction, the actual window identity. The calibration phases come from
`CalibrationServer.Owner`; correction phases come from its existing held,
active and restored window/telemetry boundaries. Snapshot validation must not
claim release by interpreting paused, completed or closed as released.

## Application boundaries

- Preparation publishes the cold endpoint before loading/preparing the plant,
  then Prepared only after the existing science preparation succeeds.
- Connect is applied by the sole owner, constructs/starts the same acquisition
  endpoints, establishes required native HEART hold where applicable, and
  publishes Connected only after those effects complete. It does not release
  normal acquisition admission.
- Resume admits the next unit through the existing owner. Pause gates new units;
  it does not cancel an already accepted calibration action or reset its probe.
  Complete a mutation at the appropriate existing acquisition boundary, outside
  parameter callbacks and without holding the native loop lock across effects.
- Calibration Reset is an explicit unsupported-operation rejection requiring a
  fresh instance. It must not alter the current held probe or cursor.
- Correction Reset retains the existing completed/restored window checks,
  verified HEART replacement generation, plant reset, telemetry fences and
  preserved earlier window evidence. Nested operations receive the accepted
  request's remaining deadline.
- Shutdown cannot report successful release while restoration is unresolved.
  If the calibration owner holds an unrestored figure, reject ordinary shutdown
  and continue allowing Restore/Release through the action owner. Failure cleanup
  may close owned resources while retaining a truthful fault/held disposition;
  it must not fabricate restoration or a successful Release.
- A successful terminal shutdown completion follows the actual cleanup boundary
  and is flushed through public core synchronization before endpoint withdrawal.
  If transport disappears, the caller retains unknown outcome.

Lifecycle service calls inside acquisition waits must not reentrantly destroy
the session being used by the outer acquisition stack. Shutdown staging alone
is not completion. Current action admission, restoration and fault behavior
remain owned by `CalibrationServer.execute!` and its acquisition methods.

## Integration and acceptance

The deployment descriptor identifies the selected lifecycle profile and node.
The supervisor binds the actual spawned PID and fresh endpoint incarnation,
observes preparation, applies Connect, establishes the existing runner/session
links, then applies Resume. Replace request/reply and preparation/connect/quit
files only when each owner and actual caller implement that sequence. Ordinary
simulator startup files remain a separate issue #9 migration boundary.

Qualify codecs and callback staging first, then actual scientific and unchanged
HEART owners on a private core, followed by fresh installed Classic/Copper FGN,
JFG and HEART packages. Preserve unsupported reset, held/restored state, fresh
cursor queries, expiry/removal, competing callers and finite cleanup evidence.
Scientific equivalence and inclusive steady-state allocation checks remain
separate from cold lifecycle transport checks.

## Launcher and exporter increment

The launcher selects a calibration or correction lifecycle descriptor containing
exactly `role`, `argv`, `environment`, `control-protocol`, `control-node` and
`instrument`. The instrument is `classic` or `copper`. It validates the selected
profile, exact argument bindings and absence of live file-control arguments.
The selected source receives an absolute private remote and
`--control-instance @SOURCE_OWNER_INSTANCE@`; the launcher creates that
incarnation before spawn and binds the actual spawned PID. Discovery and
Connect share the finite preparation deadline. Initial Pause, runner admission
and source Resume retain their existing ordering.

Selected exporters require a fresh ordinary native-source base and remove its
preparation, connection, quit and request/reply marker fields and arguments.
Saved scientific reports remain unchanged artifacts. Calibration Reset is
rejected before mutating the runner; a fresh calibration instance is required.
Cleanup requests native Shutdown and requires Stopped, then retains the existing
owned-process-group cleanup when preparation or transport has failed. A rejected
Shutdown does not claim restoration or release.

Root checks on Julia 1.12.7, CPU 15, 2026-10-06: 44 descriptor checks, 21 caller
checks, 150 portable export checks and 74 private-core helper checks passed.
The caller fixtures test unsigned cursors, no invented snapshot for known
rejection, no reconnect after owner loss and rejection of calibration Reset
before effects. The first descriptor test fixture omitted its own client files;
that setup failure is retained separately from the corrected passing fixture.
Evidence is under `~/.cache/rtc-live-controls-20261005/` in
`acquisition-deployment-root-final2-20261006.log` and
`acquisition-export-helper-root-20261006.log`.
The preceding complete deployment suite passed 1,974/1,974 checks in 76 sets;
`acquisition-deployment-suite-root-20261006.log` retains its output. The final
focused caller rerun additionally checks the recorded native token/incarnation
and preservation of unsigned cursors through saved JSON reports.

This increment is caller and exporter implementation. The actual scientific and
HEART acquisition-owner migration and fresh installed qualification remain
pending; it does not complete issue #6 or establish scientific equivalence.
