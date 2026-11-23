# First native NDArray update on Classic CPU

Each private Classic CPU run used Julia 1.13.4, PipeWireAO SDK 4.0.8,
and the same release builds of the GUI bridge, module and browser. The
RTC baseline was `76c96fb` on the native NDArray branch based on v0.7.28.
The DM was a simulated 277-actuator mirror. Every run started a fresh RTC
from prepared package caches and exercised the ordinary scalar edit and
restore before the first NDArray update. For the subsequent change that
stores the compiled methods in the package image, see the
[package-precompilation comparison](package-image.md).

## What compiled on the first edit

The trace starts when the public session decodes the first NDArray command
and ends when it completes the correlated reply. That interval was 1,823 ms.
Julia's cumulative compilation counter advanced by 1,229 ms in MediaSession.
In the parameter owner it advanced by a further 350 ms between taking the
ticket and completing the reply. The following three requests showed zero
counter advance over the corresponding intervals. Compiler durations can
include nested work. The method times below are individual records.
[Full first-update method signatures and phase markers](first-update.trace.gz)

| Process | First-use specialization | Julia compile time |
| --- | --- | ---: |
| MediaSession | `apply!` on the public NDArray dispatch ticket | 551.5 ms |
| MediaSession | `request_owner!` for the running NDArray effect and its parameter-source owner | 263.0 ms |
| Parameter source | `parameter_controller` on the live PipeWire registry type | 94.9 ms |
| Parameter source | Arming the owner timer with `update_timer!` | 73.4 ms |
| MediaSession | `reply_pod` for the NDArray ticket and its Submitted reply | 70.2 ms |
| MediaSession | `Ingress._finish!` for the same ticket | 54.1 ms |

Both processes also compiled the constructor for an inline Float32 array
with a declared schema. Source lookup, staging the publication and checking
its ticket accounted for additional owner-side records.

## Startup preparation

MediaSession now admits and completes representative NDArray requests on a
private gate. It compiles the concrete public dispatch and owner-forwarding
methods for Ready and Running. The parameter owner exercises slot staging on
a single-Float32 scratch source. It precompiles registry verification and
timer calls. The workload covers configured ranks, inline and streamed
payloads, and optional schemas. It sends no native requests and has no
scientific output stream. The private-core regression checks the live
source bytes, sequence, publication state and bootstrap completion after
preparation. [Session warmup](../../../src/media_session/session.jl) ·
[Parameter owner warmup](../../../src/control/parameter_source.jl) ·
[Isolation regression](../../../test/parameter_ndarray_private_core.jl)

## Follow-up trace

A fresh session with the initial warmup took 295 ms from native command
decode to reply publication. Compilation in that interval fell from 1,229
to 101 ms in MediaSession. Parameter-owner compilation from taking the
ticket to completing the reply fell from 350 to 20 ms. The original public
dispatch, forward encoder and final reply publication accounted for zero
compiler-counter increase at their respective markers.
[Follow-up method signatures and phase markers](follow-up.trace.gz)

The remaining first-use records included constructing the effect ticket,
comparing the wire shape with the configured shape, reading the parameter
completion and reply header, constructing the machine reply, and checking
the active ticket under the owner loop lock. The final startup workload
prepares those calls. The trace also recorded 4.2 ms compiling the task
closure that runs the effect. A fresh-process check of the final workload
exercised in-memory admission through completion without emitting another
compiler record for the effect-ticket constructor or machine reply.
The two owner crossings occupied additional
wall time. For example, 105 ms elapsed between the session sending the
request and the parameter owner taking the ticket. There was no compiler
counter at the start of that owner interval.

## Browser timings

Chromium's DevTools Protocol recorded the WebSocket send and the matching
Submitted reply in the same clock domain. The first boundary below includes
the required controller Status verification. The second starts when the
browser sends the offset. Times are milliseconds, in request order. Each
row describes one fresh RTC process. The untraced rows give the
before/after comparison.

| RTC run and boundary | First edit | Restore | Second edit | Restore |
| --- | ---: | ---: | ---: | ---: |
| Previous warmup, untraced, Status → reply | 1,958 | 107 | 123 | 175 |
| Initial warmup change, untraced, Status → reply | 474 | 251 | 180 | 243 |
| Final warmup, untraced, Status → reply | 334 | 126 | 144 | 213 |
| Previous warmup, untraced, offset → reply | 1,831 | 37 | 49 | 45 |
| Initial warmup change, untraced, offset → reply | 371 | 66 | 51 | 57 |
| Final warmup, untraced, offset → reply | 255 | 46 | 58 | 52 |
| Previous warmup, tracing enabled, offset → reply | 1,862 | 66 | 54 | 54 |
| Initial warmup change, tracing enabled, offset → reply | 310 | 47 | — | — |

