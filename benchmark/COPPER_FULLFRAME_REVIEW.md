# Copper complete-frame delivery and live control review

Date: 2026-09-29. Scope: the matched CPU Copper chain, HEART Standard-WFS
input, and FGN/JFG complete-frame delivery. Progressive qualification remains
separate. Source traces and observer receipts use CLOCK_MONOTONIC; packet-to-DM
comparison uses its existing wire measurement boundary.

## Revisions and evidence

- HEART SPA source repair: `09290d5`, merged to plugin main. Installed normal
  release DSO: `b2448d9c715a79b9c0a39c7c3b637083c7c07683252fb1f8f02707ba906a2a6e`.
- RTC callback-serving waits: `86f5b8e`; bounded reader preparation and shared
  parameter payloads: `3b6a88e`, on `rtc-copper-all-loops`.
- JFG scalar preparation: `1a6ea5a`; GC-safe script monitor waits: `bdf3eba`,
  on `rtc-copper-all-client-loops`. Runtime parameter signature preparation:
  `2750a5b`; standalone prepared bootstrap: `5c034d9`.
  The first GC-safe replay records dirty
  `1a6ea5a`; its island script hash matches the subsequently committed repair.
- Scientific calibration, input, and executable hashes are retained in each
  run report. Historical benchmark reports retain their dirty worktree status.
  Repairs are now merged; the integration documents retain subsequent evidence.
  HEART wfsSimulator is unchanged.
- [Three-way delivery evidence](data/copper_fullframe_borrowed_delivery_20260929.json)
  and [live-update evidence](data/copper_live_update_delivery_20260929.json)
  preserve successful and failed reports.

## Findings

### CF-01 — Premature source-buffer recycling

Severity: high. Confidence: confirmed. Disposition: repaired and integrated.

The previous source recycled a published complete-frame buffer on an IO-status
transition without its exact return. Subsequent cycles could overwrite pending
handoffs. The final input also lacked a retry activation at end of source.
The source now uses the existing bounded loan lifetime and cycle gate for
complete frames, with exact buffer-ID return and eventfd retry/reattachment.
No frame-progress metadata or new PipeWire scheduler is introduced. UDP
reception continues during overload, with explicit whole-frame drop counters.

Validation: fail-before/pass-after source regressions, five plugin tests in
normal and trace builds, and ordered three-way 1,024-frame replays including
last-frame delivery. The installed normal plugin also passes all five tests
and a three-way replay. This does not promise delivery under unbounded overload.

### CF-02 — Reliable command fanout changes broadcast semantics

Severity: high. Confidence: confirmed. Disposition: comparison topology fixed.

Reliable tee dispatch chooses an available downstream consumer. A demanded
output linked both to an observer and a command adapter is therefore unsuitable
for the reliable measured command path. The complete-frame comparison uses
one command chain through the adapter to the DM sink. Adapter Header sequences
and DM wire vectors establish alignment; no unavailable observer vectors or
observer-boundary latency are invented.

Validation: exact ordered wire commands and numerical comparison for all three
RTCs on the same FITS cube and calibration.

### CF-03 — Idle/control waits blocked the PipeWire owner loop

Severity: high. Confidence: confirmed. Disposition: repaired.

The RTC runtime Parameter source processes on its owner main loop. A 100 ms
stdin receive wait blocked that loop, causing a failed native run with 53
published frames and 971 explicit drops. Replacing it with a PipeWire channel
and owner-loop iteration restored 1,024 frames. Subsequent property adoption
polls slept for 5 ms on that same owner, matching measured source loan holds.
All ten adapter waits now service callbacks and preserve wall-clock retry
budgets. Quiescence requires complete 5 ms observation intervals.

Validation: callback-progress, command wake/order, monitoring-fairness, and
nested-iteration tests; Rust tests, formatting, Clippy; same-case native and
JFG full-frame replay. Independent review checked ownership and acknowledgment
predicates. Existing core roundtrip calls are not independently time-bounded.

### CF-04 — Reconstructor file loading and clones occupy the owner thread

