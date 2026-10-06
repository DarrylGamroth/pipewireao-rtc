# Native deployment bootstrap and final audit

Issue #9 follow-up, 2026-10-06. This is functional private-core evidence, with
zero science frames submitted and no scientific or rate claim.

## Confirmed corrections

- The first actual deployment fixture exposed an undefined `hints` binding in
  `wait_state`. Locator hints were assigned inside the polling loop and used
  afterward. Initializing the binding before that loop fixes the scope; live
  admission continues to come from the fresh native supervisor Status.
- The next fixture completed all controls but exposed an invalid post-exit
  `getpid(process)` call in `wait_final_report`. Julia reports ESRCH after the
  process exits. The helper now requires the PID captured from the owned
  launcher, waits for its process completion, then verifies that PID against
  the saved final artifact. The test also matches it to the PID returned from
  the actual native supervisor observation before any controls.
- Persisted and returned supervisor records use `control_locator`; the
  transitional `socket` alias is removed. The locator remains a saved hint,
  not a live request/reply transport or readiness authority.

## Same-fixture verification

The final fixture passed **45/45** assertions, including native Status,
malformed command rejection, session stop, READY reset, restart, terminal quit,
final process/report checks and bounded cleanup. The admitted report has no
`socket` alias. The actual runner binary SHA-256 is
`f4f8adf29a28aea11a915d929b671ac1bffec0fbc569d6d4e3766aa5a228f430`.

The test ran with inherited CPUs 14 and 15; its explicit owner placement
requires CPU 14. An earlier CPU-15-only invocation failed the placement
precondition before launching the core. No affinity assertion was relaxed.

Retained evidence under `~/.cache/rtc-live-controls-20261005/` includes:

| Fixture directory | Observed result |
| --- | --- |
| `native-runner-deployment-2051883801765015` | Undefined locator hints; 3 passed before setup error |
| `native-runner-deployment-2051981781561036` | Controls completed; post-exit PID query errored after 30 passed |
| `native-runner-deployment-2052194055684105` | Final 45/45 passed, source/binary identities and final report retained |

Intermediate fixture assertion mistakes are also retained. They are not
production findings or passing qualification evidence.

This fixture uses an external toy owner and arms no ndarray sinks. It does not
qualify installed Classic/Copper science, simulator allocations, systemd user
services, calibration restoration or target-host latency. Those gates remain
separate under issue #9.

## Ordinary-owner deployment integration (2026-10-06)

The runtime now requires the distinct native bootstrap profile for ordinary
simulator and external graph owners. It validates exact node, per-role
incarnation placeholder and absolute private remote bindings, requires at least
two default Julia threads with no interactive pool, and rejects lifecycle
markers and live file controls. SourceControlV1 remains the separate ordinary
scientific source endpoint.

Startup retains one exact native client for each owner and uses one absolute
preparation deadline for discovery, fresh Status and Connect. Cleanup uses that
retained client for Quit and closes it; missing or uncertain clients are never
reconnected during cleanup. Existing finite process-group revocation remains
available. No runtime marker touches or source JSON request/reply files remain.
`legacy_export_input=true` only permits validating old sealed inputs during
explicit offline export conversion; the runtime constructor uses strict
validation.

Focused schema checks passed **40/40**. Six existing deployment, runner,
acquisition, supervisor, observation and interruption suites passed **432**
assertions, including fresh installed wrapper imports with paths containing
spaces. The first integration run failed cleanup because the new predicate
compared a protocol string with the typed Profile object; using its canonical
profile name corrected that implementation mistake. The original failed log
is retained. Evidence is under `rtc-live-controls-20261005`, in
`native-bootstrap-deploy-{first,second}-20261006.log` and the focused schema log.
These checks submit **zero scientific frames**.

Exporter conversion, independent review and fresh installed Classic/Copper
science, allocation, placement and systemd checks remain required before
issue #9 can close.

### Actual deployment owner handshake

The real launcher fixture now uses native bootstrap for its four non-scientific
ndarray endpoints. The final run passed **59/59**, including native owner
preparation/Connect, absence of all four lifecycle markers, exact publication
and retained session controls, cleanup and final artifact checks. Placement
observed exactly one `rtc-bootstrap` native thread on CPU 14 with SCHED_OTHER
and priority zero. The inherited launcher envelope was CPUs 14/15. No
scientific frames were submitted or ndarray sinks armed.

Evidence: `native-bootstrap-real-launcher-final-20261006.log` and
`native-runner-deployment-2056760444664516`, under the same retained cache.
The first migrated fixture passed 56 checks and failed one obsolete assertion
that still required `toy.connected` to exist. The fixture now checks native
placement and explicitly checks that lifecycle files do not exist; that failed
log is retained. Both fixtures used unchanged runner SHA-256
`f4f8adf29a28aea11a915d929b671ac1bffec0fbc569d6d4e3766aa5a228f430`.
This is launcher/transport verification, not an installed scientific or
systemd qualification.

## Sustained qualification report authority

The selected sustained qualification coordinator now retains its verified native
supervisor client through the run. Fresh SourceControl Status supplies completed,
paused, acquisition generation, sequence and matching report-ready cursor; saved
report presence is never polled for completion. Reset qualification observes the
native generation advance and zero cursor before restarting. The simulator's
cold report writer records the actual acquisition generation in prefix and
sustained artifacts, checked against that native publication before payload hashes
are verified. Its frame computation and allocation measurement boundaries are
unchanged. Private runtime comes from the verified deployment observation rather
than the public locator's parent directory.

Focused coordinator checks pass 130/130, including stale report-generation and
cursor rejection. Scientific report/unit checks pass with the new generation
field; these are software fixtures, not installed SCI qualification. Logs:
`~/.cache/rtc-live-controls-20261005/sustained-native-final-20261006.log` and
`simulator-report-cursor-20261006.log`. The initial new coordinator tests lacked
these helpers and failed as recorded in `sustained-native-before-20261006.log`;
that is implementation evidence, not a reproduced installed stale-report defect.
Installed continuous/reset/midrun-control and inclusive allocation qualification
remain required after the bootstrap allocation fix.

### Verified locator handoff

Independent review found that the sustained coordinator still used the removed
`socket` key after `wait_state` returned `control_locator` (BOOT-R002). The
coordinator now passes the verified deployment UUID and absolute deadline to
the locator connection and checks the exact launcher PID. A mismatched client
is closed before rejection. The focused coordinator suite passes 133/133;
the independent handoff suite passes 6/6, including the wrong-PID cleanup case.
Evidence: `sustained-locator-fixed-20261006.log` under the retained live-controls
cache. These are software checks; installed scientific qualification is separate.
