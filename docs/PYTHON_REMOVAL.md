# Python tooling removal — 2026-10-08

Baseline: `6b893b7e98e474580f53ff913751963b62f8db2a` on `main`.
Cleanup branch: `work/python-cleanup-20261008`, initially clean at that revision.

Removed all 104 tracked Python files: former deployment helpers, benchmark
runners/analyzers, tests and historical investigative scripts. Also removed:

- `benchmark/run_revolt_latency.jl`: its Rust test target is retired.
- `deployment/wireplumber/test_session.jl`: its implementation is retired.
- `scripts/build_wireplumber_pilot.sh`: its dependency-alias pilot is retired.
- `docs/validation/systemd-owners-20261007/investigate.jl`: obsolete historical
  coordinator probe containing Python child commands.

No runtime/scientific implementation or recorded result was changed. Current
scripting uses Julia. Old benchmark runners are retired without replacement
parity; the retained Julia reporter can analyze existing compatible CSV records.
Historical source links bind the baseline rather than missing local files.
Julia export guards still exclude Python assets and strip legacy `placement.py`
from imported packages; these are compatibility checks, not Python execution.

## Verification

- Existing Julia SDK suite: **2,663/2,663 assertions across 93 test sets passed**,
  using Julia 1.12.7 with CPU affinity `10,14`.
- Tracked and on-disk Python source inventory in the cleanup worktree: zero.
- Independent source/build/service/CI review: no retained dependency or Python
  invocation; expected Julia exclusion guards remain.
- Historical source links resolve to files at the baseline. Changed current
  guides have valid local targets; pre-existing sibling-worktree links in the
  historical Classic row design remain outside this cleanup.
- Whitespace checks pass. The existing GUI/HIL service remains active.

These are software/source integrity checks, not new live-loop, numerical,
allocation, latency, rate or hardware qualification. Known disposable-fixture
Git diagnostics occurred during successful tests, as in the previous SDK run.
