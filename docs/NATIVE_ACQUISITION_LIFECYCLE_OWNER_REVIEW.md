# Native acquisition lifecycle owner review

Date: 2026-10-06. Independent review of actual HIL owner integration, separate
from the codec and transport-helper reviews.

## Scope and source

Review worktree: `pipewireao-rtc-lifecycle-owner-review`, branch
`review/acquisition-lifecycle-owners-20261006`, initially clean at `d64879e`,
including `ea77c36`. Production was read only. Root integration equivalents are
`027bbe8` and `eb9d738`. The generic accepted-action retirement change was also
reviewed at root commit `438a048`.

The authority is `NATIVE_ACQUISITION_LIFECYCLE_INTEGRATION.md` in the integration
branch, together with the NAL-001 through NAL-004 obligations in
`NATIVE_ACQUISITION_LIFECYCLE_REVIEW.md`. Reviewed the bridge, scientific and
HEART calibration owners, HEART correction owner, action server boundary hooks,
nested native HEART reset calls, report writers and endpoint retirement path.

This review establishes source and cold software behavior. It does not establish
installed owner admission, unchanged vendor HEART operation, scientific
agreement, correction performance, or steady-state allocation of an entire
exchange.

## NALO-001 — report cursor can outrun the correction report

- Severity: P2. Confidence: high. Classification: confirmed source defect with a
  cold reproducer.
- Disposition: accepted by the primary agent, corrected in the integration
  worktree, and independently verified. The corrected source SHA-256 is
  `380c28e0625531645feaf917b52f727fabc1d7a06694fe215eaf88401180f615`.
- Affected source at `d64879e`: `heart_correction_owner.jl` lines 620–624,
  653–656, 710–717 and 735–742; `heart_calibration_owner.jl` lines 661–663;
  `simulator.jl` lines 239–266.

### Evidence and mechanism

The native acquisition method commits acquisition cursor N after the exposure
completes. The enclosing correction `exchange!` subsequently waits for native
DM/VDM telemetry and command relay. Those waits may service lifecycle requests.
Only after `exchange!` returns does the outer loop advance `state.sequence` and
record the exchange and correction truth.

Pause followed by Resume during these waits is allowed by the bridge. Resume
calls `save_report!`, whose writer serializes the previous `state.sequence` and
`recorder.count`, but whose cursor publication reads the newer live acquisition
cursor. Failure cleanup has the same problem when an exchange fails after
exposure completion and before recording. Current acquisition cursor N is
truthful; identifying the saved report with N is not.

Observed cold fail-before: the unchanged production `save_report!` closure,
real bridge cursor implementation and a report sink preserving the real
writer's sequence/count fields produced report cursor 8 with saved sequence 7
and seven completed frames: **2 passed, 1 failed**. The sink is a stub; it does
not execute science or prove an installed timing scenario. Reachability is
established separately from the actual source ordering above.

Evidence:
`~/.cache/rtc-lifecycle-owner-review-20261006/report-cursor-before.jl` and
`report-cursor-before.log`. Julia 1.12.7, CPU 15.

### Adjudicated remediation and validation

Retain a complete four-component completed-record cursor independently of the
live acquisition cursor. Initialize it at successful Connect, advance it only
after both exchange recording and correction-truth recording succeed, and reset
it at the successful new-generation initialization boundary. Use this retained
cursor for normal and failure report publication. Advance the public report
cursor only after the report write succeeds. Status continues to expose the
actual live cursor independently.

`finish_window!` restores the zero figure and validates/archives telemetry; it
does not acquire another exposure, so it does not justify advancing the retained
exposure cursor. Required checks include initial zero, live cursor ahead of
recorded cursor, report write failure, reset generation, all four UInt64 fields,
and preservation of the recorded cursor through partial exchange failure.

Independent verification of the actual corrected `save_report!`,
`reset_effect!` and record/truth/update source blocks: the same expanded cold
fixture produced **14 passed, 4 failed** before correction and **18/18 passed**
after correction, with bounds checking enabled. It checks the original live-8 /
report-7 case, failed report publication, failure in either recording step,
advancement after both steps, reset-to-zero in a different generation, and exact
preservation of all four UInt64 fields including high-bit values. Scientific
recording, reset effects and report storage are controlled stubs; the production
ordering and publication blocks execute unchanged. Evidence in the same cache:
`report-cursor-boundaries.jl`, `report-cursor-boundaries-before.log` and
`report-cursor-boundaries-after.log`.

The fix leaves the live cursor unchanged. A fault after frame recording but
before truth recording can leave partial diagnostic data in the saved failure
report; its reported cursor conservatively covers only the last wholly recorded
exchange. This distinction is intentional and does not invent completed truth.

## Reviewed invariants

- Effects remain in the sole existing owner. Endpoint callbacks stage requests;
  bridge dispatch applies them outside the PipeWire loop lock. Correction's
  `in_effect` guard prevents nested lifecycle effect dispatch from its own
  service callbacks.
- Connect, Reset and Shutdown are deferred during accepted calibration actions.
  Pause changes admission; the action's existing deadline and next-reader
  inactivity interval remain unchanged. Lifecycle transport failure during an
  action is latched until the boundary. `OwnerServiceAbort` unwinds owned I/O
  without fabricating an action fault or changing held/restored evidence.
- Calibration Reset returns unsupported without altering the probe. Ordinary
  calibration Shutdown requires initial/unheld or released/restored/unheld
  action facts. Correction requires its retained restoration archive and no
  active native correction proof. A completed frame count alone does not
  authorize shutdown.
- Correction held and restored are independent. The d64879e change preserves
  source command ownership while a restored Connected session remains open;
  successful session closure removes that live ownership claim.
- Nested correction HEART status/reset/hold operations receive the accepted
  absolute deadline. Public successful completion rechecks ticket identity,
  controller presence and expiry. Late effects cannot produce a successful
  completion after expiry. This does not prove a hard bound on filesystem or
  dependency cleanup execution.
- Terminal success is published after owned listener/session cleanup and uses
  public exact-sequence core synchronization before endpoint withdrawal.
  Cleanup failure or deadline loss prevents a successful terminal claim.
- Generic endpoint retirement now passes `ticket.command` to the profile's
  failure encoder. The compatibility method delegates to existing three-argument
  encoders; calibration action failure retains the accepted run and serial,
  including high unsigned bits. It uses the completion namespace for accepted
  work and leaves admission rejection separate.

## Verification and remaining gates

Independent rerun of `deployment/hil/test_native_acquisition_lifecycle.jl`:
**12/12 passed**, CPU 15, private core. This covers deferred Reset, modeled
released facts after completion expiry, and warmed idle wake allocation. Log:
`~/.cache/rtc-lifecycle-owner-review-20261006/bridge.log`. The process reported
that precompilation completed with some dependency versions already loaded;
this is retained in the log, and the result remains a cold transport check.

Inspected root accepted-action retirement fixture and its final log:
`~/.cache/rtc-live-controls-20261005/calibration-action-retirement-root-final2-20261006.log`,
**17/17 passed**. Deadline and actual controller-removal cases retain the exact
accepted run/serial and terminal ticket without running an owner effect.

Actual selected scientific and HEART owners, exported package completeness,
private-core session linking, restoration and shutdown on installed Classic and
Copper packages remain primary-agent qualification gates. The action JSON
transport still belongs to issue #7; this review does not promote its migration.
