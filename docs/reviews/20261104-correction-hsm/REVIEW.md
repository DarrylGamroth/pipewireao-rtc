# Correction HSM review — 2026-11-04

## Scope and baseline

Reviewed `CorrectionLoops` and `CorrectionRecovery` on
`codex/package-cleanup-20261104` in the `pipewireao-rtc-cleanup` worktree.
The branch starts at `4658e7f676c538df01c919b4902c9df25a63a105` and already
contains the authorized, uncommitted [package cleanup](../20261104-package-cleanup/REVIEW.md).
Those edits were preserved. This increment changes the two correction
machine implementations, their focused tests, repository guidance and review
documentation. The user selected Hsm.jl as the preferred implementation for
Julia-owned state machines where the execution boundary permits it.

Authority: RTC-DEV-032–036, particularly RTC-DEV-034's reference evidence and
RTC-DEV-035's serialized sequencing, failure latching and prohibition on command
effects in entry/exit behaviors. Reviewed against the installed Hsm 0.3.2
dispatch and transition semantics. Recovery's hierarchy is preserved. Loop
control now shares operational handling and pending-state timer behavior through
parents; its five published leaf outcomes are unchanged. Timeout values, wire
contracts, numerical algorithms and process boundaries are unchanged.

## Findings and disposition

### HSM-01 — Failure latching bypasses event handling

Category: accepted design improvement; high confidence. Disposition: implemented.

Previously, `unknown!` and `failed!` changed the failure fields before dispatching
an event that only selected the destination state. The event alone could not
perform the declared operation, and its handler did not show the first-failure
latching rule. That split made the machine harder to review as an event-driven
component.

`unknown!` now dispatches `Unknown(reason)`. Its root handler retains the first
reason and transitions to `Unknown`. `failed!` dispatches
`Failed(reason, uncertain)`; the recovery handler owns first-failure latching,
reference invalidation and selection of `Unverified` or `Fault`. Repeated events
are handled internally without re-entering terminal states.

The loop observer retains one deliberate exception boundary: if Hsm itself
throws before handling an unknown event, `unknown!` latches a publication failure
and returns without throwing. This preserves its previous callback contract.
It does not claim that Hsm completed its transition: `state` continues to report
`Unknown` when failure is latched. A fault-injection test exercises this path.

### HSM-02 — Accepted facts and transitions have different owners

Category: accepted design improvement; high confidence. Disposition: implemented.

Loop request/adoption fields and recovery qualification/protection/close fields
were updated by public wrappers before their corresponding events ran. Accepted
event payloads now carry the facts and the handlers update the fields alongside
their transitions.

| Machine | Event | Handler-owned operation |
| --- | --- | --- |
| Correction loop | `Requested` | Record accepted generation/value; preserve same-value state and duplicate deadline |
| Correction loop | `Observed` | Qualify initial readback or record adoption in the appropriate state handler |
| Correction loop | `DeadlineChecked` | Expire or rearm only through the shared pending-state handler |
| Correction loop | `Unknown` | Retain first failure and enter unknown outcome |
| Recovery | `Qualified` | Record coherent initial loop scope and generation |
| Recovery | `Protect` | Bind new token/reason and initialize protective operation facts |
| Recovery | `Release`, `CloseRemaining` | Record admitted closure selection |
| Recovery | `Failed` | Retain first failure, invalidate reference evidence and select failed outcome |
| Recovery | `LoopObserved`, `RecoveryObserved`, `ReleaseObserved` | Interpret evidence and adopt generations in the matching phase |
| Recovery | `LoopStaged`, `RecoveryStaged` | Bind staging acknowledgements only in Closing/Opening respectively |
| Recovery | `DeadlineChecked`, `Cancelled` | Apply deadlines and cancellation only in eligible phases |

Mutation/observation facades now dispatch domain events rather than inspect the
active phase. Shared transport/identity validation and timeout preflight remain
where required. Effects remain returned once by admitted operations; event
handlers do not send native commands or use an effect mailbox. Event dispatch
does not replace native wire-input validation.

The loop hierarchy is `Operational → Open | Closed | Pending`, with
`Pending → Opening | Closing`; `Unknown` remains outside `Operational`.
`Pending` owns timer entry/exit, adoption and deadline handling. The recovery
hierarchy reuses `ProtectiveOpen` for common forced-open monitoring and
cancellation, with `Opening` overriding monitoring to confirm opening adoption.
Public status/readiness queries may still inspect the active state.

### HSM-03 — Reference observations select phases outside the HSM

Category: accepted design improvement; high confidence. Disposition: implemented.

`observe_reference!` previously inspected the current state to select behavior
and updated freshness or cleared verification outside the handlers. It now
dispatches one `ReferenceObserved` event after identity/serial/generation and
timeout preflight. The active phase decides what the observation means:

