# RTC replacement on a continuously publishing private core

The development RTC can admit a source through its data Ports without taking
ownership of its process, acquisition generation or clock. Separate systemd
services own the private core and the publisher. Each RTC retains its own
session identity, controllers and Links.

## Native restart fixture

Three fresh coordinators used the normal RTC launcher and authenticated native
Warmup, Admit, Status, Start, Stop and Quit commands. One synthetic publisher,
one independent observer and a second sink on the RTC-owned Link shared a
private core. The endpoints ran on CPUs 10 and 11 using Julia 1.13.4,
PipeWireAO 0.9.6 and its native SDK. The Julia package cache was populated
before timing. Each RTC opened a new process and session. The observer
owned its own persistent Link.

| Activation | Launch to native Ready | Consecutive frames at the RTC-linked sink while Running |
| --- | ---: | ---: |
| 1 | 8.612 s | 112 |
| 2 | 8.187 s | 118 |
| 3 | 8.288 s | 119 |

With the old process gone, the independent observer received 38 frames during
the first 425.8 ms gap and 11 during the next 127.7 ms gap. Both intervals
had consecutive sequence numbers and 10 ms of model time per sequence. Every
one of the 1,220 frames recorded by the RTC-linked sink matched the observer
by sequence and model time. The observer logged 3,440 frames across all phases
and missed eight sequences outside the two gaps. This fixture establishes
continued publication and receipt by the new session. It has no optical
model, correction graph or instrument timing deadline.

The fixture selects the native `fast` output mode for its two consumers. In a
control run the default reliable output gave frames to the first eligible
consumer. Both Links reported Active, but the RTC-linked sink received zero
frames. Another trial with reference-counted output failed its advancement
check. The delivery claim above uses observed buffers on both Links.
[Reproducer, lifecycle logs and both frame traces](native-restart.tar.gz)

## Installed systemd replacement

Two activations of the installed launcher on a non-actuating fixture reached
Ready in 37.046 and 30.002 s. Both passed native Start, Stop, Reset and Quit.
The RTC-linked sink received 111 and 109 frames in the respective Ready-to-Quit
windows. Each RTC withdrew its Link and discovery record and exited. The core
PID (310144), publisher PID (310150), private socket and observer Link retained
their identities throughout. The observer's sequence advanced from 2096 to
2133 and 4495 to 4540 during Stop. It advanced from 2727 to 2737 and 5023 to
5033 with the respective RTC absent.

The core leader and its two named data loops ran on CPU 10, the publisher on
CPU 11 and the RTC on CPU 9. An earlier fixture omitted the configured native
data-loop threads. The installed admission check rejected that service. A
separate private-core test accepted the actual server PID and rejected the
same socket paired with a different process PID. The final installed fixture
included this early Core identity check. The matching private-core selector
passed three checks. After integrating the upstream shutdown diagnostics at
RTC commit `2728607`, the full Julia 1.13.4 RTC suite passed all 10,724
checks across 516 test sets. The [installed evidence archive](installed-restart.tar.zst)
contains complete unit definitions, immutable candidate patches, lifecycle
receipts, traces, failed attempts and a checksum inventory.

## Independent optical sources

The external-pupil optical test passed 150 assertions. A persistent LLOWFS
observer received frames while the SCC receiver was replaced. After both
receivers disconnected, the source accepted four further input intervals.
New receivers saw LLOWFS sequences 21 and 22 and SCC sequence 11 in their
original acquisition domains and generations at the expected model times.
CAL2 requires its upstream pupil feed to continue for the model to advance.

The fitted-single SPIDERS CPU simulation ran as its own systemd service
without an RTC. Two SCC receivers, separated by eight seconds with no camera
consumer, observed sequences 3 and 5 at model times 20 and 40 ms. The
simulator PID, acquisition domain and generation were stable. The 12 checks
included successful shutdown of the simulator with the private core still
available. The existing managed optical regression passed all 27 checks.
The independent launcher accepts external-pupil and clocked optical exports.
The legacy GPI2 coupled replay still follows its command-driven contract.
[Optical selectors, logs and exact revisions](independent-optical.tar.zst)

## CAL2 RTC replacement with the simulator already publishing

A fixed-pupil CAL2 application ran the actual SCC and LLOWFS controller
graphs with eight native queue modules and ten RTC-owned Links. Before the
first start request, independent observers had already received both cameras
from one warmed HIL process. Both RTCs admitted the same core, source, pupil
feed and camera observers. Each received its own process, session UUID and
ten new Link serials. The RTC-owned graphs loaded their installed package
images in each activation. The installation selected RTC tree
`764219a5109568325223d97dbeaff61758df2976` and HIL tree
`d0354f40493eefc8e3e9597c690df224d12ee566`. This RTC verified the
core PID during admission. The later pre-launch native Core PID check was
exercised in the installed fixture above. The CAL2 timings predate that check
and the upstream shutdown diagnostics.

| Elapsed wall time on the shared workstation | First RTC | Replacement RTC |
| --- | ---: | ---: |
| Service start request to Ready | 103.976 s | 58.287 s |
| RTC MainPID start to systemd active | 63.254 s | 43.669 s |

The following intervals partition the first row, using monotonic systemd
and journal timestamps. Launching the service includes the installed
preparation and publication helpers. Graph owners and the coordinator can
work concurrently within an interval.

| Interval | First RTC | Replacement RTC |
| --- | ---: | ---: |
| Service start request to RTC MainPID start | 40.709 s | 14.568 s |
| RTC MainPID start to publisher waiting for the control endpoint | 24.580 s | 15.766 s |
| Control endpoint wait to publisher waiting for owners and RTC warmup | 5.643 s | 4.794 s |
| Owner and RTC warmup wait to acknowledged warmup | 26.453 s | 15.986 s |
| Acknowledged warmup to service start returning Ready | 6.591 s | 7.174 s |

The second RTC started after the first RTC and all its Links had gone away.
During 86.4 s with the RTC absent, LLOWFS advanced from sequence 22 to 25 and
SCC from 4 to 5. The acquisition domains and generation stayed the same. The
independent core (PID 341891) and simulator (PID 341896) stayed up. These
intervals measure software service startup under shared-host load. The
paced test feed verifies publication across restarts. An optical throughput
measurement would require an independently paced load.

After native Start each RTC received fresh, finite physical offsets from both
controllers. The first RTC observed LLOWFS sequence 10 at model time 18 ms and SCC
sequence 3 at 20 ms. The replacement observed LLOWFS sequence 28 at 54 ms
and SCC sequence 7 at 60 ms. All four carried their respective
camera domains and generation. The simulated profile produced zero correction
demand in these samples.

Both sessions acknowledged native Stop and Quit. Their ledgers recorded
complete cleanup. The first service stop took 51.3 s and the second 41.6 s,
including the systemd stop and cleanup helpers.

After the second service stopped, the observer received LLOWFS sequence 42.
The feeder then staged pupil 43 and waited 200 s for the corresponding LLOWFS
exposure. Its timeout ended the test. All three permanent Links still reported
Active. The feeder waits for LLOWFS before sending the following pupil. The
trace lacks a dequeue receipt at the feeder and receipts for HIL ingress and
publication of that pupil. Delivery after the second shutdown remains
unresolved. The first attempt at this test also exposed a missing metadata
declaration in the SCC probe, corrected before the two timings above.
[Reproducer, journal, traces, package identities and partial outcome](cal2-restart.tar.gz)
