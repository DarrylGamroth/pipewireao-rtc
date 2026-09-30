# Independent FGN process trace review

Date: 2026-09-30. Reviewed source only and retained verification records; the
reviewer made no production edits and ran no live controller or build.

Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewire-classic-fgn-trace`.
Baseline: `a4de38e0d7257d98e5c03c51f248f84e6a822c26`.
Scope: `src/modules/module-ndarray-filter-chain.c` and
`src/tests/test-ndarray-filter-chain-feedback.c`.

## FGT-01 — metadata read before graph admission

**P2, high confidence, confirmed; corrected source reviewed.**

The first candidate called `spa_buffer_find_meta_data` before invoking the graph.
That helper traverses `buffer->metas` without checking its pointer, alignment or
bounded count. It also returns Header storage without enforcing its alignment.
The trace then dereferenced the Header. This introduced a diagnostic-only crash
or undefined access for buffers which normal graph admission rejects.

Evidence: normal `validate_buffer` in
`spa/plugins/filter-graph/filter-graph-ndarray.c:2366` checks metadata count,
pointer and alignment; its Header validation is at line 2396. The implementing
worker added the null-array regression before repair and recorded SIGSEGV
(return code −11) in `build-rtc-trace/metadata-regression-before.json`.

The corrected `fgn_process_trace_header` at module lines 180–201 checks the
metadata count limit and array pointer/alignment before traversal. It checks
Header size, pointer/alignment and duplicates before dereference. Unknown or
malformed Header metadata becomes sentinel sequence/offset; the graph is still
called, and its error is recorded. The focused test now covers null arrays,
excessive counts, misaligned arrays, null/misaligned Header storage, missing and
undersized Headers. Assertions remain enabled even in release tests through
`#undef NDEBUG` before `<assert.h>`.

No remaining source blocker was found after this correction. The reviewer
inspected `build-rtc-trace/metadata-regression-after.json`: the same focused
regressions pass with exit 0. The worker also retained successful normal and
macro-enabled O3 build/test results. Production changes are committed as
`9464907e1` in the dedicated trace worktree. This is software verification;
it does not establish timing or capacity.

## Lifecycle, storage and disabled behavior

- The fixed buffer holds 32,768 records × 32 bytes = 1 MiB. It is allocated and each
  page touched before `connect_filter`, including its last byte. Allocation
  failure follows the existing module error cleanup and releases either partial
  allocation. Prefaulting does not assert pages can never be reclaimed.
- The filter data loop is the sole trace writer. Begin uses slot `used`; end
  increments `used` only after a successful clock sample. Failed samples and
  capacity overflow increment `omitted`. No record can pass the capacity bound
  in this single-writer call sequence.
- Destruction first disconnects the filter. `filter_disconnect` destroys the
  implementation node; `node_deactivate` synchronously calls
  `pw_loop_locked(... do_node_unprepare ...)`. That removes the data-loop source
  and prevents future callbacks while serializing with current callbacks.
  Trace dump/free follows `pw_filter_destroy`, so the reader does not race the
  writer in this lifecycle. No additional atomic record fields are needed.
- Allocation, page touching, file formatting and output occur outside graph
  processing. `fclose` failures now produce a diagnostic message. Truncated
  output must still fail parser checks; a normal RTC exit alone does not validate
  the trace artifact.
- All new fields, functions, calls and trace-only includes are guarded by
  `PW_ENABLE_DIAGNOSTIC_TRACE`. Macro-disabled source adds no trace work or
  storage. The reviewer also inspected both built modules: release strings lack
  `PW_FGN_PROCESS_TRACE_DIR`/`fgn-process-`; diagnostic strings contain them.
  Macro-enabled but environment-disabled runs still execute the disabled check
  and are distinct from the normal build.

## Required report interpretation

The trace counts actual `spa_fgn_graph_process` invocations, not every module
process callback. A callback that exits early or has `ready == false` is absent.
The end/result are captured before feedback commit and output publication. A
nonnegative graph result therefore does not establish whole-cycle or wire
success. Start/end bracket the call and include instrumentation setup around
it; their difference is not isolated graph self-time.

A complete diagnostic report requires:

1. The expected invocation count and exact `(sequence, offset)` order.
2. Parsed rows equal recorded `used`, `omitted == 0`, no missing trace file,
   no sentinel identity and valid nonnegative timestamp intervals.
