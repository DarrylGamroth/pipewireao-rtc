# A low-order update between the two guarded closes

This run used the same pause, pulse and restored reference as the matched
112-mode experiment. The protective reset at tick 1801 held both branches
open. A fresh camera return delivered zero demand at the calibrated flat.
A generation-correlated release succeeded. The LLOWFS branch produced its
fresh flat evidence and closed on tick 1803.

On tick 1804 LLOWFS ran first. Its next update put a small nonzero demand
on the mirror (peak 1.3338252 × 10⁻⁵). The SCC pair then produced a shared
command at the same nonzero peak. SCC's reference observation sequence
was still zero and its close guard stayed set. The attempt to obtain
SCC readiness expired. The test ended there.

[Native control readbacks](gates.txt) and [actual shared command
cursors](applied-command.csv) give the event order. This is one observed
ordering on the private core.
