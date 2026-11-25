# GPI2 native Quit deadline and startup measurements

RTC 0.7.8 reached Ready in 516.36 s on the managed GPI2 CPU profile.
The simulator later reported an expired bootstrap owner ticket. The RTC
reported an expired session effect and the stop hook retained an unknown
outcome. Emergency cleanup removed the private core and owners.
[Release verification](../rtc-078-20261110/README.md)

## Diagnostic results

Two private-core probes used the same dependency closure and host file
as the release test, with temporary source instrumentation. The first
probe used Julia I/O from the bootstrap monitor. The controller blocked
in that logger while its main thread was in PipeWire, so this probe
cannot establish the cause of the release failure. The second used a
small direct write to the service journal and acknowledged Quit.

In the second probe, native Quit took 3.93 s from RTC dispatch to its
publication fence. The RTC's cumulative compile counter advanced
1.28 s in that interval. It took 0.469 s to reach the first bootstrap
owner after entering ShutdownOwners, with 0.466 s recorded as Julia
compilation. The simulator took 0.485 s from entering cleanup to writing
its final report. The report itself took 8 ms after transport closure.
The original release logs establish the simulator's ticket expiry but
lack the detail to assign every part of that run's elapsed time.

The native session Quit ticket, the declaration-order check and the
bootstrap monitor's Quit route cross abstract dispatch boundaries. The
trial patch precompiled those concrete routes before accepting commands.
The existing Hsm, source-first order, correlated replies and shared
five-second effect budget still govern shutdown.

## Time to Ready

The second trace reached Ready in 634.89 s. The owners prepared
concurrently, so their wall and compilation times cannot be summed.
The compile counter measures process-local cumulative compilation,
including work on multiple threads. Values can exceed the wall interval.

| Interval in the second trace | Wall time | Julia compile counter delta |
| --- | ---: | ---: |
| Controller bootstrap Ready to Prepared | 555.67 s | 562.36 s |
| Simulator bootstrap Ready to Prepared | 297.43 s | 253.79 s |
| RTC waiting for ConnectOwners | 411.84 s | 6.94 s |
| Simulator science preparation within its owner interval | 42.56 s | 38.21 s |
| Simulator diagnostics warmup and frame preparation within its owner interval | 16.24 s | 17.66 s |

First-use compilation dominated the controller's startup path in the
trace. The same interval also includes instrument setup and graph
warmup. Service preparation, owner registration, Link negotiation and
admission consume wall time as well. These measurements describe the
traced application. The original 516.36 s run had phase timestamps
without compilation counters.

## Registry-only trial

The uninstrumented trial used Julia 1.13.3 and an initially empty depot
with General and a disposable copy of DarrylGamrothRegistry. The local
registry entry labeled the candidate RTC 0.7.9 and selected source tree
`ac2a037115ba3ca85d784ae4b5d8b9ddb2916300`. The resolved GPI2 Manifest
differed from the failed release run only in the RTC entry. Its SHA-256
was `69bb6015f3cc3cbe8ab822060de584d058bcd51fbfb71391e627be44ee44fa43`.

The full core suite passed 10,851 assertions. The focused session selectors
passed 1,255 assertions, and the ordinary bootstrap private-core selector
passed 51. The candidate reached Ready in 640.29 s against the original
900 s budget and entered Running.

The installed systemd hook attempted one native Quit. The simulator
exited, but the controller reported an absolute deadline expiry and the
parameter owner reported that its retained controller had been revoked.
The RTC reported an expired effect. The stop hook retained
`systemd_quit.accepted=false` and systemd reported failure. Emergency
cleanup removed the private socket and stopped the session and all four
owners. The service logs recorded no SIGKILL.

The precompilation trial is insufficient and remains outside the committed
changes. The remaining measurement is a failing-run timeline that retains
the exact session deadline and each owner's request receipt, cleanup,
terminal publication and Core synchronization timestamps. It should use
bounded in-memory records emitted after the effect to avoid the logging
interference seen in the first probe.
