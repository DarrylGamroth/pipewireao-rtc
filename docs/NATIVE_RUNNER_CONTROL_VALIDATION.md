# Native runner control prerequisite validation

2026-10-05. Phase B software evidence for the
[request profile](NATIVE_RUNNER_CONTROL.md) and
[independent review](NATIVE_RUNNER_CONTROL_REVIEW.md). Starting clean revision
`e57b2e5403bd8b90b6a2ebbaa7fbefe6c4ccfada`, branch
`work/native-control-planes-20261005`, worktree `pipewireao-rtc-native-controls`.

## Changes and scope

`src/control.rs::Command::execute` now returns closed typed result records using
the existing lifecycle, group, scalar, status and generation types. It invokes
the same validations, observations and lifecycle events in the same order.
`ExecutionResult::outcome()` derives the outcome; `legacy_json()` renders only
at the existing console/socket response boundary. The legacy socket transport
still exists and is explicitly unmigrated.

`src/native_runner_codec.rs` encodes and decodes the exact 14-operation request
profile through the reviewed common envelope. It performs no artifact I/O,
registry admission or lifecycle execution. The module is compiled in the
binary with a documented temporary dead-code allowance until endpoint wiring.
There is no production native runner endpoint in this increment.

The HEART wrapper and all scientific/frame paths are unchanged. Its reset/status
files and live health-report reads remain migration debt, as recorded in the
[inventory recheck](LIVE_CONTROL_INVENTORY.md#heart-boundary-recheck).

## Verification

Commands use the existing cache `native-filter-target`, CPU 14, offline locked
dependencies, feature `live`, installed `/opt/pipewireao` pkg-config/library
paths, one bounded process timeout and no fresh release or GPU build.

| Check | Result | Evidence |
| --- | --- | --- |
| Focused binary tests | 38 passed, zero failed, one existing scientific/private-core fixture ignored | `native-runner-typed-bin-test.log` |
| Full live Rust regression | 163 passed, zero failed, four existing fixtures ignored | `native-runner-typed-rust-regression.log`, matching summary JSON |
| Strict binary and library Clippy | Passed with `-D warnings` | `native-runner-typed-clippy.log` |
| Formatting | Passed | `native-runner-typed-format.log` |

The primary agent independently reran the full live suite against the same
source: 163 passed, zero failed and four ignored across 13 result sections.
`native-runner-root-regression.log` has SHA-256
`fab9a1ea91f50b62815162c2772fbe1cb4e98eaa67e68d82b773444a82e37650`.
The final diff and reviewed source hashes were checked independently of the
implementation worker's report.

Evidence directory:
`/home/dgamroth/.cache/rtc-live-controls-20261005`. An existing dependency
future-incompatibility note for `proc-macro-error2` 2.0.1 remains; it is not a
new project lint or a failing test. The full suite does not run the four
ignored scheduler/scientific/private-core fixtures. The synchronization fixture
was qualified separately in the
[prior sync evidence](NATIVE_CONTROL_SYNC_VALIDATION.md); it is not rerun here.

Eight golden-result test groups cover all 13 result variants, six outcomes,
seven scalar variants, optional generation observations, empty collections,
full-width unsigned counters, signed generations and command-specific state
capitalization. Float/Double rendering preserves exact bits, including negative
zero and NaN bit patterns, rather than interpreting them as JSON numbers.

Eight request-codec test groups cover all operations, UInt64-max controller
serial, seven native scalar types, finite property requests, negative-zero
bits, exact types/arity, unknown operations, duplicate names, canonical property
ordering, 42-record admission and 43-record rejection, positive F32_LE dimensions,
extent overflow, exactly 512 MiB declared parameter extent and one element over.
Every truncated prefix of a valid status request rejects. The artifact path in
round-trip tests need not exist: the codec does not open it.

## Encoder capacity correction

NRCR-001 was observed in the initial source: encoding cloned command strings
and built an owned dimension array before the common encoder rejected excess
capacity. The correction preflights borrowed fields with checked native size
arithmetic before constructing variable-size POD values. Shape and path byte
bounds precede traversal/UTF-8 conversion; oversized element types are rejected
before the existing formatted diagnostic can copy them.

The boundary test compares acceptance and successful bytes with the actual
common SPA encoder for 561 string lengths across alignment and the 16 KiB
boundary, plus 11 dimension-array ranks. Additional tests exercise oversized
paths/types and a caller-owned million-element shape. Source ordering and these
software checks establish the preflight correction; no heap-allocation
measurement or steady-state zero-allocation claim is made for this cold path.

Documentation checks cover local links/anchors, whitespace/final newlines and
unique active/archive requirement definitions. The changed roadmap Mermaid
document was rendered with the local CLI image, no network, a read-only source
mount and CPU 14; its output matches the current source and is a valid SVG.

## Source identities

| File | SHA-256 |
| --- | --- |
| `src/control.rs` | `cde16043a664fe76b85c40afc8f905297675bd9b4cca8be0deab4adba829db75` |
| `src/main.rs` | `35bb8209b386e0e3290f2533913b6d62c10d57ee2b37af3c3bf86a1a92a2b7ab` |
| `src/native_runner_codec.rs` | `f887e9d1d461692ec5c385f6b2b8e9fa464ceb3c4ceb956acfe5f2e123b8bbee` |
| `native-runner-typed-bin-test.log` | `ac0ad742c9bc91cc064e3002d27a10292e1a2c06f11e83db6c8622c316bcb6c4` |

## Remaining gates

Production endpoint admission, native result encoding/capacity preflight,
one-pending-slot ownership, real registry-bound callers, whole-request deadline
propagation and supervisor migration remain open. These tests establish software
codec/compatibility behavior, not native end-to-end control, installed science,
frame latency, hard real-time behavior or hardware validation.
