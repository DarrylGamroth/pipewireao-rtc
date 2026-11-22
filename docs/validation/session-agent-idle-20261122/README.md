# MediaSession owner polling trial

The baseline is RTC `9eaf009`. Both versions use Agent.jl 0.4.1,
PipeWireAO.jl 0.9.6 and the same RTC manifest. The baseline requests a 1 ms
Julia sleep after every invocation. The candidate uses
`Agent.SleepingMillisIdleStrategy(1)` for empty turns. It counts each
newly scheduled effect as work and calls `yield()` after productive turns.
The owning task still invokes the agent, iterates the native loop and closes
the session. Scientific frame processing runs on separate data threads.

We expected the candidate to reduce accumulated sleep during a series of
control exchanges, while consuming similar CPU on a quiet core. The functional
checks cover progress of same-thread effects, deadline handling, command
correlation and orderly exit. We compared the measured distributions without
setting a numerical acceptance threshold for control latency.

## Recommendation

Keep `AgentInvoker` and take this scheduling change into the next sealed GPI2
CPU qualification. Median control latency and burst throughput improved across
all three pairs. On the instrument, record control CPU during bursts, Ready and
Running transitions, each Quit effect and the terminal acknowledgement while the
science graph runs. That test can distinguish a quiet-owner polling delay from
delay in an effect or its provider. A native readiness wait would add descriptor
lifetime, local wakeup and deadline handling. Revisit it if instrument measurements
show the idle polling cost or deadline overshoot exceeds the control CPU or timing
budget. [Prior installed GPI2 shutdown evidence](../rtc-0722-gpi2-classic-20261116/README.md)

## Measured control traffic

Three interleaved pairs ran on a shared Ryzen 7 6800H host. Each arm used
a fresh private daemon and a warmed session in settled Fault with its
declared source absent. A separate client alternated typed Status and Groups
requests. The light schedule targeted 100/s. Bursts contained 32 requests
sent one at a time, with a 20 ms gap between bursts. All 9,216 timed
requests returned their expected reply with consecutive tokens. Each arm
contributed 1,536 light and 3,072 burst requests. Latency runs from public
client invocation to typed acknowledgement. Percentiles below use nearest
rank on pooled requests. Ranges span the three runs per arm.

| Metric | Unconditional sleep | Agent idle and yield |
| --- | ---: | ---: |
| Light p50 / p99 / maximum (ms) | 3.886 / 7.700 / 34.980 | 1.762 / 6.954 / 36.918 |
| Burst p50 / p99 / maximum (ms) | 4.502 / 8.743 / 30.507 | 2.390 / 6.059 / 23.356 |
| Burst acknowledgements/s, including quiet gaps | 188–190 | 306–324 |
| Quiet session CPU (% of one logical CPU) | 2.86–3.34 | 3.03–3.77 |
| Quiet scheduler timeslices/s, all session threads | 469–471 | 456–468 |
| Deadline to owner clock sample on expiry turn (ms) | 0.718–18.141 | 0.377–32.920 |
| Deadline to completed fault transition (ms) | 0.732–18.165 | 0.395–32.946 |
| Deadline to settled fault after compensation (ms) | 12.612–29.165 | 7.116–37.539 |
| SIGINT to observed exit with a request pending (ms) | 80.0–92.8 | 64.8–112.7 |

All six SIGINT runs acknowledged the outstanding Status and exited zero.
In a separate public-launcher check during startup, sending SIGTERM after
the Status and Groups acknowledgements terminated both baseline and candidate
by signal 15. Neither completed the graceful-exit assertion. The installed
session unit uses a public stop hook and specifies SIGINT. Direct SIGTERM
remains a separate shutdown issue. [Signal diagnostic](SIGTERM.md) · [Installed unit](../../../assets/deployment/pipewireao-session@.service.in)

The quiet CPU ranges overlap. The scheduler counts are a proxy for wakeups.
The owner still polls a Julia timer when idle. Three deadlines per arm and a
shared Linux host give too little evidence to establish a deadline-tail
improvement. The largest observed expiry overshoot occurred in the candidate.
The [benchmark method and traces](METHOD.md) retain individual request timings,
generator timestamps, session CPU counters and source hashes.

| Pair | Run order | Baseline trace | Candidate trace |
| --- | --- | --- | --- |
| 1 | Baseline then candidate | [Run 1](baseline-1.tsv.gz) | [Run 1](candidate-1.tsv.gz) |
| 2 | Candidate then baseline | [Run 2](baseline-2.tsv.gz) | [Run 2](candidate-2.tsv.gz) |
| 3 | Baseline then candidate | [Run 3](baseline-3.tsv.gz) | [Run 3](candidate-3.tsv.gz) |

## Functional verification

On Julia 1.13.4 with one default thread and zero interactive threads, the
[private-core selector](../../../test/media_session_private_core.jl) kept
a native event ready while a Julia task requested shutdown. The task ran
before the native source exhausted its 32-dispatch budget and the session
returned zero in `Offline`. The [host selector](../../../test/media_session_host.jl)
advanced a cached clock to the deadline of a submitted update on a quiet
core. That turn scheduled source Hold and reported positive work. A second
attempt to schedule the same effect returned zero.

In a disposable copy we removed the productive-turn yield and omitted new
effects from the work count. The same shutdown test then observed dispatch
32 of 32 before the Julia task ran. The deadline test saw a zero work count
on the turn that scheduled source Hold. Both assertions passed with the
candidate. The 80 private-core assertions and 1,512 assertions across the
other nine focused selectors passed. The full RTC suite also passed 10,612
assertions on Julia 1.13.4 with the matching JLL prefix. It includes several
of the focused selectors, so the assertion counts overlap.

The public process selector exercised an admitted Quit during startup, SIGINT
and loss of the publisher. The other focused selectors exercised ingress,
effects, object and Link ownership, transport and cold acquisition shutdown.
The deliberate disconnects in the host selector emitted the expected injected
operation and source Hold failures. [Session integration checks](../../../test/integration/README.md#current-julia-session-policy-checks)

A separate one-thread scheduling probe kept a PipeWire event continuously
ready and used the candidate's interrupt guard, idle strategy and productive-turn yield
around a native iteration. A same-thread `@async` task waiting on Julia's libuv-backed 10 ms
timer woke in 10.32–10.66 ms across four warm trials. Each trial completed
4,867–5,197 productive turns with zero empty turns. This checks scheduler
progress under continuous readiness on this Julia version.

Reproduce the focused checks from the candidate checkout with the locked
project and the matching native artifact.

```sh
julia --startup-file=no --threads=1,0 --project=. -e '
using PipeWireAO
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
include("test/test_media_session.jl")
for selector in ("controls", "ingress", "effects", "transport", "objects", "host",
                 "acquisition_private_core", "process", "private_core")
    include("test/media_session_" * selector * ".jl")
end'
```
