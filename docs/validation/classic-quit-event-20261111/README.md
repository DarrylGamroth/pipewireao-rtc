# Classic first QuitRequested timing

The [RTC 0.7.14 release run](../rtc-0714-20261111/README.md) observed
5.40 s from the client-side submission fence to the accepted reply.
This follow-up traced the running RTC on a private PipeWire core.

## Baseline

The test installed the same Classic CPU cohort with a temporary local
registry build of RTC 0.7.14. The build enabled Julia compilation tracing
at the entry to the RTC's native Quit handler and emitted monotonic
timestamps at the entry, request, receipt and exit of each bootstrap
retirement. The standard installed unit, exact process identity check,
PipeWire contracts and deadlines were used. The trace covers dispatch
and effects after the handler was entered. It excludes compilation
before the handler body started and does not profile the separate owner
processes.

The submission fence was first observed at +5.51 s, the RTC entered
Quit at +6.08 s, and the client acknowledgement was observed at +11.11 s,
relative to the systemd stop job. The full managed stop took 16.24 s.

| Bootstrap owner | Retirement entry to validated receipt | Request call to validated receipt |
| --- | ---: | ---: |
| Julia controller | 1.236 s | 0.682 s |
| Standalone HIL simulator | 1.356 s | 1.353 s |
| Parameter publisher | 0.869 s | 0.868 s |

The owner interval includes any RTC compilation and transport processing
between the timestamps. The first owner's identity and withdrawal
preparation accounted for another 0.553 s before its request. The next
0.430 s between controller retirement and simulator retirement included
Link withdrawal. After the last receipt, RTC still had to remove controls
and publish the correlated terminal reply. The WFS analysis worker was
stopped separately by systemd in 65 ms.

Julia emitted 61 trace entries through the observed acknowledgement,
with reported durations totaling 1.56 s. This includes compilation
for the diagnostic output and is not an exclusive wall-time accounting.
Examples include the retirement declaration and node-set iterators,
the typed effect task, and the native reply encoder and ingress
completion. The largest single trace entry after the acknowledgement
was 170 ms for a Filter close specialization.

## Candidate with tracing

The candidate prepares typed effect execution, native Quit reply encoding
and ingress completion, and session close before exposing the control
endpoint. The first owner uses direct declaration and node-set iteration.
The change preserves native identity checks, the order of owner and Link
retirement, and the five-second RTC effect deadline.

The same temporary build and instrumentation were used for two candidate
runs. RTC compiler trace entries before the controller Quit call fell
from 32 entries (725 ms reported) to 20 (385 ms and 366 ms). The
corresponding interval from RTC Quit entry to the controller Quit call
fell from 0.808 s to 0.480 s and 0.455 s.

| Owner request call to validated receipt | Baseline | Candidate 1 | Candidate 2 |
| --- | ---: | ---: | ---: |
| Julia controller | 0.682 s | 0.816 s | 0.992 s |
| Standalone HIL simulator | 1.353 s | 2.182 s | 1.912 s |
| Parameter publisher | 0.868 s | Deadline expired | 1.162 s |

Both instrumented candidate runs expired at the five-second effect
deadline. The first expired while waiting for the parameter publisher.
The second received all three owner receipts, with the last arriving
about 4.996 s after Quit entry. Control removal and reply publication
still had to follow. systemd fallback completed in both cases and all
recorded owner MainPIDs were zero. These traces locate the additional
wall time in owner round trips. They do not identify the cause inside
the owner processes.

## Owner CPU sampling

The same candidate source without in-process tracing was installed from
the temporary registry and run on another private core. The stop
completed fallback cleanup in 22.92 s after another native deadline
failure. Starting at the observed submission fence, `perf record`
sampled each process with `cpu-clock:u` at 49 Hz until it exited.
The interval includes time before and after the individual bootstrap
requests and, for the RTC, failure cleanup.

| Process | Samples | Samples in libLLVM |
| --- | ---: | ---: |
| RTC | 140 | 59.29% |
| Julia controller | 55 | 69.09% |
| Standalone HIL simulator | 116 | 37.93% |
| Parameter publisher | 68 | 69.12% |

No samples were lost. The owner profiles include LLVM instruction
selection, DAG combining and compiler pass management. These counts
are shares of sampled CPU time. They establish that Julia compilation
continued in the separate owners during shutdown, without assigning
a wall duration to that compilation or identifying its Julia callers.

## Verified candidate

The final candidate also prepares the bootstrap monitor's Quit route,
terminal fence and owner finish and close calls, plus each concrete
quit callback before registration. The parameter publisher prepares
its stream, endpoint and timer close methods. These are compile
requests. They send no PipeWire commands and close no resources.

A new Classic install selected the candidate from a temporary local
registry (test-only version `0.7.19`, source tree
`37e814eb40e9bcff1031c51e6b6f95a9e25ccd5a`). Every other dependency
entry matched the traced baseline. The installed Project and Manifest
matched the resolved copies. No in-process tracing was enabled.
The existing five-second effect deadline and all receipt and identity
checks remained in force.

| Measurement | RTC 0.7.14 release run | Final candidate |
| --- | ---: | ---: |
| Managed stop elapsed | 14.71 s | 12.42 s |
| Stop job to submission fence observed | 4.59 s | 4.13 s |
| Submission fence to acknowledgement observed | 5.40 s | 3.98 s |
| First post-stop sample to core PID gone | 2.61 s | 2.50 s |

The candidate reached Ready in 383.3 s. Its RTC control dispatch
preparation took 41.2 s, compared with 31.4 s in the 0.7.14 release run
and 35.3 s in the traced baseline. These are separate runs on a shared
host. The preparation difference includes host variability and the
additional compilation before admission.

The WFS analysis worker was still starting at stop and exited in
33 ms. The native Quit was accepted, all owners exited, and the private
socket and invocation unit files were removed. No SIGKILL was recorded.

At 49 Hz, the final run recorded fewer libLLVM samples during the
fence-to-exit windows than the RTC-only candidate. The counts were
36 vs 83 for the RTC, 22 vs 38 for the controller, 29 vs 47 for the
parameter publisher and 32 vs 44 for the simulator. LLVM still appeared
in each profile. Sampling covers different wall-time intervals and
cannot assign the reduction to individual methods.

The MediaSession machine, object, effect and ingress tests and the
owner bootstrap codec and entrypoint tests passed with the matching
PipeWireAO JLL artifact.
