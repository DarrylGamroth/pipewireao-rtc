# REVOLT Classic comparison

Date: 2026-09-30. Development comparison in progress.

## Common workload

The comparison uses the original seven-frame 352 × 352 Classic FITS cube,
188 Shack–Hartmann subapertures of 22 × 22 pixels, the original reconstructor
and extrapolator, and 277 physical commands. Rust and Julia retain 221
controlled coordinates; HEART retains its original padded 277-coordinate
representation. These representations implement the same selected control law,
but their operation counts differ.

The selected controller uses gain −0.3, pole 0.99, anti-windup gain 0.99 in
FGN/JFG, and limits ±0.8 µm. Background, coordinates, reference slopes,
thresholds, active mask and projection arrays come from the maintained Classic
calibrations. See [the matched-chain review](CLASSIC_MATCHED_REVIEW.md).

All live attempts use unchanged `wfsSimulator` with 11 rows per UDP packet:
32 packets per frame. The initial functional gate uses seven frames at 10 Hz
and 2,000 µs nominal readout. It does not establish latency percentiles,
maximum throughput, strict RT placement, or physical operation.

## Complete-frame functional checks

| RTC receiver | WFS packets / DM commands | Maximum command difference from Rust reference | Run status |
| --- | --- | ---: | --- |
| FGN complete frame | 224 / 7 | 2.98 × 10⁻⁸ µm | Pass, all children exit normally |
| JFG complete frame | 224 / 7 | 1.79 × 10⁻⁷ µm | Pass, seven callbacks, feedback bridge healthy, normal exit |
| Unchanged progressive HEART | 224 / 7 | 4.17 × 10⁻⁷ µm | Pass, live flags/mode verified, normal exit |

FGN and JFG report zero source rejection, drops, and buffer starvation. Their
fresh final-harness runs are `rtc-classic-fgn-fullframe-short-r4-20260930` and
`rtc-classic-jfg-fullframe-short-r2-20260930` under `~/.cache`. The HEART row
is `rtc-classic-heart-progressive-short-r5-20260930`. Existing GMS readback
verifies the selected flags and authoritative command-handler correction mode
before ingress and after replay. The internal integrator state has no readback
in this harness, so full qualification remains distinct from the short gate.
Earlier alias, huge-page, telemetry and diagnostic-state failures are retained.

The [evidence record](data/classic_fullframe_development_20260930.json) retains
every attempt, including native startup failures before pixel ingress.
The [transport review](CLASSIC_TRANSPORT_REVIEW.md) records their dispositions.
The Python harness requires NumPy and PyYAML plus the existing capture tools;
it loads developed graphs and provides no scientific implementation.

## Clipping and numerical limits

None of the seven live frames clip. They establish unsaturated wire agreement,
not live nonzero clipping-feedback equivalence. A separate 1,031-frame array
replay exercises nonzero feedback and validates the Float32 controller
recurrence independently, bit for bit, using each implementation's residuals.
That trajectory nevertheless fails the existing 10⁻⁶ µm cross-implementation
comparison by reaching 1.25 × 10⁻⁶ µm. The criterion has not been relaxed.
See [the precision review](CLASSIC_PRECISION_REVIEW.md).

## Remaining gates

1. Exercise live nonzero clipping feedback and preserve the long-sequence
   precision evidence before reporting scientific equivalence.
2. Qualify Classic row graphs. Their 32-buffer source requirement currently
   conflicts with the 16-buffer maximum advertised by ndarray consumers;
   [the row design](CLASSIC_ROW_DESIGN.md) proposes a bounded range correction.
3. Measure repeated first-packet → DM and terminal-packet → DM distributions,
   work completed during readout, and maximum exact-delivery rates for all five
   selected receiver/graph configurations under documented placement.
4. Qualify `FITS source → SPA HEART stdWfs sink → UDP → each RTC` separately,
   as requested in [the progressive plan](PROGRESSIVE.md).
