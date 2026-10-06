# Native calibration action endpoint review

Date: 2026-10-06. Independent review of the Julia action-server and caller
integration under RTC-ARCH-024 / RTC-DEV-030.

## Source and scope

Review branch `review/calibration-actions-20261006`, dedicated worktree
`pipewireao-rtc-calibration-actions-review`, initially clean at `323f767` on
`eb9d738`. Production source was read only. This review covers
`native_calibration_actions.jl`, its lifecycle Bridge integration, selected
scientific/HEART calibration owners, `CalibrationServer` effect delegation,
the Julia native action client, campaign binding and HEART caller integration.
The maintained contract is `NATIVE_CALIBRATION_ACTION_CONTROL.md`.

The Rust endpoint adapter is explicitly unfinished in this source revision.
Its old `--endpoint` interface is known migration debt; the new Julia invocation
arguments do not establish Rust readiness. Launcher readiness JSON supplies
connection hints only; native discovery must still prove exact live identity.
Issue #8 owns replacing that bootstrap handoff. Neither limitation is promoted
as a completed native capability here.

## Review observations

- The action endpoint borrows the existing Bridge Core and ThreadLoop. Parameter
  callbacks stage owned, bounded typed values; the existing sole owner invokes
  `CalibrationServer.execute!`. No scientific scheduler or additional SCI effect
  task is introduced.
- The typed adapter retains Hold, Adopt, Settle, Collect, Capture, Restore and
  Release implementations. The only effect-code change selects a transport
  reply-capacity preflight. Figure dimensions, measurement dimensions and exact
  128 KiB Collect reply capacity are checked before SCI identity binding or
  acquisition. Native success messages are empty, matching that size budget.
- Fresh client binding includes private remote, exact node, PID and positive
  incarnation. Common-envelope controller identity/token/operation and action
  run/serial are checked independently. Increasing serials permit gaps, as the
  existing SCI owner contract requires; wraparound is rejected locally.
- Wrong dimensions and wrong run/nonincreasing serial do not update the
  inactivity receipt time. An owned admitted request sets that time from its
  ingress deadline minus budget, so scientific effect duration consumes the
  same inactivity window. Effect checks also enforce the accepted ticket's
  finite absolute deadline and current controller proof.
- Paused ordinary actions return Cancelled. Restore and Release remain available
  for recovery. Actual SCI failure is reflected in native lifecycle Fault while
  the Core is usable. The special transport abort after actual Release retains
  released/restored/unheld facts.
- Release completion is flushed using exact public Core synchronization before
  action endpoint closure. The lifecycle endpoint remains open for Shutdown.
  Action ingress closes before the normal post-service SCI cleanup path.
- The Julia client retires unknown outcomes without reconnect or retry.
  Dictionary requests and reports are local adapters; selected owners no longer
  create a Unix action listener or perform live JSON action framing.

## NCAE-001 — foreign request retirement faults the bound calibration run

- Severity: P1. Confidence: high. Classification: confirmed source defect and
  deterministic private-core reproduction.
- Disposition: independently confirmed, accepted by the primary agent, fixed
  in `5743b3e`, and independently verified. Review-worktree cherry-pick:
  `d206c42`. Corrected action-server source SHA-256:
  `66276c157686c590b8cc1ed2b3da7f9bc73278719a58332ca1cf40b08c189a43`.
- Affected code: `deployment/hil/native_calibration_actions.jl`, `serve!`
  terminal-request handling and `_fault_transport!`; related `apply!`
  foreign-controller completion path.
- Baseline: `323f767`; action-server source SHA-256
  `fc8db4f8b87a61a28a28b84787fade34f960bb801f68365d8c909efcf2bccb19`.

### Observed

The private-core discriminator establishes this ordering:

1. Controller A completes Hold and remains bound to the healthy SCI owner.
2. Hold the sole owner at its safe service boundary, without holding the
   ThreadLoop lock.
3. Controller B stages a Restore request on the same action endpoint.
4. Close B's actual public controller Filter under its own ThreadLoop lock.
5. Wait until the owner's exact `controller_present(B)` proof is false.
6. Resume the sole owner so it can take the staged request.

Result: **7 passed, 3 failed**. The owner reports
`TransportFailure("calibration request expired before effect")`, changes phase
from held to fault, and becomes faulted while retaining hold. Its bound A
controller and SCI run/serial are unchanged; B performs no adoption. The
three failures are the expected absence of server failure, absence of SCI fault,
and preservation of held phase. No disposable private daemon remains.

Exact reproducer and fail-before log:
`~/.cache/rtc-calibration-actions-review-20261006/foreign-retirement.jl` and
`foreign-retirement-before.log`. Julia 1.12.7, bounds checking enabled, prepared
HIL dependencies with source `PipeWireAO.jl` prepended to LOAD_PATH. Source SDK
revision was `3545127`. CPU 15 was shared with other cold validation; elapsed
fixture time is not a latency qualification.

### Derived mechanism and related race

