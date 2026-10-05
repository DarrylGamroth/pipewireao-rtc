# Native live-control migration review

2026-10-05. Independent source and design review. The inactive, zero-port
Filter approach is feasible for the cold control owners and preserves the
existing dispatcher boundaries. Proceed with the small shared-envelope and
cross-language mechanism increment after resolving the correlation rules below.
This review does not establish completed migration, bounded runtime execution,
allocation qualification or hardware behavior.

## Scope and evidence identity

- Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls`.
- Branch: `work/native-control-planes-20261005`.
- RTC source: `74099a2861ed7d60789a38c0f3ad4121b029bf48`.
- Starting changes: untracked `LIVE_CONTROL_INVENTORY.md`,
  `NATIVE_CONTROL_FILTER_PROOF.md` and `NATIVE_CONTROL_MIGRATION_DESIGN.md`
  under `docs/`, owned by the primary task. This review changes only this file.
- Julia API source inspected: canonical sibling `PipeWireAO.jl`, reported proof
  revision `354512752bc35fd9fe59fe16cc1a0585668107c6`, public version 0.6.16.
- Rust API source inspected: Cargo-pinned `PipeWireAO-rs`
  `f2d86899328465e9b97ccbfb4b10d0b243749171`.
- Authority: repository `AGENTS.md`, `docs/README.md`, relevant portions of
  RTC-ARCH-020 through RTC-ARCH-023, RTC-DEV-021/022/029 and the active roadmap.
  The archive was not used.

The [design](NATIVE_CONTROL_MIGRATION_DESIGN.md),
[inventory](LIVE_CONTROL_INVENTORY.md) and
[Julia mechanism proof](NATIVE_CONTROL_FILTER_PROOF.md) are reviewed inputs.
The recorded proof's 30 assertions are existing evidence; this reviewer did not
rerun them. No production edits, simulation, GPU jobs or test workloads were run.
The low-latency design skill supplied the ownership/bounds review checklist.

The user's selection of native PipeWire serialization authorizes changing the
listed live transports. It does not promote physical authority, remote control,
a new scientific scheduler or sibling-package changes. JSON configuration and
immutable reports remain within the existing artifact boundary. Runtime reads
that currently confer readiness or completion are live controls even when their
file names end in `.json`.

## Assessment and ownership

The critical control path is client encoding → native Node request → bounded
callback staging → existing owner dispatcher → existing effects → retained
native completion → exact client correlation. The owner remains the sole writer
of lifecycle/scientific state. Callbacks must not run effects or wait for them.
The staged slot remains occupied during execution, including after a client
abandons its wait. A rejection does not overwrite the accepted completion.

The inspected Julia `src/filter.jl:235` callback copies a POD before invoking
the application, and `:677` publishes global parameters. The pinned Rust
`pipewire/src/filter/rc.rs:400` callback requires `Send`, receives a borrowed
POD and exposes no setter identity. Its `filter/mod.rs:142` and `:163` expose
connect/publication. The proof supplies observed support for inactive export,
zero ports, no processing callback, explicit completion publication and removal.
No activation, dummy port, data link or scientific processing owner is needed.
Rust and Julia interoperability for the final shared envelope is still a
required observation. The follow-on Rust mechanism proof reported by the primary
agent is a separate scalar mechanism gate, not that final-envelope qualification.

The current Rust crate enables `v0_3_34`; `FilterFlags::ASYNC` is gated by
`v0_3_77` (`pipewire/src/filter/mod.rs:870`). Its no-port proof uses `INACTIVE`
alone. Julia's mechanism proof uses `ASYNC | INACTIVE`. There is no frame-buffer
queue/dequeue in either fixture, so matching the flags by widening Cargo features
is unnecessary. Preserve this language/API distinction in reproduction notes.

Cold allocation is acceptable for supervisor/runner/wrapper control. The Julia
Filter's framework POD copy precedes application bounds checking; do not claim
that every allocation occurs only after the application cap is checked. Bound
subsequent decoding, owned staging and retained results, and preserve the prepared
Stream codec on measured scientific source paths. This is an acknowledged cold
path exception, not a finding that requires a new generic transport framework.

There is no new throughput or tail-latency claim to review. The selected contract
is finite operation/preparation/cleanup waits, bounded requests and retained work,
truthful completion and unchanged scientific behavior. A single pending command
does not bound a blocking effect's duration or guarantee health/stop responsiveness.

## Findings

### NCMR-001 — Correlation must distinguish concurrent controllers

Severity: High. Confidence: High. Evidence class: derived design defect.
Disposition: accepted and incorporated into design prose during review; final
schema, completion table consistency and implementation remain to be checked.

Evidence: the initial design §2 assigned a globally increasing owner token, allowed clients
to choose it from retained metadata, replays the last committed duplicate, and
defines completion as endpoint/token/operation. Controller identity is described
principally for calibration disconnect tracking. The native Filter callback does
not identify the setter connection (Julia `src/filter.jl:235`; Rust
`pipewire/src/filter/rc.rs:400`).

Two ordinary clients can read the same next token and send the same operation
and payload. A completion containing only owner/token/operation is acceptable
to both clients. Treating the second submission as a duplicate also contradicts
the intended collision rejection. This is a concurrency error without assuming
malicious clients.

Required correction: include exact controller global ID, object serial and
controller instance in each request, completion and rejection. Include that
identity in the duplicate key. Replay a terminal result only for the same
controller and same canonical request; a different controller using an occupied
token receives an independently correlated collision rejection. Preserve the
original completion. Do not retry automatically. A completion must match the
full correlation tuple before advancing a client.

Validation: two real clients read identical retained token metadata; exercise
same and different payloads, while pending and after completion. Exactly one
submission may execute, and only its controller may accept that terminal result.
Replay from the original controller must perform no second effect. Rejection
from another caller must not invalidate the successful caller's result.

### NCMR-002 — Inner Rust sync can outlive every outer deadline

Severity: High. Confidence: High. Evidence class: observed baseline source behavior
and subsequently reproduced runtime stall.
Disposition: local synchronization corrected and independently verified in
[NCMS-001](NATIVE_CONTROL_SYNC_REVIEW.md#ncms-001--inner-sync-ignores-outer-deadlines).
The whole-request budget and production owner admission remain integration gates.

Baseline evidence: `src/live.rs:3183` waits in `main_loop.run()` until the selected sync
callback runs, with no elapsed-time or error-exit condition in that loop. Calls
include constructor discovery (`:612`), property/reset paths (`:1192`, `:1298`),
group control (`:1681`), required-object monitoring (`:2845`) and cleanup
(`:1890`, `:1929`). An outer deadline cannot interrupt this inner wait.

Required correction: a deadline-aware sync helper using finite loop iteration,
matching done/error observation and the existing caller's absolute deadline.
Thread budgets through preparation, operations, monitoring and cleanup. Do not
merely replace each call with a fresh five-second wait: a series of such waits
can exceed the original budget. Report unknown mutation outcome when an effect
may already have started. Preserve the single dispatcher.

Validation: fail-before/pass-after daemon stall and disconnect while syncing,
including cleanup and required-object monitoring. Confirm bounded owner return,
finite cleanup and no success/rollback claim after an unknown outcome. Public
endpoint admission must not claim this gate from the no-port Filter proof.

### NCMR-003 — Controller existence is not a complete calibration timeout policy

Severity: Medium. Confidence: High. Evidence class: observed existing behavior
and derived migration omission.
Disposition: accepted and incorporated into design §2 during review; executable
deadline and caller-marker behavior remain to be validated.

Evidence: `deployment/hil/calibration_server.jl:649` starts a finite timer for
each record read. `serve_connection!` at `:694` starts the next reader before
`execute!`, and `check_reader` at `:668` rejects EOF, timeout and pipelined data.
The outer catch faults the owner. `fault!` at `:182` retains held ownership and
clears restoration. The initial design tracked registry removal and individual
operation deadlines, but omitted the connected silent caller and abandonment on
a shared surviving connection. The maintained design now states both obligations.

Required correction: scope the monitored controller identity to the calibration
control session/run. Remove that marker on client timeout/abort even if a shared
Core survives. Retain an explicit finite next-request deadline and poll it on the
existing owner service loop. Start it at the accepted-request boundary alongside
the next-request wait, not at completion; the current reader is already active
during execution. Keep the action deadline separately authoritative. Do not
accept a second action while the first executes. Expiry, removal or native-core
loss must prevent release and retain hold/fault; it must not synthesize a
restored result. Async task scheduling is incidental, not a timing guarantee to
copy.

A transaction-owned inactive caller Filter is a feasible marker if the public
Client binding cannot provide the needed reliable lifetime/instance contract.
It has no data ports or processing callback. The exact marker choice should be
established in the small proof before wiring scientific owners.

Validation: caller exits during adoption, caller disappears immediately before
Release, persistent Core survives an abandoned run, controller remains connected
but sends nothing, and an action consumes most of the next-request budget.
Check actual session hold/fault, not only the client's error. A request queued
after its deadline must execute no effect. Restoration after a known rejection
and fault handling after an unknown outcome must retain their existing distinction.

### NCMR-004 — Active contracts mandated the old transport

Severity: Medium. Confidence: High. Evidence class: observed documentation
inconsistency. Disposition: resolved at the design/active-contract level by
RTC-ARCH-024 and RTC-DEV-030; transport implementation and validation remain open.
User authority was already supplied; no additional permission gate is inferred.

Initial evidence: `docs/architecture.md:396` and RTC-DEV-022
(`operations.md:671`) specified Unix/socket operation and ownership restrictions.
Calibration completion channel text (`operations.md:968`) specified JSON and a
64 KiB response.
The current Rust and Julia calibration server both allow 128 KiB
(`src/calibration_socket.rs:20`, `deployment/hil/calibration_server.jl:9`), while
the Julia client reads 64 KiB (`calibration_campaign.jl:326`).

Required correction: deliberately update the existing active requirement IDs
with each selected native transport contract, retaining one executor, owner-only
local access, finite bounds, unknown-outcome semantics and all calibration action
meaning. Distinguish runner reply caps from calibration reply caps. Resolve the
128 KiB calibration response contract and Julia client together. Keep the roadmap
and authority map aligned with implemented versus pending phases.

Validation: contract-to-code comparison of action coverage, numerical fields,
limits, failure cases, CLI/install/export callers and remaining live JSON use.
Removing the socket must preserve its owning-user restriction through the private
core's access boundary. Merely checking a claimed registry object is lifetime
correlation, not authentication of a setter; do not claim stronger isolation.
No remote authentication framework is called for by this local migration.

Follow-up contract review: RTC-DEV-022 now selects the private native endpoint
and records the Unix interface as migration debt. RTC-DEV-030 distinguishes the
64 KiB lifecycle and 128 KiB calibration limits, exact caller correlation,
finite nested deadlines, inactivity and restoration. Its common envelope and
single-terminal rules explicitly apply to new cold owners; the already completed
supervisor-exclusive source retains its unchanged run/reset/source schemas.
The calibration text now identifies installed server selection and the current
client/server bound mismatch accurately. The README preserves the three active
documents as normative authority, and the roadmap orders codec proof, bounded
runner effects, owner/client migrations and final live-file removal.

RTC-ARCH-024 and RTC-DEV-030 each have one active definition. An identifier-only
check found neither in the archive; no archived capability was promoted by this
review. The reviewed additions provide sufficient authority for the narrow
phase-A codec increment, without claiming completion of later migration phases.

### NCMR-005 — Design proof references need repository destinations

Severity: Low. Confidence: High. Evidence class: observed documentation issue.
Disposition: corrected by the primary agent during review; inspected updated
inventory/proof links and current baseline provenance.

The initial design referred to `native-control-filter-proof-notes.md` and the initial
`remaining-live-json-inventory.md`, whereas the maintained review inputs are
`NATIVE_CONTROL_FILTER_PROOF.md` and `LIVE_CONTROL_INVENTORY.md`. Preserve the
earlier source revision as historical provenance, but link the actual maintained
documents and identify cache-only logs as evidence artifacts. Check local links
and avoid representing the older design inspection revision as the current
implementation baseline.

## Payload and identity decisions supported by the evidence

Native Float32 arrays are sufficient for 277 commands and 376/3600 mean values.
There is no demonstrated need for extra data streams or a two-channel command
protocol for these payloads. Exposure metadata must remain exact and bounded.
Even an ideal packed array of five 64-bit fields needs 163,840 bytes for 4,096
exposures, before response values or POD overhead; the 128 KiB limit therefore
necessarily reduces the supported Collect count. Capture's stored frame bound
and Collect's encoded completion bound are different limits.

The existing `collect!` already checks capacity before acquisition
(`calibration_server.jl:378`). Preserve that ordering with checked encoded-POD
size arithmetic, including object/field names, headers, padding and identity
overhead. Test the largest accepted and first rejected count for each profile
and representation. Do not discover oversize only after collecting exposures.
The design correctly leaves captured arrays/manifests as committed artifacts
and moves their completion authority into the native result.

SPA Long bit-pattern reinterpretation can preserve UInt64 identity fields
without another protocol. It requires an explicit field-by-field unsigned
contract in both languages. Test 0 where permitted, 1, 2⁶³−1, 2⁶³ and 2⁶⁴−1;
reject zero in positive fields. Use unsigned comparisons after decode. Keep
signed positive budgets/model-time limits distinct from unsigned run, serial,
domain, generation, sequence and object-serial identities. The generic positive
owner request token is separate from calibration's existing UInt64 run/serial;
do not silently narrow calibration identities to that generic token range.

## Smallest coherent next increment

Implement and validate only the cold native owner/client envelope first, using
existing public Julia and pinned Rust APIs. Establish both-language no-port
inactive export, exact owner/controller discovery, a single staged command,
outside-callback adoption, full retained publication, correlated fresh query,
collision/duplicate/stale behavior, removal and finite waits. A scalar fixture
is sufficient; no calibration acquisition or scientific Stream changes are
needed for this proof.

The minimal retained set is one snapshot/last completion, one capabilities/token
metadata object and one independent rejection. Requests are not retained ACKs.
The shared envelope needs version, endpoint instance, full controller identity,
token, operation and remaining budget; terminal records echo the correlation
tuple and typed result. Exact names and numeric enums remain a reviewed contract
decision. Keep only the last committed canonical request for duplicate comparison,
one pending request and one rejection. No unbounded journal or additional broker
is needed.

Use a fixed shared header and exact owner-specific payload schemas rather than
an arbitrary nested value map or runtime schema registry. A Struct payload needs
bounded bytes/depth and exact operation-specific arity/types/counts. The initial
snapshot's zero token and empty controller identity are explicit sentinels, never
a fresh completion. Unsigned object serials use their full Long bit pattern,
including negative signed representations; positive signed owner/controller
instances and generic request tokens follow a different range rule. Diagnostic
Apply operations belong to a test profile/namespace, not the production operation
catalog. Malformed headers cannot safely receive fabricated correlated replies:
use an explicitly uncorrelated bounded rejection/diagnostic, preserving the ACK.

Then complete NCMR-002 before native runner admission and migrate the existing
supervisor caller with it. The design's subsequent HEART wrapper, calibration
owner, calibration action/client and public operator phases are dependency
coherent. Each phase may state remaining JSON transport explicitly; it must not
silently fall back after selecting native control. Full migration cannot be
claimed while public supervisor requests or mutable status files still carry
live authority.

Before calibration implementation, settle NCMR-003 and freeze unsigned encoding,
payload caps and controller-marker semantics. Cross-language field tests and
private-core lifecycle tests precede installed CPU science. Existing source
allocation evidence is not inherited by newly affected paths. GPU, cadence and
physical qualification remain separate from this control-plane review.
