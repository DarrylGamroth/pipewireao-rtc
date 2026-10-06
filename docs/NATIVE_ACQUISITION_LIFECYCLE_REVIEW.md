# Native acquisition lifecycle foundation review

Date: 2026-10-06. Scope: RTC issue #6 codec foundation and the primary owner's
integration decisions, under RTC-ARCH-024 / RTC-DEV-030. This is an independent
source review, not evidence that owner migration or installed qualification is
complete. No confirmed defect was identified in the reviewed codec foundation.
The integration obligations below remain open until the owner code and callers
implement and verify them.

## Reviewed state and boundaries

- Codec worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-calibration-lifecycle-codec`,
  branch `rtc-calibration-lifecycle-codec`; initial revision
  `ef7cf251e3dd631b48b022585aeaf3523225ef66`, clean before this review document.
  Foundation commit `606998c` is followed by the dispatch correction `ef7cf25`.
- Integration source: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls`,
  revision `60e28b8a262edce94cf6340d446acedf554dacfb`. The integration plan was
  untracked and `docs/NATIVE_HEART_VENDOR_VALIDATION.md` was already modified;
  neither was changed by this reviewer.
- The reviewer owns only this document. No science, vendor process, native
  endpoint fixture or production modification was performed by this review.
- The reviewed integration plan is `docs/NATIVE_ACQUISITION_LIFECYCLE_INTEGRATION.md`
  in the primary worktree, SHA-256
  `baa11ec509526927a110765179ad4d6235229a44649715ebddb349b8fd6cb820`.

The [codec contract](NATIVE_ACQUISITION_LIFECYCLE_CONTROL.md) defines only cold
lifecycle transport. The actual serialized authorities remain
`CalibrationServer.Owner`, its scientific/HEART acquisition sessions, and
`HeartCorrectionOwner.Owner`. Action framing migration is still issue #7;
ordinary simulator startup controls remain issue #9. No new scientific owner,
frame scheduler, model driver or physical authority is proposed.

## Foundation review

| Area | Source evidence and conclusion |
| --- | --- |
| Profile identity | Calibration and correction have distinct versioned profile names and capability namespaces. The shared client binds exact profile, PID, endpoint incarnation, registry ID and serial; a matching wire shape alone does not establish profile identity. |
| Operations | Six zero-field request operations have fixed IDs. The codec checks header/command agreement and rejects unknown operations or nonempty payloads. State-dependent permission and calibration's unsupported Reset belong to the owner. |
| Cursor width | Domain, generation, sequence and model time are UInt64. Both directions reinterpret SPA Long bit patterns; no signed comparison or narrowing occurs. Report cursor and correction window preserve high-bit values as well. |
| Snapshot validation | Exact nine-field arity, typed scalars, bounded phase vocabulary, incompatible running/completed rejection, calibration window absence and Connected cursor/generation/window conditions are enforced. Preparing/Prepared can truthfully carry initial snapshots without a cursor. |
| Completion and failure | Successful correlated completion requires a snapshot. Negative completion may use None. Generic client handles the empty initial sentinel separately. Fresh live status must therefore come from a newly matched request, not a report file or the sentinel. |
| Bounds | Shared envelope enforces 16 KiB requests and 64 KiB lifecycle replies. Message and phase strings are separately bounded and validated. No JSON payload or report path is added. |
| Endpoint fit | The generic endpoint stages one owned ticket in the callback and returns it for serialized execution outside the loop lock. Profile traits supply all required request, completion, rejection and failure methods. Existing deadline, controller-removal, retained-terminal and collision rules remain applicable. |
| Dispatch correction | `ef7cf25` replaces profile `isa` branches with `_phases` and `_validate_window` dispatch. Inspection confirms unchanged wire IDs and constraints, with direct phase/window regression checks. |

The codec deliberately does not infer held/restored flags from phase,
completion, readiness or endpoint closure. That is necessary to represent a
truthful partial failure. Additional semantic restrictions must be justified by
the actual owner transitions; schema validation cannot manufacture restoration.

## Integration obligations

These stable IDs are review checkpoints, **not confirmed defects in the codec**.
The primary adjudicated NAL-001 through NAL-004 as accepted required integration
obligations, not codec defects. Their implementation is primary-owner work.
The plan addresses their intended behavior; source and focused integration
evidence must establish the final outcome.

### NAL-001 — Preserve action ownership and restoration evidence

Classification: required integration verification; high confidence in the source
constraints. Affected code: `deployment/hil/calibration_server.jl`,
`calibration_owner.jl`, `heart_calibration_owner.jl` and lifecycle snapshot builder.

Observed: `CalibrationServer.effect!` sets `restored=true` only after adoption and
settling succeed without clipping. Release requires held, restored and phase
`:restored`, then invokes session release before clearing held. `fault!` retains
hold, clears restoration and invalidates the probe. `execute!` refuses all later
actions once faulted. Ordinary Pause must therefore gate new admissions without
throwing through an accepted action and accidentally faulting that owner.
Restore/Release remain admissible while ordinary action admission is paused.

HEART startup additionally has a native/session hold before the action owner's
initial Hold request: `CalibrationServer.Owner(session::Session)` starts at
phase `:initial`, held=false while requiring `session.state.held=true` and a
native hold proof. Preserve the existing action-owner meaning of snapshot held
and document it; do not collapse the separate native hold proof into a synthetic
Release. The existing calibration report already uses `owner.held` and
`owner.restored`.

