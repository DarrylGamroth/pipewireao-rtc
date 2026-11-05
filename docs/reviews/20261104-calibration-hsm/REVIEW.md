# Calibration HSM migration — 2026-11-04

## Scope and baseline

Implemented `CalibrationAcquisition.Procedure` and
`CalibrationPreparation.Procedure` with Hsm.jl on
`codex/package-cleanup-20261104` in the `pipewireao-rtc-cleanup` worktree.
The branch starts at `4658e7f676c538df01c919b4902c9df25a63a105`. The existing
uncommitted [package cleanup](../20261104-package-cleanup/REVIEW.md) and
[correction HSM changes](../20261104-correction-hsm/REVIEW.md) were preserved.
The original `pipewireao-rtc` checkout and installed RTCs were not changed.

Authority remains RTC-DEV-029/030 and the existing
[Julia acquisition contract](../../JULIA_CALIBRATION_ACQUISITION.md).
This increment changes internal state representation and event handling, not
the native action protocol, scientific validation, numerical algorithms,
timeout values or separate filter-graph process. Reviewed against local
Hsm 0.3.2 and verified with Julia 1.13.3.

## Design and preserved behavior

Public mutation functions dispatch events. Phase-dependent updates and command
selection live in leaf or ancestor handlers. Read-only status access and common
type/owner validation remain outside handlers where appropriate. No command
submission, consumer work or file I/O occurs in entry/exit behaviors.

| Machine | Parent | Children and shared behavior |
| --- | --- | --- |
| Acquisition | Active | Acquiring and Recovery share cancellation latching and unknown deadline expiry |
| Acquisition | Acquiring | Holding, Adopting, Settling, Collecting, Processing; known failures request restoration, unknown outcomes fault |
| Acquisition | Recovery | Restoring, Releasing; failures fault without another recovery attempt |
| Acquisition | Terminal | Complete, Aborted, Fault; cancel/expire are harmless, completion/failure are rejected |
| Preparation | Active | Pending, Ready; common cancellation, expiry and invalidation |
| Preparation | Terminal | Cancelled, Expired, Invalidated; no revival or replacement of terminal evidence/reason |

Acquisition uses a transient Idle state for the constructor's Started event.
This lets the handler choose Hold or immediate Restore for an initially cancelled
run. Hsm initial transitions themselves are unconditional. Terminal outcomes are
ordinary hierarchical states so their public rejection/no-op behavior remains
available after completion.

Preparation's lowercase `state` property projects Hsm's current state. There is
no second mutable phase field. Existing property reads, confirmation identity,
owning-task checks and clock sampling order are preserved. `check_current!`
dispatches Expire and then CheckCurrent; the Ready handler admits the request.
Duplicate completion invalidates Ready without sampling the clock. An invalid
or regressing clock invalidates a live gate; terminal gates cannot revive.

Acquisition retains these ordering and recovery rules:

- Run/serial/operation correlation is checked before completion time. A mismatch
  faults without restoration, including when its time is non-finite.
- A correlated completion at the absolute deadline has a known outcome and
  requests restoration when acquiring. Deadline expiry without a completion has
  an unknown outcome and faults without another native command.
- Collect validation and cursor adoption precede owned retained and consumer
  snapshots. Cancellation of an in-flight valid Collect still delivers its batch.
- The first failure is retained. Restore and Release run at most once, and
  cancellation does not interrupt recovery. Recovery failure cannot admit data
  as a complete calibration.
- The transport driver still classifies an outcome as known only after its
  exchange returns. Its existing cold-compilation deadline rebasing is unchanged.

## Findings and disposition

### HSM-CAL-01 — Consumer cancellation recursively dispatches the machine

Category: confirmed migration regression, high confidence. Disposition: fixed
before completion; independent review verified the correction.

The initial migration invoked the consumer from a Collecting handler. A consumer
calling public `cancel!` then recursively dispatched the same machine, which
Hsm rejects. The original implementation reported Cancelled and issued Restore;
the first migration instead reported Processing. The same scripted consumer
established fail-before/pass-after behavior against the pre-migration source.

Collecting now stages one typed owned batch and transitions to Processing.
The completion dispatcher takes and clears that single delivery slot, invokes
the consumer between dispatch steps, then dispatches Consumed. Processing owns
cancellation polling and subsequent command selection. Consumer failure dispatches
Failed with a known outcome. Failure handlers clear stale delivery. No task,
unbounded queue or additional transport authority was introduced.

Tests cover consumer cancellation and cancellation followed by an exception:
one consumer call, exact Restore serial, cleared delivery, first failure,
Restore/Release sequence and final aborted report. An independent Sol reviewer
reproduced these cases against both baseline and migrated source and reported
no remaining findings after the fix.

## Verification

The three focused selectors pass 605 assertions across 24 testsets:

```sh
julia --startup-file=no --project=. -e 'using PipeWireAORTC; include("test/test_calibration_procedure.jl"); include("test/test_calibration_acquisition.jl"); include("test/test_calibration_preparation.jl")'
```

Coverage includes hierarchy/direct events, all six native action deadline
boundaries, mismatch precedence, terminal behavior, snapshot isolation,
consumer cancellation/failure, known transport outcomes, preparation freshness,
clock sampling and owning-task rejection. Existing independent sensor replay
and numerical parity tests remain in these selectors.

The core suite is run with the explicitly selected native artifact prefix:

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO; ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir); include("test/runtests.jl")'
```

Result: 8,828 passing assertions across 396 testsets, process exit 0. The Git
`cat-file` missing-object diagnostic comes from the existing intentional object
deletion test in `test/test_configuration_store.jl`; its assertions pass.

The optional scalar allocation selector passes 13 assertions:

```sh
julia --startup-file=no --project=. test/hsm_allocations.jl
```

After 128 warmup cycles, 1,000 ready-preparation admission checks allocate zero
bytes, including a counted deterministic clock call per check. The same run
retains zero-byte results for 1,000 correction-loop and recovery cycles.
Constructors, cold compilation, preparation transitions, failures, transport,
timers, scientific work and required acquisition snapshot allocations are outside
that measured region. This establishes neither a whole-acquisition allocation
budget nor GC, deadline or tail-latency qualification.

The five changed Markdown documents parse with Julia Markdown. Changed local
link targets and the candidate-review anchor, code fences, final newlines and
public help for the migrated procedures/events were checked. `git diff --check`
passes. No existing requirement identities or Mermaid diagrams were changed.

No installed service, live RTC, instrument source, device or shared PipeWire core
was changed by this increment. Optional science/private-core/live and hardware
gates were not rerun. The prior runtime `ao-session-hooks` baseline failure
remains documented in the package cleanup record; this increment changes no
runtime C or Lua source.
