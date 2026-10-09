# Ordinary session shutdown source review — 2026-10-09

Scope: read-only review of current WirePlumber Lua, shared Julia native controls,
REVOLT owners and retained Classic journals. No edits to production source, live
runs, HEART binary changes, science changes or scheduler changes were made.
Global instructions were read; preferred Sol ID is `gpt-6.1-sol`.

## Revisions and evidence

- Shared worktree `pipewireao-rtc-julia-package`: `ae540e31700ccb026c999d23241f2a1b1275ae0d`, clean.
- WirePlumber worktree `wireplumber-core-endpoints`: `d532f8918d76ed843a7bf39d2b3beebc93292310`, clean.
- `REVOLTRTC.jl`: `2c91e04f73fe39c2d2ab8499fc08656e489418c5`, clean.
- `AdaptiveOpticsSimPipeWireHIL.jl`: `15fd37d97ca9ff6b62d97a149e90ca1ed4368662`, clean.
- Journal root: REVOLT `docs/validation/installed-classic-split-20261008/`.
- AOS/HIL resource close implementation is deterministic already; no adapter
  defect was established by these journals.

## Reconstructed paths

Ordinary native session Quit:

```text
Lua dispatch Quit
  → source run=held acknowledgment (outstanding adoption completed)
  → graph run=stopped acknowledgment
  → withdraw owned links and Core.sync absence fence
  → publish session Offline completion
  → Core.sync publication fence
  → disconnect WirePlumber (controller node disappears)
  → systemd ExecStopPost
  → revoke core, revoke source, stop remaining consumers
  → prove exact cgroups/jobs empty; remove owned unit files
```

No owner-bootstrap Quit or HEART shutdown request is issued in this path.
Emergency `systemctl stop` follows another path: required-object loss may fault
Lua before it disconnects; its best-effort fault handler holds ingress/graphs and
withdraws links; ExecStopPost then preserves core/source-first revocation.

## SHUT-001 — Ordinary Quit omits graceful owner termination

Severity P2; confidence high; confirmed source defect relative to graceful owner
exit, not a failure of the existing exact-process cleanup proof.

Evidence:

- WirePlumber `src/scripts/ao/session.lua:481` holds source/graphs, withdraws,
  publishes Offline, disconnects at line 498.
- Startup clients are local `bootstraps` at `session.lua:612`; Connect operation
  2 for bootstrap / 3 for HEART is used, but clients are not retained for Quit.
- Shared `src/native_owner_bootstrap_codec.jl:18`: Quit is existing operation 3.
- REVOLT `src/native_heart_codec.jl:41`: shutdown is existing operation 4.
- Shared bootstrap `src/native_owner_bootstrap_runtime.jl:102` fails closed when
  its retained controller disappears.
- Normal Classic JFG journal `classic-jfg/owned-journal.jsonl:60,80,102` records
  controller revocation for source and both graph owners after native Quit.
- Successful staged HEART journal `heart-core-fix/owned-journal.jsonl:56` records
  simulator revocation/exit 1 before emergency core stop at line 76.

Interpretation: these are expected fail-closed diagnostics under the present
teardown sequence, not evidence of a runtime ingress/data failure preceding
Quit. Cleanup-complete is true, graceful exit is false. Do not weaken controller
identity guards or reclassify arbitrary revocation as success.

Remediation candidate: Lua retains exact declared cold owner clients, preserves
source hold → graph hold → link withdrawal, issues existing terminal owner
operations and validates their exact completion/lifecycle before disconnecting.
This requires SHUT-002 first. Link withdrawal alone may expose separate retained
buffer defects (SHUT-003); do not assume terminal requests repair those.
Emergency core/source-first systemd cleanup remains unchanged.

## SHUT-002 — Terminal publication fence does not prove peer consumption

Severity P1 for a proposed graceful-shutdown path; confidence high; confirmed
ordering hole in existing terminal owner APIs, not demonstrated lost completion
in these journals (ordinary Lua Quit currently never invokes these APIs).

