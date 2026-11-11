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

Julia emitted 60 trace entries through the observed acknowledgement,
with reported durations totaling 1.53 s. This includes compilation
for the diagnostic output and is not an exclusive wall-time accounting.
Examples include the retirement declaration and node-set iterators,
the typed effect task, and the native reply encoder and ingress
completion. The largest single trace entry after the acknowledgement
was 170 ms for a Filter close specialization.
