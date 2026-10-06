# Native deployment supervisor control

2026-10-06, issue #8, phase F of the
[native control migration design](NATIVE_CONTROL_MIGRATION_DESIGN.md), under
RTC-ARCH-024 / RTC-DEV-030. Worktree `pipewireao-rtc-native-supervisor`, branch
`rtc-native-supervisor`, starting revision
`1eba8edc48cde64a72be532d03530156d583b3c9`; the starting tree was clean.

The codec foundation implements Julia/Rust codecs, the shared Julia client
profile, reply capacity reservation and cross-language fixtures. The Julia runtime
integration replaces the selected `DeploymentRunner.control/serve_control/coordinate`
path with an inactive native endpoint on the same private core, published before
owner preparation. The existing DeploymentRunner remains the sole supervisor.
Rust CLI/GUI integration and installed scientific qualification remain separate
gates. These cold software tests make no scientific convergence, frame allocation,
timing or hardware qualification claim.

## Endpoint and request contract

The public profile is `pipewireao.rtc.deployment-supervisor/1`, distinct from the
internal `pipewireao.rtc.runner/1`. Generic NodeInfo protocol, PID, instance,
registry global ID, object.serial, controller marker and exact-token admission
retain the [common envelope](NATIVE_CONTROL_ENVELOPE.md) and existing
`NativeControlClient` / `NativeControlEndpoint` rules. A supervisor client never
selects an internal runner by profile.

Capability names use the `pipewireao.rtc.deployment-supervisor` namespace with
`version`, `instance`, `owner-pid`, `lifecycle`, `last-token`, `controllers`.
The lifecycle field is supervisor phase: Preparing=1, Admitted=2, Failed=3,
Stopping=4, Stopped=5. `admitted` is true exactly in phase Admitted. Running is
an independently queried runner/scientific fact, never inferred from that phase.

Requests reuse all fourteen exact [runner commands](NATIVE_RUNNER_CONTROL.md),
operation IDs and payloads, including the typed scalar property transaction and
parameter artifact descriptor. No argv array, relaxed SPA-JSON command string,
JSON byte buffer, arbitrary dictionary or new scientific scheduler is introduced.
The new Julia runner decoder shares encoder bounds and semantic checks; decoding
neither opens parameter artifacts nor admits a caller.

`validate_admission(phase, command)` rejects every operation except Status unless
phase is Admitted. Integration must call it before any preparation or effect.
Preparing Status contains an empty process catalog and absent owner observations.
An admitted snapshot requires a fresh runner Status observation.

## Successful completion

The payload is exactly:

```text
Struct(Id phase, Bool admitted, Struct snapshot, Struct runner_result or None)
```

A Status completion has None in its final field; its result is the snapshot's
fresh runner observation. A successful other operation requires phase Admitted
and the operation-specific runner result. `runner_result` retains the existing
`Struct(Id runner_lifecycle, Id outcome, Struct operation_details)` schema and
its submitted/requested/completed/active distinctions. Float/Double property
bits, unsigned counters, optional generations and the closed operation result
remain unchanged. For example, a parameter result remains Submitted, even when
its optional generation pair is present.

The snapshot is exactly:

```text
Struct(Struct owned_processes, runner_observation or None,
       source_observation or None, heart_observation or None)
```

| Record | Fields in order |
| --- | --- |
| Owned process | Struct(String role, Id PID) |
| Binding | Struct(String name, String profile, Id owner_PID, Id global_ID, Long unsigned_serial_bits, Long instance) |
| Runner observation | Struct(binding, Long matched_Status_token, String session_id, Struct runner_Status_result) |
| Source observation | Struct(binding, Long matched_query_or_Status_token, Id source_kind, Struct source_snapshot) |
| HEART observation | Struct(binding, Long matched_Status_token, Id HEART_lifecycle, Struct HEART_snapshot) |

The process catalog has at most 32 records, unique roles and unique positive
PIDs; role, binding name/profile and session ID strings have at most 128 UTF-8
bytes. Bindings require assigned nonzero global IDs, positive PID, serial and
instance. Each observed binding PID must appear in the current owned process
catalog. Integration must construct these records from live bound clients and
currently owned processes; saved locator/status metadata is not authority.

The runner session ID retains existing CLI/UI semantics:
`native-runner-instance:<actual runner binding instance>`. It is absent when no
runner observation exists. The supervisor incarnation remains in the common
completion header and is not substituted into that runner session field.

