# Source fault teardown, 2026-10-07

Baseline RTC `5282c93`, dedicated branch/worktree
`fix/graceful-fault-teardown-20261007` /
`/tmp/rtc-graceful-fault-teardown-20261007`. Production correction is `781daf3`.
CPU FGN/JFG, CUDA AOS, Copper complete-frame, 500 Hz model / 100 Hz wall pacing,
non-actuating private cores. CPU0/1, unchanged HEART and desktop services are
outside this increment.

## Changes and acceptance

- An exited source leader is checked through existing owned-group cleanup,
  including adopted descendants. Confirmed group exit replaces an impossible
  pause request; it does not manufacture a pause acknowledgement. The core stays
  available for native cleanup of surviving owners.
- Native runner cleanup after that proof retains exact bindings and request
  deadlines without requiring already-failed peers to pass a health check.
- Unknown source outcomes still require immediate ingress revocation. Once the
  private core group is confirmed gone, the source receives the existing eight
  second owner grace to finish its failure report. Failed core revocation leaves
  source grace at zero. Dead cores receive no native owner requests.
- Private cold report warmup covers `failure::Nothing/String` and
  `achieved_cycle_rate_hz::Nothing/Float64`, including the selected sustained
  companion. The normal String failure method remains warmed. No recorder,
  graph, plant or public acquisition sequence is advanced by this preparation.
- A single cold `SIMULATOR_REPORT_WRITTEN` line confirms final atomic report
  publication. The loss harness checks it for a living simulator and rejects
  recorded Julia shutdown-signal diagnostics and finalizer failures. The deliberately
  killed simulator is exempt from producing a report.

These gates establish fault report completion, owner exit and owned cleanup.
They do not require a fault-free log: expected frame timeout, lost source control
and revoked-core diagnostics remain visible. The intentionally interrupted
exchange is not accepted as delivered. A fresh native pause acknowledgement and
source-revocation latency remain unqualified. The receipt field
`julia_shutdown_interrupted` records a log-text match, not a directly observed
termination signal. SIGKILL cannot emit a Julia diagnostic, and surviving-owner
exit signals were not recorded. Report publication and owned cleanup are direct
observations; natural termination is supported by the traces and timing rather
than an independently recorded exit status.

## Software checks

The SDK suite passes 3,441 assertions, including 45 teardown assertions. The
source-exit checks fail against the baseline. A separate delayed-report case
fails before the change (12 pass / 1 fail) and passes afterward (13 pass), proving
that grace follows core revocation rather than relying on an exit race.
The baseline report-type check fails (10 pass / 2 fail); the corrected simulator
suite passes 199 assertions, including 24 report-type/state checks.
[Cold logs](cold/sdk-tests.log) preserve these results and failures.
The SDK suite's earlier intermediate failed run was corrected by restricting
post-revocation runner cleanup health checks to the existing exact native binding.

## Live checks

The installed copies `/tmp/rtc-fault-teardown-{fgn,jfg}-20261007` change only
`julia/src/deploy.jl`, the two packaged copies of `simulator_owner.jl`, and
`provenance.json`. All 719 FGN / 718 JFG sealed artifact hashes were checked.
Algorithms, calibration matrices/maps, scientific dependencies, graph
configurations and Rust runner bytes are unchanged. Preparation is reproducible
with [the then-current preparation script](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/scripts/prepare_fault_teardown_test.jl).

| Check | CPU FGN | CPU JFG | Scope |
| --- | --- | --- | --- |
| Required-link deletion | [Pass](fgn-linkloss/receipt.json) | [Pass](jfg-linkloss/receipt.json) | Final source fault report written, no observed Julia shutdown-signal/finalizer-failure diagnostics, admission revoked, all owned groups/core removed |
| Simulator SIGKILL | [Pass](fgn-ownerloss/receipt.json) | [Pass](jfg-ownerloss/receipt.json) | Exact owned pidfd injection; surviving owners exit without observed shutdown-signal/finalizer-failure diagnostics, all owned groups/core removed |
| Fresh admission | [Pass](fgn-readmission/receipt.json) | [Pass](jfg-readmission/receipt.json) | New native identities; two 512-command runs per executor, stop/reset/resume, unchanged baseline prefixes and simulator tail heap/GC gates |

The source loss tests preserve native errors. FGN owner loss retains a failed
pause attempt and its nested cleanup diagnostic; JFG retains transport/buffer
failure diagnostics. No error has been filtered out to make these tests pass.
The runner's existing best-effort native cleanup catches are unchanged; these
results do not establish comprehensive reporting of every cleanup RPC failure.

Commands use the existing installed SDK and fresh output directories:

```sh
taskset -c 2-15 env JULIA_PKG_OFFLINE=true OPENBLAS_NUM_THREADS=1 \
  JULIA_NUM_THREADS=1,0 julia --startup-file=no --compiled-modules=existing \
  --project=/tmp/rtc-fault-teardown-fgn-20261007/julia \
  deployment/qualify_wireplumber_loss.jl \
  /tmp/rtc-fault-teardown-fgn-20261007 \
  /tmp/rtc-fault-fgn-linkloss-runtime-20261007 \
  /tmp/rtc-fault-fgn-linkloss-20261007 \
  /home/dgamroth/workspaces/codex/pipewire/wireplumber \
  /tmp/wp-ao-pilot-20261006/build required-link
```

Substitute JFG paths for that executor, `simulator-owner` with fresh paths for
owner loss, and `qualify_wireplumber_hil.jl` without the case argument for fresh
admission. Cold SDK checks use `deployment/julia/test/runtests.jl`; simulator
report checks use `deployment/hil/test_simulator.jl` in an environment containing
both plant packages. The temporary cold environment adds the unchanged Classic
source to the copied Copper dependencies; its unrelated working-tree edits were
preserved.

Logs here are copies with trailing whitespace removed. Original outputs remain
in the corresponding temporary evidence directories. [Checked hashes and assertions](checks.json) cover all six receipts, installed
artifacts, unchanged 256-frame detector/command prefixes and zero simulator
heap/GC tails in both runs. Binary prefixes remain in the temporary evidence
directories; the checked digests and report copies are retained here.
[Independent review](REVIEW.md) records acceptance and limitations.

## Scope limits

Link ownership remains with RTC and process supervision remains with its current
supervisor. WirePlumber realization/withdrawal and independent systemd owner
units have not transferred. No new camera-rate, tail-latency, full-sequence
scientific equivalence, general multi-output AOS, Classic/row/HEART fault or
physical-actuation qualification follows from these tests.
