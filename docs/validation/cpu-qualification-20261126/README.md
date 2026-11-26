# CPU qualification of PipeWireAORTC 0.7.33

The controlled services ran on private PipeWire cores on rtc-devel with Julia
1.13.4 and CPU optical simulation. The installed Classic and CAL2 projects used
RTC 0.7.33 (registry tree `2d86d9bb3859cc5d59694b98f24a2a172c0ab237`),
PipeWireAO.jl 0.9.6 and PipeWireAO_jll 4.0.10+0 (Linux AVX2 artifact
`b5a54eff79257332e4f793664180fd59e277f26d`).

## Standalone CAL2

The current controller definition failed installation with persistent graph
owners because LLOWFS lacked the required live-priming configuration. Instrument
commit `283a30a` adds install-time qualification and live residual priming for
both controllers and raises the RTC and SDK compatibility floors to the tested
releases. The original mode fails the graph-owner check. The repaired mode
passes all five focused profile checks. The fresh export `b65760d` installs with
both retained graph services and the selected C-RED 2 Float32 ROI calibration.
Its independently launched CPU simulator uses the same optical configuration
bytes as the first export.

On this host the separate `/tmp` tmpfs was full. A diagnostic service
confirmed that the native SPA-JSON parser could return success with empty
captured output when the file was on that filesystem. The site host
profile declares `TMPDIR=/var/tmp` for the graph services and session.
The installer seals that setting in the units and admission verifies
the installed fragments.

With the provider and graph owners already running, the first attach reached
native held Ready in 8.435 s with ten Links. Admission was complete and
correction was open. The operator's Start command enabled live priming.
LLOWFS produced its first matched output 32.542 s after Start. The SCC
pair completed 189.278 s after Start. At the exercised CPU pace the
provider consumes roughly one 2 ms pupil step every 32 wall seconds,
and SCC combines five steps per exposure. Both offsets remained zero.
Native Quit completed in 4.137 s. Both camera queues returned one
pending capture loan and went from three capture buffers to zero.
The two cameras continued publishing with the RTC detached. A fresh
attachment reached held Ready in 6.931 s on the same provider and core.

An RTC-only SIGKILL on the released build removed the old native control
owner and all RTC Links. Both capture pools retired. The independent
core, provider and two graph services kept their incarnations. Both
cameras advanced in their existing acquisition domains and generations
with the RTC detached. The released direct unit left its discovery
locator behind because systemd skipped `ExecStop` after the RTC died.
The replacement RTC reached held Ready in 5.824 s. Its first matched
LLOWFS residual arrived 19.071 s after Start with a zero offset. The
final native Quit took 3.484 s, and both camera capture pools returned to zero.
The full provider witness contained 86 consecutive LLOWFS exposures
and 17 consecutive SCC exposures.

RTC commit `32d2e5a` adds an invocation-checked direct `ExecStopPost`.
The hook removes only the exited session's locator. A successful exit
skips the Julia cleanup process. The installed private-core direct
fixture passed 136 checks, including native Quit, RTC-only SIGKILL,
discovery and Link retirement with the provider still live, and
rejection of invalid provider placement. The RTC core suite passed all
12,342 checks across 581 testsets, including Aqua.

## Classic installed controls and observation

The installed CPU session held Ready with 20 owned Links. The installed CLI
submitted a reversible engineering offset and restored its original value.
Both active generations were confirmed, and the live offset stream matched all
277 Float32 coefficients after each command. The elapsed times from the CLI
invocation to observed active generation were 3.460 s and 2.209 s, including
process startup. The native GUI client selected the same session and displayed
its live status in offscreen production panels. The independent GUI Status
client continued through a paused reader and an explicit selection after
reconnect. GUI commit `6dd627e` allows zero owned Nodes while requiring owned
Links and preserving the exact count comparison across reconnect.