Every nested observation token is positive. Integration must acquire it through
a newly processed query with exact native identity/correlation, within the
accepted ticket's absolute deadline. The codec can check identity/field
consistency; fixtures alone cannot prove actual native freshness or coherent
startup. Bootstrap capability data and saved scientific reports cannot supply
these observations. A sequence of queries is not an atomic simultaneous
snapshot of multiple processes.

### Source observations

Source kind 1 is the unchanged simulator source contract. Its binding profile
name `pipewireao.source-control/1` identifies the actual validated V1
run/reset/query/snapshot property set; it does not require a new
`rtc-control.profile` advertisement on the existing hot source. Its current
legacy instance 1 is retained and fenced by actual PID, registry serial and
removal observations. A later cold readiness endpoint has a separate incarnation.

Its source snapshot fields are the actual eleven `HILSourceControl.SnapshotValues`:

```text
Struct(Int version, Long instance, Int kind, Long completed_token, Int result,
       Long generation, Long sequence, Bool running, Bool completed,
       Long report_generation, Long report_sequence)
```

Version=1, kind=QUERY=3, result=0, and completed_token must equal the source
observation token. Instance must equal the binding. Generations are positive;
sequences are nonnegative. The report cursor cannot lead the scientific cursor;
a completed snapshot requires the current report cursor. This source has no
invented acquisition domain/model timestamp fields.

Source kinds 2 and 3 are calibration and correction. Their exact advertised
profiles are `pipewireao.rtc.calibration-lifecycle/1` and
`pipewireao.rtc.correction-lifecycle/1`. Their payload is
`Struct(Id cold_lifecycle, Struct acquisition_snapshot)`, reusing all nine fields,
closed phases/instruments, optional four-component acquisition/report cursors and
window semantics from the [acquisition lifecycle codec](NATIVE_ACQUISITION_LIFECYCLE_CONTROL.md).
Cursor components and window Longs preserve full UInt64 bits.

The optional HEART observation reuses all nine fields and Ready health
invariants from the [HEART codec](NATIVE_HEART_CONTROL.md), including the current
child PID, child generation, placement/diagnostic facts and saved report locator
and digest. A saved report path is an artifact locator, not a live health source.

## Failures and capacity

An independent admission Rejection has exact payload
`Struct(Id phase, Bool admitted, String field, String message)` and carries no
applied inner result. A negative accepted Completion instead has exactly:

```text
Struct(Id phase, Bool admitted, snapshot or None,
       Struct(String field, String message, runner_result or None))
```

Each diagnostic string has at most 8192 UTF-8 bytes and no embedded NUL. An
optional RunnerRecord preserves an actual matched successful inner operation
under phase Admitted and the same outer operation ID; it does not claim overall
supervisor success. Snapshot remains None unless fresh Status verified it.
For example, an explicit source Resume rejection after completed runner Start
preserves Running/Completed and the source error; a subsequent fresh Status
reports the actual paused source. Local render exposes that known inner result
with `ok=false`. No rollback or retry is invented. This pre-release refinement
changes only the prototype negative Completion grammar; successful completions
and Rejection are unchanged. There is no old negative grammar fallback. The common zero sentinel
remains an uncorrelated rejection diagnostic and cannot become a fresh operation
completion. Oversized diagnostics require a short truthful capacity error;
stack traces remain stderr/saved diagnostics, not a wire schema.

`completion_size` checks the combined 64 KiB reply before variable runner
catalogs are cloned or encoded. Cold source and HEART records have fixed field
counts and bounded small strings; their existing validators are reused. Query
capacity failure rejects rather than truncating a catalog.

Before **any mutation effect**, integration must call
`preflight_mutation_reply(command, snapshot; snapshot_bound=...)`. The helper
reserves the common header, complete supervisor snapshot, worst closed runner
mutation result, and bounded failure alternative including its nested Struct,
optional actual snapshot and worst matched inner result. It uses actual requested
names and distinct `node:property` prefixes for up to 42 property generation
rows, and the optional generation pair for parameter results. Parameter shape,
schema and artifact path are preparation metadata and are not fabricated result
fields. No dummy result catalog is built. An explicit future snapshot bound must
cover optional fields and string growth that the operation can introduce; it
cannot be smaller than the current snapshot. The internal runner's independent
64 KiB reservation does not reserve the larger supervisor completion.

