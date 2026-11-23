# Sealed CAL2 fixed-pupil warmup

## What changed

AdaptiveOpticsSim now owns synthetic external-pupil warmup. For an eligible
CPU optical graph it retains the first intensity from each phase of a fixed
pupil and integrates all ten 2 ms inputs through the ordinary exposure path.
It checks for cancellation at each input and resets scientific state on
completion or failure. Changing the input disables reuse for the rest of
that warmup. Graphs with state, shared buffers, detector responses or
unsupported execution use the ordinary path. HIL supplies the zero-OPD,
unit-amplitude pupil, encodes completed exposures through the quiet emitter
and clears the transport buffers. Live acquisition uses the original
external-pupil step.

The candidate scientific tests include a graph whose intermediate output
aliases another sensor's pupil input. An earlier implementation changed the
second camera exposure in that case. The corrected eligibility check
detects the overlapping storage and reproduces the ordinary exposures.
The final focused AOS run passed 216 checks. HIL's preparation, acquisition,
control and clocked-source selector passed 103 checks with Julia 1.13.3.

## Sealed applications

| Package or asset | Ordinary | Fixed pupil |
| --- | --- | --- |
| AdaptiveOpticsSim | 0.3.29 | 0.3.30 at `e6b157e0` |
| AdaptiveOpticsSimPipeWireHIL | Private 0.5.12 | 0.5.13 at `c5f04a3` |
| CAL2 sealed export commit | `03aea6055dd96948f5d44402cb8cc517044de4c4` | `c9ca7fcb56ca321d2d8d62c4d4320c8c3148b7ac` |
| Application manifest SHA-256 | `2f38ee6b9610c948cd99a040ea796aed8ff5555b70388f08923e80c6eed26896` | `dbf44bb44e84c7037cbbaf0670399663fb837d999687a5e480a3ce3dd5a3f678` |

The paired applications use Julia 1.13.3, RTC 0.7.28, PipeWireAO.jl 0.9.6
and PipeWireAO_jll 4.0.8+0. The private candidate registry at `6b49876e`
resolves the exact source trees. Comparing the sealed exports found identical
content for 477 of 479 files, including calibration, optical definitions,
graphs, deployment and launchers. Only the package Project and Manifest
changed, with 198 other dependency records identical. The service comparison
uses the RTC 0.7.28 launcher in both arms.

## Optical reference

The [installed-image verifier](verify_optical_outputs.jl) compares complete
Float32 buffers, shapes, sensor names, timestamps, exposure durations,
sequences, generations, sampling and chopper/trigger metadata directly to
the [ordinary CAL2 reference buffers](../hil-installed-startup-20261122/cal2-warmup.tar.zst).
It exercises the production HIL warmup with a recording emitter, then calls
the ordinary input path on five changing pupils after reset. Run it with the
candidate application's installed startup package on the Julia load path
and its optical depot first. Its two arguments are the installed application
directory and the extracted `ordinary` reference prefix.

The installed candidate matched all 12 synthetic exposures byte for byte with
one propagation each for LLOWFS, fringed SCC and unfringed SCC. All six
post-reset outputs from five varying pupils matched the ordinary reference.
The verifier also checked the cleared buffers and the new acquisition
generation. [Per-exposure hashes and graph counts](optical-outputs.txt)

## Full sealed service on rtc-devel

Both arms used the ordinary RTC 0.7.28 installed unit, the same CPU
assignments and a matched initial PoCL cache. Each launched a fresh private
core, both calibrated controllers, the optical simulator and the RTC.
Reported elapsed times are wall seconds on a shared workstation. Each
measurement is one activation per arm.

| Interval | Ordinary | Fixed pupil |
| --- | ---: | ---: |
| systemd start to native Ready and publication | 419.839 s | 89.696 s |
| Simulator optical warmup | 382.702 s | 44.994 s |
| Julia compile counter during optical warmup | 3.522 s | 1.908 s |
| Service elapsed time outside optical warmup | 37.137 s | 44.702 s |
| SCC controller graph preparation (compile counter) | 0.741 s (0.638 s) | 0.602 s (0.518 s) |
| LLOWFS controller graph preparation (compile counter) | 0.900 s (0.808 s) | 0.909 s (0.776 s) |
| Service elapsed time by completion of both controller warmups | 20.291 s | 18.020 s |

The fixed pupil reduced service time to Ready by 330.143 s (78.6%) and
simulator optical warmup by 337.708 s (88.2%). The latter exceeded the
service saving because the other parts of startup took 7.565 s longer in
the candidate. Controller graph warmup itself took at most 3.1 ms in either
arm. The Julia counters report work within the logged phase. They exclude
work during process launch and package-image loading. The warmup and Ready
figures are separate from installation and from live optical propagation.

## Live optical and controller comparison

Under native Start both installations received the same 30 timestamped 2 ms
pupils. Every one of the 71 resulting Float32 buffers matched byte for byte.

| Stream | Shape | Buffers matched |
| --- | --- | ---: |
| LLOWFS camera | 224 × 224 | 30 |
| LLOWFS physical offset | 2,304 | 30 |
| SCC camera | 256 × 256 | 6 |
| SCC physical offset | 2,304 | 5 |

Sequence, model PTS, duration, generation, reference clock type and chopper
state matched. Each run generated its own acquisition UUIDs and sampled its
own host reference timestamps. The comparison retains the original metadata
and excludes those run-specific values from equality.
[Per-stream hashes and exact sequences](live-optical-comparison.json) ·
[Per-process startup phases](paired-phases.json) ·
[Raw payloads, lifecycle receipts, journals and reproducer](paired-managed.tar.zst)

Both services acknowledged Stop and the observer confirmed a quiet interval.
The ordinary service acknowledged native Quit. The fixed-pupil service timed
out during Quit, and systemd reported a failed unit. Emergency cleanup
removed its private socket and all five original processes. The journal
reported an expired session effect and an expired simulator owner request.
It did not identify the specific effect that exhausted the deadline.

A separate invocation of the same candidate reached Ready in 68.703 s and
acknowledged Start, Stop and Quit. Native Quit took 7.411 s. Systemd recorded
a successful exit and all five processes exited. This retry used the same
deadline settings and omitted pupil injection. The cause of the earlier
timeout remains unresolved. [Focused lifecycle receipts](focused-quit-retry.tar.zst)
