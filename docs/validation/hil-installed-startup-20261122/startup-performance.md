# Parallel service startup and measured changes

## GPI2

The deployed simulator, graph and parameter owners have distinct systemd
units in the same invocation. The prepare command starts the private core,
verifies its identity and connects to its Unix socket before it starts those
owners together. HIL publishes a cancellable Preparing endpoint before
constructing optics. The long-lived RTC coordinator starts once its
invocation-specific configuration and process bindings are available. It
waits for real owners, realizes its declared Links and confirms admission.

On the first GPI2 run, moving the simulator to the instant of core process
creation could have advanced its launch by at most 7.1 s. The simulator
connected 74.4 s before service Ready. On the later ordinary invocation
the core-to-simulator launch gap was 1.2 s. CAL2's corresponding upper
bound was 5.1 s. The bounds include work to make and verify a real socket.
The separate systemd services already overlap optical work with graph
preparation. [Per-profile startup events](startup-times.json)

The GPI2 experiments used the same installed CPU simulation, calibration,
Julia 1.13.4 executable and released RTC 0.7.28. Each invocation started
fresh processes on a new private core. The earlier 219.9 s run happened
during other installation work. The following trials used populated caches.
The ordinary setting uses Julia's default optimization. The candidate uses
`-O0` for the short-lived systemd `prepare` and `publish` Julia commands.
It preserves the long-lived RTC and scientific owner arguments, native
admission checks, and the normal Stop, Status and Quit paths.

| Trial in execution order | Core exec | Simulator exec | Whole service Ready |
| --- | ---: | ---: | ---: |
| Ordinary retry | 5.7 s | 6.9 s | 61.8 s |
| Startup helpers at `-O0` | 3.6 s | 4.4 s | 55.7 s |
| Ordinary repeat | 6.1 s | 7.3 s | 63.1 s |
| Installer-generated candidate launcher | 3.5 s | 4.3 s | 54.0 s |
| Generated launcher with publication helper on CPU 14 | 3.4 s | 4.2 s | 49.7 s |

All times start at service activation. Each GPI2 trial delivered detector
frames and all three command vectors, returned to Ready on Stop, and
acknowledged Quit. The generated launcher also completed the fitted-single
SPIDERS lifecycle with Ready at 34.7 s. The receipts identify the native SDK
and the actual installed optical and receiver libraries. [Run receipts](startup-experiments.json)

The GPI2 host profile places the coordinator, the graph leader, the private
core leader and the publication helper on CPU 3. Linux scheduler counters
show the publication helper's main thread accumulated 9.21 s of CPU time
and 27.54 s runnable in the ordinary repeat. The generated launcher
recorded 5.49 s on CPU and 22.08 s runnable. Moving only the publication
helper to CPU 14 recorded 4.01 s on CPU and 0.13 s runnable. That change
advanced Ready by 4.36 s compared with the generated-launcher trial on
CPU 3. The simulator continued preparing concurrently. The data establish
the timing on this workstation. A deployment that separates helper placement
can use an explicitly selected management CPU in its host profile.

A separate, side-effect-free validation intercepted the systemd reload and
compared three fresh processes per optimization level on CPU 14. Median
elapsed times to that boundary were 6.548 s at the ordinary setting,
4.957 s at `-O1` and 3.586 s at `-O0`. The arms loaded the same native RTC
package cache and produced the same reserved roles and core fragment.
The service trials above exercised the real reload and native admission.
[Scheduler samples, journals, launchers and offline reproduction](startup-experiments.tar.gz)

To repeat the managed comparison, install the same sealed application into
`installs/gpi2` beside the extracted scripts, using the verified fresh-depot
layout. Set `repo` in `managed.py` to the local RTC checkout that contains
the flow observer and control driver. The archive retains the original
journals from all four profiles.

The candidate RTC installer passed 294 installation, relocation and sealing
checks, including both supported launcher forms and a modified launcher.
The focused launcher and stop tests passed 27 checks. On the first installer
run the CLI smoke test reached its 180 s timeout during cold package-cache
creation. Precompiling the candidate in the private depot let the selector
complete with the original timeout. The service measurements above used an
installed optical image and populated package caches.

## CAL2 optical warmup

The deployed CAL2 service spent **302.8 s** warming its CPU optical execution.
It fed ten identical 2 ms synthetic pupils through LLOWFS and the two SCC
chopper phases. An offline experiment used fresh Julia processes, identical
installed images and equally seeded private PoCL caches. It retained
LLOWFS, fringed SCC and unfringed SCC intensities for reuse only across the
known-identical synthetic pupils. Both arms integrated the same ten time
intervals and checked for cancellation. Both used the ordinary acquisition
code on varying pupils after reset.

| Same-host offline test | Ordinary | Fixed-pupil prototype |
| --- | ---: | ---: |
| Synthetic warmup | 226.335 s | 42.155 s |
| LLOWFS / fringed SCC / unfringed SCC propagations | 10 / 5 / 5 | 1 / 1 / 1 |
| PoCL compiler invocations | 2 | 2 |
| Time for first five varying inputs after reset | 115.612 s | 100.519 s |

The prototype saved 184.180 s (81.4%) in the **synthetic warmup**.
All 12 synthetic buffers and six subsequent complete varying-pupil buffers
were byte-identical, including timing, sequence and trigger metadata.
Every one of the nine ordinary repeat inputs ran without new PoCL
compilation. Identical replay work differed in elapsed time across the two
arms. The managed CAL2 installation still uses the ordinary optical path.

The experiment uses private optical graph internals to isolate the repeated
propagation. A production implementation belongs behind a transport-neutral
AdaptiveOpticsSim operation that knows which graphs are deterministic for
a fixed input. HIL can then request that operation for its quiet synthetic
warmup and keep the ordinary feed for real inputs. The version under test
supports the measured CAL2 CPU configuration only. [Probe, complete buffers and numerical comparison](cal2-warmup.tar.zst)

To reproduce the numerical experiment, extract the archive beside a scratch
`installs/cal2` directory containing a freshly installed application from the
candidate registry. From the extracted `optics-study` directory, run
`bash run-cal2-ab.sh 14,15 5` on this host. The Julia script compares all
serialized frames and metadata. The run records the Julia and FFTW thread
counts, CPU target, phase times, allocations and PoCL compilation deltas.
