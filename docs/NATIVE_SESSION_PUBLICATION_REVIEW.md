# Independent session publication and locator review

## Baseline and scope

Review date: 2026-10-06. The immutable root source is
`91eedee0807aae5907520954f2dbdfeab2fe3e8b`. Reviewer worktree:
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-supervisor`,
branch `rtc-native-supervisor`, merged review baseline `844de23` (initially
clean). The six reviewed Julia source files have no diff from `91eedee`.
This review changes only this document. The primary owns all remediation.
The final primary correction is `d0d88c5`; its committed source hashes
match the exact files independently verified below.

Authority is repository AGENTS.md, RTC-ARCH-024 / RTC-DEV-030,
[NATIVE_SESSION_DISCOVERY.md](NATIVE_SESSION_DISCOVERY.md), and
[NATIVE_SUPERVISOR_CONTROL.md](NATIVE_SUPERVISOR_CONTROL.md).
The selected surface is local Julia publication, CLI selection and immutable
locator handoff to calibration/HEART consumers. Same-UID adversarial writers,
installed science, service operation and rendered GUI observation are outside
this source-level review.

## Findings

| ID | Severity | Confidence | Disposition |
| --- | --- | --- | --- |
| NSP-001 | Low | High | Confirmed: selected Julia listing creates missing registry directories; primary correction independently verified |
| NSP-002 | Informational | High | Publication, binding, deadline and cleanup ordering supported by source and scoped checks |
| NSP-003 | Informational | High | Remaining application and installed qualification gates remain open |

### NSP-001 — Selected listing creates the registry

**Observed:** `Deployment.list_sessions` at `deploy.jl:1132` calls
`NativeSessionDiscovery.registry_directory`. That helper invokes
`_ensure_private_child`, creating missing `pipewireao-rtc` and `sessions`
directories. Thus the selected `sessions` CLI path writes the filesystem when
called against a fresh valid XDG root. Listing must remain read-only; directory
creation belongs to publication. No owner request or scientific mutation was
observed, and this is not evidence of wrong-authority access.

**Discriminator:** An external script calls `Deployment.list_sessions` against
a fresh owned mode-0700 XDG root and against a root containing only the
mode-0700 application directory. It requires an empty list, unchanged directory
contents, and no lock file. At `91eedee`, the same eight assertions produce
**5 passed, 3 failed**: the application/registry directories are created.

Evidence is retained under
`~/.cache/rtc-live-controls-20261005/native-session-publication-review-20261006/`:
`readonly-listing.jl` and `readonly-before.log`. The earlier complete pure
selection/discovery run passed **95/95** before this independent discriminator;
those tests did not include a missing-registry listing call.

**Required correction:** Validate only existing owned mode-0700 ordinary
runtime/application/registry directories. Return an empty list when an
application or registry directory is absent. Reject existing invalid paths;
do not create or repair them. Preserve the creating resolver for publication.
The primary accepted this finding and implemented a separate
`existing_registry_directory` resolver and nine regression assertions.
**Verified correction:** The primary's narrow correction adds
`existing_registry_directory`: it validates each existing component with the
same owned ordinary-directory and exact mode-0700 check, returns `nothing` for
absent application/registry components, and performs no creation or lock open.
The selected listing returns an empty typed vector for that absence. Publisher
creation remains unchanged. The unchanged external discriminator passed
**8/8** on CPU 11 after coordination with the bootstrap worker. Its output is
`readonly-after.log` in the same cache directory. The primary's expanded pure
suite passed **104/104**; its retained log was inspected.

Reviewed corrected source SHA-256 values at `d0d88c5`:

| File | SHA-256 |
| --- | --- |
| `deployment/julia/src/deploy.jl` | `7e3aac969ca22b34a0d22287b79a5c5cf8897bb5bd4da1da3181f8a2f6de9efc` |
| `deployment/julia/src/native_session_discovery.jl` | `86b80d2da1e445a3bd7a93a8e4295da929e2c8484f1647800fec8e6b1ddbc331` |

**Disposition:** Confirmed low-severity contract gap corrected by the primary,
independently verified using the same fail-before/pass-after assertions. No
production source was changed by the reviewer.

### NSP-002 — Native identity and private-runtime handoff

**Observed source:** `_run_locked` creates the public inactive supervisor on the
private core, writes the locator and publishes the existing endpoint UUID,
actual supervisor PID, positive endpoint incarnation, exact remote and node
name before its scientific-owner preparation loop. Publication retains its
expected identity before atomic replacement, permitting ordinary cleanup after
a later failure. Retirement compares UUID/PID/incarnation, preserving an
already replaced publication. `stop` accumulates endpoint-close failures and
still attempts discovery retirement and owned process cleanup. Runtime close
sets its closed flag before teardown; the later repeated close is idempotent.
An invalid record is retained for explicit diagnosis under the discovery
contract.

`wait_state` copies one bounded immutable `Locator`, checks the spawned PID
when supplied, connects using that same copy and obtains newly matched native
Status. Later locator replacement is not reread to redirect that client. Live
phase/source/process/runner facts come from the completion. Artifact fields
are copied separately and never substitute for Status success.

The corrected `private_runtime` and `observation_remote` fields use the bound
locator remote's private child rather than the locator file's parent.
Calibration and HEART consumers use these fields. Their action client still
validates actual native owner PID/incarnation/profile; saved process or lifecycle
reports do not establish a successful binding. The retained old/new path
regression in [NATIVE_SESSION_DEPLOYMENT_VALIDATION.md](NATIVE_SESSION_DEPLOYMENT_VALIDATION.md)
is consistent with the source defect and correction.

Explicit session control parses its command before connection and passes one
absolute deadline through selection, fresh Status and the later explicit
request. Native request dispatch checks remaining time before set_param.
Selection retains the exact verified client, including actual global ID,
unsigned serial and fresh query token. It does not retry, rebind or use a JSON
socket fallback. UUID mismatch closes its provisional connection. The known
PID/incarnation failure classification remains Inaccessible as documented in
[NATIVE_SESSION_SELECTION_REVIEW.md](NATIVE_SESSION_SELECTION_REVIEW.md).

**Independent execution:** Julia 1.12.7, CPU 15, existing deployment project,
no dependency installation, Rust build or scientific workload. The separate
read-only pass-after discriminator used CPU 11 with primary authorization and
bootstrap-worker coordination. The actual
private-core `native_supervisor_endpoint.jl` fixture passed **52/52** endpoint
assertions plus **9/9** deadline and **6/6** observation prerequisites. It covers
copied-locator replacement, exact live binding, Preparing rejection, two
controllers, malformed/busy/stale requests, expiry/removal, capacity-before-
effects, partial negative completion and terminal cleanup. Subordinate science
observations are explicit fixtures, not installed scientific owners.
Log: `private-supervisor.log` in the same review cache directory.

**Accepted limits:** The pre-existing Julia ordinary readdir scan bounds
returned record processing, not unrelated same-UID files. Cooperative
filesystem race semantics and private-remote parent canonicalization remain
as reviewed in NSS-004; no new hostile same-UID authentication claim is made.
This increment does not extend the legacy eleven-field source wire deadline.

### NSP-003 — Qualification remains scoped

The primary validation document distinguishes pure tests, actual private-core
selection, zero-frame launcher checks and the actual GUI read-only selection
proof. Those results do not establish installed Classic/Copper science,
FGN/JFG/unchanged HEART application operation, systemd owner bootstrap,
rendered observation, stall/reconnect isolation, allocation or latency.
Those gates remain required. No source-level issue in this review authorizes
promoting those claims.

## Execution commands

From the reviewer worktree:

```sh
taskset -c 15 julia --startup-file=no --project=deployment/julia -e \
  'using PipeWireAODeployment, Test; include("deployment/julia/test/test_native_session_discovery.jl"); include("deployment/julia/test/test_native_session_client.jl")'
taskset -c 15 julia --startup-file=no --project=deployment/julia \
  ~/.cache/rtc-live-controls-20261005/native-session-publication-review-20261006/readonly-listing.jl
taskset -c 15 julia --startup-file=no --project=deployment/julia \
  deployment/julia/test/native_supervisor_endpoint.jl
```

The first run produced 62 + 11 + 3 + 9 + 10 = 95 passing assertions. The
second deliberately failed the unchanged read-only oracle. The third passed
52 + 9 + 6 assertions. Local links, whitespace and final newline are checked
before this artifact is committed. No Mermaid diagram was changed.

Pass-after command from the primary worktree, after CPU 11 coordination:

```sh
taskset -c 11 julia --startup-file=no --project=deployment/julia \
  ~/.cache/rtc-live-controls-20261005/native-session-publication-review-20261006/readonly-listing.jl
```

Primary expanded regression log inspected:
`~/.cache/rtc-live-controls-20261005/native-session-read-only-root-20261006.log`
(62 + 11 + 3 + 9 + 10 + 9 = 104 passing assertions).
