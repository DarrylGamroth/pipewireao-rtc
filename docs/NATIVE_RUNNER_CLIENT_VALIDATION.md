# Native supervisor-to-runner controls

2026-10-05. Phase C caller evidence under RTC-DEV-030, following the
[runner endpoint](NATIVE_RUNNER_ENDPOINT_VALIDATION.md) and
[migration design](NATIVE_CONTROL_MIGRATION_DESIGN.md). Worktree
`pipewireao-rtc-native-controls`, branch `work/native-control-planes-20261005`,
starting clean revision `0377007`. The
[independent client/deployment review](NATIVE_RUNNER_CLIENT_REVIEW.md) records
the confirmed defects and their dispositions.
The [evidence ledger](NATIVE_RUNNER_CONTROL_EVIDENCE.json) records source,
binary and log identities.

## Implemented boundary

The existing Julia supervisor starts the same Rust runner with an explicit
private remote, node name and positive endpoint instance. It connects a typed
native client, verifies the actual owned PID/global ID/serial/profile/instance,
and waits for its own controller marker's admission. Fresh Status and Start
completions must be successful and have the expected Ready/Running lifecycle
before ingress release. No runner JSON socket or fallback is used.

The client serializes requests, sends each token once and requires an exact
endpoint/controller/token/operation completion or rejection. Invalid local
commands are ordinary rejections before source effects. Submitted unknown
outcomes and source coordination failures still propagate into supervised
cleanup. Cleanup skips native requests after the private core has been revoked;
the existing owned-process cleanup remains available. Source pause, runner
admission and source resume retain their existing ordering.

The public operator broker remains explicitly JSON in this increment. CLI
argument parsing and result rendering at that compatibility boundary are distinct
from the now-native supervisor-to-runner exchange. Prepared/connected/quit files,
HEART reset/health and calibration controls remain migration debt.

## Observed CPU checks

Evidence root: `/home/dgamroth/.cache/rtc-live-controls-20261005`.
The sealed normal runner binary has SHA-256
`71549afe3ca2f235c1264dafc0f18602936de861ad5e549cbc1b70c7c330fb4d`.
Julia is 1.12.7 with registered PipeWireAO 0.6.16 and one BLAS thread.
Focused fixtures use CPU 14 with no requested real-time priority or locked-memory
budget. The SDK can still lock its small transport buffers; the supervisor
fixture records 8,192 locked bytes for the toy owner.

| Check | Result | Evidence |
| --- | --- | --- |
| Final full Julia regression | 1,791 assertions in 69 test sets passed | `native-runner-julia-sealed-regression.log` |
| Native request/result codec | 146 assertions passed | Same sealed regression log |
| CLI parser/presentation adapter | 144 assertions passed | Same regression log |
| Bounded client observations plus two actual connections | 46 unit and 58 private-endpoint assertions passed | `native-runner-client-sealed-serial.log`, `native-runner-client-2016340796032916/` |
| Invalid command regression before correction | Unknown/malformed commands throw out of the broker; invalid Stop attempts source coordination | `native-runner-coordination-before-corrected-fixture.log` |
| Same command path after correction and startup success checks | 29 coordination and 10 admission assertions passed | `native-runner-coordination-after-final.log` |
| Actual deployment supervisor and normal runner, independent final replay | 41 assertions passed | `native-runner-deployment-sealed.log`, `native-runner-deployment-2016880146419963/` |

The deployment fixture uses `Deployment.run`, generated package inputs, a
private core and an owned Julia child with four two-element ndarray endpoints.
The supervisor creates the native runner client itself. Operator requests go
through the remaining public broker and the native internal hop. Invalid command
then fresh Status, Stop, Reset, Start and Quit pass; final state is stopped,
the runtime is removed and the core, runner and toy child are absent. No ndarray
frame is submitted and no sink is armed. The supervisor fixture uses 14 Julia
threads pinned to CPU 14, while the toy owner uses one. It qualifies lifecycle
wiring, not processing concurrency or rate.

The full Julia regression retains existing Git diagnostic output from
temporary exported-package provenance fixtures; those checks passed. It does
not report any failed assertions. Source-owner behavior has focused unit/mocked
coverage here; this launcher fixture specifically covers the no-source-owner
branch. A deployed native-source/HEART/calibration campaign remains a separate
gate when those owner migrations are complete.

Preliminary deployment fixture failures were corrected in the fixture: its
initial runtime exceeded the Unix socket path bound, and a redundant log copy
targeted the same file. The fixture's failure cleanup was separately reviewed
and corrected to preserve process identity and to inspect captured children
even after supervisor exit; a stale-identity check does not signal the live test
process. These are not scientific or runtime implementation fixes.

One sealed-client replay failed during runner link preparation with a
synchronization timeout before client binding (`native-runner-client-sealed.log`).
At that time other qualification processes shared CPU 14. The serial replay
passed using the same source, binary and timeout settings. Scheduling contention
is a hypothesis; the evidence does not establish the timeout's root cause or
loss-free startup under arbitrary contention. The failed log is retained.

## Remaining gates

HEART wrapper controls and their health consumers are next in phase C, with
HEART vendor source unchanged. Calibration/correction source admission,
calibration action server and both clients, public operators and remaining
live readiness/status-file authority follow the reviewed migration order.
Saved configuration, immutable manifests and reports can retain JSON.

These checks do not qualify installed Classic/Copper science, inclusive frame
allocations, deadline distributions, blocked filesystem I/O or physical hardware.
Affected installed campaigns must follow the owner migrations; existing source
allocation and causal-adoption contracts remain required.
