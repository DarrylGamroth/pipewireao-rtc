# Classic terminal projection comparison

## Scope

This increment profiles the Julia terminal science body under the matched zero
CPU latency request established in [the platform investigation](CLASSIC_PLATFORM.md).
It changes the CPU implementation of existing identity and unit-selection
projections in FilterGraphAlgorithms. The graph, fixtures, controller, ordinary
dense extrapolation, clipping feedback, source, transport and thread placement
remain unchanged. The [algorithm design and independent review](https://github.com/DarrylGamroth/JuliaFilterGraph.jl/blob/d0ce2296a22773d6e2f7a0f1a61da471508d2933/docs/classic-cpu-projections.md)
explain the execution policies and numerical constraints.

This is a finite software replay on the Ryzen 6800H development host. It is not
physical DM qualification, a maximum-rate study or a hard real-time bound.
HEART and FGN are unchanged; their earlier matched measurements remain in the
platform investigation. This campaign tests the before/after Julia change.

## Method

`run_classic_projection_comparison.py` selects two explicit Julia source roots
and forwards them through the existing live runner. The baseline is
`6f1da393f9bd7153ed95b8811ccf32ebce6342a6`. Candidate sources and the modified
harness are archived with hashes. The validated change is committed as
`d0ce2296a22773d6e2f7a0f1a61da471508d2933`; measurement-time source
revisions and dirty diffs remain distinct from this promotion commit. Both ignored benchmark manifests are retained
and identical. Julia is 1.12.7, OpenBLAS uses one thread, row workers are disabled,
and matrix layout is shared.

Each normal window sends 1,029 frames, with continued controller state and the
same seven-image corpus repeated 147 times. Unchanged wfsSimulator sends 32
11-row packets for each 352×352 image at nominal 2 ms readout, at 100 or 250 Hz.
Every receiver window must pass exact ordered WFS/DM delivery, arithmetic
acceptance, functional checks, source rate within 1%, normal child exit and empty
owned process group. The session-owned zero CPU latency request is verified and
released after capture; no persistent power policy is changed.

Placement remains: source CPU 12; PipeWire loop CPU 0/FIFO 83; Julia science
CPU 2/FIFO 83; adapter CPU 4/FIFO 83; Julia auxiliary thread CPU 6; orchestrator
CPU 14. These cores are not isolated from the rest of the host. Memory locking
remains disabled. Raw captures, placement, power-policy snapshots, readout and
source-period distributions are retained per window.

The first campaign has three repetitions per rate/variant. Its rate ordering
alternates, but a harness bug leaves baseline first at 100 Hz and candidate first
at 250 Hz in all three repetitions. Additional reversed-pair windows check the
opposite order. The corrected case generator preserves original rate indices
when reversing rate order. The retained original campaign is not retrospectively
labelled fully counterbalanced.

The latency endpoints are captured WFS packets and captured UDP DM commands.
The headline table excludes each window's first 100 frames and reports ranges
of individual window percentiles, without pooling or confidence-interval claims.
All-frame distributions, including startup maxima, remain in the compact evidence.
Arithmetic acceptance preserves the historical strict-tolerance failure and
application-accuracy limitation. Passing source-derived floating-point bounds
is not a new scientific accuracy budget.

## Observed live results

All 16 windows passed: 526,848 WFS packets and 16,464 ordered DM commands,
with no observed frame-period deadline misses. All 13 parameter-file hashes
match across windows. Every captured DM command stream has the same SHA-256,
`a0151ae2e240a9533a2e856a875bdd65d10f5372d0080b49ee828c6c2d53467d`.
There are zero observed clipping classification disagreements. This byte
identity applies to this corpus and the captured command boundary; it does
not establish general bitwise projection equivalence or physical accuracy.

Terminal captured WFS packet → captured UDP DM command, µs. Each range covers
four separate window percentiles (three original plus one opposite-order):

| Rate | Baseline p50 | Candidate p50 | Baseline p99 | Candidate p99 |
| --- | ---: | ---: | ---: | ---: |
| 100 Hz | 81.7–83.5 | 62.2–63.8 | 116.7–166.8 | 71.1–102.8 |
| 250 Hz | 80.8–84.7 | 61.3–62.7 | 98.5–125.6 | 67.6–93.5 |

Pairwise p50 savings are approximately 18–23 µs. Every matched pair also has a
lower candidate p99, including both opposite-order checks. This observation is
not a claim that all future tail quantiles improve or that pair order is irrelevant.

First captured WFS packet → captured UDP DM command p50 ranges improve from
2,016.9–2,019.1 to 1,997.8–1,999.6 µs at 100 Hz and from 2,016.6–2,020.7 to
1,997.4–1,998.8 µs at 250 Hz. The observed readout interval is approximately
1,936 µs, because the last of 32 packets precedes the nominal 2 ms endpoint.
The readout work and transport are unchanged; this change reduces terminal
science work after the last row.

The [compact evidence](data/classic_projections_20260930.json) preserves both
campaigns separately, all-frame distributions, per-window gates, numerical
bounds and historical failures. The two local manifests are
`~/.cache/rtc-classic-projection-live-20260930/manifest.json` and
`~/.cache/rtc-classic-projection-live-reversed-20260930/manifest.json`;
their hashes are retained in that evidence. Raw captures and source archives
remain in those directories. The session-owned request reads zero during each
window and returns to 2,000,000,000 µs after release. Every owned process group
is empty on completion.

For context, the earlier matched campaign measured FGN terminal p50 at about
62–64 µs and HEART at 84–86 µs. The new Julia medians are in the earlier FGN
range and below the earlier HEART range. These are comparisons with prior
windows, not a newly interleaved three-RTC campaign. HEART and FGN were not
rerun or modified in this increment.

## Verification and cleanup

The final 219 Classic Python tests pass, including explicit source-root
forwarding and corrected pair ordering. The algorithm repository's complete
CPU suites pass 11,656 assertions; its projection Graph transaction tests and
concrete inference/LLVM checks also pass. The independent review verifies the
retained manifests, hashes, tables and claim limits. The final diff passes
whitespace checks. No PipeWire, HEART or FGN production source changed.

Completed per-window Julia compilation caches were removed after checking all
16 owned process groups absent, recovering 433,223,720 bytes (about 413 MiB).
Sources, manifests, installed/private libraries and captured evidence remain.
The cleanup manifest is
`~/.cache/classic-projection-completed-cache-cleanup-20260930.json`. Raw CPU
profiles were compressed only after verifying round-trip content and preserving
original/archive hashes. No cleanup occurred during a timed capture window.
