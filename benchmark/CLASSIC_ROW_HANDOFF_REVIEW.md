# Classic row handoff review

Tool provenance: the Python scripts and retired Julia launcher referenced here
were removed from the current checkout on 2026-10-08. Commands describe the
[recorded source revision](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/CLASSIC_ROW_HANDOFF_REVIEW.md);
these commands are not runnable in this checkout. Results and design claims
retain their original scope. See the [current benchmark index](README.md) for retained tooling.

Independent architectural diagnostic review, 2026-10-01. Read-only source and
offline trace analysis; no implementation changes, builds or latency runs.

## Scope and evidence

Evidence: `/tmp/rtc-classic-merged-diagnostic1000-252-20261001`, 252 offered
frames at 1,000 Hz, 32 row blocks per frame, 850 µs nominal readout. These
instrumented FGN/JFG windows lost frames and do not qualify a successful
comparison or ordinary performance. They use the developed scientific graphs.

Reviewed native runtime `167968ecfba9649b563284b39655010789e0a46b` and HEART
source plugin `10388618bbf8493612cb1d852ccc0e018faa3c87`. The diff between
`9464907` and `167968ec` is empty for `src/pipewire/ndarray-filter.c` and
`src/modules/module-ndarray-filter-chain.c`. Source-plugin main and diagnostic
worktree heads agree. Diagnostic build instrumentation remains a distinct
measurement condition.

Offline reproduction, pinned to housekeeping CPU 14:

```text
taskset -c 14 python3 /tmp/review_classic_row_handoff_20261001.py
```

Output `/tmp/classic-row-handoff-independent-20261001.json` records paired
measurements and SHA-256 hashes of the input traces and scheduler analyses.
Archive this script and output with the diagnostic evidence.

## RH-001 — Serialized row service includes downstream graph completion

**Classification:** observed behavior plus source-derived explanation; not a
confirmed implementation defect. **Priority:** high for throughput work.
**Confidence:** high for counts, ordering and code paths.

Both sources negotiated **64 buffers**. Source diagnostics report:

| Observation | FGN row | JFG row |
| --- | ---: | ---: |
| Valid received datagrams | 8,064 | 8,064 |
| Published rows / callbacks / releases | 5,952 | 5,568 |
| Delivered complete frames | 186 | 174 |
| Whole-frame reservation starvations / drops | 66 | 78 |
| Omitted source trace records | 0 | 0 |

`source.c::reserve_row_frame` reserves all 32 buffers for an admitted frame.
`publish_next_buffer` allows only one `row_inflight`; return of that exact ID
precedes the next publication. All published rows have corresponding callbacks
and release records in these traces. More than 32 negotiated buffers therefore
does not imply multiple rows being processed concurrently. More buffering can
absorb a burst but does not remove this serial service limit.

The following are medians over joined retained-row records, in µs. P is source
publication, C the scientific callback, Q source-side release processing.

| Interval | FGN row | JFG row |
| --- | ---: | ---: |
| P → C start | 2.094 | 6.462 |
| C body | 10.455 | 15.770 |
| C end → Q | 23.890 | 16.822 |
| P → Q | 34.479 | 43.872 |
| Paired `(Q − P) − C body` | 26.124 | 23.504 |
| Q → next P | 0.050 | 0.110 |
| P → next P within the same frame | 34.170 | 43.297 |

These medians are not additive. Subtracting independently reported medians does
not give the median residual. Paired mean P → Q is 42.331 / 45.230 µs, including
cold and terminal rows. The offered average budget is 1 ms / 32 = 31.25 µs per
row; readout bursts require additional transient buffering. These observations
support investigating the serial handoff, without predicting uninstrumented
capacity from a median or attributing all frame losses to one delay component.

### Downstream adapter activation

The DM adapter's native ingress trace has only 186 / 174 actual payload
callbacks, at activation numbers 32, 64, … . Its data-loop nevertheless has one
observed switch-in in **every** P → Q interval: 5,952 / 5,568. Each is after the
scientific callback ends. The scheduler-derived median intervals are:

| Interval | FGN row | JFG row |
| --- | ---: | ---: |
| C end → adapter switch-in | 3.517 | 3.857 |
| Adapter switch-in → Q | 19.752 | 12.909 |

The FGN scheduler trace has a qualification error, so its scheduler-derived
numbers above are descriptive raw evidence only; they must not be promoted to
qualified scheduler results. JFG's kernel trace qualifies, but its full-window
callback completeness and comparison gates fail because rows were dropped.

Source explanation: `impl-node.c::process_node` triggers dependents on graph
completion; this is not conditional on a newly published terminal DM payload.
`pw_impl_node_reliable_cycle_complete` and reliable return handling prevent the
source from reusing the row until graph completion. `ndarray-filter.c::process`
can wake, find no input payload and return before its application callback.
Thus a nonterminal row can incur downstream activation/completion even though
no DM payload is processed. This is additional work beyond SH/reconstruction.

