# Classic completed row-work lower bounds

Date: 2026-09-30. This is offline analysis of saved functional diagnostics.
The result is **derived**, conditional on the reviewed synchronous graph and
clock model. Individual SH or MVM kernel completion times are not observed.

## Method and acceptance

`analyze_classic_row_work.py` combines the raw callback CSV, WFS packet capture,
run and node reports, exact graph configuration, fixture, arithmetic acceptance
and command bytes. It requires:

- Complete, ordered frames: 32 WFS packets and 32 graph calls per frame, offsets
  0, 11, …, 341; no duplicate, missing, sentinel or rearranged identities.
- Zero trace omissions, consistent CSV/report counts, serial valid timestamps,
  and C graph results containing only documented success flags (0 or 1).
  `SPA_FGN_PROCESS_RESULT_PROPS_CHANGED = 1` reports changed properties;
  it does not establish an output or indicate failure. Failed runs, missing
  science evidence, clipping
  disagreement and abnormal child exits cannot supply a count.
- The reviewed 352 × 352 detector, 188 active subapertures of 22 × 22 pixels,
  unchanged ascending ROI order and 221 controlled output coordinates.
  Fixture hashes must agree with both runner and arithmetic evidence. JFG node
  parameter/profile hashes must agree with the runner as well.
- The exact authored and adapted JFG split graph with workers 0, or the exact
  generated/deployed FGN fused graph with helpers 0. FGN generator and template
  hashes are retained. Alternate graphs and asynchronous helper variants fail.
- One C process trace, with the module and client library identities matching
  the diagnostic wrapper and run provenance. JFG uses its callback report.
- Positive finite flux margin and successful source-arithmetic acceptance;
  the original strict numerical comparison remains in the output unchanged.

Packet epochs are read as Decimal values and converted to exact integer
nanoseconds. `classic_wire.open_evidence` supports retained plain, zstd, xz or
gzip packet artifacts and propagates archive errors. No missing artifact is a
passing observation. Every input file consumed by the analysis is hashed.

These checks establish a consistent retained evidence chain. They do not
cryptographically attest that running machine code came from the reviewed
source, or exclude an unrecorded runtime parameter mutation. The source-to-run
provenance and absence of such mutations remain conditions of the deduction.

## Count and units

For zero-based packet row offset r and subaperture row origins yᵢ:

```text
P(r) = number of ordered subapertures satisfying yᵢ + 22 ≤ r + 11
completed SH subapertures ≥ max P(r) over definitely completed calls
completed x/y gradient values ≥ 2 × max P(r)
completed MVM matrix columns ≥ 2 × max P(r)
```

Each counted matrix column has updated all 221 controlled output coordinates.
Column 2i is x and column 2i+1 is y for zero-based subaperture i. One completed
x/y pair therefore means two columns, not two subapertures. The algorithm's
221 controlled coordinates differ from HEART's 277 padded output rows.
Counts are cumulative prefixes: summing P over calls would double-count work.
A zero lower bound means no completed science work is established by these
observations; it does not establish that no such work occurred.

The complete prefix table and source walkthrough are in
[the independent C trace review](CLASSIC_FGN_TRACE_REVIEW.md).

### FGN source path

The graph's `shwfs-row-reconstructor-f32` uses Rust's fused
`shack_hartmann_row_reconstruction.rs`. `measure_ready_prefix` measures ready
ROIs; `process_block` invokes synchronous
`accumulate_reconstruction_partition`, which visits each new slope column and
updates the 221 reconstruction coordinates before advancing the processed
prefix. Helpers 0 selects this synchronous path. The C end timestamp follows
`spa_fgn_graph_process` and precedes feedback commit and output publication.

### JFG source path

The actual fixture is `fixtures/pipewire/rtc-classic-row-feedback.conf`, selected
by `benchmark/run_classic_array_replay.jl`. It contains
`shack-hartmann-measurement-block-f32` followed by
`incremental-dense-reconstructor-f32`. This is the **split** implementation;
an earlier exploratory citation to the fused Julia implementation was incorrect
and has been withdrawn.

`shack_hartmann_measurement_block.jl:322` finds the ready prefix. Its accepted
row processing publishes x/y measurements, column indices and count and returns
Complete even when count is zero. `incremental_dense_reconstruction.jl:224`
visits every published column; its call from line 282 runs synchronously.
`JuliaFilterGraph/src/graph.jl:934` executes ready nodes and visits downstream
nodes before returning. Workers 0 preserves this ordinary graph. Thus an
accepted row callback's completion implies completion of the same SH/MVM prefix.

Both implementations may return Deferred after rejecting row metadata. A normal
return alone is insufficient. The fixed graph, complete ordered stream and
exact per-frame output/science evidence are necessary to establish accepted
contiguous frames for this deduction.

Reviewed algorithm source SHA-256 values (under the sibling worktrees
`calculon-algorithms-main-copper` and `JuliaFilterGraph-progressive-requal`):