Severity: high. Confidence: confirmed mechanism; earlier 17 ms event attribution
remains unresolved. Disposition: repaired in `3b6a88e`; repeated candidate
and installed integration evidence now passes for both controllers.

The command path read a 3.64 MB file on the owner thread, cloned its bytes for
lifecycle emission, then cloned them into publisher pending state. The runtime
Parameter stream is an active graph target whose process callback runs on
that owner loop. In the retained switch capture, the RTC owner ran for 5.80 ms
while the JFG data loop slept; source frame 253 was borrowed for 5.37 ms.
GC counters remained constant throughout ingress. This establishes an owner
occupancy mechanism, but does not apportion file loading versus each clone.

The repair prepares file-backed values on the existing stdin reader. One
`Arc<Vec<u8>>` owns the payload and is shared through lifecycle and publisher
handoffs without deep byte clones. A session-owned capacity-one acknowledgment
lets the reader prepare at most one parameter awaiting dispatch. The reader
waits until serialized owner dispatch completes; owner signaling never blocks,
and session exit releases the reader even with an undrained PipeWire channel.
Per-publisher pending slots retain their existing bound. Lifecycle dispatch and
callback-visible Rc state remain on the owner thread.

Validation: allocation identity through emitted, pending, and cloned effects;
publisher allocation identity; delayed-reader callback and monitoring progress;
command order, errors, exit with an undrained native queue, and a 32-command
flood. All 64 Rust tests passed, one maintained private-core integration test
was ignored, and formatting/Clippy checks passed. Independent review found no
outstanding confirmed defect. The final native path then passed three fresh-process 1,024-frame live-update
replays with zero source drops/starvations. All five outputs (mean, correction,
controller state, constraint feedback, demanded) compared bitwise equal to the
independent reference; delivery, numerical comparison, and the separate timing
flag passed in every run. Diagnostic maxima were 703.537, 1,023.756, and
867.384 µs, each below the 2,109.705 µs frame period with zero over-period
sequences. This establishes the retained native repetition result. At this
review stage Julia continuity remained open: its first combined GC-safe pass
was followed by failed replays described in CF-06. CF-10 below records the
later ready-retry repair and six passing candidate replays.

The mapped SPA buffer copy remains required by transport ownership. The last
payload deallocation can still occur on the owner thread. Neither residual
cost is assumed negligible; the connected timing report measures the combined
path, without apportioning those costs.

### CF-05 — First scalar transaction compiled after publication

Severity: medium. Confidence: observed delay and cold methods confirmed.
Disposition: startup preparation repaired in `1a6ea5a`; repeated candidate
and installed live-update checks passed after the CF-10 transport repair.

The initial Julia scalar acknowledgment took about 850 ms while frames
continued. Explicit native/property callback precompilation reduced this to
about 100 ms. Compiler tracing also identified approximately 48 ms of dynamic
property preparation. Tuple assignment length was part of its specialization,
so warming one subset would not cover arbitrary valid subsets.

An additive vector preparation API preserves existing tuple semantics. The
executor prepares a dry transaction using current declared runtime values
through owned SPA Pod serialization/parsing before connecting the node. It
discards the candidate without staging, reset, adoption, or generation writes.
The same vector type serves every supported subset/order.

Validation: scalar contract, mixed types, duplicate/unknown/type/update-class/
constraint errors, current-value preparation and unchanged state/generations;
complete FilterGraphPipeWire tests including zero-allocation assertions.
Independent review found no confirmed semantic defect. The first combined
GC-safe replay observed scalar acknowledgment after 50.55 ms, with singleton
`property_change_at=506` and no source loss or frame-period timing exceedance.
Acknowledgment polling time is separate from the per-frame adoption boundary;
this is not a 50.55 ms graph-processing latency measurement. Later repeated
candidate and installed checks are retained under CF-10.

### CF-06 — GC-unsafe monitor sleep amplifies safepoint wait

Severity: high for the confirmed amplifier. Confidence: confirmed by focused
microprobe; attribution of original intermittent frame loss remains unresolved.
Disposition: monitor wait repaired in `bdf3eba`; initial combined repeats had
mixed outcomes. Later CF-10 candidate repetitions and installed checks passed;
the individual historical loss mechanisms remain separately adjudicated.

