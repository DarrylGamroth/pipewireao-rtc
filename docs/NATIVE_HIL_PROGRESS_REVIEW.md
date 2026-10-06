# Native HIL observer progress predicate

2026-10-06. Independent bounded read-only review of the failed
`/tmp/gui-classic-render-death-v1/result.json`, its exact sealed installed
Classic FGN observation package, and runner discard accounting. No source edit,
test, private core, build or SCI was performed.

## HIL-PROGRESS-R001 — owned-discard growth is invalid for the external AOS sink

**Severity:** high for qualification correctness (false failure).
**Confidence/classification:** confirmed by installed graph and source.
**Affected:** GUI harness `capture_process` and the existing render-stall branch.
**Disposition:** remove the owned-discard growth conjunct for these HIL graphs;
retain complete-exchange native progress and all eventual delivery gates.

The exact installed session's only command sink is `simulator-command`, with
`ownership="external"`. The graph's demanded 277-coordinate command port links
directly to that AOS command input. Runner `src/live.rs:1168` constructs
`sink_names` by excluding external sinks. Its discard observation sums only
that owned-sink map. Thus this session correctly has `discarded_by_sink={}` and
`discarded_buffers=0`; requiring growth cannot succeed even if HIL exchanges
continue. Admission and final retained snapshots both show that empty map/zero.

## Source sequence is completed causal exchange progress

The inspected installed files match their package seals:

1. `hil/simulator_owner.jl:492–495` calls `exchange_frame!`, then commits the
   returned sequence into owner state. Source-control publication reads that
   committed state; status does not advance it.
2. The installed HIL adapter `src/exchange.jl:871–915` publishes one frame,
   waits for that frame's publication and **the same sequence's command**, waits
   for its driver cycle, adopts the command and only then returns the sequence.
3. Command receipt at `exchange.jl:332–345,393–403` rejects another pending
   command, zero/stale/mismatched sequence and inconsistent timing; it copies the
   complete command before marking `command_ready`.

Consequently same-instance/same-generation increasing native source sequence
proves additional required detector-to-controller-to-AOS command exchanges for
this graph. It is not merely a frame-offer counter or observation queue metric.

## Correct predicate and evidence limit

Keep fresh successful admitted native supervisor Status, Running supervisor
lifecycle, healthy source status/error, unchanged source instance and acquisition
generation, and strictly increasing committed source sequence. The before
witness must be incomplete and running. After may still run or reach healthy
finite completion during the interval; do not add an unconditional source-running
requirement that rejects legitimate completion. Retain both observations even
when a predicate fails.

Existing `preserve_science` still requires native publication at the completed
generation/cursor, complete metrics, equal completed frames/commands/sequence
and requested total, exact retained payload hashes and consecutive records.
The six-record trajectory/reset comparison and truth equality remain required.
Removing the unrelated discard counter does not relax those delivery gates.

The failed v1 case has final source sequence38 and clean owned shutdown, but
its exact before/after observer-boundary samples were not retained. This proves
completed exchanges by final cleanup, not that the historical observer interval
passed the corrected predicate. Preserve its failure and rerun the maintained
gate after the narrow harness repair.

Exact file/report hashes and seal checks are in the
[review receipt](validation/integrated-gates-review-20261006/hil-progress-review.json).
