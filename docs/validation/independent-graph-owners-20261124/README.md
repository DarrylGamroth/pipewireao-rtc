# Controller graph services across RTC restarts

The comparison concerns the installed service option described in the
[operating procedure](../../SYSTEMD_SESSION_STARTUP.md#keep-controller-graph-services-running-across-an-rtc-restart).
The [bootstrap contract](../../OWNER_BOOTSTRAP_DESIGN.md#graph-service-lifetime-across-rtc-sessions)
specifies the public behaviour for another implementation.

## Regression checks

The [full package suite](rtc-suite.log.gz) passed **11,830 assertions in
551 testsets** on the final implementation at `c390d00`, with Julia 1.13.3
and the native prefix supplied by PipeWireAO_jll. The installed final CAL2
candidate `c7737e0` has identical `src/` and `ext/` trees. Earlier installed
measurements used `e828a4ca`, which matches the original implementation at
`c84a32c` apart from installer rollback. The fixed and earlier activations
are identified separately below.

- The [private-core bootstrap test](../../../test/owner_bootstrap.jl) exercised claimant loss during Connect and
  while Connected, fresh bootstrap serials, a foreign Quit, an unclaimed Quit
  and the claimant's acknowledged Quit. It also expired the ticket during
  final Connect completion and during the terminal Quit synchronization. All
  91 assertions passed.
- A [leaky-integrator graph](../../../test/persistent_graph_owner.jl) ran twice in the same live process. Its
  graph and bootstrap serials changed, the service instance stayed fixed,
  and a change to the fixture graph file between sessions left the retained
  in-memory configuration intact. All eight assertions passed. The installed
  service additionally checks the identity of its inputs at admission.
- The [installer](../../../test/test_persistent_graph_deployment.jl) and launcher tests passed 46 checks for persistent graph
  deployment and 183 existing checks for owner units and the installed
  launcher. Cases include ineligible graphs, changed calibration, stable unit
  names, exact library mapping and cleanup after a rejected calibration without touching the independent services.
  The focused offline cold installer fixture passed 637 checks, including
  rollback of a partial copy, retry to the same destination, Git export
  validation and symlinks. It used a retained CAL2 manifest pinned to
  PipeWireAORTC 0.7.30. The stock registry available for this run contained
  versions through 0.7.29.

## Installed CAL2 timing and first corrections

The independent optical simulator was already publishing. These CPU HIL
measurements use monotonic wall time from requesting service activation to
systemd Ready. A separate caller also checked the held graph through native
Status and matched the 10 declared Links. In the matched pair on `e828a4ca`,
the first activation started both graph processes. The second followed an
acknowledged native Stop and systemd Quit. The two processes retained their
PIDs, process start ticks and systemd invocation IDs. Their native bootstrap
and data Nodes and all session Link serials changed.

| Activation in the matched pair | Time to Ready |
| --- | ---: |
| Start RTC and both graph processes | 13.501 s |
| Restart RTC with the same two graph processes | 8.833 s |

This restart saved **4.667 s (35%)** in one matched pair. The earlier cold
activations on the same candidate took 16.799 and 17.333 s under different
source/host conditions. The fixture used ordinary workstation scheduling.
These measurements establish neither a worst-case bound nor a comparison
with instrument-matched HEART hardware.

For the warm 8.833 s run, the fixture confirmed a new camera sample while
held and sent explicit Start. After the Start acknowledgement, LLOWFS
produced its first observed qualifying residual after **64.770 s**
(acquisition 11), and SCC produced its first qualifying chopped pair after
**192.764 s** (acquisition 3). Both physical offset vectors were zero. The
HIL feeder staged one pupil per 32 **wall-clock** seconds, with 2 ms LLOWFS and
10 ms SCC exposures in **model time**. These intervals include waiting for
the real simulated camera outputs and polling observation. They do not
measure graph execution latency or predict on-sky frame latency.

| Separate signed correction checks on the same build | Open-loop acquisition | First observed acquisition after Close | Maximum absolute error versus calibrated projection |
| --- | ---: | ---: | ---: |
| SCC | 6 | 7 | 4.79 × 10⁻¹⁷ m (tolerance 1.43 × 10⁻¹⁵ m) |
| LLOWFS, fresh HIL process | 5 | 6 | 3.16 × 10⁻¹⁶ m (tolerance 8.80 × 10⁻¹⁵ m) |

Each check compared all 2,304 channels. A premature Close was refused. Each
branch primed on live simulated camera data with zero correction before its
explicit Close. The SCC and LLOWFS signed checks used separate activations.

The original test feeder waited for a LLOWFS output before staging its next
pupil. It stopped at pupil 65 when it missed that observation. The fixture was
then changed to pace pupil submissions independently and check for overwrite.
In that run SCC continued delivering exposures while the LLOWFS tap and
controller missed frames. LLOWFS eventually stopped appearing at the persistent
tap after sequence 17. The cause of that delivery gap remains unestablished.
The independent source kept its process and clock across RTC restarts.

## Unexpected process exit on forced RTC replacement

On `e828a4ca`, killing the RTC after the first signed SCC correction revoked
its native controller, but its LLOWFS graph process exited with `EPIPE`.
With an in-flight native FIFO buffer, tearing down the session-owned Link
can wake the graph's native run call before the bootstrap connection has
observed controller removal. The persistent owner now handles that specific
error on its control path. It waits up to five seconds for the bootstrap
monitor to prove that its exact claimant was revoked, and retires the
attachment immediately upon proof. A still-valid claimant, deadline without
revocation, native core failure or cleanup error retains the failure. This
exception path adds no waiting to ordinary frame processing or startup.

The [private-core FIFO regression](../../../test/persistent_graph_owner_faults.jl)
failed at the retirement assertion on `c84a32c` and passed all 15 checks on
the repair. It removes an actual Link with a retained buffer and tests delayed
claimant loss, a still-valid claimant, and session-scoped operation.

On the repaired installed build, the first activation with prestarted graph
services reached Ready in **14.093 s**. Its LLOWFS integrator primed open on
acquisition 14. After explicit closure, the first observed correction on
acquisition 16 matched all 2,304 calibrated channels (maximum absolute error
3.16 × 10⁻¹⁶ m). The test then sent SIGKILL to the Running RTC with LLOWFS
closed. All ten session Links and the old native authority retired. LLOWFS
acquisition 17 arrived while the RTC was absent. Both graph services retained
their unit invocation IDs, PIDs, process start ticks and bootstrap instances.

The replacement reached native and systemd Ready in **11.839 s** with fresh
session, Link and graph endpoint identities. Both loops reported Open and
unprimed. Start and premature Close checks confirmed the previous session's
permission to correct did not carry over. The replacement subsequently
acknowledged a normal Quit. A different graph process under the same unit
name had faulted the earlier Running session in a separate negative trial.
In the final trial, changing one installed calibration coefficient prevented
a new Ready, retained the original input error in the failed invocation
record and completed cleanup without stopping the independent graph services.
Explicitly stopping the graph services subsequently left the source and core
running. The fixture then stopped those two services separately.

The persistent camera tap observed LLOWFS 17 and 20 in the two RTC-off gaps
on the final build. It missed sequences 9, 12, 15, 18 and 19 during that
series. Acquisition domains and generations remained stable and model time
advanced for the samples actually observed. This establishes continuity of
service identity across restart and records the observed gaps.

The [matched startup and optical receipts](cal2-timing-and-optics.tar.gz)
contain the cold/warm pair and both camera oracles. The [final installed
replacement receipts](cal2-rtc-replacement.tar.gz) contain the signed LLOWFS
correction, exact RTC kill and replacement, changed-calibration refusal and
unit teardown, together with the fixture scripts and build manifests.

## CPU sharing

On this host logical CPUs 2 and 3 are hardware threads of the same physical
core. The RTC main thread and PipeWire main loop were both pinned to CPU 3.
PipeWire's data loop used CPU 2. LLOWFS ran on 8/9, SCC on 10/11 and the
simulator on 6/7. These are four physical cores with two hardware threads each.

During the matched **8.833 s** warm restart, the last pre-Ready samples showed
5.846 s of execution and 0.080 s of runnable wait for the RTC main thread.
The preparation process's main thread accumulated 1.496 s of execution and
0.019 s of runnable wait. On the repaired
11.839 s restart, the corresponding RTC and preparation main-thread waits
were 0.140 and 0.042 s. These counters cover
the sampled threads. They exclude time blocked on other work and the effect
of simultaneously executing threads sharing physical-core resources.
[Linux scheduler counter definitions](https://docs.kernel.org/scheduler/sched-stats.html)

We also sampled each application thread and logical CPU for 49.36 s during
the warm optical run. CPU 6 was 100% busy. The simulator main thread executed
for 48.09 s and waited 1.26 s runnable. Another simulator thread on CPU 6
executed for 1.24 s and waited 1.28 s. CPU 7 was 10.4% busy. The four
controller CPUs ranged from 1.6% to 3.5% busy. SCC exposure 6 arrived during
the sample. The persistent LLOWFS observer had last received sequence 17.
This sample identifies where the CPU time went. It cannot attribute the
missing LLOWFS deliveries to a scheduler or a PipeWire mechanism.
[Per-thread results and startup samples](cpu-sharing.json) ·
[Raw per-second samples](cpu-sharing-samples.jsonl.gz)

## Instrument scope

This is an opt-in change to the shared RTC. Deployment selects graph services
by execution contract. Applications can also have conventional session-scoped
owners. GPI2 profiles that declare recovery controllers and SPIDERS profiles
using composed graphs or recovery remain on the session-scoped path. A
Classic CPU graph must have live priming configured to be eligible. An
installed restart measurement applies only to the instrument, graph variant,
source and host on which it ran.