Evidence:

- WirePlumber `src/scripts/lib/ao-owner.lua:182` schedules the next Props poll in
  up to 5 ms. Its poll verifies current owner identity before query and again in
  the enum_params callback (lines 192/206). Removal can fail either check.
- Shared bootstrap `native_owner_bootstrap_runtime.jl:405` publishes Quit
  completion, flushes its own Core.sync, then returns from the monitor.
  `finish!` waits for monitor completion; `with_owner` closes transport immediately.
- REVOLT `src/heart_owner.jl:555` flushes terminal publication, exits run when
  stopping, and `main` finally closes its native runtime at line 685.
- Neither Core.sync wait contains an acknowledgment from the consuming client.

Derived sequence allowed by source: owner publishes/syncs/removes its endpoint
between successive WirePlumber polls. The server accepted the publication, but
the peer need not have enumerated it. A delay/grace sleep cannot prove delivery.

Minimal cold design candidate: after science/child cleanup and terminal
publication, retain only the control endpoint until the exact issuing controller
is removed or the original finite operation deadline expires. WirePlumber keeps
its controller until it has consumed all terminal completions and published its
own Quit outcome. Controller removal is expected only in this acknowledged-local
terminal phase; every pre-terminal loss remains a fault. Capture the actual Quit
controller, token and original deadline, not just a node name. Do not acknowledge
science cleanup before it completed. Additional live mutations in terminal state
must remain rejected; duplicate terminal replay may retain existing semantics.

An explicit reader acknowledgment is an alternative, but requires versioned
protocol changes. Either design needs deterministic delayed-peer tests before
it can be called a completion-delivery fix. Terminal retention is cold control
work; it does not add scheduling to the frame path.

## SHUT-003 — Calibration failure cleanup uses emergency stop; first JFG
buffer failure precedes core stop

Severity P2 investigation; confidence high for chronology, moderate for mechanism.
No confirmed root cause in buffer ownership is established here.

Evidence:

- REVOLT `src/calibration_campaign.jl:626` selects emergency `stop!` on acquisition
  failure; its successful path uses native `shutdown!` at line 576.
- Classic JFG calibration journal line 72: systemd begins session stop.
- Line 73: Lua faults `Required registry incarnation removed`.
- Lines 74–105: retained ndarray buffers removed before processing completes;
  Format/Latency changes return Broken pipe. These occur ~108 ms after session
  stop, while the private core is still alive.
- Lines 106/109: WFS/command graph owners exit on `pw_ndarray_filter_run failed:
  Broken pipe (-32)`, ~5.3 seconds after the removal errors.
- Line 152: private core finally stops ~13.2 seconds after session stop.

Interpretation: this trace must not be presented as ordinary native Quit, or as
proof that core-first ExecStopPost caused the first retained-buffer failure.
Registry loss followed by fault-path link withdrawal is consistent with buffer
reconfiguration while a stopped graph still retains input; the exact resource
that disappears and retained-buffer state were not captured. An error during
forced teardown alone does not establish a normal streaming defect.

Cheapest discriminating checks: compare ordinary native Quit versus emergency
stop on the same admitted, held JFG graph after one real frame. Capture cold
timestamps for source/graph hold acknowledgments, owned link withdrawal and first
native buffer removal; record retained input count if an existing bounded native
diagnostic is available. If ordinary native Quit reproduces it before any core
removal, investigate graph stop/drain/unconfigure ownership in PipeWireAO; do not
mask `-32` in Julia or add copies. If only emergency stop reproduces, preserve it
as emergency diagnostics and assess whether known restored/released calibration
failure can safely request ordinary Lua Quit before fallback (separate change).

## SHUT-004 — HEART wrapper finalizer lock error occurs after forced termination

