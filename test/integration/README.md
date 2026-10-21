# Actual headless RTC fault qualification

## CPU-only standard Link qualification

`session_items.jl` uses the existing private-core helper and real
`PipeWireAO.NdArraySource` / `NdArraySink` endpoints. It loads the installed
candidate's production `ao-connections`, upstream Link APIs and RTC-local
control-module binding, checks exact endpoint identities and port IDs,
checks that the link creator client belongs to the actual RTC PID, exchanges
three CPU arrays, and proves link withdrawal while preserving an unrelated node. A separate
WirePlumber daemon shares the private core through a minimal profile with no
device monitors or desktop auto-connect policy; this is process coexistence,
not hardware or full desktop-policy qualification. It starts no systemd
session, simulator, CUDA runtime or physical device. It stops only its own
headless RTC child and private daemon; the evidence directory must be fresh.

```sh
julia --startup-file=no --project=. test/integration/session_items.jl \
  /absolute/path/to/wireplumber-library-prefix /absolute/path/to/rtc-prefix \
  /absolute/path/to/fresh-evidence-directory
```

The candidate uses upstream Link and SessionItem interfaces built against
PipeWireAO, plus the separately inventoried generic Lua/POD bindings. The
RTC prefix contains its native control module; the generated profile selects
Lua and that binding, without SessionItem factories, desktop audio policy or an
all-feature event source. Set `LD_LIBRARY_PATH` with the candidate WirePlumber
library first, then RTC and PipeWireAO dependencies, so an older library cannot
shadow the candidate. Endpoint client PID checks bind Client info; registry announcements
alone do not guarantee the PID property. The fixture leaves the link available
for 30 seconds for first-use compilation and sample exchange, then checks
retirement and remote absence. This is a functional test, not a latency bound.
Logs and `receipt.json` remain in the evidence directory, including failures.

## Actual session fault cases

`session_faults.jl` is opt-in. It creates new private sessions through
`PipeWireAORTC.SessionRuntime`; it never attaches to an existing
session. Use only a sealed, non-actuating simulation or recorded-data package.
Physical DM safe-state actions and operator approval are outside this test.

Prerequisites:

- Linux user systemd with a working user bus and delegated cgroups.
- The package's installed PipeWireAO/WirePlumber dependencies, scientific
  packages, data, and configured CPU/resource rights.
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
The separate `session_policy_faults.jl` qualification checks production Lua
policy ordering with controlled I/O boundaries; its evidence has a different
scope from the installed-session checks above.

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
AOS case against a fresh sealed application separately; for Classic's JFG application,
`--controller-role julia` selects its declared graph owner.

## Deterministic production-policy checks

`session_policy_faults.jl` loads the selected production `ao/session.lua` in
Lua 5.4 and gates its asynchronous source, graph, and link operations. It
exercises the real fault callback with controlled I/O boundaries, without
starting a service or changing the policy. The admitted state is supplied by
the test; native discovery, transport and systemd are outside this check.

```sh
julia --startup-file=no --project=test test/integration/session_policy_faults.jl
julia --startup-file=no --project=test test/integration/session_policy_faults.jl \
  /absolute/path/to/pipewireao-rtc/native/scripts/ao/session.lua
```

The default policy is `/opt/pipewireao/share/pipewireao-rtc/scripts/ao/session.lua`.
Install the Lua 5.4 shared library for this optional test. Output records the
selected policy path and SHA-256; each case creates and closes a separate Lua
state. The seven cases check source-first hold acknowledgement, both graph
holds before withdrawal, first-fault retention/cancellation, unknown source
hold, failed graph hold, uncertain withdrawal, failure before source capture,
and absence of automatic readmission. Several obligations share a case.

| Scenario | Verification surface | Remaining limit |
| --- | --- | --- |
| Source hold before graph hold and withdrawal | Production Lua callback with gated completions | Native/device timing is not measured. |
| Repeated faults, unknown hold, graph/withdrawal failures | Production Lua callback | Controlled I/O failures do not inject native proxy errors. |
| Sink removal, owned link removal, graph-child exit | Opt-in installed-session cases | Each selected sealed package/policy closure needs its own live result. |
| Held Fault with surviving owners, or unknown Hold with complete policy shutdown | Installed-session observations and exact-invocation journals | The finite window does not prove absence of every possible retry. |
| Complete cleanup and explicitly requested fresh admission | Installed-session cases and exact retained identities | This does not qualify physical command disposition. |
| Native sink error and proxy-error injection | Gap: needs a cooperative owned sink or a declared plugin fault mechanism | A remotely bound Node has no public `set_error!` operation. |
| Physical DM safe-state action and approval | Deferred outside the non-actuating RTC profile | The retired JFG harness is not evidence for this RTC path. |