The script monitor and gate waits called `Base.Libc.systemsleep`, whose native
sleep does not release Julia's GC participation. The focused
[GC-safe wait probe](../../JuliaFilterGraph.jl/benchmark/results/julia-gc-safe-script-wait-2026-09-29.json)
used Julia 1.12.7 with two default threads and no interactive threads. A worker
slept for 10 ms while the main thread requested `GC.gc(false)` 1 ms after the
worker signaled. After two warmup samples per implementation, five retained
samples gave median time to safepoint of 9.412921 ms with the old sleep versus
24.456 µs with `@ccall gc_safe=true usleep`. This confirms a safepoint delay
amplifier. The shared helper now serves the script monitor/gate call sites;
scientific algorithms, parameters, process-loop behavior, and GC policy are
unchanged by this wait repair. Its forced collection is confined to the probe;
production GC remains enabled. The later unpublished startup collection is
recorded separately in CF-08. Independent review found no confirmed defect.

A historical Julia replay dropped five frames during matrix replacement with
a 17.1 ms source loan hold. Startup-inclusive GC logs cannot locate a collection
within ingress. Two subsequent callback-counter captures showed no GC during
ingress, including update-associated overruns. The reader/shared-payload
candidate and its bounded successor each then dropped three early frames,
respectively 38–40 and 39–41, before either update. These failures remain in the
evidence ledger. The confirmed sleep amplifier does not establish that GC
caused any particular historical frame loss.

The first same-case replay with all committed repairs delivered 1,024 frames
at 474 Hz with zero source drops/starvations, ordered demanded observations,
and independent numerical comparison within unchanged tolerance. Diagnostic
source-terminal-to-demanded-observer maximum was 966.621 µs against the
2,109.705 µs frame period, with no over-period sequences. Matrix and scalar
inference intervals were singleton (`matrix_change_at=256`,
`property_change_at=506`). The largest compared error was 4.76837158203125e−7
in correction/controller state; demanded error was 2.9802322387695312e−8.
Delivery and numerical qualification and the separate timing flag all passed.
The next same-case repeat failed with missing sequences 38–39 before either
update. Source frame 34 remained borrowed for 11.989883 ms. Its Julia log records
an 11.64 ms collection without a timestamp; similar durations do not establish
that this collection caused or coincided with the frame hold.

A subsequent compiler/callback diagnostic replay failed with missing sequence
258 at matrix replacement. Unlike the earlier untimestamped logs, callback
counters correlate a collection with this run's callback gap: sequence 253 ended
at monotonic time 1490038744071348 ns with GC pause count 26 and total GC time
531289860 ns; sequence 254 started at 1490038753810443 ns with count 27 and total
539332589 ns. One collection added 8.042729 ms within the 9.739095 ms gap, after
matrix submission at 1490038740870304 ns. This establishes a collection across
this diagnostic matrix-update gap. It does not attribute the earlier 17.1 ms
event or isolate the allocation/cold-start trigger. Compiler tracing may alter
timing, so this diagnostic is not a controlled performance comparison.

All reports remain in the evidence ledger. The first passing run supports
functional progress; the failed repeats prevent a claim of continuous delivery
without stalls. Original historical causality, repeatability, worst-case timing,
and physical DM response remain unqualified.

### CF-07 — Ambiguous adoption boundaries can misdiagnose numerical failure

Severity: medium. Confidence: confirmed. Disposition: reporting repaired.

A locally admissible inferred boundary can fail independent replay while
another admissible boundary reproduces the data. A selected replay mismatch
with ambiguous boundaries is inconclusive for affected outputs and still
rejects qualification. Mean pupil intensity is upstream of both updates;
its mismatches remain definite failures. Tolerances are unchanged, and
incomplete/non-finite observations still fail.

Validation: independent boundary inference/oracle regressions and benchmark
reporting tests. Actual successful live runs have singleton inferred intervals
and compare unclipped intermediate state as well as demanded commands.

