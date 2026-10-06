# Native supervisor cold runtime and public Rust validation

2026-10-06. Worktree `pipewireao-rtc-native-supervisor`, branch
`rtc-native-supervisor`; production baseline merge `8c91459`, Julia integration
`544eaad`, followed by the containing Rust/client/negative-grammar refinement
commit. CPU15 only. Julia 1.12.7. Shared Cargo target reused with incremental
compilation disabled; no new target directory, scientific core, or vendor edit.

## Actual private-core interoperability command

```sh
taskset -c 15 env JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
  LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
  SUPERVISOR_CLI_BINARY=/home/dgamroth/.cache/rtc-live-controls-20261005/native-filter-target/debug/pipewireao-rtc \
  julia --startup-file=no --project=deployment/julia \
  deployment/julia/test/native_supervisor_endpoint.jl
```

Exact final command output:

```text
Test Summary:                                                       | Pass  Total   Time
typed supervisor carries one absolute deadline through coordination |    9      9  13.2s
Test Summary:                                                           | Pass  Total  Time
unavailable optional observation preserves required admission placement |    6      6  1.0s
Test Summary:                                                  | Pass  Total   Time
actual public supervisor native callers and staged coordinator |   63     63  15.2s
```

The test creates an actual private PipeWire core and public no-port supervisor
endpoint, two retained actual Julia controllers and actual Rust CLI controllers.
It verifies Preparing Status/rejection, admission, typed coordination,
duplicate/conflicting/malformed/busy/stale requests, combined capacity before
effects, accepted expiry/controller removal, terminal Quit flush/owner removal,
actual immutable UUID match/rejection, Rust PID/inc/profile rejection before
effects and explicit negative partial Start followed by fresh Running/paused
Status. The nested runner/source bindings, observations and effect ledger are
explicit mocks. This is transport/coordinator software evidence, not installed
science or hardware qualification.

Validated Rust binary SHA-256:
`f4f8adf29a28aea11a915d929b671ac1bffec0fbc569d6d4e3766aa5a228f430`.
It was rebuilt after the negative grammar refinement and before the final
interoperability run; the subsequent lint fix changes test code only.

## Rust and codec checks

All commands used `taskset -c 15`, `CARGO_INCREMENTAL=0`, existing
`CARGO_TARGET_DIR=/home/dgamroth/.cache/rtc-live-controls-20261005/native-filter-target`,
`PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig` and the library
path above, with offline Cargo:

```text
cargo build --offline --features live --bin pipewireao-rtc
cargo test --offline --features live --lib native_
test result: ok. 45 passed; 0 failed; 0 ignored; 0 measured; 33 filtered out
cargo test --offline --features live --lib
test result: ok. 75 passed; 0 failed; 3 ignored; 0 measured; 0 filtered out
cargo clippy --offline --features live --all-targets -- -D warnings
Finished dev profile successfully
cargo fmt --all
```

The three existing ignored tests require separate native scientific/private-core
fixtures. Cargo emitted its existing dependency future compatibility notice for
`proc-macro-error2 v2.0.1`; no dependency code was changed.

The Julia supervisor codec suite passed 207 assertions after intentionally
regenerating the 48 shared fixtures, including one changed negative fixture and
four new partial/invalid-negative fixtures. Successful and Rejection fixtures
retain their bytes. The old negative grammar is rejected without fallback.
Exact capacity boundary/one-byte overflow checks cover every mutation operation
and the nested error/optional inner result alternative before effects.

Adjacent Julia suites passed native client 23, typed coordination 15, runner
coordination 39, source failure 44, portable deployment 214, source preparation 7
and control interruption 4 assertions. Root independently found and remedied a
`wait_state` hints scope defect while running its actual launcher fixture; that
root-owned deployment fix and installed qualification are separate from this
artifact and must not be inferred from the mock transport proof above.

## Remaining promotion gates

Independent runtime/public client/negative-grammar review (NSCR-004), root-owned
actual launcher/source/HEART binding and cleanup qualification, missing optional
observation queue qualification, discovery and GUI integration remain separate
gates. Simulator SourceControlV1 cannot transmit an absolute owner deadline into
its pre-existing nested HEART reset; the supervisor preserves its accepted
deadline at available native waits and does not claim full V1 inner propagation.
