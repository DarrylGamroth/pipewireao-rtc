# Final native foreground qualification

2026-10-06. [Evidence ledger](NATIVE_FINAL_FOREGROUND_EVIDENCE.json) records
exact installed packages, descriptor/qualifier/runner hashes and raw results.
Each uses the native-only runner and verified native supervisor admission,
then 512 complete exchanges, stopped reset, and another 512 exchanges.
The configured simulation model is 500 Hz; paced closed-loop wall cadence is
100 Hz. Sixteen retained prefix exchanges precede each allocation interval.
GC remains enabled. Placement excludes CPUs 0/1 but includes a core shared with
an unrelated existing process; these are functional and allocation checks.

| Implementation | Exact exchanges per run | Measured exchanges per run | Simulator heap / GC | Reset and cleanup |
| --- | ---: | ---: | --- | --- |
| Classic FGN v6 | 512 | 496 | All reported fields zero | Passed |
| Classic JFG v5 | 512 | 496 | All reported fields zero | Passed |
| Copper FGN v5 | 512 | 496 | All reported fields zero | Passed |
| Copper JFG v4 | 512 | 496 | All reported fields zero | Passed |

The inclusive allocation scope is the simulator process after its retained
prefix, including optics, transport, recording, diagnostics and controls,
excluding final report serialization. Command and pixel prefixes are byte exact
across each stopped reset. This is within-implementation reset repeatability,
not cross-implementation scientific equivalence. Classic has no detector upper
rail samples. Each Copper run reports two upper-rail pixels in two frames;
that existing science remains unchanged and is not hidden by the comparison.
Detector saturation is distinct from DM limiting.

Copper FGN v4 failed after native admission with a generic runner Status error;
its last source observation was sequence 414, paused, followed by complete
cleanup. [The diagnostic correction](NATIVE_RUNNER_STATUS_DIAGNOSTIC.md)
preserves the detailed typed error. The subsequent fresh v5 installation did
not reproduce the failure. Its cause remains unknown; success is not evidence
that diagnostic preservation fixed the underlying failure.

These checks do not qualify systemd services, midrun pause/resume, calibration
restoration, unchanged HEART, live GUI/observer attachment, maximum rate,
progressive readout, hard deadlines or hardware. Those remain separate gates in
[the final qualification plan](NATIVE_FINAL_QUALIFICATION_PLAN.md).
