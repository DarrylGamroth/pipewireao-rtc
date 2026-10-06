# Native calibration action codec foundation

This phase E foundation implements the pure Julia and Rust profile
`pipewireao.rtc.calibration-actions/1` under RTC-ARCH-024 / RTC-DEV-030. It does
not migrate an owner, action server, Rust endpoint, campaign client, deployed
profile or export. Issue #7 remains open. The existing effect implementation,
restoration fencing and scientific acquisition behavior remain authoritative.

The [action inventory](NATIVE_CALIBRATION_ACTION_WIRE_INVENTORY.md),
[common envelope](NATIVE_CONTROL_ENVELOPE.md) and
[acquisition lifecycle](NATIVE_ACQUISITION_LIFECYCLE_CONTROL.md) define the
prior boundaries. This document specifies only the selected action payload.
The common envelope bounds the complete request to 16 KiB and the complete
calibration completion or rejection to 128 KiB. Native integer widths, array
child widths, padded extents, exact arity, strings and container grammar are
validated through that envelope before typed decoding. No JSON text is carried
inside a POD.

## Requests

Envelope operation IDs and exact args Struct fields are:

| ID | Action | Args Struct fields in order |
| --- | --- | --- |
| 1 | Hold | empty |
| 2 | Adopt | probe Id, figure Float Array |
| 3 | Settle | probe Id, cursor Struct, rule Struct |
| 4 | Collect | probe Id, cursor Struct, measurements Id, frames Id |
| 5 | Capture | probe Id, cursor Struct, frames Id |
| 6 | Restore | figure Float Array, rule Struct |
| 7 | Release | empty |

Every request payload is exactly `Struct(run Long, serial Long, args Struct)`.
Run and serial are positive UInt64 identities represented as SPA Long bit
patterns. The common request header supplies the positive bounded Int64
relative budget; payload identities do not replace common controller/token
correlation.

A cursor is exactly four Long fields: domain, generation, sequence, model_ns.
All identities preserve UInt64 bit patterns. Domain and generation are positive;
sequence may be zero; model_ns is in 0…Int64 max. This action time bound is
narrower than the lifecycle snapshot cursor, which retains all UInt64 model
bits. The codecs do not enforce owner-specific cursor equality or sequencing.

| Rule ID | Exact rule Struct |
| --- | --- |
| 1 | Immediate: Id(1) |
| 2 | DiscardExposures: Id(2), frames Id |
| 3 | ModelTime: Id(3), positive duration Long ≤ Int64 max |

Probe is in 0…16,383; frames in 1…4,096; measurements in 1…131,072. Figures
are nonempty finite Float32 arrays with a logical limit of 4,096 elements.
The complete 16 KiB wire limit applies additionally, so a logical maximum
figure can exceed encoded capacity. Encoder preflight inspects borrowed arrays
and computes their padded extent before constructing or copying array PODs.
An owner still validates its exact command and measurement contracts before
any action effect.

## Completions and rejections

Every correlated action completion payload is exactly:

```text
Struct(lifecycle Id, run Long, serial Long, result Struct or None, message String)
```

Lifecycle IDs reuse the cold lifecycle: Preparing=1, Prepared=2, Connected=3,
Fault=4, Stopped=5. There is no additional SCI phase state machine in this codec.
Run and serial are positive UInt64 bit patterns. UTF-8 messages contain no NUL
and at most 8,192 bytes. Unknown lifecycle, result and reason IDs reject.

| Result ID | Exact result Struct fields |
| --- | --- |
| 1 | Held: Id(1), cursor Struct |
| 2 | Adopted: Id(2), cursor Struct, figure Float Array, clipped Bool |
| 3 | Settled: Id(3), cursor Struct |
| 4 | Responses: Id(4), values Float Array, exposures Long Array, valid Bool |
| 5 | Captured: Id(5), cursor Struct, manifest String, sha256 String, frames Id, bytes Long, metadata_bytes Long |
| 6 | Restored: Id(6), figure Float Array, clipped Bool |
| 7 | Released: Id(7) |
| 8 | Failed: Id(8), reason Id |

Success result IDs 1…7 must match the envelope operation. Failed is permitted
for any known action operation and remains a typed action result. Reason IDs
are Cancelled=1, Endpoint=2, InvalidEvidence=3, ProbeClipped=4. A negative
transport completion may carry None instead of an action result; a completion
with envelope result zero requires an action result. Initial sentinel
completions are not action completions.

