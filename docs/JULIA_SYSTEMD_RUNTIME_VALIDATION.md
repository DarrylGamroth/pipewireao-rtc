# Installed Julia executable and user-service validation

This record addresses [RTC issue #2](https://github.com/DarrylGamroth/pipewireao-rtc/issues/2)
under RTC-ARCH-020, RTC-DEV-021 and RTC-DEV-023. The source baseline is
`03f72c1f8ef1f10b574f46735d7b7a5e7f4fe027`. The task began in a clean sibling
worktree on `work/systemd-julia-runtime-20261005`; unrelated installed packages
and services were preserved. [The evidence ledger](JULIA_SYSTEMD_RUNTIME_EVIDENCE.json)
records exact sources, package identities, commands and results.

## Executable selection

Installation accepts optional `--julia-executable` with an absolute executable
path. Its default is the actual executable of the installing Julia process.
A bounded startup-free probe validates Julia ≥ 1.12 and < 2 and reports the
runtime executable. Selection through juliaup resolves to that managed runtime.
Generated deployment and calibration/export wrappers all quote and execute the
same absolute path. Foreground and generated systemd units use the same wrapper.

Selection and sealed-wrapper compatibility are checked before copying the
destination. Unsealed installed wrappers are regenerated. A sealed wrapper
must match the generated wrapper for the selected runtime; an incompatible
wrapper is rejected with instructions to export a fresh SDK. Sealed scientific
assets, SDK sources and descriptor hashes are preserved. The selected runtime
must remain installed; choose another runtime through a fresh installation.

## Failure before correction

A fresh CPU-12 toy export was installed by the unchanged baseline installer as
`issue2-julia-before`. Its generated wrapper contained `exec julia`. The actual
user manager reported:

```text
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
```

Foreground preflight with that PATH exited 127. Its exact generated static unit,
copied as `pipewireao-rtc@issue2-julia-before.service`, also exited 127 with
`exec: julia: not found`. No deployment instance or graph was admitted. These
results reproduce the executable lookup boundary without using an existing
operator deployment.

## Adjacent SIGINT correction

After executable selection was corrected, a foreground run reached Running and
answered status, then failed during SIGINT shutdown. SIGINT interrupted the
owned asynchronous control accept task; fetching its result raised
`TaskFailedException` containing `InterruptException`, which the lifecycle
treated as a failure. Owned processes and the instance directory were removed,
but the final phase was failed and the launcher exited unsuccessfully.

A deterministic fixture reproduces this distinction: before correction,
interruption produces the wrong exception and leaves the failed accept task
attached to the owner, while an ordinary accept error remains a real failure.
The correction catches only `InterruptException` inside that owned task and
returns an interruption sentinel. The dispatcher clears the task and translates
only that sentinel to its existing graceful interruption path. Other accept
failures retain `TaskFailedException`; no general exception unwrapping is used.

## Completed gates

| Gate | Observed result |
| --- | --- |
| Baseline foreground/minimal-PATH preflight | exit 127; Julia lookup fails before admission |
| Baseline generated static user unit | exit 127; no graph admission |
| Final installer/deployment regression | 256 assertions pass (44 + 205 + 7) |
| Accept interruption, before correction | 2 pass, 2 fail; wrong exception and retained failed task |
| Accept interruption, after correction | 4 assertions pass; ordinary errors remain failures |
| Fresh installed foreground/minimal-PATH preflight | succeeds |
| Fresh installed foreground readiness/status/SIGINT | Running, status succeeds, exit 0, final stopped with no cleanup errors |
| Fresh generated static user unit readiness/status/systemctl stop | active/running, status succeeds, Result=success, ExecMainStatus=0 |
| Julia identity | foreground and service `/proc/<pid>/exe` identify the same selected Julia 1.12.7 binary |
| Cleanup/environment | owned processes and instance directories removed; task-owned unit files removed; manager environment unchanged |

The deployment tests cover all ten generated operational wrappers under minimal
PATH, explicit selection through a path with spaces and an apostrophe,
relocation/reinstallation, invalid executable/version rejection before copying,
and sealed wrapper preservation or actionable rejection. The interruption
fixture distinguishes graceful interruption from ordinary accept failure.

Installed lifecycle checks reuse the maintained two-link toy NdArray fixture
from `deployment/julia/test/native_runner_deployment.jl`, with CPU 12 and a fresh
installed SDK whose owner project is package-relative. The private core,
external toy owner and Rust runner use public interfaces. The fixture submits
zero ndarray frames and does not arm scientific sinks.

The unmodified generated static user unit uses the manager's existing minimal
PATH, default notification, affinity, limit and shutdown policies. The manager
environment was compared before and after. Each task-owned unit file was removed
and the manager reloaded after its checks. Fresh installed packages and evidence
remain under the task-owned paths recorded in the ledger for inspection.

These are installation and functional lifecycle checks. They do not establish
scientific convergence, throughput, timing, physical hardware qualification or
exclusive CPU ownership. The toy endpoints emit the existing `can't setup mixer`
warnings; admission still observes both exact links, and the checks submit no
frames.
