# Native runner endpoint validation

2026-10-05. CPU software evidence for phase B of
[the native migration](NATIVE_CONTROL_MIGRATION_DESIGN.md), under RTC-DEV-030.
Worktree `pipewireao-rtc-native-controls`, branch
`work/native-control-planes-20261005`, starting clean revision `0377007`.
The [profile](NATIVE_RUNNER_CONTROL.md) governs its native records;
[independent review](NATIVE_RUNNER_ENDPOINT_REVIEW.md) tracks findings.

## Implemented boundary

An inactive no-port Filter shares the existing runner Core and main loop.
Callbacks stage a bounded typed command; the sole Runner/Statig dispatcher
executes existing effects outside callbacks. Caller markers are bound actual
Nodes with verified NodeInfo global ID, serial, PID, instance and zero ports.
One accepted slot remains occupied through terminal publication. Admission
rejections retain the prior completion; matching duplicates do not execute again.

A single cold worker prepares parameter artifacts. Request expiry or observed
caller removal fences the prepared result; an abandoned worker remains busy
until its result is drained. Required-object monitoring continues during
preparation and precedes dispatch of a prepared result when monitoring is due.
Mutation reply capacity is checked before preparation/effects. Nested PipeWire
waits inherit the accepted absolute deadline; arbitrary filesystem I/O is not
claimed to be preemptible.

Native CLI flags require held startup and an absolute socket in an owner-only
runtime directory. Console and legacy socket ingress cannot accompany native
mode. Legacy socket callers remain explicitly unmigrated; there is no fallback.
HEART source, scientific algorithms and source frame callbacks are unchanged.

## Observed checks

Evidence directory: `/home/dgamroth/.cache/rtc-live-controls-20261005`.
Rust builds use the existing target cache, locked offline dependencies, feature
`live`, installed `/opt/pipewireao` libraries and CPU 14. Julia uses 1.12.7,
registered PipeWireAO 0.6.16, one Julia thread and one BLAS thread on CPU 14.

| Check | Result | Evidence |
| --- | --- | --- |
| Production binary, two actual independent callers | 143 passed, zero failed | `native-runner-endpoint-sealed.log` |
| Rust workspace tests and strict all-target Clippy | 184 passed, zero failed, nine ignored; Clippy passed with `-D warnings` | `native-runner-final-build.log` |
| Destructor with stopped private daemon, before correction | Failed: fresh synchronization delayed drop by 5.000192111 seconds | `native-runner-drop-before/rust.log` |
| Same destructor test after correction | Passed: drop took 128,130 ns | `native-runner-drop-after/rust.log`, `elapsed-ns` |
| Due monitor with a queued 250 ms request, before correction | Failed: healthy Ready became Fault on request-budget expiry | `native-runner-queued-monitor-before/queued_budget/rust.log` |
| Required-object loss and stalled-core request budget | Four Rust diagnostic cases passed; 12 Julia assertions passed | `native-runner-monitor-sealed.log`, `native-runner-monitor-sealed/` |

The sealed production binary has SHA-256
`71549afe3ca2f235c1264dafc0f18602936de861ad5e549cbc1b70c7c330fb4d`.
The workspace's nine ignored tests include the five separately exercised Drop
and monitor diagnostics. The four pre-existing private-core fixtures were not
run in this increment: one stopped-core synchronization diagnostic and three
scientific graph fixtures. The build retains the pre-existing
`proc-macro-error2` future-compatibility warning.

The two-caller fixture uses four tiny external ndarray endpoints and two
runner-owned links. It submits and arms no arrays. Endpoints are initially held;
their public activation makes links eligible before runner Start, while no
scientific ingress occurs. It checks Ready admission, Status/Groups, Start/Stop,
duplicate successful Start, duplicate accepted failure, cross-caller token
collision, stale token, wrong endpoint instance, malformed envelope rejection,
fresh queries, actual caller removal, retained completion and normal Quit with
owner removal and exit zero. It does not compare RTC scientific algorithms.

Two preliminary fixture failures were corrected without production workarounds.
Inactive ndarray endpoints did not satisfy Start's existing active-link gate;
activating those endpoints without submitting frames corrected the setup.
A scalar POD submitted as `SPA_PARAM_Props` yielded no owner rejection, so the
malformed-envelope check uses a valid Props carrier with invalid header fields.
That result does not establish a PipeWire defect. Both preliminary logs remain.

The destructor correction skips redundant synchronization only when all local
owned-resource collections have already been released. Partially initialized
owners retain destructor cleanup. The stopped-daemon test isolates this extra
wait; its elapsed value is diagnostic evidence, not a latency benchmark.

The four monitor diagnostics use separate private cores and held tiny ndarray
endpoints. Required-object loss is injected both with preparation pending and
with an accepted request still queued. Both cases reach Fault, publish the
matching negative terminal, release admission and suppress an actually injected
late prepared command. The two budget cases stop the private daemon: accepted
SessionStart and a due monitor inherit the 250 ms request budget and preserve
Ready when that budget expires. The sampled synchronization timeout is discarded
as a health observation; normal maintenance resumes independently. These tests
inject admission identities and preparation results rather than creating a
blocked artifact read; the two-actual-caller fixture separately verifies authority.

## Qualification limits and remaining gates

Stalled-core pre-effect synchronization, pending/queued required-object loss and
late-result fencing are qualified for the focused CPU cases above. Expiry partway
through multi-stage scientific effects, Running finite-source completion and
blocked artifact I/O remain unqualified.
Mailbox tests cover bounded staging, busy, duplicate/collision/stale admission,
queued expiry and worker-slot retention; they are not evidence of blocked
filesystem I/O or remote receipt after timeout. Removal observed during effects
cannot be made atomic with remote lifetime changes and does not imply rollback.

The [supervisor-to-runner native client](NATIVE_RUNNER_CLIENT_VALIDATION.md) is
implemented with focused CPU caller qualification. HEART wrapper reset/health, calibration owners and clients,
public operator requests and live readiness/status-file authority still require
replacement. Saved configuration, manifests, reports and CLI rendering
can retain JSON. No installed science, allocation-free frame behavior, hard
real-time execution or physical-device capability is claimed by this fixture.
