# Local RTC session discovery

Status: bounded listing and exact native selection are implemented and have
private-core fixture evidence. Supervisor publication, installed deployment
and GUI integration remain separate delivery gates.

This contract implements the listing boundary selected for RTC issue #4. A
deployment supervisor publishes a local locator while it is alive. A locator
is a hint for finding the supervisor's public operator endpoint; it is not
health, lifecycle, permission, or proof that the endpoint still has the
advertised identity. The native control contract remains authoritative after
selection.

## Ownership and location

The existing deployment supervisor owns publication and removal. There is no
global broker, systemd-name inference, PipeWire-wide remote scan, or GUI-owned
launch/lifecycle. Each user runtime directory contains:

```text
$XDG_RUNTIME_DIR/pipewireao-rtc/sessions/session-<stable-uuid>.pod
```

The runtime directory and both created child directories MUST be owned by the
effective user, be ordinary directories rather than symlinks, and have owner
access only (mode 0700). Record files and the cooperative writer/remover lock
MUST be owner-only (mode 0600). The discovery module MUST reject inaccessible,
foreign-owned, linked, or incorrectly-permissioned paths. The API never creates
or repairs `XDG_RUNTIME_DIR` itself.

The registry is local to one OS user. It does not grant access to another user,
authenticate hostile processes running under the same UID, or provide remote or
browser discovery. Same-UID processes can already access the selected user
runtime; the private directory prevents accidental cross-user exposure and
symlink/path confusion.

## Native record

Each file contains one exact bounded SPA POD `Struct`, not JSON and not a live
control request. Its fields and order are:

| Field | SPA type | Rule |
| --- | --- | --- |
| Schema version | Int | Exactly 1 |
| Operator label | String | Nonempty UTF-8, no NUL, at most 256 bytes; duplicates allowed |
| Stable session ID | String | Lowercase canonical UUID; equals the UUID in the filename |
| Supervisor owner PID | Id | Positive UInt32 bit value |
| Supervisor incarnation | Long | Positive Int64, new for each supervisor endpoint incarnation |
| Private PipeWire observation remote | String | Absolute socket path, at most 2,048 bytes |
| Supervisor endpoint node name | String | Nonempty ASCII `[A-Za-z0-9_.-]`, at most 128 bytes |

The complete POD is at most 4 KiB. The filename is derived only from the stable
session UUID, so labels do not need to be unique. The fixed record identifies a
deployment supervisor. It cannot identify a standalone Rust runner as an
operator session or authorize bypassing the supervisor for HIL source control.

## Publication and replacement

The supervisor writes a new record to a uniquely created temporary file in the
same directory, applies mode 0600, flushes and closes it, then atomically
renames it over the UUID path. Publication and removal use a nonblocking
cooperative registry lock; concurrent publication/removal fails promptly for
the caller to handle. The owner publishes only its own PID. A replacement
process may reuse a stable session ID but MUST publish a new incarnation.

Removal reads the current record under the lock and removes it only when the
stable session ID, owner PID, and incarnation all match the caller's expected
record. A stale shutdown from an older incarnation therefore cannot remove a
newer supervisor's publication. An invalid or inaccessible record is left in
place for explicit diagnosis; the discovery reader never repairs or deletes it.

## Listing and explicit selection

Listing is bounded to 128 `.pod` candidates. Every well-formed record is
returned as `Unverified`, with no cached lifecycle or health claim. A crash may
leave a stale record; it remains an unverified locator and cannot authorize
control. Malformed, linked, oversized, foreign-owned, or mismatched records are
reported as malformed entries rather than silently treated as live sessions.
Each displayed diagnostic is limited to 512 bytes, and the listing fails as a
whole if it exceeds the entry bound instead of returning a partial catalogue.

Selecting one entry calls an injected verifier with that exact record. The
verifier connects only to the recorded absolute remote and named supervisor
endpoint, then obtains fresh native endpoint identity and status. Its result
must match the stable session ID, owner PID, supervisor incarnation, the exact
remote used for that connection, endpoint name, and deployment-supervisor
authority. The verifier validates the recorded remote with the native client's
owned private-socket check before connecting. The fresh result also carries the
observed PipeWire global ID and `object.serial`, which are returned to the
caller as the selected endpoint identity, plus the positive token of the newly
processed status query. A mismatch is `Replaced`; timeout,
disappearance, or inaccessible endpoint is `Inaccessible`. Neither case
rebinds, retries a mutation, removes the locator, or falls back to saved status.

Lifecycle is taken only from the fresh status result. A stopped but still-live
deployment supervisor retains its endpoint and record and is listed with its
operator label; its fresh status can report `Stopped`. A terminated supervisor
removes its record during ordinary shutdown. A crash can leave a stale entry,
which remains `Unverified` until selection verification fails. No lifecycle,
mutation, acquisition, or gating-observer request is issued by listing or by
this selection verifier contract; the verifier's one fresh status query is
read-only. Later operator controls remain explicit opt-in requests through the
verified supervisor.

`NativeSessionClient.select_session` supplies the native verifier. It connects
once to the exact recorded endpoint, sends one read-only Status, checks the
fresh UUID/PID/incarnation and native global/serial identity, and retains that
same client after selection for later explicit controls. A different fresh UUID
is `Replaced`; a failed connection, including a rejected PID/incarnation match,
is `Inaccessible`. Neither path parses failure messages or rebinds to another
owner. Under an admitted supervisor, a READY or OFFLINE runner maps to
`Stopped`, a RUNNING runner to `Ready`, and a faulted runner to `Fault`; these
are discovery states rather than substitutes for the complete native status.

Independent fixture checks pass 76 assertions for the bounded local contract
and 26 against an actual private-core supervisor, in addition to 15 coordinator
assertions. The [selection review](NATIVE_SESSION_SELECTION_REVIEW.md) records
the exact file-permission correction and the failure classification limit.
These checks do not establish deployment-owned publication, installed science,
GUI selection, Native/WASM portability, or application qualification. RTC issue
#4 remains open until those integration gates pass.
