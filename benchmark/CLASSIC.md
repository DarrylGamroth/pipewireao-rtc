# REVOLT Classic comparison

Date: 2026-09-30. The four-gate development comparison is complete;
see the completion record and validation boundaries below.

The subsequent [scheduler and idle investigation](CLASSIC_PLATFORM.md)
records the repeated 100/250 Hz comparison with matched effective CPU latency
requests, complete diagnostic handoffs, and work completed during readout.

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

The baseline and capacity attempts use unchanged `wfsSimulator` with 11 rows per
UDP packet: 32 packets per frame. The separate FITS/SPA sender qualification uses
the same pixels and packet layout. The initial functional gate uses seven frames at 10 Hz
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
2. Helper characterization passed 18 array cases (0/1/2 workers,
   shared/sharded matrices, three repetitions). Warmed frame and batch allocations
   are zero. Four live 63-frame JFG captures (frame mode and row mode with 0/1/2
   workers) have zero process-wide allocation/GC increments inside every recorded
   callback body. This boundary excludes native transport, initial dispatch,
   property adoption and notification. Whole-stack allocation freedom is not
   claimed. See the JFG live callback and helper evidence documents.
3. The controlled 100 Hz baseline is complete: three successful 1,029-frame
   windows per path, exact delivery and no one-period misses. The original
   failed third HEART attempt is retained alongside its successful replacement.
   Actual readout traces establish completed science work in HEART and derived
   lower bounds in both graph implementations. See [HEART readout evidence](CLASSIC_HEART_READOUT.md)
   and [graph row-work evidence](CLASSIC_ROW_WORK.md). The repeated rate search
   is complete; see [the final capacity evidence](CLASSIC_CAPACITY.md).
4. The same FITS cube now passes through the SPA stdWfs sender into all five
   RTC paths: 2,016 exact input packets and 63 ordered commands per path,
   accepted numerical checks, normal exits and zero source/sender errors.
   Readiness and Position acknowledgement corrections were necessary; the
   zero-packet failures and independent review remain preserved. Fresh installed checks also pass from `/opt/pipewireao` with canonical main
   Rust/Julia receiver roots. The two Julia dependency-startup failures are
   retained alongside successful repeats after refreshing its ignored local
   manifest. See [SPA sender qualification](CLASSIC_SPA_SENDER.md).

## Original repeated 100 Hz baseline

Each path has three distinct process windows of 1,029 detector frames with
2,000 µs requested readout. Latency runs use the documented CPU placement and
uninstrumented deployed PipeWire core. The table gives the range of per-run
percentiles after the first 100 frames (929 samples per run); exact delivery
and the one-period check include all frames. Percentiles are not pooled or
worst-case bounds. All paths emitted 3,087 commands without missing delivery
or 10 ms period overruns.

| RTC path | First packet → DM p50, µs | p99, µs | Terminal packet → DM p50, µs | p99, µs |
| --- | ---: | ---: | ---: | ---: |
| HEART progressive | 2,152–2,160 | 2,268–2,319 | 241–251 | 366–407 |
| FGN complete frame | 2,222–2,225 | 2,545–2,619 | 315–317 | 632–688 |
| JFG complete frame | 2,415–2,454 | 2,679–2,693 | 519–545 | 783–804 |
| FGN rows | 2,366–2,370 | 3,161–3,374 | 450–455 | 1,241–1,451 |
| JFG rows | 2,431–2,495 | 3,001–3,284 | 518–578 | 1,080–1,369 |

The [baseline evidence](data/classic_baseline_20260930.json) records exact
per-window values, artifact hashes and the retained failed HEART attempt.
These original 100 Hz results do not show an end-to-end advantage over HEART. Early
scientific work is demonstrated, but does not establish a net latency benefit
for the current row transport/executors at this workload and pacing. The row
entries above precede the source notification/headroom correction.
The corrected-source 100 Hz row measurements are retained in
[data/classic_row_baseline_fixed_20260930.json](data/classic_row_baseline_fixed_20260930.json);
they also do not establish a net advantage over HEART at 100 Hz.

## Final common 250 Hz comparison

