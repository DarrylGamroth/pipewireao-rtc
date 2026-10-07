# Private systemd owner unit probe

Date: 2026-10-07. Design baseline: `dde0bf4`; systemd user manager 257.13.
Probe scope: private non-scientific user units only. No existing services were stopped or changed. Manager reported `DefaultLimitRTPRIO=95`, `DefaultLimitMEMLOCK=4294967296`; effective host cpuset was `0-15`.

## Cleanup-hook result

Coordinator unit: `pipewireao-probe-coordinator-20261007.service`; transient owner units used the design name `pipewireao-owner-<coordinator InvocationID>-probe.service`, `Type=exec`, `Restart=no`, `KillMode=control-group`, `TimeoutStopSec=3`. Coordinator `ExecStopPost` was exactly:

```
/usr/bin/systemctl --user stop pipewireao-owner-${INVOCATION_ID}-*.service
```

Two coordinator starts had distinct IDs `bc12ee8feda142ed812cd106a4513e14` and `07964dd7510943dd81d76e19648c668a`. On normal stop, the first coordinator's SIGTERM handler wrote its stop marker, and then both coordinator and matching owner were inactive (`MainPID=0`, `Result=success`). On abrupt main-process SIGKILL, the second coordinator reached `ActiveState=failed`, `Result=signal`; its matching owner became inactive with `MainPID=0`, `Result=success`. `/proc/*/cgroup` contained no remaining PID for either owner unit. This demonstrates invocation-scoped glob expansion and cleanup after normal and abrupt exits. Owner units had distinct systemd InvocationIDs from the coordinator IDs.

A preliminary run with `$INVOCATION_ID` (without braces) did not expand: journald recorded an invalid literal unit name and the owner stayed active. It was stopped explicitly by its exact unit name. The braced form above passed.

## CPU affinity and cgroup evidence

The owner in the coordinator probe had `AllowedCPUs=2` but no `CPUAffinity=` setting. While it was active, `/proc/<pid>/status` reported `Cpus_allowed_list: 0-15`. Its reported ControlGroup did not resolve under `/sys/fs/cgroup` at the time checked. That probe therefore shows that setting the `AllowedCPUs` property alone did not constrain this process; it did not establish that systemd user units cannot apply affinity.

A separate active unit, `pipewireao-cgroup-check-20261007.service`, was checked with both `CPUAffinity=2` and `AllowedCPUs=2`. While active, its MainPID was 522436, InvocationID `7a03c9579c4d4ccdb7841a6e66be149c`, and ControlGroup `/user.slice/user-1000.slice/user@1000.service/app.slice/pipewireao-cgroup-check-20261007.service`. Its process affinity was CPU 2, and its live `cgroup.events` reported `populated 1`. `cpuset.cpus.effective` was absent. The unit then stopped cleanly; afterward its ControlGroup directory no longer existed under `/sys/fs/cgroup` (so no post-stop `cgroup.events` file remained to read). systemd reported the unit inactive with MainPID 0. This confirms effective process affinity from `CPUAffinity=2` in that active unit, but does not demonstrate enforcement by `AllowedCPUs` alone or a post-stop `populated 0` event value.

No production code or persistent manager configuration was changed. The exact coordinator unit file was removed after the probe; transient owner units are inactive. No global `reset-failed` was run.
