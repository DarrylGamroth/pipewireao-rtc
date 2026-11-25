# Direct RTC admission through libsystemd and PipeWireAO

Each newly installed direct RTC reads its validated topology from the activation
document. The installer verifies it using the native SPA parser and records the
identity of the configuration loaded by PipeWire. A single connection to the
user systemd manager subscribes before reading unit and service properties.
MediaSession correlates CoreInfo and a native sync reply on its own connection
before creating either RTC control endpoint. It checks service incarnations,
placement, the public Status reply and the held Links before notifying systemd.
A change during the last native check requires fresh service and native proof.
The connection closes after notification or when a failed admission exits.

The RTC uses the host's libsystemd, which it already uses for readiness
notification. Direct attachment needs the public user D-Bus address to work.
PipeWire carries the detector data, controller outputs and RTC commands.
The older Julia Systemd wrapper declares Julia 0.5. The systemd JLL supplies
the library binary. JuliaServices' DBus.jl uses libdbus and its maintainers
describe its API as unstable. [Systemd.jl requirements](https://github.com/yuyichao/Systemd.jl/blob/master/REQUIRE)
· [systemd_jll products](https://github.com/JuliaBinaryWrappers/systemd_jll.jl#products)
· [DBus.jl](https://github.com/JuliaServices/DBus.jl)
· [public systemd D-Bus interface](https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.systemd1.html)

## CAL2 restart on an already-publishing simulator

Three blocks of three starts used the same independent CUDA simulator, private
PipeWire core, retained controller graphs, calibration and CPU placement.
The original used RTC `b24edf9` and the new path used `eb5bf4c`.
Each start launched Julia 1.13.3 with its distribution image and an existing
RTC package image. The operator's start request ran through systemd's
acknowledgement of held Ready. Detach measured a systemd stop request through
successful return. The two frame intervals start at the subsequent native
Start acknowledgement and end at the observer's first usable live result.
SCC requires two exposures. Each cell below is the median of three.
[Individual timings and acquisition numbers](timings.csv)

| Installed RTC | Attach to Ready (s) | Detach (s) | First LLOWFS (s) | First SCC pair (s) |
| --- | ---: | ---: | ---: | ---: |
| Original, before | 5.430 | 2.880 | 0.034 | 4.062 |
| Native queries | 6.387 | 3.561 | 0.301 | 3.677 |
| Original, repeated after | 5.897 | 3.090 | 0.165 | 4.573 |

The new path took 0.490 s longer to Ready and 0.471 s longer to detach than
the later baseline median. The earlier and later baseline medians themselves
differed by 0.467 s to Ready. These shared-host measurements establish the
observed elapsed times. Attribution of the differences to the bus or PipeWire
would require isolating their work. Each accepted trial confirmed ten exact
Links and both integrators open, then observed a nonzero residual and exactly
zero physical offset for each controller. Camera publication continued after
every accepted Quit. The measurements cover CAL2 software HIL.

A separate activation sampled the RTC cgroup roughly every millisecond.
The original sample observed nineteen `systemctl show` children, one
`pwao-dump` and the native SPA parser. The candidate sample observed zero
of those helpers. The placement checks still use `id` and `chrt`, and pinned
Git exports have separate Git checks. Process sampling can miss short-lived
children. The admission code establishes which calls were removed.

Switching the shared validation depot back to the original build produced
**one 167.875 s start**. The running service spawned a Julia package-image
compiler. This trial is recorded separately from the cache-present comparison.
Another original start reached Ready in 6.082 s and systemd stop returned
success, but its exact invocation journal lacked the native Quit receipt.
It is excluded. The operator's original installation subsequently loaded
its package image in a new process with `--compiled-modules=strict`. The
candidate loaded its own image from an isolated depot under the same check. Both RTCs finished
detached. The simulator and retained graph services kept their identities.

The archive contains all nine accepted trials, the two additional baseline
observations, process samples, cache checks, camera trace and offline replay.
Its SHA-256 is
`f3b122a2e5ac4eba62970bf6cdd2dcdf547237107690313974cad3f0c98bb1df`.
[Measurements and replay](cal2-native-admission-eb5bf4c.tar.gz)

## Admission checks

- The private-core test connected the RTC to a healthy but different PipeWire
  daemon. The original session constructor accepted it. A separate registry
  observer recorded both the session and controller nodes. This exercises a
  socket change between the former separate probe and the RTC connection,
  using a different live daemon for the constructor test. The revised
  constructor rejected the daemon before the observer saw either node.
  The selector also exercised a silent socket, missing CoreInfo, a matching
  daemon and withdrawal on close. The 13 assertions include the separate
  managed-cohort probe. [Selector](../../../test/integration/independent_core_identity.jl)
  · [Original failure](core-before.log.gz) · [Passing run](core-after.log.gz)
- The user-manager selector passed 44 assertions using disposable user services
  and an isolated unresponsive bus. It verified exact command argument
  boundaries, empty command arrays, service identity, restart, removal and
  deadlines. In the earlier implementation the silent peer still held a 400 ms
  operation open 1.5 s after accepting the socket. The new client expired the
  operation within its caller's budget. [Selector](../../../test/systemd_bus.jl)

Run these two opt-in selectors from the RTC project with Julia 1.13, a matching
PipeWireAO artifact, and a short temporary path for native sockets. The
user-manager selector needs a working user bus and permission to start
temporary services on CPU 0.

```sh
TMPDIR=/var/tmp julia --startup-file=no --project=. test/integration/independent_core_identity.jl
TMPDIR=/var/tmp julia --startup-file=no --project=. test/systemd_bus.jl
```

The complete RTC suite passed 561 testsets and 11,968 assertions on Julia
1.13.4. The number of assertions in the concurrent snapshot test depends
on how many samples its reader obtains. [Full test log](rtc-full-suite.log.gz)
