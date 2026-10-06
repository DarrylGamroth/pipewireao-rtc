# Native runner maintenance and serialized Status admission

Date: 2026-10-06. Independent read-only source review of clean RTC source
`367c26fba759062a27fb3f7fa4e48917ce6798ca` in
`pipewireao-rtc-native-controls`. Artifact worktree:
`rtc-bootstrap-allocation-review`, at `3bd6117`. No production edits, build,
new native-core experiment or SCI execution in this initial pass.

## Observed failure

Retained `~/.cache/rtc-native-final-deployment-20261006/`
`gui-hil-service-classic-fgn-v3/result.json` records `success=false` and:

```text
native runner Status failed (result=-16, lifecycle=Running,
instance=2069334779930001, token=95, operation=3):
request: runner control slot is busy
```

The failed cleanup result is also retained. This establishes a correlated busy
rejection, not a scientific, CPU-placement, GC or source-backend failure. The
diagnostic does not separately report occupied-slot versus maintenance cause.

## RUNNER-MAINT-R001 — Monitoring rejects a sole fresh request as busy

**Severity:** high for sustained public control availability. **Confidence:**
high for the source mechanism; actual token-95 branch attribution is derived
from the inspected route, not directly traced. **Affected:**
`src/native_runner_mailbox.rs:203`,
`src/native_runner_endpoint.rs:741` and `:926`, and
`src/live.rs:3053` / `:3380` / `:3409`.

The runner invokes required-object monitoring every 100 ms. It sets
`Stage.maintenance=true` for the complete check. For external objects,
`check_external_object_contracts` performs a core roundtrip, then enumerates
and synchronizes each required port's format. Those waits iterate the same
main loop that dispatches the native filter's request callback. During that
iteration `Stage.stage` rejects a fresh request with -EBUSY whenever maintenance
is true, including when both pending and occupied are empty.

This behavior already has a deterministic source fixture:
`src/native_runner_endpoint_tests.rs:290`,
`maintenance_rejects_new_admission_without_changing_accepted_identity`.
It explicitly checks Status rejection with no accepted work, unchanged
last-token zero and empty pending/occupied. The test encodes the present design;
it is not evidence that ordinary serialized caller availability is satisfied.
It was inspected, not rerun in this review.

The observed GUI path does not require a concurrent runner client to reach
this rejection. GUI calls target the public supervisor. `serve_control` guards
against reentry with `dispatching`, uses one runner client, and issues its
before/operation/after requests serially. A public Status invokes one fresh
runner Status. The supervisor's ordinary main poll does not issue a separate
background runner request; `observe_boundary!` handles only optional-observer
failure. The native Julia client additionally guards its request with a lock
and `active` flag and only returns a matching rejection or completion.

An otherwise ordinary read-only Status rejection becomes a fatal supervisor
`control.outcome` failure in `supervisor_snapshot` / `serve_control`. Repeating
the identical unknown operation or changing scientific timing is not a sound
repair for this maintenance admission policy.

**Proposed direction for primary adjudication:** retain bounded single-slot
admission and one effect dispatcher while permitting a sole request received
during maintenance to wait within its own immutable admission deadline. A
queued request must not reset the monitor budget, evade controller-removal
checks, or execute before required-object failure is fenced. If maintenance is
made incremental instead, preserve the same guarantees. Do not merely delete
the busy check without analyzing nested waits and deadline inheritance.

**Required validation:** deterministic maintenance/request interleaving with
empty slot; second concurrent admission still rejected; no effect while
monitoring; original deadline and controller removal honored; required-object
loss still completes/fences queued and prepared work; expired monitoring does
not incorrectly become a scientific object fault. Then a fresh installed
serialized-Status service cohort, with failed v3 preserved.

**Disposition:** mechanism reported immediately to primary. No production
remediation applied by reviewer. Exact dynamic branch at token 95 remains
untraced; there is no evidence supporting a CPU/GC/backend explanation.

## Alternative hypothesis: completion publication precedes slot retirement

`Endpoint.finish` publishes terminal parameters, then calls `Stage.complete`.
This ordering alone does not establish a request race. The selected Rust SDK
`f2d8689` Filter wrapper calls `pw_filter_update_params` directly. The inspected
local native implementation updates parameters and emits node info without an
explicit main-loop iteration. Incoming request callbacks use that same local
main loop. The review found no demonstrated point for a remote request callback
to run between these two operations, unlike the explicit iterations inside
monitoring. Therefore no terminal/slot reordering is recommended from this
hypothesis. A reentrant native callback trace would be needed before promoting
it to a confirmed defect.

This artifact records source concurrency analysis and existing retained
integration evidence. It does not claim a new interleaving experiment or a
successful service qualification.