Required checks: paused held probe remains held and associated; unsupported
Reset changes neither cursor nor probe; Shutdown while unrestored is rejected
without faulting or closing the action owner, so its existing Restore/Release
path remains available. A real failure may retain fault/hold and close resources;
it must not acknowledge restoration. Verify initial HEART native hold separately
from initial action ownership.

Disposition: accepted plan boundary; owner implementation and tests pending.

### NAL-002 — Do not derive correction restoration from completion alone

Classification: required integration verification; high confidence. Affected
code: `deployment/hil/heart_correction_owner.jl`, `finish_window!`, `reset_window!`
and lifecycle snapshot builder.

Observed: the main loop sets `state.completed=true` before `finish_window!`.
That function switches to restore_run and clears `owner.active` before zero
adoption, telemetry stop/drain, validation and archival complete. Only its final
`owner.retained=true` establishes successful restoration and retained evidence.
The session's held flag means serialized plant command ownership and remains
true during active native correction; it is not the native RUN/CORRECT mode.
`PhaseStore.current` ends at restore_run and has no restored label.

Required checks: a failure during restoration can report completed=true and
restored=false; active absence or closed resources cannot become restoration
proof. Derive the lifecycle restored label only after the completed retained
boundary. Preserve positive window identity, old-window artifacts and the
actual reset generation. Keep reset paused until explicit Resume.

Disposition: the plan requires these existing boundaries; final mapping and
failure-boundary tests pending.

### NAL-003 — Apply cancellation and shutdown at safe serialized boundaries

Classification: required integration verification; high confidence. Affected
code: acquisition service hooks, lifecycle dispatcher, nested HEART operations,
report publication and cleanup.

Observed: `CalibrationServer.serve_connection!` services lifecycle control while
waiting for input and from action connection checks. HEART acquisition also
calls its service hook inside waits. Reentrant session destruction there would
invalidate resources still used by the outer acquisition stack. Generic endpoint
`complete!` verifies a successful ticket's deadline and live controller but does
not apply owner effects or perform terminal core synchronization for the caller.

Required implementation: stage a terminal intent without acknowledging success,
reach the existing acquisition boundary, resolve/reject held-state shutdown,
perform actual cleanup, then publish Stopped and synchronize under the accepted
ticket's remaining deadline before endpoint withdrawal. Do not execute accepted
mutations after expiry/removal. If expiry/removal happens during an effect,
retain the actual effect/fault/hold state and preserve the caller's unknown
outcome; do not roll back evidence or retry. Bound nested startup/reset/restore
commands and waits with the remaining accepted budget, replacing their current
fresh fixed timeout starts when invoked by a lifecycle request.

Calibration action reader inactivity remains a distinct authority deadline:
the next reader is started before the accepted action runs. Lifecycle Status or
Pause must not restart it or grant a silent action controller a new lifetime.
Issue #7 must preserve acceptance-based inactivity and controller/run binding.

Required checks: shutdown during an acquisition wait, expiry before mutation,
expiry/removal after a partial effect, stalled terminal sync and owned cleanup.
Verify the selected state after each, not merely transport rejection.

Disposition: correctly identified in the plan; no endpoint integration exists
in this foundation to verify these transitions yet.

### NAL-004 — Publish fresh acquisition and report cursors independently

Classification: required integration verification; high confidence. Affected
code: lifecycle status builder and report writers.

Observed: the codec carries independent optional acquisition/report cursors and
does not impose ordering across their generations. This fits a reset whose new
acquisition cursor precedes a still-retained report from the old window. Existing
reports can fail partway through multiple writes; file existence is not a fresh
native completion.

Required checks: update the report cursor only after the selected report
publication succeeds; retain its prior value on failure. A fresh Status uses the
actual serialized acquisition cursor and a newly accepted token. Exercise
report lag, failed publication and reset across generations with high-bit cursor
values in the codec. Never fill report_cursor from cursor merely for convenience.

Disposition: plan and codec agree; owner publication binding pending.

## Verification evidence and limits

The source and test cases were independently inspected. The primary ran the
focused codec suite on CPU 15 and obtained **174/174 passed** in 2.1 seconds,
recorded in
`/home/dgamroth/.cache/rtc-live-controls-20261005/acquisition-lifecycle-codec-root-20261006.log`.
This reviewer independently read that log and the corresponding test source.
Tests cover both profiles and all six operations, full-width cursors including
the high bit and UInt64 maximum, independent report cursors, valid early states,
negative completion/rejection, arity/type/phase/window errors and envelope bounds.
These are codec tests; they do not execute an integrated acquisition owner.
No additional test workload was launched by this reviewer.

The review document's local links, trailing whitespace and final newline were
checked. No normative requirement definition or Mermaid diagram was changed.

| Artifact | SHA-256 |
| --- | --- |
| `deployment/julia/src/native_acquisition_lifecycle_codec.jl` | `fffc52738240ab8cd9c135176ff38ea28363c2de694113c846b00d3b7b7b559b` |
| `deployment/julia/test/test_native_acquisition_lifecycle_codec.jl` | `77a9f4cd7efdc63b48f46f05b7a16f7c0d080f6a74e9d1d8e5c3745915e7539d` |
| `docs/NATIVE_ACQUISITION_LIFECYCLE_CONTROL.md` | `87570aa2a66fc2b762fa14368edf1db33118090e711abdea60b1de1d6c76b58d` |

Acceptance of this foundation does not establish connected profile behavior,
owner readiness, restoration, shutdown cleanup, installed Classic/Copper
FGN/JFG/HEART operation, scientific equivalence or inclusive steady-state
allocation results. Those gates require the actual owners and callers.
