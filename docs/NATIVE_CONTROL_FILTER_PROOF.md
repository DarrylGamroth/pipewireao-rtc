# Diagnostic native control Filter proof

2026-10-05. CPU software integration evidence only. No production files changed,
no GPU or normal PipeWire session used, no scientific workload run. This is a
migration dependency proof, not the current installed SDK or real-time gate.

## Observed result

Two initial fresh runs passed **30/30 assertions** using public PipeWireAO 0.6.16
on CPU 14. A subsequent canonical-main rerun also passed **30/30** in 8.4 s;
`native-control-filter-proof-canonical-main.log` records that run. It loaded the
clean canonical checkout `/home/dgamroth/workspaces/codex/pipewire/PipeWireAO.jl`
at exact revision `354512752bc35fd9fe59fe16cc1a0585668107c6`; `git status
--porcelain=v1` was empty before and after the run. No proof script was changed
for the canonical rerun. The separate Julia owner and client each own
a ThreadLoop/Context/CoreConnection on one isolated private daemon. The child
inherits CPU 14 affinity. Native requests and completions cross the process
boundary through PipeWire Node parameters/events; no JSON request transport is
present.

The proof checks:

- Exactly one advertised owner Node; positive global ID/object.serial;
  NodeInfo owner PID, protocol version and instance match the expected process.
- Zero input and output ports. The owner constructs an inactive asynchronous
  Filter with no process callback, driver/trigger flags, links or frame buffers.
- A complete retained set of three independent standard Props objects:
  initial snapshot, capabilities and empty rejection sentinel. Exact prepared
  scalar parsers validate their schemas and values.
- An APPLY request with instance 23/token 1 reaches the owner's callback. The
  callback validates and stages one owned scalar tuple. No incoming POD escapes
  the callback and no completion is published there.
- With adoption held by the fixture, retained Props and the subscribed snapshot
  remain initial. The native request does not automatically become an ACK or
  overwrite the retained snapshot.
- The existing serialized owner loop takes the staged tuple after callback
  return, performs exactly one adoption, then publishes the complete retained
  set. The client observes instance 23/APPLY/token 1/count 1/applied=true.
- A fresh QUERY/token 2 is observed through the subscription before subsequent
  retained enumeration. It matches the instance, kind and token, preserves
  adoption count 1 and reports applied=true. No second application occurs.
- Owner shutdown removes the bound proxy and advertised Node within the finite
  removal deadline. The child exits successfully and the private daemon remains
  alive until fixture cleanup.

Owner log: `callbacks=2 adoptions=1 ports=0 process_callback=none frames=none`.

## Failure evidence and correction

The first fixture failed its initial enumeration wait after 12 successful
identity/zero-port assertions. The immutable record is
`native-control-filter-proof-initial-enumeration-failure.log`.

`native-control-filter-proof-sequence-diagnostic.log` then demonstrated three
subscription Props at sequence 1 and the same three enumerated Props at
sequence 1073741829, although the requested keyword sequence was 1001.
No requests/adoptions had occurred. This was a fixture correlation assumption,
not missing retained Props or an endpoint failure.

Source evidence explains the result:

- `pipewire/src/modules/module-protocol-native/protocol-native.c:1276` accepts
  the caller sequence, but line 1286 marshals
  `SPA_RESULT_RETURN_ASYNC(msg->seq)` instead.
- `pipewire/spa/include/spa/utils/result.h:35` sets the asynchronous bit to
  1 << 30; line 44 combines that bit with the native message sequence.
  Observed 1073741829 = 2³⁰ + 5.
- PWA `src/objects.jl:1464` checks the native call return but does not return its
  asynchronous sequence. Public `enum_params!` returns the Node.

The corrected fixture deduplicates exact retained Props and validates their
schemas/initial incarnation and token. It makes no caller-sequence equality
assumption. Actual completion freshness still requires exact instance/kind/token
matching; enumeration is not a command completion.

An intermediate run reached 29 assertions and completed removal, then its final
diagnostic print called `getpid(child)` after child exit, which raised ESRCH.
`native-control-filter-proof-post-exit-print-failure.log` preserves this fixture
error. The child PID is now captured immediately after launch and reused.

## Artifacts and reproduction