## Bounded admission design adjudication

Primary accepted the source mechanism and proposed allowing a request into the
existing single pending slot during maintenance, with dispatch suppressed until
monitoring returns. Independent design review accepts the ownership model:
nested callbacks only stage/validate owned request data, while the sole Runner
dispatcher remains outside the nested monitor. Existing occupied, controller,
token and Parameter-worker guards must remain. Required-object failure takes
and negatively completes current or pending work before continuation; subsequent
dispatch checks expiration and live controller identity again. Dirty capability
state is covered by terminal publication or the next normal publication tick.

### RUNNER-MAINT-R002 — Entry-only deadline snapshot misses a new queued request

**Severity:** high for the proposed liveness guarantee. **Confidence:** high.
**Classification:** derived from existing source control flow; no new runtime
experiment. **Affected:** proposed maintenance admission change and existing
`monitor_required_objects` / `LiveGraphAdapter` wait scopes.

The current monitor captures `request_deadline` only before entering its nested
callbacks. If initially idle, it chooses a five-second maintenance deadline.
A new 250 ms request admitted during those callbacks would be absent from the
snapshot. With a stalled core the monitor could continue for five seconds;
later dispatch checks prevent expired effects, but do not preserve the existing
request-bounded monitor liveness. The existing queued-budget fixture admits
before monitor entry and does not cover this new interleaving.

Simply shortening the shared callback-deadline Cell is also insufficient by
itself: `roundtrip_until` snapshots a local deadline once, while its calls to
`wait_for_callbacks` ignore a false return. A dynamically shortened deadline
could stop each wait without ending the outer loop, causing it to spin until
the older local deadline. Deadline changes must be re-read and acted on through
the nested wait loops, or supplied through an equivalent explicitly checked
scope. Do not introduce a second effect dispatcher.

**Required validation:** admit a short-budget request after monitoring has
started; stall or delay synchronization; require bounded timeout publication,
unchanged original admission deadline, no dispatched effects, no busy-spin and
no false required-object fault. Preserve the existing queued-before-monitor,
required-loss, controller-removal and true second-request-busy checks.
**Disposition:** reported before production remediation; primary owns the
minimal design selection. A post-monitor deadline re-read alone establishes
effect safety, not the already-blocked monitor's liveness bound.

## Initial concrete remediation review

The primary supplied an uncommitted four-file repair on RTC `635990f`:
one pending request is admitted during monitoring; production callback admission
shortens an owner-thread deadline Cell; roundtrip waits re-read the cap and act
on false wait returns; monitoring re-reads pending deadline before applying its
observation. Original duplicate/occupied/controller/worker guards and terminal
publication order remain. This addresses the identified entry-snapshot and
ignored-wait problems, subject to the nested-scope issue below. No reviewer
build or test execution accompanied this source pass.

### RUNNER-MAINT-R003 — Nested lexical minimum can hide a callback deadline

**Severity:** high for the proposed deadline guarantee. **Confidence:** high.
**Classification:** derived directly from the proposed Cell transitions;
not an observed installed failure. **Affected:** draft `DeadlineGuard::drop`
and `control_deadline_limiter` in `src/live.rs`.

The initial repair detects a callback reduction only when the current deadline
is earlier than the deadline installed by that lexical guard. Consider an outer
five-second scope, a nested 100 ms lexical scope, and a newly admitted request
whose deadline is 250 ms. The limiter stores `min(100 ms,250 ms)`, leaving the
Cell unchanged. Inner Drop sees no reduction and restores the outer five-second
deadline, losing the admitted request's 250 ms cap. Equal callback/inner
deadlines have the same ambiguity. The minimum alone does not retain enough
information to distinguish lexical limits from callback admission limits.

**Proposed remediation:** retain callback/admission cap separately, or retain
an equivalent requested deadline and change identity, so a cap hidden by an
earlier lexical deadline survives restoration to its parent. Clear the
admission cap when the outermost operation scope ends; it must not leak into
later unrelated operations. **Required validation:** hidden and equal callback
caps, tighter callback cap, ordinary lexical restoration, unwind/outermost
cleanup, and no cap changes for rejected or duplicate admissions. Preserve the
actual newly-arriving-during-blocked-monitor timeout fixture.
**Disposition:** reported to primary immediately during precommit review;
source remediation remains primary-owned and unaccepted until this ambiguity
is addressed.

### Revised separate-limit design: source acceptance

The next primary draft replaces the ambiguous minimum with `ControlDeadline`
containing independent `scope` and `admission` fields, shared through
`Arc<Mutex<_>>` to satisfy the actual native filter listener's Send bound.
The effective deadline is their minimum. Admission updates its own monotone
cap only while a lexical scope is active. An inner guard restores its parent's
lexical state while carrying the admission cap; the outermost guard restores
the prior inactive state. Consequently an admission cap hidden by a shorter
inner scope is preserved. Source review accepts this correction of R003.

