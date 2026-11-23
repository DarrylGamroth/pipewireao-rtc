# RTC startup and integration review

The Classic CPU controller spent 96.694 s between finishing construction of
its numerical graph and starting its synthetic graph check on the 226.110 s
launch. The simulator had already connected and was held. The RTC's operator
command check used 86 ms. The next startup investigation should follow the
Classic controller through that 96.694 s interval. The next integration
should bring the six native NDArray commits onto the same baseline as CAL2's
live open-loop priming. The [worktree inventory](worktrees.md) identifies
which other work can be parked.

## START-01. What occupied the 226 seconds?

We matched the GUI worker's two retained REVOLT Classic CPU runs to the
systemd journals of their RTC, graph, simulator and parameter processes.
The table uses elapsed seconds since service start. The processes worked
concurrently, so their durations cannot be added. Publication, the independent Ready check and Running use the harness clock.
The intermediate service and owner boundaries use journal receipt times. The [source table](classic-phases.tsv) identifies both units,
clock origins, capture hashes and journal queries.

| Milestone | Earlier build | With the RTC command package image |
| --- | ---: | ---: |
| Graph and simulator services launched | 14.8 s | 18.7 s |
| Controller starts building its numerical graph | 52.6 s | 50.8 s |
| Controller finishes building its numerical graph | 126.8 s | 103.3 s |
| Simulator confirms connected and held | 132.6 s | 67.1 s |
| Controller starts its synthetic graph check | 302.1 s | 200.0 s |
| Controller finishes its synthetic graph check | 323.8 s | 210.4 s |
| RTC's launch client observes that owners and Links are prepared and held | 333.0 s | 215.6 s |
| Harness observes the published RTC | 342.2 s | 221.6 s |
| Harness attaches and independently confirms native Ready | 351.7 s | 224.2 s |
| Native Start reaches Running | 355.2 s | 226.1 s |

**Established.** The controller spent 52.470 s building the configured
Classic numerical graph in the new run. Then 96.694 s elapsed before its
synthetic check began. That check itself took 10.453 s. In the old run the
corresponding intervals were 74.227, 175.330 and 21.737 s. This particular
Classic graph costs substantially more to start than the CAL2 graphs.
On the new run the RTC's launch client was already waiting for its
owners at 80.964 s. The Classic graph could only report prepared after its
own warmup. That places the graph directly on the path to Ready.

**Unresolved.** The graph code hands the prepared graph to `run_prepared`,
builds its PipeWire node in disconnected state, sets up its observers and
then calls the synthetic check. The wait for the native Connect command
comes later. These journals cannot separate Julia first-use compilation,
node construction, observer setup and time runnable on a shared CPU inside
the 96.694 s interval. The graph's elapsed compilation counters and unit
lifetime CPU totals cannot supply that attribution. The two source files at
the tested revision are `fadea7a:ext/PipeWireAORTCGraphExt.jl` and
`fadea7a:src/media_session/session.jl`.

The installed Classic fixture already held a 37.5 MB compiled
`ExportedGraphWarmup.so` for the controller. Both child journals' command
lines include `Base.require(Main, :ExportedGraphWarmup)` and
`--compiled-modules=existing`. Their messages contain no cache-hit receipt
and the captures have no process image maps. A cache on disk and a request
to load it establish neither successful reuse nor coverage of these concrete
node and observer types.

**First experiment.** On the same installed Classic graph, capture the running
controller's mapped graph image and its hash. Time entry to
`run_prepared`, graph-node construction, observer attachment and the start
of the first graph execution. Record monotonic elapsed time, process CPU,
leader runnable wait and Julia compilation for each interval. Repeat in fresh
processes with the same dependency versions, CPU placement and populated
depot. A disconnected run on captured inputs can isolate first-use code.
An installed restart shows whether improving it advances Ready. Record the
first real frame, first operator reply and the values applied by the controller.

## START-02. Keep install-time work out of the control deadline

The command sent by the GUI updates a deformable-mirror offset. The command
handler must decode it, check its identity and format, deliver it and send
a correlated reply within its five-second request deadline. On
`codex/native-ndarray-interchange`, the RTC package build exercises vector
and matrix command paths on small representative inputs. The runtime retains
a short check for the ranks actually deployed and a fallback for uncovered
ranks. Compiling an uncovered rank three still took 10.2–10.9 CPU-seconds
in a separate cold probe. If an instrument deploys that rank, exercise it in
its installed image and time its first command before admitting the build.

