# Installed CAL2 RTC startup CPU attribution

The CAL2 source was already publishing into an independent private PipeWire
core. Both complete-frame graph services were present before each timed start.
The RTC used the installed direct systemd launcher from `bc90853`, Julia
1.13.3, existing package images and CPU 3. It admitted ten fresh Links and
reported native Ready with execution held. The endpoint and required graph
identities were checked independently. This interval ends at Ready, before any
Start command or wait for a usable camera frame.

| Time through Ready | Passive | Leader CPU profile |
| --- | ---: | ---: |
| Request to systemctl return | 12.105 s | 11.159 s |
| Request to systemd MainPID start | 19 ms | 18 ms |
| Main-thread CPU | 9.642 s | 9.131 s |
| Main thread runnable and waiting for CPU | 0.237 s | 0.160 s |
| Remaining nonrunning time through the last sample | 2.186 s | 1.829 s |
| Whole RTC process user plus system CPU | 9.88 s | 9.37 s |
| Reaped child user plus system CPU | 0.20 s | 0.19 s |
| Major faults / storage reads | 385 / 74.8 MB | 66 / 92.1 MB |
| Sampled CPU 3 frequency, median | 4.06 GHz | 4.21 GHz |

The final scheduler samples preceded systemd Active by 13–14 ms. Process I/O
counters include reaped children. Storage reads occurred chiefly early in
startup. Sampled wait channels also show epoll, futex and filesystem waits.
The nonrunning residual includes these waits and scheduling or sampling
boundaries. The file, child process and native protocol behind each blocked interval
remain unassigned.

The second start sampled the main thread's user CPU at 199 Hz, beginning
0.259 s after systemd started MainPID. Of 1,725 samples through Active,
1,069 (62.0%, approximately 5.372 sampled CPU seconds) had an instruction
pointer in LLVM or Julia's code-generation library. Ten more landed in
explicitly identified Julia inference symbols. Other identifiable samples
included garbage collection (83) and package-image restoration (16).
Unresolved and general runtime samples can include additional compilation.
The profiler and sampling observer ran on CPU 12. Observer plus child CPU
cost was 0.373 s in the passive arm and 0.385 s in the profile arm. The wall-time difference also includes changes in storage activity, CPU
frequency and wait time. The profile's effect on Ready time remains
unresolved. The observer initially failed when the kernel denied its transient
process I/O read. The reported launches use the corrected observer, which
keeps scheduler samples if the I/O counters are unavailable.

## Startup operations

The third activation used a separately built RTC image with phase timestamps
and Julia compilation tracing. It retained the original pinned launcher,
core, simulation source, both graph services and ordinary native admission.
It reached Ready in 13.597 s. Its larger I/O count and its tracing make the
diagnostic timeline unsuitable as an uninstrumented baseline. Its Quit helper
inherited the diagnostic package environment and expired while connecting.
Systemd cleanup finished. The two normal baseline starts acknowledged Quit.

| Operation | Wall | Main-thread CPU | Julia compiler elapsed |
| --- | ---: | ---: | ---: |
| Main process start through RTC package initialization | 2.623 s | 1.387 s | — |
| First entry into the RTC | 0.486 s | 0.474 s | 0.480 s |
| Verify sealed installation and prepare the invocation | 4.296 s | 3.888 s | 3.795 s |
| Construct the native MediaSession | 0.681 s | 0.634 s | 0.625 s |
| Capture owners, connect them, discover graphs and establish held Links | 2.784 s | 2.097 s | 2.021 s |
| Verify admission through the native proof client | 1.490 s | 0.836 s | 1.408 s |
| Confirm held native Status | 0.336 s | 0.257 s | 0.332 s |
| Verify live placement and publish discovery | 0.448 s | 0.251 s | 0.202 s |
| Retire proof client, fence the Links and notify systemd | 0.413 s | 0.402 s | 0.391 s |

