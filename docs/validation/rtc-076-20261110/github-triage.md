# RTC GitHub triage — 2026-11-10

Reviewed all 17 open issues and the one open draft pull request in
`DarrylGamroth/pipewireao-rtc` against the 0.7.6 release and current
repository evidence. The dispositions below are proposed GitHub updates.

## Work to keep open

| Item | Current evidence and next check |
| --- | --- |
| [#41 GPI2 control enters Fault](https://github.com/DarrylGamroth/pipewireao-rtc/issues/41) | Highest priority. Open-loop and woofer-offset transactions both produced an unknown effect outcome on 0.7.3. Local main has a separate cold control preparation change at `7140c2e`, outside the 0.7.6 tag. Use a fresh private GPI2 CPU session to verify both operations against that change and correlate admission, submission, adoption/readback and terminal reply. Preserve the unknown-outcome fence. |
| [#12 Native Quit timeout](https://github.com/DarrylGamroth/pipewireao-rtc/issues/12) | Keep the timeout investigation. The old Classic report used WirePlumber. A [recent SPIDERS run](../spiders-managed-startup-20261109/README.md) still expired during native Quit and completed emergency cleanup. Capture the effect that consumes the shutdown budget on a current cohort. |
| [#9 Native lifecycle and integrated qualification](https://github.com/DarrylGamroth/pipewireao-rtc/issues/9) | Retain as the qualification tracker after replacing the old owner and deployment matrix with the maintained profiles. Use the [current roadmap](../../roadmap.md#current-work) to distinguish individual profile and timing gates. |
| [#11 Classic CUDA retained buffer loss](https://github.com/DarrylGamroth/pipewireao-rtc/issues/11) | The report identifies a required Link loss after a native retained-buffer error. Reproduce on the current Classic CUDA cohort and record the exact producer, Link and buffer transitions before assigning a transport fix. |
| [#13 Classic queue ownership failure](https://github.com/DarrylGamroth/pipewireao-rtc/issues/13) | Retest demand telemetry with the separately registered queue artifact. The original protocol error came from a different deployed queue binary. If it recurs, capture pool withdrawal and playback return ordering for the queue owner. |
| [PR #25 CAL2 lifecycle selector](https://github.com/DarrylGamroth/pipewireao-rtc/pull/25) | Still relevant. Main's test reads a fixed `generated/calibration` path. The draft follows the executed selection and improves capture and cleanup diagnostics. The merge preview shows conflicts in the lifecycle harness. Refresh it against main and pass the selected-calibration native lifecycle and capture gate before merging. The draft reports a previous capture gap after Running. |

## Items to reconcile

| Item | Proposed disposition |
| --- | --- |
| [#3 Sparse Registry queue identity](https://github.com/DarrylGamroth/pipewireao-rtc/issues/3) | Close the reported defect. [OBSR-002](../../LIVE_OBSERVATION_REVIEW.md#obsr-002--identity-property-deltas-and-asynchronous-preparation) records delayed NodeInfo admission, exact identity checks and 41 boundary assertions. Keep profile-level observation qualification in #9. |
| [#4 Local session discovery](https://github.com/DarrylGamroth/pipewireao-rtc/issues/4) | Close the RTC contract work after linking the current discovery tests and GUI selection evidence. The contract has named locators, a fresh native Status requirement and explicit stale or inaccessible outcomes. Track current GUI or remote-access gaps against their owners. |
| [#5 HEART native wrapper](https://github.com/DarrylGamroth/pipewireao-rtc/issues/5) | The issue records a merged wrapper and actual unchanged vendor-process qualification. Close the wrapper increment and carry any applicable consumer gates into the lifecycle tracker. |
| [#6 Acquisition owner lifecycle](https://github.com/DarrylGamroth/pipewireao-rtc/issues/6) | Replace references to retired owners with specific verification gaps for current bootstrap, SourceControl and calibration endpoints. Preserve historical cursor and restoration evidence. |
| [#7 Native calibration actions](https://github.com/DarrylGamroth/pipewireao-rtc/issues/7) | Reconcile the completed Julia native action path with the obsolete Rust RTC coordinator requirement. Keep any maintained external-client interoperability and installed-profile acceptance as explicit gates. |
| [#8 Native operator supervisor](https://github.com/DarrylGamroth/pipewireao-rtc/issues/8) | The Julia MediaSession and native client implement the public operator path. Re-scope the issue to any remaining actual-caller and profile qualification in #9. |
| [#10 WirePlumber Quit rejection in Fault](https://github.com/DarrylGamroth/pipewireao-rtc/issues/10) | Supersede the old operation admission defect. The current HSM handles Quit in Managed, which includes Fault. Keep a current actual-caller Fault-to-Quit gate under #9 or #12. |
| [#36 Describe deadline](https://github.com/DarrylGamroth/pipewireao-rtc/issues/36), [#37 rebuild Status](https://github.com/DarrylGamroth/pipewireao-rtc/issues/37), [#38 post-reconnect Status](https://github.com/DarrylGamroth/pipewireao-rtc/issues/38) | Close as superseded by the [RTC simulator settings and rebuild service retirement](../../reviews/20261107-simulator-retirement/REVIEW.md). #37 has an isolated, tested token patch from the old path. If the active native Status client reproduces a token rejection, record it separately against the current owner and caller. |
| [#39 Optical clock keyword](https://github.com/DarrylGamroth/pipewireao-rtc/issues/39) | Close with `837fa60` and the [constructor regression](../optical-observation-clock-20261102/README.md). |
| [#40 Synchronized analysis keyword](https://github.com/DarrylGamroth/pipewireao-rtc/issues/40) | Close with `8c28b72` and the [synchronized WFS regression](../analysis-construction-20261102/README.md). |
