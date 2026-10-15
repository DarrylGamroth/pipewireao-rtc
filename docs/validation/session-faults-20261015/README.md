# RTC fault-test ownership and validation

The standalone JFG supervisor and its ALPAO recovery harness were retired at
JFG commit `45f3dd6`. Their historical results do not qualify the selected RTC.
These tests keep WirePlumberAO as session authority and systemd as process owner.
Physical DM authority, safe-state actions and operator approval remain deferred.

## Software checks

- RTC package suite: **1,850 assertions in 53 reported testsets passed** on
  Julia 1.12.7, using the test workspace and the existing dependency lock.
- `test/integration/session_policy_faults.jl`: **7/7 cases passed** for each of
  the installed, current-source and cached FGN deployment Lua policies. The test
  controls I/O completions and admitted state; it does not qualify native
  discovery or timing.
- Two temporary mutation controls failed as intended: removing first-fault
  deduplication and issuing a graph hold before source acknowledgement.
- Independent review reproduced and verified fixes for two new-test defects:
  nonthrowing assertions could permit readmission/`completed=true` after a failed
  invariant (RTF-001), and cleanup observation could erase the original stop
  error (RTF-002). Throwing gates now stop progression; stop, observation and
  reconciliation errors remain separate. Controlled verification observed
  exactly one stop mutation after an unknown outcome.
- Four checks against an actual private PipeWire core passed for registry
  observation and node/link removal plumbing. Six independent controlled checks
  passed for trusted client PID matching and node-incarnation retention. These
  checks do not establish session admission or fault containment.

| Selected Lua policy | SHA-256 |
| --- | --- |
| Installed `/opt/pipewireao/share/wireplumber/scripts/ao/session.lua` | `973396341b941d74f1dc95a87b1b8c2e21cf425766fb5661d6719fdf4639771b` |
| WirePlumber source at `d20cd203`, `src/scripts/ao/session.lua` | `bb232ff9a615cb205a71558bab1b5a264d0f989c8ac9ad9d1e12e2bf008869d6` |
| Sealed `split-fgn-release-fixed/wireplumber/scripts/ao/session.lua` | `de0ba4765cdec06916dd035f41be348bb6ed167386fa0517e4276e197148e407` |

## Installed-session attempts

The first sink-removal attempt used the unchanged cached calibration package
`rtc-registry-shutdown-20261009/split-jfg-release-fixed-v2` and fresh stage
`/tmp/rtc-sink-fault-test-20261015-jfg`. It timed out before admission; **no sink
fault was injected and no recovery claim follows**. Source dependency
precompilation consumed 167 seconds. AOS CUDA extension precompilation completed
shortly before the publication deadline; the later shutdown stack still showed
compiler inference during AOS graph preparation. The first observed service
failure was `direct session did not warm before publication deadline`.

The owned startup reconciler retained `cleanup_confirmed=true`,
`cleanup_complete=true`, a quiescent session unit, empty owner cgroups and no
remaining captured processes. Startup budgets were not increased. The stage
retains `qualification.json`, `faulted/start-failure.json`,
`faulted/final-launch.json`, `faulted/observed-startup-cleanup.json` and the
owned journals. Those host-local artifacts are not copied into this repository.

A second attempt used unchanged `split-fgn-release-fixed` and fresh stage
`/tmp/rtc-sink-fault-test-20261015-fgn`. It also exceeded the publication deadline
before admission, with CUDA dependencies still being precompiled. The source's
shutdown exceeded its stop budget and systemd terminated it. Exact cleanup was
independently confirmed: retained processes were gone, owner cgroups were empty,
the session unit was quiescent, and the final ledger reported
`cleanup_complete=true` without cleanup errors. This confirms containment of
the failed startup, not graceful source shutdown or an admitted-session fault.

Each installed invocation uses a fresh isolated Julia depot and copied sources,
so the previous attempt's completed precompilation does not by itself make a
plain retry warm. No cache overrides, descriptor changes or longer startup
budgets were introduced. **Live sink/link loss, graph-child exit and fresh
readmission remain unqualified**; neither attempt reached fault injection.

The [test procedures and coverage matrix](../../../test/integration/README.md)
keep live loss/readmission results separate from the deterministic policy tests.
Neither passing software checks nor a startup timeout establishes physical
command disposition, sustained deadlines, or full scientific-profile coverage.
