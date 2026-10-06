# Native runner control profile

2026-10-05. Phase B of
[the migration design](NATIVE_CONTROL_MIGRATION_DESIGN.md), under
RTC-ARCH-024 / RTC-DEV-030. Worktree `pipewireao-rtc-native-controls`, branch
`work/native-control-planes-20261005`, starting revision
`e57b2e5403bd8b90b6a2ebbaa7fbefe6c4ccfada`; the starting tree was clean.

## Scope and implementation boundary

The profile replaces the runner's local socket framing, not `Runner`, Statig,
graph ownership, scientific algorithms, or graph run/reset serializers.
Commands and results are closed Rust types. Native encoding matches their
variants explicitly; it does not translate arbitrary JSON maps, embed JSON
strings, or infer scalar types from JSON numbers. Existing CLI/socket rendering
remains an explicit legacy boundary until production callers migrate.

This document specifies the selected request and result schemas and the
implemented native runner endpoint. The two-caller private-core fixture
qualifies normal admission, query, lifecycle, duplicate/rejection, caller
removal and exit behavior. Remaining deadline/preparation gates are recorded
separately in [endpoint validation](NATIVE_RUNNER_ENDPOINT_VALIDATION.md).
The [supervisor client](NATIVE_RUNNER_CLIENT_VALIDATION.md) is implemented and
has focused CPU caller evidence; other live control owners still require migration.
No installed scientific or frame-latency claim follows from these cold control
checks.

## Requests

Advertisement profile: `pipewireao.rtc.runner/1`. Requests use the
[common envelope](NATIVE_CONTROL_ENVELOPE.md), including its exact incarnation,
caller identity, positive token, relative remaining budget and 16 KiB bound.
The operation Id selects one exact payload Struct; extra fields are invalid.

| Operation Id | Command | Payload fields, in order |
| --- | --- | --- |
| 1 | Quit | Empty Struct |
| 2 | Groups | Empty Struct |
| 3 | Status | Empty Struct |
| 4 | Properties | String graph |
| 5 | Property generation | String graph, String node |
| 6 | Parameter generation | String graph, String node |
| 7 | Stop group | String group |
| 8 | Start group | String group |
| 9 | Stop session | Empty Struct |
| 10 | Start session | Empty Struct |
| 11 | Source ended | Empty Struct |
| 12 | Reset | Empty Struct |
| 13 | Set properties | String graph, Struct of property records |
| 14 | Prepare and set parameter | String graph, String parameter, String element type, Array of Id dimensions, String schema, String artifact path |

Each property record is exactly `Struct(String qualified_name, scalar_value)`.
Allowed scalar POD types are Bool, Int, Long, Float, Double, Id and String;
the POD type itself carries the scientific property type. Float and Double
requests must be finite, and their bit patterns (including negative zero) are
preserved. Names are nonempty UTF-8 strings without embedded NUL. String property
values and schemas may be empty. Duplicate property names are rejected before
preparation or effects; canonical encoding sorts records by name. The property
transaction limit is 1 through 42 records, retaining the existing CLI's 128-field bound
(`properties-set`, graph, three fields per property). The envelope additionally
bounds bytes, string length, depth and total input work.

Parameter requests retain the existing artifact preparation boundary:
the path names persisted ndarray input, not a live request/reply or status file.
The codec does not open that path. The existing preparation code verifies a
regular non-symlink file, descriptor identity and exact byte extent, then owns
the read bytes before dispatch. This is not a cryptographic immutability proof
against concurrent writers. Element type remains `F32_LE`; shape is nonempty
with positive dimensions, checked byte arithmetic and the existing 512 MiB
maximum. The native request carries the small descriptor, not a 512 MiB POD.
`PreparedParameter` is an internal command and has no request encoding.

Unknown operations, wrong arity/types, nonfinite property values, duplicate
properties, invalid shape/extent and oversized envelopes are rejected before
filesystem preparation or lifecycle effects. A decoded request has no authority
by itself: endpoint and actual registry incarnation validation are required
before admission.

## Result semantics to retain

The dispatcher produces typed records for shutdown, group and status snapshots,
property snapshots, property/parameter generations, group requests, session
completion, property adoption observations and parameter submission. No generic
JSON value is the dispatcher's result authority. The legacy renderer retains
the existing field names, null observations and Float/Double bit representations.

