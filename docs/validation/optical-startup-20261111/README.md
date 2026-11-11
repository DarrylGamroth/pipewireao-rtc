# CAL2 and SPIDERS CPU startup

Private PipeWire cores, Julia 1.13.3, PipeWireAO 4.0.2,
FilterGraphPipeWire 0.5.5, and the CPU simulation backend. The validation
packages used exact registered-style package trees from a private depot.
GPI2's operator session and port 8080 were stopped throughout. CAL2 used
its separate composed CPU test plant.

## Startup and control

On RTC 0.7.9 with HIL 0.5.1, SPIDERS fitted dual took 481 seconds from
launch helper entry to Ready, including installation. The helper spent
10 seconds compiling in its own process. The Start request completed
Running in 2.1 seconds, but the following fresh Status failed. The RTC
then faulted when a Status controller disappeared.

An independent native trace of the same failure recorded 36.8 seconds
between the source mailbox receiving Status and publishing its reply.
The RTC's effect deadline was 5 seconds. Compilation accounted for about
2 seconds of that interval. The source consumed requests between complete
optical duties. AOS 0.3.23 and HIL 0.5.2 service controls at cooperative
CPU propagation checkpoints. The RTC separately treats abandoned
read-only Status as a failed observation and preserves fault compensation
for uncertain mutations. The new ingress assertions fail on the prior
gate for both expiry and loss of the requesting controller.

The first CAL2 test-plant composition rejected conflicting affinity for
the shared native data loop. Exporting both halves with the same
`rtc-data-loop` and `telemetry-loop` settings resolved the configuration
error. CAL2 optics and both controller owners were placed on separate
physical CPU cores from SPIDERS.

## Measured startup phases

Phase wall times overlap across owners. Julia's compilation counter can
aggregate compiler work across threads and should not be added to elapsed
wall time. Fresh imports with previously populated package caches took
approximately 0.4 s for RTC, 1.1 s for FilterGraphPipeWire, and 2.0 s for HIL.

| Phase | SPIDERS | CAL2 |
| --- | ---: | ---: |
| RTC control dispatch preparation | 25.6 s | 35.1 s |
| FilterGraph controller preparation | 64.9 s | 9.5 s LLOWFS, 12.8 s SCC |
| FilterGraph controller warmup | 10.5 s | 1.1 s LLOWFS, 2.4 s SCC |
| Optical model preparation | 174.4 s | 161.0 s |
| Optical warmup | 35.4 s | 136.3 s |

From the systemd start request to Ready, SPIDERS took 390 s and CAL2
took 565 s. These times exclude instrument export and installation. The SPIDERS controller
also spent time between graph preparation and warmup before its PipeWire transport was ready. The simulator's optical preparation and
warmup were the longest measured phases.

## Browser observations

Chromium used the WASM review build of the shared GUI and the existing
bridge over loopback HTTP. Real workspace clicks selected each view.
For each listed feed, the browser received two increasing publication
sequences. SPIDERS filtered SCC frames matched the requested optical
classification, and browser RTC status was fresh Running. The browser build from GUI commit
`8739a47` matches the source tree of main at `6e01aad`.

Source candidates were RTC `c2cfc68`, HIL `7de7a49`, and AOS 0.3.23
tree `6728b50637dfa621f1af9cabbf2a8b3ce2b135ce`. The focused RTC
suite passed 1,251 assertions and the HIL optical execution and publication
suites passed 133. A private CPU software run does not qualify hardware
or real-time cadence.

| SPIDERS panel | Publication sequences |
| --- | --- |
| SCC fringed | 1 → 3 |
| SCC unfringed | 4 → 6 |
| SCC pair status | 6 → 7 |
| SCC modal residual | 7 → 8 |
| LLOWFS tip/tilt | 8 → 9 |
| LLOWFS nominal image | 9 → 10 |
| LLOWFS flux | 10 → 11 |
| LLOWFS validity | 11 → 12 |
| CRED2 ROI | 16 → 17 |
| LLOWFS CoG offset | 17 → 18 |
| BAX307 demanded map | 18 → 19 |

| CAL2 panel | Publication sequences |
| --- | --- |
| LLOWFS optical intensity | 1 → 2 |
| LLOWFS modal residual | 8 → 9 |
| LLOWFS requested tweeter offset | 14 → 15 |
| SCC optical intensity | 1 → 2 → 5 |
| SCC chopped pair status | 2 → 6 |
| SCC modal residual | 2 → 6 |
| SCC requested tweeter offset | 6 (single browser sample) |
| Tweeter adopted command | 64 → 66 |

The CAL2 browser used a temporary copy of the component view config with
the composed session label `gpi2-cal2-testplant`. CAL2 published only two
SCC exposures and one pair by the time its upstream pupil source reached roughly 100
samples. A later browser attachment received SCC exposure 5, and the
pair-derived feeds next published sequence 6. The raw and pair sequence
skips existed in the source feed. AOS invalidates incomplete optical
integration windows on input discontinuities. The browser observations
do not establish the cause of every skipped input or guarantee continuous
SCC cadence on this CPU profile.

### CAL2 time to Ready

| Time since systemd start | Event |
| --- | --- |
| 0:39 | Optical owner started |
| 1:36 | Optical owner finished loading simulation packages |
| 2:28 | Optical model preparation began |
| 5:08 | Optical model prepared |
| 5:26 | Optical warmup began |
| 7:42 | Optical warmup finished |
| 9:01 | Final optical transport preparation began |
| 9:25 | RTC admitted and Ready |

Julia reported 125 s of compilation in optical model preparation and
85 s in warmup. The 79 s from warmup completion to final transport
preparation is a separate interval. The phase logs do not attribute that
interval to compiler versus other setup work.

## Shutdown

SPIDERS acknowledged native Quit and cleaned up its private service cohort.
CAL2 attempted native Quit once. The RTC logged an expired session effect and
lost its owner proxy before the client received a completion. The retained
ledger reported `systemd_quit.accepted=false`, `cleanup_complete=true`, and
`unit_files_removed=true`. Both private services and browser listeners were
stopped. The CAL2 Quit deadline remains a separate failure.
