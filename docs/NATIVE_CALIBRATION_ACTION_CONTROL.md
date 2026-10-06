# Native calibration action control

The phase E codec foundation implements the pure Julia and Rust profile
`pipewireao.rtc.calibration-actions/1` under RTC-ARCH-024 / RTC-DEV-030. It does
not by itself establish owner migration or installed qualification. The Julia
integration described below migrates the selected action server and campaign
client. The Rust endpoint and installed qualification remain pending; issue #7
remains open. The existing effect implementation,
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

Float32 vector axes enumerate the wire values; their host index labels are not
scientific coordinates in this profile. CPU vectors supporting scalar iteration
may have shifted axes, strided views or reinterpret wrappers. The encoder
materializes a dense owned wire vector after encoded-capacity preflight when the
host wrapper cannot be passed directly to the SPA constructor. These are cold
control allocations; device-array scalar iteration is not a supported contract.

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
allocating dummy arrays. `preflight_collect_reply` also enforces 128 KiB. The
native owner calls this before acquisition effects and uses the same
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

These foundation results are pure CPU serialization checks. They establish neither native owner
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

## Julia action server and client integration

The integration baseline is commit `eb9d738` on 2026-10-06, including the
reviewed codecs and phase D acquisition owners. Its selected source owners are
`calibration_owner.jl` and `heart_calibration_owner.jl`.

| RTC-ARCH-024 / RTC-DEV-030 obligation | Allocation and current evidence | State |
| --- | --- | --- |
| Bounded typed action ingress and responses | Existing envelope codec and `HILNativeCalibrationActions.ActionServer`; private-core synthetic acquisition tests | Implemented for Julia source owners |
| Capacity before acquisition effects | Injected exact native Collect preflight in existing `CalibrationServer.execute!` / `effect!`; oversized Collect leaves exposure count zero | Implemented |
| Preserve SCI numerical behavior and restoration | Typed adapter delegates all actions to the existing effects; full synthetic cycle and immutable capture test | Implemented, installed SCI evidence pending |
| Exact owner and controller/run/serial identities | Explicit client Binding, fresh native NodeInfo/capability proof, actual controller fencing, full UInt64 payload identities | Implemented for Julia |
| Sole owner Core and ThreadLoop | Action endpoint borrows the lifecycle Bridge core/loop; identity assertions and terminal cleanup tests | Implemented |
| Lifecycle service during accepted effects | `safe=false` service checks defer Connect/Reset/Shutdown; safe owner boundary services them outside effects | Implemented; final independent review pending |
| Finite disconnect/deadline failure and cleanup | Existing ticket deadlines and actual controller presence; action ingress closes before SCI cleanup; Release facts survive later transport abort | Implemented, expanded installed fault tests pending |
| Selected Rust coordinator and CLI | Caller arguments use explicit `--remote`, `--node`, `--owner-pid`, `--owner-instance`; Rust endpoint migration follows this increment | Partial |
| Native supervisor identity handoff | Existing launcher readiness metadata supplies connection hints; fresh native proof remains mandatory | Partial, issue #8 owns replacement |
| Installed exports and selected profiles | New source assets require parent integration and installed acceptance | Pending |

The action node is the lifecycle node with `.actions` appended. It shares the
owner PID and positive incarnation with that lifecycle node. `Binding` carries
an explicit remote, action node, expected PID and incarnation. Native connect
must prove all four, profile and capability before actions; a saved report or
node name cannot authorize an endpoint. A replacement owner requires a new
explicit binding. Unknown outcomes retire the Julia connection without retry.
Saved plans, capture manifests and reports remain ordinary JSON evidence.

Selected owners create no calibration Unix listener and perform no JSON socket
action I/O. Compatibility parsing of `--calibration-socket` remains temporarily
for the parent export migration; it creates no selected fallback. Legacy socket
helpers remain available only to their existing development fixtures.

