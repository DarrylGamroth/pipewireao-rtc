# Classic row admission: one retained terminal buffer

Date: 2026-09-30. This report analyzes a saved, instrumented failure. No live
replay, build or production edit was performed for the analysis.

## Result and scope

**Observed:** The source negotiated 32 row buffers. At frame 1's first receive
observation, 31 frame 0 buffers had been returned on the source loop. Its one
remaining published buffer was ID 31, generation 1, ordinal 32, row offset 341.
Julia was still processing that terminal row. All 32 packets of frame 1 arrived,
but none was published by the source.

**Derived:** The source's unchanged admission rule needs 32 AVAILABLE buffers
before accepting a frame. It had 31. This accounts for the single starvation and
whole-frame drop. The shortage is established from the actual pool count and
ordered lifecycle records; it is no longer merely inferred from the default
buffer parameter.

This confirms the admission mechanism for **this diagnostic run**. It does not
establish why every component took its observed time, whether another pool size
would sustain a rate, or whether the previous uninstrumented failure had an
identical timeline. In particular, neither JIT compilation nor garbage
collection is established as the cause.

Input directory:
`~/.cache/rtc-classic-jfg-admission-trace63-250hz-20260930`.
The requested window was 63 frames at 250 Hz with 2,000 µs readout and 11-row
packets. The run and physical qualification remain **false**:

- WFS: 2,016 complete ordered packets, zero rejected packets.
- Published: 1,984 rows / 62 frames, IDs 0 and 2–62.
- Source counters: one dropped frame and one starvation.
- DM: 62 commands with frame 1 absent; all four child exits were 0.
- No command oracle acceptance is inferred for a trajectory with a missing
  frame. The diagnostic does not convert failed wire delivery into a pass.

Machine-readable evidence is
[data/classic_row_admission_20260930.json](data/classic_row_admission_20260930.json).
It includes exact integer timestamps, per-frame callback durations, original
errors, provenance, input hashes and the counterfactual pool arithmetic.

## Trace integrity and event meanings

All four native trace files have zero omissions and their parsed counts match
their headers. Source R/P/N/Q counts are 2,016/1,984/1,984/1,984. Every P has a
matching Q with the same buffer ID and generation. All 1,984 source ready calls
return 0. Native science D/G/E/R each count 1,984, and output O counts 62.
The adapter and sink each identify exactly the same 62 output frames. Julia's
1,984 callbacks have zero omissions and exact ordered frame/offset identities.
Every native G/E interval contains its corresponding Julia body interval.

| Event | Instrumented boundary |
| --- | --- |
| Source R | Timestamp immediately after successful `recv`, before parsing/admission |
| Source P | Buffer published to SPA IO |
| Source N begin/end | Around the synchronous ready notification |
| Native G/E | Before/after the Julia native process callback |
| Julia start/end | `_process_graph_buffers!` and success counter; excludes property adoption, notification and native bridge |
| Native R | Immediately before `pw_filter_queue_buffer` recycles the input |
| Source Q | Immediately before `return_buffer` changes the buffer to AVAILABLE |

Source Q and native R are observations near transfer operations, not timestamps
of the exact ownership-changing instructions. In particular, Q supplies a lower
bound on when the source marks that slot AVAILABLE. A Q completed earlier on
the same serialized source loop establishes availability before a later R.

## Frame 1 admission timeline

All times below use the same CLOCK_MONOTONIC domain and are relative to source
R(frame 1, ordinal 1), absolute time **1569170884745105 ns**. These comparisons
need no realtime/monotonic clock conversion.

| Observation | Relative time, µs |
| --- | ---: |
| Frame 0 penultimate source Q (ID 30) | −93.075 |
| Frame 0 terminal source P (ID 31) | −92.994 |
| Frame 0 terminal ready N begin / end | −92.964 / −92.033 |
| Frame 0 terminal native G | −89.047 |
| Frame 0 terminal Julia body starts | −88.957 |
| Frame 1 first source R | 0 |
| Frame 0 terminal Julia body ends | +9.878 |
| Frame 0 terminal native E | +9.988 |
| Frame 0 terminal native R | +10.189 |
| Frame 0 terminal source Q | +77.926 |

At R1 the source had returned IDs 0–30 and had published ID 31. No other frame
was reserved. Source R is followed by the frame's admission check on the same
source loop, which cannot run the later Q callback in between. The single
published slot therefore prevents obtaining the full 32-buffer reservation.

The terminal Julia body lasts 98.835 µs. The native E follows its end by 0.110 µs.
The source Q is another 67.737 µs after native R. This separates work that was
still executing at the input boundary from the subsequent delay before
source-visible return. The trace does not subdivide that latter interval into
queueing, wakeup, scheduling or precise reuse-callback service.

## Earlier first-frame delay

Frame 0 also contains a delay before its first Julia call:

| Observation, relative to source R(frame 0, ordinal 1) | Time, µs |
| --- | ---: |
| First source P | 65.363 |
| First source N begins | 958.545 |
| First source N ends | 975.236 |
| First native G | 1,057.370 |
| First Julia body starts | 1,097.355 |
| First Julia body ends | 1,131.429 |

