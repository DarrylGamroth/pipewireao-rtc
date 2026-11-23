# CAL2 startup with both cameras already publishing

The [timing diagram and phase definitions](phases.md) show how service startup,
controller preparation and numerical warmup overlap.

The [installed CAL2 restart](README.md#cal2-rtc-replacement-with-the-simulator-already-publishing)
reached Ready in 58.287 s on its second activation. The individual graph
journals put the following events on the same monotonic clock as the
systemd service. Times include intervals in which other processes ran.

| Milestone after requesting service start | First RTC | Replacement RTC |
| --- | ---: | ---: |
| Julia graph services started | 32.01 s | 11.04 s |
| RTC process started | 40.71 s | 14.57 s |
| SCC numerical warmup finished | 39.19 s | 19.01 s |
| LLOWFS numerical warmup finished | 39.41 s | 21.08 s |
| Both graph warmups finished to service Ready | 64.57 s | 37.21 s |

On replacement, SCC graph preparation took 0.71 s including 0.61 s of
Julia compilation. LLOWFS preparation took 0.94 s including 0.84 s of
compilation. The services ran concurrently. Completing numerical warmup
still leaves port activation, native admission and publication of Ready.
These intervals do not individually attribute CPU time to those operations.

## Fresh-process deployment preflight

The installed `prepare` command checks the deployment profile and declared
node owners. A focused comparison called that exact preflight twice per
fresh Julia 1.13.3 process using the installed CAL2 project, the same populated
depots and CPU 3. Four launches ran in ordinary, minimal, minimal, ordinary
order. Both compiler modes used the installed helper's `-O0` setting. The
minimal variant added `--compile=min`. Julia's cumulative compilation
counter was enabled for both. The second call used the first call's compiled
methods within that process.

| First preflight call | Ordinary | Minimal compilation |
| --- | ---: | ---: |
| Elapsed time, two processes | 4.37, 3.80 s | 0.58, 0.62 s |
| Julia compile counter | 4.21, 3.70 s | 0.05, 0.08 s |
| Repeat preflight in same process | 0.094, 0.086 s | 0.467, 0.457 s |

The original configuration and validation code ran in all four processes.
The cold and repeat measurements explain why a faster one-shot check can
still be slower for a helper that spends time polling or handling native
callbacks. Only a full launch can establish the effect on service Ready.

## Installed RTC launches and CPU scheduling

The same installed application ran three times on one independently
supervised private core and CAL2 simulator. Both camera observers had
received frames before the first timed activation. The RTC, graph images,
placements, source, admission protocol and configured deadlines were
identical across launches. The two ordinary activations each received ten
fresh Links, passed authenticated Ready, Start and Stop and acknowledged
native Quit. Scientific payload equality was checked in the earlier
[paired optical experiment](../cal2-fixed-pupil-20261122/README.md).

| In execution order | Service start to Ready | Native Start round trip after Ready | Systemd stop including Quit and cleanup |
| --- | ---: | ---: | ---: |
| Ordinary | 190.895 s | 2.711 s | 39.803 s |
| Minimal compilation for prepare and publish | Still awaiting publication at 320.439 s | — | Trial interrupted |
| Ordinary | 37.840 s | 0.930 s | 13.593 s |

The Julia Start round trip includes the client call and uses an already
connected, identity-verified session. Systemd pins the session leader
and its one-shot helpers to CPU 3 in this profile. A 200 ms sampler
read each leader's Linux scheduler counters. The table shows CPU execution
and time runnable on the run queue at the final available sample through
Ready. Whole-process CPU can also include other threads. The RTC and
publication helpers run concurrently. [Linux scheduler counter definitions](https://docs.kernel.org/scheduler/sched-stats.html#proc-pid-schedstat)

| Leader and interval | First ordinary CPU / runnable wait | Last ordinary CPU / runnable wait |
| --- | ---: | ---: |
| Preparation helper before RTC process start | 4.40 / 50.58 s | 4.11 / 4.37 s |
| RTC process start through Ready | 10.47 / 118.59 s | 10.16 / 14.53 s |
| Publication helper through Ready | 3.81 / 62.22 s | 3.92 / 7.82 s |

Preparation ends before the RTC process starts. Together these two leaders
accumulated about 150.3 s more runnable wait in the first ordinary launch,
across a 153.1 s wall-time difference. The RTC leader used about ten CPU-seconds in each
ordinary activation. The previous 58.287 s
activation has no scheduler counters. In a later preflight
comparison with identical settings, CPU 3 took 1.67 and 2.41 s, including
0.70 and 1.31 s of runnable wait. CPU 5 took 1.05 and 1.07 s, including
0.04 s wait each time. This second experiment changes the preflight
process's placement only. No full RTC activation was timed on CPU 5.

The minimal-compilation preparation helper spent 1.56 s executing on its
leader. Its publication helper acknowledged RTC warmup but never reported
Ready during the observation. A diagnostic stack sample was requested
after the elapsed time had exceeded the first ordinary launch. At 320.439 s
the experiment stopped this helper, which had accumulated 60.05 s of CPU
and 201.20 s of runnable wait. Systemd cleaned up the failed activation.
The final ordinary RTC reattached to the same core and simulator. These
measurements support keeping the normal publication helper. For reducing
startup, the measured costs are the first calls in the RTC and helpers and
their competition for the session leader CPU. The published time-to-Ready
criterion still requires current process, placement, Link and native status
evidence after each replacement.
[Reproducer, process counters, native receipts and journal](startup-attribution.tar.gz)

## HEART reference

Four retained loopback runs used the native HEART executor, a 4 × 4 WFS,
a two-actuator mirror and ordinary Linux scheduling. From the first timestamp
inside `hrtRtc`, the successful READY acknowledgement occurred within these
wall-clock bounds.

| Run | READY request sent | Subsequent LOOP request sent |
| --- | ---: | ---: |
| 10 Hz, first | 122.077 ms | 164.023 ms |
| 10 Hz, second | 121.967 ms | 165.337 ms |
| 100 Hz, first | 123.908 ms | 168.978 ms |
| 100 Hz, second | 116.900 ms | 158.695 ms |

The executor logged startup, configuration, matrix loading and the READY
reply. Its reply line has no timestamp. The harness waits for successful
acknowledgement and completion before sending LOOP, which gives the upper
bound. These intervals omit process creation before the first log. WFS
publication starts later. HEART READY starts configured open-loop processing.
The systemd CAL2 measurement starts at the service request and its Ready
precedes the command to start its execution groups. These observations
establish the scale of the delay but cannot establish a speed ratio for
matched instruments.
[Archived HEART runs](https://github.com/DarrylGamroth/AdaptiveOpticsSimPipeWireHIL.jl/tree/fc5bd72f965f786bc12662868337baa2bac8d8da/docs/evidence/heart-timing-20261107)
· [Sequential HEART test commands](https://github.com/DarrylGamroth/AdaptiveOpticsSimPipeWireHIL.jl/blob/fc5bd72f965f786bc12662868337baa2bac8d8da/test/heart_executor.jl)
