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
