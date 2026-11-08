# Actual headless RTC fault qualification

## Classic CPU Ready-to-Quit regression

`classic_shutdown.jl CPU_APPLICATION FRESH_STAGE NATIVE_PREFIX` starts a fresh
non-actuating CPU session, requests one native Quit and checks exact owned
process/cgroup cleanup. Use the registered Classic project and pinned depot,
the prefix's client config/module/SPA/library paths, and empty CUDA/ROCm device
visibility. Automatic package GC and precompilation should be disabled.
The test retains native identities, installed hashes and manager/owner journals;
success is written only after the outer testset passes. It does not retry an
unknown operation. Cleanup elapsed time includes systemd owner termination and
is distinct from the unchanged five-second native effect bound.

See the [shutdown qualification](../../docs/validation/classic-shutdown-20261021/README.md)
for the native memory regression, deployment and fault recovery evidence.

## Managed Classic CPU closed-loop replay

This replay used the former RTC simulator launcher. The
[detector validation record](../../docs/validation/classic-detector-20261022/README.md)
identifies its pinned source and collected test harness. Current simulation
execution and its integration selectors are in AdaptiveOpticsSimPipeWireHIL.

## Current Julia session-policy checks

The cold policy selectors exercise the Hsm machine, typed effects, object
binding/link lifecycle, ingress and transport without a WirePlumber host or Lua
runtime. The machine selector is included in `test/runtests.jl`; the effects,
objects, ingress and transport selectors are included there as well.

```sh
julia --startup-file=no --project=. test/test_media_session.jl
julia --startup-file=no --project=. test/media_session_effects.jl
julia --startup-file=no --project=. test/media_session_objects.jl
julia --startup-file=no --project=. test/media_session_ingress.jl
julia --startup-file=no --project=. test/media_session_transport.jl
```

Optional `media_session_private_core.jl`,
`media_session_acquisition_private_core.jl`, `media_session_host.jl` and
`media_session_process.jl`
checks need the current source
environment with the PipeWireAO public `iterate!` API and a matching native SDK
prefix. They own only a private core and test processes. Session control needs
one owning Julia thread and no journal worker pool. Use `--threads=1,0` and set
`PIPEWIREAO_PREFIX` to the matching PipeWireAO SDK:

```sh
PIPEWIREAO_PREFIX=/absolute/path/to/pipewireao-sdk \
  julia --startup-file=no --threads=1,0 --project=/absolute/source-environment test/media_session_private_core.jl
PIPEWIREAO_PREFIX=/absolute/path/to/pipewireao-sdk \
  julia --startup-file=no --threads=1,0 --project=/absolute/source-environment test/media_session_acquisition_private_core.jl
PIPEWIREAO_PREFIX=/absolute/path/to/pipewireao-sdk \
  julia --startup-file=no --threads=1,0 --project=/absolute/source-environment test/media_session_host.jl
PIPEWIREAO_PREFIX=/absolute/path/to/pipewireao-sdk \
  julia --startup-file=no --threads=1,0 --project=/absolute/source-environment test/media_session_process.jl
```

