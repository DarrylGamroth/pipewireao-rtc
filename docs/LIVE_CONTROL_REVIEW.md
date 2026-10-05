# Native simulator live-control review

Independent source and evidence review, 2026-10-05. The final checkpoint below
supersedes the earlier design-only and pending qualification checkpoints.
The active requirements remain RTC-DEV-025/026 in
[operations.md](operations.md); the selected work is recorded in
[LIVE_CONTROL_ALLOCATION_PLAN.md](LIVE_CONTROL_ALLOCATION_PLAN.md).

Reviewed RTC revision `57337d6d52db7e23d27a55d58e358995f235b3d7`, branch
`work/hil-live-controls-20261005`, worktree `pipewireao-rtc-live-controls`.
The allocation plan was already untracked; this review changes no production
source. Also inspected the uncommitted prepared POD/parser additions in
`PipeWireAO-native-owner-control` (base `5b21749`) and native PipeWire source
at `42fdf86f4e66b15e7cc1d22404294f2234dfcb85`. The native source inspection is
not proof that an installed artifact has those exact bytes.

The existing SPA run/reset encoding is suitable, provided the source retains
its own serialized adoption boundary. Fresh source snapshots need a versioned
query contract. The current pause report writer allocates inside the inclusive
simulator measurement; adjudication below selects native live snapshots and
preparation/reset/final saved reports, retiring the redundant pause checkpoint.

## Final selected-source increment review, 2026-10-05

**Disposition: no confirmed correctness blocker remains for the selected native
complete-frame simulator source-control increment.** This conclusion covers
the reviewed current RTC diff, PWA commit
`354512752bc35fd9fe59fe16cc1a0585668107c6` (released 0.6.16), and adapter commit
`0960d980b28db36d0d1d6714f7d75791d1233f37` (0.1.1). It does not declare the
broader live-control serialization migration complete. The reviewer changed
only this document and ran no workload or test in this final pass.

### Observed live evidence and independent artifact checks

Evidence root: `/home/dgamroth/.cache/rtc-live-controls-20261005`.
Each row identifies `<case>-evidence.lifecycle.json` and the corresponding
`<case>-evidence/run-{1,2}/sustained-result.json` primary reports.

| Case | Exact frame/command exchanges per run | Measured exchanges per run | First-run held sequence | Whole-run missed wall periods, runs 1 / 2 |
| --- | ---: | ---: | ---: | ---: |
| `classic-fgn-native-v9` | 8192 | 7936 | 6136 | 93 / 54 |
| `classic-jfg-native-v10` | 8192 | 7936 | 5990 | 77 / 46 |
| `copper-fgn-native-v11` | 4096 | 3840 | 2537 | 5 / 0 |
| `copper-jfg-native-v12` | 4096 | 3840 | 2412 | 4 / 0 |

All eight primary reports exactly equal their lifecycle summaries. In all
eight, allocated bytes, pool/big/malloc/realloc counts, GC pauses, GC time and
full sweeps are zero. The interval starts after the retained 256-frame prefix
and ends after final command adoption. First-run intervals include native
pause, two fresh status queries, held waiting and resume. Preparation,
stopped reset and final saved-report serialization are outside this interval;
no allocation counter subtraction or reset around midrun controls is used.
These are process-wide Julia counters, not instrumentation of every native or
GPU allocator.

For each case, both held queries have increasing request tokens, the same
paused sequence and generation, `completed=false` and `report-ready=false`.
The final source snapshot reports generation two, the requested final sequence
and a current saved-report cursor. All four lifecycles report success,
confirmed public shutdown and complete observed owner cleanup. The cleanup
record is a final observation of tracked process groups, not a proof about
untracked unrelated processes.

The reviewer recomputed SHA256 from all sixteen retained frame and command
binary files. They match the lifecycle digests and match between the two runs
of each case. This establishes exact reset reproduction of the retained
prefix, not independent replay or bit identity of all later frames. These
campaigns have sparse optical truth disabled; previous sustained scientific
validation remains separately identified rather than being silently repeated.

The recorded protected sets contain 342, 345, 336 and 338 files respectively.
Every saved file was independently rehashed and matched both its recorded
digest and the corresponding file in the original source package. Installed
simulator helpers match the reviewed source. Installed deployment descriptors
and the current qualification coordinator match the lifecycle hashes. This
supports unchanged protected graph, calibration and scientific source inputs;
it does not upgrade an unlisted file to protected status.

### Integration and validation disposition

The final diff retains serialized owner adoption, bounded accepted/rejection
slots, loop-protected observation/publication, separate token-correlated
completion, exact node incarnation checks and failure cleanup described below.
No optical algorithm, calibration, gain, model period, frame identity or
controller reset inside a running interval is introduced. Calibration export
explicitly selects its existing file-control owner when replacing the native
simulator; it is not a silent native-control fallback.

