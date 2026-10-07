# Independent source fault teardown review

Date: 2026-10-07. Reviewer: independent Astra agent
`fault_shutdown_design_review`. Baseline: `5282c93`; production correction:
`781daf3`; source and evidence hashes: [checks.json](checks.json).

## Disposition

Accept the production correction and scoped report-completion/owned-cleanup
claim. No production blocker was found. The primary agent independently checked
the diff, fail-before/pass-after logs, six receipts, package seals and prefix
comparisons. The evidence wording was narrowed following FT-004; no source or
runtime behavior changed for that clarification. The reviewer then checked the
revised README and review record, confirmed FT-004 resolved and accepted the
narrow merge scope with no remaining blockers. No runtime checks were repeated.

| ID | Severity | Confidence | Evidence and analysis | Remediation / validation | Disposition |
| --- | --- | --- | --- | --- | --- |
| FT-001 | Medium | High | Baseline teardown attempted source coordination after source exit and revoked the core unnecessarily. `deployment/julia/src/deploy.jl` now confirms owned-group cleanup, including adopted descendants, before retaining the core for native cleanup. Exact native binding checks and request deadlines remain. | Source-exit regressions fail against baseline; corrected cases pass, including adopted descendants and cleanup with a failed peer. | Resolved |
| FT-002 | Medium | High | Immediate source termination could interrupt its final report. Core-group revocation now precedes the existing eight-second source grace; failed core revocation leaves grace at zero. | Delayed-marker regression: 12 pass / 1 fail before, 13 pass afterward. Live required-link tests publish final failure reports for both executors. | Resolved within report-completion/owned-cleanup scope |
| FT-003 | Medium | High | Empty-recorder warmup omitted the populated report's `Float64` achieved-rate serializer type. Private warmup now covers all four failure/rate combinations and retains the normal String-failure call without advancing the plant or public acquisition. | Baseline type check: 10 pass / 2 fail. Corrected simulator suite: 199 pass, including 24 report-type/state assertions. | Type gap resolved; its individual contribution to prior teardown latency was not isolated |
| FT-004 | Low | High | The loss harness detects shutdown-signal log text, not process termination signals. SIGKILL cannot emit a Julia diagnostic, and surviving-owner exit signals are absent from the receipts. | README describes no observed shutdown-signal diagnostics. It defines the receipt field's diagnostic-only meaning. Report publication and owned cleanup are directly observed; natural termination remains supported by traces/timing, not a recorded exit signal. | Evidence limitation accepted and claims narrowed |

The existing best-effort native cleanup catches are unchanged. These results do
not establish complete reporting of every failed cleanup RPC. Expected FGN
source-control errors and JFG transport/buffer errors remain in the evidence.
They were not filtered out to obtain success.

## Independent verification

The reviewer read source and retained evidence without edits, runtime tests or
new live processes, and independently verified:

- All 41 initially indexed source, receipt, log and report hashes. The later
  wording-only documentation corrections do not change those hashed inputs.
- All 719 FGN / 718 JFG installed artifact hashes; only the four declared
  shutdown/report/provenance artifact entries differ from the accepted packages.
- All eight actual binary prefix comparisons: two executors × two runs ×
  detector/command prefixes, byte-identical to the corresponding baselines.
- Each fresh-admission sustained report has 512 completed exchanges, 256
  retained prefix frames and 256 measured tail exchanges with zero reported
  simulator Julia heap/GC counters. Prefix reports describe the retained 256
  frames, not the complete 512-exchange run.
- Cold logs total 3,441 SDK assertions, 199 simulator assertions and 45
  strengthened teardown assertions. The delayed-marker test fails before and
  passes after the correction.
- Both required-link-loss logs contain final failure-report publication markers.
  All six receipts record complete owned cleanup. Fresh runs confirm normal
  shutdown, native identities different from the failed deployments, held
  controls and reset/resume after optional observer death.

No fault-time pause acknowledgement, source-revocation latency, camera-rate,
full-trajectory scientific equivalence, link/process ownership transfer,
general multiple-endpoint AOS or physical actuation was qualified. Existing
algorithms, calibration artifacts, Rust runner bytes and unchanged HEART were
preserved.
