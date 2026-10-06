# Native calibration action codec review

Date: 2026-10-06. Scope: RTC issue #7 pure Julia/Rust codec foundation under
RTC-DEV-030. The reviewed wire validation and encoded-capacity calculations pass
the checks below. One low-severity borrowed-array compatibility defect is
confirmed as NCA-001 and independently verified corrected in the primary
worktree. Owner effects, native caller admission and scientific qualification
are outside this foundation.

## Provenance and review scope

Implementation: `0fb933ca7ca66d88794651a45e2a7465495f4b2f` from
`work/calibration-action-codec-20261006`. The reviewer created a clean separate
worktree at that revision:

- `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-calibration-codec-review`
- branch `review/calibration-action-codec-20261006`

Only this review document is changed in the repository by this reviewer.
Investigative Julia scripts and logs are retained in
`/home/dgamroth/.cache/rtc-calibration-codec-review-20261006/`.
No private core, owner, plant, vendor HEART process or scientific workload was
started. Rust uses the existing shared Cargo target with `--offline`; no new
build tree or dependency download was requested.

Authorities reviewed: [action profile](NATIVE_CALIBRATION_ACTION_CONTROL.md),
[wire inventory](NATIVE_CALIBRATION_ACTION_WIRE_INVENTORY.md),
[common envelope](NATIVE_CONTROL_ENVELOPE.md), and RTC-DEV-030 in
[operations](operations.md). Existing `CalibrationServer.effect!` and
`collect!`, the Rust coordinator types and socket DTOs establish the current
semantic boundary. The codec's local Capture type does not add Capture to the
Rust acquisition coordinator.

## NCA-001 — Accepted offset Float32 vectors fail during owned SPA copying

Severity: low (P3). Confidence: high. Classification: confirmed wrapper
incompatibility; no wrong value or scientific side effect was observed.
Disposition: primary confirmed and corrected; independent verification passed.
The reviewer made no production change.

Affected code: `deployment/julia/src/native_calibration_action_codec.jl`,
`Adopt`, `Restore`, `Adopted`, `Restored`, `Responses` and `_float_pod` (line 177
at the reviewed revision).

The figure/value fields accept `AbstractVector{Float32}`. Preflight validates
length and finiteness through the array interface, without a one-based-axis
restriction. `_float_pod` passes that vector to `SPA.Array`, whose public
implementation constructs `Vector{T}(values)`. For a valid host AbstractVector
with axes `0:5`, Julia's axis-checked copy rejects the conversion:

```text
DimensionMismatch: axes must agree, got (Base.OneTo(6),) and (0:5,)
  PipeWireAO.SPA.Array -> NativeCalibrationActionCodec._float_pod
```

The independent reproducer defines a small read-only shifted vector with
ordinary scalar access and iteration. It holds finite Float32 values and has
no device or lazy computation behavior. Strided and reinterpret views passed
before the shifted Adopt input failed. The failure log and exact reproducer
are `borrowed-vector-fail-before.log` and `borrowed-vector-fail-before.jl`.
Shifted exposure vectors already work because their encoding uses iteration.

The wire arrays enumerate values; source indices have no wire meaning. The
minimal options are to create the owned Float32 vector in iteration order after
preflight, or to explicitly document and enforce one-based host vectors at the
codec boundary. The primary should select the intended API rather than treating
the inherited SPA copy restriction as an accidental public contract. A local
codec correction need not change the generic PipeWireAO library.

Required validation: compare plain, noncontiguous, reinterpret and offset-vector
bytes for Adopt/Restore and Float32 result arrays; preserve negative-zero bits.
Verify that oversized borrowed vectors still fail exact preflight before the
owned copy. Keep caller input unchanged and retain finite-value checks.

### Adjudication and independent verification

The primary accepted the generic host-vector contract and added a specialized
`Vector{Float32}` path preserving the existing factory. Other
`AbstractVector{Float32}` inputs are validated, then copied with `enumerate`
into dense owned wire storage. That copy occurs after encoder size preflight;
source axes are not transmitted. The profile documentation now states the
CPU scalar-iteration contract and excludes device-array scalar iteration.
The additional bounded copies are cold serialization work.

