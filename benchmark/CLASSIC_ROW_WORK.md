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
  and C graph result exactly 0. Failed runs, missing science evidence, clipping
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
| Analyzer | `635823f075849d39f72d72babe47b5fc850859a3ba0c82c02d57aa89ef186240` |
| Result JSON | `6ffb536105f840f356d9ceb7a26ade1013657ea61adc80f16263143cdbe16e13` |

## Reproduction and coverage

```sh
taskset -c 14 python3 -m unittest discover -s benchmark -p test_analyze_classic_row_work.py
taskset -c 14 python3 benchmark/analyze_classic_row_work.py \
  ~/.cache/rtc-classic-allocation-trace63-20260930/jfg-row-100hz-r1 \
  --output ~/.cache/rtc-classic-allocation-trace63-20260930/jfg-row-100hz-r1/derived-row-work.json
```

Nine focused offline tests cover clock hulls and rounding, strict boundaries,
sensitivity, cumulative units, causality, trace corruption/omissions, helper
exclusion, active masks and exact packet parsing. The saved JFG analysis passes.
FGN parsing and count logic are covered synthetically; a real FGN science trace
must pass the same evidence gates before any FGN observation is added here.

This supports the conditional within-readout science-work part of the Classic
qualification. It does not establish pure kernel service time, whole-stack
allocation freedom, uninstrumented deadline performance, maximum sustained
capacity or physical application accuracy. JFG allocation measurements retain
their recorded callback-body scope; the C trace measures no allocations.
