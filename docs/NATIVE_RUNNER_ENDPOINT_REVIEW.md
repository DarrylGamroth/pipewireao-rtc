# Native runner endpoint review

2026-10-05. Independent architecture and implementation review of the Phase B
endpoint in [the runner profile](NATIVE_RUNNER_CONTROL.md), under RTC-ARCH-024
and RTC-DEV-030. This artifact records the endpoint implementation review and focused CPU
qualification. Caller migration and scientific qualification remain separate.

## Scope and baseline

Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls`.
Branch: `work/native-control-planes-20261005`. Starting revision:
`03770074b590a73156c664ea0d4ea816b5853921`. The implementation owner reported a
clean starting tree. At first inspection, the expanded runner profile was
modified and `src/native_runner_result.rs` was being written. The reviewer owns
this artifact and the explicitly authorized diagnostic files
`src/native_runner_endpoint_tests.rs` and
`deployment/julia/test/native_runner_monitor.jl`. No production changes were
made by the reviewer.

The [request/typed-result prerequisite](NATIVE_RUNNER_CONTROL_REVIEW.md),
[common envelope](NATIVE_CONTROL_CODEC_REVIEW.md) and
[local synchronization correction](NATIVE_CONTROL_SYNC_REVIEW.md) are separate
completed increments. This review concerns actual runner ingress, retained
native results, registry lifetime correlation, admission, preparation and whole
owner deadlines. Production caller migration, installed science and GPU
campaigns are outside this review.

## NRE-001 — Duplicate precedence must respect the highest accepted token

Severity: Medium. Confidence: High. Evidence: selected contract and initial
mailbox source. Disposition: addressed in `Stage::stage`; source and the actual two-caller
fixture verify stale/collision behavior. The finer pending interleavings are
covered by mailbox unit tests, not remote concurrency qualification.

The runner profile permits matching duplicates of the accepted or last terminal
request, and also states that accepting a newer token makes all older tokens
stale. These rules require an explicit order. If terminal token N remains
retained while N+1 is pending, a duplicate of N must be stale, even though it
still matches the retained terminal record. Checking the terminal duplicate
before the highest accepted token would violate the selected migration rule.

Required implementation: compare against the highest accepted token before
duplicate replay. Equal-token duplicates must match the full controller
incarnation, operation and canonical payload. Changed remaining budget must
not extend the original deadline. A valid newer request advances the token at
acceptance, including when preparation or execution later fails. Busy, malformed
and other admission failures do not advance it. A different caller choosing
the same token receives independent rejection and cannot claim the completion.

Required validation: retain N, accept N+1, submit an exact duplicate of N while
N+1 is pending and after N+1 fails; both must be stale. Exercise same-token
pending/terminal duplicates, changed payload/operation/controller, and a rejected
newer request followed by the next admissible token.

The initial `src/native_runner_mailbox.rs` checks stale tokens before retained
duplicate matching, retains occupied identity after taking pending work, and
excludes budget from duplicate identity. `Stage::complete` clears only the exact
occupied request. Preparation integration must preserve the original descriptor
in `Accepted.command` and execute the prepared value separately, because the
descriptor participates in this completion identity.

## NRE-002 — Caller removal has an observation boundary

Severity: Medium. Confidence: High. Evidence: public registry notification and
serialized owner model. Disposition: contract and source clarification addressed;
concurrent-removal qualification remains distinct from normal removal evidence.

The initial integration wording says removal before dispatch produces a terminal
failure without effects. Registry and bound-node removal are asynchronous
notifications. Another connection can remove its marker after any local check
and before a lifecycle effect; a marker is not an atomic authorization lease.
The guarantee must identify removal already observed by the owner at its
admission, dispatch and publication checks. A sync barrier can order processed
notifications but cannot make a later remote removal atomic with the effect.

Required clarification and implementation: fence observed disappearance or
changed incarnation before dispatch and before reporting success. Preserve
unknown outcome for disappearance observed during/after effects and do not
claim rollback. State the local publication linearization point; successful
Filter publication does not prove receipt by a remote caller. Do not add an
authentication framework: this remains same-user private-core correlation.

Required validation: remove an actual marker while queued/preparing and observe
no effects; remove it during a downstream wait and retain truthful failure or
unknown outcome; check that a recycled global ID with another serial/instance
cannot satisfy the request. Distinguish observed notifications from an assumed
instantaneous view of another connection.

The revised profile states the observed-removal boundary explicitly. The
endpoint synchronizes and checks lifetime before dispatch, synchronizes after
execution, and checks again when constructing/publishing the terminal result.
Normal actual-marker removal and rejection of its former identity are exercised
by the two-connection fixture. Removal during an in-flight effect is not proved
by that normal-removal case.

## NRE-003 — Native Active property results admit impossible observations

Severity: Medium. Confidence: High. Evidence: inspected result codec, existing
owner predicate and fail-before/pass-after test. Disposition: addressed in the
result codec; owner integration remains subject to final review.

The initial `src/native_runner_result.rs::check_result` validates operation,
session lifecycle and status lifecycle, but does not validate the necessary
conditions for a `PropertiesSet` result with `active_adoption_observed = true`.
Both encoding and decoding consequently admit Active with a Ready lifecycle,
no observations, absent generations or unequal requested/active generations.

The existing `control::property_adoption_observed` predicate requires Running,
nonempty observations, and every observed active generation equal to its
requested generation, in addition to advancement from the pre-effect baseline.
The baseline is not carried in the completion, so the codec cannot establish
advancement independently. It can and should reject violations of the necessary
conditions represented in the result itself. This is not a change to adoption
semantics.

Required correction: enforce the represented necessary conditions in shared
`check_result`, used by both encoder and decoder. Preserve submitted results
with unknown observations. Required validation: valid Running/Active round-trip
and explicit rejection tests for each impossible Active case on encoding and
raw-envelope decoding. Owner integration must still establish baseline
advancement before constructing Active.

The result worker independently confirmed the predicate, and the primary agent
authorized correction. The reviewer inspected the shared guard: it first bounds
the row count, then requires Running, nonempty observations, present generations
and matching requested/active values for Active. Submitted observations remain
permitted when those conditions are absent.

Evidence under `~/.cache/rtc-live-controls-20261005`:
`native-runner-result-active-before.log` fails the new assertion because the
initial encoder accepts an impossible Active reply.
`native-runner-result-unit-final.log` passes all 11 result-codec test groups,
including both encode and raw-envelope decode rejection for five impossible
Active cases. The suite also checks all operations, scalar bits including NaNs,
unsigned counters, optional observations, exact 64 KiB capacity, malformed
records and error/completion distinction. Strict Clippy passes in
`native-runner-result-clippy-final.log`, with the existing dependency
future-incompatibility warning. Reviewed result source SHA-256:
`71339a957cb96ed38c8e7d18c985828cb721553c701b667af7aa654ded96b38e`.

## NRE-004 — Adapter destruction can restart cleanup after the outer budget

Severity: Medium. Confidence: High. Evidence: inspected integration and existing
cleanup/Drop paths, with native fail-before/pass-after. Disposition: addressed
for already-released local resources.

The initial integration wraps Stop and Unload in one five-second
`Runner::with_control_deadline` scope in `src/main.rs::run`. That scope ends
before the local Runner is destroyed. `LiveGraphAdapter::drop` then calls
`cleanup(None)` unconditionally. Cleanup establishes a fresh five-second local
scope and performs synchronization even when explicit Unload already emptied
the resource collections. Therefore the destructor can wait again after the
advertised cleanup budget was exhausted. This second wait is derived from
source; its complete process elapsed time has not yet been measured in this
review. The earlier sync prerequisite already measured an empty-adapter
cleanup waiting five seconds against a stopped daemon.

Required correction: retain the same remaining cleanup budget through
destruction, or make cleanup after a completed resource release idempotent
without new synchronization. Preserve cleanup on early failure paths that
still own resources. Required validation: terminate an endpoint against a
stopped private core and measure the complete process shutdown, including
destructors; confirm local resource release and normal healthy cleanup too.

The focused private-core fixture first completes explicit cleanup, then SIGSTOPs
its own daemon and destroys the adapter. The reviewer inspected
`native-runner-drop-before/rust.log`: the new assertion fails after
5.000192111 seconds in Drop. The corrected destructor calls cleanup only when
one of the six local resource collections remains populated: links, controlled
graphs, latest/hold nodes, SPA nodes, parameter publishers or modules. Explicit
cleanup drains every collection even when synchronization reports failure.
Partially initialized owners with remaining handles still receive cleanup.

The same fixture passes in `native-runner-drop-after/rust.log`, with elapsed
128,130 ns recorded in `native-runner-drop-after/elapsed-ns`. The Julia fixture
uses finite child termination and resumes only its own paused daemon. This
isolates removal of the second synchronization wait; it is not a measured
five-second bound for every possible populated-resource destructor/native call.

## NRE-005 — Parameter preparation suppresses required-object monitoring

Severity: Medium. Confidence: High. Evidence: inspected owner loop and Runner
monitor semantics. Disposition: addressed in source and focused native
monitor-fencing tests.

The initial `native_runner_endpoint::run` calls `poll_required_objects` only
when `current.is_none()`. A parameter request occupies `current` while file
preparation runs, for up to the capped 30-second request budget. During that
interval the owner pumps callbacks but does not dispatch required-object loss
or finite-source completion through the lifecycle. `Runner::poll_required_objects`
is the method that converts these observations into the existing serialized
events. The legacy worker preparation path leaves owner monitoring active.

Required correction: continue finite required-object monitoring while the
preparation worker is pending, with synchronization bounded by the remaining
accepted budget. If monitoring faults the session, fence the prepared result
and report truthful failure before any parameter effect. Preserve the sole
dispatcher; the worker must not acquire lifecycle ownership. Required validation:
hold a preparation result, make a required object fail or a finite source finish,
and demonstrate prompt serialized monitor handling without waiting for the file
worker or dispatching its late result. A deterministic CPU fixture is sufficient
for this ordering claim; it is not scientific qualification.

The corrected loop calls `monitor_required_objects` whenever the monitor is
due, including while `current` is populated, and before dispatching a prepared
result. The diagnostic test uses actual Runner/Endpoint objects and four held
external ndarray nodes. It stages an accepted descriptor directly with synthetic
controller labels, removes an actual required sink, and calls the same monitor
helper used by the owner loop. Both a preparation already held in `current` and
a descriptor still queued in `Stage.pending` produce Fault, a matching negative
terminal and release of the accepted slot. Calling the production
`dispatch_prepared_result` helper with the late original header and a Quit
sentinel does not dispatch, change lifecycle or overwrite the terminal. It clears
the remaining worker-busy slot.

`native-runner-monitor-proof-after/rust.log` and `queued_loss/rust.log` each
report one passing ignored Rust diagnostic test. The four-case parent fixture
reports 12/12 checks in `native-runner-monitor-proof-after.log`. The synthetic
admission bypasses registry verification deliberately; the separate two-caller
fixture covers actual marker correlation. No filesystem worker was blocked, and
finite-source completion was not injected in this focused loss test.

## NRE-006 — Due monitoring can ignore an already accepted queued deadline

Severity: Medium. Confidence: High. Evidence: inspected revised loop ordering.
Disposition: addressed in source and focused fail-before/pass-after CPU tests.

After moving due monitoring ahead of prepared-result processing, the loop may
have `Stage.pending = Some(accepted)` from the preceding callback iteration
while its separate preparation `current` remains None. The monitor helper
selects a five-second standalone deadline from `current` alone and runs before
`take_pending`. It therefore ignores the deadline of an already accepted queued
request. A monitor failure also only finishes `current`, leaving that queued
accepted request to owner disappearance rather than its available terminal path.

Required correction: include any accepted queued request in monitor deadline
selection and failure fencing. Also adjudicate requests admitted reentrantly
during an existing maintenance sync, whose deadline cannot retroactively
shorten an already selected wait without an explicit mechanism. Preserve finite
maintenance and avoid introducing a second dispatcher. Required validation:
stage a short-budget request before a due stalled-core monitor and demonstrate
that monitoring does not restart five seconds; exercise the accepted pending
failure path. The pre-effect request timeout fixture does not exercise this
ordering.

The correction snapshots the current or queued accepted deadline while enabling
a scoped maintenance flag. New reentrant requests receive Busy without token
advancement during maintenance; stale and exact-duplicate handling retain their
existing precedence. The flag does not hold the mailbox mutex during effects.
The diagnostic unit `maintenance_rejects_new_admission_without_changing_accepted_identity`
checks these boundaries.

Simply clamping `poll_required_objects` was insufficient: expiry during sampling
was converted into RequiredObjectFailed and faulted an otherwise healthy
session. The fail-before child log
`native-runner-queued-monitor-before/queued_budget/rust.log` records the required
Ready assertion failing with actual Fault and a synchronization-deadline
scientific diagnostic. The parent fixture's later timeout is secondary to that
explicit assertion failure.

The final correction separates sampling from
`Runner::apply_required_object_observation`. Existing polling still samples and
applies through the sole dispatcher; both entry points retain Ready/Running
eligibility. The native monitor discards an observation whose accepted sampling
budget expired, finishes that request with ETIMEDOUT and preserves the session
state. A subsequent independent health check can still observe genuine loss.
This does not classify a short control budget as evidence of scientific failure.
The owner loop also takes an already expired or removed queued request under
the mailbox lock and finishes it outside that lock before due monitoring. The
reviewer inspected this subsequent loop-level refinement; the four diagnostic
cases directly call the monitor helper and do not independently exercise that
earlier loop branch.

The same queued-budget test now passes in
`native-runner-monitor-proof-after/queued_budget/rust.log`: 250,108,073 ns,
Ready retained, exact negative terminal, and accepted slot released. The direct
accepted SessionStart case in `budget/rust.log` passes at 250,013,976 ns without
passing its pre-effect synchronization. These are CPU functional timing checks,
not latency benchmarks. The daemon is fixture-owned and SIGSTOPped; negative
publication is local and nonwaiting, with no claim of remote timeout receipt.
These cases do not qualify expiry partway through a multistage mutation.

## Architecture conditions for implementation review

- Reuse the adapter's actual Core and main loop. The public SDK exposes local
  NodeInfo listeners and Filter construction from a Core. Bind candidate Nodes
  and inspect NodeInfo metadata; do not assume custom properties occur in
  registry global announcements. The inactive Filter has no ports or scientific
  processing callback.
- Native mode requires the selected explicit private absolute remote and held
  startup. Reject conflicting native, legacy socket and console ingress options.
  An advertised capability is a bootstrap snapshot; a fresh status still needs
  a newly accepted matching query.
- Keep at most 32 candidate bindings, including candidates awaiting NodeInfo.
  Specify what frees silent/invalid candidates and how a marker announced at
  capacity can become eligible later. Do not imply automatic promotion of a
  discarded announcement unless a bounded mechanism implements it. A finite
  client discovery failure is preferable to an unbounded deferred-marker queue.
- Retain one accepted request through preparation, effects and terminal
  publication. Reentrant callbacks during downstream synchronization must see
  that occupied slot. Keep the independent rejection and prior terminal result
  intact on busy/malformed/stale input. Copy only bounded data and execute no
  blocking filesystem or lifecycle work in callbacks.
- A bounded preparation worker owns one job and one result slot. A timed-out
  preparation continues occupying its worker slot until its result is drained;
  it cannot overwrite or dispatch through a newer request. Other controls may
  proceed once the abandoned request has a terminal result. Do not join blocked
  filesystem I/O at endpoint cleanup; worker exit remains tied to the process.
- Cap the accepted owner budget at 30 seconds and establish one absolute
  deadline. Check it before effects and publication, and propagate it through
  existing synchronization. This does not preempt arbitrary filesystem or
  callback execution and is not a hard real-time execution bound.
- Expiration must still permit a bounded, nonwaiting negative terminal
  publication attempt. Requiring positive remaining operation time for every
  publication would strand an expired accepted slot. Success must satisfy the
  accepted deadline; timeout notification must not extend that deadline or
  claim caller receipt. Define endpoint fault/exit behavior if publication
  itself fails, and recheck lifetime/deadline after success encoding.
- Establish the separate five-second cleanup scope across Stop and Unload,
  including nested synchronization. The previous main path invokes these
  sequentially, so independent fresh local budgets would not implement one
  cleanup budget. Release local handles on failure without claiming remote
  removal while the daemon is unavailable.
- Preflight worst-case mutation completion size before preparation/effects.
  Query oversize must reject truthfully after bounded result encoding, and error
  diagnostics need a bounded fallback. Preserve signed generations, unsigned
  counter bits, optional observations and causal outcome distinctions.
- Native result encoding must validate operation, lifecycle, outcome and detail
  invariants, not merely the common envelope. Initial sentinel records cannot
  satisfy a fresh operation. Preserve raw diagnostic Float/Double bits while
  maintaining finite request values.

## Verification status

The reviewed endpoint architecture preserves the single lifecycle dispatcher,
bounded request/preparation slots, actual public NodeInfo lifetime correlation
and typed native transport. No confirmed blocker remains for this reviewed
endpoint boundary after the recorded corrections. Final build/regression and
source replay evidence are maintained by the implementation owner in
[NATIVE_RUNNER_ENDPOINT_VALIDATION.md](NATIVE_RUNNER_ENDPOINT_VALIDATION.md).

The final two-actual-caller replay passes 143 checks in
`native-runner-endpoint-sealed.log` using binary SHA-256
`71549afe3ca2f235c1264dafc0f18602936de861ad5e549cbc1b70c7c330fb4d`.
The final monitor replay passes 12 parent checks in
`native-runner-monitor-sealed.log`. The full Rust workspace run in
`native-runner-final-build.log` has 184 passed, zero failed and nine ignored;
formatting and strict all-target Clippy pass, with the existing
proc-macro-error2 future-incompatibility warning. Ignored tests are not promoted
to workspace coverage; separately selected native diagnostics are identified
above. The focused four-case monitor
fixture passes 12 parent checks and four separately selected ignored Rust tests
in `native-runner-monitor-proof-after.log` and its evidence directory. Earlier
monitor evidence in `native-runner-monitor-proof-final.log` covered only two
cases and predates the queued-budget correction; it must not be used as proof
of that later correction.

Reviewed source SHA-256 at this pass (subsequent production changes require
reconciliation):

- `src/native_runner_endpoint.rs`:
  `52b6b79d21e99ec878f9ac5ce2f2dfd37059738ed7ca201f00631055ebe02d2e`.
- `src/runner.rs`:
  `9c35184edb041ebfac6ed4d6cc20c52a336b977cafcf248126adb05ae09e2077`.

Normal marker removal is qualified; atomic remote lifetime/effect ordering,
blocked filesystem cancellation, populated-resource worst-case shutdown,
installed science, physical behavior and allocation-free frame behavior are not
claimed. The endpoint and synthetic diagnostic tests do not themselves migrate
production Julia supervisor, calibration or HEART callers.