The runtime integration must create one inactive no-port endpoint on the same
private core **before** spawning/admitting owners. It stages owned commands
through the existing sole DeploymentRunner coordinator outside callbacks.
Preparing Status and mutation rejection continue until coherent runner/source
admission. The same accepted `Ticket.deadline` must reach every nested runner,
source, acquisition, HEART and synchronization operation. Existing fresh
8/16/30-second nested budgets in `deploy.jl` require replacement in that
integration; the Julia runtime now propagates the accepted deadline at available wait boundaries,
with the Simulator V1 inner-owner limitation described below.

## CPU codec evidence and remaining integration

The foundation baseline passed 197 assertions on CPU15; the negative Completion
refinement now passes 207. The adjacent runner
codec and generic client suites pass 146 and 23 assertions. Forty-eight shared
native POD fixtures cover all fourteen requests, all result variants, Preparing
and admitted simulator/calibration/correction/HEART status, negative completion,
rejection/sentinel, Float negative zero/NaN diagnostic bits, signed generation
fields, UInt64 high bits and malformed semantic/type rejection. Rust decodes and
re-encodes every valid Julia fixture identically and rejects every malformed
fixture. Both languages check every mutation's exact 64 KiB reserve boundary and
reject one byte beyond that bound before effects.

The expanded Rust native codec/mailbox/result selection passes 31 tests; four
existing connected fault fixtures remain explicitly ignored in that selection.
Focused commands use the shared offline Cargo target and installed PipeWireAO
libraries. Cargo formatting and strict binary Clippy pass. Cargo reports the
existing dependency future-incompatibility warning for `proc-macro-error2`.
Julia reports the existing mixed loaded/precompiled dependency-version notice;
the fresh process completes all selected suites. These are codec/software
checks, not connected supervisor, source science or installed qualification.

Remaining gates are independent codec review; production staged endpoint and
one-deadline coordination; fresh native discovery/admission; actual two callers,
busy/stale/duplicate/removal/expiry cases; CLI/GUI migration; public socket and
live status/readiness-file removal; installed startup/control/cleanup and the
selected scientific/HIL checks. Discovery hints must be followed by exact fresh
native supervisor profile/PID/incarnation and Status verification.


## Julia runtime integration evidence (2026-10-06)

Production integration started clean at merge `8c914592e12f96790c2ea5cf304640cb1ed0f66d`
(root baseline `9055db3`). `NativeSupervisorRuntime` publishes no ports and stages
callbacks through the common Endpoint. The same DeploymentRunner services Preparing
Status at its existing health/wait boundaries with a recursion guard; Preparing
mutations are rejected and no owner observations are exposed. Coherent admission
changes phase to Admitted only after existing preparation/start completes.

`control.json` is a bounded saved locator with version/profile/private remote/node/
owner PID/incarnation. It supplies hints to a fresh exact native bind followed by
Status. `state["socket"]` temporarily aliases this locator for dirname/path callers;
it is not a Unix socket and must retire with issue #9. Saved phase/admitted, owner
bindings and scientific reports are never control authority. `wait_state` observes
native live state; `wait_final_report` reads a saved final report only after observing
the actual owned launcher exit and matching its PID. Former JSON helpers have
explicit `fixture_` names and are absent from the selected production path.

Every accepted ticket uses its one absolute deadline for fresh runner/source/HEART
queries, source pause/reset/resume, typed runner coordination and terminal flush.
No new 8/16/30-second budget is started inside public coordination. The unchanged
Simulator SourceControlV1 schema has no owner deadline field: the supervisor's
source wait uses the accepted deadline, while the source owner's existing nested
HEART reset uses its pre-existing internal budget. This is an explicit existing
wire limitation; full owner-to-owner deadline propagation is not claimed for V1.
Expiry or lost identity fails closed without reconnect/retry/fallback. Before any
mutation, the supervisor reserves the combined header, future snapshot, closed
runner result and bounded error alternative. Future snapshot allowance includes
optional acquisition cursors/window, longest closed source phase and HEART's
4096-byte report path/64-byte digest/optional child fields. The admitted runner
sink/process/binding catalogs are fixed by the realized deployment: these public
commands cannot load a new graph or owner. Read-only catalog queries can reject
actual reply overflow. Successful Quit carries the fresh snapshot taken immediately
before its effect (operation-defined ordering, rendered as `before_quit_effect`)
and synchronizes the terminal publication before cleanup.

