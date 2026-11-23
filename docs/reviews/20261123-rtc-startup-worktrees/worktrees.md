# RTC branches and checkouts on 23 November 2026

The snapshot covers the PipeWireAORTC Git repository at local `main@f62e1e1`.
The server advertised `main@2346963`. Local main contained that commit and
25 more. The [inventory](branches.tsv) records all 260 named local branches,
their exact commits and corresponding server tips where present. The two
detached checkouts appear below. These counts exclude the temporary checkout
used to write this review. A final check found a **21st worktree and 261st
branch** created during the review. `fix/source-revocation-quit` started
at the fault review's `e3113f5` in `~/workspaces/codex/worktrees/rtc-source-revocation`
and had an edit to `src/media_session/machine.jl`. This is the active
repair for the fault work. Coordinate session changes with that worker. The
tables retain their original snapshot so the recorded counts reconcile.

| Relation to local main | Local branches | Interpretation |
| --- | ---: | --- |
| Exact tip already reachable | 193 | Includes main itself. Git preserves all of these histories through local main. |
| All branch-side patches match | 26 | Every branch-only commit in these 26 has an equivalent non-merge patch on main. Their original commit IDs and evidence provenance can still have value. |
| At least one unmatched patch | 41 | Includes research, saved drafts, reviews, release verification and nested branches. Each needs its own disposition before retirement. |

`git cherry f62e1e1 <tip>` compares non-merge patches. It can miss work
that landed through a squash, rewrite or changed context. It also omits
merge resolutions. The inventory shows branch-only commit counts, both
patch counts and any number omitted by the comparison. An unmatched patch
alone does not establish a missing feature. For example, main already has
the CUDA 6.5.1 and AMDGPU 2.11 bounds from the CUDA cohort. The branch
still retains its test records. The 39 branch heads on the server had
one tip outside the history of local main, the CAL2 test draft described below.

## Disposition of the 20 existing worktrees

A clean checkout had no staged, unstaged or nonignored untracked contents at
inspection. All clean rows below also had no ignored contents listed by Git.
Cleanliness says nothing about another worker's plans. The fault review
advanced from 24 changed paths to commit `e3113f5` during the inspection.
The checkout paths for the named branches are in the inventory.

| Checkout or branch | Tip | Disposition |
| --- | --- | --- |
| Main working directory | `f62e1e1` | Keep. Thirteen locally modified paths include development configurations, the workspace, and test fixtures. |
| `codex/native-ndarray-interchange` | `fadea7a` | Integrate the six-commit series as one reviewed change. Its independent test evidence and dependencies are in the [startup review](REVIEW.md). |
| `review/rtc-fault-lifecycle-20261123` | `e3113f5` | Keep the active review. It reproduces a conditional Quit failure and records a release-blocking finite-completion problem in a candidate simulator. |
| `codex/rtc-stop-deadline-v050` | `ccaa1d5` | Preserve the three modified files covering client timing, the historical session CLI and Stop tests. This base is reachable on upstream main. Its local edits need their owner's disposition. |
| `codex/scoped-controller-warmup` | `1c2515f` | Park. Its alternate per-role graph build option overlaps the current CAL2 graph exporter. A three-way preview conflicts in the graph extension, graph startup generator and host profile parser. Revisit only against a measured gap in a named instrument. |
| `codex/session-fault-operation` | `1db1021` | Review with the fault work. It adds the triggering request and effect to failure reporting. Confirm current coverage of the first failed Quit effect before porting it. |
| `codex/cuda-651` | `3d080df` | Retain GPU qualification evidence. The two package compatibility floors are already on main. |
| `codex/fgpw055-verification` | `2031fde` | Retain historical Classic/CAL2/SPIDERS/GPI2 verification. This branch contains the older `codex/gpi2-startup` tip. |
| `work/gpi2-startup` | `4f0c45f` | Retain the 10 November GPI2 cold-start record separately from current timing. |
| `codex/bootstrap-error-invalidation` | `e0fe1e7` | Clean. Exact tip on upstream main. Calibration-loaded bootstrap compilation is already included. |
| `codex/gpi2-pupil-tap` | `01c5537` | Clean. Exact tip on upstream main. |
| `rtc-gpi2-woofer-hold` (detached) | `c2c5ad5` | Clean. Exact tip on local main and the session-idle integration branch. |
| `codex/session-agent-idle` | `5ffcaa7` | Clean. Exact tip on local main. |
| `codex/gpi2-session-idle-integration` | `c2c5ad5` | Clean. Exact tip on local main. |
| `codex/rtc-stop-deadline-trace-v0728` | `a8b2029` | Clean. Exact tip on upstream main. Distinct from the modified v050 checkout. |
| `codex/chopped-detector-warmup` | `52eda81` | Clean. Exact tip on upstream main. |
| `codex/release-rtc-0.7.24` | `22f8b94` | Clean. Exact tip on upstream main. |
| `codex/gpi2-intensity-export` | `0ee4c0e` | Its one branch-only patch matches local main. |
| `codex/gpi2-intensity-runtime` | `e46035f` | Its two branch-only patches match local main. |
| `/var/tmp/gpi2-pupil-tap.LQRnhIc0/qualified-rtc` (detached) | `7af920a` | Its four branch-only patches match local main. The original tip is also reachable from `codex/gpi2-pupil-tap-pre-upstream-rebase`. |

The **eight** clean, exact-ancestor worktrees are the first candidates to
retire after confirming that their owners and installed fixtures no longer
use the paths. The three patch-equivalent GPI2 worktrees are a second group.
Removing a checkout and deleting its branch are separate decisions.
`git worktree prune --dry-run` found no stale registrations. None of the 20
checkouts was removed by this review.

## Outstanding work without a dedicated RTC checkout

- The only open RTC pull request was the October CAL2 capture draft,
  `test/cal2-selected-calibration@4d302d8`. GitHub reports conflicts. Its
  seven commits affect three test files. Main's capture code already reads
  the declared calibration selection and records acquisition timing.
  Compare the remaining assertions for standalone pupil capture and failure
  diagnostics with the current tests, then port any gap and close the old
  draft. [Pull request 25](https://github.com/DarrylGamroth/pipewireao-rtc/pull/25)
- Keep `benchmark/gpi2-handoff-20261121`, the transport and buffer-ownership
  reviews, historical SPIDERS optical trials and explicitly named archive
  branches as evidence. Several SPIDERS refs descend from one another.
  The old simulator-startup branch also contains the canonical-metadata
  latency branch. The number of tips overstates the number of independent
  changes.
- `codex/cal2-live-prime-instrument@c9e6bb9` is in
  `adaptive-optics-simulations`. Its two instrument switches require a
  released RTC containing the install-time qualification and live close gate.
  Carry that branch to the next compatible release. This is the instrument
  dependency relevant to this review. The census covers RTC.
