# Progressive Copper and Classic comparison

## Scope

Requalify the existing CPU row-block graphs after the core ready-retry repair.
The reference full-frame comparison is
`data/copper_merged_fullframe_baseline_20260929.json`. The deployment launcher
starts and controls the scientific graph; it does not execute each frame.

Work starts from RTC `5f7e37e`, JFG `7a126ec`, and FGN `8361b31` in separate
`copper-progressive-requal-20260929` worktrees. The recipe starts from
`45525861cde` and pins core `d130d3afa` for the next native JLL release. These
checkouts were clean before the comparison changes.

## Copper acceptance

1. Build and check the portable native JLL from the repaired core. Keep the
   HEART plugin provenance separate: it is not part of that artifact.
2. Run a short three-way row replay, then three independent 1,024-frame replays
   using the shared FITS cube, identical reconstructor/projections/flat,
   clipping feedback, and a ±0.8 µm command limit.
3. Use the unchanged HEART simulator, gated before ingress, at 474 Hz with
   2,000 µs readout and two 32-row packets per frame. Readout stays within the
   frame period. Check the declared FIFO policies and CPU placement.
4. Connect one DM consumer per graph output. Require exactly 2,048 input
   packets, 1,024 ordered physical DM commands, zero source drops/starvations,
   and command error ≤10⁻⁶ µm. Report clipping independently so saturation
   cannot conceal disagreement. Retain packet and command identities.
5. Compare first-packet → DM, terminal-packet → DM, and packet spacing against
   the full-frame record. Retain first-frame and warmed distributions
   separately. Profile the remaining terminal work only after delivery and
   numerical checks pass.

Use borrowed row-block buffers with bounded ownership. Under overload, discard
whole frames explicitly while reception continues. Do not add camera
backpressure or frame-progress metadata. No tuning or concurrent builds are
part of a latency replay. The host is not isolated, so finite trials characterize
latency and delivery rather than establish a worst-case bound.

## Classic follow-up

Current implementation and retained functional checks are summarized in
[the Classic comparison](CLASSIC.md).

Keep HEART's stdWfs handler unchanged and progressive. Use the same
`wfsSimulator` FITS corpus, packetization, rate and readout for five configurations:

| RTC | Receiver and graph execution |
| --- | --- |
| HEART | Normal progressive stdWfs path |
| Rust FGN | Complete-frame assembly and graph |
| Julia JFG | Complete-frame assembly and graph |
| Rust FGN | Row-block publication and progressive graph |
| Julia JFG | Row-block publication and progressive graph |

First qualify the developed complete-frame FGN/JFG chains against progressive
HEART with the maintained Classic SHWFS calibration. Establish numerical
agreement, clipping feedback, ordered delivery and placement before measuring
latency or qualifying the row-block variants. Record missing graph or harness
support explicitly; do not substitute a reduced algorithm chain.

For each configuration report first-packet → DM and terminal-packet → DM,
captured packet spacing, startup and warmed distributions, and exact command
delivery. Compare complete-frame versus row-block FGN/JFG directly to assess
work hidden during readout. HEART is the unchanged progressive reference;
these are not three native complete-frame execution paths. Do not use the
Copper-specific deferred HEART gate for Classic or modify HEART to add a mode.

## Follow-up SPA sender qualification

After the comparisons using `wfsSimulator` are complete, qualify the existing
sender plugin end to end using `FITS source → SPA HEART stdWfs sink → UDP → RTC`.
Replay the same input and calibration into each RTC separately, preserving the
selected receiver modes above. This is additional sender/transport evidence;
it does not replace the `wfsSimulator` baseline or change HEART's receiver mode.

Check emitted pixel payloads, frame and packet identities, byte order and
packet boundaries against the corpus and selected protocol configuration.
Measure actual packet pacing, record sender/source error and drop counters,
and require exact ordered DM delivery and numerical agreement with the
corresponding qualified `wfsSimulator` replay. Use the sink's existing
packetization and readout-time settings; do not add a second scientific RTC
implementation or report an unexecuted plugin path as qualified.

Results, hashes, failures, and any changes to this plan belong in the maintained
comparison evidence before the work is merged.

## Copper results, 2026-09-30

PipeWireAO_jll 1.7.0+18 contains the repaired core. All five glibc artifacts
were built and their products and selectors checked; the host AVX2 artifact
passed the PipeWireAO.jl binding tests. Foreign-platform execution was not
tested. The [release record](data/pipewireao_jll_ready_retry_release_20260929.json)
identifies the recipe, package, registry, and user GitHub release.

The [normal progressive series](data/copper_progressive_baseline_20260930.json)
passed all nine 1,024-frame replays: 9,216 ordered commands, correct pixel
payloads, and matching physical DM vectors. Maximum disagreement was
4.6 × 10⁻⁸ µm. Outputs peaked at 0.272 µm, below the ±0.8 µm limit; the
FGN direct-oracle comparison independently recorded zero clipped actuators.
Clipping feedback remained enabled. This normal workload does not exercise
saturation; the earlier dedicated clipping tests remain separate evidence.

The table gives ranges across three trials, including startup frames. Times
are measured from captured packets, not nominal readout duration.

| RTC | Progressive first packet → DM p50 | Progressive terminal packet → DM p50 | Progressive terminal packet → DM p99 | Prior full-frame terminal packet → DM p50 |
| --- | ---: | ---: | ---: | ---: |
| HEART | 1,286–1,304 µs | 288–310 µs | 632–665 µs | 459–471 µs |
| Rust FGN | 1,197–1,219 µs | 200–219 µs | 280–344 µs | 253–255 µs |
| Julia JFG | 1,218–1,221 µs | 218–225 µs | 313–417 µs | 244–254 µs |