All five paths pass three distinct 1,029-frame windows with the same 2,000 µs
nominal readout and selected science chain. Each path delivered all 3,087 DM
commands, with no first-packet→DM interval exceeding its 4 ms frame period.
The corrected release HEART SPA receiver is used for both graph row paths.
HEART RTC/wfsSimulator are unchanged. The following ranges are per-window
percentiles after the first 100 frames: 929 samples per window. Delivery and
deadline checks include every frame, including startup.

| RTC path | First packet → DM p50, µs | p99, µs | Terminal packet → DM p50, µs | p99, µs |
| --- | ---: | ---: | ---: | ---: |
| HEART progressive | 2,169–2,193 | 2,304–2,327 | 243–262 | 367–384 |
| FGN complete frame | 2,179–2,188 | 2,436–2,654 | 253–272 | 499–720 |
| JFG complete frame | 2,432–2,440 | 2,590–2,829 | 506–519 | 662–894 |
| FGN rows | 1,982–2,061 | 2,091–2,682 | 54–122 | 171–760 |
| JFG rows | 2,028–2,061 | 2,511–2,631 | 99–144 | 573–698 |

[The common-rate evidence](data/classic_common250_20260930.json) retains exact
per-window values, conditions, hashes and artifact locations. Rows reduce
median residual latency and median first-packet latency at this operating point.
Their tail advantage is inconsistent: Julia row p99 exceeds HEART in every
window, and Rust row p99 varies from below to above HEART. These are packet
capture measurements through command wire egress, not exposure→physical DM
response or worst-case execution bounds.

Readout-work diagnostics independently establish actual completed science.
Unchanged HEART completed SH work before terminal receive in all 63 observed
frames, with conservative prior-batch MVM bounds in 62 frames. The corrected
Julia 250 Hz diagnostic establishes completed SH/MVM prefixes in all 63 frames:
4–184 SH subapertures, median 166; 8–368 MVM columns, median 332, each updating
221 controlled outputs. The separate Rust diagnostic establishes positive
completed prefixes in 58/63 frames; zero bounds in the other five do not prove
absence of work. Graph bounds are derived from synchronous successful callbacks
and a documented clock-offset envelope, with a 10 µs sensitivity check.
Instrumented runs are separate from these normal latency/capacity windows.
See [the row-work method](CLASSIC_ROW_WORK.md).

## Tested exact-delivery capacity

| RTC path | Highest passing rate, Hz | First higher failing rate, Hz | Highest all-frame deadline-clean rate, Hz |
| --- | ---: | ---: | ---: |
| HEART progressive | 250 | 750 | 250 |
| FGN complete frame | 1,250 | 1,500 | 250 |
| JFG complete frame | 1,250 | 1,500 | 250 |
| FGN rows | 500 | 750 | 250 |
| JFG rows | 250 | 500 | 250 |

Each passing rate requires three distinct eligible 1,029-frame windows, exact
ordered delivery, selected numerical acceptance, normal child exits, requested
RTC placement and achieved average source rate within ±1%. These are finite
experimental bounds, not sustained hardware maxima. Readout decreases at higher
rates to remain within 85% of the frame period. Full-frame 1,250 Hz windows
were loss-free but missed the frame-period deadline; delivery is not timeliness.
HEART at 500 Hz has only two eligible passing windows and one incomplete capture;
it is neither a passing rate nor a confirmed RTC failure bound. Julia rows at
500 Hz have two exact windows and one eligible dropped-command window.

[The classifier record](CLASSIC_CAPACITY.md) preserves every exclusion, failed
window and original strict numerical result. Losses are mostly early, but a
later Rust row loss at frame 605 is also retained. The evidence does not identify
all remaining high-rate loss mechanisms as JIT, GC or OS scheduling.

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

## Delivery and verification

Reviewed transport and tracing changes are merged to their owning main branches;
normal HEART/FITS and clean two-factory ndarray plugins are deployed and qualified
from `/opt/pipewireao`. The prior installed prototype plugin/header and unrelated
SDK source edits remain preserved in rollback storage and a named WIP branch.
Diagnostic builds were not deployed. HEART RTC/wfsSimulator binaries and science
coefficients are unchanged. [The delivery record](data/classic_main_delivery_20260930.json)
indexes tested source revisions, installed hashes, backups and user-fork pushes.
The focused Classic harness suite passes 155 tests. The independent
[four-gate review](../docs/CLASSIC_FOUR_GATE_VERIFICATION.md) accepts this development
characterization at its documented arithmetic, allocation, clock and finite-window
boundaries.