Independent inspection confirms the change reaches every figure/response
encoder through `_float_pod` without changing wire IDs, bounds or finite-value
checks. The original exact `borrowed-vector-fail-before.jl` reproducer now
passes **170/170** with `--check-bounds=yes` against the primary worktree; see
`borrowed-vector-after.log` (2.8 seconds). The primary also established
**18 passed / 1 error before** and **31/31 wrapper + 161/161 codec checks after**,
recorded in `calibration-action-array-{before,after}-20261006.log` under the
shared live-control evidence cache. Those logs were independently read.

The independent remaining-boundary script explicitly constructs a genuine
`Base.ReinterpretArray` with copied UInt32 backing and records its concrete type.
The equivalent maintained test should retain that backing copy to avoid a double
reinterpret simplifying to the original dense array. This test-precision note
does not affect the confirmed offset-vector failure or its correction.

Verified corrected Julia source SHA-256:
`2ee9cb2ea1e5bcc7fe20861699b91d56f9d3f48a686d14c7c776ac2021a1fa12`.

## Wire and numeric review

| Area | Evidence and conclusion |
| --- | --- |
| Common framing | Both codecs route through strict shared Props framing, complete byte limits and payload grammar before typed decoding. The action profile uses the common names with the calibration 128 KiB reply bound. |
| Request identity | Payload has exactly run Long, serial Long and args Struct. Both identities must be positive and preserve every UInt64 bit; common controller/endpoint/token correlation is independent. |
| Scalar/type/arity | Every action, rule and result checks exact field arity and POD kind. Probe/count fields are Id, identity/time fields Long, figures/results Float arrays, exposures Long arrays and flags Bool. Wrong child kind/width is rejected by shared grammar and typed array selection. |
| Float32 | Julia fields require Float32 vectors; Rust owns Vec<f32>. Both reject nonfinite figures/results. Converting an oversized Float64 to Float32 produces Inf, which the Julia discriminator confirms is rejected. No finite Float32 is widened/narrowed by wire serialization; negative zero is present in shared byte fixtures. |
| Cursor versus exposure time | Action cursor domain/generation are positive, sequence keeps all UInt64 bits, and model_ns is bounded by Int64 maximum. Exposures separately allow high-bit start/duration, require positive domain/generation/duration and reject UInt64 end overflow. These distinct rules match the selected contract. |
| Operations and results | Known success-result IDs must match operation 1…7. Typed Failed is available for each known action. Zero transport result requires an action result; None requires negative transport result. Unknown result/reason/lifecycle IDs reject. |
| Rejection namespace | Rejection uses the distinct common rejection names and exactly lifecycle/message payload, without invented action run/serial. The Rust namespace test confirms rejection bytes do not decode as completion. |
| Capture metadata | Relative manifest syntax, bounded UTF-8, lowercase SHA256, frame count and full UInt64 artifact byte counts are checked. File existence/content and reservation budgets remain owner/caller checks. |
| Borrowed data | Preflight inspects bounded logical lengths and finite values before creating vector PODs; result encoding rechecks complete extent before copying. Caller mutation during encoding is not a supported concurrent ownership contract. NCA-001 records the separate offset-copy incompatibility. |

No other confirmed wire, numeric, arity, result/operation or capacity defect was
found in this review. Rust safe enums prevent invalid encoder-side lifecycle or
failure variants; Julia explicitly validates reinterpret-created enum values.

## Exact encoded capacity

The independent calculation reconstructs the complete padded POD grammar rather
than calling the codec's size helpers. For m measurements, n exposure records,
and s message UTF-8 bytes:

```text
pad8(x) = 8 × ceil(x / 8)
Responses completion bytes =
    288 + 48 + 40
    + pad8(16 + 4m)
    + pad8(16 + 40n)
    + pad8(9 + s)
```

The terms include the common property names, complete eight-field header,
Props/property wrappers, payload lifecycle/run/serial, result ID/valid flag,
array child descriptors and message terminator/padding. With an empty message,
this reduces to `424 + 8 × ceil(m / 2) + 40n`.

Observed/derived boundaries for an empty message:

