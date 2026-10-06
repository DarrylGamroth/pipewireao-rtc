# Independent Rust ingress-retirement review

2026-10-06. Bounded source review of `d46cf6eaefee65f4261241819cf01bea063e473f`
and follow-up `cebe0a568ac541826ee461a1aad03f3339c7c352`. Reviewed from the
initially clean `rtc-bootstrap-allocation-review` worktree based on `4cc6ad9`,
using the exact commit objects. This review changes documentation only.

## RETIRE-R001 — Native path security and remaining ingress preserved

**Classification:** verified source review, no new confirmed defect.
**Confidence:** high for the inspected diff. **Disposition:** no additional
remediation requested. This is not independent build or installed evidence.

Affected files: `src/main.rs`, `src/lib.rs`, `src/control.rs`,
`src/native_path.rs`, `src/native_runner_endpoint.rs`, and the changed CLI and
endpoint tests. The retired control/calibration socket adapters and their old
socket fixtures are removed.

Observed and derived results:

- The runner parses arguments before connecting its graph adapter. The retired
  `--control-socket` option now reaches the ordinary unknown-argument error,
  including the equals form; no retired socket is created. Native selection
  still requires its bounded node name, positive instance, and start-paused
  admission. The native branch does not start the console reader.
- Console hold/start-paused operation remains available, with its existing
  bounded line handling and nonblocking reply handoff. The removal changes
  socket-specific plumbing rather than lifecycle execution semantics.
- `validate_socket_path` moved out of the deleted socket server into
  `native_path`. A direct function comparison found only its absolute-path
  diagnostic text changed. It still resolves the parent, requires a directory
  owned by the effective UID with no group/other permissions, and does not
  create or replace an endpoint. `effective_uid` is unchanged.
- `native_runner_endpoint::validate_remote` still applies `symlink_metadata`
  to the final path and requires an actual same-user socket. A final symlink
  remains rejected. Canonicalized parent aliases remain the existing behavior.
  The helper movement does not strengthen the existing same-user threat model
  into a race-free filesystem capability claim.
- `SocketRequest`, socket-server wiring and the public calibration-socket
  module are removed. Typed native commands, local response rendering and
  console control remain. No scientific algorithm or native controller
  identity check changes in this diff.
- Follow-up calibration CLI tests exercise the native CLI's saved-plan
  validation and reject the retired `--endpoint` before plan reading or native
  connection. They do not replace the native calibration protocol's separate
  restoration, cancellation, identity or installed endpoint tests.

The new path tests cover missing and regular files, preservation of existing
contents, a real Unix socket, final symlink refusal and nonprivate parent modes.
The argument tests cover retired options before native/console selection and
absence of retired help text. These tests were inspected; no fresh Rust build
or execution was performed under this review's disk/resource constraint.

The primary's build and software evidence remains in
`docs/LIVE_CONTROL_RETIREMENT_REMEDIATION.md` at the reviewed commits. This
independent pass makes no SCI, systemd, GUI or hardware qualification claim.