| Findings | Final disposition and remaining boundary |
| --- | --- |
| LCR-001, LCR-002, LCR-007 | Accepted implementation: existing native run/reset schema plus separate standard Props query/snapshot/rejection, coherently published and correlated |
| LCR-003, LCR-008 | Corrected and covered by focused callback tests: malformed/oversized input and overload cannot replace an accepted completion; excess rejection traffic still has only a finite unknown-outcome guarantee |
| LCR-004 | Implemented identity, deadline, no-retry and ingress-revocation contract; successful composed cleanup observed in all four cases; fault fixtures and normal live cleanup cover different conditions |
| LCR-005 | Accepted report contract: live snapshots are authoritative; preparation/reset/final artifacts remain cold and their generation/sequence are explicit |
| LCR-006 | Closed for the measured four CUDA cases and selected inclusive control interval; unrestricted input traffic, native allocators, HIP and hard real-time bounds are not qualified |
| LCR-009 | Accepted separately bounded held preparation, followed by unchanged finite live request budgets; historical v6 causality remains unproven |

Independently inspected saved test summaries total 1384 passing SDK assertions
in 63 sets (`sdk-native-released-0616-full.log`), 87 owner-protocol assertions,
125 source-control assertions and 18 owner-loop assertions in the three
`native-owner-*-released-0616.log` files. The PWA full log
`pwa-unused-notifications-full.log` totals 2011 passing assertions. The adapter's
1280-assertion log and exact path are recorded under LCR-009. These are software
checks; the live cases supply the composed CUDA simulator evidence.

The preserved v7 and v8 failures both report 329552 allocated bytes and 6675
pool allocations, with zero GC. The v8 sampled profile attributes 27313 of
27337 sampled bytes to first-use compilation entered through the unused core
remove-memory notification and 24 bytes to an unused stream-command POD copy.
The targeted PWA repair leaves those optional listener pointers null only when
no application callback exists. Native mandatory handling and configured
application callbacks remain intact; the generic independent review records
this as NC-005. The successful v9–v12 counters close the measured application
gate. Sampling does not independently attribute every byte of the failed
whole-process total, and this finding does not explain every earlier failure.

### Limits and deferred migration

The installed live cases explicitly record development-source acquisition.
PWA 0.6.16 is released and registered; the adapter commit is on local main with
no configured remote. The SDK registered dependency test is separate from the
live packages' frozen acquisition identity. No JLL change is part of this
increment, and this review does not relabel the live artifacts as a fresh
all-released export.

Only the supervisor-to-complete-frame-simulator control path is native SPA
Props. The public supervisor socket, Rust session control socket, calibration
source files, HEART controls/health and saved JSON reports remain outside this
migration. They require separately scoped follow-up where applicable. Native
live status does not promise a newly serialized pause report.

The measured wall-period misses remain in the table. Intentional held time
also appears in source gaps; it must not be interpreted as ordinary exchange
latency. The evidence supports exact delivery and the stated allocation bound
on this shared host, not hard real-time deadlines, isolated maximum capacity,
physical optical validation or HIP zero-allocation qualification. Synchronous
native loop-lock calls are not proven preemptible at a strict wall deadline.
No speculative repair is required by those disclosed limits.

## Initial composed implementation review, 2026-10-05

This checkpoint supersedes earlier statements about unimplemented candidates.
The reviewer inspected the current RTC `source_control.jl`, `source_client.jl`,
simulator, supervisor integration, qualification caller and focused fixtures,
plus the adapter's `exchange.jl` hooks in
`AdaptiveOpticsSimPipeWireHIL-native-control`. This pass changed only this review
and launched no tests or workloads while the primary agent's GPU campaign ran.
No new confirmed production correctness blocker was found by this source pass.
Live inclusive allocation and exact-delivery qualification remain pending here.

| Finding | Current implementation disposition | Evidence boundary |
| --- | --- | --- |
| LCR-001 | Implemented: unchanged native V1 run/reset PODs, separate query/snapshot/rejection schemas | Parser and codec evidence belongs to the generic PWA review; source-specific semantic tests are present |
| LCR-002 | Implemented: all four retained Props in one update; client joins native mutation status to matching source kind/token/state | Private-core client fixture proves transport/correlation, not actual optical adoption timing |
| LCR-003 | Corrected candidate overflow path: explicit nonfatal overflow handler stages an INVALID/token-zero rejection; accepted slot survives | Source callback tests exercise registered callback delivery, malformed partial parses, overflow and separate rejection publication |
| LCR-004 | Implemented: exact node ID/serial, advertised PID/instance/version, shared absolute deadline and unknown-outcome disable | Client fixtures cover invalid identity, missing source, timeout, removal and refusal after unknown outcome; composed supervisor cleanup still needs live/fault evidence |
| LCR-005 | Implemented selected report semantics: pause/status/resume use live snapshots; reset/final reports remain cold | Owner helper tests assert pause/query cause no report, report cursor stays old, and reset writes one report |
| LCR-006 | Implemented cooperative held waiting; allocation and CPU/resource qualification remains open | Zero no-request helper/pacing tests are present; full inclusive live control counters cannot be inferred from them |
| LCR-007 | Implemented public standard named Props codec with source policy retained in RTC | No new native property ID or run/reset C schema change |
| LCR-008 | Implemented separate rejection POD and retained accepted completion | Bounded overload may leave later rejected requests unanswered; timeout stays unknown |