Severity P3 diagnostic; confidence high for occurrence, unresolved for precise
interruption mechanism. This is a Julia wrapper lifetime issue, not evidence of
an unchanged HEART binary defect.

Evidence:

- HEART fixed-run journal line 79 begins systemd stop of wrapper; line 161 logs
  `cannot close a PipeWire thread loop while its native lock is in use`; line 171
  confirms service stopped.
- REVOLT `src/heart_owner.jl:75` closes endpoint/core/context inside the native
  lock and then closes the loop outside it. Normal deterministic source ordering
  is already correct.
- PipeWireAO `src/thread_loop.jl:150` explicitly prohibits closing a loop with a
  nonzero native-access count. The guard is valid and must remain.
- Wrapper main has SIGINT handling and atexit child stop, but forced systemd
  SIGTERM does not prove `main`'s deterministic finally completed.

Candidate: prove normal native HEART shutdown (existing SHUTDOWN command, child
death acknowledgment, native control retention from SHUT-002) makes wrapper exit
normally before systemd fallback. If the same lock diagnostic persists on that
path, capture lock ownership/access count at deterministic close and escalate
then. Do not change PipeWireAO close invariants or HEART binary based only on
forced-finalizer output.

## Required validation for remediation

1. Deterministic delayed reader: hold WirePlumber Props polling after terminal
   effect long enough for the old owner to remove its endpoint; demonstrate old
   request fails/unknown and retained endpoint allows exact completion.
2. Controller removal before terminal effect: remains failure, never clean.
3. Wrong controller incarnation/replayed stale token: remains rejected.
4. Terminal deadline expires without reader: bounded close, caller unknown/fault;
   no unbounded process/endpoint leak or manufactured peer acknowledgment.
5. Ordinary FGN, one/two-owner JFG and unchanged HEART: source silence, stopped
   graphs, owned links absent, exact successful owner terminal completions,
   normal owner exits and eventual empty cgroups/jobs; unrelated session intact.
6. Emergency stop/admission failure still revokes core/source first and proves
   exact cleanup. These are separate from graceful-exit acceptance.
7. Ordinary link withdrawal with held JFG buffers is measured independently of
   owner terminal delivery. Retain any buffer failure as a failed gate.

Disposition at initial review: findings submitted to primary for adjudication.
The sections above record the original read-only investigation. Subsequent
authorized remediation and cold validation are recorded below; no GPU, HEART
binary, scientific graph, timing or full installed cohort qualification is claimed.

## Authorized SHUT-002 remediation

Implemented uncommitted in the existing shared/app worktrees:

- Native endpoint tracks actual controller removal separately from permanent
  proof/error revocation. A proof revoked before removal stays revoked.
- Successful terminal completion atomically seals new request admission under
  the same native thread-loop lock as publication. Existing exact replay remains
  available; fresh work is rejected with the existing envelope result `-108`.
  No protocol operation IDs or payload schemas changed.
- Successful bootstrap Quit waits after `main_finished` (scientific resource
  cleanup), completion publication and Core.sync. Only the cold control endpoint
  remains until exact controller removal or the original finite request budget.
- HEART wrapper shutdown uses the same retained-terminal helper after child stop
  and successful native publication. The unchanged binary was not exercised by
  these cold tests.
- Existing negative terminal replies retain their prior behavior; this change
  qualifies successful-terminal retention only. Expiry releases bounded local
  resources, and does not manufacture proof that the reader consumed a reply.
- Independent finding TSH-001 (fresh work could overwrite pending state during
  retention) was independently verified and corrected by the atomic terminal gate.

Changed shared production files: `src/native_control_endpoint.jl`,
`src/native_owner_bootstrap_runtime.jl`. Changed REVOLT production file:
`src/heart_owner.jl`. Adjacent test constructor arities and successful Quit reader
release are updated; new opt-in private-core tests are `test/native_owner_terminal.jl`
and REVOLT `test/native_heart_terminal.jl`. No WirePlumber Lua edits by this worker.