The first accepted Hold or Restore binds the actual common-envelope controller.
Logical figure and measurement extents and exact Collect capacity are checked
before controller or SCI run/serial binding. Rejected dimensions leave prior
SCI identity and probe association intact.
The existing SCI owner validates its run, increasing serial, phase, figure,
cursor, settling and restoration rules. Another controller receives a typed
InvalidEvidence result without effects. Paused admission returns typed
Cancelled for ordinary actions while Restore and Release remain available.
The inactivity clock starts at receipt of an owned admitted request and includes
effect time. Completion, malformed requests, wrong run/serial and another
controller do not extend it. Accepted effect checks enforce both the ticket
deadline and this inactivity bound.

Foreign ticket expiry/removal is neutral to the bound run. Generic ingress may
terminalize such a ticket before the SCI adapter takes it; the adapter records
that terminal without binding authority or changing the bound run's activity,
phase, hold, serial or effects. An expired initial invalid ticket likewise cannot
bind action authority. If a foreign typed rejection loses its caller before
publication, a negative transport completion resolves that ticket after checking
that its expiry/removal is the sole cause. Core, publication and internal ticket
failures and retirement of the bound controller remain failures of the active run.

Successful replies carry an empty message, so native Collect preflight uses
`message_bytes=0`. Request adapters inspect exact encoded figure capacity before
copying dictionary figures. The encoder checks the final reply again. No new
SCI state machine, acquisition math or timing coefficients are introduced.

Release flushes its terminal reply through the existing Bridge Core sync before
closing only action ingress. The lifecycle endpoint remains alive for final
Shutdown and stopped publication. If transport aborts after the actual Release
effect, cleanup retains the released, restored, unheld SCI facts even when the
client cannot establish the outcome.
When the existing SCI effect or accepted-action failure has actually faulted the
owner, the adapter publishes lifecycle Fault before action ingress closes while
the Core remains usable. Publication failure is retained with the primary
failure. A transport exception after Release does not create an SCI fault or
publish lifecycle Fault.

### Reproducible software verification

Use Julia 1.12.7 on CPU 15 with the already installed HIL project and source
SDK; no dependency installation is needed:

```sh
taskset -c 15 julia --startup-file=no \
  --project=/home/dgamroth/.cache/rtc-heart-native-20261006/classic-fgn-cpu-base/hil \
  deployment/hil/test_native_calibration_actions.jl

taskset -c 15 julia --startup-file=no --project=deployment/julia \
  -e 'include("deployment/julia/test/test_native_calibration_action_client.jl"); include("deployment/julia/test/test_campaigns.jl"); include("deployment/julia/test/test_heart_calibration_export.jl")'
```

The native fixture starts only disposable private PipeWire cores and synthetic
acquisition sessions. It checks owner PID/incarnation mismatch, full UInt64
run/serial, Hold/Adopt/Settle/Collect/Restore/Release, exact native reply capacity,
controller fencing, paused admission, held disconnect, immutable Capture,
malformed POD rejection, action ingress revocation and post-Release transport
abort, logical instrument dimensions, and long-effect inactivity. It reuses the existing server's development regressions. Run these cold
fixtures serially on CPU 15: legacy 500 ms socket fixtures can expire under
overlapping compilation. This software evidence does not qualify science
cores, classic or Copper live acquisition, GPU, hardware or real-time latency.

Observed on branch `work/native-calibration-actions-20261006`, Linux x86_64,
Julia 1.12.7, CPU 15: the connected suite passed 646/646 assertions (539 existing
SCI/server regressions and 107 native integration assertions). The focused SDK
run passed 47 client, 66 campaign and 106 HEART export assertions, 219/219 total.
`git diff --check` passed. These results do not close issue #7 or promote an
installed scientific capability claim.

Independent review NCAE-001 demonstrated a foreign controller's removal before
take incorrectly faulting an already held bound run at baseline `323f767`
(7 passing / 3 failing assertions). The same private-core discriminator passed
12/12 after the scoped adapter fix, using the current source SDK
`PipeWireAO.jl` rather than the prepared HIL project's vendored SDK. The source
fixture additionally covers foreign expiry/removal before take, expiry while
applying a foreign rejection, and an expired invalid initial ticket. No generic
endpoint machinery or SCI numerical effects change in this remediation.