All eight observation products advanced after a 60 s slow-client phase and
60 s with those observation clients detached. The demanded queue accepted
570 additional upstream publications between witness samples during
detachment. It recorded zero ownership protocol errors. These are
short-duration reproduction attempts for the historical
[Classic demanded queue incident](https://github.com/DarrylGamroth/pipewireao-rtc/issues/13).
A separate run stopped a connected demanded-command client process for 60.574 s.
The detector and demanded-command queues each accepted another 610 publications
during the stall. After recovery and a 30.065 s detach, a fresh client retained
the same producer and received newer data with zero observed queue protocol
errors. Native Quit and exact cleanup completed in 21.795 s on the first run
and 12.492 s on the separate stall run. The timed normal launch reached held
Ready in 34.597 s. The original CUDA buffer-removal failure remains open.

The installed Classic optical assets also passed all 106 checks in the
native calibration pilot. The pilot correlated the UInt16 camera capture and
derived measurements through Collect, rejected the under-threshold response,
confirmed exact restoration and Release, and verified that streams, buffers
and workers retired. The cancelled and controller-loss cases retained their
separate completion rules. The test promoted no calibration candidate.

The separate native Collect consumer selector passed 209 checks against
the same installed assets. It observed two exposures, rejected new Collect
requests after an injected consumer error, then confirmed Restore and
Release and verified worker retirement.

## Copper CPU SPECULA feedback

The maintained private-core Copper lockstep selector passed 16 checks against
SDK 4.0.10+0 with the metadata-enabled FGN fixture built from
`filtergraph-rs` `737b910`. It verified the first illuminated command
(266.887 nm maximum absolute OPD) and replayed that command in a second
SPECULA plant to reproduce the next exposure. The SDK, Copper optics and
fixture identities are retained with the run. This leaves [CCR-017's ordinary
progressive-streaming calibration case](../../CALIBRATION_COMPLETION_PLAN.md#copper-cohort-and-selection-policy)
open.

## GPI2 CPU simulator pacing

The installed 10 Hz CPU host setting produced 57 gap-free detector frames
at 1.561 frames/s during the diagnostic window. Each model exposure was
500 µs and the three commands matched the detector acquisition IDs.
The rtc-devel host profile selected a 1 Hz wall-clock target and delivered
36 consecutive detector frames at 1.002 frames/s. The three correctors
reported the same acquisition identities, and the installed session accepted
native Quit. The authoring build kept the 2,000 Hz model clock, controller
graph and FITS binding bytes identical. No GPU libraries were mapped by the
core, RTC, controllers or simulator during the check.

## GPI2 CPU deadline replay

A separately scheduled native producer cycled through the archived 1,062
242 × 240 UInt16 detector images on a fixed 2 kHz clock. The replay used the
current complete-frame CPU controller and selected calibration, retaining
woofer, tweeter and tip/tilt command sinks and disabling optional telemetry.
The graph, producer and command receipt threads used SCHED_FIFO priority 15
on separate physical cores. Each window retained one startup frame, 8,000
warmup offers and 120,000 measured offers. The miss count includes every
rejected offer and any completion over 500 µs from its scheduled release.
Latency percentiles are conditional on receipt of all three commands.

| Untraced window | Offered | Rejected at source | Late completions | Deadline misses | Median | p99 | p99.9 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 120,000 | 100,496 | 19,504 | 120,000 | 11.337 ms | 16.134 ms | 19.559 ms |
| 2 | 120,000 | 102,612 | 17,388 | 120,000 | 12.683 ms | 18.685 ms | 23.110 ms |

The traced run also missed all 120,000 deadlines. Its 13,776 complete
frames joined exactly to their controller callbacks. Median callback
duration was 4.106 ms, with a minimum of 2.865 ms. Every captured
callback alone exceeded the deadline. From callback return to receipt
of all commands the median was 63 µs. Release-to-publication and
publication-to-callback medians were 8.013 ms and 3.961 ms during this
overloaded run. The trace changes the timing and is reported separately.

The replays used the archive's column-major detector wire layout.
The current installed definition selects row-major. These CPU tests use
the workstation and a separate replay topology. Deployments also require
the [target-host timing gate](../../operations.md#rtc-dev-019--verified-process-and-thread-placement).