### Cold evidence

Logs in the same cache directory as this review:

| Check | Result |
| --- | --- |
| `terminal-before-20261009.log` | Before runtime from shared `ae540e3` loaded as an overlay with current endpoint; same enum-only delayed reader sees endpoint closed before observation: 2 assertion failures and a late-query error |
| `terminal-after-20261009.log` | 40/40: delayed enum consumption, exact controller release, finite expiry, post-terminal proof mutation, fresh Status/Quit rejection and exact replay with original ticket/deadline retained |
| `heart-terminal-after-20261009.log` | 35/35 cold HEART wrapper terminal API checks, plus 31/31 existing portable owner checks |
| `bootstrap-after-20261009.log` | 49/49 existing actual-core bootstrap controls |
| `bootstrap-sealed-after-20261009.log` | 66/66 existing retained-controller/pre-terminal loss guards |
| `endpoint-faults-after-20261009.log` | 46/46 existing profile/envelope/proof/publication failure checks |
| `bootstrap-idle-after-20261009.log` | 12/12; isolated quiet/connected bootstrap windows and direct poll/cancel/check measured zero bytes |
| `shared-strict-terminal-20261009.log` | Full strict shared package tests: 1,562/1,562 assertions in 42 sets |
| `app-strict-terminal-20261009.log` | Full strict REVOLT package tests against the developed shared worktree: 1,362/1,362 assertions in 65 sets |

The delayed reader unsubscribes from Props, fences that request at its Core, and
delays its explicit enum query after the terminal publication. Thus subscription
delivery cannot substitute for the intended Lua enum observation. Replay checks
explicitly verify admission, no pending work, identical saved terminal ticket and
deadline, and no new rejection; a later enum retains the original terminal data.

All tests used Julia 1.12.7 with bounds enabled/deprecations treated as errors on
CPU13/15, threads=2,0, and private PipeWire cores. They are cold control/lifetime
software evidence; they do not establish steady-state allocations, GPU behavior,
latency or unchanged HEART child shutdown. The zero-byte bootstrap result is
limited to the existing connected/bootstrap microbenchmark, not the full RTC
process or scientific application. Initial HEART test setup timed out
because it did not pump the owner before Client.connect; moving the existing
consume driver before connect corrected that test setup, not production code.

Final production source hashes:

```text
8787006a2dec134e5de7dd6e4cea0b1b73bbea461d89fbd17ed3cf073638ec58 shared src/native_control_endpoint.jl
a87d188a95db44b6788a3bf9dcfba64c5061fac63a8e203fa8ecb2f8da057d3c shared src/native_owner_bootstrap_runtime.jl
8cb0c5ec3ab43cdddcb857b8466af9f9bdb5c319dfed13cb1572dd6cdac7414b REVOLT src/heart_owner.jl
```

`git diff --check` passed for both worktrees. After primary authorization and
independent final review, source/tests were committed locally:

- Shared: `ca27a5576ca58d3874ad0d08f373a6673a02a3b6` (6 files).
- REVOLT: `6611e0063feab9eb5ec7e5fb1ec370c54d342b7b` (2 files).

Both worktrees were clean after these commits. No pushes by this worker. The
REVOLT immutable shared pin is deliberately unchanged pending primary's shared
push and pin update; testing used a temporary environment, not that old pin.
Independent final review found no remaining confirmed production gap in this
terminal retention scope. Primary owns Lua normal Quit orchestration and live
installed qualification. SHUT-003 remains an unresolved emergency-teardown
diagnostic; SHUT-004 graceful child/wrapper exit remains a separate live gate.

### Exact commands

Run from `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-julia-package`,
with redirected logs under `/home/dgamroth/.cache/rtc-julia-package-20261008`:

