# WirePlumber-owned RTC session lifecycle

Status: the replacement Copper complete-frame FGN/JFG path passes installed
admission, reset/start/stop, stopped and running gain/matrix adoption, 512
exchanges per engine, and exact accepted per-engine retained prefixes. FGN
required-parameter-owner loss reaches Fault with no owned links; JFG native
Quit reaches Offline and complete systemd cleanup. Both simulator measured
tails report zero allocations/GC. The existing runtime coordinators are removed
in the migration worktree. Broader profile/loss/timeout and timing qualification
remain separate; see [the checks](validation/wireplumber-session-20261007/SESSION_CHECKS.md).

Source baseline: RTC `e791361eaa491dae7e99e1d3df69816de58061a3`, branch
`work/wireplumber-session-20261007`, initially clean worktree. Existing results
remain scoped to their recorded revisions and configurations.

## Decision

This decision, **RTC-ARCH-025**, supersedes the active ownership allocation in
which a Julia `DeploymentRunner` and Rust Statig session runner divide session
coordination. WirePlumberAO's Lua profile is the sole session lifecycle,
admission, and connection-policy authority. systemd owns process lifetime.
Julia deployment tooling remains for one-shot export, installation and
preflight, with Julia calibration clients retained. Scientific Julia owners,
including JFG graph processes, remain selected profile components. The Lua policy and one-shot launcher are implemented in the review worktrees.
The selected Copper scientific checks below establish their recorded scope;
they do not establish timing or every profile and fault case.

| Owner | Responsibility |
| --- | --- |
| WirePlumberAO Lua profile | Own session state, exact discovery/admission, declared external connection policy, source-first stop, reset/update sequencing, bounded deadlines, required-loss handling, cleanup and fresh readmission. |
| systemd | Start, stop, reap and supervise runtime processes and enforce configured service resource policy. Service activation does not admit a session. |
| PipeWireAO | Own graph hosting, NDArray transport, scheduling and public node/control surfaces. Its native typed endpoint plus a narrow C transport shim provides the asynchronous PipeWire operations Lua needs; the shim is not another lifecycle authority. |
| FGN/JFG | Prepare and execute internal scientific graphs and apply owner-local scientific controls, properties and parameter adoption. Internal graph scheduling and workers remain executor responsibilities. |
| AOS/HIL owner | Own simulated instrument physics, model time, frame/command causality and its source-local pause/reset/query contract. |
| AOC/calibration client | Own calibration mathematics and estimates. Julia clients prepare/export inputs, coordinate deployed acquisition actions and publish accepted artifacts without owning session admission. |
| Julia deployment tools and GUI/CLI | Export/install/preflight or issue bounded native requests and observe status as clients. Scientific Julia owners and Julia calibration clients remain; no Julia client owns session lifecycle or deployment supervision. |

## Migration and removal gates

1. Define and implement a public, bounded native typed WirePlumber session
   endpoint over PipeWire's standard control surfaces. A C transport shim may
   expose required asynchronous PipeWire operations to Lua; Lua and native
   handlers must not perform blocking PipeWire roundtrips, filesystem or
   configuration work, or scientific work. The shim must not contain session
   policy, duplicate state, or become a second command bus. External owner
   operations must be bounded. Selective `ObjectManager` features must avoid
   subscribing to unrelated scientific Node Props while still observing exact
   endpoint and Link identities.
2. Preserve exact declared endpoint identity, port contract, negotiated Format,
   passive-link behavior, topology, and cleanup. Withdrawal must account for
   pending Link-creation completions, cancel outstanding creation, deactivate
   and destroy proxies, synchronize the manager Core, and confirm absence of
   the exact correlated Link cohort before success or a new generation. A
   zero-links snapshot alone is insufficient. Stale manager/runtime incarnations
   cannot adopt an old generation. Unknown operation outcomes stay faults; retry
   requires fresh admission.
3. Move source-first stop, held reset, owner-local update/adoption, finite
   end-to-end deadlines, required-object loss, partial-start cleanup and fresh
   readmission into the single WirePlumber session authority. Keep acquisition
   held until actual owner readiness and adoption are observed. Keep at most one
   internal session/group effect in flight. Tokens are never reused within a
   WirePlumber incarnation; matching includes token, kind, originating
   transition, group and session incarnation. Cancel/fence superseded work and
   discard late completions. Source pause, reset and release retain AOS's native
   owner contract; science work stays in FGN/JFG/AOC owners. A systemd emergency
   hook must revoke ingress before consumer teardown if the WirePlumber service
   dies while Lua is unavailable.
   Each invocation must use fresh owner unit names with `Restart=no`, bind
   owners to verified MainPIDs and process incarnations, verify the installed
   emergency cleanup hook before startup, and reconcile uncertain launches and
   pending starts. Terminate only owned processes with bounded user-manager
   operations; a name-based stop is not an atomic incarnation fence.
4. Preserve declared full-frame and row-block working data paths, both FGN and
   JFG, and accepted artifacts. These are scientific data/executor paths, not
   interchangeable hosting options. FGN LocalModule can execute FGN in the WirePlumber process. The selected
   implementation hosts FGN in a separate ordinary PipeWire client service.
   These choices have different placement and failure boundaries; only the
   selected separate-client Copper path has the new scientific checks. Neither option moves frame scheduling into Lua; PipeWire and
   executors retain scheduling responsibilities.
5. Qualify lifecycle ordering, timeout/disconnect uncertainty, every required
   endpoint/Link/manager/runtime/Core loss, cleanup fences, source silence,
   fresh-incarnation readmission, reset/update adoption, and retained scientific
   outputs for each profile before enabling it.
6. Only after replacement evidence passes, remove the Julia `DeploymentRunner`
   runtime coordinator and Rust Statig session runner, direct session-link
   realization, and their runtime systemd launcher/supervisor roles. Retain
   native client libraries, one-shot Julia deployment tooling, Julia scientific
   owners and calibration clients, owner-local controls, graph-internal
   execution and historical qualification records.

Existing Copper link/systemd transfer and lifecycle evidence demonstrates only
its recorded behaviors. It does not qualify WirePlumber-owned session lifecycle,
readiness, source authority, reset/update coordination, or any removal gate
above.

## Resource admission

The Lua policy remains CONFIGURING after held scientific preparation. The
invocation's one-shot `ExecStartPost` client uses private operation 15 to inspect
warmup, verifies effective placement and retained process incarnations, then
submits operation 16 once. Only Lua transitions to READY. Both operations bind
the same live controller global ID, serial, instance and PID; public Start is
rejected before READY. Successful administrative completions contain lifecycle
and warmup state, not a scientific command result.

The new path currently rejects a non-null `cpu-latency-us` during installation
and preparation. Checking permission to open `/dev/cpu_dma_latency` does not
apply a QoS request. A process-lifetime lease must be implemented and qualified
before this optional setting can be enabled. The selected migration profiles
use null.

## Observed control-plane check

See [module-load evidence](validation/wireplumber-session-20261007/MODULE_LOAD.md).
This demonstrates native transport and a CONFIGURING warmup query only; it does
not qualify admission, scientific execution, cleanup, latency or allocation.