There are 20 source receive records before the first N. In the reviewed source,
`socket_ready` drains its receive loop before calling `notify_ready`; the
observed P→N gap is **893.182 µs**. That interval occurs before Julia processing.
It includes the source's batch handling and any scheduling/preemption during
that interval; the trace does not isolate syscall or CPU service time.

The first native G→Julia-start interval is 39.985 µs. The first Julia body is
34.074 µs; the complete native G/E bracket is 74.289 µs. Attributing the entire
initial millisecond to Julia compilation would contradict this timeline.
Summed Julia body durations are 1,027.386 µs for frame 0, 811.754 µs for frame 2
and 837.950 µs for frame 3. These are diagnostic elapsed observations, not
uninstrumented execution-time bounds.

## Julia GC and warmup interpretation

All 1,984 body intervals show zero change in process-global allocation bytes,
GC pause count and total GC time. The same counters are unchanged from the
first body's start through the last body's end. Thus this trace shows neither
GC activity nor counted Julia allocation during that span. The separate
connect/run/close diagnostic records 4,670,624 allocated bytes and no GC;
that broader interval includes work outside the live callback span.

The trace's initial counter snapshot has pause count 25; the first body has 29.
Those earlier collections are outside the live body interval and do not explain
the traced admission shortage. Counter scopes must not be mixed.

The runner executes two complete array science frames and resets before node
publication. Constructor precompilation covers native callback specializations.
The owner warmup uses absent row metadata and returns before sensing, as already
recorded in `node-report.json`. That is a real coverage limitation, but this
trace does not establish a missing-compilation defect. The first native-entry
interval precedes the first body counter sample; attribution of its 39.985 µs
would require another diagnostic. No new JIT hypothesis is promoted to fact.

## PCAP clock comparison

The wrapper's integer endpoint brackets give an offset hull of
[1789232089873566176, 1789232089873567589] ns, width 1,413 ns. Conditional on the
offset remaining inside that hull, frame 1 capture precedes its source R by
8.246–9.659 µs. Frame 0 capture precedes its first source R by
145.602–147.015 µs. Frame 1 first capture is epoch 1790801260758303035 ns;
DM0 capture is epoch 1790801260758367706 ns, 64.671 µs later.

Two endpoint brackets cannot bound unseen interior clock excursions. Capture
observations are not physical NIC/sensor arrivals. These clock qualifications
do not affect the one-buffer shortage deduction, whose events share monotonic
time and whose source lifecycle is serialized.

## Bounded headroom option

The source proof is `spa/plugins/heart/source.c` at revision
`83e3c7bfdd93ceaf0e8898ba7be2ebde1bb64f4d`: `reserve_row_frame` at line 1117,
`port_reuse_buffer` at 1053, `release_ready` at 1230, and `socket_ready` at 1421.
Reservation always obtains the complete next frame and drops it if insufficient
slots are available. All outstanding slots count, whether queued or published.

For the same observed one-slot state, a total of 33 buffers would provide the
32 free slots needed at this instant. A two-extra-slot policy means **34 total
buffers**, not two complete frames:

| Total pool | Prior unavailable slots tolerated when reserving 32 | Extra pixel storage over 32 buffers |
| --- | ---: | ---: |
| 32 | 0 | 0 bytes |
| 33 | 1 | 7,744 bytes |
| 34 | 2 | 15,488 bytes |
| 64 | 32 | 247,808 bytes |

These are counterfactual admission calculations, not a prediction of a changed
run's result. Extra buffers do not add a pixel copy or sender backpressure;
they allow more bounded outstanding ownership before the existing drop policy
applies. Metadata/storage overhead is additional. Source MAX_BUFFERS is 64,
and the existing modulo scan and 64-bit release mask support counts such as 34.
The current advertised default/minimum is 32 and maximum 64; merely setting
`link.max-buffers = 64` does not request a 64-buffer allocation.

Any policy change needs explicit source/configuration review, a recorded actual
negotiated count, lifecycle/ownership tests, and new repeated exact-delivery,
science, source-pacing and deadline results. Neither 34 nor 64 is established
as a capacity solution by this failed 32-buffer diagnostic. No policy or
production code was changed here.

## Provenance and reproduction

The fresh O3 diagnostic DSO has SHA-256
`080a8e7db589fa2e191ba6319c75496684070c6035bd8756aaa88f554e0e70a6`.
The build record is `~/.cache/classic-heart-diagnostic-build-20260930.json`.
The analyzer checks its clean before/after source revision and source hash,
DSO identity, native library identity, trace completeness and cross-layer
frame/offset/ownership order. Full input hashes are in the evidence JSON.
The failed reports and raw traces remain untouched.

From the RTC repository root, reproduce the bounded offline analysis with:

```sh
taskset -c 14 python3 \
  ~/.cache/rtc-classic-jfg-admission-trace63-250hz-20260930/analyze-admission.py
```

The saved analysis script is hashed in the JSON. The analysis completed on CPU
14 in under 0.1 seconds, using only saved files. Its assertions check the
observed identities and lifecycle invariants; no production test or live
experiment is represented as having been performed by this analysis.