```bash
taskset -c 13,15 julia --startup-file=no --project=. --threads=2,0 --check-bounds=yes --depwarn=error test/native_owner_terminal.jl
taskset -c 13,15 julia --startup-file=no --project=. --threads=2,0 --check-bounds=yes --depwarn=error test/native_owner_bootstrap.jl
taskset -c 13,15 julia --startup-file=no --project=. --threads=2,0 --check-bounds=yes --depwarn=error test/native_owner_bootstrap_sealed.jl
taskset -c 13,15 julia --startup-file=no --project=. --threads=2,0 --check-bounds=yes --depwarn=error test/native_control_endpoint_faults.jl
taskset -c 13,15 julia --startup-file=no --project=. --threads=2,0 --check-bounds=yes --depwarn=error test/native_owner_bootstrap_idle.jl
taskset -c 13,15 julia --startup-file=no --project=. --threads=2,0 --check-bounds=yes --depwarn=error -e 'using PipeWireAODeployment; push!(LOAD_PATH,"/home/dgamroth/workspaces/codex/pipewire/REVOLTRTC.jl"); include("/home/dgamroth/workspaces/codex/pipewire/REVOLTRTC.jl/test/native_heart_terminal.jl"); include("/home/dgamroth/workspaces/codex/pipewire/REVOLTRTC.jl/test/test_heart_owner.jl")'
taskset -c 13,15 julia --startup-file=no --project=. -e 'using Pkg; Pkg.test(; julia_args=["--startup-file=no", "--check-bounds=yes", "--depwarn=error"])'
taskset -c 13,15 julia --startup-file=no --project=. -e 'using Pkg; Pkg.activate("/home/dgamroth/.cache/rtc-julia-package-20261008/terminal-app-test-env-20261009"); Pkg.develop([Pkg.PackageSpec(path="/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-julia-package"), Pkg.PackageSpec(path="/home/dgamroth/workspaces/codex/pipewire/REVOLTRTC.jl")]); Pkg.status(); Pkg.test("REVOLTRTC"; julia_args=["--startup-file=no", "--check-bounds=yes", "--depwarn=error"])'
```

The temporary Manifest records the shared path above explicitly. Full REVOLT
tests print Git-not-a-repository diagnostics while examining portable source
copies; the complete suite exits zero and reports all tests passed. No source
or instrument files were changed to suppress that output.

Fail-before overlay command (the cached runtime file was extracted with
`git show ae540e31700ccb026c999d23241f2a1b1275ae0d:src/native_owner_bootstrap_runtime.jl`):

```bash
taskset -c 13,15 julia --startup-file=no --project=. --threads=2,0 --check-bounds=yes --depwarn=error -e 'using PipeWireAODeployment; Base.include(PipeWireAODeployment, "/home/dgamroth/.cache/rtc-julia-package-20261008/terminal-runtime-before-20261009.jl"); push!(ARGS,"release"); include("test/native_owner_terminal.jl")'
```

That run intentionally exits 1. It tests the old runtime removal behavior with
the same actual private-core delayed enum peer, not a complete old-package build.

## SHUT-E001 — Fresh installed Classic FGN native Quit evidence

Read-only bounded follow-up requested by primary. Exact stage:
`/tmp/rtc-split-classic-fgn-509d8f82`; session invocation
`516ee43bb8e1475fbbcfb08e2c5fe5bb`; unit
`pipewireao-session@ec8c95002f4d.service`.
Primary reports shared `ca27a55`, app `6611e00` with pin update `18ff717`, and
installed WirePlumber `650e9843`. No source/test changes or service mutations
were made by this follow-up.

### Observed

- `shutdown-attempt.json` retains the exact unit/invocation and `accepted=true`.
- `final-launch.json` and `check-receipt.json.shutdown` retain phase `stopped`,
  error null, service_result `success`, cleanup_complete and unit_files_removed.
- Final ledger `owners.*.state` remain `running`: they are retained admission
  snapshots, not terminal observations or live processes.
- Exact named-unit journal has no controller-revocation, Broken pipe, finalizer,
  session-fault or Main-process-failure diagnostic for this invocation.
