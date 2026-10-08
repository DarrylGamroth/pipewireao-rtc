# Classic row admission: one retained terminal buffer

Tool provenance: the Python scripts and retired Julia launcher referenced here
were removed from the current checkout on 2026-10-08. Commands describe the
[recorded source revision](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/CLASSIC_ROW_ADMISSION.md);
these commands are not runnable in this checkout. Results and design claims
retain their original scope. See the [current benchmark index](README.md) for retained tooling.

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

## Reviewed remediation and saved successful check

The source fixes are isolated in the dedicated HEART worktree
`pipewireao-spa-plugin-heart-row-admission`, branch
`codex/classic-row-admission`, based on clean `83e3c7bf`. Main and `/opt`
remain unchanged. Two separate commits implement the reviewed changes:

- `9f3c321`: after a newly published `HAVE_DATA`, leave the nonblocking socket
  receive loop and issue the existing single ready notification. The unchanged
  IN/ERR/HUP registration is level triggered, so unread packets remain eligible
  for the next callback. When an older row is in flight, receiving can still
  queue subsequent rows; this is not a global one-packet callback limit.
- `10388618`: prefer `min(64, max(8, 2 × row blocks per frame))` row buffers.
  The original one-frame minimum and maximum of 64 remain negotiable; complete
  frames still prefer 8. Validated row counts are at most 64, so doubling is at
  most 128 before clamping. Counts above 32 receive bounded partial overlap,
  rather than storage for two complete frames.

**Software verification:** The burst regression queues two row datagrams before
one socket callback and samples the receive counter inside its first ready
call. The old source observes 2 and fails; the patched source observes 1,
leaves the second datagram readable, consumes it on the next callback, and
retains the exact row IDs, bytes, terminal marker and return behavior. The
buffer regression fails on the old Classic default of 32 and passes with
64/minimum 32. Actual parameter filtering and fixation also select 32 for a
consumer capped at 32. Full-frame default 8, small row profiles, and clamped
33-/64-block profiles pass. Independent source review found no remaining
blocker. Fresh normal and diagnostic O3 builds each pass all five transport
unit tests on CPU 14; candidate source/build/header and test-log hashes are
retained in the new evidence JSON. The diagnostic unit run did not export CSV
because its requested directory had not been created; its functional tests
passed. Complete diagnostic export is verified in the live check below.

**Observed live check:** The primary agent ran the saved 63-frame JFG row check
at 250 Hz, 2,000 µs readout, workers 0 and shared matrix layout:
`~/.cache/rtc-classic-jfg-admission-fixed63-250hz-20260930`. Its actual pool is
64. WFS delivery is 2,016 exact ordered packets; source publication, native
science and Julia each identify all 2,016 rows. Sink, adapter and captured DM
commands identify frames 0–62 exactly once in order. Source rejected, dropped
and starvation counters are all zero. All four child exits are 0. Wire
arithmetic consistency, command limits, the historical 10⁻⁶ µm comparison and
retained controller feedback checks pass; the maximum command difference from
the captured reference is 4.76837158203125 × 10⁻⁷ µm. Calibration and scientific
graph/configuration hashes and coefficients match the failed diagnostic.

Every native trace has `used = parsed rows` and zero omissions. Source
R/P/N/Q each count 2,016; each P/Q/N tuple has the same buffer ID and generation.
Repeated buffer use increments generation exactly, without overlapping loans.
Native D/G/E/R each count 2,016 and output O counts 63. Every native process
interval contains its corresponding Julia body. Both before/after placement
snapshots show daemon, adapter and science loops on CPUs 0/4/2 with FIFO 83;
Julia default threads are pinned to 2/6. The source command records CPU 12.

### Notification and headroom observations

| Instrumented observation | Saved failed run | Saved successful run |
| --- | ---: | ---: |
| Actual row pool | 32 | 64 |
| First-frame P→N | 893.182 µs | 0.270 µs |
| Frame 0 receives before first N | 20 | 1 |
| Published rows / DM commands | 1,984 / 62 | 2,016 / 63 |
| Dropped frames / starvations | 1 / 1 | 0 / 0 |

Across all 63 successful first-row publications, P→N is median 0.060 µs,
nearest-rank p95 0.130 µs and maximum 0.270 µs. Across all 2,016 rows, it is
median 0.060 µs, p95 0.110 µs and maximum 1.172 µs. Per-frame values are retained
in [data/classic_row_admission_fixed_20260930.json](data/classic_row_admission_fixed_20260930.json).
These are same-host monotonic observation intervals around instrumented code;
they include scheduling and are not a normal latency baseline.

From complete ordered prior-frame receives and serialized source Q records,
at least 63 buffers are AVAILABLE before each new frame reservation in this
successful check. This accounts for queued rows as well as published rows:
`available = 64 − (32 × prior frames − prior source returns)`. The reservation
instruction itself is not timestamped. This check demonstrates sufficient
headroom for its observed ownership timeline; it does not establish sustained
capacity or guarantee a rate under different scheduling.

All 2,016 Julia body intervals show zero change in process-global allocation
bytes, GC pause count and total GC time. Those counters are also unchanged
from the first body start to the last body end. This excludes counted Julia
allocation/GC in that span, not native allocation or startup/property/close
work. Both fixes were present together in this live check: the isolated unit
tests distinguish their software behaviors, while this check verifies their
combined delivery and arithmetic result. Repeated normal runs remain the
separate performance evidence.

### Candidate provenance and reproduction

The successful source DSO has SHA-256
`f30d9e6d8dedde4f5ea473b86b5498dd8dcb38c662fba5455a83ca686cbce93e`.
The frozen normal candidate has SHA-256
`efaf3a810284a6a39b9c84fb433cf9669a638da14b41cd528b8a18cc593ce7d6`.
Build commands, compiler flags, installed header hashes, source hashes, isolated
fail-before/pass-after logs, private core/module identities and saved run inputs
are retained in the new JSON. The original failed JSON and raw artifacts remain
unchanged.

From the RTC repository root, reproduce this read-only analysis with:

```sh
taskset -c 14 python3 \
  ~/.cache/rtc-classic-jfg-admission-fixed63-250hz-20260930/analyze-admission-fixed.py
```

The saved script and its input helper are hashed in the evidence JSON. The
recorded campaign-source hash matches commit `82c80663`; a later timestamp
validation commit changed the current file. Both hashes and that historical
match are retained. The wrapper and live-runner hashes still match their
recorded sources. The analysis checks delivery, identities, buffer generations, interval ordering,
source/library/calibration provenance, placement snapshots, arithmetic gates,
process exits and GC counters. It uses only saved files and makes no new live,
normal-latency, capacity or physical-accuracy claim.