In the final run, elapsed time from browser automation returning from Enter
to the Submitted reply was 458, 181, 267 and 242 ms. The five-second mutation
budget starts when the GUI prepares the edit. Using the encoded remaining
budget at send, those durations through reply were 408, 128, 216 and 215 ms.
The first write still took about 200 ms longer on the wire than the warm
writes. The final performance measurement ran with compiler tracing disabled.

The untraced baseline, initial change and final change had session UUIDs
`1535c0c5-683f-40aa-9107-5ce60afe6ed2`,
`ace73533-cc4f-4eee-89ae-b15f4924911b` and
`19751767-32bc-4144-8a96-f641f5d9e0cf`, respectively. The traced
baseline had UUID `b80cb440-3b87-4d28-a748-1df43fe92a06` and the
follow-up trace had UUID `7e9533b7-7f8e-4f97-beea-31fb58ed9e98`.
Every edit and restore was sent once and matched by generation and
correlation. Independent readback matched all 277 Float32 bit patterns after
each write. Both edit/restore cycles returned the scalar and offset to their
original values. All browser pending counts returned to zero.

The session's “prepare control dispatch” startup phase took 27.13 s
on the traced baseline, 38.75 s on the initial untraced change, and
96.30 s on the final untraced run. Julia's compilation counters recorded
27.10, 38.71 and 96.26 s in those phases. Tracing began after startup
preparation. The runs shared CPU time with other processes, so the
live differences alone do not measure the incremental CPU cost of the
workload. All browser measurements began with the private RTC in Running.

A separate fresh Julia process for each revision used one spare CPU, a
warm package cache, `--threads=1,0`, and the inferred native session
type. After `prepare_dispatch!(T)`, a timed
`Base.invokelatest(prepare_parameter_ndarray!, T, 1)` took 2.53 s of
process CPU time on the baseline and 5.05 s on the final change. Elapsed
time matched CPU time to within 1 ms in each process. This measures the
session's rank-one workload only. The parameter-owner process and live
owner discovery were outside that measurement.

The initial untraced warmup run timed out during Quit after all four writes
and restoration had completed. The supervisor recorded a failed stop and
completed cleanup. All four child services had exited and their unit
files were removed. The final untraced run stopped normally. The bridge
exited successfully, and cleanup removed every private child service.

## Measurement procedure

1. Use the sealed non-actuating Classic CPU export and the matching SDK.
   Point both the session and its parameter owner at the same tested RTC
   source. Preload only the package in the three launch contexts (default,
   `--threads=1,0`, and `--threads=2,0`) so building package images does
   not enter the fresh-process timings.
2. On Julia 1.13.4 the temporary diagnostic called
   `ccall(:jl_force_trace_compile_timing_enable, Cvoid, ())` and
   `Base.cumulative_compile_timing(true)` on entry to the session and
   parameter-owner service loops. It disabled both at shutdown.
   Sample `time_ns()` and
   `Base.cumulative_compile_time_ns()` at decode, dispatch, forwarding,
   staging and reply. Capture journal records with `journalctl --all -o json`
   to retain the full concrete types in long signatures. Leave stream
   callbacks untouched.
3. Start a fresh private owner, verify its UUID and private socket, admit
   Running, then connect the production browser and bridge on loopback.
   Perform a scalar edit and restore, commit the first DM offset with Enter,
   verify the observed data, and restore the original offset. Repeat against
   the same owner for the warm comparison. Match browser send and reply by
   connection generation and correlation. Repeat with tracing disabled for
   performance comparison.

## Software checks

The final RTC core suite passed 10,769 assertions in 515 testsets on Julia
1.13.4. The initial warmup passed the same 515 testsets. The concurrent
snapshot test collected 80 assertions in that run and 51 in the final run.
The focused codec, golden-vector, deadline and private-core checks passed
50 assertions, including the scratch-publication isolation check.

```sh
julia --startup-file=no --project=. -e '
using PipeWireAO
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
include("test/runtests.jl")'
```
