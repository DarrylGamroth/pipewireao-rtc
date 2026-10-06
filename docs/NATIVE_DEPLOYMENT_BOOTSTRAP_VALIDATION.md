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