| Result | Existing semantics that native completion must preserve |
| --- | --- |
| Shutdown | Accepted request; cleanup occurs after dispatch, not before this result |
| Groups/status/properties/generations | Observed snapshots, not mutation completion |
| Group start/stop | Requested and observed group state; lifecycle is preserved |
| Session start/stop/reset/source-ended | Expected lifecycle reached after existing effects |
| Property update | Active only when all affected generation observations establish adoption while running; otherwise submitted |
| Parameter update | Submitted, not active; optional observed parameter generation does not establish adoption |

Property generations have optional active values. Parameter generations have
nonoptional requested/active values, but the entire post-submission observation
may be absent. Keep these distinct. Status counters use full-width unsigned
values, while generation fields preserve their existing signed Long semantics.
Native result encoding must bound configured group/sink/property catalogs and
variable strings to the 64 KiB envelope. Mutation completion capacity must be
checked before effects. Query oversize is a truthful rejection, not truncation.

## Endpoint integration contract

The integration below started at clean revision `0377007`; its CPU software
evidence is separate from the preceding codec prerequisites.

### Native results

Successful completion payload is exactly
`Struct(Id lifecycle, Id outcome, Struct operation_details)`. Lifecycle IDs are
Offline=1, Configuring=2, Ready=3, Running=4, Fault=5. Outcome IDs are
Accepted=1, Observed=2, Requested=3, Completed=4, Active=5, Submitted=6.
The header's operation selects the exact detail schema below. Scalar property
snapshots preserve Float/Double bits, including nonfinite diagnostic values;
the finite request rule remains separate.

| Operation | Details, in order |
| --- | --- |
| 1 | Bool shutdown=true |
| 2 | Struct of group records: Struct(String name, Id group state) |
| 3 | Bool running, Long owned nodes, Long owned links, Long discarded buffers, Struct of sink records: Struct(String name, Long discarded count) |
| 4 | String graph, Struct of property records: Struct(String qualified name, scalar) |
| 5 | String graph, String node, Long requested, Long active or None |
| 6 | String graph, String node, Long requested, Long active |
| 7, 8 | String group, Id requested group state, Id observed group state or None |
| 9–12 | Id completed lifecycle |
| 13 | String graph, Struct of observations: Struct(String node, Long requested or None, Long active or None), Bool active adoption observed |
| 14 | String graph, String parameter, Struct(Long requested, Long active) or None, Bool active adoption observed=false |

Group state IDs are Stopped=1, Running=2. Counter Longs preserve UInt64 bit
patterns, with checked conversion for platform-sized node/link counts. Generations
retain signed Int64. Requested None with active Long is invalid; complete property
observation absence is two None values. Requested group state, outcome and
completed lifecycle must agree with operation and producer invariants. No JSON
value is inferred or embedded, and no query catalog is silently truncated.

An accepted operation failure is a negative-result terminal completion with
exact payload `Struct(String field, String message, Id lifecycle)`. Admission
failure uses the same payload as an independent negative-result rejection.
Oversized error diagnostics use a short truthful capacity diagnostic. The
initial operation-zero sentinel is not a fresh operation completion.

### Advertisement, callers and bounded admission

Endpoint NodeInfo properties are `pipewireao.rtc-control.protocol` =
`pipewireao.rtc-control/1`, `pipewireao.rtc-control.profile` =
`pipewireao.rtc.runner/1`, positive `pipewireao.rtc-control.instance`, and
`pipewireao.rtc-control.owner-pid`. Node name and actual `object.serial` also
identify the endpoint. Native mode takes `--control-node NAME`,
`--control-instance POSITIVE`, an explicit absolute private `--remote` and
`--start-paused`. It is mutually exclusive with socket ingress and console
submission; there is no fallback.

A caller exports an inactive no-port Node named
`pipewireao.rtc.controller.<caller suffix>` on its actual connection, with the
same protocol, profile `pipewireao.rtc.controller/1`, caller instance and PID.
The owner binds that actual Node and validates NodeInfo metadata against the
registry's global ID/object.serial. Custom properties are not assumed to appear
in global announcements. Bound-node and registry removal fence the incarnation.
This supplies lifetime/correlation on the user's private core; it is not
authentication against another process of that same user.

