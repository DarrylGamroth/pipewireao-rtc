# WirePlumber session checks

Scope: isolated, non-actuating Copper complete-frame CPU FGN/JFG with CUDA AOS.
Wall pacing is 10 Hz; simulated model period/exposure is 2 ms. These checks
establish functional lifecycle and retained-output behavior, not real-time
latency, throughput or physical qualification. The active GUI/HIL service is
untouched. The private core uses PipeWire commit `691928291`;
`/opt/pipewireao` is unchanged.

## Scientific and live control checks

| Check | FGN | JFG |
| --- | --- | --- |
| Held startup, verified placement, fresh native READY | Pass | Pass |
| Native reset/start/stop | Pass | Pass |
| Stopped gain/matrix submission, subsequent active adoption | Pass | Pass |
| Running gain/matrix updates, requested = active generation | Pass | Pass |
| Frame/command exchanges after restoring baseline and reset | 512/512 | 512/512 |
| Retained 256-frame pixels/commands match accepted per-engine prefix | Exact | Exact |
| Simulator post-prefix 256-exchange allocation/GC counters | Zero | Zero |

FGN evidence: [updates](fgn-final-updates.log),
[complete controls](fgn-complete-controls.log),
[result](fgn-complete-simulator-result.json),
[sustained result](fgn-complete-simulator-result.json.sustained.json).
JFG evidence: [updates](jfg-final-updates.log),
[complete controls](jfg-complete-controls.log),
[result](jfg-complete-simulator-result.json),
[sustained result](jfg-complete-simulator-result.json.sustained.json),
[prefix hashes](jfg-complete-prefix-hashes.json).
Accepted hashes are recorded in
[the earlier owner-service evidence](../systemd-owners-20261007/evidence.json).
No cross-engine bitwise-equivalence claim follows: each matches its own accepted
scientific baseline. Simulator allocation counters cover its process after the
retained prefix, including controls, but exclude final report serialization;
they do not measure the entire RTC or cold matrix-update allocations.

## Loss, Quit and cleanup

FGN invocation `ec6dc3f832c24f6fb79507ffb1f2ec31`, manager PID 792520:
actual required parameter-owner SIGKILL produces fresh native Fault with zero
owned links. The journal identifies required registry incarnation removal;
this exercises the corrected ObjectManager removal path.
[Loss controls](fgn-parameter-loss.json), [journal](fgn-parameter-loss.log),
[final cleanup](fgn-final-cleanup.json) record the exact cohort.

JFG invocation `37128b39dbea4816aafaee178c8a37cb`, manager PID 799558:
[native Quit](jfg-quit-controls.log) reports Offline and shutdown accepted.
The exact systemd unit becomes inactive/MainPID zero;
[cleanup](jfg-final-cleanup.json) reports cleanup_complete=true.
The one-shot start helper admits this fresh instance while a separate shared
FGN template exists, following the WPI-27 guard correction.

These checks preserve the active unrelated GUI/HIL service. They do not prove
all Link, graph, source, manager or Core loss variants, pending-operation
uncertainty, source-silence handling, or revocation latency.

## Final coordinator-free SDK

Fresh JFG instance `d19c851c8e53`, invocation
`74ba3f03245540b1a407e73b643e22f5`, manager PID 836201, runs an exported SDK
without the old coordinator binary, launcher, modules or templates. It completes
another 512 exchanges and matches the same accepted retained prefix hashes:
[controls](jfg-final-sdk-complete-controls.log),
[result](jfg-final-sdk-simulator-result.json.sustained.json),
[hashes](jfg-final-sdk-prefix-hashes.json).
The simulator measured tail again reports zero allocations/GC.

The GUI's exact selected-session read-only test observes Ready and renders its
production picker/panels offscreen:
[GUI check](gui-direct-readmission.log). It does not qualify a native window or
full GUI mutation/source telemetry coverage.

The corrected one-shot Julia normal shutdown obtains native Quit→Offline
acknowledgement and complete exact-unit cleanup:
[shutdown](jfg-final-sdk-shutdown.log),
[attempt/acknowledgement](jfg-final-sdk-shutdown-attempt.json),
[cleanup](jfg-final-sdk-cleanup.json). The unit is inactive/MainPID zero.
The unrelated active GUI/HIL service retains PID 1632744.

[SDK export/install](julia-coordinator-retirement-sdk.log) and the
[production calibration export/install](calibration-export-install-check.log)
pass without services. The latter uses actual sealed WirePlumber assets and a
placeholder calibration executable; it proves packaging, not acquisition.
[Review](REVIEW.md) records independent rechecks of the retirement and the two
calibration corrections. Broad profile and failure qualification below remains
open.

## Preserved original failures

The first FGN incarnation `3ff44037c3e040869405fea7a9ca165d` reached Ready and
passed start/stop/reset, then stopped matrix publication timed out because its
publisher waited for a processing callback. The original
[failed control](stopped-parameter-fail-before.log) and
[journal](fgn-ready-journal.log) remain. The corrected publisher queues a free
borrowed output buffer while paused, fences deferred publication authority, and
reports Submitted separately from graph adoption. Both full-session update
checks above demonstrate pass-after behavior.

[Review](REVIEW.md) records other source findings and their distinct evidence
scopes. The original failure reports remain scoped to their original revisions.

## Final software checks and dependencies

- [Julia suite](julia-final-tests.log): 2,620 assertions in 88 test sets pass.
- [Rust suite](rust-final-tests.log): all retained targets pass (70 library,
  5 calibration binary, 19 calibration, 3 calibration CLI and 2 ingress tests).
- [Rust Clippy](rust-final-clippy.log): all live targets pass with warnings denied.
  Rust formatting and diff whitespace checks pass.
- [WirePlumber build](wireplumber-final-build.log): pass.

WirePlumberAO session implementation is commit `9e339138` on
`work/ao-session-20261007`. PipeWireAO's required Link info correction is
commit `691928291` on `work/link-info-mask-20261007`. The checks use these
private builds; they do not qualify the unchanged `/opt/pipewireao` installation.

## Remaining qualification

- Full replacement loss/timeout matrix and delayed publication cases.
- Classic, row-block, operational calibration/HEART and general multi-endpoint
  session profiles; their earlier scientific artifacts remain preserved.
- Target rate, deadline and latency qualification.

The runtime coordinators and supervisor fallbacks are removed in the migration
worktree. Old supervisor-specific qualification programs/tests are retired;
their source remains available at baseline `e791361e`, and their historical
reports do not become evidence for the new architecture. One-shot exporters,
scientific owners and operational calibration clients remain.