**Disposition:** architectural optimization candidate. Preserve exact row
ownership, graph dependency completion, conditional publication and feedback
semantics; do not remove a required completion edge based solely on absent
payloads.

## RH-002 — Owner-thread recycling is plausible; recursive publication is unsafe

**Classification:** source-established ownership path and design constraint.
**Priority:** high for any proposed handoff change. **Confidence:** high for the
reviewed path; other embeddings need explicit verification.

SPA's local `spa/include/spa/node/node.h` specifies `port_reuse_buffer` must run
from the data thread. Generic `audiotestsrc` returns buffers to its empty list
synchronously; `v4l2-source` calls its recycle routine synchronously. A separate
eventfd is not an unconditional SPA requirement.

For the reviewed native row path:

```text
consumer finishes and publishes the returned ID
→ driver completion or driver reliable event on its data loop
→ flush_reliable_input_returns
→ pw_impl_port_reuse_row_output
→ tee_reuse_buffer
→ HEART source port_reuse_buffer
→ atomic released_ids + eventfd write
→ source release_ready on its data loop
→ Q, make buffer AVAILABLE, clear row_inflight
→ publish_next_buffer, notify_ready
```

The source's data loop is the SPA `DataLoop` support interface. Native driver
return handling is already marshalled to the driver data loop. The exercised
path therefore supports investigating owner-thread synchronous recycling.
Current atomics/eventfd also tolerate returns from a different context; retain
that behavior or formally constrain the contract rather than assuming every
external caller follows the reviewed route.

Recycling state and publishing the next row are different operations. In
`impl-port.c::pw_impl_port_reuse_row_output`, the caller clears the IO buffer ID
and `row_borrowed` **after** `spa_node_port_reuse_buffer` returns. Calling
`notify_ready` recursively from that reuse callback would encounter the old
borrowed state and incomplete return transaction. Similar activation/gate state
must be considered throughout the call stack. The existing deferred event
avoids this reentrancy.

**Disposition:** no production defect established. A safe design can recycle
on a proven owner thread while deferring publication until the host return
transaction has completed, or introduce an explicit post-return continuation.
Simply replacing the eventfd write with `release_ready` is not justified.

## RH-003 — Existing timestamps cannot isolate the source eventfd cost

**Classification:** measurement limitation. **Priority:** medium.
**Confidence:** high.

Q is recorded in `source.c::release_ready`, not at entry to
`port_reuse_buffer`. C end → Q includes output validation/publication, input
recycling, graph completion and downstream adapter activity, return propagation,
the source eventfd dispatch, ingress or other work on the source loop, and
possible scheduling interruptions. P → C also includes host activation and
projection work; FGN's graph-call boundary differs from JFG's Julia callback
boundary. The residual is not a pure transport implementation benchmark.

Q → next P is tiny once release processing executes. This does **not** reveal
how long the release event waited. Existing source traces contain no distinct
return-entry timestamp and no thread ID at that boundary.

**Required discriminating measurement:** add bounded preallocated diagnostic
records at source reuse entry, driver return transaction completion, source
release-event entry and consumer empty activation entry/exit. Record thread ID
and clock domain once per trace. Join records by frame/ordinal/generation/ID;
retain trace completeness, kernel loss and censoring checks. Compare normal
uninstrumented runs separately after any candidate change.

## Design options and required validation

1. **Keep the current contract, remove redundant owner-loop deferral where
   proven.** Separate immediate recycling from post-return publication; retain
   a cross-thread fallback and bounded retry behavior. Measure the saved portion
   before assuming it reaches 1,000 Hz.
2. **Avoid empty downstream activations.** Explore an explicit graph contract
   that completes dependencies correctly when outputs are unavailable, or
   colocate maintained DM transport adaptation so a nonterminal row does not
   require a remote empty activation. This requires protocol/topology work and
   must preserve terminal output, one-frame feedback and live updates. It is not
   permission to substitute a minimal C scientific proxy.
3. **Change publication granularity only as a separate experiment.** Batching
   rows amortizes handoff but delays progressive SH/MVM completion and changes
   the latency tradeoff. Preserve existing calibration, developed algorithms,
   sample ordering and rejection/reset behavior; quantify the tradeoff.

Any implementation needs focused ownership and liveness checks: duplicate and
stale returns, return concurrent with ingress, same/cross-loop callers, pause,
IO detach/reattach, buffer renegotiation, rejected-ready retry, partial-frame
loss/recovery, terminal-only publication, feedback and parameter adoption.
Retain exact numerical/work checks. Then use repeated matched normal replay
windows, the same source schedule and fixed placement to test throughput and
latency. Additional buffering alone cannot establish sustainable throughput.

## Qualification flags retained

- FGN: `comparison_qualified=false`, `qualified_trace=false`,
  `qualified_callbacks=false`; CPU 4 has an unmatched repeated idle entry,
  and callback count is below the complete offered window.
