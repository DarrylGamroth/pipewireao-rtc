# Exact native client socket connection

2026-10-06. Source baseline `943bfa9d9a6e5975c5d1db4ed0c0b455b748a441`.
Dedicated worktree `rtc-native-explicit-socket`, branch
`fix/native-explicit-socket-20261006`, initially clean. The primary approved
the bounded shared-helper design before implementation. Root worktree changes
and the stable GUI executable were untouched.

## NATIVE-CONN-R001 — process remote selector overrides explicit client property

**Severity:** high for exact-session availability. **Confidence:** confirmed.
**Affected:** `native_supervisor_client::Resources::connect` and
`native_calibration_endpoint::Resources::connect`. **Observed:** both used
`ContextRc::connect_rc` with `remote.name` after validating an absolute socket.
The native local-socket implementation prioritizes `PIPEWIREAO_REMOTE` over
that property. A GUI observing one private core can therefore connect its second
session's control client to the first core. The existing exact native identity
proof rejects the wrong owner; no identity bypass or wrong-owner control effect
is established by this review.

An isolated child with two ordinary Unix listeners directly reproduces the
public API mechanism. The old property call produces:

```text
EXPLICIT_SOCKET requested_accepted=false environment_accepted=true
```

The same selection oracle fails, exit101. Using the connected FD produces:

```text
EXPLICIT_SOCKET requested_accepted=true environment_accepted=false
```

The oracle then passes. These are real socket/public PipeWire context calls,
not mocked routing. Neither listener is a PipeWire daemon or scientific core.
The retained before variant changes only the test's transport setup to the
previous public property API; it is not a complete old production executable.

## Selected repair and ownership

One crate-private helper connects to the already validated absolute Unix path
using existing public rustix APIs, with NONBLOCK and CLOEXEC. Immediate success
proceeds; an accepted EINPROGRESS connect is polled under the original remaining
deadline and checked with SO_ERROR. Poll EINTR only recomputes remaining time.
AF_UNIX EAGAIN/full backlog fails immediately: it is not treated as a connected
or pending socket and never retried. Other errors and expiration fail closed.

The helper returns an OwnedFd, consumed by public `ContextRc::connect_fd_rc`.
RAII closes pre-handoff failures; the public PipeWire `core.h` contract states
that the consumed FD is closed on disconnect or error. No raw-pointer or unsafe
cleanup workaround is introduced. Both clients retain existing path/privacy
validation, PID/incarnation/UUID/global/serial proof, original absolute deadline,
bounded controller state and unknown-outcome behavior. No process environment
is changed. The ordinary runner's relative core connection is unchanged.

## Validation and disposition

CPU15, existing offline RTC target, debug0/incremental0: focused socket tests
**3/3 pass**, plus the nested environment child **1/1**. Checks cover conflicting
environment/public FD handoff, nonblocking I/O, invalid/expired/missing paths,
and immediate full-backlog rejection. Child environment is set only at spawn;
the exact owned child has an external deadline. Formatting and Clippy
`--features live --lib --tests -- -D warnings` pass. The existing
`proc-macro-error2 2.0.1` future-compatibility notice remains.

The [receipt](validation/native-explicit-socket-20261006/receipt.json) retains
source/evidence hashes, exact commands, old-route source and before/after logs.
The first compile was stopped after detecting a debug-profile mismatch; the
final compile reused the existing target and rebuilt the RTC crate only.
No new dependencies, large target, GUI rebuild, scientific algorithm edit or
SCI run was performed.

**Disposition:** source mechanism and cold remediation are demonstrated. The
primary must integrate/rebuild the GUI and rerun actual installed duplicate
selection; this review does not convert the failed installed case to a pass.
