# GPI2 native Quit admission clock

The [RTC 0.7.8 release check](../rtc-078-20261110/README.md) reached Ready in
516.36 s. The simulator's native Quit ticket and the RTC shutdown effect
expired. Emergency cleanup removed the four owners and the private core.

## Released shutdown path

The managed GPI2 CPU profile ran on a private PipeWire core with the same
registered dependency closure and host configuration as the release check.
Temporary probes in RTC 0.7.8 recorded monotonic timestamps, deadlines and
Julia compilation counters in preallocated, memory-mapped buffers per
process. Shutdown records used atomic slot reservation and no log writes.
The HIL package was unchanged. This probe reached Ready in 452.24 s.

The RTC used the duty-cycle timestamp **1,010,502,690,462,125 ns** to
calculate the shared five-second effect deadline
**1,010,507,690,462,125 ns**. At the Hsm handler, only **4.3908 s**
remained. The earlier ingress path had already consumed **609.2 ms** of
the effect budget. The client's deadline was
**1,010,510,690,060,133 ns** and was later than the effect deadline.

Times below are seconds since the RTC admitted Quit. Owner receipt comes
from the native ticket. Owner-local deadlines are absolute monotonic
nanoseconds. RTC observed each owner's completion before sending the next
owner request, while the owner's completion fence could finish later.

| Owner | RTC sent | Owner received | Owner dispatched | Cleanup done | Reply staged | RTC observed | Owner fenced | Owner-local deadline (ns) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Simulator | 1.8634 | 1.8645 | 2.3171 | 2.7239 | 2.7514 | 2.7584 | 2.8568 | 1,010,507,692,451,396 |
| Controller | 2.7630 | 2.7652 | 2.9930 | 3.1191 | 3.1436 | 3.1513 | 3.2217 | 1,010,507,693,240,310 |
| Parameters | 3.1559 | 3.1581 | 3.3859 | 3.6995 | 3.7286 | 3.7398 | 3.8884 | 1,010,507,693,178,535 |

The RTC spent 492 ms between entering ShutdownOwners and the first
owner's retirement check, with 489 ms recorded by its Julia compilation
counter. The final RTC completion fence finished 4.3747 s after admission,
with **16.0 ms** left. This run acknowledged Quit and confirms the stale
timestamp defect. The original release failure has no per-owner trace.

## Reproduced native Quit failure

A controlled test on the same RTC 0.7.8 path inserted a 1.25 s delay at
native ingress before Hsm admission. This exercised the stale timestamp
while leaving the five-second budget and client deadline logic intact.
The first attempt stopped during simulator optical worker preparation
and produced no native Quit measurement. The retry used a new private
core, reached Ready in 575.67 s, and entered Running.

The cached timestamp was **1,012,824,291,052,763 ns**. The RTC admitted
Quit at **1,012,826,160,078,465 ns**, set the effect deadline to
**1,012,829,291,052,763 ns**, and had **3.1310 s** left. The client's
deadline was **1,012,832,290,545,652 ns**. The controller was the pending
owner when the RTC observed expiry at 3.1392 s, 8.2 ms after the
shared deadline.

| Owner | RTC sent | Owner received | Owner processed ticket | Cleanup done | Reply staged | RTC observed | Owner fenced | Owner-local deadline (ns) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Simulator | 1.8835 | 1.8857 | 2.3648 | 2.8798 | 2.9037 | 2.9135 | 3.0009 | 1,012,829,310,369,056 |
| Controller | 2.9192 | 2.9204 | 3.1569 | 4.3674 (fallback) | — | — | — | 1,012,829,294,285,549 |
| Parameters | — | — | — | 5.3515 (fallback) | — | — | — | — |

The controller reached its ticket 22.7 ms after its local deadline and
never dispatched native Quit. The RTC sent no Quit to the parameter
owner. The installed stop hook retained an unknown result after the
owner proxy disappeared. Emergency cleanup removed the four owners and
private core. This reproduces a failure due to the shortened effect
budget under a controlled ingress delay. The original 0.7.8 expiry
occurred on the simulator ticket, with no trace to apportion its delay.

## Startup compilation

In this trace, the controller took 371.72 s from bootstrap Ready to
Prepared, with a 380.10 s increase in its Julia compilation counter. The
simulator took 286.09 s with a 251.97 s increase. While the RTC waited
224.00 s for ConnectOwners, its own counter increased by 6.57 s. The
processes prepare concurrently. Each counter sums compilation across
threads, so a counter can exceed wall time and the two cannot be
subtracted to compute non-compilation time.

The controller's process-time compilation includes specialization for
the concrete GPI2 graph. Preparation explicitly requests some of that
compilation and triggers more when it exercises the graph. This occurs
after systemd starts the service and is separate from Pkg building
reusable package caches during export. The overall service interval also
includes owner setup, the native PipeWire core and Link negotiation.
The [previous trace](../gpi2-quit-deadline-20261110/README.md) observed
the same startup pattern in a longer run.

## Fix and registry-only verification

The RTC now samples the monotonic clock when it dispatches the Quit
event into the session Hsm. All shutdown effects keep one absolute
deadline, the earlier of the client deadline and five seconds after
admission. Other work in the duty cycle still uses its cached timestamp.
The deterministic regression advances the cached clock beyond the old
deadline, then checks completion within the new shared deadline and a
second case with an earlier client deadline.

The core suite passed 10,930 assertions, including 86 in that regression.
The managed GPI2 CPU check used Julia 1.13.3 and an initially empty depot.
Pkg installed all dependencies from General and a disposable copy of
DarrylGamrothRegistry. The disposable registry labeled the candidate RTC
0.7.9 and pointed to Git tree `88f05f1f485b08f1fa0fada7edb0b776e89d7e05`.
The runtime and regression sources match commit `7771e71`; the candidate
also has temporary version metadata. The application Manifest differs
from the 0.7.8 release check only in the RTC entry. Its SHA-256 is
`06485ab005a920d322683c6306833c1f7d0c12eba26e6768c084393c36bd964f`.
Installed Project and Manifest bytes matched export. Package trees and
the native SDK and queue artifacts were checked against the registry
entries, with no SDK overlay or development path dependencies.

Dependency installation took 4m49s. Export and package cache building
took a separate 8m58s. The installed private-core systemd service reached
Ready in 504.04 s within the 900 s budget and transitioned to Running.
The runtime and three Julia owners used the fresh depot. The installed
stop hook attempted one native Quit and recorded its acceptance. All
four owners and the session exited, the private socket and unit files
were removed, and systemd reported success. The service and owner logs
recorded no SIGKILL. The full stop and reconciliation took 83.13 s.
This includes the stop hook and service cleanup outside the five-second
native effect. The candidate run had no timing probes in the effect.
PipeWire logged format and mixer warnings during startup and a missing
optional SPA DBus library. The exact session admission and Quit checks
completed on the private core.