- `native_control_filter_protocol.jl`: diagnostic scalar request/snapshot schema.
- `native_control_filter_owner.jl`: separate inactive no-port Filter owner.
- `native_control_filter_private_core.jl`: bounded isolated daemon fixture.
- `native_control_filter_proof.jl`: public Node client and 30 assertions.
- `native-control-filter-proof-first-pass.log`: first successful corrected run.
- `native-control-filter-proof.log`: initial successful repeat.
- `native-control-filter-proof-canonical-main.log`: successful clean canonical-main rerun.

```sh
JULIA_LOAD_PATH='/home/dgamroth/workspaces/codex/pipewire/PipeWireAO.jl:@stdlib' \
taskset -c 14 julia --startup-file=no \
  /home/dgamroth/.cache/rtc-live-controls-20261005/native_control_filter_proof.jl
```

Canonical PWA source HEAD: `354512752bc35fd9fe59fe16cc1a0585668107c6`, version
0.6.16, clean main checkout. The proof loads no RTC source. The earlier design
inspection used RTC revision `57337d6d52db7e23d27a55d58e358995f235b3d7` and its
then-current worktree changes. Julia 1.12.7. All new proof artifacts reside in
the evidence directory.

Every observation wait has an absolute monotonic deadline; private-daemon startup
is bounded at 10 s, cold child preparation at 30 s, individual native observations
at 10 s and child cleanup at 5 s. The owner's entire service loop is bounded at
45 s. Empty staged/adoption/quit files synchronize the test harness only; they
contain no command fields, values or serialized replies. They are not proposed
production transport or a second owner lifecycle.

The daemon helper uses the existing PWA-test convention to locate the bundled
daemon/plugin artifacts. All connections, bindings, setters, subscriptions,
parsers and parameter publication use public Julia APIs; no native pointer call
or private native structure is used. Public Filter/Node callbacks provide copied
owned PODs. Prepared publication storage remains owned and alive for every call;
only decoded immutable scalar values are staged.

## Limits

This proves the Julia inactive no-port Filter mechanism across real separate
processes on a private native core. It does not establish Rust codec
interoperability, final shared namespace/enums, concurrent writer arbitration,
busy/duplicate/stale rejection behavior, variable calibration payload bounds,
controller-disconnect hold semantics or installed migration correctness. Those
remain the narrow phase-A/B follow-on gates in
`NATIVE_CONTROL_MIGRATION_DESIGN.md`.

Cold callback copies/publication allocations are permitted for this proof and
were not measured. This mechanism must not replace the existing prepared,
bounded scientific Stream source-control path in the inclusive allocation gate.

## Julia-to-Rust scalar mechanism repeat

The same Julia client assertions passed **30/30** against the separate public
Rust Filter owner in [the diagnostic example](../examples/native_filter_proof.rs).
The final repeat took 5.7 s on CPU 14. Owner output remained two callbacks,
one adoption, no ports, no process callback and no frames. Exact PID, instance,
registry global ID and object.serial, retained three-Props state, staging without
ACK, applied completion, fresh query and bounded removal were checked.

Rust uses the existing pinned `pipewire-ao` revision
`f2d86899328465e9b97ccbfb4b10d0b243749171` with `v0_3_34`, and `INACTIVE`
alone. Its `ASYNC` flag is gated behind `v0_3_77`; the first build failure is
preserved. No Cargo feature or dependency upgrade was required for this
zero-port endpoint. Julia continues to use `ASYNC | INACTIVE`.

Build, rustfmt and focused Clippy `--no-deps -D warnings` pass. Cargo separately
reports future incompatibility in dependency `proc-macro-error2` 2.0.1. The
bounded debug build cache used approximately 326 MiB; compilation and tests
excluded CPU 0/1 and used no GPU. The tested example SHA-256 is
`5a1e4f899c6e83f5c8eb53a4982f89ef2541739c0211a4055414fc3ff0cdf66d`.

Evidence under `~/.cache/rtc-live-controls-20261005`:
`native-control-filter-rust-proof.log`,
`native-control-filter-rust-build.log`,
`native-control-filter-rust-clippy.log`, and
`native-control-filter-rust-proof-notes.md`. The notes record the explicit
private-core reproduction command and earlier diagnostic failures. The fixture
markers still synchronize tests only; live command/reply bytes are native SPA.

This proves the diagnostic scalar schema across Julia/Rust. It does not establish
the final common caller/deadline envelope, payload bounds, competing callers,
disconnect handling or finite Rust runner effects. The
[common envelope](NATIVE_CONTROL_ENVELOPE.md) and
[migration review](NATIVE_CONTROL_MIGRATION_REVIEW.md) keep those gates distinct.
