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
included this early Core identity check. The [installed evidence archive](installed-restart.tar.zst)
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
