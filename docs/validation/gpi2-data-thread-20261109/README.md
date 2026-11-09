# GPI2 PipeWire data-thread timing — 2026-11-09

## Workload and measurement boundaries

The instrument source was `e55cf2ccd8aa5ae4d6b05918a365d1b5376252fe`. The
installed, non-actuating application used the registered GPI2 CPU simulator
profile, the calibrated 242 × 240 UInt16 detector stream, and the complete-frame
Julia controller with its three simulated command sinks. The controller's ports
declare 2 kHz in both tests. One host configuration paces the simulator at the
authored 10 Hz and the other requests 2 kHz. Both use the same scientific and
transport settings. Each run owns a distinct private core. Optional GUI and
analysis clients were idle.

Julia 1.13.3 stock GC remained enabled. The host is an AMD Ryzen 7 6800H with
16 MiB L3, Linux 6.12.113, and the `powersave` frequency governor. The graph's
PipeWire data loop was pinned to CPU 5, its process leader to CPU 4, and the HIL
leader to CPU 6. The graph data loop used `SCHED_OTHER` and OpenBLAS used one
thread. These are workstation characterization runs.

The tested releases were RTC 0.7.3, PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2+0,
PipeWireAOQueue_jll 0.1.0+0, FilterGraphPipeWire 0.5.3, FilterGraphs 0.10.2,
FilterGraphAlgorithms 0.12.2, AOS 0.3.22, HIL 0.5.1, and Proper 0.4.1. The
release-tree and SDK checks passed 34 assertions. The package cohort was
unchanged by the test. The temporary instrument authoring copy enables the
existing graph callback sampler and HIL phase recorder. The installed runtime
uses the registered SDK and separate queue artifact.

- **Julia controller callback.** The FilterGraphPipeWire trace measures the
  warmed callback body on the PipeWire data thread, including input metadata,
  property/parameter adoption, scientific execution, and output data/metadata
  marking. The two same-thread Julia allocation samples are valid only within
  one GC epoch. The boundary excludes native entry and final publication,
  untracked native allocation and helper-thread work. The extended bounded
  sampler passed the upstream 18-assertion selector with the installed Julia
  headers.
