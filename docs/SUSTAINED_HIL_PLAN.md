# Sustained complete-frame HIL qualification

Starting revision: `1d3f1b5cadab0bb222390d90311b4094c30a40c3`.
Worktree: `pipewireao-rtc-sustained-hil`, branch `work/sustained-hil-20261004`.
Fresh evidence: `/home/dgamroth/.cache/rtc-sustained-hil-20261004`.

## Selected increment

Qualify Classic and then Copper with the accepted measured AOS calibrations,
complete-frame FGN and JFG, and CUDA simulation on RTX 3080. Refresh transport
packages to released PipeWireAO 0.6.14 and PipeWireAO_jll 1.7.0+19 without changing
scientific graphs, maps, inverses, gains, detector model or model period. HEART
is unchanged. This increment is non-actuating simulation under RTC-ARCH-021;
it does not select physical deployment or host policy changes.

Retain the historical finite evidence. Fresh deployment must verify its own
resolved package bytes, exact scientific artifacts, admission and shutdown.
Independent review identified the 256-frame recording bound and expensive truth
hashing as incompatible with a continuous-state cadence claim.

## Execution and evidence

1. Fresh finite diagnostic runs: Classic FGN/JFG and Copper FGN/JFG, 256 frames,
   explicit stopped reset and exact repeated payloads. Use the existing independent
   truth replay and zero-command baseline gates. Command rail proximity alone
   does not prove clipping feedback; use chronological graph replay separately.
2. Extend the scientific owner explicitly with a bounded total target, preserving
   the existing finite default. Retain at most 256 images; validate identities,
   chronology, finite commands and bounds for every exchange. Keep plant and
   controller state continuous beyond the retained prefix. Write a distinct
   sustained report; never present retained-prefix counts as total delivery.
3. Diagnostic-enabled sustained runs retain global-sequence late truth samples.
   Their residual/atmosphere ratios are observations, separate from the replayed
   finite prefix. No sparse sample is described as replay of intervening frames.
4. Diagnostic-disabled sustained runs characterize cadence, source-to-command
   latency, exchange duration, inclusive elapsed time, GC/allocation and host/GPU
   memory. Prefix preparation and serialization are outside the measured interval.
   Fixed-size histograms report quantile bounds and overflow, not invented exact
   values. Allocation measurements name the process and interval they cover.
5. Exercise pause/resume without resetting the loop, explicit stopped reset,
   fresh sequence/generation, and public shutdown. Restart starts from the
   declared seed and calibration; do not reuse operator mutations implicitly.

Closed-loop unpaced capacity is a completed exchange rate, not open-loop maximum
RTC throughput. A separately paced test preserves model chronology, waits for a
future deadline after an overrun, reports missed periods, and never catches up
in bursts. Model exposure remains no longer than model period. Choose Copper
wall pacing from measurements. Do not infer a 500 Hz or 1 kHz simulation claim
from a model period. No CPU0/1 execution or host tuning is introduced.

## Required validation

Cross the retained boundary without changes to prefix bytes. Inject a sequence,
model-time, timing identity or nonfinite-command defect after frame 256 and fail
closed. Check fixed memory across total targets, zero allocation in the metrics
update, finite legacy regression, truth sampling bounds, incomplete reports and
serialization limits. Run GPU/RTC cases serially. Record competing load,
placement, released dependencies and exact descriptor hashes. Extended-memory
checks distinguish live memory from retained pools and do not establish a
zero-allocation graph callback from source-process counters.

## Disposition

The selected continuous and stopped-reset frame-loop increment is implemented
and exercised in the recorded CUDA configuration. The
[evidence ledger](SUSTAINED_HIL_EVIDENCE.json) seals the completed reports;
the observations below describe their scope. Midrun control/report processing
still allocates and remains an unqualified lifecycle gate. No physical-device,
hard-deadline, HIP zero-allocation or isolated maximum-rate claim is established.

### Allocation gate added from measured failure

The user requires zero allocations in the warmed simulator frame loop. This
includes optical execution, HIL staging and exchange, wall pacing, recording,
metrics and enabled per-frame diagnostics. Preparation, stopped reset and final
report serialization remain outside the frame-loop measurement. Disabling GC
does not satisfy this gate.