### CF-08 — Prepare standalone startup before publishing the Julia node

Severity: high for remaining startup/first-use exposure. Confidence: observed
pass for repeated candidates and installed checks. Disposition:
repaired in `2750a5b` and `5c034d9`; the first candidate's captured report
retains its precommit dirty provenance.

The candidate precompiles runtime parameter preparation signatures without
fabricating a parameter transaction. The standalone island constructs its node
unconnected, exercises owned warmup and monitor first-use work, starts the
monitor, and performs one explicit full collection before connect/publication.
Stop-marker validation occurs once; warmed `ispath` and GC-safe sleep polling
measured zero allocated bytes in the focused startup wait probe. This scope
does not establish zero allocation in arbitrary graph or parameter operations.
No collection is forced during live processing and GC remains enabled.

Unpublished warmup preserves the owner's prior `warmed` flag. The first native
Start must still settle controls accepted while stopped after publication and
retain its normal first-Start reset behavior. An independent review checked
this compatibility repair; the focused 16-assertion regression failed before
and passed after the correction. The durable
[startup checks](../../JuliaFilterGraph.jl/benchmark/results/julia-island-startup-checks-2026-09-29.json)
record all 44 assertions passing: 16 first-Start assertions and 28 cleanup/
startup assertions covering normal shutdown, a preexisting marker, connect/run
exceptions, and collection before connect. The connected closed-loop abort
proof also passed. These checks do not substitute for repeated connected
measurement; the separate row-abort proof issue is recorded in CF-09.

The first prepared-bootstrap live replay delivered all 1,024 frames, with zero
source drops/starvations and no missing demanded observations. Delivery,
independent numerical comparison, and separate diagnostic timing qualification
passed. Maximum source-terminal-to-demanded-observer time was 936.277 µs,
with zero over-period sequences. Inferred boundaries were singleton
`matrix_change_at=256` and `property_change_at=505`; maximum compared error was
4.76837158203125e−7 within the unchanged 1e−6 tolerance.

All 1,024 callback trace records retained GC pause count 27 and total GC time
632687496 ns at both start and end. These counters were unchanged from the
first callback start (1491221243961431 ns) to the last callback end
(1491223402014305 ns), establishing no collection increment over that live
interval. The startup-inclusive `JULIA_GC_DIAG` still reports a pause and
85.289119 ms of GC time; the log's 20.54 ms full recollection and 64.75 ms
incremental pause appear before `JULIA_ISLAND_CONNECT_ACCEPTED`. This startup
accounting must remain separate from callback-correlated ingress evidence.

The next bootstrap repeat stalled before live reconstructor adoption after
253 callbacks; subsequent parameter-phase repeats have mixed results described
in CF-10. Those historical stalls are superseded by the repaired-candidate and
installed continuity checks below. The result does not establish a general
bound on future update allocations, GC frequency/duration, or worst-case
latency, and does not resolve the original historical 17.1 ms event.

### CF-09 — Existing row-abort proof expected rollback of committed nodes

Severity: qualification blocker for the affected progressive proof. Confidence:
confirmed preexisting stale proof expectation by baseline reproduction and
source semantics. Disposition: stale proof corrected in `129402a`; connected
abort regression passed. Progressive performance qualification remains separate.

The connected `scripts/test_row_graph.jl --abort` proof fails the assertion
"the Julia island did not discard its in-flight row sample". A controlled
launcher substitution using the prior committed island script reproduced the
same failure, establishing that the prepared-bootstrap change did not introduce
this observed proof failure. The retained baseline launcher SHA256 is
`9c04a7dc424d4eb5cbfd84f0515a19328fb545904e4af0cb52ff2c0b3d66649f`.