### Adoption, locking and retained history

`ParameterChanged` copies parsed scalar fields into one accepted slot under the
PipeWire callback's loop ownership. Borrowed POD storage never escapes. The
atomic ready flag is a notification; field reads and publications use
`with_frame_stream`, so it is not being used to justify unsynchronized access to
the other fields. The owner reads the pending tuple briefly under that lock,
applies it outside the lock, and publishes/clears it under the lock. The accepted
slot remains occupied throughout application and any cold reset/report work.
A callback during that interval cannot overwrite it. Rejection publication
changes only its own retained object and does not clear the accepted slot.

The real owner calls this helper at the top of its serialized loop, after the
preceding exchange returned and its matching command was adopted and recorded.
It does not service a pause from the middle of an outstanding exchange. Neither
new adapter hook changes frame IDs, graph parameters, retry policy, driver-cycle
completion or command adoption. `frame_acquisition_generation` reads under the
existing endpoint lock. Additional stream properties cannot override existing
transport properties; construction failure retains the existing resource
cleanup path. Callbacks must stage controls and must not run optics/reset work.

Token history survives model reset. Negative owner-policy completions consume
the accepted token and are correlated through native status plus the source
snapshot. Callback rejections have a separate record and cannot overwrite that
completion. One nuance should remain explicit: duplicate recognition currently
uses kind and token, including for RUN requests with different requested states.
It preserves the first outcome and never applies the later state. Therefore
"duplicate" means reuse of that identity, not byte equality of a request. The
supported supervisor never reuses tokens. This is not evidence of a second
mutation or a delivery failure; stronger contradictory-payload rejection would
be a separate protocol choice and must not introduce a competing completion for
the first identity.

### Correlation, report cursor and failure boundaries

The client retains observations only under its own loop lock. A mutation needs
both matching native status and source snapshot; a fresh query needs its own
matching snapshot. Stale lower tokens are ignored, conflicting same-token
snapshots/statuses fail closed, and a later completion cannot silently satisfy
an earlier request. Reset success requires the next generation, sequence zero,
held state and report readiness. The report-ready comparison checks both
coordinates, rather than treating a preparation file as a current checkpoint.

The owner writes final artifacts before it can consume the next query. It sets
the report cursor only after successful writing. Reset similarly writes before
publishing completion. Ordinary midrun pause leaves the old saved-report cursor
visible while reporting the current adopted sequence. A publication/report
failure propagates to owner failure handling without clearing the accepted
identity or inventing rollback. The supervisor marks native control failure and
revokes ingress through its existing source-first cleanup. The client is closed
in the final cleanup path; it does not retry an unknown mutation.

At this initial composed checkpoint, discovery shared the request's absolute
8-second or 16-second deadline. LCR-009 below records the subsequently accepted
separate cold-preparation deadline. No blocking core roundtrip is added to
production. Loop-lock acquisition and underlying native API execution remain
synchronous: source checks around them are not proof of an operating-system
hard upper bound under a stalled native callback. This limitation is not a newly
demonstrated hang and does not justify speculative concurrency changes.

### Remaining qualification and scope

The private-core `SourceMock` applies and publishes from its callback and
increments a synthetic sequence. That test establishes actual native transport,
initial discovery, correlation, reset observation, timeout and removal handling.
It does not independently establish the production owner boundary. The owner
helper fixture explicitly simulates command adoption before consuming pause;
the final live composition must confirm the same ordering with real exchanges.

Required remaining evidence is successful installed midrun status/pause/held
queries/resume, stopped reset/restart, exact retained data/truth and inclusive
simulator-process heap/GC counters with both RTC graph owners. Preserve failed
runs and distinguish Julia counters from native allocation. At this review the
primary agent also reported a 224-byte PWA full-suite allocation observation
under investigation despite an isolated zero result; neither result is promoted
to a resolved global gate by this document.

This increment removes JSON from the complete-frame source-owner control path.
The public supervisor command socket, preparation markers, saved reports and
separate calibration-owner controls retain their disclosed formats. It cannot
be presented as migration of every live control surface. Further migration must
preserve its own existing ownership and cleanup contracts.

## Ownership and publication decision

The supervisor owns one outstanding control operation. A source parameter
callback validates a bounded POD and stages scalar request fields. The simulator
owner consumes them only between completed `exchange_frame!` calls, after the
matching command has been adopted. It alone changes admission, model state,
sequence, completion, acquisition generation and scheduling deadline.

Use the existing PipeWire loop lock for the brief mailbox transfer and native
publication, with a documented single pending slot. Never hold that lock across
optics, exchange, reset, report I/O or waits. The callback may run while an
exchange is outstanding; accepting a request into the slot is not completion.
Retain the slot's identity until completion publication succeeds. A borrowed
callback POD must not escape; copy its validated scalars into prepared storage.

