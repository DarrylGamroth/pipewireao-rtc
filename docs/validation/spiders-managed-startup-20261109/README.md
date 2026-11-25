# Managed SPIDERS fitted-dual CPU cold start — 2026-11-09

This run uses the sealed fitted-dual CPU application exported from instrument
revision `948903e`. The later selector migration at `101b7f2` changed the test
and documentation. The export used `spiders/profiles/fitted-dual-controller/cpu.yaml`
and `spiders/profiles/fitted-controller/host.cpu.example.yaml`. It retained
the fitted SCC and nominal LLOWFS calibration, the normal standalone HIL
entrypoint, and the RTC's declared Links.

The standard installer and generated systemd user unit started a fresh RTC,
private core, simulator and controller. The unit-specific environment used
Julia 1.13.3, one OpenBLAS thread and existing package caches. A private depot
held copies of the manifest's package sources. The run verified the tree
hashes of RTC 0.7.3, PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2+0,
PipeWireAOQueue_jll 0.1.0+0, AOS 0.3.22, HIL 0.5.1, AdaptiveOpticsCalibration
0.17.3, Proper 0.4.1, FilterGraphAlgorithms 0.12.2, FilterGraphs 0.10.2 and
FilterGraphPipeWire 0.5.3 against the sealed manifest. Its SHA-256 is
`01a7bdb11705948ddd1139e9e317f5e98c828a1caaa8a913751f83bdf1a0e1f0`.
The core used the original SDK artifact
`b84754cc61ae9a8e33d31ec4352f188fa5405581` and the separate registered queue.

The AMD Ryzen 7 6800H host used the sealed CPU placement. The core and RTC
used CPUs 2–3, HIL used 6–7, and the controller used 8–9. This is a
fresh-process software check with cached packages and ordinary scheduling.

## Startup against the configured budget

Systemd confirmed `TimeoutStartSec=900.0`. Invocation
`0318eaa45cd7411faee6ecb9467219ce` reached Ready in **508.59 s** from
the journal's Starting to Started events, leaving **391.41 s** (43.5%) of
the budget. The launcher independently verified native Ready and the owner
incarnations after 524.64 s from the start command. Installation took 29.43 s
before the budget began.

| Milestone | Seconds since systemd Starting | Phase interval |
| --- | ---: | --- |
| Private core socket and registry available | 45.87 | Service preparation and core start |
| Standalone HIL and graph processes started | 46.34 | 0.47 s after the core observation |
| Graph bootstrap Preparing | 68.12 | 21.78 s after graph process start |
| HIL bootstrap Preparing | 77.68 | 31.34 s after HIL process start |
| Graph bootstrap Prepared | 361.44 | 293.32 s from graph Preparing |
| HIL bootstrap Prepared | 487.57 | 409.90 s from HIL Preparing |
| HIL bootstrap Connected | 490.70 | 3.13 s from HIL Prepared |
| Graph bootstrap Connected | 493.20 | 2.50 s after HIL Connected |
| All 21 Links active or paused | 498.27 | 5.07 s after both owners Connected |
| Managed Ready and systemd Started | 508.59 | 10.32 s after Links were present |

The phase markers come from systemd's monotonic journal and roughly 0.6 s
registry polling of the published bootstrap capability records. HIL and
graph preparation overlap. The managed graph endpoint reports preparation,
owner construction, and warmup together as Preparing. The separate
dual-transport selector run at instrument commit `101b7f2` isolated those
Julia calls. Its times describe the selector process.

At HIL Prepared, the HIL leader had accrued 315.11 s on CPU and 124.42 s on
the scheduler run queue since process start. At graph Prepared, the graph
leader had accrued 305.74 s on CPU and 8.50 s on the run queue. These are
per-thread scheduler counters and include work outside first-use compilation.
In the earlier instrumented attempt, brief debugger samples found the graph
in LLVM post-register-allocation scheduling and HIL in LLVM loop optimization
and later in Julia type inference. Both owners were compiling during the
samples.

## Admission and command traffic

Native Ready was confirmed for the same invocation and owner PIDs. The live
registry contained all 22 declared Nodes, 21 RTC-owned Links and 18 queues
loaded from the registered artifact. Every Link matched its declared output
and input Port and its RTC owner. The 21 Links were active during the command
check and retained the same IDs across the capture. The two camera-to-graph
Links and the direct shared-command Link to HIL were active.

A native Start request completed Running. The probe attached five temporary
readers to the existing queue outputs using their declared metadata layouts.
It matched three SCC and three LLOWFS correction arrays to their own detector
exposures by acquisition identity and reference timestamp. All observed
command payloads were finite. For exposure 24, the SCC reference timestamp
was 1794263489060757231 ns and LLOWFS was 1794263489060714581 ns. The two
branch corrections retained those timestamps and camera identities. Shared
DM publication 24 carried the LLOWFS timestamp and its own acquisition
domain. All three captured shared publications matched the LLOWFS reference
in this sample. FilterGraphs selects the final accepted branch in descriptor
order when it publishes one shared command from a batch. The run establishes
traffic from both camera branches and a shared command stream. Separate
shared publications attributed to SCC were unobserved.

PipeWire emitted ndarray mixer setup warnings during admission. An initial
observation attempt offered incomplete SCC metadata and its two temporary
capture Links failed buffer negotiation. The declared production Links
remained admitted. An initial Start did not complete Running. A subsequent
native Status still reported Ready, then a direct Start completed Running.
A later Status during operation returned an expired-effect result. The
command probe used passive data observation after the acknowledged Start.

## Quit result

**The clean Quit gate failed.** The generated unit's stop hook verified the
native session and recorded that it submitted Quit. The request expired
before its correlated Offline acknowledgement. The RTC reported
`Session effect expired; outcome unknown` during cleanup. The receipt records
`attempted=true`, `accepted=false` and service result `exit-code`. Both
Julia owners exited with `retained native bootstrap controller was revoked`
after the RTC exited. The emergency hook completed cleanup 57.67 s after
systemd began stopping the unit. The socket and all three owner PIDs were
gone and the owner unit files were removed. The journals of this invocation
showed no SIGKILL, SIGABRT or wrong-context warning. The available receipt
does not identify the specific Quit effect that missed its deadline.

## Earlier attempts

The first attempt used the systemd manager's default Julia depot. HIL
encountered a missing RTC source directory during extension loading and the
stop hook could no longer load RTC. The standard emergency cleanup hook was
rerun with the isolated package sources. The ledger confirmed cleanup and
systemd escalated the compiling graph owner to SIGKILL in that attempt.

The first isolated attempt used an additional bootstrap Status client for
phase timing. Both owners reached Prepared, then an owner operation was
rejected with `EALREADY` before Link creation. The timing client shared the
bootstrap request-token space with RTC. Its presence changed the experiment,
so the recorded admission run used only passive registry observation during
startup. The failed attempt's cleanup was confirmed.
