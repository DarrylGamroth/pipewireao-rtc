# Installed owner shutdown qualification — 2026-10-09

## Scope and changes

WirePlumber remains the session authority, systemd owns process lifetime, and
scientific owners close their own resources. HEART's implementation is unchanged.
Ordinary Quit now holds the source and graphs, withdraws owned links, requests
existing native owner shutdown operations and validates their terminal replies
before publishing Offline and disconnecting. Emergency cleanup remains separate.

Native owners retain successful terminal replies until the exact issuing
controller disappears or the original request deadline expires. Publication at
the server alone does not prove that an asynchronous reader consumed the reply.
The terminal admission gate rejects fresh requests atomically with publication;
exact replay preserves the original completion and deadline.

| Component | Qualified source |
| --- | --- |
| Shared Julia runtime | `ca27a5576ca58d3874ad0d08f373a6673a02a3b6` |
| REVOLT HEART wrapper | `6611e0063feab9eb5ec7e5fb1ec370c54d342b7b` |
| REVOLT shared dependency pin | `18ff717` (tree verified against shared commit) |
| Installed WirePlumber | `650e9843a6093dd850f3498bf68f0baeec663d18` |

WirePlumber was installed using `meson install -C build --no-rebuild` into the
user-owned `/opt/pipewireao` prefix. Installed session/owner Lua SHA-256 values
match source. Fresh sealed SDKs copy that installed runtime and both Julia
projects; original graph, calibration, simulated plant and HEART binary bytes
are hash-checked and preserved. Original sealed SDKs are not modified.

## Software evidence

- Shared strict package tests: 1,562 assertions in 42 sets.
- REVOLT strict package tests with the same developed shared source: 1,362 in 65.
- Actual private-core delayed-reader checks: 40 bootstrap and 35 HEART checks.
- Existing bootstrap, sealed-authority and endpoint-fault checks: 49, 66 and 46.
- WirePlumber Meson checks: all 57 passed, including native shutdown payloads.
- Bootstrap allocation checks: 12 passed; isolated connected/idle bootstrap
  windows measured zero bytes. This does not qualify graph allocations.

The previous bootstrap runtime fails the same delayed enum-reader experiment:
it removes its endpoint before observation. The fixed runtime retains the
successful result, rejects new work, permits exact replay and terminates on exact
controller removal or finite expiry. Tests also retain proof-revocation faults.
The [independent review](REVIEW.md) records TSH-001 and its verified remediation.
Its reviewed test run had 35 bootstrap/30 HEART assertions; the final 40/35 runs
add explicit replay-state checks without changing the reviewed production code.

Exact commands, logs and source hashes are preserved in the
[implementation evidence](IMPLEMENTATION_EVIDENCE.md) and
`/home/dgamroth/.cache/rtc-julia-package-20261008/shutdown-review-20261009.md`.
Installed logs and bounded receipts are under that cache's `installed-checks/`.

## Installed lifecycle evidence

Selected checks exercise admission, held/running gain requests, reconstructor
submission, reset/resume, accepted native Quit and exact owned cleanup. Running
gain replies prove active generation 2; held reconstructor requests establish
submission, not subsequent graph adoption. Model period is 2 ms with 10 Hz wall
pacing for CPU FGN/JFG and CUDA AOS. Classic exposure remains 1.896 ms. These are
functional controls checks, not 500 Hz measurements.

The first installed Classic FGN invocation is
`516ee43bb8e1475fbbcfb08e2c5fe5bb`, unit
`pipewireao-session@ec8c95002f4d.service`. Accepted native Quit proves the installed
Lua owner completion chain. Its successful source report and source/parameter
termination records precede private core stop; its journal has no revocation,
broken-pipe or finalizer faults. Cleanup and owned unit-file removal pass.

The final launch record's owner snapshots describe the pre-shutdown state.
Post-cleanup `systemctl show` returns unloaded/default status; it is not retained
proof of individual exit-zero codes. Do not infer those codes from the defaults.
The native completion chain, exact journal chronology and bounded cleanup are
the evidence for this scoped lifecycle result.

| Profile/engine | Exact invocation | Journal faults |
| --- | --- | --- |
| Classic FGN | `516ee43bb8e1475fbbcfb08e2c5fe5bb` | None flagged |
| Classic JFG | `65a3edc9624243e997e3a75e6dc6ca15` | None flagged |
| Copper FGN | `5d41bee4bb5f45768a989f8a6fa9845f` | None flagged |
| Copper JFG | `9fd5f477307f44138d260c48a3bafe70` | None flagged |
| Classic unchanged HEART bridge | `802ff065d8a04d8888509f6cba93aa39` | No owner shutdown faults |

All four pass the controls, reset/resume, native Quit, bounded cleanup and
unit-file removal checks above. Their source completion reports have
`failed=false`. Native bootstrap-owner termination records precede core stop.
The journal checks cover controller revocation, Julia exceptions, process-failure
records, broken pipes, unexpected SIGTERM and finalizer errors.

The unchanged HEART bridge separately passes admission, start/stop, reset with
child generation 1→2 and a new PID, restart and native shutdown/cleanup. Its
CPU simulator retains the original 10 Hz model rate and finite acquisition;
the final source window records ten frames/commands and `failed=false`.
This does not qualify HEART scientific calibration/correction. Its core logs
one `pw.port: can't setup mixer` warning during negotiation; selected lifecycle
and source-count checks pass. The same warning occurs in the earlier installed
baseline invocation `cd0ac87d5525479981c2d5a7f52e5900`; it is not a new shutdown
regression. This result is not treated as a numerical or
loss-free throughput result.

## Scientific and resource boundaries

Classic's earlier invalid acquisition remains a failed gate. Bounded native
Capture distinguishes insufficient active-region flux from transport failure:
the unchanged flat lamp input has finite outputs but several active regions
below its sealed flux threshold. A separately declared brighter lamp capture
passes all 184 active regions without saturation. Thresholds, mask and seed are
unchanged. Instrument-owned evidence records the input change and acquisition
retry separately; it does not establish interaction-matrix accuracy.

Both brighter-lamp installed Classic acquisition pilots pass two quality-valid
response batches (two exposures per probe), restoration, release, a completed
source query, native Quit and owned cleanup. FGN invocation:
`f1cbb0e2a5db4290bdb23a1689a30309`; JFG invocation:
`e490b4655c034e27bef16794f1b65540`. Neither journal has flagged owner faults.
The [bounded summary](qualification-summary.json) records all seven checks and
their exact cached receipt/journal hashes; raw scientific payloads stay outside
the source repository.

Full matrix adoption, scientific precision, complete allocation boundaries,
row-block profile parity, accelerator alternatives and timing/rate acceptance
retain their own gates. No physical or hardware-loop qualification is claimed.
The earlier JFG buffer errors during emergency cleanup after a rejected
calibration remain recorded in the instrument evidence; the successful normal
Quit checks do not establish their separate root cause or emergency-path repair.

## Worktree cleanup

The [cleanup record](WORKTREE_CLEANUP.md) records eight clean worktrees removed,
approximately 164 MiB reclaimed and all branch refs retained. Three dirty trees
remain intact; their [disposition](RETAINED_WORKTREES.md) identifies superseded
code and the unique historical MVM placement profiles.
WirePlumber's qualified branch was fast-forwarded and pushed to its own fork's
`master` at `f248ff5770c42d6d04c4745952cb4ce980072f5d`. Its clean completed worktree
was then removed normally, reclaiming approximately another 130 MiB including
the build directory. Its branch ref and installed `/opt/pipewireao` runtime
remain intact.