Map pause/resume to native stopped/running requests without deactivating the
transport from the callback. The held source and its connected streams remain
distinct: the owner stops arming frames after adoption. Reset remains a cold,
stopped operation, coordinated after the RTC is stopped; successful completion
requires both model/transport reset and a changed acquisition generation.

## Findings and dispositions

### LCR-001 — Preserve exact native V1 parsing

Severity: high. Confidence: high. Evidence: observed source contract.

Native `src/pipewire/run-control.c:108` accepts exactly three key/value pairs
for requests and four for status inside `SPA_PROP_params`. It rejects unknown
keys there and rejects `unknown` as a requested state. The Julia
`src/run_control.jl` wrappers correctly preserve these distinctions.

Do not append sequence/generation/completed fields to that inner struct or
encode a status query as a run request for `unknown`. Keep existing run/reset
ABIs unchanged. Add a separately versioned, public SPA Props source-query
request, with a positive token and explicit capability advertisement. It must
be staged and completed at the owner boundary, so an enum of cached Props is
not mistaken for a fresh query.

Disposition: recommended implementation constraint. Validation required:
legacy C and Julia parsers still accept extended publications; unknown version,
duplicate key, malformed type, absent field, invalid token and unknown state
preserve owner state. Version/type parsing must not depend on key ordering.

### LCR-002 — Publish completion and source snapshot coherently

Severity: high. Confidence: high. Evidence: observed source, derived protocol
requirement.

The supervisor currently needs sequence and finite-completion state in
`deployment/julia/src/deploy.jl:444`; native run status alone cannot provide
them. Its cached last token also cannot establish freshness while frames run.

The initial review proposed one completion Props object whose `SPA_PROP_params` contains
the unchanged native run or reset status, and whose separately allocated,
documented outer property contains a versioned source snapshot. The C parser
finds `SPA_PROP_params` and ignores unrelated outer properties. The extension
must validate the complete outer shape itself, including duplicate properties;
the permissive native lookup is not that validation. Allocate the property ID
through the owning public API rather than choosing an undocumented constant.

The snapshot identifies the source instance/node incarnation, operation kind,
completed token, acquisition generation, adopted sequence, running/held state
and finite-completed flag. Define integer ranges and overflow rejection. The
operation and token must agree with the native completion. A query has its own
completion kind/token and the same source snapshot contract. These fields
describe one committed owner boundary. Preserve a completed mutation's snapshot
until its next completion; later frame progress must not relabel its ACK.

The compatible alternative is multiple Props objects in one update, as used by
native `ndarray-filter.c:1373`. If selected, correlate every component by
instance, kind and token before accepting it; subscribers receive separate
parameter events, so callback adjacency is not an atomic snapshot guarantee.

Native `stream.c:345` removes all parameters with each updated object ID before
adding the new set. Sequential single-POD updates of run status, reset status
and query status therefore erase one another. Publish the complete advertised
Props set together using prepared storage, or define a complete combined outer
object that preserves all required contracts. Do not duplicate
`SPA_PROP_params` to combine run and reset statuses: native lookup finds one.

Disposition: the narrower named-Props design in LCR-007 supersedes the initial
outer-property recommendation. Both compositions can preserve coherence; the
selected design avoids a new property ID. Required discriminating test:
two clients observe fresh status while running, pause after delayed adoption,
reset to a new generation, and re-enumeration retaining all capabilities and
statuses. The existing token-73 probe establishes transport feasibility only;
it does not exercise this composition or fresh snapshots.

### LCR-003 — Keep malformed input nonfatal and handoff bounded

Severity: high. Confidence: high. Evidence: observed candidate source.

`PipeWireAO/src/spa.jl:22` throws when a callback POD exceeds prepared capacity.
`src/stream.jl:204` catches callback errors and calls `_stop_after_callback`.
Using this path unchanged for an oversized control violates invalid-request
survival. `_ArrayParamChanged` in `src/ndarray_exchange.jl:147` handles format
negotiation and ignores Props; replacing it wholesale would also lose required
format behavior.

Provide a public bounded control hook alongside the existing format handler.
Oversized control input must reach a nonfatal rejection policy before copy;
other parameter types must retain their declared behavior. Parser destinations
are valid only on success: partial output after an error is not a validated
request identity. Never apply partially parsed fields or silently truncate PODs.

The slot's busy behavior must preserve the accepted request. Duplicate/stale
tokens reject without reapplying a mutation; use the existing EALREADY/ESTALE
distinction where appropriate. A second request gets bounded busy rejection,
not an overwritten slot or an unbounded reply queue. Rejection publication must
not destroy the accepted request's eventual completion. The supported controller
serializes operations; overload tests must still verify this bounded behavior.

Disposition: confirmed integration issue in the candidate buffer failure path;
fix required before malformed-input qualification. No adversarial test was run
in this review.

### LCR-004 — Keep admission, timeout and ownership semantics

Severity: high. Confidence: high. Evidence: observed active requirements and
existing supervisor behavior.

