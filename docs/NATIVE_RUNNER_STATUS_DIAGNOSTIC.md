# Failed runner Status diagnostic

2026-10-06. Fresh installed Copper FGN v4 used native-only runner SHA
`7968051f1d4d591414f6cffb995f6efbacc4099ccb881bd3a268e67423f9a341`
and the final native qualifier. Admission and earlier queries succeeded. The
cohort subsequently failed with `native runner Status failed`; the final
observed source cursor was 414, paused. All tracked detached groups were absent
at final cleanup. This is a failed integrated gate, not a throughput result.

The supervisor discarded the matched runner Completion result code, lifecycle,
identity and error detail when rejecting a failed Status. The small diagnostic
change retains those fields on the failure path. Success handling, deadlines,
source admission, restoration and allocation boundaries are unchanged.

A deterministic failed-Status fixture demonstrates the diagnostic defect:
four detail checks fail before the change (one exception check passes), and
all five pass afterward. The complete focused coordination file passes 20
assertions. This verifies diagnostic preservation only; it does not repair or
establish the cause of the Copper failure.

Raw failed lifecycle, deployment log and before/after test logs remain under
`~/.cache/rtc-native-final-deployment-20261006/`. The next discrimination is a
fresh sealed installation with the diagnostic change and the same scientific
cohort, preserving the failed package and result. No automatic retry, deadline
extension or inferred scheduling cause is selected.
