# Separate systemd owner services

Status: implemented; selected Copper CPU FGN/JFG + CUDA AOS parity gates pass. Baseline `dde0bf4`, branch
`work/systemd-owners-20261007`, worktree `/tmp/rtc-systemd-owners-20261007`.
The starting tree was clean. Existing desktop and GUI services are outside scope.

## Allocation

The opt-in service backend uses ordinary transient **user services**, launched
with `systemd-run --user --service-type=exec`. systemd owns process creation,
service state, cgroup containment, termination and reaping. The existing headless
coordinator retains native preparation, scientific readiness, source hold/release,
reset, artifact adoption and admission revocation. WirePlumber retains external
link ownership. No scientific algorithms or calibration bytes change.

The default direct backend remains available. The initial service backend is
entered through a generated coordinator user unit, not an arbitrary foreground
process. GUI and CLI use the same native control endpoint in either case.
Installation creates units without enabling or starting them.

## Service identity and cleanup

Each owner unit is named `pipewireao-owner-<coordinator InvocationID>-<role>.service`.
The coordinator verifies its user service MainPID, InvocationID and cgroup before
launching owners. It retains each owner's InvocationID, MainPID, process start
ticks and cgroup. Startup and stop query live systemd identity; steady admission
health uses the retained process identity without launching systemctl on every
poll. Native owner identity and actual thread placement are still verified before
source release. Any owner death revokes admission; there is no automatic owner
restart or adoption of a replacement process.

Owner services use `Restart=no`, `KillMode=control-group`, finite stop deadlines,
role CPU affinity and effective RT/memlock limits. Whole-process FIFO is
not enabled. Runtime roles continue to place their own science/data-loop threads.
This host
does not expose a delegated cpuset controller for owner services: merely setting
AllowedCPUs would not prove enforcement. The initial backend uses CPUAffinity and
verifies all actual thread affinities against the declared envelope before ingress.

Do not attach owner `BindsTo`/`PartOf` stop propagation to the coordinator:
systemd would stop them concurrently with its scientific ingress shutdown.
Normal shutdown first uses the existing native ingress and owner lifecycle,
then asks systemd to stop the retained owner services. A coordinator
`ExecStopPost` invokes the installed `cleanup-systemd-owners` command after normal
exit or abrupt coordinator death. It reconciles invocation-specific units and
pending start jobs, stops the private core and confirms its cgroup empty first,
then stops the remaining services. A core-stop uncertainty fences consumer cleanup.
The complete hook shares a 45-second monotonic budget across listing, identity
queries, pending-job cancellation, stop requests and cgroup confirmation.
The fallback uses the standard systemd service cleanup hook. A coordinator restart receives a new
InvocationID and cannot reuse an old admitted cohort.

The cleanup hook is required and verified before owner creation. Unit names are
exclusive and never restarted/reused within an invocation. A systemd StopUnit
request is name-based, so the identity query and stop are not an atomic
incarnation compare-and-stop. External manual or hostile same-name replacement
is outside this supported workflow; observed replacement identities are rejected.
Its unit pattern
contains the coordinator's 32 hexadecimal invocation identity, never a profile
name, PID or unbounded deployment-wide wildcard. No numeric process-group signals
or child subreaper are used by this backend. Direct backend cleanup stays intact.
An uncertain unit identity fences destructive cleanup and remains an explicit
cleanup failure; it must not silently stop a replacement incarnation.

## Selected closure and evidence

[Installed qualification and independent review](validation/systemd-owners-20261007/README.md)
record the completed selected gates, exact source/artifact identities, original
failures and remaining scope. Runtime directories use explicit lifecycle cleanup;
Julia process-exit temporary cleanup cannot delete deliberately retained failures.

| Contract | Changed allocation / required check | Initial scope |
| --- | --- | --- |
| RTC-DEV-003/013 | systemd services do not acquire node or link authority; WirePlumber retains declared external links and scientific owners retain their nodes | Existing selected session |
| RTC-DEV-019 | Effective user-manager rights, role cgroups, all warmed thread placement before ingress; CPU0/1 excluded | Copper CPU FGN/JFG + CUDA AOS |
| RTC-DEV-020/023 | Generated opt-in unit and relocated SDK; no implicit start; direct default unchanged | Selected installed packages |
| RTC-DEV-021 | systemd owner lifetime; native readiness retained; failed startup, owner death, coordinator death, bounded cleanup and fresh admission | Separate private user units |
| RTC-DEV-022/030 | Same native GUI/CLI and scientific controls; no JSON live controls | Existing contracts unchanged |
| RTC-DEV-025/026 | Held source, native pause/reset/resume; exact prefixes and inclusive simulator allocation/GC tails | Existing CUDA plant and CPU graphs |
| Accepted workstation boundary | One process supervisor, separate link/science owners | Opt-in transfer only |

Verification order: focused parser/identity/command tests; private dummy user-service
startup, failure, descendant cleanup and abrupt coordinator exit; then installed
Copper FGN/JFG clean two-run cohorts, controls/reset, required owner/manager/core
loss and fresh restart. Retain failures and exact source/configuration identities.
Readiness or throughput is never inferred from ActiveState=active. These checks do
not establish latency, deadlines, other profiles, physical safety or general
multiple-endpoint AOS qualification. Remove replaced supervision only after its
corresponding checks pass; direct-mode support is not yet redundant.
