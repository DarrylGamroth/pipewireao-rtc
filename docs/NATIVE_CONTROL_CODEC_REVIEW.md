# Native control codec review

2026-10-05. Independent review of the fixed common envelope implementation,
before production owner integration. The fixed header plus owner-specific payload
boundary is appropriately narrow. One confirmed Julia encoder capacity-check
ordering defect was corrected during review and passed the same focused check.
No unresolved confirmed correctness defect remains in the reviewed codec logic.

## Reviewed state and scope

Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls`;
branch `work/native-control-planes-20261005`; starting RTC commit
`74099a2861ed7d60789a38c0f3ad4121b029bf48`. Codec files and the envelope document
were new, uncommitted primary/worker changes. This reviewer owns only this review
artifact and made no production changes.

Final reviewed source SHA-256:

| File | SHA-256 |
| --- | --- |
| `src/native_control_codec.rs` | `44c72ef1087fcf597239366fe6b272efe88c59ae279208e94e5e981866ce9d40` |
| `deployment/julia/src/native_control_codec.jl` | `bc1dff7a12ee132a67b135acdb2787188d4206bd54af6aa9017f1b19ca5b363c` |
| `examples/native_control_envelope_proof.rs` | `8b157777129a165481f16e54925c268d26756596317a418bd97ba8310ce923dc` |
| `deployment/julia/test/native_control_envelope_proof.jl` | `ba6d589a1250c8fd3a085a5cf19a010f0dd6ea52d2f94b44c03e8a20a985b14d` |

Reviewed files:

- [Envelope contract](NATIVE_CONTROL_ENVELOPE.md).
- [Rust codec](https://github.com/DarrylGamroth/pipewireao-rtc/blob/0fadb2a116f360df7f7d601b8e7f2bea02d809f9/src/native_control_codec.rs) and its embedded unit tests.
- [Julia codec](../deployment/julia/src/native_control_codec.jl) and
  [unit tests](../deployment/julia/test/test_native_control_codec.jl).
- Rust `src/lib.rs` feature-gated exposure and Julia package/test-suite inclusion.
- [Common-envelope diagnostic owner](../examples/native_control_envelope_proof.rs)
  and [Julia fixture](../deployment/julia/test/native_control_envelope_proof.jl).
- Relevant public POD ownership/parsing implementations in canonical PipeWireAO
  0.6.16 and the pinned Rust SDK revision
  `f2d86899328465e9b97ccbfb4b10d0b243749171`.

The existing [migration review](NATIVE_CONTROL_MIGRATION_REVIEW.md) remains
applicable to owner integration. This review does not replace its pending
deadline, caller-disappearance, restoration or deployment gates.

## NCMC-001 — Julia validates oversized payloads before checking the envelope cap

Severity: Medium. Confidence: High. Evidence: observed source ordering and
reproduced allocation behavior. Disposition: corrected by the primary agent;
independent same-fixture pass-after and exact-bound checks complete.

At the initial reviewed revision, `_envelope` calls `_validate_payload(payload)` before
`_envelope_size(...) <= limit`. The validator calls public `pod_value(SPA.Bytes,
...)` and `pod_value(SPA.Array, ...)`; these copy the byte payload or allocate the
decoded array. The top-level encode cap therefore rejects only after potentially
large additional allocation. The same ordering traverses every supplied child
before rejecting a wide payload.

This is an outgoing cold-encoder defect, not a demonstrated unbounded remote
decoder or a scientific hot-path regression. Input PODs already exist, and the
SDK caps each individual POD body below 1 MiB, but the codec must still enforce
its smaller request/reply bound before further payload decoding/copying.

Fail-before experiment: direct-load the Julia codec and canonical public PWA on
CPU 14; construct a valid request header and a Struct containing an already-built
512 KiB `SPA.Bytes` POD. Warm the rejection path, then measure only
`@allocated reject(header, payload)`, where `reject` calls `encode_request` and
catches `ArgumentError`. Result: request rejected, **527,576 bytes allocated**
despite the 16 KiB request limit. An initial 4 MiB fixture was rejected by the
SDK constructor before reaching the codec; it is not evidence about codec
allocation. No scientific or GPU work ran.

Required correction: calculate the encoded size and enforce the selected cap
before `_validate_payload` or any payload materialization. Use checked arithmetic
and stop as soon as accumulated size exceeds the cap; do not traverse an
arbitrarily wide already-invalid payload merely to compute a final sum. Keep the
final encoded-size check. Rust already computes bounded size before cloning its
payload tree and invoking the serializer.

Pass-after: the revised `_envelope` checks size before `_validate_payload` and
uses capped incremental arithmetic. The same warmed 512 KiB fixture still rejects
and now allocates **3,216 bytes**, eliminating the payload-sized copy. Independent
Julia checks also constructed exact 16,384-, 65,536- and 131,072-byte envelopes:
all three accepted, and adding one payload byte to each rejected. The payload
byte count was `limit − sizeof(encoded empty payload) − 8`, accounting for its
Bytes POD header. Existing tests cover ordinary payloads; the primary agent added
an oversized-array rejection case. The measured before/after fixture is the
discriminating regression evidence for validation order. This correction does
not impose a zero-allocation requirement on cold control encoding.

The final Julia source adds exact child-POD length checks and handles the input
byte vector's starting index explicitly. Inspection confirms capacity preflight
still precedes payload validation, so the NCMC-001 correction remains present.

## NCMC-002 — Fixture failure cleanup was not bounded by its stated five seconds

Severity: Low. Confidence: High. Evidence: observed source and documentation
discrepancy. Disposition: primary agent accepted; fixture correction and final
normal-path repeat pending at initial finding. The revised cleanup helper was
subsequently inspected and the source defect is corrected. Final normal-path
repeat is owned by the validation agent; no fault-injected cleanup claim follows.

The initial Julia fixture's `finally` paths called default `kill` (SIGTERM) and
then unconditional `wait` for both the daemon and owner. The owner had a five-second
grace wait before SIGTERM, but no bound afterward; the daemon had no exit wait
deadline. The reproduction command's external timeout bounds the overall test
process, not these cleanup functions. Thus the validation statement claiming
finite daemon/child cleanup was stronger than the implementation.

Required correction: use a bounded failure cleanup helper with explicit process
exit observation and escalation, and call `wait` only after observing exit.
State successful node removal/child exit as normal-path observations; fault
cleanup timing and production cleanup qualification remain separate. This is a
diagnostic harness issue, not a defect in the common codec or evidence of a
failed successful-run cleanup.

Correction inspected: `stop_proof_child!` checks process exit, sends SIGTERM and
waits at most five seconds, then escalates to SIGKILL with a separate five-second
exit observation. Failure to observe exit raises an error; unconditional `wait`
is reached only after exit was observed. Both daemon and owner failure cleanup
use this helper. The main successful owner path already observes exit before
calling `wait`.

## Verified design and implementation properties

1. Both implementations encode one standard Props object, one flags-zero params
   property, four ordered children and eight exact header children. Wrong names,
   arity, property flags, outer object identity, header scalar widths and extra
   trailing bytes reject. The request/reply eighth-field type distinction is
   explicit: Long budget versus Int result.
2. Rust checks the complete input byte cap and validates raw POD spans, scalar
   widths, array element sizes/divisibility, strings and recursive depth before
   `PodDeserializer::deserialize_any_from`. Checked offset arithmetic prevents
   enclosing-span escapes. Its allowlist excludes recursive Object/Choice and
   pointer/FD payloads before the generic decoder can inspect them.
3. Julia's public `pod_value(SPA.Object, ...)` and `pod_value(SPA.Struct, ...)`
   parse one container level and return owned child PODs; they do not recursively
   deserialize the whole tree. `_check_payload` controls recursion and rejects
   the ninth Struct level before descending into it. It is therefore appropriate
   to use these public parsers after the complete input-byte bound. The scalar
   Bool wire size is four bytes, and leaf values do not add a Struct level.
4. The payload allowlists agree on None, Bool, Id, Int, Long, Float, Double,
   String, Bytes, the six supported scalar-array types and bounded Structs.
   Rectangle/Fraction/FD arrays and other native types remain excluded. UTF-8
   validity and absence of embedded String terminators are checked.
5. Controller serial encoding preserves all UInt64 bits, including signed-negative
   Long representations. The decoded identity tests unsigned serial positivity;
   instance, token and budget retain their separate signed-positive checks.
   Neither zero nor invalid global ID is admitted as a correlated identity.
6. The completion sentinel and uncorrelated rejection require an entirely zero
   controller/token/operation tuple. Successful rejection, negative-result initial
   completion and partial-zero identities reject. Owner instance/version remain
   valid even in sentinel records. These rules cannot themselves make a sentinel
   satisfy a fresh request.
7. Decoders return owned values. Rust builds owned `Value` storage; Julia's public
   POD constructor/container readers copy child storage. Borrowed callback bytes
   need not survive after decode. No codec retains a native pointer.
8. Scientific float finiteness, exact operation arity/counts, controller registry
   validation and actual operation selection remain explicit owner obligations.
   The generic codec's acceptance of native Float/Double values is not a claim
   that NaN/infinity are scientifically valid. Unknown operation IDs cannot be
   rejected generically before an owner profile defines them.
9. Package exposure adds a callable codec module, not a dispatcher, broker,
   runtime registry, scientific callback or transport fallback. The existing
   prepared source-control implementation remains outside this change.

## Required integration evidence and limits

The codec supplies data representation only. Pending-slot ownership, controller
lifetime verification, global token ordering, busy/collision/stale rejection,
canonical-payload duplicate comparison, fresh-query matching and terminal
publication still require the existing owner's serialized adapter. In particular,
Rust's derived numeric `PartialEq` is not a defined bitwise canonical scientific
payload comparison; the future owner must implement the canonicalization rule
it actually declares. No current dispatcher uses this equality for deduplication,
so this is an integration obligation, not a demonstrated defect.

The diagnostic zero-port Filter's reported 30/30 mechanism assertions use its
own scalar schema. The actual common-envelope fixture now separately records
42/42 assertions, including UInt64-max controller serial, initial/uncorrelated
sentinels, owned native payload, staged-without-ACK state, one adoption, identical
replay, a different-controller token collision, fresh query, unsupported-operation
rejection and normal node/process removal. The review inspected the native log
and fixture source; the execution was performed by the primary/validation agents.

The diagnostic owner has one pending slot and keeps it occupied until completion
publication succeeds. Its callback validates/decodes the bounded envelope and
stores owned encoded payload bytes to satisfy the SDK callback's Send bound;
no unsafe Send implementation is introduced. Exact diagnostic payload evaluation,
counter adoption, fixture marker writes and publication happen after callback
return. Full request identity and canonical encoded payload participate in
duplicate comparison; changing the remaining budget does not extend an already
accepted request's deadline.

The client sends synthetic controller IDs 42 and 43 over one native connection.
These values test codec/correlation behavior, not actual registry caller identity,
authentication, two concurrent client connections or controller disappearance.
The owner PID/global ID/object serial are observed against the real spawned
process. Empty adoption/quit markers and the owner-ready PID file synchronize
only the fixture; all request/result fields use native parameters/events. The
diagnostic APPLY/QUERY IDs belong to the explicit diagnostic profile.

The published unit evidence contains 66 focused Julia assertions and ten Rust
test groups, including malformed lengths and empty arrays of all supported
scalar types. These language-local checks plus the native fixture are sufficient
evidence for the shared codec increment. They do not establish the production
runner's finite synchronization, actual caller lifetime, calibration restoration,
installed science/allocation regression or hardware/cadence qualification.

The inspected `native-control-envelope-proof-final.log` reports 42/42 in 5.3 s,
owner PID 3205198 and client PID 3205166, five callbacks and one adoption. This
run predates the failure-cleanup helper correction; its normal-path observations
remain evidence while a final-source repeat is completed separately. Existing
diagnostic logs remain under `~/.cache/rtc-live-controls-20261005`; see the
[validation record](NATIVE_CONTROL_ENVELOPE_VALIDATION.md) for maintained results.

Final scope assessment: no confirmed blocker remains for committing the shared
codec layer. The active documents preserve the completed source schemas, identify
remaining JSON transports as migration debt, and keep production owner integration
separate. This review does not approve copying the diagnostic caller identities,
marker coordination or simplified operation handler into production controls.

The primary/implementation agents own broad suite execution and the native
fixture. This reviewer ran only the focused NCMC-001 before/after diagnostic and
three exact-cap boundary checks described above, and inspected existing test
coverage. No full deployment, GPU workload or hardware check was run during
this review.
