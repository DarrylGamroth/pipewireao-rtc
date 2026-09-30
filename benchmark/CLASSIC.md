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

## Row functional checks

Both developed row paths now pass the same short, unsaturated gate: 224 row
blocks, seven ordered DM commands with IDs 0–6, no rejected/dropped/starved
source frames, healthy feedback, and normal process exits.

| Row RTC | Maximum command difference from Rust reference |
| --- | ---: |
| FGN fused SH sensing/reconstruction plus complete control chain | 1.19 × 10⁻⁷ µm |
| JFG split SH measurement blocks/incremental reconstruction plus complete control chain | 2.68 × 10⁻⁷ µm |

JFG's array replay also passes 1,621 lifecycle assertions and allocates zero
steady-frame heap bytes after warmup. Its live owner reports 224 callbacks;
successful frames are attested by the independent DM capture, not inferred
from the callback count. Live allocation and GC diagnostics include session
setup/shutdown and do not establish a zero-allocation transport callback.

Classic requires 32 buffers reserved per frame. The ndarray consumers now
advertise a maximum of 64, retaining their default of four and minimum of two.
The private row daemon explicitly sets the existing `link.max-buffers = 64`
policy. No watermark metadata, extra pixel copy, or camera backpressure was
added. The connected 32-buffer test fails with the former maximum of 16 and
passes with 64 under the same daemon policy; all 16 ndarray tests pass.

The original native FGN replay received every block but omitted frame 0 at
both 2 ms and 20 ms readout. Rust calibration incorrectly retained its pending
discontinuity when the first incoming row was already discontinuous, marking
row two discontinuous and abandoning reconstruction. Both row and region
calibration now consume the pending flag unconditionally before combining it
with the incoming flag. Four reset/adoption regressions fail before the fix
and pass afterward; the two complete integration test files pass 20 tests.
The fixed bundle delivers all seven commands at the original 2 ms pacing.
Calibration arithmetic and controller coefficients are unchanged.

[The row evidence record](data/classic_row_development_20260930.json) retains
ten attempts, the original regression logs, binary hashes, and numerical
reports. Both row paths pass with the staged release core and with that core
installed in `/opt/pipewireao`. All 16 ndarray tests pass in the release build.
Deployment hashes are recorded retrospectively; original run reports are kept. The unchanged HEART
short gate above provides the third RTC comparison. Long clipping/precision,
helper placement, latency percentiles, capacity, and the FITS-to-stdWfs SPA
sender path remain separate work.

## Clipping and numerical limits

None of the seven live frames clip. They establish unsaturated wire agreement,
not live nonzero clipping-feedback equivalence. A separate 1,031-frame array
replay exercises nonzero feedback and validates the Float32 controller
recurrence independently, bit for bit, using each implementation's residuals.
That trajectory nevertheless fails the existing 10⁻⁶ µm cross-implementation
comparison by reaching 1.25 × 10⁻⁶ µm. The criterion has not been relaxed.
See [the precision review](CLASSIC_PRECISION_REVIEW.md).

## Live clipping gate (2026-09-30)

The original seven detector frames were repeated four times without resetting
controller state. Gains, matrices, thresholds, and ±0.8 µm command limits are
unchanged. All five selected paths delivered 896 WFS packets and 28 ordered DM
commands. All outputs contain 168 clipped values, with identical clipping
decisions and 7,588 unclipped reference values.

| RTC path | Maximum command difference, µm | Existing 10⁻⁶ numerical gate |
| --- | ---: | --- |
| FGN complete frame | 5.96 × 10⁻⁸ | Pass |
| JFG complete frame | 4.17 × 10⁻⁷ | Pass |
| FGN row block | 2.98 × 10⁻⁷ | Pass |
| JFG row block | 4.17 × 10⁻⁷ | Pass |
| HEART progressive | 1.31 × 10⁻⁶ | Fail: two unclipped extrapolated values |

JFG's post-stop retained feedback has 15 nonzero final values in both modes;
maximum difference is zero for complete-frame mode and 5.96 × 10⁻⁸ µm for row
mode. HEART's public final clipping count is 15, matching the reference.
These final-state checks do not by themselves attest every intermediate
feedback update. FGN has no live internal feedback snapshot in this harness.
The separate 28-frame JFG row array replay records prelimit commands and
feedback throughout, with maximum differences 2.98 × 10⁻⁷ µm each, 19 frames
with nonzero feedback, and zero warmed steady-frame allocations.

[The clipping evidence](data/classic_clipping_20260930.json) preserves each gate
and its artifacts, including the failed HEART result. [The independent HEART
review](CLASSIC_HEART_CLIPPING_REVIEW.md) localizes both failures to extrapolated
physical rows, each combining 221 controlled coordinates. Existing HEART
circular-buffer dumps were captured after replay with its public client. An
independent Float32 model reproduces every downstream captured value from
HEART's gradients, using fused multiply-add and sequential sparse projection.
Gradient differences are the earliest observed disagreement; the two wire
failures combine propagated controller differences with projection rounding.
The diagnostic run also failed shutdown with a loop-monitor socket error; it
is preserved as a failed run. No numerical criterion has been relaxed. The reported short captures are functional checks,
not capacity or tail-latency qualification.

## Four-gate completion record

1. Numerical analysis is resolved for the CPU comparison: see
   [source-derived arithmetic acceptance](CLASSIC_NUMERICAL_ACCEPTANCE.md).
   HEART's complete model reproduces all 285,033 values in the new 1,029-frame
   wire capture bit for bit. The original 10⁻⁶ cross-implementation failures
   remain failures under that historical criterion. This establishes the
   selected equations and Float32 arithmetic behavior, not an application
   physical accuracy budget. Longer campaigns select this documented policy
   explicitly; their strict comparison files remain present.
2. Helper characterization has passed 18 array cases (0/1/2 workers,
   shared/sharded matrices, three repetitions). Live callback allocation and
   readout timing are still being collected.
3. Long pilot captures now attest exact 1,029-frame delivery for HEART,
   FGN complete frame, FGN rows, JFG complete frame, and JFG rows. They are
   retained as pilots: the repeated placement-controlled series and capacity
   search are not complete.
4. SPA sender qualification has exposed premature Start in the generic
   video-view adapter. The source-only zero-packet failures are preserved.
   A targeted readiness correction is being validated before receiver tests.

## Original gate obligations


1. Resolve numerical acceptance for the observed HEART extrapolation and
   long-sequence precision differences before reporting scientific equivalence.
   The live clipping checks above preserve the original failed gate.
2. Characterize helper layouts and live allocation boundaries after the
   successful release-deployment checks for both short Classic row graphs.
   The 32-buffer negotiation correction is implemented and tested as described
   in [the row design](CLASSIC_ROW_DESIGN.md).
3. Measure repeated first-packet → DM and terminal-packet → DM distributions,
   work completed during readout, and maximum exact-delivery rates for all five
   selected receiver/graph configurations under documented placement.
4. Qualify `FITS source → SPA HEART stdWfs sink → UDP → each RTC` separately,
   as requested in [the progressive plan](PROGRESSIVE.md).