Responses have 1…131,072 finite Float32 values. Exposures are a flat Long Array
with exactly five fields per record: domain, generation, sequence,
start_model_ns, duration_ns. There are 1…4,096 records. Every field preserves
all UInt64 bits; domain, generation and duration are positive, and
start_model_ns + duration_ns must not overflow UInt64. Cursor model-time bounds
do not constrain exposure start/duration bit patterns. Further causal and
owner association checks belong to the existing action effects and coordinator.

Manifest strings are nonempty, relative, at most 512 UTF-8 bytes, and have no
empty, dot or dot-dot path components or backslashes. SHA256 is exactly 64
lowercase hexadecimal ASCII characters. Payload bytes and metadata bytes retain
all UInt64 bits; artifact existence, contents and owner reservation budgets
are not codec claims.

A transport rejection is separately named by the common envelope and carries
exactly `Struct(lifecycle Id, message String)`. It carries no action result or
run/serial payload. The common rejection header retains its negative transport
result and correlated or all-zero uncorrelated identity rules.

## Exact Collect reply capacity

`collect_reply_size` computes the complete successful Responses envelope from
measurement count, frame count and the known message UTF-8 byte count, without
allocating dummy arrays. `preflight_collect_reply` also enforces 128 KiB. Future
owner integration must call this before acquisition effects and use the same
message size or reserve the maximum possible size.

For a SPA body of b bytes, padded POD extent is `(b + 15) & ~7`. A Float Array
has an eight-byte child descriptor plus four bytes per element; the exposure
Long Array has an eight-byte child descriptor plus 40 bytes per exposure. The
Responses Struct adds its POD header, result Id and valid Bool. The enclosing
payload includes the lifecycle Id, run/serial Longs and padded message String;
the fixed common envelope includes its two names, eight-field header and Props
object/property wrappers. All additions and products use checked arithmetic.
Encoders independently recheck the exact final extent before copying vectors.

## Validation scope

The shared binary fixtures in
[`tests/fixtures/native-calibration-actions`](../tests/fixtures/native-calibration-actions)
were emitted by Julia. Both codecs compare re-encoded bytes against them.
They cover every action, all settling rules, every result and failure reason,
negative transport completion, rejection, full UInt64 identity boundaries,
wrong arity/type, unknown IDs, nonfinite arrays and invalid exposure ends.
Focused tests also check complete request/reply capacity and exact Collect
extent at the 128 KiB boundary.

These are pure CPU serialization checks. They establish neither native owner
migration nor restoration, disconnect, deadline, capture artifact, installed
science, GPU, hardware or real-time qualification. Capture remains a codec-local
Rust action/result because the existing Rust coordinator has no Capture type;
a future endpoint adapter must explicitly map that interface.

Observed on 2026-10-06 from isolated branch
`work/calibration-action-codec-20261006`, based on RTC commit `596de8d`:
Julia 1.12.7, Rust/Cargo 1.97.1, Linux x86_64, CPU affinity 15. No private
PipeWire core, acquisition owner or scientific workload was started.

```sh
taskset -c 15 julia --startup-file=no --project=deployment/julia \
  -e 'include("deployment/julia/test/test_native_control_codec.jl"); include("deployment/julia/test/test_native_acquisition_lifecycle_codec.jl"); include("deployment/julia/test/test_native_calibration_action_codec.jl")'

PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig \
LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
  taskset -c 15 cargo test --offline --features live --lib \
  --target-dir /home/dgamroth/.cache/rtc-live-controls-20261005/native-filter-target

PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig \
LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
  taskset -c 15 cargo clippy --offline --features live --lib --tests \
  --target-dir /home/dgamroth/.cache/rtc-live-controls-20261005/native-filter-target \
  -- -D warnings

taskset -c 15 cargo fmt --all --check
```

Julia passed 66 common-envelope, 174 acquisition-lifecycle and 161 action-codec
assertions. Rust passed six action-codec tests, including all 43 shared binary
fixtures, and the library regression passed 33 tests with two existing
private-core fixtures ignored. Clippy with warnings denied and formatting
passed. Cargo reports an existing future compatibility warning in dependency
`proc-macro-error2` 2.0.1; this foundation changes no dependencies.