On Classic, command preparation fell from **65.162 to 0.086 s elapsed** and
from **20.948 to 0.020 s of process CPU**. The main thread's runnable wait
fell from 44.212 to 0.065 s. The earlier 27 and 96 s observations lack the
phase counters to reconstruct their exact difference. In the paired runs the
first GUI offset reply took 381 and 280 ms and all 277 values matched after
each edit and restore. One prior build had already replied in 255 ms under
different load. The demonstrated improvement is avoiding first-use compiler
work at service launch. The 129 s end-to-end difference also includes
different CPU contention and controller startup. The package image grew by
15.2 MB in this test.

Take the branch from its common base `6416ed8`. The first two commits add
sealed-descriptor FITS transfer and in-memory serialization. `76c96fb`
introduces native parameter updates, `63931b5` prepares the first configured
update, `bf497d2` records verification and `fadea7a` adds command-image
coverage. A merge preview with `main@f62e1e1` reports textual conflicts
only in the evidence index and roadmap. Both development lines touch the
session's control behavior. Validate the combined tree with a first native
vector and matrix write, format rejection, acknowledgement and scientific
readback, CAL2 refusal of premature closure, its first signed correction,
and Stop/Quit. The individual test suites exercised different source trees.
The bootstrap cache fix `e0fe1e7` is already an ancestor of both tips.

## START-03. What to keep at RTC restart

| When | Work and ownership |
| --- | --- |
| Package build and instrument installation | Compile common commands and the instrument's actual graph specializations. Validate static declarations, dimensions and calibration bindings. Exercise synthetic scientific outputs with the installed calibration. CAL2 already does this last step at install. |
| RTC activation | Give this invocation a fresh identity. Attach to the live core and source, start required RTC-owned processes, allocate and bind their actual resources, verify the current ports, Links, placement and held state, then publish Ready. Static files cannot prove those properties of today's running processes. |
| After Start, correction open | On CAL2, collect the first usable LLOWFS exposure and the first complete SCC chopped pair. Accept a fresh close request only after the relevant live measurement. A separately supervised simulator can keep publishing across RTC replacement. |
| Stop, failure or cancellation | Clean up this invocation's processes and Links, preserve the first failed effect and retain ownership boundaries for an independent source. A late owner or an earlier discovery record cannot authorize a new RTC. |

Today systemd first calls a Julia helper that validates the deployment,
identifies the source and starts the owners. The RTC main process opens
the native endpoint and establishes its held graph. A second Julia helper,
`publish`, reads the deployment again, waits for the RTC, inspects live
processes and placement, sends Admit, requires fresh Ready, and publishes
the locator that the GUI uses. It also submits configured optional analysis
units. The warmup poll participates in authenticating the launch client.
Moving that code requires an equivalent admission and cancellation path.
[Unit template](../../../assets/deployment/pipewireao-session@.service.in)
· [Launch preparation](../../../src/deployment/session_launch.jl)
· [Ready publication](../../../src/deployment/session_cli.jl)
· [Optional analysis cleanup](../../../src/deployment/analysis_services.jl)

The smaller CAL2 case measures the cost of this orchestration. On its
22.016 s restart with an already publishing camera, the preparation helper,
RTC main thread and publication helper used 3.64, 10.30 and 4.38 CPU-seconds
respectively. Preparation runs before the RTC. Publication overlaps it.
CAL2's old synthetic checks took only 1–3 ms per controller and the
reverse-order comparison found no repeatable Ready improvement from moving
them to installation. [CAL2 restart evidence](../../validation/cal2-live-prime-20261123/README.md)

**Recommended design after consolidation.** Validate immutable deployment
facts once and carry forward the validated facts for the current invocation.
Have MediaSession announce that its own admitted session is ready. Use an
off-data-thread startup effect for process and placement checks. Publish the
discovery record before notifying systemd from the main process. This can
remove a Julia process, another cold profile read and polling round trips.
It retains systemd supervision and MediaSession's existing ownership under
RTC-ARCH-026. The benefit in service wall time still needs measurement.
[Ownership contract](../../architecture.md) · [systemd readiness notification](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)

Test normal launch and failure before replacing the publisher. Exercise a
wrong CPU, an owner replaced during verification, required Link loss, startup
cancellation with optional analysis pending, and a fresh RTC against the
same independent source. Alternate new and baseline launches and report
service-to-Ready, Ready-to-Running, first usable input and first command
separately. For the on-sky restart case, use a source already publishing.
For Classic, retain a managed-source comparison to relate back to these
journals. A target service-to-Ready deadline remains an operational decision.

## Order of work

1. Use one RTC integration checkout for the native NDArray series and existing
   CAL2 changes. Preserve the independent fault review and address its
   release blockers before promoting an affected build.
2. Use that same baseline to measure the Classic graph interval. Fold any
   applicable result from the old scoped-graph branch into that experiment.
3. Simplify how the RTC announces Ready once the combined start, failure
   and shutdown behavior is covered. Keep historical studies and GPU or
   SPIDERS qualification on their recorded revisions.
