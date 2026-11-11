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

## Targeted precompilation

The package now precompiles the CLI and the measured stop, cleanup and
record-write signatures. These directives compile the live operations
without executing them. A PrecompileTools workload uses a small nested
JSON record to cover dynamic parser and writer dispatch in memory.

A fresh Classic install selected the candidate from a temporary local
registry under version `0.7.14`, tree
`facb99cd8166825db27d6ce0618f7c5b1c38a413`. This was a test-only
version. Pkg preserved every other Manifest entry and verified the
candidate's installed source hash. Package precompilation took 32.2 s
with the other package caches present. The installed Project and
Manifest matched the resolved application byte for byte.

Classic reached Ready on a new private PipeWire core in 362.3 s.
The test requested managed stop after the WFS worker had consumed
2.068 s of cgroup CPU time and before it reported ready. The worker
stopped in 43 ms. The native Quit was acknowledged, the invocation
record reported complete cleanup and removed unit files, and the
private socket and owner processes were gone. There were no retained
jobs or SIGKILL entries. The candidate used the same native deadlines
and ran with compilation tracing enabled.

| Measurement | Clean 0.7.13 baseline | Candidate |
| --- | ---: | ---: |
| Managed stop elapsed | 60.84 s | 15.46 s |
| Stop job to Quit submission fence | 39.30 s | 4.89 s |
| ExecStop CPU through submission fence | 27.86 s | 4.25 s |
| Submission fence to acceptance observed | 3.78 s | 5.34 s |
| ExecStopPost start to core PID gone, sampled | 15.80 s | 2.80 s |
| ExecStopPost CPU by core PID disappearance | 15.70 s | 2.44 s |

Sampling resolution was about 87 ms. The wall-time reduction was 75%
for this pair of runs. Host contention varied, and the native operation
itself took longer in the candidate run. Neither candidate hook
reported compilation of the large JSON parser specialization.
The CLI entry point still recompiled in both hooks, at 1.17 s and
1.12 s respectively.

The full RTC core suite passed with the matching PipeWireAO JLL artifact
selected as the native prefix.
