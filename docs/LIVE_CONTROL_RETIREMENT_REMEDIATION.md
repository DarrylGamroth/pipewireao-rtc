# Rust live control retirement: NRET-001 and NRET-002

## Scope and source

2026-10-06; dedicated `pipewireao-rtc-jfg-sdk` worktree,
`audit/live-control-retirement-20261006` branch. Starting production revision
`4cc6ad92eac04d9725f36ee9ee436b33d901596d`, clean after the read-only audit
commit `208e22f`. The primary agent authorized only NRET-001 and NRET-002 from
[the retirement audit](LIVE_CONTROL_RETIREMENT_AUDIT.md). No Julia, HEART,
scientific algorithm, saved artifact format or sibling source changed.

## Implemented removal

- Removed production `--control-socket` parsing/advertising, server construction,
  server implementation and the `SocketRequest` wire type. Unknown options are
  rejected while parsing, before connecting a core or loading configuration.
- Removed the public `calibration_socket` export and
  `CalibrationSocketEndpoint` implementation. Its socket-only integration tests
  no longer exercise a supported API and were removed with it. This deliberately
  breaks downstream callers of the retired adapter.
- Replaced the additional obsolete JSON peer fixture in
  `tests/calibration_cli.rs` with native argument rejection and saved-plan
  preflight tests. Its old Unix accept loop would wait for a connection that the
  already-native CLI rejects. Invalid/oversized saved-plan checks are preserved
  using actual native binding arguments before connection.
- Preserved the console reader, typed command preparation/execution, sole
  serialized dispatcher, console line bound and local JSON response rendering.
  Public native control/runner/calibration clients and codecs are unchanged.
- Moved the two filesystem functions previously shared through the JSON server
  to `src/native_path.rs`. Native remote validation still requires an absolute
  path, canonical private parent owned by the effective user, an actual final
  socket and exact effective-user ownership. A final symlink is still rejected.
  No directory, endpoint or replacement socket is created by validation.

The path helper retains the existing parent canonicalization behavior; this
change does not introduce a new filesystem policy. Static comparison with the
starting source verified both production function bodies unchanged except for
one diagnostic naming the native remote instead of the retired control socket.

## Added and preserved verification

New tests:

- Binary parser rejects both obsolete flag spellings before console/native
  selection and leaves the requested socket absent.
- Actual CLI integration rejects obsolete ingress without output, connection
  or socket creation; help no longer advertises it.
- Console parsing/line bounds remain available.
- Filesystem helper checks absolute/private owned parent, canonical parent,
  absent/existing endpoint nonreplacement, and invalid file parent.
- Native endpoint checks absent/regular endpoints, actual Unix socket, final
  symlink rejection and private parent permissions without a running daemon.

Existing owner-loop/nonreentrancy tests are preserved. Native runner mailbox,
native calibration identity/retirement/capacity tests and transport-neutral
calibration coordinator tests remain unchanged. Deleting JSON socket tests does
not constitute new evidence for native restoration, deadline or cleanup gates.

Completed checks on CPU11:

- Targeted rustfmt and `git diff --check` passed.
- Static source searches found no remaining Rust `ControlSocketServer`,
  `SocketRequest`, `CalibrationSocketEndpoint` or socket module selection.
- `rustc --test src/native_path.rs`, using an existing cached `tempfile` rlib,
  passed **2/2** helper tests. Retained compressed executable:
  `~/.cache/rtc-live-controls-20261005/native-path-retirement-tests-20261006.gz`.
  Compressed SHA256:
  `c4d902b7477eabed59ef72401995c194a8e223407c3f2fb6c1158fd758ccc6b9`.
- Fail-before discriminator: retained runner binary SHA256
  `f4f8adf29a28aea11a915d929b671ac1bffec0fbc569d6d4e3766aa5a228f430`
  advertises `--control-socket` under `--help`, violating the new help test's
  exact retirement criterion. This invocation did not connect a core or owner.

## Focused build and pass-after verification

After verified archival provided space, the primary agent authorized focused
offline Cargo qualification. All commands ran on CPU11, one job, in the existing
`~/.cache/rtc-live-controls-20261005/native-filter-target`; no new target directory
or dependency download. Environment: `CARGO_INCREMENTAL=0`,
`CARGO_PROFILE_DEV_DEBUG=0`, `CARGO_PROFILE_TEST_DEBUG=0`, empty `RUSTFLAGS`,
`PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig` and
`LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu`. A process-group guard
would stop Cargo below 60 MiB free; it never triggered (approximately 200 MiB
free after qualification).

```text
cargo test --offline --features live -j 1 --lib --bin pipewireao-rtc
cargo test --offline --features live -j 1 --bin rtc-calibrate \
  --test retired_ingress --test calibration --test calibration_cli
cargo clippy --offline --features live -j 1 --no-deps --lib --bins \
  --test retired_ingress --test calibration --test calibration_cli -- -D warnings
```

Results: **130 passed** (library 86, runner 18, calibration CLI unit 2,
transport-neutral calibration 19, native CLI preflight 3, retired runner ingress
2). Seven actual private-core fixtures remain explicitly ignored; they were not
run or counted as passes. Clippy passed with no repository lint warnings. Cargo
retains the existing dependency future-incompatibility notice for
`proc-macro-error2 v2.0.1`; no unrelated dependency change was made.

The actual rebuilt runner rejects both retired flag spellings without creating
a socket or reading configuration, and its help passes the same criterion that
the retained binary failed. The rebuilt `rtc-calibrate` rejects `--endpoint`
before plan read/connection and validates saved plans before native connection.

Retained cache evidence: `retirement-rust-lib-bin-20261006.{log,json}`,
`retirement-rust-cli-calibration-20261006.{log,json}` and
`retirement-rust-clippy-20261006.{log,json}`. Production source is `d46cf6e`;
the second test ledger records the exact changed calibration CLI fixture hash.
`retirement-rust-evidence-sha256-20261006.json` hashes logs, ledgers and rebuilt
executables.
Original 46,343,832-byte runner was losslessly archived before overwriting the
shared executable, with decompressed SHA verified:
`retirement-before-pipewireao-rtc-f4f8adf-20261006.gz` (compressed SHA256
`282918d31ccb754958c0ae7b7052b41ee24e2976762e46a2cfa9f4840fd339de`).
`retirement-before-runner-20261006.json` records its original path/inode/link
count and known SHA; its original build revision was not reconstructed.

Updated shared `debug/pipewireao-rtc` SHA256:
`7968051f1d4d591414f6cffb995f6efbacc4099ccb881bd3a268e67423f9a341`.
Updated shared `debug/rtc-calibrate` SHA256:
`ce0ba26cf04f64ea1cb730c4b89309592c5097843cc326d867c4ddd1bfe9b1cb`.

## Remaining gates

Actual updated-runner native foreground/service qualification and independent
diff review remain required. No installed runtime, scientific allocation,
numerical, performance or hardware qualification is claimed here. NRET-003
through NRET-006 remain outside this approved removal.
