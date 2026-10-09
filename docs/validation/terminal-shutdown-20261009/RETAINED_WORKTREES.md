# Retained dirty RTC worktree disposition

Read-only comparison on 2026-10-09. Active source was `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-julia-package` at `ca27a55` (`Retain terminal owner controls until reader release`), with pre-existing untracked `docs/validation/terminal-shutdown-20261009/`. The three retained RTC worktrees were inspected at `0377007` (live observation), `f8dbb47` (progressive requal), and `f3f0815` (session discovery). No files or refs were changed. The `deployment/julia` layout in these older RTC worktrees was moved to package-root `src/`, `test/`, and `assets/` in active history by `3101c5a`.

## Summary recommendation

- **Live observation:** its code was committed as `c4c47ee`, then removed from the active implementation by `354ae53` when WirePlumber became the session authority. The active package retains the historical validation and review records. The local edits mostly rewind later qualification/evidence and native-control state relative to `c4c47ee`; they are not current implementation. Preserve no unique code solely for current runtime use. If retaining a historical snapshot, use the active committed evidence rather than the local downgraded copy.
- **Progressive requalification:** the active branch already contains the generated capacity result and its conclusions. The three untracked local files are absent from active history. The two profile files encode a unique diagnostic CPU placement and may be useful only if that experiment is resumed. The summarizer script is orphaned/stale in this repo: it imports `run_copper_baseline`, which is absent from active `benchmark/`, and its report output is already present in active benchmark data. Do not treat it as an active capability.
- **Session discovery:** implementation, tests, documentation and navigation are already in the active package under their new paths and have evolved beyond the dirty copies. The untracked handoff is byte-identical to the active package copy. These dirty files do not appear to add current source functionality.

## Per-worktree evidence and path mapping

### `pipewireao-rtc-live-observation` (`0377007`)

Tracked dirty paths: `deployment/hil/Project.toml`, `owner_protocol.jl`, `simulator.jl`, `test_owner_protocol.jl`; `deployment/julia/src/PipeWireAODeployment.jl`, `deploy.jl`, `hil_export.jl`; `deployment/julia/test/runtests.jl`, `test_deploy.jl`, `test_exports.jl`; `docs/operations.md`, `docs/roadmap.md`. Untracked: `deployment/julia/src/observation_boundary.jl`, `deployment/julia/test/test_observation_boundary.jl`, `test_observation_loop.jl`, and `docs/LIVE_OBSERVATION_VALIDATION.md`.

- Current history shows implementation `c4c47ee` (`Add optional HIL detector observation boundary and bounded qualification`), followed by `354ae53` (`Replace RTC coordinators with WirePlumber session authority`), which deletes `deployment/julia/src/observation_boundary.jl`. The observation source/test therefore existed but was retired in the active architecture; active `src/`/`test/` contain no corresponding `ObservationBoundary` module. The committed validation/review records remain at active `docs/LIVE_OBSERVATION_VALIDATION.md` and `docs/LIVE_OBSERVATION_REVIEW.md`.
- The local untracked observation source and loop test are byte-identical to the earlier `c4c47ee` snapshot. The boundary test differs only in a `DeploymentRunner` constructor field count from that snapshot, consistent with its old source layout. Active later history removes the implementation.
- Many dirty tracked files differ from the `c4c47ee` implementation commit. For example, `owner_protocol.jl` replaces native controller identity with request/reply file paths; `simulator.jl` reintroduces JSON-file HEART reset and removes `HILHeartControl.with_controller`; `deploy.jl` removes native supervisor/acquisition client paths. Those edits are not present in the current package implementation and represent an older/in-progress path, not an improvement already integrated.
- The dirty `docs/LIVE_OBSERVATION_VALIDATION.md` shortens the status to “in progress” and deletes most later qualification/evidence sections relative to current active committed documentation. The dirty `docs/roadmap.md` similarly removes later milestones/evidence. Active committed copies should remain authoritative.
- Disposition: stale/retired implementation and evidence rewind. No unique current runtime contribution identified. The local full validation report is not a safe replacement for the active committed report.

### `pipewireao-rtc-progressive-requal` (`f8dbb47`)

Only untracked paths: `benchmark/profiles/ryzen-6800h-copper-streaming-mvm.cpu`, `benchmark/profiles/ryzen-6800h-copper-streaming-mvm.json`, `benchmark/summarize_copper_capacity.py`.

- Active `benchmark/data/copper_progressive_capacity_20260930.json` and `benchmark/PROGRESSIVE.md` already retain the attempt results and limitations (HEART misses, FGN/JFG delivery/parity observations, no sustained/max-capacity claim). The profile and new summarizer are absent from active history.
- The two `ryzen-6800h-copper-streaming-mvm` profiles are potentially useful, unique experiment configuration: they pin two MVM worker placements (`HOP0.MVM.0101/0201`) in addition to the streaming worker assignments. Retain only if that diagnostic topology may be revisited; no result evidence in these three files demonstrates a run using it.
- The summarizer's purpose (failed-start-retaining finite capacity report) overlaps the checked-in active JSON result. It imports `run_copper_baseline` from the sibling `JuliaFilterGraph.jl/benchmark`, not from active RTC `benchmark/`; that module is not present in the active package. Thus the script is not self-contained in this repository and should not be considered maintained/runnable as-is. No unique result data is in the script.
- Disposition: active conclusion/results are already preserved; profile definitions are the only distinct potentially reusable artifact; script is superseded in result and stale in dependency assumptions.

### `pipewireao-rtc-session-discovery` (`f3f0815`)

Dirty tracked path: `docs/README.md`. Untracked: `deployment/julia/src/native_session_discovery.jl`, `deployment/julia/test/test_native_session_discovery.jl`, `docs/DISCOVERY_INTEGRATION_HANDOFF.md`, `docs/NATIVE_SESSION_DISCOVERY.md`.

- The current package already includes the implementation at `src/native_session_discovery.jl`, its tests at `test/test_native_session_discovery.jl`, and selected runtime integration in `src/wireplumber_session_runtime.jl`, with package includes/tests wired in `src/PipeWireAODeployment.jl` and `test/runtests.jl`.
- Comparing local source/test to active root-layout files shows the active code has evolved: terminology moves from “supervisor” to “session”; `FreshSupervisorStatus` becomes `FreshSessionStatus`; `existing_registry_directory` is added; the active test removes the manual include shim and adds permission-mode coverage. These local files are an older pre-package snapshot, not extra current code.
- `docs/DISCOVERY_INTEGRATION_HANDOFF.md` is byte-identical to the active package file. Local `docs/NATIVE_SESSION_DISCOVERY.md` is older/different from the active version. The dirty `docs/README.md` is an older path/navigation index; active `docs/README.md` already indexes native session discovery under the current `src/` and documentation structure.
- Disposition: duplicate/superseded implementation and docs; no unique current behavior found in the local changes.

## Caveat

This is a source/history disposition, not a content recovery or cleanup authorization. Local changes remain untouched. The progressive MVM placement profiles are the one clearly unique candidate artifact; determine whether that experiment is still intended before removing that dirty worktree or its files.
