# Actual WirePlumber RTC fault qualification

`session_faults.jl` is opt-in. It creates new private sessions through
`PipeWireAORTC.WirePlumberSessionRuntime`; it never attaches to an existing
session. Use only a sealed, non-actuating simulation or recorded-data package.
Physical DM safe-state actions and operator approval are outside this test.

Prerequisites:

- Linux user systemd with a working user bus and delegated cgroups.
- The package's installed PipeWireAO/WirePlumber dependencies, scientific
  packages, data, and configured CPU/resource rights.
- A sealed package accepted by the current deployment validator, containing a
  WirePlumber session manager, node-owner declarations, and a source using
  `pipewireao.rtc.calibration-lifecycle/1` with `instrument=classic` or `copper`.
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

Each case captures registry identities and session links, injects one removal
or signals only the verified controller unit's main process, requires Fault
and absent session links, and queries the source's paused state. Three subsequent
observations span 0.6 seconds and check that surviving owner incarnations stay
unchanged, the session stays Fault, and no links reappear. This is a bounded
observation of automatic recovery, not an unlimited no-retry guarantee.

The test then requests cleanup of its exact unit, checks the retained ledger,
empty cgroups, and disappearance of captured processes. A service failure may
remain recorded after successful fault cleanup; the stop exception is retained
and cleanup must still be proved independently. The test explicitly starts a
second fresh cohort, checks new session/owner identities and Ready→Running,
then cleans that cohort up too.

`qualification.json`, `faulted/observed-cleanup.json`, and
`readmitted/observed-cleanup.json` retain the observations. The qualification
receipt records the sealed descriptor and selected Lua policy hashes, plus the
test/tooling source identities. Startup and observation deadlines are finite;
a failed gate does not trigger mutation retries. A cleanup failure remains a
failure with retained diagnostics; the test does not broadly kill services.

Polling does not establish source-first causal ordering or real-time bounds.
The separate `session_policy_faults.jl` qualification checks production Lua
policy ordering with controlled I/O boundaries; its evidence has a different
scope from the installed-session checks above.

## Deterministic production-policy checks

`session_policy_faults.jl` loads the selected production `ao/session.lua` in
Lua 5.4 and gates its asynchronous source, graph, and link operations. It
exercises the real fault callback with controlled I/O boundaries, without
starting a service or changing the policy. The admitted state is supplied by
the test; native discovery, transport and systemd are outside this check.

```sh
julia --startup-file=no --project=test test/integration/session_policy_faults.jl
julia --startup-file=no --project=test test/integration/session_policy_faults.jl \
  /absolute/path/to/wireplumber/src/scripts/ao/session.lua
```

The default policy is `/opt/pipewireao/share/wireplumber/scripts/ao/session.lua`.
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
| Fault retention, held source, no automatic readmission | Installed-session observations | The finite window does not prove absence of every possible retry. |
| Complete cleanup and explicitly requested fresh admission | Installed-session cases and exact retained identities | This does not qualify physical command disposition. |
| Native sink error and proxy-error injection | Gap: needs a cooperative owned sink or a declared plugin fault mechanism | A remotely bound Node has no public `set_error!` operation. |
| Physical DM safe-state action and approval | Deferred outside the non-actuating RTC profile | The retired JFG harness is not evidence for this RTC path. |
