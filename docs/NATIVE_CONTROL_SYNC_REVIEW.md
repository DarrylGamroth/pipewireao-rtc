# Native synchronization deadline review

2026-10-05. Independent review of the narrow Rust callback-synchronization
prerequisite identified as NCMR-002 in the
[migration review](NATIVE_CONTROL_MIGRATION_REVIEW.md). The scoped deadline
implementation and native pass-after evidence address the local synchronization
defect. No confirmed blocker remains for committing this prerequisite. Whole
request deadlines, populated-resource cleanup and scientific qualification remain
separate integration obligations.

## Scope and baseline

RTC source baseline: `74099a2861ed7d60789a38c0f3ad4121b029bf48`, branch
`work/native-control-planes-20261005`, worktree
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls`.
The initial review began alongside the primary task's uncommitted codec work.
Final review is against prerequisite changes on
`7724ba8b10f060c9f87512d01977b4762040039b`, after the shared codec increment and
main integration. The implementation owner changed `src/live.rs` and diagnostic
fixtures; this reviewer owns only this review artifact.

This increment bounds callback synchronization and propagates local observation
deadlines into nested sync waits. It does not implement the production native
owner endpoint or a complete absolute budget around each public lifecycle
request. It does not change scientific scheduling or callbacks. Multiple
independent effect stages may still have separate budgets until the subsequent
owner integration supplies an enclosing request deadline.

## NCMS-001 — Inner sync ignores outer deadlines

Severity: High. Confidence: High. Evidence: observed source and reproduced
stalled-core behavior. Disposition: addressed for local callback synchronization,
with inspected implementation and native fail-before/pass-after evidence.

Baseline `src/live.rs:3183` waits for one Core sync sequence in
`main_loop.run()`. It has no timeout/error exit while waiting; the completion
callback calls `main_loop.quit()`. Reset, run-control, property adoption,
node/link observation, discard polling, dependency monitoring and cleanup call
this helper. Their surrounding five-second or 500 ms observation loops cannot
interrupt that inner wait. Errors are examined only after matching completion.

The primary agent's isolated-core fail-before experiment is recorded under
`~/.cache/rtc-live-controls-20261005` in
`native-sync-stall-before.log`, `native-sync-stall-before-owner.log`,
`native-sync-stall-before.jl` and `native-sync-stall-probe.rs`. The reviewer read
the logs and probe source. After a successful adapter connection, the fixture
SIGSTOPs only its own private daemon and calls `LiveGraphAdapter::progress()`.
After six seconds, the probe has produced no result and remains running. It
returns `Ok(())` only after SIGCONT, with elapsed time 6.002840681 s. Four fixture
assertions pass. This demonstrates an unbounded sync relative to the intended
finite control budget; it does not measure scientific latency.

Required correction: use finite loop iteration until matching Core done,
observed error or the effective absolute deadline. Give standalone sync a
five-second maximum and propagate earlier local deadlines. Timeout reports
unknown operation outcome if effects may already have been submitted. It does
not assert cancellation, rollback or remote resource removal.

## Design conditions for implementation review

- The private guard owns an `Rc<Cell<Option<Instant>>>`, stores the previous
  value, clamps its deadline to the earlier enclosing value and restores the
  previous value in Drop. It must not retain a borrow of the adapter that blocks
  ordinary mutable operations. Guards remain lexically nested on the owner
  thread; no public mutable deadline setter or cross-thread propagation is added.
- Establish a local guard before the first sync/sample/effect belonging to that
  local operation. In particular, baseline reset/run helpers perform initial
  synchronization before creating their old deadline, and discard quiescence
  samples before creating its old deadline. These waits must not escape the
  selected local budget.
- `wait_for_callbacks` must clamp its supplied sample deadline to the enclosing
  deadline too. A five-millisecond observation cadence does not grant five more
  milliseconds after a parent expires. Finite iterate calls must use the
  remaining duration and preserve interruption/error handling.
- Check known Core errors promptly; do not wait for done after an error. Check
  deadline/error after dispatch as well as before it, before accepting success.
  A done callback observed after expiration must not convert a timed-out wait
  into success. Retain exact Core ID and sequence correlation, and remove the
  inner done callback's `main_loop.quit()` side effect.
- Guard restoration must survive normal return, early error and unwind. A
  failed operation must not leave the next unrelated operation with a stale
  expired deadline. An inner guard must never lengthen its outer budget.
- Cleanup gets its own finite budget, capped by an existing parent. It still
  drops local listeners/proxies/modules after sync expiry and returns the first
  relevant error. Clearing local ownership/status is not evidence of remote
  deletion while the daemon is paused or disconnected.
- `progress_until` may provide an explicit diagnostic deadline beside the
  existing hidden `progress`; keep it documented as an observation helper,
  without representing it as a production per-request budget API.

This controls how long synchronization waits for native progress. It does not
preempt arbitrary callback execution, filesystem operations, native destruction
or scientific work. The shared owner thread must continue to exclude blocking
effects from callbacks. The change must not claim a hard maximum execution time
from finite polling alone.

## Final implementation review

Reviewed source SHA-256:

| File | SHA-256 |
| --- | --- |
| `src/live.rs` | `cf990d47bfc824cb85911025f4a76f20d06b072fe06547532630bebfce128747` |
| `examples/native_sync_deadline_proof.rs` | `b1f4758ff1c8b0412f295c48f14e5776e7641d069e9777c212d558e945d158b3` |
| `deployment/julia/test/native_sync_deadline_proof.jl` | `36119148be7514a1eda019532175b85fb07493cd4314abf691a515b6500803c1` |
| `deployment/julia/test/native_control_private_core.jl` | `1ef02e594e76daa702601b0de53bf1ff14b06084d5f726eb26bfb860e549ca93` |

Finalization removed one surplus newline at EOF from the reviewed helper
(`7a48eec02c229dc425e8cb2f4b000a8fb9434643f9c171c3e9bf1c154077678f`).
The primary agent verified that this single byte is the entire source difference;
the helper implementation and recorded behavioral results are unchanged.

The diff is confined to deadline state/guard, hidden `progress_until`, the sync
helper, existing local observation scopes, three focused guard tests and one
explicitly invoked private-core test. Native test setup/teardown was extracted
from the envelope fixture for reuse, with the daemon passed to fixture-owned
signal control. The envelope callback and assertion behavior remains unchanged.

All pre-existing production local-deadline loops establish a guard: numerical
reset, property update, run-state request, active-link observation, owned-node
removal, owned-node discovery, external-node discovery, discarded-buffer progress,
discard quiescence and link-creation observation. Cleanup additionally shares a
single five-second scope across its nested waits. Reset/run initial synchronization
and discard quiescence's initial sample now belong to their existing local budget.

The helper checks entry expiry before submitting sync. Each dispatch loop consumes
observed errors, checks expiry, then accepts exact done; thus a late done cannot
win over expiry and an observed error does not require done to arrive. The scoped
guard removes the inner run/quit interaction and restores the previous deadline
on exit. `wait_for_callbacks` clamps to the inherited deadline. Cleanup retains
its first error and still reaches the local resource-release statements after
sync failures.

The link-creation budget retains its existing boundary after issuing creation;
the reset operation's preceding latest/hold pause can have a separate sync budget.
These are consistent with the selected local-wait scope and must not be presented
as a five-second maximum for the entire lifecycle command.

`native-sync-deadline-unit.log` records **3/3 passing tests** for longer-inner
clamping, shorter-inner restoration and unwind restoration. The reviewer read
this result; the implementation owner executed it. `git diff --check` passes for
`src/live.rs`. The unchanged dependency warning for `proc-macro-error2` 2.0.1
appears in the test log. These checks do not replace the stalled-core experiment.

## NCMS-002 — Startup failure initially lost the fixture child handle

Severity: Low. Confidence: High. Evidence: observed fixture control flow.
Disposition: corrected and source-reviewed; not a production-adapter defect.

The initial `run_sync_proof` spawned a child, then awaited READY before returning
its handle to the caller. Its catch logged and rethrew without stopping the child,
so a startup failure happened before the caller's cleanup scope owned that child.
The primary agent added `stop_proof_child!` in the catch before logging/rethrow.
The existing bounded helper performs exit observation and TERM/KILL escalation.
The correction does not change the successful fixture path. No startup-failure
injection result is claimed.

## Completed local synchronization evidence

The reviewer independently inspected the sources and these recorded results;
the primary and validation agents executed them. All signal operations target
fixture-owned private daemons. No ordinary PipeWire session, scientific graph,
GPU or hardware was used.

`native-sync-deadline-proof.log` records **34/34 Julia assertions** and an
explicit **1/1 passing Rust private-core test**. Observations include:

| Observation | Result |
| --- | --- |
| Already-expired explicit deadline | Error before submission in 2.826 µs; source branch precedes Core sync |
| 250 ms explicit wait on stopped daemon | Error at 250.012249 ms, completion unknown |
| Default wait on stopped daemon | Error at 5.000015620 s, before daemon resumption |
| Existing external-node discovery path | Error at 500.021376 ms, demonstrating the inherited 500 ms scope |
| Cleanup of an empty adapter on stopped daemon | Error at 5.000023115 s; later sync waits do not each restart five seconds |
| Stale done callbacks during a new sync | Exactly two old Core done events observed; new 250 ms sync still times out at 250.730968 ms |
| Healthy synchronization after resumption | Fresh sync succeeds; guard restoration permits later work |
| Forced daemon termination | Native connection error returned in 3.567970 ms, without waiting for timeout |

The private Rust test adds its own Core done-event listener and asserts the two
old callbacks were actually dispatched. This distinguishes rejected stale replies
from a test in which no stale replies arrived. Its subsequent fresh sync succeeds
only after the fixture resumes the daemon. Short fixture sleeps allow old replies
to queue; they do not by themselves establish successful completion.

The five-second default observation has a declared fixture acceptance interval
of 4.9–5.5 seconds. Shorter waits and cleanup have broader explicit host-scheduling
tolerances in the fixture. Reported values are CPU software observations, not
hard deadlines under arbitrary scheduling or callback execution.

`native-control-envelope-helper-compat.log` records **42/42** after shared helper
extraction. `native-sync-deadline-rust-regression-final.log` records **147 passed,
zero failed and four ignored**. One of those ignored tests is explicitly exercised
by the native synchronization fixture above; the other three are existing
scientific/private-core fixture gates. The older regression log has three ignored
tests and is not the final suite identity. Final formatting and strict focused
Clippy logs pass; the existing `proc-macro-error2` 2.0.1 future-compatibility warning
remains unchanged. Evidence is under `~/.cache/rtc-live-controls-20261005`.

## Remaining limits and commit assessment

Cleanup testing uses an adapter with no scientific nodes, links or modules.
Source review confirms local release statements remain reachable after sync
failure, but populated-resource destruction timing and daemon-side removal are
not measured. This prerequisite does not prove those resources were removed
while a daemon was paused. It does not preempt blocking destructors/callbacks or
bound filesystem/configuration preparation.

The planned broader lifecycle/scientific regressions were not run for this narrow
prerequisite. The ordinary Rust suite and targeted private-core failure tests
support the synchronization correction; installed scientific and allocation gates
remain separate. There is still no common absolute budget enclosing every complete
production owner request, and the production native endpoint/JSON retirement has
not been implemented by this change.

No confirmed blocker remains for the scoped prerequisite commit. No production
source or workload was modified or run by this reviewer. Review artifact checks
cover source hashes, local links, finding identities, trailing whitespace and
the final newline.