| Active state | Valid reference/coherence/readiness | Invalid evidence |
| --- | --- | --- |
| `Verifying` | Record evidence and transition to `Holding` | Clear verification; stay in `Verifying` |
| `Holding` | Refresh evidence internally | Clear verification internally |
| `PartiallyClosed` | Refresh evidence internally | Clear verification internally |
| `Releasing` | Refresh evidence internally | Latch failure and transition to `Unverified` |
| Other phases | Unhandled; retain existing facts | Unhandled; retain existing facts |

Matching observations advance the serial even when reference evidence is
invalid, as before. Invalid evidence does not change the last successful
freshness timestamp. Refreshes return `EventHandled` without a self-transition,
so they cannot restart an adoption deadline.

## Hsm constraints and retained boundaries

- Hsm 0.3.2 rejects recursive dispatch. Handler helpers only validate or mutate
  facts; they never call dispatch, timeout preflight or another public operation.
- Transition targets remain literal calls inside `@on_event`, so Hsm's macro
  lowering retains its supported transition semantics.
- Entry/exit behaviors retain their timer bookkeeping only. Scientific effects
  remain at the existing serialized execution boundary.
- Native timer callbacks still wake the control context rather than dispatching
  from another thread. Expiration remains checked before accepting late evidence.
- Generation staging and cancellation now use phase handlers too. Qualification
  preserves the original initial-state clock-check ordering. Close requests use
  event admission results to return their effect, including the existing
  `released=true` request in Holding falling back to ordinary release.
- `observe_loop!` contains no state switch. Its common shape check still occurs
  before phase handling, preserving the original rejection order. Release
  observations still advance their serial before a prerequisite failure.
- Clipping thresholds, hysteresis and scientific observations are unchanged.
  This review does not introduce another HSM for that algorithm.

Event vocabulary uses existing `Unknown`/`Failed` outcomes, accepted request and
applied observations, and the existing `ReferenceObservation` concept. No new
wire fields, persistent status values or scientific concepts are introduced.

## Other state-machine candidates

These are identified migration opportunities, not additional implementations or
claims of present defects. Prefer Hsm.jl for the Julia control machines below;
use hierarchy only for genuinely shared admission, failure and cleanup behavior.
Do not add another session authority, supervisor or unbounded event queue.

| Priority / ID | Component | Event/handler design and validation boundary |
| --- | --- | --- |
| 1 / HSM-C01 | `CalibrationAcquisition.Procedure`, `src/calibration_procedure.jl:24` | Completion/cancel/expire/fail events; acquisition and restoration/release parents around existing Hold/Adopt/Settle/Collect/Restore/Release phases. Preserve one pending command, known-vs-unknown outcomes, late completion rules and one restoration/release attempt. Use `test/test_calibration_procedure.jl` and acquisition/client selectors. |
| 2 / HSM-C02 | `CalibrationEndpoint`, `src/control/calibration_endpoint.jl:122` | Replace separate action/phase admission and result-derived phase writes with admitted-action and completed-result events. Reuse Prepared/Held/Adopted/Settled/Responses/Captured/Restored/Released/Fault vocabulary. Keep action effects outside callbacks/locks and preserve run/serial correlation and terminal delivery. Use the optional private-core endpoint selector and an action/phase matrix. |
| 3 / HSM-C03 | `CalibrationPreparation.Procedure`, `src/calibration_preparation.jl:92` | A small Hsm gate for Pending/Ready and terminal outcomes. Shared terminal handling must prevent revival; confirmation, expiry, cancellation and invalidation are events. Preserve duplicate-ready invalidation, task ownership, monotonic clock checks and public result semantics. Consistency now favors this migration despite its smaller size. |
| 4 / HSM-C04 | `OwnerBootstrapRuntime.Runtime`, `src/control/owner_bootstrap_runtime.jl:178` | Use Preparing/Prepared/Connected/Stopped/Fault and pending connect/quit substates inside the existing reserved monitor. Owner-thread methods publish facts; only that monitor dispatches. Preserve locks/atomics, thread-one science ownership, exact tickets, discovery sealing and terminal handshakes. Requires private-core, sealed, idle and churn selectors. |
| 5 / HSM-C05 | `ControlEndpoint` ticket admission, `src/control/control_endpoint.jl:271` | Idle and pending Staged/Applying states, with terminal admission closed only after the actual terminal operation. Keep decoded payload/replay caches as data. Preserve same-lock publication, independent rejection, canonical replay and failure retention. `terminal_request` also retains ordinary completed tickets: it must not be mistaken for a terminal lifecycle state. Requires endpoint/fault/publication-failure tests. |
| 6 / HSM-C06 | `SystemdOwners.Service`, `src/deployment/systemd_owners.jl:28` | Cold client-operation states Pending/Running/Stopped/Uncertain/StopFailed can make verification and stop-result handling explicit. Preserve exact process/incarnation/cgroup evidence and refusal of uncertain replacement effects. This remains one-shot client bookkeeping; systemd retains process lifetime and RTC retains session authority. Use the existing systemd-owner and session cleanup selectors. |