RTC-DEV-025 and `source_control` require finite waits and fail-closed unknown
outcomes. A successful `set_param!`, core roundtrip, or callback receipt proves
delivery at most. Only a matching completed token and coherent snapshot prove
application. Bind the private core's intended source by exact node incarnation
and expected owner; name alone must not admit duplicate or replaced nodes.
Reset the token namespace only for a new source instance, not a model reset.

Specify one finite overall deadline covering submission, adoption and
completion observation; do not extend it on stale events. Preserve
the existing 8 s normal / 16 s reset operational bounds unless changed with
evidence. After timeout, disconnect, source removal or publication failure,
the result remains unknown and the supervisor revokes ingress before consumer
cleanup. Do not automatically retry, infer rejection, or resume because a late
status looks plausible. Wrong schema/version is a preparation failure, not a
fallback to the old wire format.

Disposition: retain existing guarantees while updating profiles, package
dependencies, source hooks, supervisor and tests together. The file-specific
wording of RTC-DEV-025 needs a targeted native-transport amendment; do not drop
its identity, ordering, ownership, bound and unknown-outcome requirements.

### LCR-005 — Retire interim report publication explicitly

Severity: high. Confidence: high. Evidence: observed source; warm allocation
measurements supplied in the allocation plan, not reproduced by this review.

`simulator.jl:359` currently writes a pause/reset report before publishing ACK.
`write_report:251` rewrites and hashes retained binary frames/commands, slices
metadata vectors, builds report objects and serializes JSON.
`correction_truth.jl:177` creates digest strings and per-frame report objects;
`sustained_run.jl:90` builds sample records. Native control encoding alone leaves
this work unchanged. A full Classic prefix contains 352 × 352 × 2 × 256 =
63,438,848 frame bytes before command data and JSON.

RTC-DEV-025 requires adoption before pause acknowledgement, but does not require
an interim JSON report before that acknowledgement. RTC-DEV-026 requires truthful
retained and total results; it does not make a saved report the live status
interface. The report-before-ACK behavior is an implementation choice, reinforced
by the earlier qualification script, rather than a normative checkpoint promise.
The selected user request for native live controls permits replacing that choice.
Durable recording is explicitly deferred by AGENTS.md.

Adjudication: remove JSON/binary report writing from native status and pause.
Use token-matched native snapshots for live owner state and counts. Preserve
saved JSON and binary artifacts at preparation, stopped reset, finite completion
and orderly termination/failure cleanup. Do not introduce a report worker or a
specialized JSON encoder to preserve a checkpoint function the user did not ask
for. This is a documented behavior change, not proof that the old report writer
became allocation-free.

The report availability contract must say:

- Preparation/reset reports describe those completed phases and their generation;
  an existing zero-count report is not live status during a later run.
- A midrun pause guarantees an adopted sequence and held state in its native
  snapshot. It does not promise a newly saved partial JSON/binary checkpoint.
- Finite completion publishes the normal complete artifact set. Expose terminal
  readiness to report-consuming callers only after publication succeeds, or
  provide an explicit report-ready indication that they must await. Setting
  `completed=true` before asynchronous report publication would break callers
  that immediately open the files.
- Normal termination still writes the truthful partial/final artifacts before
  owner exit, with current generation and sequence. Existing deployment cleanup
  can remove its runtime directory; this is not a new durability promise.
- Prefix reports retain prefix counts, while the sustained companion reports
  actual owner delivery. A saved report must identify its phase/generation or
  document an equally unambiguous caller contract. Report failure remains a
  deployment failure and is not relabeled successful terminal readiness.

Update `deployment/qualify_sustained.jl:317` to check native pause/status snapshots
and their unchanged sequence after waiting. Keep final artifact/hash checks and
cold reset report checks. Update the allocation-plan wording, usage, active
native transport wording and tests together; retain the historical allocating
file/report measurements. The measured interval stays exactly from retained
prefix through final adoption. All actual controls, waits and any accidental
interim report work remain included. Do not reset counters at pause/resume,
subtract work, disable GC or call GC to conceal it. Final serialization remains
outside the interval as already declared. Retirement of an unnecessary operation
reduces work; moving it out of the measured interval would not.

Keep calibration-owner semantics separate: `deployment/julia/src/calibration_campaign.jl:433`
reads the old pause reply file, and lines 575–580 wait for a restored, completed
calibration-owner report at the paused cursor. That is a distinct ownership and
restoration workflow. Preserve it or migrate it deliberately if those profiles
also adopt the new control transport. Do not remove required calibration report
publication through a shared simulator refactor.

Disposition: accepted target semantic change after primary-agent adjudication.
The prior report-before-every-pause recommendation is superseded. Required
validation is native live lifecycle plus unchanged final artifact content and
inclusive process counters; no zero-allocation report-writer claim is made.

### LCR-006 — Idle behavior and native costs require scoped evidence

Severity: medium. Confidence: high. Evidence: observed loop; supplied component
measurements.