The proof requires pending discontinuity after a downstream callback abort,
but the existing graph commits each completed node before running downstream
nodes (`JuliaFilterGraph/src/graph.jl:947,959`). Pyramid row commit completes
its terminal frame (`FilterGraphAlgorithms/.../pyramid_pixel_row.jl:241`), and
row-block completion clears pending discontinuity. Thus a downstream abort
cannot retroactively mark that already committed terminal frame as an abandoned
in-flight sample. The specific assertion is stale against existing per-node
commit semantics; this does not confirm an algorithm defect. The corrected
proof checks the committed terminal frame, cleared pending discontinuity,
reset row cursor, committed sequence, and adopted gain without inventing
rollback of the upstream node. No production algorithm was changed. The
same connected `--abort` regression passed after the correction; its log is
`~/.cache/jfg-connected-row-abort-per-node-20260929.log`. Complete-frame
results and the passing closed-loop abort proof remain separate evidence.

### CF-10 — Live reconstructor stall precedes the Julia Parameter callback

Severity: high. Confidence: confirmed rejected source-ready activation with
no retry in the direct-return diagnostic; the earlier r5 rejection remains
derived from its observed late asynchronous window. Disposition: source/core
ready-retry repair reviewed and merged; six repaired candidate diagnostic
replays passed; normal `/opt/pipewireao` release deployed. The resolved
installed three-way baseline has since passed, as recorded below.

The prepared-bootstrap repeat failed "live reconstructor was not adopted during
ingress" after 253 graph callbacks ending at sequence 252. Its retained live
callback samples show constant GC counters. The report is partial because
adoption failed; missing whole-run counters and numerical comparison are not
invented from those samples.

The first parameter-phase diagnostic passed all 1,024 frames and both updates,
with maximum diagnostic latency 817.729 µs, zero over-period sequences, and
singleton matrix/scalar boundaries 256/506. Its ten parameter-phase records
show initial and live replacement callback entry, borrowing, preparation,
and publication. Numerical comparison passed within unchanged tolerance.

The second held diagnostic failed the same adoption check and stopped after
253 graph callbacks. Its parameter trace contains only the five initial
publication records; no live replacement entry reaches the native Julia
Parameter callback. The live graph callback GC samples remain constant. Held
stacks show the parameter worker awaiting work, Julia native main/data loops
and RTC/daemon loops waiting in event polling; they do not show a compiler or
GC actively holding the live parameter worker. This localizes the unresolved
failure upstream of the native Julia Parameter callback, without establishing
which publication, activation, or delivery step failed.

A separate source/core inspection found that source `ready()` return values
are ignored and the reliable cycle gate can return `-EBUSY` without retaining
that rejected activation. This is a demonstrated code hazard requiring a
deterministic busy-rejection regression. The retained stalled replay has not
yet demonstrated an actual `ready=-EBUSY` event, so that hazard is not assigned
as its cause. A third held diagnostic then passed all 1,024 frames with a maximum of
852.755 µs and singleton matrix/scalar boundaries 255/504. Its intended extra
native traces were absent because their output directories were not created;
that pass therefore provides no node-ready/ndarray-filter trace evidence.
The fourth held diagnostic passed all 1,024 frames with zero source drops,
maximum diagnostic latency 779.835 µs, zero over-period sequences, and singleton
matrix/scalar boundaries 256/505. All five output comparisons passed. The
fifth repeat failed live adoption after 253 callbacks (sequences 0–252), with
only the five initial Parameter phase records. Its callback GC pause count
remained 28 and GC time remained 617557920 ns throughout the recorded interval.
Source/core behavior was unchanged between these retained diagnostic runs.

The r5 held daemon state shows driver cycle 255 and every active target
`FINISHED`, with `row_cycle_inflight=1`, `reliable_retry_pending=0`,
`reliable_retry_dispatched=false`, and `reliable_release_pending=0`.
The WFS source has `HAVE_DATA`, buffer 1; its downstream peer has `NEED_DATA`,
invalid buffer ID, and no borrowed row. The asynchronous reconstructor
publisher also has `HAVE_DATA`, buffer 1, while its alternate mix IO has
`NEED_DATA`. The actual Julia `reconstructor` port has no pending parameter,
no scheduled worker, and no completed parameter. These are observations of
unforwarded source and Parameter data with no remaining activation demand,
not a Julia callback still preparing a matrix.

The retained monotonic timestamps establish this ordering:

