# Native runner control prerequisite review

2026-10-05. Independent review of the
[runner request profile](NATIVE_RUNNER_CONTROL.md), closed dispatcher results
and native request codec. This is a Phase B prerequisite under RTC-ARCH-024 and
RTC-DEV-030. The inspected request schema and typed results have no remaining
confirmed correctness blocker for this prerequisite. They do not establish a
production native runner endpoint.

## Scope and baseline

Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls`.
Branch: `work/native-control-planes-20261005`. Starting revision:
`e57b2e5403bd8b90b6a2ebbaa7fbefe6c4ccfada`; the implementation owner reported a
clean starting tree. At the first source inspection, the owner's profile,
`src/native_runner_codec.rs`, `src/control.rs` and `src/main.rs` changes were in
progress. The reviewer changes only this review artifact.

The review compares the new profile and implementation with the existing
`Command` parser, parameter preparation, lifecycle dispatch and JSON result
semantics at that revision. The common envelope and local synchronization
prerequisite remain separate reviewed components. No deployment, scientific,
GPU or hardware campaign is part of this review.

## NRCR-001 — Runner encoder copies input before capacity rejection

Severity: Medium. Confidence: High. Evidence: observed source and focused
boundary tests. Disposition: addressed in the reviewed implementation.

The initial `src/native_runner_codec.rs::encode_request` clones command strings
and constructs an owned Id array before calling the common envelope encoder.
It also calls `decode_payload` to check its newly constructed values, which
copies them into another command. Thus a rejected property String, graph name,
schema, path or dimension vector can allocate in proportion to the unbounded
caller-owned input before the 16 KiB envelope check. The common codec's own
preflight cannot bound work already performed by this wrapper. The decoder
does validate the incoming envelope before constructing a command; this finding
concerns command encoding, not unbounded native ingress.

Required correction: calculate the encoded size from borrowed command fields
with checked arithmetic and reject oversized input before copying variable
data. Bound collection traversal too. Preserve exact acceptance at the native
envelope limit; do not impose an undocumented conservative byte limit. Keep
the existing common codec as the final serialized-envelope authority.

Required validation: oversized strings and Id arrays reject before owned POD
construction; arithmetic overflow rejects; a maximum-size valid request is
accepted and the next aligned size is rejected. Inspect source ordering in
addition to successful rejection tests, because rejection alone does not prove
bounded allocation.

The corrected encoder calls borrowed `preflight` before constructing owned
PODs. It checks header validity, collection size, checked aligned POD sizes and
aggregate size against an empty common envelope's exact encoded length. Shape
byte size and strings are checked before parameter extent validation, preventing
an oversized shape scan or a diagnostic containing an oversized unsupported
element-type string. Path byte length is checked before UTF-8 validation. The
remaining copies operate on a request already proven to fit 16 KiB.

The new padding test compares runner encoding with the common encoder across
small string padding transitions and every string length around the envelope
limit; successful bytes match exactly. Array cases cover small ranks and ranks
around the byte limit. Another test rejects oversized element types, paths and
a preallocated million-entry shape; the unsupported-type diagnostic remains
short. These tests pass. Source ordering establishes rejection before variable
input copies; no allocation benchmark or elapsed-time bound is claimed.

## Reviewed schema and compatibility decisions

- Operations 1 through 14 cover the existing command variants. CLI aliases
  such as `exit` and the single-property form normalize to the same typed
  commands and do not require extra wire operations. `PreparedParameter` is
  an internal prepared command and is correctly excluded from serialization.
- Exact POD arity and types preserve Bool, Int, Long, Float, Double, Id and
  String without JSON number inference. Finite Float/Double requests retain
  their bits, including negative zero. Strings are UTF-8 without embedded NUL;
  empty property values and schema strings remain allowed.
- Property updates require 1 through 42 records. The maximum retains the
  existing `2 + 3n ≤ 128` CLI bound. Duplicate names reject, and the decoded
  BTreeMap provides deterministic name order for canonical encoding. Owner
  validation still checks graph declarations and qualified `node:property`
  names before lifecycle effects.
- Parameter descriptors preserve F32_LE, positive nonempty dimensions, checked
  byte multiplication and the 512 MiB preparation maximum. The decoder opens
  no file. Existing preparation checks a regular non-symlink file, compares
  opened descriptor identity and byte extent, and owns the read bytes before
  dispatch. These checks do not prove stable contents against a concurrent
  writer; the profile correctly states that limit.
- Closed results reuse actual lifecycle, group, scalar and generation types.
  The dispatcher still performs the same validation, observations and Statig
  events in the same order. `legacy_json()` is an explicit compatibility
  renderer at the existing console/socket response boundary.
- The renderer preserves legacy field names, null observations and Float/Double
  bit representations. It also preserves `READY`/`RUNNING` for session stop/start
  and `Ready` for reset/source-ended. The status result retains the fresh
  discarded-by-sink observation rather than substituting a cached map.
- Outcomes retain their causal meaning: quit is accepted before cleanup, group
  changes are requested with an optional observation, session transitions reach
  the expected state, property adoption requires the existing running and
  generation-advancement predicate, and parameter updates remain submitted.
  Missing observations do not become zero or proof of adoption. Full-width
  unsigned discard counters remain in their domain types.

## Remaining endpoint obligations

These are required future integration gates, not implemented capabilities of
this prerequisite:

1. Publish the profile and native result schema with the 64 KiB completion
   bound. Preflight mutation completion capacity before effects and reject
   oversized query results without truncation.
2. Validate actual registry caller identity and endpoint incarnation before
   admission. A decoded header is not authorization. Correlate completion,
   rejection and duplicate detection using the full identity and canonical
   command payload; preserve floating-point bits in that canonical comparison.
3. Retain one pending request through preparation, execution and publication,
   alongside one terminal completion and one independent rejection. Stage
   bounded owned bytes/header data in callbacks; keep all blocking effects in
   the existing serialized dispatcher.
4. Establish one accepted absolute deadline covering preparation, effects and
   publication. The completed local sync fix alone does not supply this budget.
   Fence late preparation and caller disappearance before dispatch; preserve
   unknown outcomes for timed-out effects and document finite restoration.
5. Exercise two actual callers, busy/stale/duplicate requests, removed identities,
   queued expiry, late preparation, stalled-core effects, fresh queries, held
   startup and cleanup. Codec tests and synthetic identities do not satisfy
   these endpoint gates or the distinct scientific/allocation gates.

## Verification evidence

Reviewed source SHA-256:

| File | SHA-256 |
| --- | --- |
| `src/control.rs` | `cde16043a664fe76b85c40afc8f905297675bd9b4cca8be0deab4adba829db75` |
| `src/main.rs` | `35bb8209b386e0e3290f2533913b6d62c10d57ee2b37af3c3bf86a1a92a2b7ab` |
| `src/native_runner_codec.rs` | `f887e9d1d461692ec5c385f6b2b8e9fa464ceb3c4ceb956acfe5f2e123b8bbee` |
| `docs/NATIVE_RUNNER_CONTROL.md` | `d55fcc314f5e89709ff9cd0a02fcc77e084152ebc8fc7b7fdef059264923c1de` |

The reviewer inspected source and implementation-owner logs under
`~/.cache/rtc-live-controls-20261005`:

- `native-runner-typed-bin-test.log`: 38 passed, zero failed, one ignored.
  This includes eight request-codec groups and eight golden-result groups.
  The ignored test requires a private scientific deployment and was not run.
- The request tests cover all 14 operations, seven scalar types, exact numeric
  bits, arity/type/name errors, nonfinite values, duplicate properties, canonical
  ordering, transaction/byte/shape limits, overflow and every truncation of a
  valid empty-payload request. A nonexistent artifact path round-trips without
  opening it.
- Golden results cover all result variants and outcomes, optional observations,
  empty catalogs, lifecycle labels, unsigned maxima, signed extrema and exact
  Float/Double bits. Their expected JSON was checked against the baseline
  dispatcher. These renderer checks do not exercise scientific effects.
- The earlier `native-runner-typed-results-test.log` and corresponding summary
  record 36 passing tests before the final two preflight test groups. They are
  intermediate evidence, not the final codec count.
- `native-runner-typed-rust-regression.log`: independently summed 13 result
  sections, 163 passed, zero failed, four ignored. The ignored cases require
  private-core or scientific fixtures; no such campaign was run for this
  prerequisite.
- `native-runner-typed-clippy.log`: strict binary and library Clippy passes.
  The existing `proc-macro-error2 v2.0.1` future-incompatibility warning remains.
  This final log supersedes the earlier failed lint attempt while the codec
  was being edited. `native-runner-typed-format.log` is empty on successful
  formatting validation. The reviewer also checked diff whitespace, review
  links and final newline.

Final log SHA-256:

| Log | SHA-256 |
| --- | --- |
| `native-runner-typed-bin-test.log` | `ac0ad742c9bc91cc064e3002d27a10292e1a2c06f11e83db6c8622c316bcb6c4` |
| `native-runner-typed-rust-regression.log` | `ec5022e9b06a93da811c177b987753426925b6ddd6c9650fa591a648e81126e2` |
| `native-runner-typed-clippy.log` | `1e74afc12baacfdf235414a2b3349b6ecc4642db0296ddbbc3cdef6398b2f875` |
| `native-runner-typed-format.log` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

No confirmed blocker remains for committing the request codec and typed-result
prerequisite. No production endpoint, whole-request timing, installed deployment
or scientific qualification is claimed.
