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

The final package-suite attempt exposed two test integration errors before the
new stop assertions: an unqualified `include` in the isolated suite module and
the direct launcher's undeclared `UUIDs` test dependency. `Base.include` and the
existing standard-library test dependency correct those failures without a
production change. The exact suite then passed 12/12 in the isolated test
environment. Retained logs are `rtc-full-suite-final.log`,
`rtc-full-suite-after-include.log` and `rtc-stop-suite-test-environment.log`.
The corrected full package suite passed 1587/1587 assertions across 44 testsets,
exit 0, with Julia 1.12.7, CPU15, one thread and
`Pkg.test(; allow_reresolve=false)`; log `rtc-full-suite-qualified.log`.
An intervening run was deliberately interrupted to release CPU15 before an
owned diagnostic's Ready gate expired; `rtc-full-suite-after-test-environment.log`
does not constitute a pass. The final production driver syntax check and
`git diff --check` passed. Opt-in live qualification is separate from the package
suite and is not automatically executed by it.

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

The stand-in tests are pinned to CPUs 12/13. Temporary files use
`/home/dgamroth/.cache/rtc-steady-state-20261010/tmp`; the shortened test socket
name preserves Unix socket path limits. Existing live sessions are not touched.

## Independent review

Astra accepted production commit `3ca7b5f` with no confirmed source defect.
`GS-REV-001` (P2) records the qualification gap: baseline ordering failure and
corrected normal/fault/unknown cases now pass their respective intended gates;
the four production balanced-drain gates below now close that gap. `GS-REV-002` (P3)
is addressed by the deadline wording and measured helper launch, request,
client close and MainPID exit times above.
The isolated test instruments a source copy with exact insertion checks;
production has no timing hooks. Its retained journals, ledgers and monotonic
checkpoints distinguish package preparation from the native request and cleanup.

## Production application qualification

The opt-in `test/native_production_shutdown.jl` ran four selected sealed,
non-actuating simulated profiles with ordinary SIGTERM, exported placements,
8192 finite exchanges and a 256-exchange prefix. Every incarnation passed a
fresh verifier using the scientific owner's exact Julia binary, project,
load path/depot and thread settings: CUDA/CUDACore 6.4.2 and
`use_nonblocking_synchronization === false`. No scientific source, calibration,
algorithm, graph, placement, production instrumentation or deadline was changed
by the driver. FGN inputs declare DM-only observation; JFG inputs declare the
selected detector/WFS feeds. This is software/application validation, not
physical hardware, capacity or uncontended real-time qualification.

The driver accepts `SEALED_PACKAGE FRESH_STAGE FRESH_EVIDENCE finite|systemd`
under the package's `revolt` Julia project. `RTC_OPERATOR_VIEW_WRITER` selects
the maintained REVOLT `scripts/deploy_classic.jl`;
`RTC_SOURCE_QUERY_CLIENT` selects the recorded existing typed query client.
`RTC_HOLD_READY`, `RTC_FINITE_CONTROLS`, `RTC_HOLD_FINISH` and
`RTC_HOLD_SYSTEMD_STOP` are opt-in test coordination gates. Their saved files
coordinate external observers; native Status remains the session authority.
The normal driver rejects SDK owner environments declaring profiling or
callback-metrics instrumentation.

All four completed finite runs had 8192 frames and matching commands. All
7936 measured exchanges had zero **simulator-process** allocation bytes,
pool/big/malloc/realloc counters, GC time, pauses and full sweeps. Fresh systemd
stop invocations separately interrupted genuine Running acquisition, completed
all matching commands, retained no scientific fault, submitted one accepted
ExecStop Quit, and ended inactive/successful with MainPID/ControlPID 0,
quiescent cgroups and complete error-free cleanup. No Unknown mutation was
retried.

| Profile | Finite measured / bytes / GC | Running sequence before systemd stop | Final matched frames/commands | Systemd stop through cleanup, s |
| --- | --- | ---: | ---: | ---: |
| Classic JFG | 7936 / 0 / 0 | 3045 | 6196 | 27.974 |
| Classic FGN | 7936 / 0 / 0 | 514 | 3650 | 27.071 |
| Copper JFG | 7936 / 0 / 0 | 512 | 3681 | 26.963 |
| Copper FGN | 7936 / 0 / 0 | 513 | 3576 | 25.425 |

The final finite runs included native gain perturbation/exact Float32
restoration, +0.81 µm OPD clipping against ±0.8 bounds, Zernike index 12 and
Fourier index 0 adoption, and active zero restoration. Classic JFG additionally
attempted a scaled 221×376 reconstructor FITS array and original restoration.
The helper's optimistic FITS flag was superseded by parent inspection:
`AcceptedSubmitted` with requested/active generation still zero does not prove
adoption. Those FITS attempts do not qualify adoption/restoration; the finite simulator
and lifecycle gates and separately verified scalar/shape controls still pass.
The original optimistic receipt is preserved beside
`live-controls/fits-adoption-adjudication.json` and
`release-finish-adjudicated.json`. The driver captures the adjudicated companion
preferentially with its filename and SHA-256, separately from finite completion;
it never treats an unchanged generation or the original helper flag as a FITS
adoption gate. Future positive FITS evidence must show each requested/active
generation advancing beyond the previous stage and active original restoration.
A read-only Ready declaration/binding preflight armed the sole external native
watcher before Start; an atomic native Running/sequence-at-least-512 receipt
triggered controls without message latency. Four held 64-sample observers per
run verified literal 277-element Float32 offset bytes and copied Headers, then
detached. All controls/restorations finished before finite exhaustion.