| Source | SHA-256 |
| --- | --- |
| Rust `crates/calculon-algorithms/src/composites/shack_hartmann_row_reconstruction.rs` | `5066328becce34a610c0f2088f7be7933dff8cca07a2ec80f66cb4407719b30f` |
| Julia `julia/FilterGraphAlgorithms/src/algorithms/wavefront_sensor/shack_hartmann_measurement_block.jl` | `de2ddf08d9802ce0ca41400a057fdaf536f0dba9500f078a718f1c1092d28284` |
| Julia `julia/FilterGraphAlgorithms/src/algorithms/wavefront_sensor/incremental_dense_reconstruction.jl` | `b71465ce511a7be5da0df9ef288d2ca31d6464bec7bbcd2031721cffececf96b` |

## Clock model and sensitivity

Each endpoint samples monotonic-before, realtime, monotonic-after. If the
realtime sample is R and the monotonic bracket is [B,A], its offset interval is
[R−A, R−B]. The analyzer takes the hull of both endpoint intervals. For JFG,
Float64 seconds and the subsequent ×10⁹ conversion introduce a conservative
248 ns rounding allowance at these recorded epochs. C brackets use integer
nanoseconds. A configurable additional margin expands both interval ends.

A callback contributes only if `end_ns + maximum_offset < terminal_packet_ns`.
Equality is excluded. Callback intervals must lie between endpoint brackets;
a call provably preceding its own input packet is rejected. The report also
computes a sensitivity result with another 10,000 ns added to the margin.

**Load-bearing assumption:** realtime-minus-monotonic stays within this hull
throughout the replay. Two endpoint samples cannot establish a bound on unseen
interior clock excursions. The extra 10 µs is sensitivity analysis, not a
measured clock bound. The terminal event is a local packet-capture timestamp,
not physical sensor or NIC arrival. Counts close to this boundary must be
interpreted with those limitations.

## Saved JFG result

Input directory:
`~/.cache/rtc-classic-allocation-trace63-20260930/jfg-row-100hz-r1`.
All 63 frames were included, with no warmup or first-frame exclusion.

| Clock margin beyond endpoint/rounding hull | Frames with positive lower bound | SH subaperture lower-bound range | MVM column lower-bound range |
| --- | --- | --- | --- |
| 0 ns | 63 / 63 | 4–184 | 8–368 |
| 10,000 ns | 63 / 63 | 4–184 | 8–368 |

The default offset hull is [1789232089873565329, 1789232089873566642] ns,
width 1,313 ns. Frame 0 establishes four SH subapertures and eight MVM columns
before the terminal capture observation. The JSON retains every frame's counts;
these ranges do not imply identical bounds for every frame.

Output: `derived-row-work.json` in the same directory.

| Artifact | SHA-256 |
| --- | --- |
| Callback trace | `17c402ef654b13ec31dc355fef73538d0a21bdab44b3b5226bb9166eedb9e0dd` |
| Node report | `2b2bf2a86a80b4dfab6f4e264807f0881b9a1f338d6aef1d1291aeab857a507c` |
| Analyzer | `530e41fb2365c79cb0d9c32333952b4093ce2dd562998aaef040e0c0070cbd88` |
| Result JSON | `11af00ae355ab59e21f5c03dd5358dcd454de6eebd0a419820d7fb6d985fa152` |

## Saved FGN result

Input directory: `~/.cache/rtc-classic-fgn-graph-trace63-20260930`.
All 63 frames and 2,016 graph calls were included. The complete packet/output
and science checks passed, with all child exits 0. The macro-enabled private
module from trace commit `9464907e1` records actual FGN graph processing;
the earlier ingress-only trace observed the DM adapter and is not used here.

| Clock margin beyond endpoint hull | Frames with positive lower bound | SH subaperture lower-bound range | MVM column lower-bound range |
| --- | --- | --- | --- |
| 0 ns | 58 / 63 | 0–184 | 0–368 |
| 10,000 ns | 58 / 63 | 0–184 | 0–368 |

Frames 8, 11, 17, 35 and 62 have zero completed-work lower bounds. This does
not establish absence of early science work. Frame 0 establishes 12 SH
subapertures and 24 MVM columns. The added 10 µs reduces individual SH bounds
for frames 3 (78→62), 31 (110→94), 36 (166→154), 53 (154→140) and 61
(176→166); unchanged aggregate ranges do not mean unchanged per-frame evidence.
The default offset hull is [1789232089873566036, 1789232089873567248] ns,
width 1,212 ns.

The first parser required result 0. Inspection of the public declaration
`spa/include/spa/filter-graph/filter-graph-ndarray.h:223` established that both
0 (NONE) and 1 (PROPS_CHANGED) are success flags. The parser now accepts both,
with explicit success-flag and unknown-flag tests. Deferred output is represented
by size zero, not a distinct graph-process return value; all stream, configuration
and per-frame output gates remain necessary.

Output: `derived-row-work.json` in the FGN input directory.

| Artifact | SHA-256 |
| --- | --- |
| `native-ingress-trace/fgn-process-3503653-0.csv` | `b455befbf6bc8e7d880343751f612866b6ed7006dcf45e868b9e6061133ad322` |
| Private graph module | `29da924ba2b0303d778cb5d4f0bb6c962b29052a02466b1a027111866d302bf4` |
| Private PipeWire client library | `194fbdba311b7fd92854e86d4ff7ccc242bf48c6d8054b4f8a4a9f341de1c148` |
| Result JSON | `fce04f947ab5fd09f68c71a04d909dbe39e327cd8fc6a80823cfaed39e44c6dd` |