Cold tests ran with Julia 1.12.7 on CPU15. `native_supervisor_endpoint.jl` passed
43 assertions on an actual private PipeWire core with two real native clients:
Preparing, no ports, normal stop/reset/start, exact accepted deadline across mock
nested runner/source calls, selected locator control, duplicate/conflicting/stale
requests, malformed requests, busy rejection, overflow before effects, accepted
expiry, actual controller removal, quit flush, endpoint removal and exact immutable UUID match/rejection. Nested science
clients in this test are explicit mocks; it does not qualify installed science.
`test_native_supervisor_coordination.jl` passed 9 deadline/effect assertions and
6 optional observation placement assertions. Independent final runtime review and
installed Preparing/admission/cleanup qualification remain required by NSCR-004.

### Optional observation admission (OBSR-001)

Observed defect: HILExport adds the observer-loop count1 requirement even when
optional detector observation cannot bind; the prior admission path then required
that absent observer loop. The admission placement selector now omits only the
`observer-loop` count1 entry for the core when detector observation was selected
and its boundary is unavailable. Available/default paths use the original contract.
Other thread counts (including observer-loop count2), envelope, policy, leader and
memlock fields are preserved; the specification is unchanged. The six cold tests
confirm this selection and preservation. Fresh installed missing-queue qualification
is a separate root-owned gate.


## Immutable deployment identity for discovery

The public Runtime creates one nonzero UUID per endpoint lifetime and publishes
`pipewireao.rtc.deployment-supervisor.session-uuid` in actual bound NodeInfo. This
identity remains stable across Preparing, admission and runner state transitions;
it does not replace the runner session ID. Generic Endpoint `properties_extra`
cannot replace any common identity key. The generic Client profile identity hook
validates the public UUID on every full bound NodeInfo update and rechecks the
retained exact bound identity at every request health boundary. Public `live_uuid`
returns only that healthy native binding; optional `expected_uuid` requires an
exact discovery hint match. No saved UUID can establish admission without fresh
native Status. Endpoint removal retires live authority; final saved reports do not
provide a live Stopped endpoint.

Adjacent cold suites also passed native client 23, supervisor codec 197, typed
supervisor coordination 15 and legacy fixture runner coordination 39 assertions.
The broader portable deployment/control-interruption suites subsequently passed:
source failure 44, portable admission/protocol 214, native preparation 7 and
control interruption 4.


## Public Rust library and selected CLI

The library exposes one shared runner request/result and supervisor codec authority
under the live feature. The bounded domain client uses exact bound owner/controller
NodeInfo, retained capability admission, a private same-user native remote, one
pending token and finite MainLoop iteration. Matching terminals observed before
later removal remain valid; malformed/conflicting evidence is fatal. Expiry after
submission retires the client with explicit UnknownOutcome. Retired clients expose
no owner binding/UUID and never reconnect/retry/fallback. Public Command/ExecutionResult
and the supervisor client are available without exposing mailbox or Statig state.

`pipewireao-rtc control --locator PATH -- COMMAND` parses operator arguments locally,
reads bounded locator hints, binds/proves the actual public profile, then sends fresh
Status and any typed command under one absolute Instant. Output JSON is local render.
The former `--socket` spelling temporarily aliases the locator flag; no Unix control
socket is opened. Retired JSON client helpers compile only for explicit legacy Rust
fixtures. The native client’s transport mechanics temporarily parallel the calibration
client while each domain qualifies independently; a common extraction requires a
separate adjudicated review and must preserve both domains’ capacity/ordering rules.


Final cold refinement/client evidence is recorded in
[NATIVE_SUPERVISOR_RUNTIME_VALIDATION.md](NATIVE_SUPERVISOR_RUNTIME_VALIDATION.md).
Rust library tests passed 75 with 3 existing installed/private-core tests ignored;
all 45 native codec/client tests passed. Strict all-target Clippy and Rust fmt passed.
The actual private-core Julia/Rust public-client proof passed 63 assertions, including
PID/inc/profile rejection before effects and preserved partial runner Start after
source Resume rejection followed by fresh Running/paused Status. Those inner
science bindings remain explicit mocks; root-owned installed qualification and
independent final runtime/negative-grammar review remain gates.