Julia recorded 9.254 s of compiler elapsed time after package initialization,
including 0.665 s of recompilation. Compiler elapsed time is process-wide and
can overlap work in other tasks and threads. Isolated imports from the stock
installed environment using fresh Julia processes on CPU 12 and the existing
images took 1.105–1.225 s for `using PipeWireAORTC`. That probe measures
package import with the Julia process already running.

Generating and checking the invocation's SPA-JSON configuration was the
largest measured preparation interval at 1.879 s elapsed, 1.816 s on the main
thread and 1.834 s of compiler elapsed time. The exact `render!` keyword
specialization took 416 ms in the trace. The same interval compiled the JSON
and SPA-JSON paths for heterogeneous dictionaries, typed maps, arrays and
scalar values. The sealed activation file check itself took 114 ms in this
run, including 105 ms of reported compilation.

The largest remaining instrumented native phases were owner capture
(1.093 s wall, 1.058 s compilation), Link connection and verification
(0.822 s, 0.501 s) and connection of the proof client (1.366 s, 1.379 s).
Trace signatures identify first use of typed registry listeners and proxy
bindings, format enumeration, property parsing and proof-client selection.
Their largest individual recorded compilation times were 108 ms, 114 ms and
191 ms, respectively. The proof client's close path spent 0.371 s, including
0.360 s of compilation distributed across typed native cleanup. The final
native synchronization took 4.7 ms and the exact held Link check took 0.9 ms.
These live operations must still observe the current native objects and
placement on each invocation.

## Precompiling configuration rendering

RTC `b2c2f1f` precompiles the concrete installed rendering call and exercises
the same in-memory SPA-JSON payload writer on a small document with the
collection types emitted by the RTC. The workload runs at package build time on an in-memory document.
Activation checks
the installed files and the current processes, renders the configuration,
checks the native parser's round trip and writes the invocation file.

The isolated render/decode selector supplied the actual sealed CAL2 profile,
the prepared owner records and the retained ten-Link configuration. It
substituted only an owned scratch socket for the remote and checked that the
entire decoded result matched the original configuration with that substitution.
Four fresh processes per arm ran in A-B-B-A-A-B-B-A order on CPU 12 with
existing package caches. These timings cover configuration generation and
decode inside an already-running Julia process.

| Time | Previous median (range) | Precompiled median (range) |
| --- | ---: | ---: |
| Render and decode wall time | 1.668 s (1.640–1.870) | 0.700 s (0.693–0.703) |
| RTC process CPU for render and decode | 1.640 s (1.617–1.794) | 0.677 s (0.671–0.680) |
| Render's Julia compiler elapsed | 1.622 s (1.599–1.827) | 0.670 s (0.664–0.673) |

Three subsequent calls in each process reported zero compilation, with
render-and-decode times of 25.9–26.4 ms before the change and 26.2–30.3 ms
after it. The candidate added 493,214 bytes (0.47 MiB) to the Julia
image and header. A separate candidate cache build took 136.2 s on CPUs
12–13 with existing dependency images.

All 666 assertions in the focused SPA-JSON, session configuration,
installed runtime, retained graph deployment, Stop, and MediaSession
transport, effects and objects selectors passed. The first selector run
reached a retained graph manifest mismatch with a symlinked artifact path.
The passing run selected the canonical path of the same native artifact.

The trace also identifies work that could move into package precompilation in
a subsequent measured change. Owner capture compiled several distinct
registry bind and enumeration methods. Proof admission and retirement
compiled the typed native client's construction, callbacks and close calls.
Each route spans several dynamic methods, while the concrete startup effect
entry points are already precompiled. The individually identified
specializations in these groups took up to 191 ms. The trace also reported a
425 ms recompile of the already-precompiled MediaSession entry point. The
diagnostic image modifies that method, leaving its relevance to stock invalidation unresolved. Fresh native evidence,
negotiation, process checks, file identities and current placement still
belong to each activation.

The archive contains the process counters, symbol samples, phase trace,
render selector, package inputs and focused test output.
[Startup CPU receipts](startup-cpu-receipts.tar.gz)