The initial sustained runs passed delivery and reset checks but failed this
allocation gate: diagnostic-disabled Classic allocated about 42.6 KB per
exchange unpaced and 158.4 KB per exchange paced. Copper recorded a 323 ms
process GC pause. These observations are retained; they do not qualify an
allocation-free simulator. Repeated unchanged control-file reads and per-wait
Julia timers are confirmed allocating source paths. Their measured contribution
and optical/transport allocations must be separated before attributing all of
the process total. Rate tests were suspended during remediation; the later
zero-allocation checks below permit fresh paced characterization without
accepting the failed runs.

The later `classic-fgn-alloc-v2` live run delivered all 8,192 exchanges and
completed public shutdown and cleanup. After its 256-frame retained prefix,
the whole simulator process allocated 31,243,136 bytes across 7,936 exchanges
(about 3.94 KB per exchange). It recorded zero GC pauses and zero GC time.
This still fails the allocation gate: absence of a collection is insufficient
when the frame loop continues allocating. The captured optical unit, quiet
control polling and native-loop lock have separate zero-allocation regression
evidence; that evidence does not qualify their combined live owner path.
The acquisition record is
`~/.cache/rtc-sustained-hil-20261004/classic-fgn-alloc-v2-evidence/run-1/sustained-result.json`.

The subsequent closure-specialization and stream-state-query experiments
exposed a repeatable transport failure before that measurement interval:
`alloc-v4`, `alloc-v5` and the prepared-query-storage variant `alloc-v7` timed
out awaiting command 2. Reverting only the stream-state query in `alloc-v6`
delivered all 8,192 exchanges, with 769,440 allocated bytes, zero GC and complete
public shutdown/cleanup. The strict qualifier correctly rejected that run and
retained its evidence. This establishes dependence on the query change; it
does not establish a compiler or reference-lifetime defect.

The bounded `trace-v9` experiment observed two queued source frames but only
one command callback. Both streams were streaming, the source remained the
driver, and the RTC's public status remained Running. Thousands of empty
source activations followed. The later serialized driver-cycle handshake
corrects the observed delivery failure in fresh runs; no compiler, algorithm
rejection or native transport root cause is established. The case identities,
failed observations and inclusive allocation
counters are retained in
`~/.cache/rtc-sustained-hil-20261004/simulator-allocation-campaign.json`.

The prepared per-owner driver-cycle handshake then delivered all 8,192 frames
in `classic-fgn-cycle-v12`, with confirmed public shutdown and cleanup. Its
7,936 measured exchanges still allocated 64 bytes in four pool allocations;
zero GC activity did not satisfy the gate. Full-interval allocation profiling
in `classic-fgn-trace-v13` reproduced exactly four 16-byte `RefValue` objects.
All four originate in CUDA.jl's periodic memory-budget refresh through
`synchronize(...; blocking=true)` and `maybe_collect(true)`, rather than the
adapter's driver-cycle wait. The profile is retained as
`~/.cache/rtc-sustained-hil-20261004/classic-live-allocation-profile-v13.json`.

A separate AOS worktree, `AdaptiveOpticsSim-captured-wait` based on `d30db3f`,
implements cooperative public `CUDA.isdone` polling followed by ordinary
`CUDA.synchronize` for the exclusively owned captured stream. This preserves
the public synchronization/error checks and Julia safepoints without disabling
GC or changing process-wide CUDA settings. Zero allocation depends on the
qualified CUDA synchronization policy; it is not a general CUDA API promise.
The narrow wait regression passes seven assertions, including a pending kernel
and the quiet-window refresh boundary. Isolated error experiments preserve the
same `KernelException` as ordinary public synchronization.

### Observed zero-allocation frame loop

All four continuous captured-CUDA cases (`classic-fgn-wait-v14`,
`classic-jfg-wait-v15`, `copper-fgn-wait-v16`, `copper-jfg-wait-v17`) delivered
exactly the requested exchanges and completed public shutdown and owned cleanup.
After each 256-frame prefix, the entire simulator process recorded zero heap
bytes, pool/big/malloc/realloc calls, GC pauses, GC time and full sweeps. The
measured intervals contain 7,936 exchanges for Classic and 3,840 for Copper.
The case ledger is `E/zero-allocation-continuous-results.json`. These cases used
local repairs before their wrapper release; their sealed provenance is retained.

