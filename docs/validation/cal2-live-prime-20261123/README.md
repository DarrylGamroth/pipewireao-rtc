# CAL2 restart and first live correction

Qualification is an automated test of the installed controller graph with its
actual calibration. CAL2's installer exercises the expected physical-offset
output in both controllers, including the synthetic chopped sequence in SCC.
The normal service restart loads the calibrated graphs, connects the live
ports and reports Ready with processing held. Start begins open-loop
processing. Each controller can accept its own close command after observing
a usable live modal residual. An early close is refused and has to be issued
again. [Operator sequence](../../HIL_CONFIGURATION.md#start-cal2-with-correction-open)

## What came off the restart path?

- Both CAL2 graph services skip the synthetic input, required-output check
  and reset at startup. In the 56.015 s baseline the calls took
  3.13 ms (SCC) and 1.08 ms (LLOWFS), in different processes. The earlier
  58.287 s restart recorded 2.11 ms and 0.73 ms respectively. Both graph
  owners reset the synthetic state before the first live exposure. [Original timing diagram](../independent-source-20261123/phases.md)
- The installed launcher's preparation command formerly read and validated the
  complete deployment and Julia manifest twice in the same process. File-open
  traces show two reads of each file before the change and one afterward.
  The node-owner and placement requirements still apply. In earlier ordinary
  runs, a second call in the same process cost 86–94 ms. The first call's Julia
  compilation cost still exists. [Preparation timing](../independent-source-20261123/startup.md#fresh-process-deployment-preflight)
- Ready does not wait for a camera exposure or a chopped pair. Live evidence
  gates the individual correction close, so an operator can inspect incoming
  measurements before enabling correction.

A larger candidate for removal is the separate Julia process that waits for
the control endpoint, polls the session, verifies placement, sends Admit,
confirms Ready and publishes the discovery record. In two earlier starts
its main thread used 3.81 and 3.92 CPU-seconds and ran concurrently with
MediaSession. Moving that work into the existing RTC process could remove a
Julia startup, a cold profile read and the readiness polling round trips.
The RTC would still need to verify the current owner identities, Links and
placement and announce the exact admitted session. Removing the process
requires an equivalent failure path on owner replacement and Link loss.
Those CPU figures do not predict the change in wall time.
[Process measurements](../independent-source-20261123/startup.md#installed-rtc-launches-and-cpu-scheduling)

## Measurement boundaries

One private PipeWire core and one CPU CAL2 optical simulator run continuously
across the service activations. Independent observers receive both
camera streams before the timer starts. The simulator publishes a 2 ms
model exposure on LLOWFS and a 10 ms model exposure on SCC. Propagating
the optics takes substantially longer than model time on this host. The
static pupil carries a 30 nm astigmatic disturbance to produce a nonzero
signal with both corrections open.

Time to Ready measures the systemd start request through the successful return
after native admission. First usable frame measures the interval from the
native Start acknowledgement to the first calibrated modal residual at the
output observer. The service log also records the Start request and round trip. For SCC this requires two opposite-chop exposures. Matching the
camera and output observations uses acquisition domain, generation, sequence
and model timestamp. Subtracting the two tap times includes scheduling and
observer delays on both sides and can yield a negative difference.

The first correction check verifies zero offset while open, native adoption of
the requested closure, then the first eligible acquisition and its modal
residual. With zero initial state and gain −0.05, the expected first
2,304-channel physical offset is the installed FITS projection multiplied by
−0.05 times that residual. The live trial has no physical actuator sink.
[Captured-camera numerical replay, including the LLOWFS corrupt-header limitation](graph-replay.md)

## Installed RTC restart and first correction

The two full runs started the RTC against the same continuously publishing
simulator. Each RTC reached Ready with both correction loops open and ten
admitted RTC Links. The recorded Start command then enabled frame processing.

| Wall-clock interval | Online synthetic check | Qualification at install |
| --- | ---: | ---: |
| RTC service start to Ready | 56.015 s | 22.665 s |
| RTC service start to Ready, reverse-order repeat | 20.761 s | 22.016 s |
| Native Start request to acknowledgement | 3.066 s | 0.697 s |
| Start acknowledgement to first usable LLOWFS residual | 23.376 s | 20.291 s |
| Start acknowledgement to first usable SCC pair | 201.724 s | 205.104 s |

The two Ready-only repeats started the new application first and the baseline
second, against the same live source with the science output taps detached.
Both reached native Ready with correction open and completed native Quit.
The direction of the timing difference reversed. Removing synthetic frames
from restart simplified the lifecycle. These four activations establish no
repeatable service-start speedup.

On the 22.016 s new-application repeat, the preparation process's main thread
used 3.64 CPU-seconds, the RTC main thread used 10.30 and the process that
publishes Ready used 4.38. Their sampled runnable waits were 0.23, 4.21 and
4.03 s. Preparation precedes the RTC, while publication overlaps it. On the
56.015 s baseline the RTC main thread alone accumulated 21.06 s of runnable
wait compared with 3.90 s on the 22.665 s new-application run. The baseline
sampler missed the preparation interval. The [restart capture](restart-captures.tar.gz)
contains the four scheduler traces, per-owner startup phases, camera records,
native timing and the numerical oracle. Its SHA-256 is
`61be6546a26d8a155c66c1d1b26058c087cc58e06c383654bba05a7ef3246dcd`.
After extraction, `python3 shareable-evidence/scripts/verify-captures.py`
checks the timing, first closed sequences, full-vector equality and source
continuity against the recorded comparison.

LLOWFS produced a nonzero residual and zero correction on its first live
exposure in each run (sequences 30 and 47). SCC withheld its outputs on the
first unpaired exposure (6 and 10) and produced a residual and zero correction
when the opposite exposure completed the pair (7 and 11). The new RTC refused
an explicit SCC close immediately after Start. The owner remained open at
generation zero and accumulated an actual pair before a new close request.

After native acknowledgement of the successful close, both runs yielded
the same signed first correction across every channel. Peak absolute values
refer to projected optical path difference at the graph output.

| Controller | First closed sequence, baseline / new | Peak absolute correction | Largest error against independent projection |
| --- | ---: | ---: | ---: |
| LLOWFS | 41 / 61 | 4.6138595 nm | 3.16 × 10⁻¹⁶ m |
| SCC | 8 / 12 | 0.7490888 nm | 4.79 × 10⁻¹⁷ m |

The oracle checked all 2,304 channels per controller in each run. Each
observed residual, pair-status and physical-offset stream used for these
checks had zero missing or replaced queue arrivals and zero protocol errors.
The baseline observer required a handoff because it expected an explicit
incomplete-pair output and a quiet interval around closure. The native
records show the unpaired exposure, the last open zero offset and the
first subsequent nonzero offset. Matching source, core and camera identities
continued through RTC shutdown and restart.

## First controller callback

Native-buffer replay used the same installed candidate image in both arms,
changing only whether the synthetic check ran in the process before the first
live-shaped input. Three fresh processes per arm replayed archived CAL2 camera
bytes on CPU 15. Times are median microseconds over the three first calls.

| Input | Online synthetic check | Live input only |
| --- | ---: | ---: |
| First LLOWFS exposure | 264.5 µs | 349.1 µs |
| First SCC exposure, waiting for its partner | 227.0 µs | 249.4 µs |
| First SCC exposure that completes a pair | 808.2 µs | 731.1 µs |

The ranges overlap on each row. These measurements include first-use dispatch
and graph execution. The private-core service figures include scheduling and
the wait for actual camera data. The [callback replay](native-callback-replay.md)
gives sample ranges, later callbacks, exact timing boundaries and the
reproduction procedure.

## Software and installation

The comparator used frozen RTC trees at commits
`3f1288077281f8fd2191875b894a3784ff1e3f5e` (baseline) and
`993d4c67` (live priming), with FilterGraphPipeWire 0.5.11 in both
environments. Both use the single-pass launcher. The final RTC implementation
in `53639e9` also rejects a hidden priming port at graph construction and
clarifies the reset documentation. Both CAL2 profiles select their published
modal residual. These runs used the CAL2 graph package images. The RTC native
operator-command work on `codex/native-ndarray-interchange` was outside this
cohort. Its `76c96fb` adds the native SPA NDArray update, `63931b5` prepares
its first use, and `fadea7a` compiles rank-one and rank-two command paths
into the RTC package image. That branch measured operator-command
preparation at 65.162 s before and 0.086 s after on Classic CPU. The
CAL2 graph self-test timings above describe a separate operation. The instrument change is in
`adaptive-optics-simulations@c9e6bb928b3299816b5b8797ce7f97db9fef16d0`.
The registered instrument dependency still needs a release containing the
installation and priming options.

The full RTC `test/runtests.jl` passed 10,783 assertions across 519
testsets using Julia 1.13.3 and the matching native JLL prefix. The permitted
CPU set included CPUs 0, 1 and 12–15 for the placement tests. The earlier
test invocation restricted itself to only 0 and 1, so its placement fixture
could not select a CPU numbered at least 2. The full rerun completed
with exit code zero. The instrument's CAL2 profile selector passed all 16
checks.

Focused tests covered export of the two CAL2 profiles, qualification with a
reused cache, rebasing generated graph workloads after composition, admission
on the current open owner, and invalidation on reset and rejected input.
The open and closed native-buffer observer checks reported zero steady-state
Julia heap allocations.
