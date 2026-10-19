# Phase investigation, 2026-10-19

## Recorded software

The first complete captures use registered RTC 0.1.6 (source e4e812b,
package tree 843c5212ab5e58bd1dad6bb298f9b469a8e26cb4), HIL 0.1.4
(e57c6f0, tree 5bb505504fc39c1265848ac8f45410780dce35f5), AOS 0.1.0,
CUDA 6.4.2, JFG 0.4.0 and PipeWireAO_jll 1.7.1+0. Target and model
period are both 2 ms; exposure and scientific/FITS inputs are unchanged.
The simulator runs on the RTX 3080. GUI refresh remains independent.

Evidence root: `/home/dgamroth/.local/state/classic-registered-20261019`.
Baseline stage `phase-session-001`, invocation
`761953efe6fb40f9880ae9897766e751`, unit
`pipewireao-session@b39b04d09563.service`. Each capture excludes 512 warmup
frames and contains 8,192 consecutive completed exchanges. Files are copied
out of the invocation before teardown. Phase ordering, generation consistency
and pacing arithmetic pass on the first closed/open captures.

## Baseline observations

| GUI | Trial | Rate (Hz) | Skipped release slots | Process GC (ms) |
|---|---|---:|---:|---:|
| Closed | 1 | 456.884 | 773 | 861.063 |
| Open | 1 | 446.857 | 975 | 929.059 |
| Open | 2 | 446.035 | 991 | 913.030 |

These are exploratory runs; the fourth baseline run was deferred for allocation
profiling. They do not establish an isolated causal effect of GUI rendering.
They do establish that the missed-period problem persists with the GUI closed.
The earlier short 280–300 Hz observations remain valid for their own windows;
they are not interchangeable with these longer phase captures.

Closed trial 1 phase costs:

| Phase | Median (µs) | p99 (µs) | Maximum (µs) |
|---|---:|---:|---:|
| AOS graph step and detector readback | 380.723 | 399.027 | 473.668 |
| Host UInt16 staging/layout conversion | 210.945 | 269.576 | 346.990 |
| Publication to matching command receipt | 1,064.184 | 1,132.642 | 7,342.168 |
| Command adoption and applied snapshot staging | 13.315 | 24.406 | 43.341 |
| Whole exchange | 1,708.391 | 1,871.777 | 8,425.036 |

The process allocation counter grows by roughly 1.5 MB per completed frame,
including all owner tasks. This is not attributed exclusively to AOS or to
any particular phase. The process GC counter grows by 861 ms over the
17.928 s capture. Sampled allocation profiling is the next discriminator.

## Bounded isolation measurements

Observed under Julia 1.13.2:

- Isolated warmed AOS graph step and detector readback allocate 2,048 bytes
  per step; command adoption allocates zero. Probe:
  `aos-allocation-probe.jl` and its log in the evidence root.
- HIL 352×352 Float32 to UInt16 staging allocates zero warmed heap bytes.
  A 4,096-sample benchmark has median 192.120 µs and p99 232.536 µs.
- Pure HIL command-copy, receive bookkeeping, adoption bookkeeping,
  applied snapshot staging and timing helpers allocate zero in focused probes.
- A cold-control mailbox with `ready=false` does not reproduce per-poll
  allocation. The generic outer measurement wrapper boxes a fixture once;
  the specialized wrapper does not allocate. An idle optical snapshot poll
  also allocates zero in its concrete fixture.

These fixtures exclude transport callbacks and concurrent owner tasks.
They narrow the investigation; they do not establish whole-owner allocation.

## Retry policy evidence

HIL's completion wait makes an immediate retry attempt, then starts a 1 ms
cooldown. The native cycle gate can reject that attempt because a preceding
cycle is still pending. The old wait starts the cooldown even when no new
cycle was issued. A deterministic fixture using the actual wait and cycle gate
shows the following ordering: first attempt rejected, prior cycle completes,
next actual trigger delayed at least 1 ms. Across 32 fixture repetitions the
minimum delay is 1,000.074 µs and median 1,000.274 µs.

This is a demonstrated policy-induced delay under that ordering. Its
contribution to the live 1 ms round-trip floor still requires paired live
traces after the narrow correction. The proposed change preserves the cycle
gate and applies the cooldown only after an actual retry issuance. Successful
retry triggers within one wait remain separated by at least 1 ms; this is not
a global spacing guarantee across initial triggers or separate waits.

No gains, noise settings, model equations, exposure or artifact values have
been changed. Sustained 500 Hz remains an open gate until measured.

## Validation so far

- Stable-version RTC suite: 2,061 assertions in 63 sets passed.
- Optional extension assembly/pacing: 18 assertions passed, including warmed
  recording below capacity with zero heap bytes and unpaced arithmetic.
- Recorder: 46 assertions passed; argument/report/binding coverage: 90.
- HIL focused instrumentation: 93 assertions and 11 Aqua checks passed.
- Broader HIL focused regressions during reconnaissance: 341 assertions passed.
- Independent capture and retry-design reviews found no sequencing blocker.

An initial whole-suite run changed package version while a test process was
running, producing two SDK-version tamper-test failures. A stable-version
rerun passes the complete suite; the transient run is retained in the logs.

## Actual allocation profile and correction

A separate registered-0.1.6 diagnostic invocation (`alloc-profile-session-001`,
invocation `64f8ddc122854e9f8b59d6ccaaa12e3e`) runs a three-second
`Profile.Allocs` sample at probability 0.0001. The profiler runs in the
headless simulator. Its startup wrapper exists only in the separate sealed
`application-alloc-profile` investigation configuration. It is not the
maintained deployment entry point. Collection stops before source Hold; decoded
results are serialized while held. This profiling run is not rate evidence.

Observed: 84 sampled allocations total 153,944 sampled bytes. The large reset
callback accounts for 35 samples / 153,160 bytes (99.49% of sampled bytes),
size 4,376 bytes each, allocated at the `run_prepared!` call to
`consume_control!`. Another 48 samples / 768 bytes are `Core.Box` allocations
at entry to `consume_control!`. The remaining sample is 16 CUDA-related bytes.
These are sampled byte totals, not estimates of total runtime allocation.
Raw `allocation-profile.bin` and `allocation-analysis.log` are retained.

The reset callback captures the prepared science owner and options. The
control poll merely forwards the callback to another method, so Julia's
function-argument specialization heuristic boxes that large callback at the
non-specialized call boundary. A concrete caller fixture reproduces linear
per-poll allocation in registered RTC 0.1.6 (4,528 bytes per poll with the
fixture's different captured payload). The earlier fixture passed an already
boxed callback from an outer call and did not reproduce this caller context.

The focused correction explicitly specializes the callable argument using
`reset_owner!::F where {F}`. The generation binding used by the request
publication callback is also separated from the later rejection-generation
binding, removing the unnecessary shared capture box. Both lock callbacks
execute synchronously; read points, reset and report-save ordering, ACKs,
rejections and callable lifetime are unchanged. Independent review found no
sequencing or lifetime blocker. Paired live traces remain required.

The one-off profile driver initially encountered a Julia soft-scope error in
its post-capture file-stability check. Source Hold and profile serialization
had already completed. The final file was copied separately and successfully
deserialized/analyzed; the driver was corrected for future use.
