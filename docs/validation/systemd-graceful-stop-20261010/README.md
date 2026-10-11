# Graceful systemd stop — 2026-10-10

Scope: the ordinary WirePlumber-owned development RTC. HEART binaries and
scientific algorithms are unchanged. No hardware, frame-rate or real-time
qualification follows from the cold control tests below.

## Source and ownership

Starting RTC revision: `c92f133195dd0a7b6ba22bc51d315d9017b471c7`.
Worktree: `pipewireao-rtc-clean-shutdown`, branch `codex/rtc-clean-shutdown`.
The canonical RTC checkout had unrelated README, module and native source
control edits; these were preserved. WirePlumber was clean at
`d20cd2037fda7b5932b0feb58b0af5aef5226a48`; its dedicated inspection worktree
has no production change.

Global `/home/dgamroth/.codex/AGENTS.md` and both repository instructions were
read. Lifecycle evidence was read from REVOLT
`docs/validation/live-dm-controls-20261010/LIFECYCLE.md`.

## STOP-001 — Direct systemd stop bypasses graceful command adoption

Severity P2; confidence high; confirmed source ordering defect for orderly
service stop. The retained Classic and Copper FGN journals demonstrate
termination-time command timeouts. They do not demonstrate command loss during
normal Running.

The old session unit had no `ExecStop`: systemd signalled WirePlumber, then its
`ExecStopPost` emergency hook revoked the private core before stopping the
source. A frame awaiting its matching command could therefore lose its graph
and transport while source adoption remained in flight.

Native Stop/Quit has the required ordering already: Lua holds acquisition,
then stops graphs. The ordinary simulator applies pause in its serialized
owner loop after `exchange_frame!` has returned with the matching command
adopted. No new drain, frame scheduler, timeout, sleep or hot-path operation
is added to either owner.

The new unit runs a one-shot native Quit client from `ExecStop` while
WirePlumber and all independently owned services remain alive. It verifies
the invocation, ControlPID, caller cgroup, retained MainPID/start time and
native session UUID. A fresh healthy Ready/Running Status is required. It
records submission intent before sending exactly one native Quit and requires
the terminal Offline completion. The existing eight-second client request
bound and five-second Lua effect bound remain. After consuming completion it
closes the controller and waits for the same WirePlumber process to exit under
a finite 30-second helper budget. The existing 300-second systemd stop bound
is unchanged.

Failed, missing or unknown native replies enter the existing bounded signal
and `ExecStopPost` cleanup path. They do not cause another native mutation.
An already exited MainPID skips the native request. Preparation and publication
also verify the exact installed `ExecStop` hook.

## Validation

The opt-in `test/native_systemd_stop.jl` uses actual user systemd services and
native typed POD controls against a private core. Its session stand-in gates
one command until the test releases adoption; the stand-in is not production
Lua, a real science graph, or a transport-frame qualification.

The baseline mode omits only the unit's `ExecStop` and checks the same assertion
that native Quit must enter before systemd can finish revoking the owner.
Its qualifying run remains pending after correcting test-only namespace and
user-manager runtime handling. Retained preliminary logs are not fail-before
qualification.

The corrected test covers retained ownership through gated adoption, ordered
terminal completion, a faulted source with no Quit submission, and endpoint
loss after the single fenced submission. It checks final MainPID/cgroup
quiescence and cleanup after each owned unit. Logs and final assertions are
recorded after the run below. A preliminary contended run timed out in the
test's cold-process gate before any Quit submission. The harness now separates
cold Julia preparation from the actual eight-second native request and uses
the production 300-second service stop bound. Reruns await the allocation
worker's profiling window; the standalone exact-hook tests passed 12 assertions.

All tests are pinned to CPUs 12/13. Temporary files use
`/home/dgamroth/.cache/rtc-steady-state-20261010/tmp`; the shortened test socket
name preserves Unix socket path limits. Existing live sessions are not touched.

## Remaining evidence boundary

Native Copper JFG Quit's reported five-second overrun remains a separate
investigation until close/report/main-finish timestamps distinguish the slow
stage. This change does not increase its deadline or claim that symptom is
repaired. The production FGN/JFG test must additionally verify equal final
frame/command counts and no terminal scientific fault on the selected staged
profile. The root task coordinates that CUDA test with the allocation worker.