- **Graph-process GC.** The pre/post GC hooks record monotonic elapsed intervals
  and collector epochs. In Julia 1.13.3 the pre hook runs after safepoint
  synchronization and the post hook after world release and finalizers. The
  hook span estimates the collection interval. Callback epoch crossings
  separately show which intervals invalidate allocation samples.
  [Julia 1.13.3 collector](https://github.com/JuliaLang/julia/blob/v1.13.3/src/gc-stock.c#L3358-L3428)
- **HIL pacing and end-to-end response.** HIL phase rows supply the scheduled
  release, exchange start, source publication, last of three command receipts
  and next scheduled release. Sequence and monotonic timestamps join these
  rows to the exact controller callback. The slot budget is one pacing period
  from scheduled release to last command receipt. An unoffered slot is counted
  as skipped. The source allows one frame in flight and explicitly advances
  over elapsed slots. This is lockstep load with an explicit slot ledger.
- **Native PipeWire scheduling.** A separate interval enables the private core
  profiler and observes node signal, awake and finish timestamps and xrun
  counters. A further interval samples user-space CPU execution on the
  controller TID. The primary timing window uses only the bounded graph/HIL
  traces. HIL stream processing uses deferred callbacks in its client event
  loop. The HIL counters are process-wide, and native profiler times describe
  native node activation.
  [PipeWire stream flags](https://docs.pipewire.org/group__pw__stream.html)

## Authored 10 Hz pacing

The warmed 150.32 s window completed 371 exchanges at 2.47 Hz with consecutive
frame identities. The source's nominal schedule had 1,503 slots. It skipped
1,132 slots and the last command for each of the 371 published frames arrived
after its 100 ms release-to-command budget.

| Measurement | Median | p99 | Maximum |
| --- | ---: | ---: | ---: |
| HIL release-to-start lateness | 1.24 µs | 3.07 µs | 3.75 µs |
| CPU optical model step | 370.07 ms | 406.76 ms | 426.03 ms |
| Detector publication to last command | 3.80 ms | 6.38 ms | 7.40 ms |
| Absolute publication interval error relative to 100 ms | 299.99 ms | 397.60 ms | 418.80 ms |

HIL's process allocation counter increased by 13,267,072 bytes between the
first and last measured exchange. Its process GC time counter did not advance.
These counters include non-data-thread work. Graph preparation re-registered
the default sampler and displaced the temporary trace export wrapper. The
first run therefore retained HIL, native profiler and graph-thread CPU
samples. Its graph allocation and GC samples are unavailable.

The separate CPU sample collected 226 observations on the graph's PipeWire
data thread. OpenBLAS SGEMV accounted for 90.71% of them, including 89.38% in
`sgemv_kernel_4x8`. This is an on-CPU sample over the selected interval. It
measures execution distribution and excludes time spent sleeping or runnable
off CPU.

## 2 kHz pacing probe

A short repeat changed only the host pacing period to 500 µs. Its warmed
15.26 s window completed 37 exchanges. Of 30,517 nominal slots, 30,480 were
skipped and all 37 published frames received their last command after the
slot deadline. The graph process recorded 20 pre-Run GC hook intervals and
one after Quit, with a maximum hook span of 170.23 ms. There were no graph
collection events between Run and Quit. The graph callback arrays from this
probe used the default in-memory factory and were unavailable after exit.

For the instrumented repeat, keep the sampler capacity disabled during graph
preparation and enable it while the node is constructed. The recorder uses
the existing callback arrays with preallocated, prefaulted file-backed
storage. It writes the same scalar samples as the standard recorder and
decodes them after process exit. The focused check retained an injected
4,168-byte allocation and correctly invalidated an interval crossing a
forced GC. It also verifies that graph preparation preserves the selected
factory.

## Instrumented 2 kHz repeat

The graph, calibration binding manifest, supervision settings and Julia
manifest match the 10 Hz export byte for byte. The resolved simulation
configuration differs only in pacing. The live registry verifies all 32 RTC
Links and ownership of the detector-to-controller and three command routes.
The Linux thread was `julia-data-loop` on CPU 5, TID 986409, matching the
sampler's thread identity.

The warmed 100.34 s window captured 261 successful callbacks. Each matched
one HIL exchange by frame sequence and monotonic timestamps. **All 261 valid
allocation samples measured zero Julia heap bytes.** The full trace retained
519 successful callbacks with zero Julia heap bytes, zero GC epoch crossings,
and ample space in the 65,536-record buffer.

| Measurement | Median | p99 | Maximum |
| --- | ---: | ---: | ---: |
| Julia controller callback body | 3.554 ms | 3.873 ms | 3.934 ms |
| Detector publication to callback start | 120 µs | 1,035 µs | 1,412 µs |
| Callback end to last command receipt | 176 µs | 1,146 µs | 5,423 µs |
| Detector publication to last command receipt | 3.858 ms | 4.929 ms | 9.104 ms |
| Absolute callback start interval error relative to 500 µs | 382.24 ms | 411.17 ms | 421.58 ms |
| HIL release-to-start lateness | 0.659 µs | 2.365 µs | 4.619 µs |
| CPU optical model step | 378.54 ms | 407.54 ms | 417.92 ms |

The pacing ledger has 200,674 nominal slots in the warmed window, of which
200,413 were skipped. All 261 published frames received their last command
late. All 261 controller callback bodies alone exceeded 500 µs. Source
publication averaged 2.60 Hz, with zero sequence gaps or duplicates after
publication. These results distinguish the source's skipped slots, controller
service overruns and completed late exchanges. PipeWire xrun counters remained
at zero for the controller, WFS, woofer, tweeter and tip/tilt nodes during the
separate profiler window.

The graph process recorded three GC hook spans during the warmed window,
from 6.06 to 15.23 ms. None overlapped a controller callback. Across the
entire recorded owner interval, 19 hook spans occurred before Run and five
between Run and Quit. The largest overall was 178.21 ms before Run. The HIL
process allocation counter increased by 9,235,200 bytes in the warmed window
and its cumulative GC time did not advance. These measurements leave native
heap allocation, GC time-to-safepoint and per-thread GC stall durations
unmeasured.

The native profiler sampled five graph activations that exactly contain a
recorded callback. Signal to awake had a 57.5 µs median and a 1.406 ms maximum.
Awake to finish had a 3.590 ms median and a 4.399 ms maximum. This small
activation sample describes the transport boundary, including scheduling and
dependencies. It is insufficient for a stable tail percentile. A separate
242-sample on-CPU profile attributed 87.19% of observations to OpenBLAS SGEMV.

The native control client confirmed that correction opened and then closed
again, with active generations 1 and 2. All 39 callbacks in that separate
window measured zero bytes. The callback trace flagged no in-callback
property or parameter adoption. This verifies the sampled callback budget
during the exercised control traffic. Parameter replacement remains outside
the measured workload.

All three private sessions acknowledged Quit. Each cleanup receipt reported
successful systemd exit and removal of the session unit files. Physical
camera and actuator deadlines, independent 2 kHz arrivals, and real-time
scheduling on the target host are outside this evidence.

## Ownership implications

Keep the Julia RTC session manager. The measured processing loop is in the
separate FilterGraphPipeWire owner. The CPU simulator's optical step dominates
lockstep cadence, so its missed pacing slots characterize this simulation
workload. The simulator remains a standalone Julia owner. A faster simulator
backend or an independent detector replay would provide a higher-rate test
source.

The GPI2 controller is the first graph owner to compare against a strict
500 µs budget. Its dense 1,509 × 11,104 Float32 reconstructor occupies
67,023,744 bytes, compared with 16 MiB L3 on this host. Reading it once per
frame at 2 kHz requires about 134 GB/s of coefficient traffic before the
other projections and transport. CPU samples place most on-CPU work inside
compiled OpenBLAS kernels. A C or Rust port that uses the same matrix and
BLAS calls would retain that work.

The existing captured Float32 Julia controller is a candidate for a separate
fixed-arrival PipeWire test. Its saved-frame study completed 2,048 offered
500 µs periods with zero observed deadline misses and 444.9 µs p99 for the
authored-output configuration. That study excluded PipeWire and hardware.
The current installed controller's supervision and live correction controls
select the ordinary CPU owner. A captured owner requires an explicitly
compatible profile.
[Captured controller results](https://github.com/DarrylGamroth/JuliaFilterGraph.jl/blob/FilterGraphPipeWire-v0.5.3/docs/gpi2-gpu-results.md)

A CPU-only hard-deadline controller is a candidate for a matched C-hosted
Rust FGN comparison after reducing matrix traffic or changing the processing
layout. Use the same frame arrivals, calibration, command products and
numerical checks to attribute any timing improvement. Use compiled SPA
adapters for physical camera or actuator callbacks that must complete within
a hard hardware deadline. This run used simulated WFS, woofer, tweeter and
tip/tilt endpoints and supplies no physical device timing or migration
decision for any of them.

## Evidence

The [archive](evidence.tar.gz) contains the callback and GC CSVs, HIL phase
rows, native profiler records, sampling reports, registry and cleanup
receipts, dependency identities, the host profiles, and the temporary
instrumentation and analysis sources. [Archive SHA-256](evidence.tar.gz.sha256)

The analysis can be rerun without PipeWire or Julia after unpacking:

```sh
sha256sum -c SHA256SUMS
python3 reproduction/summarize.py runs/10hz
python3 reproduction/summarize.py runs/2000hz
python3 reproduction/verify-registry.py runs/10hz runs/2000hz
```
