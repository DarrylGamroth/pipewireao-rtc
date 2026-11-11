# Classic shutdown compilation

## RTC 0.7.13 baseline

Classic CPU ran with Julia 1.13.3 on private PipeWire cores. Both runs
used fresh installations of the [verified registry-only Classic
application](../rtc-0713-20261111/README.md), with package caches from
the earlier verification available. Both stopped while the optional WFS
analysis worker was still starting.

| Baseline run | Managed stop | Time to Quit submission fence | Native Quit |
| --- | ---: | ---: | --- |
| Uninstrumented Julia hooks | 60.84 s | 39.30 s | Accepted |
| Julia hooks with compilation tracing | 107.25 s | 67.26 s | Deadline expired before the send; systemd fallback ran |

The uninstrumented run used 27.86 CPU s in `ExecStop` by the submission
fence. The fence-to-acceptance interval was 3.78 s. The separate
`ExecStopPost` process used 15.70 CPU s by the time the private core was
observed gone, 15.80 s after the first post-stop sample. It completed
cleanup. There were no SIGKILL entries.

The traced run used the normal installed commands via an installer-selected
wrapper that adds `--trace-compile` and `--trace-compile-timing` to the
two hook processes. It captured the following Julia-reported compile
times. These are individual trace entries and are not a wall-time
breakdown. Host contention varied across runs.

| Specialization | ExecStop | ExecStopPost |
| --- | ---: | ---: |
| SessionCLI entry point | 27.84 s | 14.55 s |
| JSON parser for the invocation record | 18.32 s | 8.22 s |
| Stop method with parsed CLI arguments | 4.33 s | |
| Cleanup invocation with a source role | | 1.42 s |
| Cleanup of the decoded invocation record | | 3.29 s |
| Atomic invocation record write | 1.40 s | |

The traced failure occurred at the first deadline check in
`ControlClient.request!`. The launch record had written its submission
fence, but the helper's absolute deadline had expired before the native
send. Its subsequent cleanup trace is evidence for the fallback path.