These are functional private-core checks; they do not qualify service
deployment, physical hardware, deadlines or real-time behavior. The previous
standard-Link/WirePlumber coexistence selector was implementation-specific and
has been retired. Its source remains in [Git history](https://github.com/DarrylGamroth/pipewireao-rtc/blob/4f7eaff/test/integration/session_items.jl);
its results apply only to the earlier implementation.

## Installed-session fault cases

These selectors are being migrated to the direct Julia session host. Earlier
receipts concern the WirePlumber implementation and do not qualify its
replacement. Each selected application/source cohort needs a fresh lifecycle
and fault result; cold helper checks alone do not establish readiness.

`session_faults.jl` is opt-in. It creates new private sessions through
`PipeWireAORTC.SessionRuntime`; it never attaches to an existing
session. Use only a sealed, non-actuating simulation or recorded-data package.
Physical DM safe-state actions and operator approval are outside this test.

Prerequisites:

- Linux user systemd with a working user bus and delegated cgroups.
- The matching PipeWireAO client/SDK source cohort, scientific packages, data,
  and configured CPU/resource rights. No Lua or libwireplumber RTC dependency
  is required by the selected host.
- A sealed package accepted by the current deployment validator, containing a
  headless RTC application, node-owner declarations, and a source using
  `pipewireao.rtc.calibration-lifecycle/1` with `instrument=classic` or `copper`,
  or an AOS source using `pipewireao.source-control/1` with an exact control node.
- A fresh stage root. The test retains its receipt and installed assets there.

From the RTC checkout, instantiate its existing project, then select one case:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=. test/integration/session_faults.jl \
  /absolute/path/to/sealed-package /absolute/path/to/fresh-sink-stage \
  --case sink-removal --sink simulator-command

julia --startup-file=no --project=. test/integration/session_faults.jl \
  /absolute/path/to/sealed-package /absolute/path/to/fresh-link-stage \
  --case link-removal

julia --startup-file=no --project=. test/integration/session_faults.jl \
  /absolute/path/to/sealed-package /absolute/path/to/fresh-controller-stage \
  --case controller-exit --controller-role julia-command
```

Names above are examples; select an exact declared sink or external graph-owner
role from the supplied package. `--prefix PATH` selects the installed native
prefix (default `/opt/pipewireao`). `--help` prints the complete CLI. Run cases
serially, each with its own fresh stage root. Existing HIL and other sessions
are not test targets.

Each case captures registry identities and session links, then injects one removal
or signals only the verified controller unit's main process. It qualifies two
policy outcomes separately. A confirmed source Hold permits the session to stay
Fault with withdrawn links and surviving owners. An unknown Hold requires the
native policy to disconnect its endpoint and systemd to finish emergency
cleanup. The test does not require a stopped source acknowledgement when the
outstanding command was lost, and it does not create another cancellation path.

For the held outcome, calibration sources use the existing public paused-state
query. AOS sources use read-only `pwao-dump` inspection of the existing run-control
ACK and source snapshot. The AOS check binds the retained node ID/serial, mailbox
instance, authenticated client PID and live source process incarnation. It
requires a new stopped run ACK after the fault and a valid saved report matching
the acknowledged report cursor. That report can precede the held acquisition
cursor. The snapshot is the last owner acknowledgement, not continuous cursor
telemetry. Three subsequent observations span 0.6 seconds and check that surviving
owner incarnations stay unchanged, the session stays Fault, and no links reappear.
This is a bounded observation of automatic recovery, not an unlimited no-retry
guarantee.

For policy shutdown, the exact manager invocation's journal must publish the
source-Hold-uncertain emergency-cleanup reason. The test observes cleanup without
sending another stop to a closed or deactivating manager. Both outcomes require
the retained cleanup receipt and disappearance of every captured owner/manager
process with empty cgroups and a quiescent manager unit. These checks settle
together within a finite 320 second observation budget: `cleanup_complete` alone
does not prove that `ExecStopPost` has exited. Changed intermediate checks and
failed observations remain recorded. A service failure may remain in the receipt
after successful emergency cleanup; the test retains that failure.

The exact manager and source invocation journals are saved. The first policy
Fault in a link-removal case must name the injected link ID/serial; a later
source-port removal does not qualify the injection. Any logged source-command
timeout must follow that first Fault. This compares journal events, without
claiming when a missing command began waiting. The receipt also records the
actual selected prefix's policy hashes. The test explicitly starts a second
fresh cohort, checks new session/owner identities and Ready→Running, then cleans
that cohort up too. Only an exact active manager may receive an explicit stop.

`qualification.json`, `faulted/observed-cleanup.json`, and
`readmitted/observed-cleanup.json` retain the observations. The qualification
receipt records the sealed descriptor and selected Lua policy hashes, plus the
test/tooling source identities. Session Ready/Start/Running checks use the
verified native session controls. The calibration-specific `W.ready` projection
is retained only for binding the calibration source query; AOS admission does
not use that projection. Each startup deadline includes the deployment's
`startup-timeout-ms` plus 130 seconds for bounded installer/manager setup, so
a declared 900 second cold preparation budget receives a 1,030 second outer
budget. Startup and observation deadlines are finite;
a failed gate does not trigger mutation retries. A cleanup failure remains a
failure with retained diagnostics; the test does not broadly kill services.

Polling does not establish source-first causal ordering or real-time bounds.

## Cold source-contract checks

Run the source profile, startup-budget, ACK identity and report-cursor tests
without starting a service or loading a scientific plant:

```sh
julia --startup-file=no --project=. test/integration/test_session_fault_helpers.jl
```

These tests preserve Classic/Copper calibration declarations and admit AOS
source-control declarations. They reject stale hold ACKs, changed node/mailbox
or authenticated owner identities, invalid scalar fields and invalid report
cursors. They distinguish held and policy-shutdown proof, reject secondary or
wrong-incarnation link faults, and exercise delayed receipt/process/cgroup cleanup
observations with a controlled clock. They preserve failed observations when a
later read settles. They do not establish live fault recovery. Run each selected
AOS case against a fresh sealed application separately; for Classic's FilterGraphs application,
`--controller-role julia` selects its declared graph owner.

## Retired production-policy selector

`session_policy_faults.jl` exercised the old production Lua policy and was
retired with that implementation. Its source remains in [Git history](https://github.com/DarrylGamroth/pipewireao-rtc/blob/4f7eaff/test/integration/session_policy_faults.jl).
Historical event-ordering evidence does not qualify current Julia policy. The
new machine/effect and native private-core selectors above cover the current
source surface; installed failure/re-admission integration remains a separate
migration gate.
