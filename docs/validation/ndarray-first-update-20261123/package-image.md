# Native NDArray package precompilation on Classic CPU

## The earlier 27 and 96 seconds

Both numbers measured how long the RTC spent warming up the code that
handles operator commands before accepting any. This trades startup time
for a shorter first operator request. The journal calls this
stage `prepare control dispatch`. It includes ordinary commands and array
updates. The earlier package image covered ordinary commands. Each new RTC
still asked Julia to compile methods for the configured array ranks. The
Classic CPU fixture declares vectors for the two 277-element mirror offsets
and matrices for the reconstructor, background and reference slopes.

On the 96.30 s run Julia reported 96.26 s inside compilation. Both are
elapsed times. Systemd charged the **entire session service** 64.83 s of CPU
(`pipewireao-session@56391c52a6b5.service`). At least 31.47 s of the phase
therefore elapsed off CPU. On the earlier 27.13 s run, the session service
used 66.06 s of CPU over its lifetime. Neither run recorded CPU time or
scheduler wait at the two phase boundaries. The exact historical split
between additional work and waiting cannot be recovered from these totals.
The earlier single-CPU probe measured a 2.53 s increase in process CPU
for rank one alone. [Previous trace and measurements](README.md)

## What the package image prepares

When Julia builds the RTC package, it exercises vector and matrix updates
through the request decoder and reply encoder that serve real operators.
Each example contains one Float32. The compiled methods also handle larger
arrays of the same rank. Julia stores native code for forwarding the
request, checking its identity and deadline, putting the array in an
output slot, arming the timer, and replying. It compiles the native I/O
calls without opening a PipeWire connection or publishing any data.

At startup the session and parameter source still run a small in-memory
check for the ranks in the installed instrument. Julia can compile any
methods missing from the image at that point. This also covers alternate
clock types and images built with workloads disabled.
[Session warmup](../../../src/media_session/session.jl) ·
[Parameter-source warmup](../../../src/control/parameter_source.jl)

## Paired private Classic CPU runs

The comparison uses RTC `bf497d2` and its package-image change on Julia
1.13.4, SDK 4.0.8 and the same private non-actuating Classic CPU fixture.
Each owner started from prepared package caches. Both source snapshots used
the same temporary timing probe around operator-command warmup. It recorded
monotonic elapsed time, the process CPU clock (`CLOCK_PROCESS_CPUTIME_ID`) and
the calling thread's Linux scheduler run-queue wait (the second field of
`/proc/self/schedstat` on the main thread). Both sessions used CPU 3.
Time to Running starts at the systemd start request.

| RTC measurement | Previous build | With package precompilation |
| --- | ---: | ---: |
| systemd start to Running | 355.176 s | 226.110 s |
| Operator-command warmup, elapsed | 65.162 s | 0.086 s |
| CPU consumed by the session process during warmup | 20.948 s | 0.020 s |
| Main thread waiting on the CPU run queue during warmup | 44.212 s | 0.065 s |
| Julia's elapsed compilation counter during warmup | 65.099 s | 0.068 s |
| First DM offset send → Submitted reply | 381 ms | 280 ms |
| Next three offset sends → Submitted replies | 84, 101, 69 ms | 48, 50, 77 ms |
| First controller verification Status send → Submitted reply | 676 ms | 394 ms |
| First automation Enter keypress return → Submitted reply | 1,171 ms | 530 ms |

On the previous build, CPU time plus run-queue wait accounted for nearly
the entire measured interval. One-second samples found CPU 3 busy throughout
that interval. The new interval was shorter than one sampling period. Its
run-queue wait came directly from the thread counter. Both snapshots
preloaded their packages before the systemd start clock began.

The host's one-minute load average was 21.35 at browser launch on the
previous build and 9.83 on the package-image build. The 129 s difference
in time to Running includes other service startup work under different
load. The same previous build had produced a 255 ms first offset reply
on an earlier start. These single-run browser timings do not establish a
repeatable first-edit speedup.

Chromium used the same release WASM, bridge and module in both runs. After
a scalar edit and restore, it committed a typed DM edit with Enter and
restored the original, then repeated the cycle. All four writes in each
run received a correlated Submitted reply exactly once. The independent
observation matched all 277 Float32 values bit-for-bit after each write.
Both runs restored the scalar and offset. The previous build's Quit timed
out after the writes, and its private services were cleaned up. The final
build stopped normally. The two session UUIDs were
`98a8d141-9194-465d-b33f-fcdb4000cec6` and
`46a2fbd0-21cf-46db-9a16-fa69c633e58a`.

The live-test RTC native package image grew from 93,909,224 to 109,100,096
bytes (15.2 MB). Filling an empty RTC package cache and importing it took
about 303 s and 262 s of wall time, respectively. Other processes were
competing for CPU during both builds. These observations do not isolate the
change in package build cost.

## Cache coverage and fallback

Two fresh processes per revision loaded the package cache on one CPU and
used the inferred native session type. After generic command warmup, the
first vector and matrix workloads together used 22.8–22.9 s of process CPU
in the previous build. The final image used 0.14–0.16 s for the same calls.
A rank-three workload, absent from the package image, completed through
the existing startup fallback. It took 10.2–10.9 s of CPU on its first
call and under 2 ms on repetition.

A separate private-core check loaded the final native package image and
exercised the parameter owner's scratch endpoint for both configured
ranks. Its first pass took 132 ms elapsed, including 130 ms measured inside
compilation. A second pass took 0.87 ms with zero measured compilation.
The test checked that the live source bytes, sequence, publication state
and retained bootstrap completion survived the scratch workload.

The final RTC suite passed 10,881 assertions across 515 testsets.
The focused codec, golden-vector, late-acknowledgement and private-core
checks passed all 50 assertions. Both used the final native package image
with `--compiled-modules=existing --pkgimages=existing`.
