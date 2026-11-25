# Optional analysis in the RTC systemd invocation

The installed unit submits optional analysis after its native Ready proof.
The systemd job submission does not wait for graph startup. The existing
`launch.json` retains optional owners and their exact fragments. Required
owner checks skip these roles. ExecStopPost checks and removes the fragments
in the invocation's normal cleanup sweep, with core and source first.

A private Classic CPU session used Julia 1.13.3, PipeWireAO 0.9.2,
PipeWireAO_jll 4.0.2+0, FilterGraphPipeWire 0.5.5 and HIL 0.5.1. Its
application selected RTC candidate tree
`1917ab925a9754f4af05f9773a28013970f53e88` from a temporary depot. The test
copied a previously verified Classic export and added a second analysis
service with an intentionally unresolved Algorithm label.

- Direct `systemctl --user start` returned in 401.3 seconds. The RTC
  reported native Ready and accepted Start. Both analysis units were
  retained in `launch.json`. The invocation created neither
  `analysis.json` nor `analysis.lock`.
- The WFS analysis service reported all four Links ready. The second
  service exited with systemd result `exit-code` and the expected unresolved
  Algorithm error. A fresh RTC status still reported Running.
- Systemd stop received the correlated native Quit acknowledgment. The
  same launch record reported `phase=stopped`, `service_result=success`,
  `cleanup_complete=true` and `unit_files_removed=true`. Both optional
  units and all required owners were quiescent. The invocation retained
  no jobs, private socket, unit links or fragments, and its owner journals
  recorded no SIGKILL.

The focused tests exercised ordinary resource policy, exact fragment
fencing, an expired optional submission budget and cleanup order.

The complete RTC core suite passed after removing the tests for the retired
optional readiness poller.