3. The actual saved graph maps input 0 to the intended raw row block. The reviewed
   baseline configuration has `pixel-calibration:raw` at input 0 and helpers 0.
4. Independent exact wire, science-policy and normal-exit evidence, plus binary,
   module and relevant source/configuration hashes.
5. Clear identification of the terminal receive boundary and its clock;
   only completed calls with `end_ns < terminal_observation_ns` contribute to
   completed-work lower bounds. Host timestamps are not physical NIC arrivals.

## Derived Classic science work from accepted callbacks

For fixed zero-based ROI row origins yᵢ, 22-row subapertures and 11-row packets,
let P(r) be the greatest leading subaperture prefix for which yᵢ+22 ≤ r+11 after
an **accepted** callback with row offset r. The shared Classic origins are
nondecreasing in row, so this is simply the number satisfying that inequality.
Origins SHA-256:
`8d648983755d662c98a4e66e9f6173d945a928c118153f1ca1699ebf17412279`.

| Row offset r | 0 | 11 | 33 | 55 | 77 | 99 | 121 | 143 | 165 | 187 | 209 | 231 | 253 | 275 | 297 | 319 | 341 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| P(r), completed subapertures | 0 | 4 | 12 | 22 | 34 | 48 | 62 | 78 | 94 | 110 | 126 | 140 | 154 | 166 | 176 | 184 | 188 |

Intermediate 11-row offsets repeat the preceding P value. Under the reviewed
synchronous paths below, by callback return P(r) SH measurements and 2P(r)
reconstruction columns are complete. Each column updates 221 controlled outputs;
these are not 277 padded HEART rows. The per-frame count before terminal receive
is max P(r) over qualifying completed callbacks, not a sum of cumulative counts.
It is a derived completed-work lower bound, not direct inner-kernel tracing.

### FGN: fused Rust row composition

`calculon-algorithms/src/composites/shack_hartmann_row_reconstruction.rs:413`
marks ready ROIs and measures the greatest prefix. `process_block` at line 501
uses synchronous `accumulate_reconstruction_partition`; the latter iterates the
new slope columns at line 483. In `process_block_with_reconstruction`, row
acceptance precedes measurement and reconstruction (lines 554–608), with
`processed_subapertures` advancing only after accumulation succeeds.

### JFG default: the actual split graph

The actual `ROW_GRAPH_FIXTURE` in `benchmark/run_classic_array_replay.jl` points to
`fixtures/pipewire/rtc-classic-row-feedback.conf`. Its nodes are
`shack-hartmann-measurement-block-f32` followed by
`incremental-dense-reconstructor-f32`. The earlier exploratory citation to the
fused Julia SH-row implementation was the wrong execution path and is withdrawn.

In `julia/FilterGraphAlgorithms/src/algorithms/wavefront_sensor/`:

- `shack_hartmann_measurement_block.jl:325` marks the ready prefix. Lines 393–412
  measure it and publish x/y slope values, zero-based column indices and count.
  Line 424 returns Complete for every accepted row block, including count 0.
- `incremental_dense_reconstruction.jl:280` accepts this block, then calls the
  synchronous accumulation at lines 283–288. Lines 234–252 visit each published
  column, update every candidate output and only then mark that column seen.
- `JuliaFilterGraph/src/graph.jl:934` executes each ready node and recursively
  visits downstream nodes. Workers 0 keeps this ordinary graph
  (`cpu_progressive_graph.jl:1327`). Thus the split graph's reconstruction is
  complete by the outer callback return. Helper variants replace the execution
  graph and are excluded from this inference without their own completion trace.

For both implementations, **nonnegative return alone is insufficient**: rejected
row metadata can return Deferred without science work. Require the actual fixed
graph/plan, unchanged active mask and ROI order, complete ordered 32 callbacks per
frame, valid metadata, zero trace omissions, and exact per-frame DM delivery and
science acceptance. The complete-output requirement distinguishes an accepted
contiguous frame from a silently abandoned partial frame. Parameter changes,
restarts, dropped callbacks, asynchronous helpers or sentinel identities invalidate
this derived count. Full-frame callbacks support whole-frame completion only.

These deductions do not qualify uninstrumented latency, indefinite capacity or
physical application accuracy.
