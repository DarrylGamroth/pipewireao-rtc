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
a cooperative 30-second helper budget established after package load. Package
loading, compilation, filesystem I/O and client close are not interruptibly
bounded by that budget. The unchanged 300-second systemd stop watchdog is the
outer process bound; the 30-second helper budget is not a total wall-clock bound.

Failed, missing or unknown native replies enter the existing bounded signal
and `ExecStopPost` cleanup path. They do not cause another native mutation.
An already exited MainPID skips the native request. Preparation and publication
also verify the exact installed `ExecStop` hook.

## Validation

The opt-in `test/native_systemd_stop.jl` uses actual user systemd services and
native typed POD controls against a private core. Its session stand-in gates
one command until the test releases adoption; the stand-in is not production
Lua, a real science graph, or a transport-frame qualification.
Both baseline and corrected stand-in units use test-only `KillSignal=SIGKILL`:
the first SIGTERM trial entered unrelated Julia diagnostic/finalizer shutdown
and needed owned-unit cleanup. This isolates process revocation ordering and
fallback quiescence. Production retains its ordinary SIGTERM policy; only the
production gate can qualify that signal path.

The baseline mode omits only the unit's `ExecStop` and checks the same assertion
that native Quit must enter before systemd can finish revoking the owner.
The qualifying run exited 1 at that intended assertion: `owner_revoked=true`,
`quit_entered=false`, `command_adopted=false`. Its owned service and private core
were cleaned. Retained evidence is
`~/.cache/rtc-steady-state-20261010/systemd-stop-before-qualified.log` and
`systemd-stop-1891544-before/normal/` under that cache root. Earlier SIGTERM,
namespace and user-manager handling logs are test artifacts, not qualification.

The corrected test covers retained ownership through gated adoption, ordered
terminal completion, a faulted source with no Quit submission, endpoint
loss after the single fenced submission, and wrong ledger PID/start ticks,
wrong session UUID and an existing submission fence. Negative ownership cases
must receive zero native Quit submissions. It checks final MainPID/cgroup
quiescence and cleanup after each owned unit. The first complete run passed
71 behavioral assertions but had nine identical test property-query errors:
the optional systemd `Result` property was not requested. Its retained full
properties show the expected two successful and seven failed helper results.
After requesting that property explicitly, the clean rerun passed 80/80
assertions in 2 minutes 46.4 seconds and exited 0. Retained evidence is
`~/.cache/rtc-steady-state-20261010/systemd-stop-after-qualified.log` and
`systemd-stop-1894817-after/` under that cache root. All nine owned units ended
with MainPID 0 and quiescent cgroups. Normal received one accepted Quit;
endpoint loss received one fenced unaccepted Quit; fault, wrong PID/start
ticks/UUID, previous submission, missing ledger and already-exited owner
received zero Quit submissions. No private test service remains.
The harness separates cold Julia preparation from the actual eight-second
native request and uses the production 300-second service stop bound. The
standalone exact-hook tests passed 12 assertions.

The corrected normal case's source-copy checkpoints (monotonic nanoseconds) are:

| Stage | Monotonic ns | Seconds after helper launch |
| --- | ---: | ---: |
| Helper launch | 181636141315771 | 0 |
| Module loaded | 181636805013921 | 0.664 |
| Cooperative budget begins | 181646188608930 | 10.047 |
| Native Quit request | 181650267168930 | 14.126 |
| Native Quit completion | 181650393288046 | 14.252 |
| Client close begins | 181650393715997 | 14.252 |
| Client close ends | 181650659244820 | 14.518 |
| MainPID 0 observed | 181650974865391 | 14.834 |
| Helper finishes | 181650974962633 | 14.834 |

Native Quit took 0.126 seconds, client close 0.266 seconds, and the fresh
MainPID exit proof followed close by 0.316 seconds. These measurements include
test timing writes and cold Julia compilation; they are functional cold-path
evidence, not a real-time latency distribution or production Lua timing bound.

All tests are pinned to CPUs 12/13. Temporary files use
`/home/dgamroth/.cache/rtc-steady-state-20261010/tmp`; the shortened test socket
name preserves Unix socket path limits. Existing live sessions are not touched.

## Independent review

Astra accepted production commit `3ca7b5f` with no confirmed source defect.
`GS-REV-001` (P2) records the qualification gap: baseline ordering failure and
corrected normal/fault/unknown cases now pass their respective intended gates;
production matching command/frame counts remain required. `GS-REV-002` (P3)
is addressed by the deadline wording and measured helper launch, request,
client close and MainPID exit times above.
The isolated test instruments a source copy with exact insertion checks;
production has no timing hooks. Its retained journals, ledgers and monotonic
checkpoints distinguish package preparation from the native request and cleanup.

## Remaining evidence boundary

Native Copper JFG Quit's reported five-second overrun remains a separate
investigation until close/report/main-finish timestamps distinguish the slow
stage. This change does not increase its deadline or claim that symptom is
repaired. The production FGN/JFG test must additionally verify equal final
frame/command counts and no terminal scientific fault on the selected staged
profile. The root task coordinates that CUDA test with the allocation worker.
