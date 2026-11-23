# MediaSession polling with an installed GPI2 controller

The registered RTC 0.7.28 (`6416ed8`) and the cooperative owner polling
candidate (`5ffcaa7`) each passed two shutdown paths on separate private
cores. The GPI2 CPU simulator used instrument revision `aaa7022`, Julia
1.13.4, PipeWireAO.jl 0.9.6 and native SDK 4.0.8. The two sealed exports
had identical graphs, calibration and Link declarations. A private registry
selected the candidate tree under the same package version. Each invocation
verified the RTC tree behind the image mapped by MediaSession and checked
the simulator and graph owner images in their live processes.

| Shutdown request | Baseline Ready / managed Quit through cleanup | Candidate Ready / managed Quit through cleanup |
|---|---:|---:|
| Stop → Ready, then Quit | 66.22 s / 13.06 s | 63.14 s / 9.04 s |
| Quit directly from Running | 62.21 s / 11.32 s | 64.35 s / 11.24 s |

In all four runs, the detector and three simulated correctors shared
acquisitions 3, 4 and 5 and continued advancing during both measurement
windows. On Stop the original owners returned to Ready and the four streams
held for at least two seconds. On direct Quit the preceding native Status
reported Running. Each managed Quit was submitted once, acknowledged and
followed by successful retirement of the original processes, socket and
discovery record.

The integrated tree based on `4e4ca63` passed all 10,537 assertions
executed by `test/runtests.jl` on Julia 1.13.4 with the matching SDK.
Its runtime sources matched the installed candidate.

### Operator responsiveness

Each invocation issued 100 paced and 80 burst requests **per operation**.
The queries used one retained client with one request in flight. The
baseline Groups median was 6.76–6.94 ms across the four windows. The
candidate median was 2.50–2.61 ms. MediaSession CPU increased in each
matched window, from 23.87–26.09% to 26.30–27.62% of one logical CPU.
The steady direct-Quit Groups p99 rose from 12.32 to 52.56 ms. Baseline
Status medians varied from 25.85 ms to 472.87 ms between invocations on
the shared host. This supports retaining the owner-task invoker and
cooperative wait for typical operator responsiveness. The experiment
establishes neither a tail-latency bound nor physical correction timing.

### Limits and reproduction

Two initial starts failed before admission with incomplete native startup
caches. A fresh baseline invocation with compatible caches reached Ready
but a cold Groups query expired before Start. Its emergency Quit produced
an unknown outcome. The qualifying four cases used identical preparation
and measured the client after verified science flow. Their external traces
bracket each complete managed Quit. The eight internal effects were timed
in a separate native fixture with synthetic admission and no science owners.

The [archived harness and receipts](gpi2-managed.tar.zst) include both
application manifests' identities, the registered baseline manifest, cache
preparation commands, per-request observations, owner CPU, startup failures
and final cleanup ledgers. Extract into the comparison workspace under
`benchmark-results/gpi2-session-architecture-20261122` and follow
`installed/REPRODUCE.md`. The archive SHA-256 is
`0e71e5ba33c5f2c4eba17cf3f7afde3a1df9e320b8eb90587ccea77b1c73bff2`.
The [earlier private-core trial](README.md) isolates the control duty cycle.