| Event | CLOCK_MONOTONIC timestamp (ns) |
| --- | ---: |
| Julia graph finishes the preceding cycle | 1493377317734557 |
| Driver finishes the preceding cycle | 1493377317785652 |
| Source publishes frame 253 (`P`, buffer 1) | 1493377317949729 |
| Asynchronous reconstructor publisher finishes that cycle | 1493377318103546 |

Source publication is 164077 ns (164.077 µs) after driver completion and
153817 ns (153.817 µs) before the asynchronous target completes. Frame 253 has
no matching source `Q` record; frame 252 had `P=1493377315839400` and
`Q=1493377316086160`. This directly establishes the late asynchronous window
that a source retry driven only by the driver's `node_process()` completion
cannot cover.

Exact evidence files:

- r4 report: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-parameter-hold-1024-r4-20260929/report.json`.
- r5 report: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-parameter-hold-1024-r5-20260929/report.json`.
- r5 daemon state and activation finish times: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-parameter-hold-1024-r5-20260929/daemon-held-state.txt`.
- r5 Julia worker and reconstructor state: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-parameter-hold-1024-r5-20260929/julia-held-state.txt`.
- r5 source publication/return trace: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-parameter-hold-1024-r5-20260929/live-source-trace/source-rtc-heart-wfs-row-source-2946781-1.csv`.
- r5 callback/GC trace: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-parameter-hold-1024-r5-20260929/callback-trace/julia-graph-callbacks.csv`.
- r5 Parameter phase trace: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-parameter-hold-1024-r5-20260929/parameter-trace/julia-parameter-phases.csv`.

Independent r5 adjudication: this is sufficient evidence to reproduce and repair
the ignored-ready/reliable-admission hazard without another production replay
first. The core checks asynchronous completion when admitting a reliable
cycle, whereas driver completion excludes asynchronous targets from its
pending count. The source ignores the rejected ready result, and that core
rejection retains no retry demand. Their conjunction explains the observed
state and ordering, but the historical callback return was not recorded;
`ready=-EBUSY` remains a derived attribution for r5. The subsequent direct
ready-return trace below establishes that attribution for its own failed run.

The direct-return diagnostic retained the old source/core behavior and added
an `N` record around the source-ready callback. Both repeats used plugin DSO
SHA256 `8e2c91ed4773ec5bc602f158bd4ff937af73801810192febbf06be1b075d35c3`.
The first passed 1,024 frames, zero source drops, all numerical comparisons,
and singleton matrix/scalar boundaries 256/506; maximum diagnostic latency was
725.966 µs with zero over-period sequences. The second failed adoption after
253 callbacks ending at sequence 252. Its only negative `N` is frame 253,
buffer 1, generation 64, returning `-16` (`-EBUSY`):

| Event | CLOCK_MONOTONIC timestamp (ns) |
| --- | ---: |
| Source publishes frame 253 | 1493775086558981 |
| Source calls ready (`N` start) | 1493775086559041 |
| Ready returns `-EBUSY` (`N` end) | 1493775086560043 |

The ready call lasts 1002 ns. There is no subsequent `N` or `Q` for frame 253.
The held daemon again has all active targets `FINISHED`, no pending/dispatched
retry, and an outstanding source publication. Julia has no pending or
scheduled reconstructor Parameter; its phase trace has only five initial
records. Callback GC counters remain 29 pauses and 676735032 ns throughout.
Together these directly confirm the rejected activation with no recovery;
the failure is upstream of Julia Parameter preparation. This confirms the
defect in the diagnostic repeat without retroactively inventing an `N` record
for r5.

Additional exact evidence files:

- Passing report: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-ready-return-1024-r1-20260929/report.json`.
- Failing report: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-ready-return-1024-r2-20260929/report.json`.
- Direct ready-return trace: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-ready-return-1024-r2-20260929/live-source-trace/source-rtc-heart-wfs-row-source-2950670-1.csv`.
- Held daemon state: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-ready-return-1024-r2-20260929/daemon-held-state.txt`.
- Held Julia state: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-ready-return-1024-r2-20260929/julia-held-state.txt`.
- Callback/GC trace: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-ready-return-1024-r2-20260929/callback-trace/julia-graph-callbacks.csv`.
- Parameter phase trace: `/home/dgamroth/.cache/rtc-copper-julia-live-updates-ready-return-1024-r2-20260929/parameter-trace/julia-parameter-phases.csv`.

The source/core repair passed its static and unit review. Three repaired Julia
candidate runs and three repaired native candidate runs each delivered all
1,024 frames, adopted both live updates, passed numerical comparison for all
five outputs within 1e-6, and qualified the recorded diagnostic live-update
timing. Each report used PipeWireAO library SHA256
`59557c19f972a8f6896d3c73b55f05a2498652b1a59bc43e26d77d4edfd47e24` and source
DSO SHA256 `71b538c1a393e7d92c24701724aca3df713331b747d633bec21366d9b9a1997a`.
The Julia source traces directly show the recovered ready sequence on frame
254 (r1), 253 (r2), and 255 (r3): `N=-16` followed by `N=0` for the same buffer
ID and generation, with one `P` and one `Q` for each frame. Reports and trace
paths are recorded in the live-update evidence JSON.

These finite candidate replays do not establish a worst-case latency bound,
physical-DM response, or general future-update timing bound. The first
installed three-way attempt against the merged release failed before Julia
ingress because the main checkout's ignored benchmark Manifest still resolved
PipeWireAO.jl 0.6.10. Resolving PipeWireAO.jl 0.6.11 made no tracked changes.
The resolved rerun at
`~/.cache/rtc-copper-fullframe-merged-ready-resolved-1024x3-20260929` passed
its three-repeat qualification, delivering 9,216 commands across the three
controllers. Report paths, comparisons, and phase statistics are in the
[merged baseline evidence](data/copper_merged_fullframe_baseline_20260929.json).
Progressive qualification remains deferred.
Completed-run Julia compiled-cache cleanup removed 55 directories
(1,669,325,998 recorded bytes), with its record retained
at `~/.cache/rtc-copper-completed-cache-cleanup-20260929.json`; reports, logs,
binaries, traces, inputs, and Rust caches were preserved.

All passing and failing runs, phase traces, and held stack paths are retained
in the live evidence JSON. The three Julia and three native repaired candidate
replays establish repeated finite delivery for this candidate setup. The
resolved installed baseline passes exact delivery and numerical comparison;
neither diagnostic nor baseline timing establishes a general timing bound.

The installed normal release also passed both managed 1,024-frame live-update
checks and both 16-frame stop/reset/restart control cycles. All commands were
ordered, with zero source drops/starvations, five-output numerical agreement
within 10⁻⁶, and explicit reconstructor/property adoption. Live commands were
unclipped; clipped control cycles exercised limiting and feedback. The
[installed control evidence](data/copper_merged_control_checks_20260929.json)
retains those four reports and the harness-only fail-before result. Timing
requires opt-in `--live-update-timing` and a diagnostic source build; untraced
release checks report null timing fields. The harness correction passed 18
unit tests and is committed as `fe19c79`.

Final integration checks passed the merged core's row-transport regression,
all five normal-release HEART plugin tests, and all 48 benchmark harness tests.
The latter also caught interrupted-source cleanup leaving child pipes open;
the added closure assertions failed before `a113284` and passed afterward.
Its fail-before log is `~/.cache/rtc-gate-pipe-cleanup-fail-before-20260929.log`;
the clean suite log is `~/.cache/rtc-merged-benchmark-tests-20260929.log`.
Local Markdown links, whitespace, JSON parsing, and the roadmap's Mermaid
render passed. Render provenance is retained at
`~/.cache/rtc-copper-merged-doc-render-20260929/validation.json`.

## Claim limits

Finite functional delivery, numerical equivalence, and software timing are
reported separately. Live timing here ends at the demanded observer, not DM
wire or actuator response. A passing run does not establish a worst-case
latency bound. Diagnostic runs with observers or scheduler/compiler tracing
are not a controlled performance ranking. Progressive work remains deferred
until the complete-frame and live-update acceptance checks pass repeatedly.