Additional conditional candidates and exceptions:

- `CorrectionSupervision.Supervisor` has clear pending/tripped/rearm states, but
  `supervision_observer.jl` calls it from the frame path. Hsm.jl is a consistency
  candidate only after concrete specialization, bounded dispatch and steady-state
  allocation/GC evidence are established for that callback. Do not insert a cold
  coordinator or move numerical threshold/hysteresis policy out of its owner.
- `ParameterSource` publication and `ext/calibration_capture.jl` slot phases
  participate in native buffer/frame callbacks. Consider Hsm for their cold
  orchestration first; a callback conversion needs its own timing/resource and
  ownership proof. Primitive buffer-slot markers are not automatically another
  application lifecycle machine.
- `AcquisitionLifecycleRuntime` publishes another owner's declared lifecycle;
  codec enums and read-only observations describe protocol data. Neither calls
  for an independent lifecycle authority merely to use Hsm.
- Simulator rebuild job states are durable crash receipts shared across
  processes, not a sufficient in-memory machine. Never reconstruct an Hsm from
  a receipt to resume or retry an uncertain replacement effect.

The Lua session policy is already an event/step machine and remains the next
language migration: `runtime/scripts/ao/session.lua` contains lifecycle/epoch
facts, operation admission, guarded callbacks, fault retirement and asynchronous
start/stop/reset/quit sequences. Evaluate Julia/Hsm.jl for policy that can live
on the Julia control boundary; retain C/Rust where RT or compiled-runtime
constraints require it. This choice must preserve the existing headless RTC's
sole authority, libwireplumber event context, exact tickets/epochs/deadlines,
source-first shutdown and the separate filter/scientific process. A native
C/Rust implementation is an explicit Hsm.jl exception, not a reason to introduce
a second Julia session coordinator.

## Verification

Before changing the loop implementation, a new 40-assertion direct-unknown-event
case failed 32 assertions because that event was not handled. This demonstrates
the newly selected event contract, not a previously claimed production failure.
The expanded 45-assertion case now passes. Further tests cover direct accepted
events, shared pending hierarchy, duplicate deadlines, post-failure events and failure of Hsm dispatch
instrumentation without an escaping observer exception.

Nine focused selectors passed before the final dispatcher-wide expansion:
loops, native timers, recovery, recovery clients, coupled recovery, clipping
supervision, observation, supervision clients and graph supervision. The final
loop/timer selectors passed 356 assertions, and the final recovery selector
passed 255 assertions. Together they add 147 assertions over the earlier tests.

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO;
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir);
for name in ("correction_loops", "correction_timers", "correction_recovery",
    "correction_recovery_client", "correction_recovery_controllers",
    "correction_supervision", "correction_supervision_observer",
    "correction_supervision_client", "graph_supervision")
    Base.include(Module(gensym(:HsmTests)), joinpath("test", "test_" * name * ".jl"))
end'
```

An independent final Sol review found no actionable behavioral regression in
the loop/recovery changes, shared pending hierarchy or dispatcher-wide expansion. It checked
failure reasons, ignored observations, serial ordering, freshness, pending
deadlines, command admission/effect ordering and Hsm's run-to-completion rules.
The final core selector passed with exit status 0: **8,692 assertions across
388 reported testsets**. This includes the direct-event tests, native timer
checks, scalar/coupled recovery and client/supervision integration. The expected
Git `cat-file` diagnostic comes from the existing corruption test, not a failed
selector. Raw output: `/tmp/pipewireao-rtc-hsm-final-core.log`.

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO;
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir);
include("test/runtests.jl")'
```

The optional `test/hsm_allocations.jl` selector passed 10 assertions on Julia
1.13.3/Hsm 0.3.2 with one default thread. After 128 warmup cycles, 1,000 nominal
scalar loop request/adoption cycles allocated **0 bytes**, and 1,000 scalar
protect/adopt/verify/release/reclose recovery cycles allocated **0 bytes**.
Measurements use function barriers and include immutable observation/effect
construction and the real clock. The test checks actual token, serial and
generation advancement so an unexecuted cycle cannot satisfy the oracle.

```sh
julia --startup-file=no --project=. test/hsm_allocations.jl
```

This narrow dynamic allocation check excludes construction/warmup, native timers,
transport/publication, coupled scopes, scientific processing and failure paths.
It is not a static allocation proof, a promise that another task cannot trigger
GC, or a timing/deadline qualification. No installed service, existing
application, scientific backend or device was modified or qualified. Markdown,
local links, final newlines and `git diff --check` also passed.