The inspected test matrix covers inner 100/250/500 ms scopes with a 250 ms
admission cap, ordinary lexical restoration, inactive admission, inability to
extend a cap, and scope cleanup. An additional admission-before-unwind followed
by a fresh unrelated scope is recommended to make the lifetime invariant
explicit; the inspected outermost Drop already implements it.

Lock ordering was reviewed: production request staging takes Stage then briefly
takes the deadline mutex. Deadline reads/restoration release their lock before
native waiting or callback dispatch, and no inverse held-lock path was found.
The production callback still only stages data and adjusts the cap; it performs
no Runner effect. These locks are in cold control paths, not scientific frame
callbacks.

Every production `wait_for_callbacks` call site in `src/live.rs` was checked.
They handle false by exiting/breaking or subsequently enter a bounded roundtrip.
The former ignored-false roundtrip now exits on false and re-reads the effective
deadline on each loop. No remaining ignored-false spin was identified. The
existing maximum five-millisecond callback-wait quantum remains; this source
review is not a hard execution-time measurement.

**Disposition:** revised source design accepted, with actual delayed admission
inside an already-running monitor and retained regression evidence still
required before final remediation verification. This is a review of the dirty
primary source, not an assertion about a yet-uncommitted final hash. No build,
test rerun or SCI was performed by the reviewer.

## Final independent verification: d92128a

Final clean production source
`d92128a06ed1e3a0f26ea35582819ab90dbc94a5` was independently inspected, including
the timer-arrival fixture and the final scope/admission tests. No additional
confirmed defect was found in this bounded review.

| Finding | Final disposition |
| --- | --- |
| RUNNER-MAINT-R001 | Corrected: one request is admitted during maintenance; true occupied-slot rejection and identity/duplicate/worker guards remain. Same admission assertion fails before (`Rejected`, expected `Accepted`) and passes after. |
| RUNNER-MAINT-R002 | Corrected: production callback shortens the active wait, nested roundtrips observe it, and monitor rechecks newly pending work before applying observations. Actual delayed-admission fixture verifies the bound and absence of command effects. |
| RUNNER-MAINT-R003 | Corrected: independent scope/admission state preserves hidden and equal admission caps; tests cover restoration, unwind and a fresh unrelated scope. |

The delayed fixture creates a real private core, stops that owned daemon, and
enters monitoring with no admitted request. A timer on the same owner loop fires
after 40 ms and calls the production `stage_request` helper with a 250 ms
SessionStart budget. The callback asserts maintenance is active. The final log
records **290,510,021 ns** elapsed from monitor entry, correlated local
ETIMEDOUT, Ready lifecycle, no SessionStart effects, no occupied/pending slot
and last-token one. This distinguishes the five-second entry-budget problem
from the required admission deadline. It uses synthetic controller admission;
no remote timeout observation is claimed while the daemon is stopped.

Independently read final evidence confirms all five actual private-core monitor
fixtures and 15 Julia assertions: pending-preparation loss, queued loss,
accepted-request budget, queued-before-monitor budget and delayed-arrival
budget. The Rust workspace log totals 198 passing tests; live cases ignored by
that workspace run were exercised separately as above. Retained Clippy output
has no project warning and reports the existing `proc-macro-error2` dependency
future-compatibility notice. Formatting success is reported by the primary;
this reviewer did not rerun formatting, builds, tests or SCI.

The committed receipt is
`docs/validation/runner-maintenance-20261006/receipt.json`, SHA-256
`13fb4620f3348c761864ef95d3c1b8c7891eb724bd3c2820c3bb706c0c104608`.
All **five source hashes and fifteen evidence hashes** were independently
recomputed with zero mismatches. Current artifacts were also hashed directly:

| Artifact | Independently matched SHA-256 |
| --- | --- |
| `/tmp/rtc-maintenance-target-20261006/debug/pipewireao-rtc` | `750059d1ee71783b63d1fbb96a6bc92cd9be436f551d1b450688a6aae2c2d5cb` |
| `debug/deps/pipewireao_rtc-efaa902bedb6b6fe` under that target | `1f5f57e3579fb5c242c2e5ae3c4e7d3c889167ca0ddb5e35b7718bae6c120a92` |

**Final disposition:** R001–R003 are closed for this source remediation and cold
verification scope. The exact historical v3 occupied-versus-maintenance branch
remains untraced. Installed service/GUI/calibration/HEART success and scientific
resource qualification remain separate; no installed pass is inferred from the
new binary or cold fixtures. Failed service v1/v2/v3 evidence remains failed.
