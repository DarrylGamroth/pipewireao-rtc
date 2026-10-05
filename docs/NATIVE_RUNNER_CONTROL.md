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

This document specifies the selected request schema. The typed result records
and request codec are a prerequisite, not evidence that the production endpoint,
registry-bound caller authority, or supervisor client has migrated. Endpoint
admission, result wire schema and whole-request execution qualification remain
open. No installed scientific or latency claim follows from codec tests.

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

## Pending endpoint integration

One inactive no-port Filter belongs to the existing adapter Core/main loop.
One pending request remains occupied through preparation, execution and terminal
publication; one terminal completion and one independent rejection are retained.
Callback storage is copied only after envelope bounds; callbacks stage owned
bytes plus a concrete header, never `spa::pod::Value` across threads (that enum
is not Send). Blocking effects stay in the existing sole dispatcher.

Admission must validate the actual caller registry marker, endpoint incarnation,
canonical payload and token rules. The accepted absolute deadline covers
preparation, all effects and publication; nested synchronization inherits the
remaining deadline. A bounded preparation worker may stage one parameter file;
it must not create an unbounded queue or allow expiry/disconnect to dispatch its
late result. A timed-out in-flight operation retains unknown outcome and must
not claim rollback. Restoration/cleanup has a separate documented finite budget.

Required integration evidence includes two actual callers, busy/stale/duplicate
handling, removed controller/owner, queued expiry, stalled-core effects, late
preparation completion, fresh queries, held startup and finite cleanup. Diagnostic
synthetic identities and successful serialization do not satisfy these gates.