## Reproduction and coverage

```sh
taskset -c 14 python3 -m unittest discover -s benchmark -p test_analyze_classic_row_work.py
taskset -c 14 python3 benchmark/analyze_classic_row_work.py \
  ~/.cache/rtc-classic-allocation-trace63-20260930/jfg-row-100hz-r1 \
  --output ~/.cache/rtc-classic-allocation-trace63-20260930/jfg-row-100hz-r1/derived-row-work.json
```

The same command accepts the FGN input directory above and writes its output
there; no live process is started by this analyzer.

Nine focused offline tests cover clock hulls and rounding, strict boundaries,
sensitivity, cumulative units, causality, trace corruption/omissions, helper
exclusion, active masks and exact packet parsing. Both saved JFG and FGN analyses pass the evidence gates. The FGN result
demonstrates positive within-readout bounds in 58 frames, not all 63.

This supports the conditional within-readout science-work part of the Classic
qualification. It does not establish pure kernel service time, whole-stack
allocation freedom, uninstrumented deadline performance, maximum sustained
capacity or physical application accuracy. JFG allocation measurements retain
their recorded callback-body scope; the C trace measures no allocations.

## Saved JFG result with the reviewed source fixes at 250 Hz

Input directory:
`~/.cache/rtc-classic-jfg-admission-fixed63-250hz-20260930`.
This successful diagnostic uses the reviewed early source notification and
64-buffer preference from HEART commits `9f3c321` and `10388618`, with the same
calibrations and split JFG science. Source pacing is 250 Hz with 2,000 µs readout,
11-row packets, workers 0 and shared matrix layout. All 63 frames and 2,016
callbacks are included, with no first-frame or warmup exclusion. Complete
ordered WFS/DM delivery, arithmetic consistency, command limits, retained
controller feedback and all four normal exits pass, as recorded in
[the admission remediation evidence](CLASSIC_ROW_ADMISSION.md#reviewed-remediation-and-saved-successful-check).

The authored split graph hash remains
`e5d8ae5f9dec86089f704b120b84343334dd5ae079465e79570c50821ea55425`.
Its exact reviewed output-boundary adaptation has hash
`7f07395864f508fb405a64cfed67f7a16f40332a39d4cdee39e0dbd5d2a4c458`.
The analyzer verifies that adaptation, worker count 0, complete ordered
identities, calibration/profile hashes, science evidence, trace completeness
and clock causality. Recomputing the entire analyzer result reproduces the
saved JSON exactly. A separate compact check recomputes the ROI prefix and
strict `callback end + maximum offset < terminal capture` comparison from the
raw callback and packet files.

| Additional clock margin | Positive frames | SH subapertures: min / median / max | MVM matrix columns: min / median / max |
| --- | --- | --- | --- |
| 0 ns | 63 / 63 | 4 / 166 / 184 | 8 / 332 / 368 |
| 10,000 ns | 63 / 63 | 4 / 166 / 184 | 8 / 332 / 368 |

These are **derived cumulative lower bounds** on completed work before each
frame's terminal local capture observation. The full scientific frame has 188
SH subapertures and 376 x/y matrix columns. Each counted column updates all 221
controlled output coordinates. Callback counts are not themselves counts of
subapertures or columns, and individual SH/MVM kernels are not timestamped.

The default clock-offset hull is
[1789232089873565251, 1789232089873566999] ns, width 1,748 ns, including the
248 ns Float64 rounding margin at each endpoint. The extra 10 µs expands this
hull by 10,000 ns at both ends. Positive bounds still hold in all 63 frames,
including frame 0's four SH subapertures and eight columns. The added margin
reduces SH bounds for frames 21, 48 and 61 from 154 to 140, and frame 33 from
184 to 176; unchanged summary ranges and medians do not imply unchanged
per-frame evidence.

The endpoint-hull assumption and local-capture limitations above remain
load bearing. This run includes process-global Julia allocation/GC counter
reads and macro-enabled native diagnostics. Its derived completed-work counts
qualify this instrumented observation. They do not establish direct kernel
service times, a normal latency baseline, sustained capacity, or the isolated
performance effect of either source fix. The earlier saved-source results
above remain unchanged.

The exact saved result is retained as
[data/classic_row_work_fixed250_20260930.json](data/classic_row_work_fixed250_20260930.json).
Its SHA-256 is
`f85a910862c71756de05c348d064215fd3ab5596b16684205012c7b50c13e3f6`.
It includes all per-frame bounds, both clock models, graph and input hashes,
arithmetic evidence and scope limitations. The compact review script is
`review-row-work.py` in the input directory, SHA-256
`1c2d9cbf1e876ba23d45594ac84c75a24433f9cb704f588681b941f5b9796fba`;
its output is `row-work-review-summary.json` there. The read-only computation
ran on CPU 14 in under 0.1 seconds, without builds or live replay.