- Source `SIMULATOR_REPORT_WRITTEN sequence=10 recorded_frames=10 failed=false`
  appears before core or FGN host stop.
- Source and parameter service final consumed-resource journal records appear
  before any recorded core stop; their journals contain no preceding systemd
  stop request. Core and FGN host subsequently have explicit stop records.

Bounded event excerpt:
`classic-fgn-516ee43b-shutdown-events-20261009.jsonl` in this cache directory
contains eight records obtained with read-only `journalctl --user` restricted
to this session and its four unique owner service names.

| Journal event | Realtime timestamp (µs) |
| --- | ---: |
| Source report, failed=false | 1791535493073238 |
| Source final consumed-resource record | 1791535493882032 |
| Parameter owner final consumed-resource record | 1791535494298600 |
| Core stop begins | 1791535504579134 |
| FGN host stop begins | 1791535504650938 |

### Derived

Current shared `_native_quit!` writes accepted=true only after its native client
returns matching successful session Offline/Shutdown completion. Installed Lua
normal Quit now validates successful terminal owner completions before producing
that session result. Its `owner.shutdown` validates exact operation/header result
and profile-specific Stopped payload; bootstrap operation 3 and HEART operation 4
retain their native v1 meaning. Combined with source/parameter termination
ordering and the source report, this supports **accepted native Quit and
scientific cleanup before core stop, without teardown faults**, followed by
owned bounded process/job cleanup. It is stronger evidence than the final
ExecStopPost cleanup receipt alone.

This does not directly retain each owner's terminal POD/token in the saved
receipt. Successful owner acknowledgments are derived through the verified
normal-Quit software contract rather than individually archived payloads.

### Explicit limit: exact process exit disposition was not retained

Post-cleanup `systemctl show` for source/parameters/FGN now reports
LoadState=not-found, blank InvocationID and default ExecMainCode/Status zero.
Those default fields **do not prove exit(0)**. The stale ledger state also cannot
prove an owner's terminal exit. Journal resource-consumption records and absence
of failures support normal cessation but do not encode an exact exit status.
Do not report exact exit-zero proof from this cohort.

Minimal optional evidence for a future harness, if exact graceful process exit
becomes an acceptance claim:

1. Save exact native Quit request/completion identity, operation, token, endpoint
   and controller incarnation, result, terminal lifecycle and observation time.
2. For each native-controlled owner, retain its matching terminal completion
   (and HEART child returncode/alive=false where applicable), scoped to original
   PID/start ticks, service invocation and native endpoint instance.
3. Capture systemd Result/ExecMainCode/ExecMainStatus while the exact owned unit
   remains loaded and before fragment removal/unit garbage collection; record
   whether an emergency stop/signal was actually issued. Keep native-controlled
   source/JFG/HEART completion separate from conventional daemon lifetime stop.
4. Retain source hold and graph stop acknowledgments, links-absent fence, terminal
   native completion and subsequent core-stop ordering alongside final empty
   cgroups/jobs and unit-file removal.

These are cold evidence fields, not a new coordinator, live protocol/schema or
hot-path logger. Primary adjudicated that current claims do not require adding
production instrumentation or expanding schema scope just to obtain exit-zero
wording. No code change is recommended for this evidence limitation.

Receipt hashes:

```text
e0b816aae2ae4a1f645f581120f439f8e67aaf47055bfb5b5b2451acbfad1f6a final-launch.json
52d10ece4dec0229a7d455760928969b97d507881a65c67e89eabfdef46aca5d check-receipt.json
28b77153e6a88374679c9312e1b45396be51e2bf869f8c1414afc3628166bfb4 shutdown-attempt.json
```

Disposition: successful installed native-shutdown/control integration evidence,
not numerical, allocation, cadence, physical-loop or exact-process-exit-zero
qualification. Other cohorts and emergency JFG teardown remain separate.