At most 32 candidate controller markers are bound, including pending NodeInfo.
This is a cold control resource limit, not a frame queue or a throughput claim.
Silent or invalid candidates retain their slot until removal. Announcements
received at capacity are ignored, not queued or automatically promoted. A new
marker after capacity becomes available can obtain admission. A bounded
capability Props record publishes verified caller identity records so clients
can wait for their marker's admission before their first operation, without
speculative request retries. This is bootstrap metadata, not a fresh query.

Capability fields are version Int=1, endpoint instance Long, owner PID Id,
lifecycle Id, last accepted token Long, and Struct of verified caller records
`Struct(Id global, Long unsigned serial bits, Long caller instance)` under names
`pipewireao.rtc.runner.{version,instance,owner-pid,lifecycle,last-token,controllers}`.
Every Props publication includes capability, terminal completion and independent
rejection. The request/reply envelope namespaces remain unchanged.

Matching duplicates of the accepted or last terminal request keep the original
outcome. Changed payload/operation or a different caller cannot claim it. A newer
accepted token makes older tokens stale even when the newer request fails.
Admission errors do not advance the accepted token or replace terminal completion.
Removal observed at the owner's pre-dispatch check produces a terminal failure
without effects. Removal observed during effects yields truthful failure/unknown
outcome and cannot roll back applied effects. Sync/checks establish observed
ordering; they cannot make remote removal and an effect atomic.

### Execution, preparation and budgets

One inactive no-port Filter belongs to the existing adapter Core/main loop.
One pending request remains occupied through preparation, execution and terminal
publication; one terminal completion and one independent rejection are retained.
Callback storage is copied only after envelope bounds; callbacks stage an owned
typed command plus a concrete header, never `spa::pod::Value` across threads (that enum
is not Send). Blocking effects stay in the existing sole dispatcher.

Admission must validate the actual caller registry marker, endpoint incarnation,
canonical payload and token rules. The accepted absolute deadline covers
preparation, all effects and publication; nested synchronization inherits the
remaining deadline.

A single cold preparation worker stages one parameter file with one job slot and
one result slot. It performs existing regular-file preparation; the owner does
not block waiting for it. Expiry/removal fences the result before dispatch. An
abandoned preparation consumes its worker slot until it returns and rejects
another parameter preparation; other controls may proceed after its accepted
slot has failed. Cleanup does not join potentially blocked filesystem I/O. The
worker cannot touch Runner or science and terminates with its supervised process.
Filesystem operations are not a hard real-time/preemptible claim.

Required-object monitoring continues while preparation is pending and precedes
prepared-result dispatch when due. It inherits an accepted request's deadline,
including a request still queued for dispatch. Expired or removed queued requests
are retired before monitoring. During an independent maintenance check, new
reentrant admissions receive Busy without advancing the accepted token. A
request-budget expiry fails that request and discards the sampled health
observation; it does not itself establish a required-object fault. Subsequent
maintenance resumes with its own budget. A genuine observed object failure still
uses the existing lifecycle dispatcher and fences a late preparation result.

Owner request budgets are capped at 30 seconds. Admission starts one absolute
owner deadline; client absolute deadlines remain authoritative. Before execution
and publication, check expiry and caller lifetime; nested adapter synchronization
inherits that deadline. Successful local publication must fit the remaining budget, while
asynchronous notification does not prove remote observation. In-flight expiry
retains unknown outcome without rollback. Timeout still makes one bounded,
nonwaiting negative terminal-publication attempt after expiry; publication
failure faults the endpoint. Stop and Unload share one separate five-second
adapter deadline and release local resources even if remote removal is unconfirmed.
The destructor does not start another synchronization scope after those handles
have already been released.

Mutation reply capacity is preflighted from command identity and worst-case
optional generation records before preparation/effects. Queries encode their
actual observation after reading it and reject oversize without truncation;
these observations perform no scientific operation.

Required integration evidence includes two actual callers, busy/stale/duplicate
handling, removed controller/owner, queued expiry, stalled-core effects, late
preparation completion, fresh queries, held startup and finite cleanup. Diagnostic
synthetic identities and successful serialization do not satisfy these gates.