- JFG: `comparison_qualified=false`, `qualified_trace=true`,
  `qualified_callbacks=false`; callback completeness fails.
- HEART: `comparison_qualified=true`, `qualified_trace=true`; no comparable
  scientific callback trace is supplied (`qualified_callbacks=false`).
- Missing FGN/JFG arithmetic reports in these failed captures remain missing;
  no scientific or physical accuracy qualification is inferred.

The evidence identifies useful next measurements and design constraints. It
does not prove that eventfd, scheduling, or any single component is the sole
cause of the capacity gap, or that one change will match HEART throughput.

## RH-004 — Qualified 250 Hz readout-overlap verification

**Classification:** verified bounded experimental evidence, 2026-10-01.
**Confidence:** high within the recorded graph and clock assumptions.
**Disposition:** accepted; does not resolve RH-001–003's throughput/design
questions or change the failed 1,000 Hz qualification flags above.

The separate `/tmp/rtc-classic-merged-diagnostic250-252-20261001` campaign offers
252 frames at 250 Hz and 2,000 µs nominal readout. All three result records pass
exact delivery, selected scientific acceptance, source pacing, normal child
exit and comparison qualification. FGN and JFG scheduler analyses have
`qualified_trace=true`, `qualified_callbacks=true`, `comparison_qualified=true`
and no errors. A subsequently generated HEART 250 Hz scheduler analysis has
`qualified_trace=false` and `qualified_callbacks=false`: TID 4180437 switches
out twice without an intervening switch-in, and CPU 0 has repeated idle entries.
Its source progress trace separately has zero loss/untraced-thread counters.
These kernel-trace errors do not invalidate the source progress lower bounds,
and the HEART 1,000 Hz kernel result must not replace this failed result. This
late scheduler artifact was generated after the archive fingerprint below and
requires inclusion in the final evidence bundle.

The reviewer independently reran both `analyze_classic_row_work.py` analyses and
`analyze_classic_heart_progress.py` on CPU 14. All three output JSON objects
reproduce the saved analyses exactly. The FGN/JFG analyzer rechecks complete
ordered callbacks and wire delivery, graph/configuration and parameter identity,
zero helpers, positive flux margins, clipping classifications, command bytes,
clock anchors and source packet geometry before deriving completed prefixes.

| Completed lower bound before each stated terminal boundary | FGN | JFG | HEART |
| --- | --- | --- | --- |
| SH subapertures | 184/188 in all 252 frames | 184/188 in 251 frames; 166 in frame 0 | 184/188 in all 252 frames |
| MVM x/y pairs | 184/188 in all 252 frames | same counts as SH | 176/188 in all 252 frames |
| MVM columns | 368/376 in all 252 frames | 368 in 251 frames; 332 in frame 0 | 352/376 in all 252 frames |

FGN/JFG bounds use synchronous callback completion plus the reviewed prefix
map and the realtime/monotonic clock envelope before the captured terminal
packet. The **+10 µs sensitivity does change one JFG scientific bound**: frame
171 decreases from 184 to 176 subapertures/pairs, or 368 to 352 columns. Four
other frames lose one definitely completed callback without changing their
scientific prefix. FGN bounds do not change; JFG's overall range remains
166–184. These details are retained rather than describing every per-frame
result as insensitive to the margin.

HEART uses its native timestamp sampled after the final receive returns.
`progress − aux` counts completed previous MVM traversal iterations, not the
newly available batch. Its arithmetic interpretation is conditional on the
recorded all-active, single-worker, non-streaming, no-flux-column configuration.
HEART columns have 277 padded actuator rows versus 221 controlled rows in
FGN/JFG. The boundaries and arithmetic counts therefore support useful work
during readout; they do not give an identical per-operation speed comparison.

Independent outputs are
`/tmp/classic-row-work-{fgn,jfg,heart}-independent250-20261001.json`.
Archive `~/.cache/rtc-classic-merged-live-20261001/diagnostics.tar.zst` has SHA-256
`06bc95a03f5197bcd9de61635557ea1a29f269b77fd6b7ceeebca7197002b198` at review.
Streaming archive inspection verified byte identity for all three saved work
analyses and the earlier handoff investigation script/result. Analysis hashes:

| Analysis | SHA-256 |
| --- | --- |
| FGN | `9abc66a610302ab4406f424c24e6cf32016cdfdb100b8cf22aa8e09e9f3d6329` |
| JFG | `b51eea5b9b684d58d1e0fd789ae20f3588e247fd67c10a58de22fa38e5ede278` |
| HEART | `9162e2f3581c7fed002b272c3399caf4cd397785354261c860f1af3f1258b589` |

A same-CPU adapter placement experiment remains a separate condition with
distinct FIFO threads. It can test placement sensitivity; success would not
prove that the source eventfd alone caused the previous throughput limit.
