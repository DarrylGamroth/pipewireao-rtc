# Classic CPU shutdown cleanup review — 2026-10-21

## Scope and source

Independent bounded review of the stopped-session ledger change in
`src/deployment/session_runtime.jl` and its focused regression checks in
`test/test_session_configuration.jl`. The implementation worktree is
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-classic-live-cpu`, branch
`codex/classic-live-cpu-20261021`, initially based on
`b3da62bba41799b53a5a9a18d4653124b0c00c98`. The initial worktree changes were the
runtime fix, its tests, and the RTC candidate version change from 0.2.0 to 0.2.1
in Project/Manifest. The reviewer made no production edits or service changes.
The sealed implementation commit is
`4d13493f6e4e91e260c71e6ba65636dc5483b32e`; its diff matches the reviewed change.

Authority: RTC-DEV-021 requires exact incarnations, bounded cleanup, and unknown
cleanup to remain a fault. RTC-DEV-031 requires accepted native Quit to Offline
and confirmed cleanup before replacement startup. This review covers that
specific shutdown boundary, rather than the full configuration replacement
implementation or scientific/timing qualification.

## Finding CLCPU-01

| Field | Assessment |
| --- | --- |
| Severity | High: completed shutdown prevented a valid replacement and was reported as unknown |
| Confidence | Confirmed from source and retained failed-operation evidence |
| Affected code | `SessionRuntime._stopped_record`, formerly calling `_ledger` |
| Disposition | Resolved: fixed and validated in the selected CPU replacement and final owned shutdown |

**Observed:** the original operation
`c73e64932cca499189250c171e7ef081/result.json` reports `state=unknown`,
`cleanup_confirmed=false`, and `session MainPID is not the exact prepared
headless RTC executable`. Its previous RTC launch ledger binds unit
`pipewireao-session@a82deb353a6f.service`, invocation
`eff167689fc24f07883329b15963825a`, PID 3889254, and start ticks 112056039.
That ledger retains `service_result=success`, `cleanup_complete=true`,
`phase=stopped`, and `error=null`.
The original stage's `shutdown-attempt.json` also binds that unit and invocation
with `accepted=true`.

Durable copies preserve the original
[unknown result](../../validation/classic-live-cpu-20261021/before/result.json),
[accepted Quit fence](../../validation/classic-live-cpu-20261021/before/shutdown-attempt.json),
and [stopped launch ledger](../../validation/classic-live-cpu-20261021/before/final-launch.json).

**Derived from source:** `_stopped_record` enters its ledger-read branch only
after proving the exact old PID/start-time is absent. `_ledger` then calls
`verify_session_process`, which requires `/proc/<old-pid>/exe` and the exact
command line to exist. The successful cleanup branch therefore cannot satisfy
that live-process requirement. PID reuse does not repair this contradiction:
it would make verification depend on an unrelated process.

The selected fix separates `_retained_ledger` from `_ledger` and calls the former
only at this stopped-session branch. The retained read still rejects a mismatch
in all five existing bindings: unit, invocation, invocation runtime directory,
PID, and start ticks. The `_ledger` wrapper continues to verify the native
executable and private configuration for every live caller, including startup,
Ready selection, and controls.

Before the changed call, `_stopped_record` still requires the manager's retained
invocation and cgroup, when present, to match the handle; a quiet unit with zero
MainPID; no queued unit job; the exact old process gone; and the retained cgroup
empty. It then still requires the exact ledger's `cleanup_complete=true` and no
cleanup errors. `_retain_stopped!` additionally requires `phase=stopped` and
`error=null`. Native shutdown acceptance and the durable attempt fence remain
separate requirements in `_native_quit!` and `reconcile_shutdown!`. No automatic
retry or alternative session selection is introduced.

The receipt is not used as live readiness evidence. Owner cleanup remains
attested by the unchanged ExecStopPost implementation, which stops and proves
empty the exact owner cohort before writing `cleanup_complete=true`; this
change does not extend that trust boundary.

## Validation

The reviewer inspected [cleanup-regression.log](../../validation/classic-live-cpu-20261021/cleanup-regression.log): all 69 focused configuration
assertions pass, including eight ledger assertions. The new assertions exercise
each retained identity mismatch independently, accept a matching retained
record, and continue to reject an invalid live executable through `_ledger`.
The [full RTC test log](../../validation/classic-live-cpu-20261021/rtc-tests.log)
passes 2,416 assertions across 77 test sets, independently tallied by the reviewer.
`git diff --check` passes. The available Julia version is 1.13.2.

The reviewer additionally performed a read-only check against the original
stage's exact unit/invocation/PID/start-time/cgroup receipt. On the sealed fixed
source, `_ledger(handle)` still throws `DeploymentError` for the absent process,
while `_stopped_record(handle, monotonic()+15)` returns the successful cleanup
receipt. Six assertions pass: live-process rejection; cleanup complete; stopped
phase; null error; matching invocation; and no cleanup errors. Output is retained
as [independent-stopped-observation.log](../../validation/classic-live-cpu-20261021/independent-stopped-observation.log). This sends no
native control, repeats no stop, changes no unit or link, and does not change the
unknown operation record. It supplies direct fail-before/pass-after evidence
for the changed stopped-ledger branch on the same exited incarnation.

The helper tests are proportionate to the extraction, and the additional check
executes `_stopped_record` after a real process exit. A separate fresh managed
operation [7562eb0a189d4b85913e6d9216c2074b](../../validation/classic-live-cpu-20261021/after/result.json), using registered RTC 0.2.1 tree
`eba8af0f017060d784df5ecbcbf2f0449794b3ba`, completes replacement. The inspected
request changes r₀ to 0.20 m and L₀ to 25 m with resume-running selected. Its old
unit `pipewireao-session@c5a261cf1d7f.service`, invocation
`189452f09a42483a8ada542fda3dc086`, retains successful stopped cleanup. The new
unit is `pipewireao-session@5d1310435860.service`, invocation
`d3683bb71b8c4b43b6dd3e8ea1411d04`, session UUID
`f6c9e3ec-dd4d-4ef1-8feb-63bd54d5c928`.

The complete result, [fresh native Running observation](../../validation/classic-live-cpu-20261021/replacement-running.json), source configuration
metadata, and fresh simulator description agree on configuration SHA-256
`7023bce990b71fcb4ede9f39105e9a40e4de1949ba227abe68bd928534c1fced`.
The [description](../../validation/classic-live-cpu-20261021/replacement-description.json)
returns r₀ = 0.20 m and L₀ = 25 m; native source properties
declare backend `cpu`; all four observed scientific/core owner GPU-library
lists are empty. The preservation receipt records all 32 original assets and
only the RTC manifest package changed; the normal application's default backend
remains CUDA.

The reviewer viewed the actual rendered Simulator Settings screenshot and the
final GUI Ready screenshot. The former shows the complete job, new session UUID,
new atmosphere settings and CPU backend. The latter shows that same session,
Ready, and a completed Stop; request history also shows completed Start. An
independent native final Ready record binds that session and invocation with
`running=false`, and the simulator acknowledgement likewise reports stopped.
These observations support the selected GUI Stop/Start/Stop and explicit
replacement reconnection workflow.

Final shutdown is also independently supported by the inspected
[native Quit attempt fence](../../validation/classic-live-cpu-20261021/after/shutdown-attempt.json),
[retained launch ledger](../../validation/classic-live-cpu-20261021/after/final-launch.json),
read-only confirmation source, and
[final-shutdown.json](../../validation/classic-live-cpu-20261021/final-shutdown.json).
They bind that exact replacement unit/invocation/session
and prove accepted Quit, an inactive unit with MainPID zero, successful stopped
cleanup, absence of the old RTC process, an empty RTC cgroup, absent exact owner
process incarnations, empty owner cgroups, quiescent owner units, and removal of
the session discovery locator.

The initial final-shutdown helper reported a `KeyError` after successful
shutdown because it unconditionally indexed optional `cleanup_errors`. That
failed [helper log](../../validation/classic-live-cpu-20261021/final-shutdown.log)
is retained. The corrected confirmation uses
`get(record, "cleanup_errors", [])` and performs observation only; it sends no
second Quit and does not retry the shutdown effect. This is a validation helper
error, distinct from the fixed production shutdown bug, and does not conceal
the failed assertion.

The original unknown operation remains retained and was not retried. The new
operation starts from a fresh admitted candidate rather than bypassing its
attempt fence. See the [validation record](../../validation/classic-live-cpu-20261021/README.md)
for the source cohort, software-rendering choice, and curated live artifacts.

The reviewer inspected the final
[stopped-state receipt](../../validation/classic-live-cpu-20261021/final-safety.json):
all three task-created session units and the prior stopped unit are inactive
with MainPID zero, and the task's GUI and X server have terminated. The
[GUI GPU-use check](../../validation/classic-live-cpu-20261021/gui-gpu-free.json)
records llvmpipe, no GPU-library mappings and no GPU device descriptors; the
software-renderer log identifies Mesa software rendering. Together with the
observed CPU simulator metadata and owner-library checks, this supports the
selected gate's GPU-free execution and final stopped state.

No additional blocking source finding was identified in the reviewed diff.
CLCPU-01 is resolved for the selected registered Classic CPU workflow.
Functional lifecycle evidence does not
establish numerical accuracy, cadence, tail latency, physical-loop behavior, or
hardware qualification.
