# Classic composed Rust row graph

Date: 2026-10-01.

FGN Classic now uses nine nodes: row calibration, separate SH measurement-block
and generic incremental reconstruction, plus the unchanged six controller,
projection, limiting and feedback nodes. JFG already uses this decomposition.

The live runner loads sensing parameters through `shack-hartmann:*` and the
matrix through `reconstruction:reconstructor` for both backends. The platform
campaign's `--fgn-root` selects the generator, binary and recorded source root
consistently; its default remains the main FGN checkout.

[Implementation and qualification](../../calculon-algorithms-main-copper/docs/classic-composed-row.md)
and [results](../../calculon-algorithms-main-copper/docs/classic-composed-row-results.json)
record the numerical/component tests and live replay. Both 1,029-frame windows
at 100 and 250 Hz had exact delivery, zero deadline overruns and DM command
bytes identical to the saved fused FGN baseline. Terminal-packet → DM medians
were 65.713 and 66.284 µs. Acceptance coefficients were unchanged.

Earlier eight-node FGN reports remain historical. This increment does not
requalify JFG, HEART, maximum rate, GPU execution or physical hardware.
