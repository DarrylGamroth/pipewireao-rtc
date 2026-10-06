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

## Remaining gates

Low disk space prevented a new Cargo build during this increment. The new main,
native endpoint and real CLI tests have not yet been compiled/run together;
the fail-before help criterion has not yet been demonstrated against a rebuilt
runner. Required follow-up: focused live Rust tests/check/Clippy, actual updated
runner native foreground/service qualification, and independent diff review.
No installed runtime, scientific allocation, numerical, performance or hardware
qualification is claimed here. NRET-003 through NRET-006 remain outside this
approved removal.