| Controlled finite profile | Control duration, s | Last held-zero sequence | Roles [none,direct,extrapolated,unknown/mixed] | Stop acknowledgement, s | Quit Offline acknowledgement, s |
| --- | ---: | ---: | --- | ---: | ---: |
| Classic JFG, FITS attempted | 11.430 | 3355 | [0,221,56,0] | 0.178 | 2.542 |
| Classic FGN | 10.708 | 3187 | [0,221,56,0] | 0.180 | 2.162 |
| Copper JFG | 10.743 | 2920 | [0,0,0,277] | 0.178 | 1.591 |
| Copper FGN | 10.709 | 3160 | [0,0,0,277] | 0.179 | 1.476 |

These are native acknowledgement intervals, separate from cold final service
cleanup. All remaining final latest Demand/Offset/role/constraint Headers
aligned. Copper JFG clip's detached endpoint instead had latest Demand 1297
while Offset/role/constraint shared 1296 / PTS 187097549938450; they are
explicitly not one latest tuple. Its window retained 348 valid production
associated feedback/role render frames, Demand +0.800000011921 and strictly
positive residual +0.002388358..+0.019619882. Its later Zernike/Fourier/zero
endpoints aligned at 1815/2341/2920. Applied remains an independent feed and is
not required to share Demand's latest Header.

### Retained evidence and preparation failures

All raw receipts are under `~/.cache/rtc-steady-state-20261010/`:

- Final controlled runs: `{classic,copper}-{jfg,fgn}-final-controlled-evidence/`,
  except Copper FGN, whose first `copper-fgn-final-finite-evidence/` completed
  controls. Each contains `qualification.json`, exact-owner CUDA proof,
  finite reports, native journals and the truthful `release-finish` companion.
- In-flight stops: `{classic,copper}-{jfg,fgn}-final-systemd-evidence/`, except
  Classic JFG's successful resumed `classic-jfg-final-systemd-evidence-2/`.
- First Classic JFG baseline: `classic-jfg-final-finite-evidence-2/` (startup
  and CUDA proof) and `...-evidence-3/` (finite result and 256-sample observer).
  It recorded 245 coherent SHWFS sequences, Header 2082 / PTS 183348173666712,
  roles [0,221,56,0] and zero constraint residual; that receipt proves the
  zero-residual case, not clipping.
- Earlier Classic FGN finite evidence preserved a 205–206/256-sample observer
  timeout after gain/clip adoption, with modes not attempted and zero submitted
  only after exhaustion. Copper JFG's first finite watcher rejected a
  Classic-specific gain target before sending any mutation. Both finite
  allocation/lifecycle gates passed; their companions record controls incomplete.
  Fresh controlled runs above close those control gaps without relabelling the
  earlier attempts.

The first Classic JFG startup failed before admission because the parent-owned
graph generator emitted colon separators instead of SPA `=`; the repaired SDKs
failed-before/passed-after the actual JFG parser with unchanged decoded graph
semantics/scientific inputs. An initial driver used a calibration-only Ready
view; direct native Status corrected the client API mismatch before first
Start. The legacy typed V1 source client also required untouched token-zero
Props, but bootstrap had already committed warm run/pause/reset/query requests.
The test-only connection validator accepts a valid committed snapshot while
preserving PID/instance/protocol checks. Authoritative native Ready plus a
read-only source query proves sequence zero before admission. Its source path
and SHA are recorded; no production source client was changed.

Ready gain readback showed an active default (Classic 1.0) before the first
graph process adopted pending configured initial properties (Running −0.3).
The helper therefore rereads and exactly restores the actual Running value.
Parent inspection confirmed the initial pending stage rejects competing writes
with EBUSY; no scientific gain/configuration change was warranted.

### Allocation and timing boundaries

Simulator counters exclude the separate JFG, parameter and FGN owner processes.
The unprofiled final SDKs omit JFG callback allocation instrumentation, so these
zero counters cannot prove zero JFG allocations or graph-thread GC pauses.
The parent separately owns explicitly sealed callback diagnostic SDKs.
Existing sustained reports retain aggregate source-to-command histograms over
7936 exchanges; raw retained-prefix observations precede controls. They do not
separate individual control phases or establish absent control-related tails.
Recorded unrelated CPU2/3/4 simulation/synthesis processes were left untouched.
Production uses exported profile placements; CPU15 observer/build work can
overlap cold preparation but all owned builds were quiet before measured Start.
Ordinary exact-project shared-depot CUDA import warming (191 s Classic, 133 s
Copper precompilation) made no GPU science call or source/cache-policy change.

Early-stop coarse markers span controls and finalization and cannot attribute
allocations to an individual phase:

| Partial run | Measured exchanges | Bytes / pool / malloc | GC pauses / time |
| --- | ---: | --- | --- |
| Classic JFG, controls | 5940 | 7,895,936 / 152876 / 50 | 0 / 0 |
| Classic FGN, no helper controls | 3394 | 7,896,528 / 152884 / 50 | 0 / 0 |
| Copper JFG, no helper controls | 3425 | 7,896,560 / 152885 / 50 | 1 / 53.189 ms |
| Copper FGN, no helper controls | 3320 | 7,893,344 / 152837 / 50 | 0 / 0 |

The similar aggregates without mutation helpers show live controls are not
required for these allocations. Copper JFG's 3425-sample source-to-command
histogram had maximum 3.070 ms and zero samples above its 4 ms wall period,
but no phase timestamp attributes its GC pause. Strict finite acceptance and
balanced partial-stop acceptance remain separate.

The original Copper JFG five-second Unknown Quit root cause remains unproven.
The selected current profile now acknowledges normal Quit within the unchanged
request/effect bounds; that pass does not retroactively identify the old slow
phase or justify a timeout increase.
