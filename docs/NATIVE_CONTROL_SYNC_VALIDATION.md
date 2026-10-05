# Native control synchronization prerequisite

2026-10-05. RTC-DEV-030 phase B prerequisite, following the
[shared envelope](NATIVE_CONTROL_ENVELOPE_VALIDATION.md). Base commit
`7724ba8b10f060c9f87512d01977b4762040039b`; branch
`work/native-control-planes-20261005`, worktree `pipewireao-rtc-native-controls`.
The [independent review](NATIVE_CONTROL_SYNC_REVIEW.md) defines the evidence
boundary. This increment does not replace a production JSON control endpoint.

## Defect and correction

Observed: a connected `LiveGraphAdapter::progress()` remained blocked for six
seconds while its fixture-owned private daemon was stopped. It returned success
only after the daemon resumed. Source inspection confirmed that the inner
`roundtrip` called `main_loop.run()` without a timeout, so enclosing observation
deadlines could not terminate that wait.

The adapter now drives finite loop iterations while checking core errors,
deadline expiry and the exact sync sequence. It rejects an already-expired
deadline before submitting a sync and does not accept a done observed after
expiry. Default synchronization has a five-second budget. Private lexical scopes
propagate the earliest enclosing deadline into nested synchronization and callback
waits, then restore the parent scope on return or unwind. Reset/run/property
observations, node/link discovery, discard observations and cleanup retain their
local budgets; their initial synchronization is included where applicable.

The implementation uses an owner-thread `Rc<Cell<...>>` and a stack guard. It
introduces no application pointer handling, scientific scheduler, frame callback
or per-frame serialization. Run/reset wire requests and scientific algorithms
are unchanged.

## CPU software evidence

Registered PipeWireAO 0.6.16 and pinned Rust SDK `f2d8689`; CPU 14, single Julia
thread and BLAS thread, private `/opt/pipewireao` core. No GPU, normal desktop
PipeWire core, HEART process or scientific frame workload was used.

The [Rust probe](../examples/native_sync_deadline_proof.rs) and
[Julia fixture](../deployment/julia/test/native_sync_deadline_proof.jl) pass
**34/34** checks, including an explicitly invoked **1/1** private Rust test.
Only fixture-owned daemons receive STOP/CONT/KILL signals.

| Observation | Result in the recorded pass-after run |
| --- | --- |
| Already-expired deadline | Rejected before submission |
| Stopped core, explicit 250 ms deadline | Unknown completion error at 250.0 ms |
| Stopped core, default five-second deadline | Unknown completion error at 5.000 s |
| Existing external-node discovery scope | Unknown completion error at 500.0 ms |
| Empty-adapter cleanup while core is stopped | Error at 5.000 s; no remote-removal success claimed |
| Two actual late core done events, new sync while daemon is stopped again | Both old events observed; new 250 ms sync still times out |
| Resumed healthy daemon | Fresh exact sync succeeds |
| Forced daemon termination while sync is pending | Connection error, rather than timeout |

These durations discriminate deadline behavior. They are individual functional
observations, not latency percentiles or a real-time qualification. The fixture
uses finite observation tolerances separately from the actual owner budgets.
Late-event instrumentation is test-only and does not add production tracing.

Three guard unit tests cover longer-child clamping, shorter-child restoration
and unwind restoration. The full locked/offline Rust regression passes **147
tests**, with **0 failures and 4 ignored** tests. One of those ignored tests is
explicitly exercised by the private-core fixture above; the three existing
scientific/private-core fixtures remain unrun in this regression. Strict library
and probe Clippy, and formatting, pass. The dependency future-incompatibility
warning for `proc-macro-error2` 2.0.1 remains unchanged.

The shared private-core helper was extracted without changing envelope semantics;
the native Julia-to-Rust envelope fixture still passes **42/42**.

## Reproduction and identities

```sh
export CARGO_TARGET_DIR="$HOME/.cache/rtc-live-controls-20261005/native-filter-target"
export CARGO_INCREMENTAL=0 CARGO_PROFILE_DEV_DEBUG=0 CARGO_BUILD_JOBS=2
export PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig
export LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu
taskset -c 14 cargo build --locked --offline --features live \
  --example native_sync_deadline_proof
taskset -c 14 cargo test --locked --offline --features live --lib --no-run
# Set this to the exact lib test executable printed by the preceding command.
export NATIVE_SYNC_DEADLINE_TEST_BINARY=/absolute/path/to/pipewireao_rtc-TEST_HASH
NATIVE_SYNC_DEADLINE_PROOF="$CARGO_TARGET_DIR/debug/examples/native_sync_deadline_proof" \
  JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 taskset -c 14 timeout 120 \
  julia --startup-file=no --project=deployment/julia \
  deployment/julia/test/native_sync_deadline_proof.jl
```

Evidence root: `~/.cache/rtc-live-controls-20261005`.

| Artifact | SHA-256 |
| --- | --- |
| `src/live.rs` | `cf990d47bfc824cb85911025f4a76f20d06b072fe06547532630bebfce128747` |
| `native-sync-stall-before.log` | `87592b2f5f19494931445271cfcfee9933932a0c152b9d4adcf56df23ccd6292` |
| `native-sync-deadline-proof-final.log` | `9fdb0c0ba5c6a7d8ec367abaeb982c57f68c714dca4a9be62c2e935c9911e533` |

Additional logs: `native-sync-deadline-unit.log`,
`native-sync-deadline-rust-regression-final.log`,
`native-sync-deadline-clippy-final.log`,
`native-control-envelope-helper-compat.log`.

## Remaining owner integration

This fixes local callback synchronization. A production endpoint still needs an
absolute request budget spanning preparation, multi-step effects and completion,
plus separate bounded shutdown/restoration handling. Loop deadlines cannot preempt
arbitrary callback code, filesystem work or CPU scheduling delays. The tested
cleanup adapter owned no scientific graph; populated local-handle release is
source-reviewed, not experimentally qualified here. Remote removal is unknown
when the daemon is stopped.

Runner native ingress, actual caller identity/lifetime, supervisor and calibration
controls remain the next [migration phases](NATIVE_CONTROL_MIGRATION_DESIGN.md).
Their current JSON paths remain explicit debt. Installed science/allocation,
property/parameter lifecycle behavior and target-host qualification must be checked
when those owners migrate. Native serialization alone is not completion evidence.
