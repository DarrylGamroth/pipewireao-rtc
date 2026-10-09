# RTC worktree cleanup record — 2026-10-09

## Outcome

Removed eight clean auxiliary worktrees using ordinary `git worktree remove`. Before each removal, full tracked and untracked status was clean and the named branch ref equaled that worktree's `HEAD`; afterward each branch still pointed to the same commit. No force removal was used. No branch, commit, or history was deleted.

The pre-removal `du -sh` measurements total approximately **164M** (rounded per directory). The sizes include ignored build files. The removal command reclaimed the corresponding worktree directories; the figure is an estimate based on those per-directory measurements.

| Removed worktree | Branch retained at unchanged commit | Pre-removal size |
|---|---|---:|
| `pipewireao-rtc-calibration-codec` | `work/calibration-action-codec-20261006` @ `0fb933ca7ca66d88794651a45e2a7465495f4b2f` | 20M |
| `pipewireao-rtc-calibration-codec-review` | `review/calibration-action-codec-20261006` @ `307395edac6378ebc4995650748b16af989cbdc7` | 20M |
| `pipewireao-rtc-native-calibration-consumer` | `work/native-calibration-consumer-20261006` @ `43bc1fd3dded56232af5067b5166e59b5867ad70` | 23M |
| `pipewireao-rtc-native-supervisor` | `rtc-native-supervisor` @ `8d2ec943f3ac0ed69eaba76e6e44e0d569af305b` | 21M |
| `pipewireao-rtc-owner-bootstrap` | `work/native-owner-bootstrap-design-20261006` @ `93a0661d2234ada8cfb11243a9b96167b73caedb` | 21M |
| `pipewireao-rtc-supervisor-codec-review` | `review/supervisor-codec-2a78a31` @ `320d237db772b76ab9b041898c9e72ae42fa1d7a` | 20M |
| `pipewireao-rtc-supervisor-public-review` | `review/native-supervisor-public-d7a711b` @ `62c834c742cdd8daa4e90b824dc1a4562c38210e` | 20M |
| `pipewireao-rtc-systemd-julia` | `work/observation-qualified-20261005` @ `adcd3f6b9bf3e67d9a1839ef24dac485937bb9e5` | 19M |

### Worktree state at cleanup

| Role | Path suffix | Branch | HEAD before → after cleanup |
|---|---|---|---|
| Canonical main | `pipewireao-rtc` | `main` | `4bc5c5d327e7fc1f589b56d7ea80f8396f8b2f1f` → same |
| Active package | `pipewireao-rtc-julia-package` | `codex/julia-package-root-20261008` | `ae540e31700ccb026c999d23241f2a1b1275ae0d` → same |
| Retained dirty | `pipewireao-rtc-live-observation` | `work/live-observation-20261005` | `03770074b590a73156c664ea0d4ea816b5853921` → same |
| Retained dirty | `pipewireao-rtc-progressive-requal` | `copper-progressive-requal-20260929` | `f8dbb47930f8d24fa7711509bac557fe9d867077` → same |
| Retained dirty | `pipewireao-rtc-session-discovery` | `work/session-discovery-20261006` | `f3f0815dc0ffa074e4265aebc51fb07a0d39dac4` → same |

The post-cleanup worktree list contained these five paths only. The active package branch has since advanced; its cleanup-time SHA above is retained for an accurate before/after record.

The three dirty worktrees were left untouched. At inventory time their visible local changes were:

- **Live observation:** 12 modified tracked files: `deployment/hil/Project.toml`, `deployment/hil/owner_protocol.jl`, `deployment/hil/simulator.jl`, `deployment/hil/test_owner_protocol.jl`, `deployment/julia/src/PipeWireAODeployment.jl`, `deployment/julia/src/deploy.jl`, `deployment/julia/src/hil_export.jl`, `deployment/julia/test/runtests.jl`, `deployment/julia/test/test_deploy.jl`, `deployment/julia/test/test_exports.jl`, `docs/operations.md`, `docs/roadmap.md`; 4 untracked files: `deployment/julia/src/observation_boundary.jl`, `deployment/julia/test/test_observation_boundary.jl`, `deployment/julia/test/test_observation_loop.jl`, `docs/LIVE_OBSERVATION_VALIDATION.md`.
- **Progressive requalification:** 3 untracked files: `benchmark/profiles/ryzen-6800h-copper-streaming-mvm.cpu`, `benchmark/profiles/ryzen-6800h-copper-streaming-mvm.json`, `benchmark/summarize_copper_capacity.py`.
- **Session discovery:** 1 modified tracked file, `docs/README.md`; 4 untracked files: `deployment/julia/src/native_session_discovery.jl`, `deployment/julia/test/test_native_session_discovery.jl`, `docs/DISCOVERY_INTEGRATION_HANDOFF.md`, `docs/NATIVE_SESSION_DISCOVERY.md`.

No tracked or untracked file appeared in the eight clean removal candidates at their immediate pre-removal checks. Branches were verified to remain at the listed commits after removal.

## Historical inventory and initial recommendation

The initial read-only inventory was made before the cleanup request was carried out. It correctly identified the 3 dirty worktrees but recommended retaining all other auxiliary worktrees because they had unique commits or review artifacts. That recommendation is historical and superseded by the removal recorded above: the user-directed adjudication preserved those commits with their branch refs, so the eight clean worktree directories could be removed without losing history.

The initial live-observation status summary said 9 modified tracked files; recounting its listed paths gives **12**. This record uses the corrected count. The initial inventory and review artifact findings are available in the task cache at `/home/dgamroth/.cache/rtc-julia-package-20261008/worktree-cleanup-inventory.md`.

A follow-up source/history comparison of the 3 retained dirty worktrees is in [RETAINED_WORKTREES.md](RETAINED_WORKTREES.md). It identifies current/superseded work and the progressive streaming-MVM profiles as a unique candidate artifact; all local changes remain untouched.