The measured first-to-terminal packet gap was about 996 µs: with two packets,
the simulator sends the first before its nominal 2,000 µs readout completes.
Progressive mode reduces the measured median remaining after terminal ingress
for all three configured chains. HEART's full-frame deferred mode also adds a
producer/consumer handshake; its entire difference cannot be attributed to
overlap. See [PR-02](PROGRESSIVE_REVIEW.md#pr-02--deferred-ingress-adds-synchronization-to-the-comparison).

The [short attempts](data/copper_progressive_short_20260930.json) include a
HEART startup delivery failure, reproduced in a separate traced run. Its
prepared next-frame bucket can be selected independently of the pending frame
trigger. Successful long trials do not repair that behavior. See
[PR-01](PROGRESSIVE_REVIEW.md#pr-01--latest-prepared-bucket-can-diverge-from-the-frame-trigger).
The largest HEART terminal latency in the normal series was 2,136 µs, above
the 2,110 µs period; exact delivery is not a deadline guarantee.

## CPU profile

A separate [diagnostic replay](data/copper_progressive_cpu_profile_20260930.json)
passed delivery and numerical checks while collecting process-group counters
and cycle stacks. Julia JIT symbols were injected into the profile. The
requested observation was 1.6 seconds, beginning 250 ms after pre-ingress
placement reports. It is not a precisely frame-aligned region.

| RTC process group | Mean CPU cores | IPC | Context switches | Minor / major faults | Cycle samples |
| --- | ---: | ---: | ---: | ---: | ---: |
| HEART | 1.124 | 0.78 | 8,518 | 12 / 0 | 419 |
| FGN graph host and DM adapter | 0.161 | 2.75 | 4,717 | 0 / 0 | 72 |
| JFG graph, daemon, and DM adapter | 0.182 | 2.42 | 7,348 | 0 / 0 | 60 |

Observed HEART samples concentrate in deliberate pause loops, polling clocks,
and active `mcount` instrumentation. JFG's largest compute samples are
incremental dense reconstruction and OpenBLAS GEMV; FGN's include AVX2 AXPY
and GEMV. These small sample counts support locating costs, not precise
percentages or a SIMD-efficiency claim. No cache or TLB counters were collected.
Process-group migrations include control threads and do not show pinned loop
migration.

A separate intrusive debugger probe confirmed lazy pause calibration is called
by HEART's WFS processor while waiting for pixels. Its timing is unsuitable for
latency comparison. The original delay's full attribution remains unresolved;
see [PR-03](PROGRESSIVE_REVIEW.md#pr-03--cause-of-the-initial-processing-delay-remains-unproven).

Next measurements should separate terminal scientific execution from PipeWire
handoffs and DM adapter scheduling, and increase the profile sample population.
The present evidence does not justify changing matrix layout, page policy, or
scheduling on the assumption of a cache, TLB, or JIT defect.

### Julia work during readout

The separate [callback trace](data/copper_jfg_callback_trace_20260930.json)
records both row callbacks for all 1,024 frames. Every first callback completed
before the terminal packet arrived, by at least 428 µs and a median 889 µs.
Source inspection shows that callback stages the available upper-pupil pixels
and accumulates their 1,800 reconstructor columns. The scientific path uses
previous-frame normalization, so it does not need to wait for the other pupils
to perform this work. The `early_frames` counter belongs to the optional worker
executor and does not measure this serial path.

| Diagnostic component | p50 | p99 |
| --- | ---: | ---: |
| First row callback | 85.7 µs | 102.3 µs |
| Terminal packet → graph entry | 21.4 µs | 58.8 µs |
| Terminal row callback | 125.1 µs | 169.9 µs |
| Terminal callback exit → DM packet | 61.4 µs | 128.4 µs |

No GC pause occurred within a recorded callback. The traced DM vectors were
identical to the normal replay. Callback spans include graph bookkeeping;
scientific nodes were not timed separately. Packet/callback attribution uses
the two recorded wall/monotonic clock pairs, whose estimated offset changed
by 602 ns; the interpolation assumes continuous clocks between those pairs.
Percentiles of these separate components must not be added as an end-to-end
percentile. The remaining controller/projection work and output handoff are
concrete targets for the next profile.

## Capacity contract

Rate sweeps preserve the same graphs, data, clipping feedback, topology, and
placement. Readout must be strictly below 95% of the period, matching unchanged
`wfsSimulator` validation. Shorter readout is therefore a changed input timing
condition, not improved performance at the original detector timing.

`--collect-all-runners` retains every implementation's result when one runner
fails. The comparison still fails qualification. Failed and successful attempts
must both be reported; a finite passing rate is not a guaranteed maximum.

The initial [capacity attempts](data/copper_progressive_capacity_20260930.json)
show exact delivery and FGN/JFG numerical agreement at 1,000, 1,500, and
2,000 Hz with readout reduced to 90% of the period. HEART failed delivery in
those attempts, including two independent 1,000 Hz starts. At 3,000 Hz all
three failed delivery; FGN and JFG each lost two commands near startup while
all 2,048 correct WFS packets were captured. This brackets an observed
FGN/JFG startup-inclusive limit; it does not establish their sustained
capacity or a repeatable maximum. No startup frames are excluded to obtain a
pass.
