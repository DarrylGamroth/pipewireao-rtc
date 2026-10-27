# Event-driven calibration review — 2026-10-26

Status: independent review found no remaining blocking defects in the reviewed
change. This is software evidence, without physical-device or deadline
qualification.

Reviewed source: `b4eab3ad25021dc98ae8c40c79f4926e0ad8ccbf`, branch
`codex/event-calibration`, worktree
`/home/dgamroth/workspaces/codex/worktrees/rtc-event-calibration-20261026`.
The implementation and test changes were already present or evolving during
review. The reviewer changed only this record.

## Scope and conclusions

Reviewed `src/calibration_acquisition.jl`, `src/calibration_procedure.jl`,
`src/native/native_control_client.jl`,
`src/native/native_calibration_action_client.jl`,
`test/test_calibration_procedure.jl`, `test/native_control_endpoint.jl`, and the
test-selector and acquisition-guide changes. Existing acquisition, CLI and
native-client tests were inspected for compatibility coverage. The affected
authority is RTC-DEV-029's correlated completion, ownership, deadline and
restoration contract, together with RTC-DEV-030's native transport bounds.

- **Observed in source:** the procedure snapshots and preflights its plan,
  retains one pending command, and checks run, serial and operation before
  advancing. Invalid correlation faults without another submission.
- **Observed in source:** known action failures can request one restoration
  and release sequence. Unknown expiration or transport outcomes stop further
  submissions. Cancellation does not overlap an in-flight command; cancellation
  raised by an online consumer is checked before another probe is issued.
- **Observed in source:** response evidence is causally validated before the
  consumer runs. Consumer and retained-receipt storage use separate snapshots;
  failed runs expose no accepted result batches. The existing finite plan and
  retained-payload limits remain in force.
- **Observed in source:** callbacks publish bounded observations and notify an
  `AsyncCondition`. The default calibration path uses native events and one
  deadline timer; explicitly supplied supervision hooks retain periodic checks.
  Julia 1.13.2's `AsyncCondition` implementation latches notification state, so
  notification between predicate inspection and `wait` is retained.
- **Observed in source:** `_exchange!` enters a concrete action specialization
  before starting the endpoint budget, then passes that absolute deadline to
  the native exchange. The procedure API still exposes an explicit deadline
  for external event-loop adapters.

## Findings and disposition

No open findings.

**ECA-01 — Wakeup-handle lifetime concern.** Severity: medium if unprotected;
confidence: high in the current protection; disposition: addressed during
implementation. A closed timer handle does not itself join its callback task,
so a queued timer callback must tolerate notification after client closure.
The final implementation holds `wakeup_lock` across both `isopen` plus
`uv_async_send` and condition closure. Native callback resources and their
thread loop close before the condition. The new private-core test explicitly
calls `wake!` after closure. This concern was derived from source inspection;
the reviewer did not reproduce a use-after-close failure in the earlier code.

## Validation and limits

Independently ran `julia --startup-file=no --project=.
test/test_calibration_procedure.jl` under Julia 1.13.2: initially 45 assertions
passed, covering a linear sensor oracle, online calculation/replay parity,
correlation, timeout/cancellation boundaries, invalid evidence and consumer
failure recovery. The final selector was rerun after the added consumer-driven
cancellation checks: all 47 assertions passed (16 online/replay, 17 correlation
and cancellation, 14 invalid-evidence/consumer recovery). `git diff --check`
passed during review.

The implementer separately reports passing acquisition/CLI regression coverage
(234 assertions), action-client tests (47), control-client tests (23), installer
tests (11), and the existing private-core calibration endpoint tests (17).
Those counts are attributed evidence, not independent executions by this
reviewer. The final private-core native-control selector remains the
implementer's integration gate.

No actual instrument campaign, physical settling, hardware ownership behavior,
worst-case callback latency, allocation budget, or deadline distribution was
qualified. Online consumers remain responsible for bounded computation or an
explicitly bounded numerical-worker handoff. The one-owner interaction protocol
does not establish multi-WFS or multi-corrector coordination.
