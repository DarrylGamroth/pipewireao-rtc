# Independent native session selection review

2026-10-06. Review worktree:
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-session-selection-review`,
branch `work/native-session-selection-review-20261006`, initially clean at
`c866d8f50d8f24f787d7b6499044dde17c87beb2`.

The reviewed source is the root's concurrent implementation in
`pipewireao-rtc-native-controls`: `native_session_client.jl`,
`native_session_discovery.jl`, their package includes, pure tests and the
private-core selection fixture. Root production edits were preserved. This
review changes only this document; investigative scripts and logs are external
cache artifacts. DeploymentRunner publication/removal is not qualified by this
review, and the GUI picker is a separate consumer gate.

## Authority and reviewed identity

Authorities are repository `AGENTS.md`, active RTC-ARCH-024 / RTC-DEV-030,
[local discovery contract](NATIVE_SESSION_DISCOVERY.md),
[integration handoff](DISCOVERY_INTEGRATION_HANDOFF.md), and the public supervisor
profile. Discovery records are unverified hints, not saved lifecycle authority.
The same-UID registry is not an adversarial authentication mechanism.

The initial reviewed source SHA-256 identities are:

| Source | SHA-256 |
| --- | --- |
| `deployment/julia/src/native_session_client.jl` | `006ac878ca1cc98196a5f3e78ba27f322d08b5a522401963ae9d6a840025267e` |
| `deployment/julia/src/native_session_discovery.jl` | `8b5201b6b509081333e14de12aa3f8f8290d6be072be518cb01ad6d27670676b` |
| `deployment/julia/test/native_session_client.jl` | `ba9c5e686f0fb5f0fe35e76fb2483f9fd211e28c776fb7b2dbb3cbdb400b652a` |
| `deployment/julia/test/test_native_session_client.jl` | `bec971818f20e418ad25e840bad7614f529d3757186d71db2d09c3373b3031df` |
| `deployment/julia/test/test_native_session_discovery.jl` | `3da3acd614f3145bb268b453d0192e77d7ac5264ee9c780ff792d48106f920b4` |

| ID | Severity | Confidence | Disposition |
| --- | --- | --- | --- |
| NSS-001 | Low | High | Confirmed mode constraint gap; primary remediation independently verified |
| NSS-002 | Informational | High | Changed PID/incarnation rejected; replacement classification needs a typed common-client distinction |
| NSS-003 | Informational | High | Exact fresh status and retained connection reviewed; production publication and application qualification remain open |
| NSS-004 | Informational | High | Bounded codec, cooperative publication and listing races reviewed |

## NSS-001 — Reader and lock validation do not require mode 0600

**Evidence and analysis:** The discovery contract requires record files and the
cooperative lock to be mode 0600 and rejects incorrectly permissioned paths.
`native_session_discovery.jl:209–218` checks a regular file, effective UID,
absence of group/other bits and owner read permission. It does not require owner
write or forbid owner execute. Modes 0400, 0500 and 0700 satisfy that predicate.
Lock validation at lines 239–242 similarly checks only regular-file status,
UID and absence of group/other permission bits.

The publisher creates its own files at 0600. The gap concerns reading an
existing incorrectly permissioned record and accepting an existing executable
lock. The same-UID ownership and native endpoint proof remain enforced. This
is a constraint mismatch, not evidence of cross-user access or hostile same-UID
authentication bypass.

**Proposed remediation:** Check the contract's exact permission bits in the
record and lock validators. Preserve explicit rejection rather than repairing
an existing entry during listing or selection.

**Required validation:** Valid 0600 publication still lists as Unverified;
0400/0500/0700 records classify as Malformed and an incorrectly permissioned
lock rejects publication. Retain the same discriminator before and after the
owner's remediation.

**Verified correction:** The same CPU-15 discriminator initially reported
**1 passed, 4 failed**: all three invalid record modes remained Unverified and
lock mode 0700 did not reject publication. The primary accepted the finding and
changed file/lock permission checks to `(mode & 0o7777) == 0o600`, with exact
0700 directory checks including rejection of special bits. Source changes are
limited to those permission predicates. The owner added five regression checks
for record modes 0400/0500/0700/4600 and lock mode 0700.

The reviewer inspected the correction and reran the unchanged external
discriminator: **5 passed, 0 failed**. Its source and before/after logs are
`~/.cache/rtc-native-session-selection-review-20261006/permissions.jl`,
`permissions-before.log` and `permissions-after.log` in the same directory.
The corrected discovery source SHA-256 is
`fa53dcbe492d849e9480682705d01952869e95e1b6c2d2d05b71ac9a8960a997`;
its updated pure test source is
`be14dedea6be44cb4c27884cc0c2c67544c18838559518d275d2870efd079e42`.

**Disposition:** Confirmed low-severity contract gap corrected by the primary,
with the same discriminator failing before and passing after. No production
file was edited by the reviewer.

## NSS-002 — Replacement classification has a common-client limit

**Observed source:** `NativeSessionClient.select_session` supplies the selected
record's exact PID and incarnation to `NativeSupervisorClient.connect`. The
common client checks actual bound NodeInfo against those values, the supervisor
profile and protocol; it also checks the owner and controller global IDs and
serials, retained capabilities and actual controller admission. Wrong values
cannot produce a retained selected connection.

A newly observed different UUID can proceed through one read-only Status query
and becomes Replaced when compared with the record. PID/incarnation mismatch
instead fails during connect and the current adapter maps that generic failure
to Inaccessible. This preserves failure and requires explicit selection; it
does not reconnect, parse exception text, retry a mutation or use saved status.

The discovery contract distinguishes mismatching fresh verifier results from
connection failure. Consistent Replaced classification for an observed changed
owner would require a typed common-client identity-mismatch result, independent
of the request/reply wire schema. The primary accepted this as a known
integration limit and retained Inaccessible as the explicit fail-closed result. It is not a wrong-authority defect in this adapter.

**Required validation:** If the classifier contract is extended, distinguish
an actual observed PID/incarnation replacement from timeout, missing endpoint,
malformed metadata and inaccessible remote. Preserve the no-rebind/no-query
boundary after failed identity validation; do not infer replacement by parsing
error messages.

**Disposition:** Explicit implementation limit / primary decision, not a
confirmed control-authority defect or authorization to edit the common client.

## NSS-003 — Fresh selection retains the connection that supplied proof

**Observed source and derived behavior:** The module connects once to the
recorded absolute private socket and exact endpoint name, sends one Status
command, and retains that client only after comparing UUID, PID, incarnation,
remote, node name and deployment-supervisor authority. It returns the observed
owner global ID, object serial and positive newly processed query token.

The common client validates the owned private socket before connecting, actual
NodeInfo profile/PID/incarnation, the immutable nonzero canonical supervisor
UUID, retained capability and admitted controller identity. The fresh reply
must match endpoint incarnation, actual controller global ID/serial/instance,
token and operation. `_fresh_status` checks client health while holding the
same ThreadLoop lock before reading that bound identity. The authority symbol
is therefore backed by the supervisor-specific client/profile check; it is not
trusted from the listing record.

Selection sends no mutation and does not query a source directly. Listing
performs no native request. A mismatch closes the temporary client; a query or
connection failure closes it before returning Inaccessible. Later explicit
operator commands use the retained client without reconnect or fallback.
`close(connection)` delegates to the serialized common-client teardown, which
closes bound nodes, controller marker, registry, core/context and ThreadLoop.
Cleanup failures remain exceptions rather than fabricated selection success.

Lifecycle uses the fresh supervisor phase and runner Status. Preparing maps to
preparing, Failed to fault, Stopping/Stopped to stopped. An admitted runner
Ready or Offline maps to stopped, Running to ready, Fault to fault and other
states to preparing. An admitted Status without a runner is rejected.

**Coverage:** The package includes discovery and then selection after the
supervisor client, so its imports use the existing package modules. The pure
fixture checks lifecycle and malformed/retired listing behavior. The actual
private-core fixture checks preparing/admitted/stopped selection, UUID mismatch,
positive query token, bound global/serial, separate actual controller identity,
no fixture effects during selection, explicit later Stop, endpoint removal,
no rebind after removal, and record cleanup. Its backend is a coordinator
fixture, not an installed scientific owner.

**Disposition:** Source supports the selected boundary. Before the permission
correction, the reviewer independently ran **71/71 pure assertions** and
**26/26 private-core assertions plus 15/15 coordinator checks** on CPU 15.
After correction, the expanded pure suite passed **76/76** and the same
private-core/coordinator fixtures again passed **26/26 + 15/15**. The latter uses an actual native connection and exact status query, with a
fixture supplying subordinate owner observations. These tests do not establish
DeploymentRunner publication/removal, installed cross-process scientific owner
status or GUI selection.

## NSS-004 — Local filesystem and record bounds preserve hint semantics

The record codec checks one exact outer length, seven fields and scalar
widths/types. Constructors enforce positive PID/incarnation, lowercase UUID,
nonempty bounded UTF-8 strings and the ASCII node-name alphabet. Maximum input
is 4 KiB before copying; the underlying SDK String parser requires exactly one
final terminator, while Struct parsing checks child headers and padded extents.
A filename UUID mismatch becomes Malformed. Diagnostics are capped at 512 UTF-8
bytes. Listing fails if more than 128 `.pod` candidates are present and returns
only Unverified valid entries. It never deletes or repairs a stale entry.

The runtime directory and created children are validated by lstat as private
owned directories, excluding final-component symlinks. Publisher/remover use a
nonblocking cooperative flock and unique temporary file plus atomic rename.
Removal compares UUID/PID/incarnation under that lock, preserving a replacement
from stale shutdown. A reader bounds its read and checks inode/device before
and after; concurrent atomic replacement/removal can yield Malformed rather
than a retry or a partial trust claim. A previously read old record remains a
hint and must pass fresh exact native verification before selection.

The directory scan uses ordinary readdir before counting matching candidates;
the 128 limit bounds returned record processing, not arbitrary unrelated
same-UID directory contents. These mechanisms are cooperative local-user
behavior, not resistance to a hostile same-UID writer changing path components
or file contents in place. The reviewed contract excludes that threat model.

**Disposition:** No additional confirmed defect within that model. NSS-001 is
the corrected exact permission constraint exception. Filesystem fixture
execution and application publication qualification remain distinct.

## Independent execution record

All runs used Julia 1.12.7 with the root's existing deployment project and
source Manifest, `--startup-file=no`, and CPU 15. No dependency installation,
new Rust target or scientific workload was started. The private-core fixture
created and cleaned its own bounded local daemon.

Pure command, from the root source worktree:

```sh
taskset -c 15 julia --startup-file=no --project=deployment/julia -e \
  'using PipeWireAODeployment; include("deployment/julia/test/test_native_session_discovery.jl"); include("deployment/julia/test/test_native_session_client.jl")'
```

Before the correction: **57 + 11 + 3 = 71 passed**. After the correction:
**62 + 11 + 3 = 76 passed**. The only added assertions are the five permission
regressions. Logs are `pure-review.log` and `pure-after-review.log` under
`~/.cache/rtc-native-session-selection-review-20261006/`.

Actual native connection command, from the same source worktree:

```sh
taskset -c 15 julia --startup-file=no --project=deployment/julia \
  deployment/julia/test/native_session_client.jl
```

Before and after the correction: **26 passed** in the actual session-selection
fixture and **9 + 6 = 15 passed** in its included coordination fixtures. Logs
are `private-core-review.log` and `private-core-after-review.log` in that same
cache directory. Final diff inspection confirmed the reviewer changed only
this document. Local Markdown links, whitespace and final newline were checked.
