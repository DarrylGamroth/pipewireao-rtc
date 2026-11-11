# Classic managed Quit timing

The [RTC 0.7.13 release run](../rtc-0713-20261111/README.md) took 66.0 s
to stop. Its journal places the optional WFS analysis stop at +0.000 s
and its completion at +0.038 s, relative to the session stop job.
systemd logged final CPU accounting for the controller at +36.648 s,
parameters at +36.927 s and simulator at +37.180 s. The private core
stopped at +64.445 s and the session stop job completed at +66.015 s.
The release run did not time the native request or profile the hooks.

## Repeat with owner and hook timing

Classic CPU ran on a new private core with the same installed Project,
Manifest and registered RTC 0.7.13 tree. Julia 1.13.3 reused compiled
package caches produced by the release run. The normal installed units
and commands were used. The repeat reached Ready in 313.7 s. At the
stop request, the analysis worker was alive, had loaded libLLVM and had
consumed 2.016 s of cgroup CPU time before reporting readiness.

Times below are relative to the session's systemd stop job
(monotonic journal time 1096919.084279 s). Owner timings use systemd's
journal or the first observed disappearance of the exact owner PID.
The observer sampled the launch record, systemd control PID and
`/proc` about every 87 ms during most of the stop. The native submission
fence is written immediately before the request call. The accepted
field is written after the correlated completion is checked.

| Elapsed (s) | Event |
| ---: | --- |
| 0.000–0.036 | systemd stops the optional WFS analysis worker using SIGHUP |
| 0.068 | First sample of the Julia `ExecStop` process |
| 24.706 | Native Quit submission fence first observed |
| 27.730 | Julia controller PID gone |
| 27.818 | Standalone HIL simulator PID gone |
| 27.904 | Parameter publisher PID gone and native Quit acceptance first observed |
| 28.338 | MediaSession RTC PID gone |
| 28.423 | First sample of the separate Julia `ExecStopPost` process |
| 42.517–42.525 | systemd stops the private PipeWire core |
| 43.567 | Invocation cleanup completion first observed |
| 43.674 | systemd completes the session stop job |

The command returned after 43.686 s. The launch record reported an
accepted native Quit, complete cleanup, removed invocation unit files
and a successful service result. The private socket was gone, all
owner MainPIDs were zero, and the invocation had no remaining systemd
jobs or SIGKILL entries.

## Where the time went

The stop helper used 24.20 CPU s by the sample that first showed the
submission fence. The post-stop helper used 14.01 CPU s before
requesting the core stop. The helpers therefore spent about 38.8 s
of wall time in these two windows. Native Quit and required-owner
retirement fit in the roughly 3.2 s from the submission fence to
recorded acceptance. The core's own stop took 8 ms.

`perf record -e cpu-clock:u -F 49 -p PID` sampled each hook process
from its first observed systemd stage. No samples were lost.

| Hook | Samples | libLLVM | Julia codegen library | Example sampled functions |
| --- | ---: | ---: | ---: | --- |
| `ExecStop` | 1,193 | 52.56% | 2.51% | `llvm::SelectionDAGISel::SelectCodeCommon`, `llvm::InstCombinerImpl::run`, `emit_function` |
| `ExecStopPost` | 684 | 49.42% | 2.34% | `emit_function`, `DAGCombiner::combine` |

These samples show substantial Julia compilation in both one-shot
helpers even with package caches available. The profile covers each
whole hook and does not isolate the compilation time of individual
Julia methods. The original run shows the same long windows around the
required-owner exits, but lacks hook samples for an exact attribution
of its additional 22.3 s.