- One exposure permits at most 32,652 measurements, exactly 131,072 bytes.
- Classic's 376 values permit at most 3,228 exposure records by wire capacity.
- Copper's 3,600 values permit at most 2,906 exposure records by wire capacity.
- The logical limit of 4,096 exposures alone cannot fit even a one-value reply.
- An Adopt figure of 4,010 values fills the complete 16 KiB request; its next
  element exceeds capacity even though the logical figure maximum is 4,096.

These are wire-capacity bounds, not admitted scientific acquisition sizes.
Checked arithmetic and semantic limits precede conversions/multiplications.
Rust independently computes the same extents and tests the maximum reply.

`preflight_collect_reply` is a pure pre-effect guard. Request encoding may
represent a logically valid Collect whose eventual reply cannot fit. This is
intentional foundation behavior: actual owner integration must invoke preflight
with its validated measurement/frame counts and the real message byte budget
before exposures, model advancement, allocation of acquisition storage or other
effects. Passing the default empty-message preflight and later emitting a larger
message is not sufficient. Reserve the maximum permitted message when its final
size is not known. Retain encoder revalidation as a second guard.

The current JSON owner still has its earlier conservative JSON-size check.
Replacing that check, invoking native preflight at the effect boundary and
preserving invalid-request versus post-effect fault behavior are integration
obligations, not completed functionality of this codec commit.

## Runtime evidence

The primary's fresh Julia action suite log,
`/home/dgamroth/.cache/rtc-live-controls-20261005/calibration-action-codec-root-20261006.log`,
was independently read: **161/161 passed**. The worker also reports 66 envelope
and 174 lifecycle checks, Rust 33 passed/two existing private-core tests ignored,
Clippy and formatting. Those additional worker results are reported evidence;
this reviewer did not independently inspect their original logs.

Independent reviewer runs on CPU 15:

| Run | Result |
| --- | --- |
| Borrowed-vector discriminator | Two ordinary-wrapper checks passed, then confirmed NCA-001 on the shifted Float32 vector; original log/reproducer preserved |
| Remaining Julia discriminator | **169/169 passed**, `discriminator.log`: 144 measurement/frame/message-padding combinations against the independent grammar, six exact-limit/one-over cases, strided/reinterpret views, shifted exposure-vector iteration and nonfinite/overflow rejection |
| Same original failing script after correction | **170/170 passed** with bounds checks, including the shifted Float32 input, `borrowed-vector-after.log` |
| Rust focused action tests | **6/6 passed**, `rust-focused.log`, including all 43 shared binary fixtures, capacity boundaries, unsigned identities, cursor/exposure validation and failure/rejection separation |

The Rust run used the existing
`/home/dgamroth/.cache/rtc-live-controls-20261005/native-filter-target`:

```sh
PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig \
LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
  taskset -c 15 cargo test --offline --features live --lib \
  native_calibration_action_codec \
  --target-dir /home/dgamroth/.cache/rtc-live-controls-20261005/native-filter-target
```

Julia used `--startup-file=no --project=deployment/julia`, version 1.12.7 and
PipeWireAO 0.6.16 at `/home/dgamroth/.julia/packages/PipeWireAO/QRGDD`.
The initial precompile emitted the existing loaded-dependency-version notice;
the subsequent focused run completed without it. Rust retains the reported
future-compatibility warning from dependency `proc-macro-error2` 2.0.1; no
codec compile warning or test failure occurred.

## Source identities and remaining gates

| Baseline artifact | SHA-256 |
| --- | --- |
| Julia action codec | `327e5fc951d52891ffedb6d755cefc0f5edd06eac8f85da78236a359fac43f57` |
| Rust action codec | `f140fcf35bdbcad095246480106b1dc659414162c126ac854596d0e3b63a829b` |
| Julia action tests | `ce736abc8542f6550c9dcd7ac0710f25853bcb18d5d49e7730d994c7e3adbf76` |

The foundation does not bind a controller to a calibration run, enforce the
acceptance-based next-request inactivity deadline, perform restoration or fence
Release, publish capture artifacts, or adapt the Rust coordinator/Capture gap.
Generic endpoint expiry-to-completion also needs the action payload's run/serial
mapping when integrated; a lifecycle-shaped failure must not be substituted.
Those owner/client integration checks remain required under RTC-DEV-030.

No scientific equivalence, installed Classic/Copper deployment, GPU, hardware,
allocation or real-time qualification is inferred from these serialization
checks.