`simulator.jl:463` uses a 5 ms sleep while paused. The plan reports 112 Julia
bytes per sleep and zero for the existing yield/safepoint helper. Replacing sleep
with perpetual yield can consume CPU and interfere with other owners; zero
allocation is not a scheduling bound. Prefer a prepared public event/timer wait
whose measured allocation and wakeup behavior fit the contract, or explicitly
measure and budget cooperative polling on the assigned CPU.

POD builders/parsers with zero Julia allocations do not prove the native
publication path avoids malloc, transport work or blocking. Qualify the actual
callback, mailbox, lock, full Props publication and supervisor observation.
No rate or latency target beyond the finite control deadline has been established
by this review. CPU evidence cannot qualify GPU synchronization or physical HIL.

Disposition: implementation and deployment measurements required.

## Acceptance evidence required

- Exact-version source-query and source-snapshot contract using standard Props,
  bounded sizes, prepared batch publication and compatible legacy parsing.
- One outstanding delayed exchange: pause receipt precedes adoption, ACK follows
  adoption, no intervening frame, resume preserves exact chronology.
- Fresh queries during running/held/completed states, including a finite run
  completing immediately after resume; cached mutation ACKs stay unambiguous.
- Malformed/oversized/duplicate/stale/busy controls preserve state; disconnect,
  source replacement, terminal-report failure and timeout retain truthful failure/unknown outcomes.
- Matching stopped reset changes acquisition generation and clears sequence,
  timing, completion and recorded state without resetting instance token history.
- FGN and JFG installed lifecycle runs include midrun status/pause/resume and final reports,
  unchanged simulator-process allocation/GC brackets and exact retained payloads.
  Attribute external worker/native resource costs separately if introduced.

No GPU work, tests or production modifications were performed by this reviewer.
The saved private-core token-73 probe and supplied parser/allocation results are
supporting evidence from the primary investigation, not independent lifecycle
verification. The initial probe failures remain harness failures without an
RTC defect claim.

## LCR-007 — Select separate named Props with a prepared scalar codec

Follow-up architectural adjudication. Severity: high for the composition
invariants; confidence: high from the native update/parser source. Disposition:
accept the narrower design subject to the validation below. This replaces the
initial preference for an extra outer property in LCR-002; no new SPA property
ID or native header change is required.

Encode source query and source snapshot as separate `SPA_PARAM_Props` objects
whose standard `SPA_PROP_params` contains their own namespaced Version 1 keys.
Retain the unchanged native run/reset status objects and publish the complete
set in one prepared batch. This reuses the native filter's existing multiple
Props pattern and leaves the legacy run/reset parsers unchanged. Source query
and snapshot keys must be wholly distinct from native run/reset keys, so native
parsers classify these objects as unrelated regardless of key ordering.

Keep source-specific key names, versions and lifecycle meaning in the RTC
protocol owner. PipeWireAO may expose the reusable prepared named-scalar codec
and batch publication API. It should not acquire simulator-specific sequence,
generation, report or science policy.

### Initial advertisement and retained set

Before broker admission, expose the intended source node with public readable
and writable Props capability and an explicit versioned source-control
advertisement. A static node property may advertise support; the broker must
also validate the initial payload schema. A node name or successful enum alone
is insufficient. Do not accidentally advertise the application-owned source as
an RTC-controlled processing graph.

The initial set contains native run status `(token=0, result=0, stopped)`, native
reset status `(token=0, result=0)`, and source snapshot `(token=0, kind=initial)`
with the actual acquisition generation, sequence zero, held state and
`completed=false`. Incarnation must be stable for that owner lifetime. Define
`report-ready` against the snapshot's generation and sequence: it is true for
the successfully published preparation report, not a promise of continuous
report refresh. The broker verifies this initial state before any resume.

Every update includes the retained native run status, reset status, and latest
source snapshot; include any additional advertised Props records as well.
Build all records completely before the one update call. The stream removes
old same-ID parameters when updating, so separate single-record updates remain
incorrect. Any update failure leaves externally observed state uncertain;
fail closed rather than assuming an atomic rollback of native storage.

A single latest source snapshot is enough for one serialized supervisor, with
an explicit retention contract: it describes the most recently completed
source operation. The retained native status for an older mutation can outlive
its matching snapshot. It must never be combined with a newer query snapshot.
If the API promises independently queryable historical mutation completions,
retain separate snapshots for those kinds; that stronger promise is unnecessary
for the currently serialized broker.

### Correlation and freshness

The snapshot carries version, token, operation kind, incarnation, generation,
adopted sequence, running, completed, report-ready and an explicit Int32 result.
The result is necessary for query/busy/error completion; run/reset snapshots
must agree with the matching native result. A query has no native mutation
status to join and completes directly through its matching snapshot.

For mutations, the broker accepts only both records matching the bound node
incarnation, expected operation kind and token. Validate actual running/held
state, generation/sequence constraints and result consistency. The event order,
parameter index, callback adjacency and a successful roundtrip are not
completion evidence. Keep bounded pending observations for the one outstanding
request. A stale snapshot cannot satisfy a newer query, and the broker must not
combine components from separate incarnations.

