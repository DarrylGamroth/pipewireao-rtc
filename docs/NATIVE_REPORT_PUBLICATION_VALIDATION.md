# Native calibration report publication

## Scope

This increment addresses the remaining report-readiness authority in calibration
campaigns and HEART calibration exports under RTC-DEV-030 and issue #9. Saved
JSON remains a diagnostic artifact. It cannot establish live owner completion.
The simulator and unchanged HEART scientific processing are unaffected.

## RPT-001 — Report accepted from another acquisition generation

Severity: medium. Confidence: high. Disposition: corrected in the selected
campaign and HEART export consumers; installed qualification remains pending.

**Observed:** the former `completed_owner_report` polled the saved report and
accepted a paused, restored report with the requested sequence. It did not
compare acquisition generation. A report from generation 1, sequence 35 was
accepted while the current native acquisition cursor was generation 2,
sequence 35. The campaign also obtained its pause sequence from a legacy
`control-reply` file.

**Correction:** the consumer queries the bound public supervisor through native
control. The returned source must have the calibration lifecycle profile and a
fresh successful, token-matched status. Completion requires a connected, paused,
released, restored owner, with no held acquisition and a published report cursor
equal to the current typed acquisition cursor. Polling shares the stage's
absolute deadline and does not retry failed native requests or fall back to a
saved status file.

After publication is established, the saved report is read once. Its domain,
generation, sequence and model time must equal the native committed cursor.
Its domain mapping, profile, backend and graph digest must also match the
admitted startup artifact. Invalid completion, ownership, restoration or failure
fields reject the report. HEART plan exports retain their additional frozen
exposure-count checks.

The operational callers now use `control_locator`. Abort cleanup no longer
depends on the presence of `state.json` before requesting native shutdown.

## Verification

Software fixture evidence, collected with Julia 1.12.7 on 2026-10-06:

| Check | Result |
| --- | --- |
| Same stale-generation fixture against the former helper at `0f0f554` | Expected rejection failed: old helper accepted the report |
| Same fixture against the corrected helper | Expected rejection passed, 1/1 |
| Focused calibration-method and campaign tests | 349 assertions across 11 test sets passed |
| Native publication cases | Pending completion, unpublished and old cursors cannot establish readiness |
| Negative cases | Wrong authority, token, lifecycle, owner phase, saved identity, ownership, restoration and unknown outcomes reject |
| Deadline cases | The same deadline reaches every query; expired entry sends nothing; a failed query is not retried |

Local evidence is retained under
`~/.cache/rtc-live-controls-20261005/`:

- `native-report-generation-discriminator.jl`;
- `native-report-generation-before-20261006.log`;
- `native-report-generation-after-20261006.log`; and
- `native-report-authority-root-final2-20261006.log`.

These checks establish the consumer invariant. They do not establish installed
calibration or correction parity, real-time latency, scientific acceptance, or
physical-device behavior. Fresh installed FGN, JFG and unchanged HEART runs
remain required for the integrated native-control qualification.
