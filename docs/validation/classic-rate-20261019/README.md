# Classic 500 Hz target and timing instrumentation

## User correction and scope

On 2026-10-19 the user clarified that the simulator must exercise the RTC at
500 frames/s and that GUI observation has an independent cadence. The earlier
10 Hz throttle was a functional bring-up setting, not a performance result.
The earlier registered deployment evidence retains that 10 Hz scope.

The application now declares both `rate=500` and `wall_rate=500`: a 2 ms model
step and a target of one actual frame every 2 ms. Exposure remains 1,896,000 ns.
The native profiler module is enabled in `core.conf.in`. No scientific settings,
FITS inputs, Julia package versions or GUI refresh settings change.
Before modification, the sealed application was copied to
`/home/dgamroth/.local/state/classic-registered-20261019/application-pre-500hz`.
The application was resealed and validated using registered RTC 0.1.5.

## Existing native timing support

The selected PipeWireAO_jll 1.7.1+0 artifact already includes
`libpipewire-module-profiler.so` and `pwao-profiler`. The profiler collects while
a client binds and disables its RT listeners after the last client disconnects.
The earlier Classic core did not explicitly load this module.

PipeWire's public Profiler interface supplies driver/follower activation data,
including signal, awake and finish timestamps, clocks, quantum/rate, CPU load
estimates and xrun counts. `pw-top` and `pw-profiler` consume that interface.
The selected source is
`pipewire-acquisition-release/src/modules/module-profiler.c` (producer and
bounded per-driver rings), `spa/include/spa/param/profiler.h` (POD fields) and
`src/tools/pw-profiler.c` (consumer). Graph period is quantum divided by rate;
the RATE column alone is not necessarily the frame-cycle frequency.

These measurements describe PipeWire graph activation. They do not encompass
all GPU plant work or acquisition-to-command latency. The existing HIL
`PipeWireFrameCommandTiming` separately records source publication and matching
command receipt on the host monotonic clock. Device application time would
require a device-owner timestamp with its declared clock domain.

For later Session timing readouts, reuse the native Profiler interface and
existing application boundaries. Aggregate distributions in a bounded headless
collector using HdrHistogram; formatting, percentiles and transport belong off
the RT callbacks. Record missed source periods, histogram overflow and missing
profiler records explicitly. The current profiler overflow path logs and skips
records without exporting a drop counter. Its per-driver `info.count` advances
through skipped records and intentional sampling; complete tail claims need
validated gap accounting. An optional profiler alone does not constitute persistent
RTC telemetry, and no new telemetry protocol or histogram component is
implemented by this configuration change.

## Measurement boundary

The actual source cadence is derived from sequence differences divided by
differences in source Header PTS, which use host-monotonic publication time.
It is not the count of GUI updates or retained queue samples. Acquisition
generation must remain unchanged across each window. Capacity-one observation
queues may discard samples while source sequences continue advancing.

The HIL source waits for matching command adoption before its next model step.
This is a completion-paced, causal coupled simulation. If processing is late,
the source skips expired wall deadlines without catch-up bursts and preserves
every model sequence. Its achieved rate does not qualify independent 500 Hz
open-loop arrivals or maximum isolated RTC throughput. A target declaration
alone does not establish 500 Hz delivery or deadline compliance.

## Current run

Evidence root: `/home/dgamroth/.local/state/classic-registered-20261019`.
The new held candidate is `gui-session-500hz-001`, native unit
`pipewireao-session@ce025a88c65a.service`, invocation
`838bd55518ee4729b6d1282bd89491bb`. The previous 10 Hz session was normally
shut down with exact cleanup before the candidate source was released.
Reset to generation 2/sequence 0, restart, all eight advancing finite/canonical
sample streams and matching SHWFS identities pass. The source remains Running,
with simulator PID `4051788` on the RTX 3080. GUI unit is now
`pipewireao-gui-classic-20261019-500hz.service`.

| Window | Source frames | Publication elapsed time | Observed rate |
|---|---:|---:|---:|
| GUI closed | 2,179 | 7.256049933 s | 300.301 Hz |
| GUI open | 1,882 | 6.717056882 s | 280.182 Hz |

These short windows are not a controlled before/after comparison. The GUI is
not the sole limiting factor. The target remains 500 Hz; **sustained 500 Hz is
not achieved or qualified**. The throttle is removed, but the throughput
limitation remains unresolved. No speculative production optimization was made.

The profiler supplies 256 objects with clocks, drivers and 2,752 follower
records. The 224 `simulator-wfs` signal→finish observations have median
295.073 µs and maximum 1,962.595 µs; corresponding JFG awake→finish observations
have median 7.694 µs and maximum 834.212 µs. These instrumented activation
measurements are not whole-exchange costs or a demonstrated bottleneck.
Driver xrun counts are zero.

The externally triggered source's profiler clock reports `rate=1/48000`,
`duration=1024`, `position=0` and stale `nsec`, while activation timestamps and
source sequences advance. This clock cannot serve as an AO frame-rate readout
here. Activation events are not proven one-to-one with completed exchanges.
The GUI must use declared frame semantics and owner counters/timestamps.

A five-second host CPU profile captured 502 samples without reported loss,
including yield/wait, CUDA-copy, clock and GC activity. Incomplete Julia JIT
symbolization prevents a definitive phase diagnosis. Raw perf data are retained.

The first GUI check assumed seven active streams, but the user layout had RTC
Session selected instead of SHWFS. The visibility-aware check passes with the
five visible DM/focal streams Running, active GUI and native Running. User
layout was preserved; the independent all-eight sample check is separate.

Evidence in the stage includes `live-rate-without-gui.json`,
`live-rate-with-gui.json`, `native-profiler.json`, `native-profiler-summary.json`,
`retained-observation.json`, `smoke-reset-report.json`,
`previous-session-cleanup.json` and `retained-verification.json`. Parent logs
include `smoke-500hz-001.log`, `rate-500hz-{without,with}-gui.log`,
`native-profiler-500hz.log` and `gui-500hz-verification-visible.log`.

## Next measurement and remaining work

Use a bounded, preallocated owner-side capture indexed by generation/sequence:
scheduled deadline, exchange begin/end, existing publication/command-receipt
times and skipped pacing slots. Internal hooks around existing
`step_hil_frame_at!` and command adoption can separate science/synchronized
GPU→host copy, host conversion, RTC round trip and command adoption. Write
records after measurement; stop a window at reset or generation change.

Expired 2 ms pacing slots are skipped. Occasional overruns can therefore produce
4 ms or longer intervals: 300 frames/s does not establish 3.33 ms science cost.
Measure phase times and consecutive frame intervals before choosing a fix.

Project/Manifest, FITS files and scientific declarations remain unchanged.
Final deployment SHA-256 is
`00feaa76c4c2d4e8d2a43839b4e70ca3571fab65e61aba6a0f4c16e3c7971a97`;
simulation configuration is
`b72354dd582124a00f085bf1778f500c82a0bb062d908cb3300613929a3fa9ec`;
core configuration is
`6d7125398f37fbaa92bd154054dd0c53823a15f1187552613030909e97e5c14a`.