The owner services a query only at the adopted-exchange boundary and publishes
that fresh snapshot. Do not update the last mutation's ACK on every frame.
`report-ready` means a saved report corresponding to the indicated state is
available; an old preparation report does not make a later paused snapshot
report-ready. On finite completion, publish terminal report availability only
after artifact publication succeeds, following LCR-005. Rejected operations
must not overwrite an accepted pending mutation's eventual completion.

### Prepared codec boundary

Preparing a POD through the existing public `SPA.Props` serializer and retaining
validated numeric payload offsets is a suitable implementation technique.
Update only fixed-width scalar payloads in owned storage; keep headers, lengths,
keys and padding unchanged. Validate ranges before writing. In particular,
SPA Bool uses its wire representation rather than Julia's one-byte Bool, and
SPA Long has signed Int64 range. Use fixed scalar operation codes or separate
prepared templates for immutable strings; do not mutate variable-size strings
in place. Document that updating the prepared object changes its borrowed POD
and requires exclusive ownership until the native call has consumed it.

The parser must validate each incoming POD independently: object type and ID,
outer property shape, nested bounds/alignment, exact names/types/count,
duplicates, version and scalar ranges. Key comparisons can use prepared byte
strings without constructing Strings. Arbitrary field order means sender
payload offsets cannot be assumed or cached from another request. Stage into
prepared scratch storage and expose values only after complete validation.
Keep unrelated-Props classification distinct from malformed control rejection.
Bound the POD size and field count before work; retain LCR-003's nonfatal
oversize behavior. Do not broaden this helper into a second general SPA schema
or serialization framework for arrays, arbitrary nested objects or science.

Required evidence: roundtrip parity with the existing SPA serializer; reordered
fields and duplicate/unknown/truncated/mistyped fields; exact scalar boundaries;
zero warmed allocation for prepare-once/update/parse/batch-publication usage;
and two-client private-core initial discovery, mutation/query correlation and
re-enumeration of the complete retained set. Test split/reordered observation
of snapshot and native status, reset generation and immediate finite completion.
The existing token-73 probe does not establish these properties. No production
edits or tests were performed for this adjudication.

## LCR-008 — Retain callback-stage rejection separately

Mailbox-source follow-up, reviewing `deployment/hil/source_control.jl` before
the proposed fourth record is implemented. Severity: high. Confidence: high
from the current publication and callback paths. Disposition: accept the fourth
Props record with the duplicate and capacity conditions below.

The current `publish!` changes the same native run/reset buffers and source
snapshot for the supplied kind/token. Reusing it for callback-stage busy/stale
rejection can erase the accepted operation's completion before the broker
observes it. The bounded request/rejection slots alone do not prevent this
external loss when parameter notifications coalesce.

Retain a fourth Props object with separate versioned
`pipewireao.source-rejection.*` keys. Give it the same coherent scalar snapshot
shape, including instance, kind, token, negative result, generation, sequence,
running/completed and report cursor. A callback only stages this rejection; the
owner publishes it between adopted exchanges. Update all four retained Props
objects in one prepared call. Rejection publication must leave the accepted
snapshot and native run/reset completion buffers unchanged. An ordinary request
accepted into the slot but rejected by owner policy still completes through the
normal native status plus source snapshot; it is not a callback rejection.

Define an explicit empty rejection sentinel at initial publication, for example
INITIAL/token zero/result zero. It differs from an uncorrelated malformed-input
diagnostic INVALID/token zero/negative result. Advertise the rejection schema
version and include a parser branch that ignores valid rejection status Props
received through the stream's own parameter notifications. The current callback
ignores run/reset/snapshot statuses; omitting the new record from that branch
would classify a valid publication as malformed input.

### Duplicate outcome ordering

A committed native completion and matching accepted snapshot are authoritative,
including a negative owner-policy completion. A later duplicate/stale rejection
cannot change that result. However, preferring success only after both records
arrive is insufficient: the duplicate rejection might arrive first.

For an exact duplicate of the currently pending kind/token, do not publish a
terminal EALREADY rejection. Preserve the pending operation and let its original
completion resolve the request. For a duplicate of a still-retained completed
kind/token, preserve the original completion, optionally republishing that
unchanged set; do not publish a competing terminal rejection for that identity.
This prevents the broker from declaring rejection while the original accepted
operation can still commit. A same token with a different kind is a distinct
invalid/replay condition and cannot match the legitimate operation's kind.

Broker matching uses bound incarnation, requested kind and token. Only a fully
validated positive-identity rejection may resolve that request directly.
Token-zero diagnostics cannot match it. Processing a later rejection event must
never replace an already resolved completion. Preserve the no-automatic-retry
rule regardless of whether the observed result is busy, stale or unknown.

### Capacity and finite outcome

The candidate `reject!` retains one rejection and silently declines later ones
until it is drained. This is bounded storage, but it cannot promise a reply to
every request under a flood. State that explicitly. The supported broker sends
one operation at a time; excess controls preserve accepted state and may receive
no correlated rejection. Its fixed deadline still yields a finite unknown
outcome and deployment failure, not inferred rejection or success. Do not
expand the slot into an unbounded completion history to promise individual
responses to arbitrary flooding.

