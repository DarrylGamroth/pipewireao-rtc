# Native cold control envelope validation

2026-10-05. Starting RTC revision
`74099a2861ed7d60789a38c0f3ad4121b029bf48`, branch
`work/native-control-planes-20261005`, worktree `pipewireao-rtc-native-controls`.
Contract: [RTC-DEV-030](operations.md#rtc-dev-030--native-local-live-controls)
and [fixed envelope](NATIVE_CONTROL_ENVELOPE.md).
Evidence root: `~/.cache/rtc-live-controls-20261005`.

## Implemented boundary

The Julia SDK and feature-gated Rust library now provide the same fixed native
Props header and bounded native payload container. They validate exact envelope
shape, scalar widths, UInt64 serial bit patterns, result/sentinel semantics,
encoded byte limits, UTF-8 and payload nesting before further materialization.
Payload action semantics, registry authority, deadline execution and restoration
remain each owner's responsibility. No live JSON transport is hidden in a POD.

The codecs allocate on cold control paths. They are not installed on the measured
scientific source, whose prepared native run/reset/query path remains unchanged.
The [committed-main source validation](LIVE_CONTROL_VALIDATION.md) is separate.
No scientific graph, calibration artifact, detector setting or matrix is changed
by this increment.

## Software checks

Julia focused tests pass **66/66**. The Rust codec has **10 focused unit tests**,
including every truncated prefix of a valid request. The full locked/offline Rust
regression passed **144 tests**, with **0 failures** and **3 ignored** repository
fixtures. The final Julia SDK regression passed **1,452/1,452 checks across 64
test summaries**. Covered codec cases include:

- required positive identities versus exact zero initial/uncorrelated sentinels;
- unsigned serial boundaries through 2⁶³ and 2⁶⁴−1;
- request Long budget versus reply Int result, wrong type/width/version and arity;
- duplicate/extra/reordered names, property flags and trailing bytes;
- 16 KiB request, 64 KiB lifecycle and explicit 128 KiB calibration caps;
- fixed-scalar arrays, native Strings/Bytes and Struct depth, malformed nested
  lengths, invalid UTF-8, unsupported POD kinds and zero-width array elements.

Independent [codec review](NATIVE_CONTROL_CODEC_REVIEW.md) found NCMC-001:
Julia initially validated an oversized Bytes payload before checking the cap,
copying it on rejection. The same warmed 512 KiB fixture allocated 527,576 bytes
before and 3,216 after checked capacity preflight was moved ahead of validation.
The current encoder preflights the complete bounded envelope before parsing
payload PODs, including Bytes and Arrays. Cold errors may allocate; this is not a
zero-allocation claim.

The full SDK log retains **24** `fatal: not a git repository` diagnostics.
These come from `ScienceExport.revision` attempting `git rev-parse` on temporary
source trees used by the HIL export tests; that helper catches Git failure and
records no revision. The fixture roots and export calls are in
`deployment/julia/test/test_exports.jl`, and the fallback is in
`deployment/julia/src/science_export.jl`. The run also logs one YAML duplicate
key diagnostic from `test_heart_configuration.jl`, which asserts that duplicate
keys are rejected. Both diagnostics are visible in the retained log; all SDK
assertions passed.

## Private native-core exchange

The [Julia fixture](../deployment/julia/test/native_control_envelope_proof.jl)
and [Rust owner](../examples/native_control_envelope_proof.rs) pass **42/42**
checks using registered PipeWireAO 0.6.16 and the pinned Rust SDK `f2d8689`.
They run as separate processes on an isolated private core, with an inactive
zero-port Filter, no processing callback, links or frame publication.

The callback validates the common envelope and stages a concrete header and
owned encoded native payload. Rust's public `Value` enum includes a pointer
variant and is not `Send`, even when this codec's grammar excludes pointers;
the mailbox therefore retains bytes and never uses an unsafe Send override.
The serialized owner decodes its exact diagnostic integer payload after callback
return, performs one adoption, and publishes a completion echoing the full header.

The fixture proves:

- exact owner PID, native global ID/object.serial, endpoint instance and profile;
- retained initial completion, capability and independent rejection;
- staged request with no early acknowledgement, then one gated application;
- full UInt64-max serial preserved in the subscribed completion;
- identical request replay with no second application;
- same-token different caller identity receives correlated −114 while the
  original completion remains unchanged;
- fresh query token 2 reports the actual counter through a subscribed completion;
- unsupported operation receives correlated −22 without replacing query success;
- node removal, child exit and private daemon cleanup under finite waits.

Owner output: five callbacks, one adoption, zero ports, no frames. Empty marker
files synchronize this diagnostic test only; command/reply fields cross PipeWire
as native SPA parameters/events. Each observation wait is bounded; cold startup
is 30 s, observations 10 s and owner service 45 s. The fixture verifies normal
node removal and child exit. Its fallback cleanup allows 5 s for graceful exit,
then sends SIGKILL and allows a further 5 s; the forced-kill path was not fault
injected. No GPU or normal user PipeWire session is used.

This diagnostic profile uses synthetic controller identities to exercise header
correlation and unsigned encoding. It does **not** authenticate a registry-bound
caller, run two independent caller connections, establish calibration hold or
inactivity handling, or implement production lifecycle operations. Those remain
explicit owner integration gates; the test is not production authority evidence.

## Reproduction and evidence

```sh
export CARGO_TARGET_DIR="$HOME/.cache/rtc-live-controls-20261005/native-filter-target"
export CARGO_INCREMENTAL=0 CARGO_PROFILE_DEV_DEBUG=0 CARGO_BUILD_JOBS=2
export PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig
export LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu
taskset -c 14 timeout 600 cargo build --locked --offline --features live \
  --example native_control_envelope_proof
NATIVE_CONTROL_PROOF_OWNER="$CARGO_TARGET_DIR/debug/examples/native_control_envelope_proof" \
  taskset -c 14 timeout 120 julia --startup-file=no --project=deployment/julia \
  deployment/julia/test/native_control_envelope_proof.jl
```

Logs: `native-control-codec-focused-final.log`,
`native-control-codec-rust-unit.log`, `native-control-envelope-proof-final.log`,
`native-control-sdk-regression.log`, `native-control-proof-build-final.log`,
and `native-control-codec-rust-clippy.log`. The public schema serializers and
owned buffer APIs are used; no application pointer cast or daemon-private layout
is introduced. Rust INACTIVE-only under `v0_3_34` remains distinct from the Julia
ASYNC|INACTIVE mechanism proof. The Cargo dependency future-incompatibility
warning for `proc-macro-error2` 2.0.1 remains documented and unchanged.

## Remaining integration

The existing public supervisor socket, supervisor-to-Rust socket, calibration
endpoint and calibration/HEART control/health files remain JSON migration debt.
The [inventory](LIVE_CONTROL_INVENTORY.md) and
[reviewed phases](NATIVE_CONTROL_MIGRATION_DESIGN.md) are the retirement checklist.
The next phase must bound existing Rust inner synchronization before native
owner controls can promise finite application/cleanup. Callback set_param return
alone is not application, and a caller timeout cannot bound a stalled owner.

CPU codec/native integration does not establish installed science, allocation,
maximum rate, hardware, HIP or hard real-time qualification. Preserve the completed
source gate while moving the remaining owners through those separate checks.
