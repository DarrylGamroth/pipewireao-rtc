# Native deployment supervisor codec foundation

2026-10-06, issue #8, phase F of the
[native control migration design](NATIVE_CONTROL_MIGRATION_DESIGN.md), under
RTC-ARCH-024 / RTC-DEV-030. Worktree `pipewireao-rtc-native-supervisor`, branch
`rtc-native-supervisor`, starting revision
`1eba8edc48cde64a72be532d03530156d583b3c9`; the starting tree was clean.

This increment implements Julia/Rust codecs, the shared Julia client profile,
reply capacity reservation and cross-language fixtures. It does not yet replace
`DeploymentRunner.control/serve_control/coordinate`, operator socket discovery,
live status files, the Rust CLI or GUI callers. It makes no installed deployment,
scientific convergence, frame allocation, timing or hardware qualification claim.
The existing DeploymentRunner remains the sole supervisor.

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

A failed accepted operation and an independent admission rejection have exact
payload `Struct(Id phase, Bool admitted, String field, String message)`.
Each diagnostic string has at most 8192 UTF-8 bytes and no embedded NUL. A
negative completion has no success snapshot/result. The common zero sentinel
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
mutation result, and bounded failure alternative. It uses actual requested
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
integration; this foundation does not establish a whole-request deadline.

## CPU codec evidence and remaining integration

On CPU 15, the Julia supervisor suite passes 197 assertions. The adjacent runner
codec and generic client suites pass 146 and 23 assertions. Forty-four shared
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