Drain/publish only bounded work per owner boundary and retain a rejection slot
on publication failure until failure cleanup takes ownership. Do not clear the
accepted request slot as a side effect of rejection publication. The complete
initial and subsequent publication sets must always retain all four records.

Required validation: busy B while A is in flight, A adoption and completion,
rejection publication before/after A, coalesced/reordered observer delivery,
exact duplicate A while pending and after completion, retained negative owner
completion, malformed token-zero input and rejection-slot overflow. Confirm A
is applied once and remains observable, B never changes owner state, and
unmatched overload ends only through the existing finite unknown-outcome path.
No tests or production edits were performed for this adjudication.

## LCR-009 — Separate held client preparation from live request deadlines

Final source checkpoint, 2026-10-05. Severity: medium operational defect in the
original shared cold-start budget; confidence: high for the reviewed phase
separation, with historical failure causality limited as stated below.
Disposition: accepted design; the required source guards are implemented.

The current supervisor performs initial native-client discovery and static
compilation while the source is held, before the initial real pause and RTC
startup. Both use one absolute preparation deadline from the existing owner
preparation option, 90 seconds by default and 900 seconds when explicitly
selected by the qualification harness. This is a separately bounded startup
phase; it does not imply that all preceding preparation shares a total 90-second
wall limit. Each real control starts its own absolute 8-second or 16-second
budget before request dispatch, submission and completion observation.

`SourceHealth` has one concrete callable type for normal and shutdown checks.
`prepare_requests!` statically precompiles the exact `Core.kwcall` request
signature with that type. It checks health, initial held/report-ready state and
zero request history, then checks the preparation deadline again. It sends no
request and admits no frame. Residual compilation during a real request remains
inside that request's budget; a successful precompile call is not a guarantee
that all future dispatch paths need no compilation.

The reviewed `source_control` implementation permits a missing-client join only
when `initial=true`, rejects entry after `source_failed`, and sets that flag on
preparation or request failure. Consequently its existing source-first cleanup
cannot silently retry a failed join. A later live request cannot re-enter cold
preparation. These guards satisfy the independent review's conditions. The
public contract document now explicitly distinguishes the phases. This is
compatible with RTC-DEV-021 held preparation and RTC-DEV-025 finite, correlated
controls; it changes the earlier implementation's stricter combined startup
budget rather than weakening a live mutation's deadline.

Cold CPU fixtures establish substantial compilation cost and variability, but
this review does not claim that compilation alone root-caused every v6 failure.
The newer successful v7 composition is positive delivery evidence, not a
controlled causal explanation of all earlier failed packages. Preserve those
identities. Offline package precompilation remains an optional latency
optimization; it is not a replacement for finite runtime preparation and
failure cleanup.

### Adapter release verification

The inspected adapter commit is
`0960d980b28db36d0d1d6714f7d75791d1233f37`, version 0.1.1, requiring PipeWireAO
0.6.15. Its public hooks, README ownership constraints, loop-protected stream
access and generation read agree with the earlier composed review. The added
private-core tests reject transport-property overrides, publish added Props,
check both helpers at zero Julia heap bytes and verify generation changes from
one to two across reset. No simulation or report work is moved into callbacks.

The reviewed full test log is deliberately identified by its actual location:
`/home/dgamroth/.cache/rtc-sustained-hil-20261004/native-adapter-pkg-test.log`.
Its five printed summaries total 1280 passing assertions and end with package
tests passed. The final status lists the actual native-control adapter worktree
at 0.1.1 and PWA native-owner-control worktree at 0.6.15. This reviewer inspected
the log and committed diff; no test or GPU workload was rerun in this checkpoint.

### V7 delivery succeeds; inclusive allocation qualification fails

The independently inspected
`/home/dgamroth/.cache/rtc-live-controls-20261005/classic-fgn-native-v7-evidence.lifecycle.json`
records all 8192 requested frame/command exchanges completed. Public midrun stop
and resume succeed. Fresh source status tokens 5 and 6 both observe generation
one, paused sequence 6307, `completed=false` and `report-ready=false`, with the
saved report cursor still at sequence zero. Public shutdown is confirmed and
cleanup is complete. Recorded prefix frame/command hashes equal the preserved
released-v32 prefix identities; this is not an independent replay of all 8192
frames.

The same record has `success=false`: over 7936 measured exchanges the inclusive
simulator counter records 329552 allocated bytes and 6675 pool allocations,
with zero big/malloc/realloc counts, zero GC pauses/time and zero full sweeps.
The gate rejects that run and preserves its evidence. LCR-006's inclusive
allocation qualification therefore remains open. The pending allocation profile
must distinguish actual sources before any production repair; library codec
microbenchmarks and successful command delivery cannot close this gate.

The earlier PWA 224-byte suite observation is now separately attributed to its
in-process observer and resolved by a documented observer-only microbenchmark
isolation change in `NATIVE_CONTROL_REVIEW.md`. That library finding does not
explain or remove the v7 simulator-process allocation result.
