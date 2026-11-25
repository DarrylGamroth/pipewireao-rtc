# Direct native Quit from systemd

ExecStop validates its systemd invocation, control PID and cgroup. It checks
the retained RTC PID and start ticks, then connects to the exact private
PipeWire endpoint by owner PID and control instance. The bound node's UUID
and registry identity are verified before submission. ExecStop sends one Quit
and requires its correlated Offline completion. The session HSM decides
whether to accept the command. The existing eight-second request budget and
cleanup after uncertain outcomes remain in place.

## Private-core checks

- The systemd stop selector uses a session endpoint that leaves Status
  unanswered. Against `c2bc141` the endpoint recorded Status and no Quit
  before the stop failed. With direct Quit, the same endpoint received one
  Quit, retained its controller through the terminal reply, and exited
  cleanly. The 108 assertions also cover rejected and unknown outcomes,
  wrong PID, start ticks, control instance, UUID and ledger version,
  missing ledger, replay fencing, and an already exited process.
- The stand-in selector ran its Julia service and stop hook at optimization
  level zero to limit first-use compilation. Two earlier stand-in runs hit
  the request deadline under cold execution. The installed application
  check used the standard launcher and production timeouts.
- The private Classic CPU application reached native Ready and Running with
  the optional analysis configuration from the preceding change. Systemd
  stop acknowledged Quit. The shared launch record reported
  `phase=stopped`, `service_result=success`, `cleanup_complete=true`,
  and `unit_files_removed=true`. The private socket and invocation jobs
  were gone, required and optional units were quiescent, and the journals
  recorded no SIGKILL.
- Focused session stop, runtime, configuration and control-client tests
  passed.