Normal foreign-controller application returns InvalidEvidence without SCI
mutation. Generic ingress can instead terminalize a staged request on expiry
or controller removal before application. `serve!` treats every newly observed
terminal ticket as fatal without checking whether it belongs to the controller
already bound to the run. Its catch then calls `_fault_transport!`, faulting A
because the owner has not reached Release. This violates RTC-DEV-030's rule
that caller collisions preserve accepted state and binds B's lifetime to A's
run incorrectly.

A related source-derived race exists after a foreign ticket has been taken:
`apply!` emits a semantic InvalidEvidence result with a zero transport result.
`Endpoint.complete!` consequently checks B's deadline/presence again. Expiry or
removal there throws through the same service fault path. This second ordering
was source-derived at baseline, rather than a second independently observed
failure. Its expiry and removal branches were exercised successfully during
post-fix verification below.

### Adjudicated remediation and required validation

Keep foreign pre-effect terminalization neutral to the bound controller's SCI
state and inactivity clock. Retiring a foreign ticket must also remain neutral
if its deadline expires or its controller disappears during the known-no-effect
completion path. Keep the bound controller's removal/deadline failure and real
Core/endpoint publication failure fail-closed. Preserve bounded generic ticket,
completion and rejection storage; do not introduce a second SCI owner or weaken
normal accepted-action deadline checks.

Rerun the exact reproducer after remediation and require A to remain held and
healthy, then successfully Restore and Release. Add the complementary foreign
expiry and taken-ticket completion race, and retain regressions proving that
bound A removal, action expiry and actual Core loss still fault or retain
unknown outcome as required.

### Independent post-fix verification

The exact original discriminator now passes **12/12**, compared with **7 passed,
3 failed** on the baseline. Controller A remains healthy and held after B's
retirement, then successfully performs Restore and Release. The extra two
success assertions are reached only when A remains healthy. The test source
was unchanged between the discriminating before and after runs; only the
review worktree's production source changed.

Further cold verification passed **80/80**:

| Check | Assertions | Observed outcome |
| --- | ---: | --- |
| Maintained foreign pre-take expiry/removal and expiry while applying | 26 | A's controller, activity, run, serial, phase and hold preserved; A restores/releases |
| Maintained expired initial invalid ticket before take | 7 | No controller or SCI identity binding; subsequent valid run succeeds |
| Foreign removal after take and bound-controller expiry before take | 19 | Foreign removal remains neutral; bound-controller expiry faults and retains hold |
| Injected actual endpoint publication failure during expired foreign completion | 11 | Failure propagates, endpoint becomes failed, A faults/holds; no foreign adoption |
| Maintained bound-controller removal | 9 | Fault and hold retained, native lifecycle Fault observed |
| Actual disposable private Core termination | 8 | Owner faults and retains hold; action ingress closes without restoration claim |

Total independent post-fix assertions: **92/92**, including the original 12.
The publication test supplies a controlled throwing callback to the real generic
endpoint publisher; it does not synthesize an owner result. The core-loss test
terminates only its own disposable private daemon. Both confirm that the
foreign-retirement exception path does not conceal real owner transport
failure. No production source was modified for these tests.

Source inspection confirms why these cases remain distinct. The neutral
completion fallback first requires an operational endpoint and the identical
pending/applying ticket, then confirms that the foreign ticket actually expired
or lost its controller. `publish!` poisons endpoint failure before rethrowing,
so its error cannot pass that operational check. Bound-controller terminal
retirement still takes the original fail-closed path.

Evidence in the same cache directory:

- `foreign-retirement-after.log` (exact original discriminator).
- `foreign-retirement-verification.jl` and
  `foreign-retirement-verification.log` (63 assertions).
- `bound-controller-core-loss.jl` and `bound-controller-core-loss.log`
  (17 assertions).

All runs used Julia 1.12.7 with bounds checking on shared CPU 15 and printed the
loaded source SDK path. Precompile cache/version warnings from the layered
prepared HIL/source SDK environment remain in the logs; the tests completed
successfully. These are protocol and cleanup assertions with synthetic SCI,
not timing, installed-owner or scientific qualification.

## Evidence discipline and remaining gates

Investigative evidence is retained under
`~/.cache/rtc-calibration-actions-review-20261006/`. The test uses a disposable
private core and synthetic acquisition effects, on CPU 15 shared with other
cold validation. Timing observations are not isolated latency measurements.

Earlier discriminator attempts are retained separately: an invalid attempt to
close a client with an active request violated the client's serialization guard;
a module-local controller identity mismatch invalidated another assertion; an
otherwise passing 12-assertion run released the owner before proving removal
and therefore did not distinguish the suspected ordering. The first invalid
close attempt also aborted during abnormal teardown. These are rejected setup
records, not evidence of an action-server or SDK root cause.

The implementation's reported 646 connected synthetic assertions and 219
client/campaign/export assertions are software evidence. Actual installed
Classic/Copper scientific and HEART actions, restoration, native Rust caller
parity, exported asset completeness and end-to-end qualification remain distinct
primary-agent gates.