Diagnostic-enabled FGN cases `classic-fgn-diag-v18` and `copper-fgn-diag-v19`
also pass the same inclusive gate. The four stopped-reset cases `reset-v20`
through `reset-v23` each repeat two uninterrupted runs, with exact retained
ADC/command hashes and identical sparse late truth. Every run independently
passes the allocation gate; see `E/zero-allocation-reset-results.json`. The
last two packages contain exact v0.6.14 wrapper source as a local path dependency.

These observations qualify warmed continuous execution in the recorded CUDA
configuration. Preparation, stopped reset and final serialization allocate
outside that interval. Midrun control/report processing has not passed the
inclusive zero-allocation lifecycle gate. The completed additional campaign
gates are recorded below; their successful results do not relabel earlier runs.

### Paced delivery

All four paced cases deliver every exchange, pass the same zero-allocation gate,
and complete public shutdown and owned cleanup. The source has a 2 ms model
period; wall pacing preserves that chronology and uses no catch-up bursts.

| Case | Requested wall Hz | Observed completion Hz | Whole-run missed wall periods | Measured exchanges over wall budget |
| --- | ---: | ---: | ---: | ---: |
| Classic FGN v24 | 250 | 247.373 | 105 | 72 / 7,936 |
| Classic JFG v25 | 250 | 248.085 | 83 | 58 / 7,936 |
| Copper FGN v26 | 100 | 99.996 | 7 | 0 / 3,840 |
| Copper JFG v27 | 100 | 99.971 | 10 | 1 / 3,840 |

Whole-run wall misses include the retained prefix; exchange histograms exclude
it. Misses delay production without dropping model exchanges or commands.
These are single observations on a shared host, not guaranteed scheduled rates.
The native graph/data threads use RT priority 83 on CPUs 2/4; simulator native
threads use CPU 6 with SCHED_OTHER, housekeeping CPU 14 and observer CPU 10.
No CPU0/1 placement, isolation or power-policy change is selected. The ledger
`E/zero-allocation-paced-results.json` retains quantile bounds and full scope.

### Feedback and arithmetic checks

Classic's fixed-input clipping control and the two Copper captured clipping
cohorts now pass the informative feedback gate. Copper v30a/v31a repeat two
finite 256-frame batches exactly across stopped reset and complete public
shutdown. Only commanded rails change to ±0.01 µm; matrices, gains and plant
chronology remain frozen. The ordinary JFG replays v34/v35 carry nonzero
controller feedback on 254/256 frames. Holding that feedback at zero changes
43,446/43,445 demanded-command components, with maximum difference 0.02 µm.
All 256 warmed public `process!` calls allocate zero bytes. FGN-input replay
retains its disclosed inverse difference and maximum command discrepancy
2.48 × 10⁻¹² m; JFG-input replay matches its recorded commands exactly. This
counterfactual uses fixed saved pixels and is not a second plant trajectory.

The v33 noisy Copper stream/capture comparison uses identical seeds, fixed 2 ms
steps and the same measured command trace. Exact UInt16 wire encoding differs
at 218 of 1,048,576 pixels across 142 frames, by at most two ADC counts. Pupil
and atmospheric OPD differences are at most 3.41 × 10⁻¹³ m; simulated DM surface
is identical, and first-frame reset repeats exactly for both policies. This is
descriptive arithmetic characterization, not bit equality or a supplied
scientific tolerance.

### Released dependency deployment

The fresh sealed Classic FGN v32 package resolves registered PipeWireAO 0.6.14
at tree `134bc7cd9e7055f42d22e526ad7de01e65f4e440`, without a source-path override.
All 138 other manifest records and frozen scientific inputs remain unchanged;
resolution updates only the stale project hash. The actual deployment delivers
8,192 frames and commands, records zero heap/GC activity on 7,936 measured
exchanges, and completes public shutdown and owned cleanup. Its report records
the intentional `/opt/pipewireao` native-library override; it does not prove that
JLL-native artifacts executed. Successful local-repair packages keep their own
original identities. Min-version export/deployment checks and installation of
the released dependency supplement this live result.
